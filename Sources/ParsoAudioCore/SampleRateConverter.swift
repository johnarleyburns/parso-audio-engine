import Foundation
import Csrc

// MARK: - Sample-rate conversion (offline, libsamplerate)

public struct SampleRateConverter: Sendable {
    public enum Quality: Sendable { case best, medium, fastest }
    private let sourceRate: Double
    private let destinationRate: Double
    private let channels: Int
    private let quality: Quality

    public init(from: Double, to: Double, channels: Int, quality: Quality = .best) {
        precondition(from.isFinite && from > 0, "source sample rate must be positive")
        precondition(to.isFinite && to > 0, "destination sample rate must be positive")
        precondition(channels > 0, "channel count must be positive")
        precondition(src_is_valid_ratio(to / from) != 0, "sample-rate ratio is outside libsamplerate limits")
        self.sourceRate = from
        self.destinationRate = to
        self.channels = channels
        self.quality = quality
    }

    public func convert(_ input: PCMBuffer) throws -> PCMBuffer {
        guard input.channelCount == channels else {
            throw SampleRateConverterError.channelCountMismatch(expected: channels, actual: input.channelCount)
        }
        guard abs(input.format.sampleRate - sourceRate) < 0.5 else {
            throw SampleRateConverterError.sampleRateMismatch(expected: sourceRate, actual: input.format.sampleRate)
        }
        guard input.frameCount > 0 else {
            return PCMBuffer(
                format: AudioFormat(sampleRate: destinationRate, channelCount: channels),
                capacity: 0
            )
        }

        let ratio = destinationRate / sourceRate
        let estimatedFrames = max(1, Int(ceil(Double(input.frameCount) * ratio)) + 256)
        var interleavedInput = [Float](repeating: 0, count: input.frameCount * channels)
        for frame in 0..<input.frameCount {
            for channel in 0..<channels {
                interleavedInput[frame * channels + channel] = input.channel(channel)[frame]
            }
        }
        var interleavedOutput = [Float](repeating: 0, count: estimatedFrames * channels)

        let converter: Int32
        switch quality {
        case .best: converter = Int32(SRC_SINC_BEST_QUALITY)
        case .medium: converter = Int32(SRC_SINC_MEDIUM_QUALITY)
        case .fastest: converter = Int32(SRC_SINC_FASTEST)
        }
        let result: (error: Int32, outputFrames: Int) = interleavedInput.withUnsafeBufferPointer { inputPointer in
            interleavedOutput.withUnsafeMutableBufferPointer { outputPointer in
                var data = SRC_DATA(
                    data_in: inputPointer.baseAddress,
                    data_out: outputPointer.baseAddress,
                    input_frames: input.frameCount,
                    output_frames: estimatedFrames,
                    input_frames_used: 0,
                    output_frames_gen: 0,
                    end_of_input: 1,
                    src_ratio: ratio
                )
                let error = src_simple(&data, converter, Int32(channels))
                return (error: error, outputFrames: Int(data.output_frames_gen))
            }
        }
        guard result.error == 0 else {
            throw SampleRateConverterError.conversionFailed(String(cString: src_strerror(result.error)))
        }

        let outputFrames = result.outputFrames
        let output = PCMBuffer(
            format: AudioFormat(sampleRate: destinationRate, channelCount: channels),
            capacity: outputFrames
        )
        for frame in 0..<outputFrames {
            for channel in 0..<channels {
                output.channel(channel)[frame] = interleavedOutput[frame * channels + channel]
            }
        }
        return output
    }
}

public enum SampleRateConverterError: Error, Sendable, Equatable {
    case channelCountMismatch(expected: Int, actual: Int)
    case sampleRateMismatch(expected: Double, actual: Double)
    case conversionFailed(String)
}


