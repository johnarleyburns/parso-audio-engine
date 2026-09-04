//
//  SemanticPreprocess.swift
//  The CLAP log-mel frontend, ported from
//  parso-tonearm/Sources/DJ/Semantic/Preprocess.swift. See ATTRIBUTION.md.
//  `PCMBuffer` (Tonearm) -> `ParsoAudioAnalysis.AnalysisAudio` (PAE).
//
#if !os(watchOS)
import Foundation
import Accelerate
import ParsoAudioAnalysis
@preconcurrency import AVFoundation

public enum SemanticPreprocessError: Error, LocalizedError {
    case resampleFailed
    case invalidSpec(String)
    case noAudio

    public var errorDescription: String? {
        switch self {
        case .resampleFailed: return "Could not resample analysis PCM to the model rate"
        case .invalidSpec(let detail): return "Invalid embedding model spec: \(detail)"
        case .noAudio: return "No audio to embed"
        }
    }
}

/// The log-mel frontend, a pure `(AnalysisAudio, EmbeddingModelSpec) -> [MelWindow]`.
///
/// Reproduces the CLAP model's own frontend: mono → model rate → repeatpad a
/// window to `clipSamples` → reflect-pad `fftSize/2` each side → periodic-Hann
/// STFT → power → librosa-slaney mel → `10·log10(max(mel, 1e-10))`. `top_db`
/// is NOT applied — the reference model constructs its `LogmelFilterBank` with
/// `top_db=None`. Deterministic vDSP only.
public enum SemanticPreprocess {

    /// One fixed-size log-mel window, in the model's frame/bins layout.
    public struct MelWindow: Sendable, Equatable {
        /// Window start/end in model-rate samples.
        public let startSample: Int64
        public let endSample: Int64
        /// `frames × melBins` Float32, row-major `[frame][bin]`.
        public let logMel: [Float]
        public let frames: Int
        public let melBins: Int

        public init(startSample: Int64, endSample: Int64,
                    logMel: [Float], frames: Int, melBins: Int) {
            self.startSample = startSample
            self.endSample = endSample
            self.logMel = logMel
            self.frames = frames
            self.melBins = melBins
        }
    }

    // MARK: - Windows

    /// Split a track into `window`-sample windows at `hop` stride. Trailing
    /// partial windows shorter than a hop are dropped (50% overlap already
    /// covers their content) unless it is the only window, which is
    /// repeat-padded. The count is capped at `maxWindows` with uniform
    /// sub-sampling.
    public static func windowRanges(count: Int,
                                    window: Int,
                                    hop: Int,
                                    maxWindows: Int) -> [Range<Int>] {
        guard count > 0 else { return [] }
        var starts: [Int] = []
        var start = 0
        while start < count {
            starts.append(start)
            start += hop
        }
        while starts.count > 1, let last = starts.last, count - last < hop {
            starts.removeLast()
        }
        if starts.count > maxWindows {
            starts = (0..<maxWindows).map { index in
                let stride = Double(starts.count - 1) / Double(maxWindows - 1)
                return starts[Int((Double(index) * stride).rounded())]
            }
        }
        return starts.map { $0..<min($0 + window, count) }
    }

    /// The full frontend: resample → window → log-mel.
    public static func logMel(pcm: AnalysisAudio, spec: EmbeddingModelSpec) throws -> [MelWindow] {
        guard pcm.frameCount > 0 else { throw SemanticPreprocessError.noAudio }
        let mono = try resampledMono(pcm, to: spec.sampleRate)
        let windowSamples = Int(spec.windowSeconds * spec.sampleRate)
        let hopSamples = Int(spec.hopSeconds * spec.sampleRate)
        let ranges = windowRanges(count: mono.count,
                                  window: windowSamples,
                                  hop: hopSamples,
                                  maxWindows: spec.maxWindows)
        return try ranges.map { range in
            let logMel = try logMel(clip: Array(mono[range]), spec: spec)
            return MelWindow(startSample: Int64(range.lowerBound),
                             endSample: Int64(range.upperBound),
                             logMel: logMel,
                             frames: spec.frames,
                             melBins: spec.melBins)
        }
    }

    /// One window's log-mel: `[Float]` of `spec.frames * spec.melBins`.
    /// `clip` may be shorter than `clipSamples`; it is repeat-padded (the
    /// model's training-time "repeatpad" semantics) then processed.
    public static func logMel(clip: [Float], spec: EmbeddingModelSpec) throws -> [Float] {
        let bins = spec.fftSize / 2 + 1
        guard spec.melFilterBank.count == bins * spec.melBins else {
            throw SemanticPreprocessError.invalidSpec(
                "mel filterbank has \(spec.melFilterBank.count) entries, expected \(bins * spec.melBins)")
        }
        guard spec.frames > 0, spec.fftSize >= spec.hopSize else {
            throw SemanticPreprocessError.invalidSpec("fftSize/hopSize produce no frames")
        }

        // 1) repeatpad the window to clipSamples.
        var clipBuffer = [Float](repeating: 0, count: spec.clipSamples)
        if !clip.isEmpty {
            let repeats = spec.clipSamples / clip.count
            if repeats > 0 {
                for i in 0..<(repeats * clip.count) { clipBuffer[i] = clip[i % clip.count] }
            }
        }

        // 2) reflect-pad by fftSize/2 each side.
        let pad = spec.fftSize / 2
        var padded = [Float](repeating: 0, count: clipBuffer.count + 2 * pad)
        reflectPad(clipBuffer, into: &padded, pad: pad)

        // 3) periodic-Hann STFT -> power, bins per frame.
        var power = [Float](repeating: 0, count: spec.frames * bins)
        computePower(padded, power: &power, spec: spec)

        // 4) mel = power · melW  (melW is row-major [bins][melBins]).
        var mel = [Float](repeating: 0, count: spec.frames * spec.melBins)
        vDSP_mmul(power, 1, spec.melFilterBank, 1, &mel, 1,
                  vDSP_Length(spec.frames), vDSP_Length(spec.melBins), vDSP_Length(bins))

        // 5) 10·log10(max(mel, 1e-10)); no top_db (reference model: top_db = None).
        var logMel = [Float](repeating: 0, count: mel.count)
        let floor: Float = 1e-10
        for i in 0..<mel.count {
            logMel[i] = 10 * log10f(max(mel[i], floor))
        }
        return logMel
    }

    // MARK: - DSP kernels

    /// numpy `F.pad(mode: "reflect")`: mirror without repeating the edge sample.
    private static func reflectPad(_ input: [Float], into output: inout [Float], pad: Int) {
        let count = input.count
        for i in 0..<pad { output[i] = input[pad - i] }
        for i in 0..<count { output[pad + i] = input[i] }
        for i in 0..<pad { output[pad + count + i] = input[count - 2 - i] }
    }

    /// Windowed real FFT power spectrum, `spec.frames × (fftSize/2+1)`, matched
    /// in scale to numpy's `|rfft(x)|²`.
    private static func computePower(_ padded: [Float], power: inout [Float], spec: EmbeddingModelSpec) {
        let n = spec.fftSize
        let n2 = n / 2
        let bins = n2 + 1

        // Periodic Hann, computed in Double then Float32 — the same table the
        // reference frontend freezes (`librosa get_window hann fftbins=True`).
        var window = [Float](repeating: 0, count: n)
        for k in 0..<n {
            window[k] = Float(0.5 * (1 - cos(2 * Double.pi * Double(k) / Double(n))))
        }

        let log2n = vDSP_Length(log2(Double(n)))
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return }

        var real = [Float](repeating: 0, count: n2)
        var imag = [Float](repeating: 0, count: n2)
        var windowed = [Float](repeating: 0, count: n)

        padded.withUnsafeBufferPointer { base in
            power.withUnsafeMutableBufferPointer { powerBuffer in
                windowed.withUnsafeMutableBufferPointer { wbuf in
                    real.withUnsafeMutableBufferPointer { rbuf in
                        imag.withUnsafeMutableBufferPointer { ibuf in
                            var split = DSPSplitComplex(realp: rbuf.baseAddress!, imagp: ibuf.baseAddress!)
                            var scale: Float = 0.5
                            for t in 0..<spec.frames {
                                let offset = t * spec.hopSize
                                vDSP_vmul(base.baseAddress!.advanced(by: offset), 1,
                                          window, 1, wbuf.baseAddress!, 1, vDSP_Length(n))
                                wbuf.baseAddress!.withMemoryRebound(to: DSPComplex.self,
                                                                    capacity: n2) { cp in
                                    vDSP_ctoz(cp, 2, &split, 1, vDSP_Length(n2))
                                }
                                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(kFFTDirection_Forward))
                                // zrip forward outputs 2× the true DFT; scale by ½.
                                vDSP_vsmul(split.realp, 1, &scale, rbuf.baseAddress!, 1, vDSP_Length(n2))
                                vDSP_vsmul(split.imagp, 1, &scale, ibuf.baseAddress!, 1, vDSP_Length(n2))
                                let row = powerBuffer.baseAddress!.advanced(by: t * bins)
                                row[0] = rbuf[0] * rbuf[0]
                                for k in 1..<n2 { row[k] = rbuf[k] * rbuf[k] + ibuf[k] * ibuf[k] }
                                row[n2] = ibuf[0] * ibuf[0]
                            }
                        }
                    }
                }
            }
        }
        vDSP_destroy_fftsetup(setup)
    }

    /// Resample mono analysis PCM to the model rate. Short-circuits when the
    /// rates match (the normal case: both 48 kHz).
    private static func resampledMono(_ pcm: AnalysisAudio, to sampleRate: Double) throws -> [Float] {
        if abs(pcm.sampleRate - sampleRate) < 0.001 { return Array(pcm.mono) }
        guard let source = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: pcm.sampleRate,
                                         channels: 1, interleaved: false),
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: source, to: target) else {
            throw SemanticPreprocessError.resampleFailed
        }
        let inBuffer = AVAudioPCMBuffer(pcmFormat: source,
                                        frameCapacity: AVAudioFrameCount(pcm.frameCount))!
        inBuffer.frameLength = AVAudioFrameCount(pcm.frameCount)
        if let channel = inBuffer.floatChannelData {
            pcm.mono.withUnsafeBufferPointer { src in
                channel[0].update(from: src.baseAddress!, count: pcm.frameCount)
            }
        }
        var output = [Float]()
        let outBuffer = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 65_536)!
        // A small box so the @Sendable input block can mutate without capture rules.
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
        while true {
            outBuffer.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: outBuffer, error: &error, withInputFrom: inputBlock)
            if outBuffer.frameLength > 0, let data = outBuffer.floatChannelData {
                let buffer = UnsafeBufferPointer(start: data[0], count: Int(outBuffer.frameLength))
                output.append(contentsOf: buffer)
            }
            if status == .endOfStream { break }
            if status == .error { throw SemanticPreprocessError.resampleFailed }
        }
        return output
    }
}
#endif
