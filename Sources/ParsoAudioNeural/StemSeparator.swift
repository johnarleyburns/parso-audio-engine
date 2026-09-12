#if !os(watchOS)
import Accelerate
import AVFoundation
import Foundation
import ParsoAudioAnalysis

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

#endif
