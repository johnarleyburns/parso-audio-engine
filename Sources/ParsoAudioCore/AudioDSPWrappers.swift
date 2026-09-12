import Foundation
import CParsoDSP

// MARK: - RT DSP wrappers (thin Swift over CParsoDSP; also usable offline for tests/reuse)

/// Independent or coupled time/pitch. `.varispeed` couples pitch to tempo
/// (scratch/pitch-bend); `.keyLock` is the Signalsmith phase vocoder.
public final class TimePitch: @unchecked Sendable {
    public enum Mode: Sendable { case varispeed, keyLock }
    // Created and destroyed on the control side; the C kernel owns all mutable
    // DSP state and receives only POD values and PCM pointers while rendering.
    private let handle: OpaquePointer
    private let channels: Int

    public var mode: Mode = .varispeed {
        didSet {
            pd_tp_set_mode(handle, mode == .keyLock ? PD_TP_KEYLOCK : PD_TP_VARISPEED)
        }
    }
    public var tempoRatio: Double = 1.0 { didSet { pd_tp_set_time_ratio(handle, tempoRatio) } }
    public var pitchSemitones: Double = 0.0 {
        didSet { pd_tp_set_pitch_semitones(handle, pitchSemitones) }
    }

    public init(sampleRate: Double, channels: Int, maxBlock: Int) {
        precondition(sampleRate.isFinite && sampleRate > 0, "sample rate must be positive")
        precondition(channels > 0, "channel count must be positive")
        precondition(maxBlock > 0, "max block must be positive")
        guard let handle = pd_tp_create(sampleRate, Int32(channels), Int32(maxBlock)) else {
            preconditionFailure("could not create time/pitch processor")
        }
        self.handle = handle
        self.channels = channels
    }

    deinit { pd_tp_destroy(handle) }

    public func reset() { pd_tp_reset(handle) }

    /// Offline convenience: process a whole buffer at the current settings.
    public func process(_ input: PCMBuffer) -> PCMBuffer {
        precondition(input.channelCount == channels, "channel count mismatch")
        precondition(input.frameCount <= Int(Int32.max), "input is too large")

        let ratio: Double
        switch mode {
        case .varispeed:
            ratio = min(2.0, max(0.06, tempoRatio)) * pow(2.0, pitchSemitones / 12.0)
        case .keyLock:
            ratio = min(2.0, max(0.06, tempoRatio))
        }
        let outputFrames = input.frameCount == 0
            ? 0
            : min(Int(Int32.max), max(1, Int(ceil(Double(input.frameCount) / ratio))))
        let output = PCMBuffer(format: input.format, capacity: outputFrames)
        guard outputFrames > 0 else { return output }

        var written: Int32 = 0
        input.withUnsafeChannels { inputChannels, frames in
            output.withUnsafeChannels { outputChannels, destinationFrames in
                inputChannels.withMemoryRebound(to: UnsafePointer<Float>?.self, capacity: channels) {
                    inputPointers in
                    outputChannels.withMemoryRebound(
                        to: UnsafeMutablePointer<Float>?.self, capacity: channels
                    ) { outputPointers in
                        written = pd_tp_process(
                            handle, UnsafePointer(inputPointers), Int32(frames),
                            UnsafePointer(outputPointers), Int32(destinationFrames)
                        )
                    }
                }
            }
        }

        // The offline API sizes its output from the requested ratio, but a C
        // kernel may return fewer frames for a partial/streaming call.
        if Int(written) == outputFrames { return output }
        let trimmed = PCMBuffer(format: input.format, capacity: max(0, Int(written)))
        for channel in 0..<channels {
            let source = output.channel(channel)
            let destination = trimmed.channel(channel)
            for frame in 0..<trimmed.frameCount { destination[frame] = source[frame] }
        }
        return trimmed
    }
}

/// 3-band full-kill isolator EQ (Pioneer-style). `-Float.infinity` == kill.
public final class Isolator3Band: @unchecked Sendable {
    // The handle is created/destroyed by the control-side object. Processing only
    // exchanges PCM pointers with the allocation-free C kernel.
    private let handle: OpaquePointer

    public init(sampleRate: Double, crossoverLow: Double = 200, crossoverHigh: Double = 2000) {
        guard let handle = pd_eq3_create(sampleRate, crossoverLow, crossoverHigh) else {
            preconditionFailure("invalid isolator EQ configuration")
        }
        self.handle = handle
    }

    deinit { pd_eq3_destroy(handle) }

    public func set(lowDB: Float, midDB: Float, highDB: Float) {
        pd_eq3_set(handle, lowDB, midDB, highDB)
    }

    public func processInPlace(_ buffer: PCMBuffer) {
        buffer.withUnsafeChannels { channels, frames in
            guard frames > 0, frames <= Int(Int32.max) else { return }
            for channel in 0..<buffer.channelCount {
                pd_eq3_process(handle, channels[channel], channels[channel], Int32(frames))
            }
        }
    }
}

/// Sweepable resonant filter (Color-FX default). `knob` -1..0 = LPF, 0..+1 = HPF.
public final class SweepFilter: @unchecked Sendable {
    private let handle: OpaquePointer

    public init(sampleRate: Double) {
        guard let handle = pd_filter_create(sampleRate) else {
            preconditionFailure("invalid sweep filter sample rate")
        }
        self.handle = handle
    }

    deinit { pd_filter_destroy(handle) }

    public func set(knob: Float, resonance: Float = 0.3) {
        pd_filter_set(handle, knob, resonance)
    }

    public func processInPlace(_ buffer: PCMBuffer) {
        buffer.withUnsafeChannels { channels, frames in
            guard frames > 0, frames <= Int(Int32.max) else { return }
            for channel in 0..<buffer.channelCount {
                pd_filter_process(handle, channels[channel], channels[channel], Int32(frames))
            }
        }
    }
}

/// Fractional feedback delay/echo. Processing is allocation-free after initialization.
public final class Delay: @unchecked Sendable {
    private let handle: OpaquePointer

    public init(sampleRate: Double, maxSeconds: Double = 2.0) {
        guard let handle = pd_delay_create(sampleRate, maxSeconds) else {
            preconditionFailure("invalid delay configuration")
        }
        self.handle = handle
    }

    deinit { pd_delay_destroy(handle) }

    public func set(timeSeconds: Double, feedback: Float, mix: Float) {
        pd_delay_set(handle, timeSeconds, feedback, mix)
    }

    public func processInPlace(_ buffer: PCMBuffer) {
        buffer.withUnsafeChannels { channels, frames in
            guard frames > 0, frames <= Int(Int32.max) else { return }
            for channel in 0..<buffer.channelCount {
                pd_delay_process(handle, channels[channel], channels[channel], Int32(frames))
            }
        }
    }
}

/// Freeverb-topology reverb. Delay-line storage is allocated during init;
/// processing is allocation-free and suitable for the real-time graph.
public final class Reverb: @unchecked Sendable {
    private let handle: OpaquePointer

    public init(sampleRate: Double) {
        guard let handle = pd_reverb_create(sampleRate) else {
            preconditionFailure("invalid reverb sample rate")
        }
        self.handle = handle
    }

    deinit { pd_reverb_destroy(handle) }

    public func set(room: Float, damp: Float, width: Float, mix: Float) {
        pd_reverb_set(handle, room, damp, width, mix)
    }

    public func processInPlace(_ buffer: PCMBuffer) {
        buffer.withUnsafeChannels { channels, frames in
            guard frames > 0, frames <= Int(Int32.max) else { return }
            if buffer.channelCount == 1 {
                pd_reverb_process(handle, channels[0], channels[0], channels[0], channels[0], Int32(frames))
            } else {
                pd_reverb_process(handle, channels[0], channels[1], channels[0], channels[1], Int32(frames))
            }
        }
    }
}

/// Stereo look-ahead brick-wall limiter with a 75 ms release.
public final class Limiter: @unchecked Sendable {
    private let handle: OpaquePointer

    public init(sampleRate: Double, ceilingDB: Float = -0.3) {
        guard let handle = pd_limiter_create(sampleRate, ceilingDB) else {
            preconditionFailure("invalid limiter configuration")
        }
        self.handle = handle
    }

    deinit { pd_limiter_destroy(handle) }

    public func processInPlace(_ buffer: PCMBuffer) {
        buffer.withUnsafeChannels { channels, frames in
            guard frames > 0, frames <= Int(Int32.max) else { return }
            if buffer.channelCount == 1 {
                pd_limiter_process(handle, channels[0], channels[0], Int32(frames))
            } else {
                pd_limiter_process(handle, channels[0], channels[1], Int32(frames))
            }
        }
    }
}

