//
//  Separation.swift
//  The model-agnostic stem-separation seam (Phase 7c): chunking, overlap-add,
//  and the `StemModelProviding` protocol every separation backend conforms
//  to. Ported and generalized from parso-tonearm/Sources/DJ/Stems/StemModel.swift
//  + StemSeparator.swift (the chunk/overlap-add kernel and the protocol
//  shape; the model-specific pieces — `DemucsStemModel`, `DemucsSpectrogram`
//  — stay in the consuming app or, for Spleeter, live in this target's
//  SpleeterStemModel.swift/SpleeterSpectrogram.swift). See ATTRIBUTION.md.
//
//  Runtime-swappable by design (current_status.md "Phase 7c"): nothing here
//  is tied to a specific model. `SeparationBackendRegistry` (below, in
//  SeparationBackendRegistry.swift) lets a host app register multiple
//  `StemModelProviding` conformances and switch the active one at runtime
//  with no code change — e.g. shipping Spleeter today and swapping in a
//  BS-RoFormer or Slakh2100-trained backend later purely by registering it
//  and flipping the active id, once one is available under a legally clear
//  license. See current_status.md "Phase 7" for the licensing survey behind
//  this default.
//
#if !os(watchOS)
import Accelerate
import AVFoundation
import Foundation
import ParsoAudioAnalysis

// MARK: - Stem identity

/// The four separated voices. The order matters — it is the order every
/// separator, cache and reader agrees on. This 4-voice shape matches both
/// Demucs-family models and Spleeter's `4stems` configuration.
public enum SeparationVoice: String, CaseIterable, Sendable, Equatable, Codable {
    case vocals
    case drums
    case bass
    case other

    /// The on-disk file name for this voice in a stem cache (`vocals.caf`, …).
    public var fileName: String { "\(rawValue).caf" }

    /// The fixed index of this voice in `SeparationVoice.allCases` order.
    public var index: Int {
        switch self {
        case .vocals: return 0
        case .drums: return 1
        case .bass: return 2
        case .other: return 3
        }
    }

    /// The voice at a fixed index; out-of-range indices clamp to `.other` so
    /// a malformed payload degrades instead of crashing a real-time caller.
    public init(index: Int) {
        switch index {
        case 0: self = .vocals
        case 1: self = .drums
        case 2: self = .bass
        default: self = .other
        }
    }
}

// MARK: - Audio shapes

/// A stereo Float32 pair at a known sample rate — the unit a separation
/// model runs on and the shape of every full-length voice a separator
/// produces. Both channels have equal length; mono sources are duplicated
/// into L/R.
public struct StemChunk: Sendable, Equatable {
    public let sampleRate: Double
    public let left: [Float]
    public let right: [Float]

    public init(sampleRate: Double, left: [Float], right: [Float]) {
        precondition(left.count == right.count, "stereo channels must have equal length")
        self.sampleRate = sampleRate
        self.left = left
        self.right = right
    }

    public var frameCount: Int { left.count }
}

/// The four voices produced for one track (or one chunk) by a stem model. A
/// single container serves both the per-chunk model output and the
/// full-length reconstruction, so the separator and any cache share one shape.
public struct StemSeparation: Sendable, Equatable {
    public let sampleRate: Double
    public let vocals: StemChunk
    public let drums: StemChunk
    public let bass: StemChunk
    public let other: StemChunk

    public init(sampleRate: Double, vocals: StemChunk, drums: StemChunk,
                bass: StemChunk, other: StemChunk) {
        self.sampleRate = sampleRate
        self.vocals = vocals
        self.drums = drums
        self.bass = bass
        self.other = other
    }

    public func voice(_ kind: SeparationVoice) -> StemChunk {
        switch kind {
        case .vocals: return vocals
        case .drums: return drums
        case .bass: return bass
        case .other: return other
        }
    }

    /// The four voices keyed by kind, in `SeparationVoice.allCases` order.
    public var all: [(kind: SeparationVoice, audio: StemChunk)] {
        SeparationVoice.allCases.map { ($0, voice($0)) }
    }
}

// MARK: - The model seam

/// Errors a separation backend can surface. Absence is **not** an error — a
/// missing model yields `nil` from `separate`; these are real failures.
public enum StemModelError: Error, LocalizedError, Equatable {
    case modelLoadFailed(String)
    case inferenceFailed(String)

    public var errorDescription: String? {
        switch self {
        case .modelLoadFailed(let detail):
            return "Could not load the stem model: \(detail)"
        case .inferenceFailed(let detail):
            return "Stem separation failed: \(detail)"
        }
    }
}

/// The swappable seam every separation backend conforms to. Everything above
/// this protocol — chunking, overlap-add, caching, the service, the UI — is
/// identical for every conformance. Absence is a value: a missing model
/// means "no separation", and the caller falls back to playing the full mix
/// — never an error and never a lie.
public protocol StemModelProviding: Sendable {
    /// The model version stamp a caller can use to drive stem-cache
    /// invalidation (a model upgrade/swap invalidates the cache, like an
    /// analysis-version bump).
    var version: Int { get }
    /// The rate and segment the model was trained at. A separator resamples
    /// the track to this rate **once**, chunks at this length, and resamples
    /// the voices back — an off-by-a-few-hundred-samples drift here shifts
    /// every stem against the full mix by milliseconds.
    var nativeSampleRate: Double { get }
    var segmentFrames: Int { get }
    /// Whether the model is currently available (a caller-supplied `.mlpackage`
    /// that has not finished downloading is a normal, expected absence).
    func isAvailable() async -> Bool
    /// Runs one fixed-length stereo chunk through the model, producing the
    /// four voices at the same length. Returns nil when the model is absent.
    func separate(chunk: StemChunk) async throws -> StemSeparation?
}

public extension StemModelProviding {
    /// Working-rate default: a model that runs at the separator's own 48 kHz
    /// rate and 2¹⁷-frame chunk needs no resampling.
    var nativeSampleRate: Double { StemChunking.workingSampleRate }
    var segmentFrames: Int { StemChunking.chunkFrames }
}

// MARK: - Chunk / overlap-add kernel

/// The pure chunk/overlap-add geometry and kernel a separator drives: the
/// model runs on fixed-length stereo chunks; the outputs are windowed and
/// overlap-added to reconstruct full-length voices with no seam artifacts.
///
/// The window is a **periodic Hann** applied once to each chunk's model
/// output. At 50% overlap its first-power COLA (constant overlap-add) sum is
/// exactly 1 (`w[i] + w[i + hop] == 1`), so a passthrough model reconstructs
/// its input exactly in the interior.
public enum StemChunking {
    /// The working sample rate a separator and cache write at by default. A
    /// model running at a different rate is resampled inside its own wrapper;
    /// the kernel always works at this rate.
    public static let workingSampleRate: Double = 48_000
    /// Fixed-length chunk in frames (~2.73 s at 48 kHz).
    public static let chunkFrames = 1 << 17
    /// Overlap in frames — 50% of the chunk.
    public static let overlapFrames = 1 << 16
    /// Frames advanced between chunks.
    public static var hopFrames: Int { chunkFrames - overlapFrames }

    /// Periodic Hann: `w[i] = 0.5(1 − cos(2πi/N))`. Exact first-power COLA at
    /// 50% overlap, which is what makes the reconstruction exact.
    /// (Accelerate's own `vDSP_HANN_NORM` is energy-normalized and does *not*
    /// hold this identity, so the window is generated here; the vector math
    /// below is still vDSP.)
    public static func window(_ count: Int) -> [Float] {
        guard count > 0 else { return [] }
        return (0..<count).map { i in
            Float(0.5 * (1 - cos(2 * Double.pi * Double(i) / Double(count))))
        }
    }

    /// Split stereo PCM into overlapping chunks, each exactly `chunkFrames`
    /// long; the final chunk is zero-padded so every chunk has equal length.
    public static func chunks(left: [Float], right: [Float],
                              chunkFrames: Int, hop: Int) -> [(left: [Float], right: [Float])] {
        let frameCount = max(left.count, right.count)
        guard frameCount > 0, chunkFrames > 0, hop > 0 else { return [] }
        var result: [(left: [Float], right: [Float])] = []
        var offset = 0
        while offset < frameCount {
            result.append((left: slice(left, from: offset, to: offset + chunkFrames),
                           right: slice(right, from: offset, to: offset + chunkFrames)))
            offset += hop
        }
        return result
    }

    /// Window each chunk output with `window` and overlap-add into a single
    /// `totalFrames`-long channel. `window` must be the periodic Hann of the
    /// chunk length; all chunks must have that same length.
    public static func overlapAdd(chunkOutputs: [[Float]], window: [Float],
                                  hop: Int, totalFrames: Int) -> [Float] {
        guard let chunkFrames = chunkOutputs.first?.count, chunkFrames > 0,
              window.count == chunkFrames, hop > 0 else {
            return [Float](repeating: 0, count: totalFrames)
        }
        var output = [Float](repeating: 0, count: totalFrames)
        var windowed = [Float](repeating: 0, count: chunkFrames)
        for (k, chunk) in chunkOutputs.enumerated() {
            let offset = k * hop
            guard offset < totalFrames else { break }
            guard chunk.count == chunkFrames else { continue }
            chunk.withUnsafeBufferPointer { cp in
                window.withUnsafeBufferPointer { wp in
                    windowed.withUnsafeMutableBufferPointer { wmp in
                        vDSP_vmul(cp.baseAddress!, 1, wp.baseAddress!, 1,
                                  wmp.baseAddress!, 1, vDSP_Length(chunkFrames))
                    }
                }
            }
            let count = min(chunkFrames, totalFrames - offset)
            output.withUnsafeMutableBufferPointer { op in
                windowed.withUnsafeBufferPointer { wp in
                    vDSP_vadd(op.baseAddress!.advanced(by: offset), 1,
                              wp.baseAddress!, 1,
                              op.baseAddress!.advanced(by: offset), 1,
                              vDSP_Length(count))
                }
            }
        }
        return output
    }

    /// Streaming sibling of `overlapAdd`: window `chunk` and add it into
    /// `output` at `offset`, clamped so the write never runs past the buffer.
    /// A separator uses this to overlap-add each chunk **as it comes back
    /// from the model**, so peak extra memory is one chunk instead of the
    /// whole track's eight voices.
    public static func overlapAddInto(_ output: inout [Float],
                                      chunk: [Float], window: [Float],
                                      offset: Int) {
        let chunkFrames = chunk.count
        guard chunkFrames > 0, window.count == chunkFrames else { return }
        guard offset >= 0, offset < output.count else { return }
        let count = min(chunkFrames, output.count - offset)
        guard count > 0 else { return }
        var windowed = chunk
        windowed.withUnsafeMutableBufferPointer { wp in
            window.withUnsafeBufferPointer { win in
                vDSP_vmul(wp.baseAddress!, 1, win.baseAddress!, 1,
                          wp.baseAddress!, 1, vDSP_Length(chunkFrames))
            }
            output.withUnsafeMutableBufferPointer { op in
                vDSP_vadd(op.baseAddress!.advanced(by: offset), 1, wp.baseAddress!, 1,
                          op.baseAddress!.advanced(by: offset), 1, vDSP_Length(count))
            }
        }
    }

    private static func slice(_ buffer: [Float], from: Int, to: Int) -> [Float] {
        var out = [Float](repeating: 0, count: max(0, to - from))
        let start = max(0, from)
        let end = min(buffer.count, to)
        if start < end {
            out[0..<(end - start)] = buffer[start..<end]
        }
        return out
    }
}

// MARK: - Separator

public enum StemSeparatorError: Error, LocalizedError, Equatable {
    case emptyInput
    case chunkLengthMismatch
    /// The model reported available but stopped producing output mid-run —
    /// loud, never a silent partial result.
    case modelUnavailableDuringSeparation
    /// Resampling the voices back to the working rate did not reproduce the
    /// input's frame count.
    case resampledVoiceLengthMismatch(expected: Int, got: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyInput: return "The track has no audio to separate"
        case .chunkLengthMismatch:
            return "The stem model returned a voice of the wrong length"
        case .modelUnavailableDuringSeparation:
            return "The stem model became unavailable during separation"
        case .resampledVoiceLengthMismatch(let expected, let got):
            return "A separated voice came back \(got) frames long, expected \(expected)"
        }
    }
}

/// Resamples stereo PCM to a target rate with `AVAudioConverter`, once per
/// track at the separator, not per chunk.
enum StemResampler {
    static func resample(left: [Float], right: [Float],
                         from: Double, to: Double) throws -> (left: [Float], right: [Float]) {
        (left: try resampleChannel(left, from: from, to: to),
         right: try resampleChannel(right, from: from, to: to))
    }

    private static func resampleChannel(_ input: [Float], from: Double, to: Double) throws -> [Float] {
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: from, channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: to, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw StemSeparatorError.resampledVoiceLengthMismatch(expected: input.count, got: 0)
        }
        let inBuffer = AVAudioPCMBuffer(pcmFormat: source,
                                        frameCapacity: AVAudioFrameCount(input.count))!
        inBuffer.frameLength = AVAudioFrameCount(input.count)
        input.withUnsafeBufferPointer { src in
            inBuffer.floatChannelData![0].update(from: src.baseAddress!, count: input.count)
        }
        final class InputState: @unchecked Sendable {
            let buffer: AVAudioPCMBuffer
            var done = false
            init(buffer: AVAudioPCMBuffer) { self.buffer = buffer }
        }
        let state = InputState(buffer: inBuffer)
        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if state.done {
                outStatus.pointee = .endOfStream
                return nil
            }
            state.done = true
            outStatus.pointee = .haveData
            return state.buffer
        }
        var output = [Float]()
        let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 65_536)!
        while true {
            outBuffer.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error,
                                           withInputFrom: inputBlock)
            if outBuffer.frameLength > 0, let data = outBuffer.floatChannelData {
                let buffer = UnsafeBufferPointer(start: data[0],
                                                 count: Int(outBuffer.frameLength))
                output.append(contentsOf: buffer)
            }
            if status == .endOfStream { break }
            if status == .error { throw StemSeparatorError.resampledVoiceLengthMismatch(expected: input.count, got: output.count) }
            if status == .haveData && outBuffer.frameLength == 0 { break }
        }
        return output
    }
}

/// Drives any `StemModelProviding` over a decoded track through the
/// chunk/overlap-add pipeline: slice → model → window → overlap-add → the
/// four full-length voices. Returns nil when the model is absent — the
/// caller falls back to the full mix.
///
/// The chunk geometry is the **model's**: a model that declares a native
/// sample rate and segment is resampled to it once per track and chunked at
/// its own segment with 50% overlap; a working-rate model (48 kHz, the
/// 2¹⁷-frame default) runs at the separator's own geometry. Voices are
/// resampled back to the working rate once, so a downstream cache/reader
/// stays untouched regardless of which backend is active.
public struct StemSeparator: Sendable {
    public let model: any StemModelProviding
    public let chunkFrames: Int
    public let overlapFrames: Int

    public var hopFrames: Int { chunkFrames - overlapFrames }

    /// Chunk at the model's native geometry: `segmentFrames` with 50% overlap.
    public init(model: any StemModelProviding) {
        self.model = model
        self.chunkFrames = model.segmentFrames
        self.overlapFrames = model.segmentFrames / 2
    }

    /// Explicit chunk geometry — the working-rate path reconstruction golden
    /// tests drive. `overlapFrames` defaults to 50% of the chunk.
    public init(model: any StemModelProviding,
                chunkFrames: Int? = nil,
                overlapFrames: Int? = nil) {
        self.model = model
        if let chunkFrames {
            self.chunkFrames = chunkFrames
            self.overlapFrames = overlapFrames ?? chunkFrames / 2
        } else {
            self.chunkFrames = model.segmentFrames
            self.overlapFrames = model.segmentFrames / 2
        }
    }

    /// Separate a decoded track into its four voices. The input is the
    /// canonical `AnalysisAudio`; mono sources are duplicated into L/R. The
    /// track is resampled to the model's native rate **once**, chunked at
    /// the model's segment with 50% overlap, and the voices resampled back
    /// to the input rate once — the round-trip length is asserted exact.
    public func separate(pcm: AnalysisAudio) async throws -> StemSeparation? {
        guard await model.isAvailable() else { return nil }
        let inputFrames = pcm.frameCount
        guard inputFrames > 0 else { throw StemSeparatorError.emptyInput }

        let left = pcm.channels[0]
        let right = pcm.channelCount > 1 ? pcm.channels[1] : pcm.channels[0]

        let nativeRate = model.nativeSampleRate
        let nativeL: [Float]
        let nativeR: [Float]
        if abs(pcm.sampleRate - nativeRate) < 0.001 {
            nativeL = Array(left)
            nativeR = Array(right)
        } else {
            (nativeL, nativeR) = try StemResampler.resample(
                left: Array(left), right: Array(right),
                from: pcm.sampleRate, to: nativeRate)
        }
        let frameCount = nativeL.count
        let hop = hopFrames
        let window = StemChunking.window(chunkFrames)

        // Eight full-length output buffers, allocated **once**. Each chunk is
        // windowed and added into place as it returns from the model, so
        // peak extra memory is one chunk, not ~2× the track × 8 channels.
        var vocalsL = [Float](repeating: 0, count: frameCount)
        var vocalsR = [Float](repeating: 0, count: frameCount)
        var drumsL = [Float](repeating: 0, count: frameCount)
        var drumsR = [Float](repeating: 0, count: frameCount)
        var bassL = [Float](repeating: 0, count: frameCount)
        var bassR = [Float](repeating: 0, count: frameCount)
        var otherL = [Float](repeating: 0, count: frameCount)
        var otherR = [Float](repeating: 0, count: frameCount)

        var offset = 0
        while offset < frameCount {
            let count = min(chunkFrames, frameCount - offset)
            var chunkLeft = [Float](repeating: 0, count: chunkFrames)
            var chunkRight = [Float](repeating: 0, count: chunkFrames)
            chunkLeft.withUnsafeMutableBufferPointer { p in
                nativeL.withUnsafeBufferPointer { nl in
                    p.baseAddress!.update(from: nl.baseAddress!.advanced(by: offset), count: count)
                }
            }
            chunkRight.withUnsafeMutableBufferPointer { p in
                nativeR.withUnsafeBufferPointer { nr in
                    p.baseAddress!.update(from: nr.baseAddress!.advanced(by: offset), count: count)
                }
            }

            guard let result = try await model.separate(
                chunk: StemChunk(sampleRate: nativeRate,
                                 left: chunkLeft, right: chunkRight))
            else {
                throw StemSeparatorError.modelUnavailableDuringSeparation
            }
            guard result.vocals.frameCount == chunkFrames,
                  result.drums.frameCount == chunkFrames,
                  result.bass.frameCount == chunkFrames,
                  result.other.frameCount == chunkFrames else {
                throw StemSeparatorError.chunkLengthMismatch
            }

            StemChunking.overlapAddInto(&vocalsL, chunk: result.vocals.left, window: window, offset: offset)
            StemChunking.overlapAddInto(&vocalsR, chunk: result.vocals.right, window: window, offset: offset)
            StemChunking.overlapAddInto(&drumsL, chunk: result.drums.left, window: window, offset: offset)
            StemChunking.overlapAddInto(&drumsR, chunk: result.drums.right, window: window, offset: offset)
            StemChunking.overlapAddInto(&bassL, chunk: result.bass.left, window: window, offset: offset)
            StemChunking.overlapAddInto(&bassR, chunk: result.bass.right, window: window, offset: offset)
            StemChunking.overlapAddInto(&otherL, chunk: result.other.left, window: window, offset: offset)
            StemChunking.overlapAddInto(&otherR, chunk: result.other.right, window: window, offset: offset)

            offset += hop
        }

        func back(_ l: [Float], _ r: [Float]) throws -> StemChunk {
            let (lOut, rOut): ([Float], [Float])
            if abs(nativeRate - pcm.sampleRate) < 0.001 {
                lOut = l; rOut = r
            } else {
                (lOut, rOut) = try StemResampler.resample(left: l, right: r,
                                                          from: nativeRate, to: pcm.sampleRate)
            }
            guard lOut.count == inputFrames, rOut.count == inputFrames else {
                throw StemSeparatorError.resampledVoiceLengthMismatch(
                    expected: inputFrames, got: lOut.count)
            }
            return StemChunk(sampleRate: pcm.sampleRate, left: lOut, right: rOut)
        }

        return StemSeparation(sampleRate: pcm.sampleRate,
                              vocals: try back(vocalsL, vocalsR),
                              drums: try back(drumsL, drumsR),
                              bass: try back(bassL, bassR),
                              other: try back(otherL, otherR))
    }
}
#endif
