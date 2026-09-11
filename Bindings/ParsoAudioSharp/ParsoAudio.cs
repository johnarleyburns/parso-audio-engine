using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace ParsoAudioSharp;

/// <summary>Reports a non-zero status returned by the Parso native API.</summary>
public sealed class ParsoException : Exception
{
    /// <summary>Creates an exception for a failed native operation.</summary>
    /// <param name="status">The native status code.</param>
    /// <param name="operation">A human-readable description of the operation.</param>
    public ParsoException(int status, string operation)
        : base($"{operation} failed with native status {status}.")
    {
        Status = status;
    }

    /// <summary>Gets the native status code returned by the failed operation.</summary>
    public int Status { get; }
}

/// <summary>Identifies a byte-oriented codec exposed by the native API.</summary>
public enum AudioCodec : uint
{
    /// <summary>RIFF/WAVE PCM.</summary>
    Wav = 1,
    /// <summary>FLAC.</summary>
    Flac = 2,
    /// <summary>Xiph Ogg Vorbis.</summary>
    OggVorbis = 3,
    /// <summary>Ogg Opus.</summary>
    Opus = 4,
    /// <summary>MP3.</summary>
    Mp3 = 5,
    /// <summary>ADTS AAC.</summary>
    Aac = 6
}

/// <summary>Describes the byte containers available in a native build.</summary>
[Flags]
public enum ContainerCapability : ulong
{
    /// <summary>RIFF/WAVE.</summary>
    Wav = 1,
    /// <summary>FLAC.</summary>
    Flac = 2,
    /// <summary>Xiph Ogg Vorbis.</summary>
    OggVorbis = 4,
    /// <summary>Ogg Opus.</summary>
    Opus = 8,
    /// <summary>MP3.</summary>
    Mp3 = 16,
    /// <summary>ADTS AAC.</summary>
    Aac = 32,
    /// <summary>Apple Lossless.</summary>
    Alac = 64,
    /// <summary>AIFF.</summary>
    Aiff = 128,
    /// <summary>CAF.</summary>
    Caf = 256
}

/// <summary>Stable transport and effect command selectors from the public C ABI.</summary>
public enum EngineCommand : uint
{
    /// <summary>Start transport.</summary>
    Play = 0,
    /// <summary>Stop transport.</summary>
    Pause = 1,
    /// <summary>Set the primary cue.</summary>
    SetCue = 2,
    /// <summary>Jump to the primary cue.</summary>
    JumpCue = 3,
    /// <summary>Set a hot cue slot.</summary>
    HotCueSet = 4,
    /// <summary>Jump to a hot cue slot.</summary>
    HotCueJump = 5,
    /// <summary>Delete a hot cue slot.</summary>
    HotCueDelete = 6,
    /// <summary>Set loop-in.</summary>
    LoopIn = 7,
    /// <summary>Set loop-out.</summary>
    LoopOut = 8,
    /// <summary>Exit or re-enter an available loop.</summary>
    ReloopExit = 9,
    /// <summary>Create a beat loop.</summary>
    BeatLoop = 10,
    /// <summary>Scale the active loop.</summary>
    LoopScale = 11,
    /// <summary>Move the active loop.</summary>
    LoopMove = 12,
    /// <summary>Set loop bounds explicitly.</summary>
    SetLoop = 13,
    /// <summary>Set loop active state.</summary>
    SetLoopActive = 14,
    /// <summary>Jump by beats.</summary>
    BeatJump = 15,
    /// <summary>Apply a synchronized position.</summary>
    Sync = 16,
    /// <summary>Set global master state.</summary>
    SetMaster = 17,
    /// <summary>Set key-lock state.</summary>
    SetKeylock = 18,
    /// <summary>Set slip state.</summary>
    SetSlip = 19,
    /// <summary>Begin jog touch.</summary>
    JogTouch = 20,
    /// <summary>Move the jog position.</summary>
    JogMove = 21,
    /// <summary>End jog touch.</summary>
    JogRelease = 22,
    /// <summary>Seek to an absolute position.</summary>
    Seek = 23,
    /// <summary>Clear synchronization.</summary>
    Unsync = 24,
    /// <summary>Arm stems.</summary>
    StemArm = 25,
    /// <summary>Set stem gain.</summary>
    StemGain = 26,
    /// <summary>Set stem mute.</summary>
    StemMute = 27,
    /// <summary>Set stem solo.</summary>
    StemSolo = 28,
    /// <summary>Set reverse state.</summary>
    SetReverse = 29,
    /// <summary>Set vinyl speed timing.</summary>
    VinylSpeed = 30,
    /// <summary>Set echo state.</summary>
    EchoSet = 31,
    /// <summary>Set Color FX kind.</summary>
    ColorFxKind = 32,
    /// <summary>Set Beat FX kind.</summary>
    BeatFxKind = 33,
    /// <summary>Set Beat FX on/off state.</summary>
    BeatFxOnOff = 34,
    /// <summary>Release Beat FX.</summary>
    BeatFxRelease = 35,
    /// <summary>Trigger a sampler slot.</summary>
    SamplerTrigger = 36,
    /// <summary>Stop a sampler slot.</summary>
    SamplerStop = 37,
    /// <summary>Configure a sampler slot.</summary>
    SamplerConfig = 38,
    /// <summary>Load a deck source.</summary>
    Load = 39
}

/// <summary>Identifies a notification drained from the native render event ring.</summary>
public enum EngineEventType : uint
{
    /// <summary>Playhead position changed.</summary>
    Playhead = 0,
    /// <summary>Deck peak telemetry.</summary>
    Peak = 1,
    /// <summary>Transport state changed.</summary>
    State = 2,
    /// <summary>A deck reached the end of its source.</summary>
    EndOfTrack = 3,
    /// <summary>A resident buffer can be released.</summary>
    BufferReleased = 4
}

/// <summary>One copied notification from the native render event ring.</summary>
public readonly record struct EngineEvent(
    EngineEventType Type, int Deck, long Frame, float F0, float F1);

/// <summary>Options shared by the native offline codec services.</summary>
public readonly record struct CodecOptions
{
    /// <summary>Gets the FLAC compression level, from zero through eight.</summary>
    public uint CompressionLevel { get; init; }

    /// <summary>Gets the target bitrate in kilobits per second.</summary>
    public uint BitrateKbps { get; init; }

    /// <summary>Gets the integer output depth for FLAC or WAV.</summary>
    public uint BitsPerSample { get; init; }

    /// <summary>Gets whether WAV output is IEEE float rather than integer PCM.</summary>
    public bool WavIsFloat { get; init; }

    /// <summary>Gets the Glint quality mode, from zero through two.</summary>
    public uint Quality { get; init; }

    /// <summary>Gets the VBR quality, from zero through nine, or null for CBR.</summary>
    public uint? VbrQuality { get; init; }

    /// <summary>Gets the native defaults used by the public codec helpers.</summary>
    public static CodecOptions Default => new()
    {
        CompressionLevel = 5,
        BitrateKbps = 192,
        BitsPerSample = 16,
        VbrQuality = null
    };
}

/// <summary>Reports native codec and PCM capabilities.</summary>
public readonly record struct CodecCapabilities(
    ContainerCapability DecodeContainers,
    ContainerCapability EncodeContainers,
    ulong ReadPcmFormats,
    ulong WritePcmFormats,
    uint MaxChannels,
    uint MaxSampleRateHz,
    ulong OfflineServices);

/// <summary>Owns managed interleaved float32 PCM copied from a native read.</summary>
public readonly record struct DecodedPcm(
    float[] Samples,
    ulong Frames,
    uint ChannelCount,
    uint SampleRateHz);

/// <summary>Deterministic portable duration, level, and tempo summary.</summary>
public readonly record struct AnalysisResult(
    double DurationSeconds, double Rms, double Peak, double Bpm, double BpmConfidence);

/// <summary>Portable HPCP/Krumhansl-Schmuckler key estimate.</summary>
public readonly record struct KeyResult(
    uint TonicPitchClass, bool IsMinor, uint CamelotNumber, string CamelotLetter,
    double Confidence);

/// <summary>One deterministic energy/novelty structure boundary.</summary>
public readonly record struct StructureSection(
    double StartSeconds, uint Kind, uint Bar, double Energy, double Confidence);

/// <summary>Owned interleaved float32 PCM returned by native sample-rate conversion.</summary>
public readonly record struct ResampledPcm(
    float[] Samples, ulong Frames, uint ChannelCount, uint SampleRateHz);

/// <summary>EBU R128 loudness values measured by the native offline service.</summary>
public readonly record struct LoudnessResult(
    double IntegratedLufs, double TruePeakDbtp, double GainToTargetDb, double LoudnessRangeLu);

/// <summary>Provides ownership-safe managed access to native offline codec services.</summary>
public static unsafe class CodecServices
{
    /// <summary>Reads the capabilities reported by the loaded native library.</summary>
    public static CodecCapabilities GetCapabilities()
    {
        var native = new NativeMethods.Capabilities
        {
            Size = (uint)Marshal.SizeOf<NativeMethods.Capabilities>(),
            AbiVersion = NativeMethods.AbiVersion
        };
        var status = NativeMethods.CapabilitiesInit(ref native);
        ThrowIfFailed(status, "capability initialization");
        status = NativeMethods.CapabilitiesGet(ref native);
        ThrowIfFailed(status, "capability query");
        return new CodecCapabilities(
            (ContainerCapability)native.DecodeContainers,
            (ContainerCapability)native.EncodeContainers,
            native.ReadPcmFormats,
            native.WritePcmFormats,
            native.MaxChannels,
            native.MaxSampleRateHz,
            native.OfflineServices);
    }

    /// <summary>Encodes borrowed interleaved float32 PCM and returns an owned managed byte array.</summary>
    /// <param name="samples">Interleaved samples. The native call borrows this span only during the call.</param>
    /// <param name="sampleRateHz">The PCM sample rate.</param>
    /// <param name="channelCount">The number of interleaved channels, one or two.</param>
    /// <param name="codec">The target codec.</param>
    /// <param name="options">Optional codec settings.</param>
    public static byte[] Encode(
        ReadOnlySpan<float> samples, uint sampleRateHz, uint channelCount,
        AudioCodec codec, CodecOptions options = default)
    {
        if (samples.IsEmpty) throw new ArgumentException("Samples cannot be empty.", nameof(samples));
        if (channelCount is < 1 or > 2 || sampleRateHz == 0 || samples.Length % channelCount != 0)
            throw new ArgumentException("PCM format must have one or two channels and a valid sample rate.");

        var nativeOptions = ToNativeOptions(options);
        var input = new NativeMethods.PcmBuffer
        {
            Size = (uint)Marshal.SizeOf<NativeMethods.PcmBuffer>(),
            AbiVersion = NativeMethods.AbiVersion,
            Frames = checked((ulong)(samples.Length / (int)channelCount)),
            ChannelCount = channelCount,
            SampleRateHz = sampleRateHz
        };
        var output = new NativeMethods.Bytes();
        var status = NativeMethods.BytesInit(ref output);
        ThrowIfFailed(status, "byte-buffer initialization");
        try
        {
            fixed (float* samplePointer = samples)
            {
                input.Samples = (nint)samplePointer;
                status = NativeMethods.CodecWrite(ref input, (uint)codec,
                    ref nativeOptions, ref output);
            }
            ThrowIfFailed(status, "codec encoding");
            if (output.SizeBytes > int.MaxValue)
                throw new ParsoException(NativeMethods.InvalidArgument, "codec encoding");
            var managed = new byte[(int)output.SizeBytes];
            if (managed.Length != 0) Marshal.Copy(output.Data, managed, 0, managed.Length);
            return managed;
        }
        finally
        {
            NativeMethods.BytesRelease(ref output);
        }
    }

    /// <summary>Decodes borrowed codec bytes and returns managed interleaved float32 PCM.</summary>
    /// <param name="encoded">Complete bytes for the selected codec.</param>
    /// <param name="codec">The source codec.</param>
    /// <param name="options">Optional codec settings.</param>
    public static DecodedPcm Decode(
        ReadOnlySpan<byte> encoded, AudioCodec codec, CodecOptions options = default)
    {
        if (encoded.IsEmpty) throw new ArgumentException("Encoded data cannot be empty.", nameof(encoded));

        var nativeOptions = ToNativeOptions(options);
        var output = new NativeMethods.PcmBuffer();
        var status = NativeMethods.PcmBufferInit(ref output);
        ThrowIfFailed(status, "PCM-buffer initialization");
        try
        {
            fixed (byte* dataPointer = encoded)
            {
                status = NativeMethods.CodecRead((nint)dataPointer, (ulong)encoded.Length,
                    (uint)codec, ref nativeOptions, ref output);
            }
            ThrowIfFailed(status, "codec decoding");
            var sampleCount = checked((int)(output.Frames * output.ChannelCount));
            var samples = new float[sampleCount];
            if (sampleCount != 0) Marshal.Copy(output.Samples, samples, 0, sampleCount);
            return new DecodedPcm(samples, output.Frames, output.ChannelCount, output.SampleRateHz);
        }
        finally
        {
            NativeMethods.PcmBufferRelease(ref output);
        }
    }

    /// <summary>Measures levels and an energy-envelope tempo estimate on borrowed PCM.</summary>
    public static AnalysisResult Analyze(ReadOnlySpan<float> samples, uint sampleRateHz,
                                         uint channelCount, uint hopFrames = 256,
                                         uint minBpm = 60, uint maxBpm = 190)
    {
        if (samples.IsEmpty) throw new ArgumentException("Samples cannot be empty.", nameof(samples));
        if (channelCount is < 1 or > 2 || sampleRateHz == 0 || samples.Length % channelCount != 0)
            throw new ArgumentException("PCM format must have one or two channels and a valid sample rate.");
        if (hopFrames == 0 || minBpm == 0 || maxBpm <= minBpm)
            throw new ArgumentOutOfRangeException(nameof(hopFrames));
        var options = new NativeMethods.AnalysisOptions
        {
            Size = (uint)Marshal.SizeOf<NativeMethods.AnalysisOptions>(),
            AbiVersion = NativeMethods.AbiVersion
        };
        var status = NativeMethods.AnalysisOptionsInit(ref options);
        ThrowIfFailed(status, "analysis-options initialization");
        options.HopFrames = hopFrames;
        options.MinBpm = minBpm;
        options.MaxBpm = maxBpm;
        var result = new NativeMethods.AnalysisResult
        {
            Size = (uint)Marshal.SizeOf<NativeMethods.AnalysisResult>(),
            AbiVersion = NativeMethods.AbiVersion
        };
        status = NativeMethods.AnalysisResultInit(ref result);
        ThrowIfFailed(status, "analysis-result initialization");
        var input = new NativeMethods.PcmBuffer
        {
            Size = (uint)Marshal.SizeOf<NativeMethods.PcmBuffer>(),
            AbiVersion = NativeMethods.AbiVersion,
            Frames = checked((ulong)(samples.Length / (int)channelCount)),
            ChannelCount = channelCount,
            SampleRateHz = sampleRateHz
        };
        fixed (float* samplePointer = samples)
        {
            input.Samples = (nint)samplePointer;
            status = NativeMethods.AnalysisMeasure(ref input, ref options, ref result);
        }
        ThrowIfFailed(status, "analysis measurement");
        return new AnalysisResult(result.DurationSeconds, result.Rms, result.Peak,
            result.Bpm, result.BpmConfidence);
    }

    /// <summary>Estimates pitch class and mode on borrowed PCM.</summary>
    public static KeyResult EstimateKey(ReadOnlySpan<float> samples, uint sampleRateHz,
                                        uint channelCount, uint windowFrames = 8192,
                                        uint hopFrames = 4096, uint minMidi = 36,
                                        uint maxMidi = 96)
    {
        if (samples.IsEmpty) throw new ArgumentException("Samples cannot be empty.", nameof(samples));
        if (channelCount is < 1 or > 2 || sampleRateHz == 0 || samples.Length % channelCount != 0)
            throw new ArgumentException("PCM format must have one or two channels and a valid sample rate.");
        if (windowFrames == 0 || hopFrames == 0 || minMidi > maxMidi || maxMidi > 127)
            throw new ArgumentOutOfRangeException(nameof(windowFrames));
        var options = new NativeMethods.KeyOptions
        {
            Size = (uint)Marshal.SizeOf<NativeMethods.KeyOptions>(),
            AbiVersion = NativeMethods.AbiVersion
        };
        var status = NativeMethods.KeyOptionsInit(ref options);
        ThrowIfFailed(status, "key-options initialization");
        options.WindowFrames = windowFrames;
        options.HopFrames = hopFrames;
        options.MinMidi = minMidi;
        options.MaxMidi = maxMidi;
        var result = new NativeMethods.KeyResult
        {
            Size = (uint)Marshal.SizeOf<NativeMethods.KeyResult>(),
            AbiVersion = NativeMethods.AbiVersion
        };
        status = NativeMethods.KeyResultInit(ref result);
        ThrowIfFailed(status, "key-result initialization");
        var input = new NativeMethods.PcmBuffer
        {
            Size = (uint)Marshal.SizeOf<NativeMethods.PcmBuffer>(),
            AbiVersion = NativeMethods.AbiVersion,
            Frames = checked((ulong)(samples.Length / (int)channelCount)),
            ChannelCount = channelCount,
            SampleRateHz = sampleRateHz
        };
        fixed (float* samplePointer = samples)
        {
            input.Samples = (nint)samplePointer;
            status = NativeMethods.KeyMeasure(ref input, ref options, ref result);
        }
        ThrowIfFailed(status, "key measurement");
        return new KeyResult(result.TonicPitchClass, result.IsMinor != 0,
            result.CamelotNumber, result.CamelotLetter == 1 ? "A" : "B", result.Confidence);
    }

    /// <summary>Segments borrowed PCM into bounded energy/novelty sections.</summary>
    public static unsafe StructureSection[] Structure(ReadOnlySpan<float> samples, uint sampleRateHz,
                                                       uint channelCount, double bpm = 120.0,
                                                       uint maxSections = 256)
    {
        if (samples.IsEmpty) throw new ArgumentException("Samples cannot be empty.", nameof(samples));
        if (channelCount is < 1 or > 2 || sampleRateHz == 0 || samples.Length % channelCount != 0)
            throw new ArgumentException("PCM format must have one or two channels and a valid sample rate.");
        if (!double.IsFinite(bpm) || bpm is < 30.0 or > 300.0 || maxSections is 0 or > 4096)
            throw new ArgumentOutOfRangeException(nameof(bpm));
        var options = new NativeMethods.StructureOptions
        {
            Size = (uint)Marshal.SizeOf<NativeMethods.StructureOptions>(),
            AbiVersion = NativeMethods.AbiVersion
        };
        var status = NativeMethods.StructureOptionsInit(ref options);
        ThrowIfFailed(status, "structure-options initialization");
        options.Bpm = bpm;
        options.MaxSections = maxSections;
        var result = new NativeMethods.StructureSection[maxSections];
        var input = new NativeMethods.PcmBuffer
        {
            Size = (uint)Marshal.SizeOf<NativeMethods.PcmBuffer>(),
            AbiVersion = NativeMethods.AbiVersion,
            Frames = checked((ulong)(samples.Length / (int)channelCount)),
            ChannelCount = channelCount,
            SampleRateHz = sampleRateHz
        };
        uint count = 0;
        fixed (float* samplePointer = samples)
        fixed (NativeMethods.StructureSection* resultPointer = result)
        {
            input.Samples = (nint)samplePointer;
            status = NativeMethods.StructureMeasure(ref input, ref options, resultPointer,
                maxSections, ref count);
        }
        ThrowIfFailed(status, "structure measurement");
        var managed = new StructureSection[count];
        for (var index = 0; index < count; index++)
        {
            var item = result[index];
            managed[index] = new StructureSection(item.StartSeconds, item.Kind, item.Bar,
                item.Energy, item.Confidence);
        }
        return managed;
    }

    /// <summary>Generates caller-sized mono min/max waveform envelopes.</summary>
    public static unsafe (float[] Min, float[] Max) Waveform(
        ReadOnlySpan<float> samples, uint sampleRateHz, uint channelCount, uint bucketCount)
    {
        if (samples.IsEmpty) throw new ArgumentException("Samples cannot be empty.", nameof(samples));
        if (channelCount is < 1 or > 2 || sampleRateHz == 0 || samples.Length % channelCount != 0)
            throw new ArgumentException("PCM format must have one or two channels and a valid sample rate.");
        if (bucketCount == 0 || bucketCount > 1_000_000 || bucketCount > int.MaxValue)
            throw new ArgumentOutOfRangeException(nameof(bucketCount));
        var minimum = new float[(int)bucketCount];
        var maximum = new float[(int)bucketCount];
        var input = new NativeMethods.PcmBuffer
        {
            Size = (uint)Marshal.SizeOf<NativeMethods.PcmBuffer>(),
            AbiVersion = NativeMethods.AbiVersion,
            Frames = checked((ulong)(samples.Length / (int)channelCount)),
            ChannelCount = channelCount,
            SampleRateHz = sampleRateHz
        };
        fixed (float* samplePointer = samples)
        fixed (float* minimumPointer = minimum)
        fixed (float* maximumPointer = maximum)
        {
            input.Samples = (nint)samplePointer;
            var status = NativeMethods.WaveformGenerate(ref input, bucketCount,
                minimumPointer, maximumPointer);
            ThrowIfFailed(status, "waveform generation");
        }
        return (minimum, maximum);
    }

    /// <summary>Converts borrowed interleaved float32 PCM to a new sample rate.</summary>
    public static unsafe ResampledPcm ConvertSampleRate(
        ReadOnlySpan<float> samples, uint sourceSampleRateHz, uint destinationSampleRateHz,
        uint channelCount, uint quality = 0)
    {
        ValidatePcm(samples, sourceSampleRateHz, channelCount);
        if (destinationSampleRateHz == 0 || quality > 2)
            throw new ArgumentOutOfRangeException(nameof(destinationSampleRateHz));
        var options = new NativeMethods.SrcOptions
        {
            Size = (uint)Marshal.SizeOf<NativeMethods.SrcOptions>(),
            AbiVersion = NativeMethods.AbiVersion
        };
        var status = NativeMethods.SrcOptionsInit(ref options);
        ThrowIfFailed(status, "SRC-options initialization");
        options.SourceSampleRateHz = sourceSampleRateHz;
        options.DestinationSampleRateHz = destinationSampleRateHz;
        options.ChannelCount = channelCount;
        options.Quality = quality;
        var input = CreateInput(samples, sourceSampleRateHz, channelCount);
        var output = new NativeMethods.PcmBuffer();
        status = NativeMethods.PcmBufferInit(ref output);
        ThrowIfFailed(status, "SRC output initialization");
        try
        {
            fixed (float* samplePointer = samples)
            {
                input.Samples = (nint)samplePointer;
                status = NativeMethods.SrcConvert(ref input, ref options, ref output);
            }
            ThrowIfFailed(status, "sample-rate conversion");
            return CopyPcm(output);
        }
        finally
        {
            NativeMethods.PcmBufferRelease(ref output);
        }
    }

    /// <summary>Measures EBU R128 loudness on borrowed interleaved float32 PCM.</summary>
    public static unsafe LoudnessResult MeasureLoudness(
        ReadOnlySpan<float> samples, uint sampleRateHz, uint channelCount,
        double targetLufs = -14.0)
    {
        ValidatePcm(samples, sampleRateHz, channelCount);
        if (!double.IsFinite(targetLufs)) throw new ArgumentOutOfRangeException(nameof(targetLufs));
        var options = new NativeMethods.LoudnessOptions
        {
            Size = (uint)Marshal.SizeOf<NativeMethods.LoudnessOptions>(),
            AbiVersion = NativeMethods.AbiVersion
        };
        var status = NativeMethods.LoudnessOptionsInit(ref options);
        ThrowIfFailed(status, "loudness-options initialization");
        options.TargetLufs = targetLufs;
        var result = new NativeMethods.LoudnessResult
        {
            Size = (uint)Marshal.SizeOf<NativeMethods.LoudnessResult>(),
            AbiVersion = NativeMethods.AbiVersion
        };
        status = NativeMethods.LoudnessResultInit(ref result);
        ThrowIfFailed(status, "loudness-result initialization");
        var input = CreateInput(samples, sampleRateHz, channelCount);
        fixed (float* samplePointer = samples)
        {
            input.Samples = (nint)samplePointer;
            status = NativeMethods.LoudnessMeasure(ref input, ref options, ref result);
        }
        ThrowIfFailed(status, "loudness measurement");
        return new LoudnessResult(result.IntegratedLufs, result.TruePeakDbtp,
            result.GainToTargetDb, result.LoudnessRangeLu);
    }

    private static void ValidatePcm(ReadOnlySpan<float> samples, uint sampleRateHz, uint channelCount)
    {
        if (samples.IsEmpty) throw new ArgumentException("Samples cannot be empty.", nameof(samples));
        if (channelCount is < 1 or > 2 || sampleRateHz == 0 || samples.Length % channelCount != 0)
            throw new ArgumentException("PCM format must have one or two channels and a valid sample rate.");
    }

    private static NativeMethods.PcmBuffer CreateInput(
        ReadOnlySpan<float> samples, uint sampleRateHz, uint channelCount) => new()
    {
        Size = (uint)Marshal.SizeOf<NativeMethods.PcmBuffer>(),
        AbiVersion = NativeMethods.AbiVersion,
        Frames = checked((ulong)(samples.Length / (int)channelCount)),
        ChannelCount = channelCount,
        SampleRateHz = sampleRateHz
    };

    private static ResampledPcm CopyPcm(NativeMethods.PcmBuffer output)
    {
        var sampleCount = checked((int)(output.Frames * output.ChannelCount));
        var samples = new float[sampleCount];
        if (sampleCount != 0) Marshal.Copy(output.Samples, samples, 0, sampleCount);
        return new ResampledPcm(samples, output.Frames, output.ChannelCount, output.SampleRateHz);
    }

    private static NativeMethods.CodecOptions ToNativeOptions(CodecOptions options)
    {
        var defaults = CodecOptions.Default;
        return new NativeMethods.CodecOptions
        {
            Size = (uint)Marshal.SizeOf<NativeMethods.CodecOptions>(),
            AbiVersion = NativeMethods.AbiVersion,
            CompressionLevel = options.CompressionLevel == 0 ? defaults.CompressionLevel : options.CompressionLevel,
            BitrateKbps = options.BitrateKbps == 0 ? defaults.BitrateKbps : options.BitrateKbps,
            BitsPerSample = options.BitsPerSample == 0 ? defaults.BitsPerSample : options.BitsPerSample,
            WavIsFloat = options.WavIsFloat ? 1u : 0u,
            Quality = options.Quality,
            VbrQuality = options.VbrQuality ?? uint.MaxValue
        };
    }

    private static void ThrowIfFailed(int status, string operation)
    {
        if (status != NativeMethods.Ok) throw new ParsoException(status, operation);
    }
}

/// <summary>Provides counters and topology information for a native engine.</summary>
public readonly record struct EngineStats
{
    /// <summary>Creates an engine statistics snapshot.</summary>
    /// <param name="masterFrame">The number of master frames rendered.</param>
    /// <param name="starvedFrames">The number of frames rendered without sufficient source data.</param>
    /// <param name="deckCount">The number of decks allocated by the engine.</param>
    public EngineStats(ulong masterFrame, ulong starvedFrames, uint deckCount)
    {
        MasterFrame = masterFrame;
        StarvedFrames = starvedFrames;
        DeckCount = deckCount;
    }

    /// <summary>Gets the number of master frames rendered.</summary>
    public ulong MasterFrame { get; }

    /// <summary>Gets the number of frames rendered without sufficient source data.</summary>
    public ulong StarvedFrames { get; }

    /// <summary>Gets the number of decks allocated by the engine.</summary>
    public uint DeckCount { get; }
}

/// <summary>Owns a Parso native engine and exposes its basic control and render operations.</summary>
public sealed class Engine : IDisposable
{
    private readonly NativeEngineHandle handle;
    private readonly uint maxFrames;
    private readonly uint deckCount;
    private readonly Dictionary<uint, PinnedDeckBuffer> deckBuffers = new();

    private Engine(NativeEngineHandle handle, uint maxFrames, uint deckCount)
    {
        this.handle = handle;
        this.maxFrames = maxFrames;
        this.deckCount = deckCount;
    }

    /// <summary>Creates a native engine with the requested render configuration.</summary>
    /// <param name="sampleRateHz">The engine sample rate in hertz.</param>
    /// <param name="maxFrames">The maximum number of frames accepted by one render call.</param>
    /// <param name="deckCount">The number of decks to allocate.</param>
    /// <returns>A disposable managed handle for the native engine.</returns>
    public static Engine Create(uint sampleRateHz = 48_000, uint maxFrames = 512, uint deckCount = 2)
    {
        var options = NativeMethods.DefaultOptions(sampleRateHz, maxFrames, deckCount);
        var status = NativeMethods.Create(ref options, out var nativeHandle);
        ThrowIfFailed(status, "engine creation");
        return new Engine(new NativeEngineHandle(nativeHandle), maxFrames, deckCount);
    }

    /// <summary>Sets the master output level used by subsequent renders.</summary>
    /// <param name="level">The linear master gain.</param>
    public void SetMasterLevel(float level)
    {
        var control = NativeMethods.DefaultControl();
        control.MasterLevel = level;
        var status = NativeMethods.SetControl(handle, ref control);
        ThrowIfFailed(status, "setting control");
    }

    /// <summary>Sets the A/B crossfader position for subsequent renders.</summary>
    /// <param name="position">A bounded position from -1 (A) to +1 (B).</param>
    public unsafe void SetCrossfader(float position)
    {
        if (!float.IsFinite(position) || position < -1.0f || position > 1.0f)
            throw new ArgumentOutOfRangeException(nameof(position));
        if (deckCount < 2) throw new InvalidOperationException("crossfader requires two decks");
        var control = NativeMethods.DefaultControl();
        control.Crossfader = position;
        control.XfadeAssign[0] = 0.0f;
        control.XfadeAssign[1] = 1.0f;
        control.Fader[0] = 1.0f;
        control.Fader[1] = 1.0f;
        control.Trim[0] = 1.0f;
        control.Trim[1] = 1.0f;
        var status = NativeMethods.SetControl(handle, ref control);
        ThrowIfFailed(status, "setting crossfader");
    }

    /// <summary>Copies interleaved PCM into pinned planar storage retained by the engine.</summary>
    /// <param name="samples">Interleaved float32 PCM copied before returning.</param>
    /// <param name="sampleRateHz">The source sample rate.</param>
    /// <param name="channelCount">The number of channels, one or two.</param>
    /// <param name="deck">The zero-based destination deck.</param>
    public void SetDeckBuffer(ReadOnlySpan<float> samples, uint sampleRateHz,
                              uint channelCount, uint deck)
    {
        if (deck >= deckCount || samples.Length == 0 || channelCount is < 1 or > 2 ||
            sampleRateHz == 0 || samples.Length % channelCount != 0)
            throw new ArgumentException("invalid deck PCM format");

        var replacement = new PinnedDeckBuffer(samples, channelCount);
        var view = new NativeMethods.PcmView
        {
            Size = (uint)Marshal.SizeOf<NativeMethods.PcmView>(),
            AbiVersion = NativeMethods.AbiVersion,
            Planes = replacement.PlanesPointer,
            Frames = checked((ulong)(samples.Length / (int)channelCount)),
            ChannelCount = channelCount,
            SampleRateHz = sampleRateHz
        };
        var status = NativeMethods.SetDeckBuffer(handle, deck, ref view);
        if (status != NativeMethods.Ok)
        {
            replacement.Dispose();
            ThrowIfFailed(status, "setting deck buffer");
        }
        if (deckBuffers.Remove(deck, out var previous)) previous.Dispose();
        deckBuffers.Add(deck, replacement);
    }

    /// <summary>Queues a public ABI command with its fixed-width payload fields.</summary>
    /// <param name="commandType">The stable command selector.</param>
    /// <param name="deck">The destination deck, or -1 for a global command.</param>
    /// <param name="i0">First integer payload field.</param>
    /// <param name="i1">Second integer payload field.</param>
    /// <param name="i2">Third integer payload field.</param>
    /// <param name="f0">First floating-point payload field.</param>
    /// <param name="f1">Second floating-point payload field.</param>
    public void PostCommand(EngineCommand commandType, int deck = -1,
                            int i0 = 0, int i1 = 0, int i2 = 0,
                            float f0 = 0.0f, float f1 = 0.0f)
    {
        if (deck < -1 || deck >= deckCount) throw new ArgumentOutOfRangeException(nameof(deck));
        var command = new NativeMethods.Command
        {
            Size = (uint)Marshal.SizeOf<NativeMethods.Command>(),
            AbiVersion = NativeMethods.AbiVersion,
            Type = (uint)commandType,
            Deck = deck,
            I0 = i0,
            I1 = i1,
            I2 = i2,
            F0 = f0,
            F1 = f1
        };
        var status = NativeMethods.PostCommand(handle, ref command);
        ThrowIfFailed(status, "posting engine command");
    }

    /// <summary>Queues the portable play command for a deck.</summary>
    public void Play(uint deck) => PostCommand(EngineCommand.Play, checked((int)deck));

    /// <summary>Queues the portable pause command for a deck.</summary>
    public void Pause(uint deck) => PostCommand(EngineCommand.Pause, checked((int)deck));

    /// <summary>Sets the primary cue in seconds.</summary>
    public void SetCue(uint deck, float seconds) => PostCommand(EngineCommand.SetCue,
        checked((int)deck), f0: ValidateNonNegative(seconds, nameof(seconds)));

    /// <summary>Queues a jump to the primary cue.</summary>
    public void JumpCue(uint deck) => PostCommand(EngineCommand.JumpCue, checked((int)deck));

    /// <summary>Sets one of eight hot cues in seconds.</summary>
    public void SetHotCue(uint deck, int slot, float seconds)
    {
        ValidateHotCueSlot(slot);
        PostCommand(EngineCommand.HotCueSet, checked((int)deck), i0: slot,
            f0: ValidateNonNegative(seconds, nameof(seconds)));
    }

    /// <summary>Queues a jump to one of eight hot cues.</summary>
    public void JumpHotCue(uint deck, int slot)
    {
        ValidateHotCueSlot(slot);
        PostCommand(EngineCommand.HotCueJump, checked((int)deck), i0: slot);
    }

    /// <summary>Deletes one of eight hot cues.</summary>
    public void DeleteHotCue(uint deck, int slot)
    {
        ValidateHotCueSlot(slot);
        PostCommand(EngineCommand.HotCueDelete, checked((int)deck), i0: slot);
    }

    /// <summary>Sets loop bounds in seconds and optionally activates the loop.</summary>
    public void SetLoop(uint deck, float startSeconds, float endSeconds, bool active = true)
    {
        if (!float.IsFinite(startSeconds) || !float.IsFinite(endSeconds) ||
            startSeconds < 0.0f || endSeconds <= startSeconds)
            throw new ArgumentOutOfRangeException(nameof(endSeconds));
        PostCommand(EngineCommand.SetLoop, checked((int)deck), i0: active ? 1 : 0,
            f0: startSeconds, f1: endSeconds);
    }

    /// <summary>Enables or disables the deck's available loop.</summary>
    public void SetLoopActive(uint deck, bool active) => PostCommand(
        EngineCommand.SetLoopActive, checked((int)deck), f0: active ? 1.0f : 0.0f);

    private static float ValidateNonNegative(float value, string parameterName)
    {
        if (!float.IsFinite(value) || value < 0.0f)
            throw new ArgumentOutOfRangeException(parameterName);
        return value;
    }

    private static void ValidateHotCueSlot(int slot)
    {
        if (slot is < 0 or >= 8) throw new ArgumentOutOfRangeException(nameof(slot));
    }

    /// <summary>Renders one block of non-interleaved stereo output into caller-owned spans.</summary>
    /// <param name="left">The destination span for the left channel.</param>
    /// <param name="right">The destination span for the right channel.</param>
    /// <exception cref="ArgumentOutOfRangeException">Thrown when the spans differ in length, are empty, or exceed the configured block size.</exception>
    public unsafe void Render(Span<float> left, Span<float> right)
    {
        if (left.Length != right.Length || left.Length == 0 || left.Length > maxFrames)
            throw new ArgumentOutOfRangeException(nameof(left));

        fixed (float* leftPointer = left)
        fixed (float* rightPointer = right)
        {
            var output = new NativeMethods.OutputView
            {
                Size = (uint)Marshal.SizeOf<NativeMethods.OutputView>(),
                AbiVersion = NativeMethods.AbiVersion,
                Left = (nint)leftPointer,
                Right = (nint)rightPointer,
                Frames = (uint)left.Length
            };
            var status = NativeMethods.Render(handle, ref output);
            ThrowIfFailed(status, "rendering");
        }
    }

    /// <summary>Gets a snapshot of native render counters and engine topology.</summary>
    public EngineStats GetStats()
    {
        var stats = new NativeMethods.Stats
        {
            Size = (uint)Marshal.SizeOf<NativeMethods.Stats>(),
            AbiVersion = NativeMethods.AbiVersion
        };
        var status = NativeMethods.GetStats(handle, ref stats);
        ThrowIfFailed(status, "reading stats");
        return new EngineStats(stats.MasterFrame, stats.StarvedFrames, stats.DeckCount);
    }

    /// <summary>Drains up to the requested number of notifications from the native event ring.</summary>
    public unsafe EngineEvent[] PollEvents(uint maxEvents = 64)
    {
        if (maxEvents == 0 || maxEvents > 1024)
            throw new ArgumentOutOfRangeException(nameof(maxEvents));
        var nativeEvents = new NativeMethods.Event[(int)maxEvents];
        for (var index = 0; index < nativeEvents.Length; index++)
        {
            nativeEvents[index].Size = (uint)Marshal.SizeOf<NativeMethods.Event>();
            nativeEvents[index].AbiVersion = NativeMethods.AbiVersion;
        }
        uint outputEvents = 0;
        fixed (NativeMethods.Event* eventPointer = nativeEvents)
        {
            var status = NativeMethods.PollEvents(handle, eventPointer, maxEvents, ref outputEvents);
            ThrowIfFailed(status, "polling engine events");
        }
        if (outputEvents > maxEvents)
            throw new ParsoException(NativeMethods.InvalidArgument, "polling engine events");
        var managedEvents = new EngineEvent[(int)outputEvents];
        for (var index = 0; index < managedEvents.Length; index++)
        {
            var native = nativeEvents[index];
            managedEvents[index] = new EngineEvent(
                (EngineEventType)native.Type, native.Deck, native.Frame, native.F0, native.F1);
        }
        return managedEvents;
    }

    /// <summary>Enables or disables the bounded native master record ring.</summary>
    /// <param name="active">Whether subsequent renders should be copied into the ring.</param>
    public void SetRecordActive(bool active)
    {
        var status = NativeMethods.RecordSetActive(handle, active ? 1u : 0u);
        ThrowIfFailed(status, "setting record state");
    }

    /// <summary>Drains recorded master frames into new managed arrays.</summary>
    /// <param name="maxFrames">The maximum number of frames to remove.</param>
    /// <returns>Separate left and right managed channel arrays.</returns>
    public unsafe (float[] Left, float[] Right) DrainRecord(uint maxFrames)
    {
        if (maxFrames == 0 || maxFrames > int.MaxValue)
            throw new ArgumentOutOfRangeException(nameof(maxFrames));
        var left = new float[(int)maxFrames];
        var right = new float[(int)maxFrames];
        uint outputFrames = 0;
        fixed (float* leftPointer = left)
        fixed (float* rightPointer = right)
        {
            var status = NativeMethods.RecordDrain(handle, leftPointer, rightPointer,
                maxFrames, ref outputFrames);
            ThrowIfFailed(status, "draining record ring");
        }
        if (outputFrames > maxFrames)
            throw new ParsoException(NativeMethods.InvalidArgument, "draining record ring");
        if (outputFrames != maxFrames)
        {
            Array.Resize(ref left, (int)outputFrames);
            Array.Resize(ref right, (int)outputFrames);
        }
        return (left, right);
    }

    /// <summary>Gets the number of frames dropped by the bounded record ring.</summary>
    public ulong RecordDroppedFrames()
    {
        ulong outputFrames = 0;
        var status = NativeMethods.RecordDroppedFrames(handle, ref outputFrames);
        ThrowIfFailed(status, "reading record counter");
        return outputFrames;
    }

    /// <summary>Discards pending recorded frames and resets the drop counter.</summary>
    public void ResetRecord()
    {
        var status = NativeMethods.RecordReset(handle);
        ThrowIfFailed(status, "resetting record ring");
    }

    /// <summary>Releases the native engine handle.</summary>
    public void Dispose()
    {
        handle.Dispose();
        foreach (var buffer in deckBuffers.Values) buffer.Dispose();
        deckBuffers.Clear();
        GC.SuppressFinalize(this);
    }

    private static void ThrowIfFailed(int status, string operation)
    {
        if (status != NativeMethods.Ok) throw new ParsoException(status, operation);
    }
}

internal sealed class PinnedDeckBuffer : IDisposable
{
    private readonly GCHandle leftHandle;
    private readonly GCHandle rightHandle;
    private readonly GCHandle planesHandle;

    internal PinnedDeckBuffer(ReadOnlySpan<float> samples, uint channelCount)
    {
        var left = new float[samples.Length / (int)channelCount];
        var right = new float[left.Length];
        for (var index = 0; index < left.Length; index++)
        {
            left[index] = samples[index * (int)channelCount];
            right[index] = channelCount == 1
                ? left[index]
                : samples[index * (int)channelCount + 1];
        }
        var planes = new nint[] { 0, 0 };
        leftHandle = GCHandle.Alloc(left, GCHandleType.Pinned);
        rightHandle = GCHandle.Alloc(right, GCHandleType.Pinned);
        planes[0] = leftHandle.AddrOfPinnedObject();
        planes[1] = rightHandle.AddrOfPinnedObject();
        planesHandle = GCHandle.Alloc(planes, GCHandleType.Pinned);
        PlanesPointer = planesHandle.AddrOfPinnedObject();
    }

    internal nint PlanesPointer { get; }

    public void Dispose()
    {
        if (planesHandle.IsAllocated) planesHandle.Free();
        if (rightHandle.IsAllocated) rightHandle.Free();
        if (leftHandle.IsAllocated) leftHandle.Free();
    }
}

internal sealed class NativeEngineHandle : SafeHandle
{
    public NativeEngineHandle(nint handle)
        : base(IntPtr.Zero, ownsHandle: true)
    {
        SetHandle(handle);
    }

    public override bool IsInvalid => handle == IntPtr.Zero;

    protected override bool ReleaseHandle()
    {
        var nativeHandle = handle;
        var status = NativeMethods.Destroy(ref nativeHandle);
        SetHandle(IntPtr.Zero);
        return status == NativeMethods.Ok;
    }
}

internal static unsafe partial class NativeMethods
{
    internal const int Ok = 0;
    internal const int InvalidArgument = -1;
    internal const uint AbiVersion = 1;
    [StructLayout(LayoutKind.Sequential)]
    internal struct Capabilities
    {
        internal uint Size;
        internal uint AbiVersion;
        internal ulong DecodeContainers;
        internal ulong EncodeContainers;
        internal ulong ReadPcmFormats;
        internal ulong WritePcmFormats;
        internal uint MaxChannels;
        internal uint MaxSampleRateHz;
        internal ulong OfflineServices;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct PcmBuffer
    {
        internal uint Size;
        internal uint AbiVersion;
        internal nint Samples;
        internal ulong Frames;
        internal uint ChannelCount;
        internal uint SampleRateHz;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct Bytes
    {
        internal uint Size;
        internal uint AbiVersion;
        internal nint Data;
        internal ulong SizeBytes;
        internal uint Reserved0;
        internal uint Reserved1;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct CodecOptions
    {
        internal uint Size;
        internal uint AbiVersion;
        internal uint CompressionLevel;
        internal uint BitrateKbps;
        internal uint BitsPerSample;
        internal uint WavIsFloat;
        internal uint Quality;
        internal uint VbrQuality;
        internal uint Reserved0;
        internal uint Reserved1;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct SrcOptions
    {
        internal uint Size;
        internal uint AbiVersion;
        internal uint SourceSampleRateHz;
        internal uint DestinationSampleRateHz;
        internal uint ChannelCount;
        internal uint Quality;
        internal uint Reserved0;
        internal uint Reserved1;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct LoudnessOptions
    {
        internal uint Size;
        internal uint AbiVersion;
        internal double TargetLufs;
        internal uint Reserved0;
        internal uint Reserved1;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct LoudnessResult
    {
        internal uint Size;
        internal uint AbiVersion;
        internal double IntegratedLufs;
        internal double TruePeakDbtp;
        internal double GainToTargetDb;
        internal double LoudnessRangeLu;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct AnalysisOptions
    {
        internal uint Size;
        internal uint AbiVersion;
        internal uint HopFrames;
        internal uint MinBpm;
        internal uint MaxBpm;
        internal uint Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct AnalysisResult
    {
        internal uint Size;
        internal uint AbiVersion;
        internal double DurationSeconds;
        internal double Rms;
        internal double Peak;
        internal double Bpm;
        internal double BpmConfidence;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct KeyOptions
    {
        internal uint Size;
        internal uint AbiVersion;
        internal uint WindowFrames;
        internal uint HopFrames;
        internal uint MinMidi;
        internal uint MaxMidi;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct KeyResult
    {
        internal uint Size;
        internal uint AbiVersion;
        internal uint TonicPitchClass;
        internal uint IsMinor;
        internal uint CamelotNumber;
        internal uint CamelotLetter;
        internal double Confidence;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct StructureOptions
    {
        internal uint Size;
        internal uint AbiVersion;
        internal double Bpm;
        internal uint MaxSections;
        internal uint Reserved0;
        internal uint Reserved1;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct StructureSection
    {
        internal double StartSeconds;
        internal uint Kind;
        internal uint Bar;
        internal double Energy;
        internal double Confidence;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct EngineOptions
    {
        internal uint Size;
        internal uint AbiVersion;
        internal uint SampleRateHz;
        internal uint MaxFrames;
        internal uint DeckCount;
        internal uint Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct Control
    {
        internal uint Size;
        internal uint AbiVersion;
        internal float Crossfader;
        internal float XfadeCurve;
        internal float MasterLevel;
        internal float LimiterCeilingDb;
        internal float LimiterEnabled;
        internal fixed float XfadeAssign[4];
        internal fixed float Fader[4];
        internal fixed float Trim[4];
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct OutputView
    {
        internal uint Size;
        internal uint AbiVersion;
        internal nint Left;
        internal nint Right;
        internal uint Frames;
        internal uint Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct PcmView
    {
        internal uint Size;
        internal uint AbiVersion;
        internal nint Planes;
        internal ulong Frames;
        internal uint ChannelCount;
        internal uint SampleRateHz;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct Command
    {
        internal uint Size;
        internal uint AbiVersion;
        internal uint Type;
        internal int Deck;
        internal int I0;
        internal int I1;
        internal int I2;
        internal float F0;
        internal float F1;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct Stats
    {
        internal uint Size;
        internal uint AbiVersion;
        internal ulong MasterFrame;
        internal ulong StarvedFrames;
        internal uint DeckCount;
        internal uint Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    internal struct Event
    {
        internal uint Size;
        internal uint AbiVersion;
        internal uint Type;
        internal int Deck;
        internal long Frame;
        internal float F0;
        internal float F1;
    }

    internal static EngineOptions DefaultOptions(uint sampleRateHz, uint maxFrames, uint deckCount) => new()
    {
        Size = (uint)Marshal.SizeOf<EngineOptions>(),
        AbiVersion = AbiVersion,
        SampleRateHz = sampleRateHz,
        MaxFrames = maxFrames,
        DeckCount = deckCount
    };

    internal static Control DefaultControl()
    {
        var control = new Control
        {
            Size = (uint)Marshal.SizeOf<Control>(),
            AbiVersion = AbiVersion,
            MasterLevel = 0.8f,
            LimiterCeilingDb = -0.3f,
            LimiterEnabled = 1.0f
        };
        for (var index = 0; index < 4; index++)
        {
            control.XfadeAssign[index] = 2.0f;
            control.Fader[index] = 1.0f;
            control.Trim[index] = 0.5f;
        }
        return control;
    }

    [LibraryImport("parso", EntryPoint = "parso_capabilities_init")]
    internal static partial int CapabilitiesInit(ref Capabilities capabilities);

    [LibraryImport("parso", EntryPoint = "parso_capabilities_get")]
    internal static partial int CapabilitiesGet(ref Capabilities capabilities);

    [LibraryImport("parso", EntryPoint = "parso_pcm_buffer_init")]
    internal static partial int PcmBufferInit(ref PcmBuffer buffer);

    [LibraryImport("parso", EntryPoint = "parso_pcm_buffer_release")]
    internal static partial int PcmBufferRelease(ref PcmBuffer buffer);

    [LibraryImport("parso", EntryPoint = "parso_bytes_init")]
    internal static partial int BytesInit(ref Bytes bytes);

    [LibraryImport("parso", EntryPoint = "parso_bytes_release")]
    internal static partial int BytesRelease(ref Bytes bytes);

    [LibraryImport("parso", EntryPoint = "parso_codec_read")]
    internal static partial int CodecRead(
        nint data, ulong sizeBytes, uint codec, ref CodecOptions options, ref PcmBuffer output);

    [LibraryImport("parso", EntryPoint = "parso_codec_write")]
    internal static partial int CodecWrite(
        ref PcmBuffer input, uint codec, ref CodecOptions options, ref Bytes output);

    [LibraryImport("parso", EntryPoint = "parso_src_options_init")]
    internal static partial int SrcOptionsInit(ref SrcOptions options);

    [LibraryImport("parso", EntryPoint = "parso_src_convert")]
    internal static partial int SrcConvert(ref PcmBuffer input, ref SrcOptions options,
        ref PcmBuffer output);

    [LibraryImport("parso", EntryPoint = "parso_loudness_options_init")]
    internal static partial int LoudnessOptionsInit(ref LoudnessOptions options);

    [LibraryImport("parso", EntryPoint = "parso_loudness_result_init")]
    internal static partial int LoudnessResultInit(ref LoudnessResult result);

    [LibraryImport("parso", EntryPoint = "parso_loudness_measure")]
    internal static partial int LoudnessMeasure(ref PcmBuffer input,
        ref LoudnessOptions options, ref LoudnessResult result);

    [LibraryImport("parso", EntryPoint = "parso_analysis_options_init")]
    internal static partial int AnalysisOptionsInit(ref AnalysisOptions options);

    [LibraryImport("parso", EntryPoint = "parso_analysis_result_init")]
    internal static partial int AnalysisResultInit(ref AnalysisResult result);

    [LibraryImport("parso", EntryPoint = "parso_analysis_measure")]
    internal static partial int AnalysisMeasure(ref PcmBuffer input, ref AnalysisOptions options,
        ref AnalysisResult result);

    [LibraryImport("parso", EntryPoint = "parso_key_options_init")]
    internal static partial int KeyOptionsInit(ref KeyOptions options);

    [LibraryImport("parso", EntryPoint = "parso_key_result_init")]
    internal static partial int KeyResultInit(ref KeyResult result);

    [LibraryImport("parso", EntryPoint = "parso_key_measure")]
    internal static partial int KeyMeasure(ref PcmBuffer input, ref KeyOptions options,
        ref KeyResult result);

    [LibraryImport("parso", EntryPoint = "parso_structure_options_init")]
    internal static partial int StructureOptionsInit(ref StructureOptions options);

    [LibraryImport("parso", EntryPoint = "parso_structure_measure")]
    internal static partial int StructureMeasure(ref PcmBuffer input,
        ref StructureOptions options, StructureSection* sections, uint capacity,
        ref uint outCount);

    [LibraryImport("parso", EntryPoint = "parso_waveform_generate")]
    internal static partial int WaveformGenerate(ref PcmBuffer input, uint bucketCount,
        float* outputMin, float* outputMax);

    [LibraryImport("parso", EntryPoint = "parso_engine_create")]
    internal static partial int Create(ref EngineOptions options, out nint engine);

    [LibraryImport("parso", EntryPoint = "parso_engine_destroy")]
    internal static partial int Destroy(ref nint engine);

    [LibraryImport("parso", EntryPoint = "parso_engine_set_control")]
    internal static partial int SetControl(NativeEngineHandle engine, ref Control control);

    [LibraryImport("parso", EntryPoint = "parso_engine_set_deck_buffer")]
    internal static partial int SetDeckBuffer(NativeEngineHandle engine, uint deck, ref PcmView view);

    [LibraryImport("parso", EntryPoint = "parso_engine_post_command")]
    internal static partial int PostCommand(NativeEngineHandle engine, ref Command command);

    [LibraryImport("parso", EntryPoint = "parso_engine_render")]
    internal static partial int Render(NativeEngineHandle engine, ref OutputView output);

    [LibraryImport("parso", EntryPoint = "parso_engine_get_stats")]
    internal static partial int GetStats(NativeEngineHandle engine, ref Stats stats);

    [LibraryImport("parso", EntryPoint = "parso_engine_poll_events")]
    internal static partial int PollEvents(NativeEngineHandle engine, Event* events,
        uint maxEvents, ref uint outputEvents);

    [LibraryImport("parso", EntryPoint = "parso_engine_record_set_active")]
    internal static partial int RecordSetActive(NativeEngineHandle engine, uint active);

    [LibraryImport("parso", EntryPoint = "parso_engine_record_drain")]
    internal static partial int RecordDrain(NativeEngineHandle engine, float* left, float* right,
        uint maxFrames, ref uint outputFrames);

    [LibraryImport("parso", EntryPoint = "parso_engine_record_dropped_frames")]
    internal static partial int RecordDroppedFrames(NativeEngineHandle engine, ref ulong outputFrames);

    [LibraryImport("parso", EntryPoint = "parso_engine_record_reset")]
    internal static partial int RecordReset(NativeEngineHandle engine);
}
