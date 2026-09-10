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
    internal const uint AbiVersion = 1;

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
}
