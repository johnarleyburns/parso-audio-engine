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

    private Engine(NativeEngineHandle handle, uint maxFrames)
    {
        this.handle = handle;
        this.maxFrames = maxFrames;
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
        return new Engine(new NativeEngineHandle(nativeHandle), maxFrames);
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
        GC.SuppressFinalize(this);
    }

    private static void ThrowIfFailed(int status, string operation)
    {
        if (status != NativeMethods.Ok) throw new ParsoException(status, operation);
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
    internal struct Stats
    {
        internal uint Size;
        internal uint AbiVersion;
        internal ulong MasterFrame;
        internal ulong StarvedFrames;
        internal uint DeckCount;
        internal uint Reserved;
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

    [LibraryImport("parso", EntryPoint = "parso_engine_create")]
    internal static partial int Create(ref EngineOptions options, out nint engine);

    [LibraryImport("parso", EntryPoint = "parso_engine_destroy")]
    internal static partial int Destroy(ref nint engine);

    [LibraryImport("parso", EntryPoint = "parso_engine_set_control")]
    internal static partial int SetControl(NativeEngineHandle engine, ref Control control);

    [LibraryImport("parso", EntryPoint = "parso_engine_render")]
    internal static partial int Render(NativeEngineHandle engine, ref OutputView output);

    [LibraryImport("parso", EntryPoint = "parso_engine_get_stats")]
    internal static partial int GetStats(NativeEngineHandle engine, ref Stats stats);

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
