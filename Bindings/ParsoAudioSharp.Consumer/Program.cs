using ParsoAudioSharp;

var tone = new float[4_800];
for (var index = 0; index < tone.Length; index++)
    tone[index] = MathF.Sin(2.0f * MathF.PI * 440.0f * index / 48_000.0f) * 0.25f;

var capabilities = CodecServices.GetCapabilities();
if (!capabilities.EncodeContainers.HasFlag(ContainerCapability.OggVorbis) ||
    !capabilities.DecodeContainers.HasFlag(ContainerCapability.OggVorbis))
    throw new InvalidOperationException("C# native consumer did not receive Xiph Vorbis capability bits.");

var encoded = CodecServices.Encode(tone, 48_000, 1, AudioCodec.OggVorbis);
var decoded = CodecServices.Decode(encoded, AudioCodec.OggVorbis);
if (decoded.ChannelCount != 1 || decoded.SampleRateHz != 48_000 || decoded.Frames == 0 ||
    (ulong)decoded.Samples.Length != decoded.Frames)
    throw new InvalidOperationException("C# native consumer received invalid Vorbis PCM.");
var analysis = CodecServices.Analyze(tone, 48_000, 1);
if (analysis.DurationSeconds <= 0.0 || analysis.Peak <= 0.0)
    throw new InvalidOperationException("C# native consumer received invalid analysis summary.");
var waveform = CodecServices.Waveform(tone, 48_000, 1, 8);
if (waveform.Min.Length != 8 || waveform.Max.Length != 8 ||
    waveform.Min.Zip(waveform.Max).Any(pair => pair.First > pair.Second))
    throw new InvalidOperationException("C# native consumer received invalid waveform summary.");

using var engine = Engine.Create(maxFrames: 256);
var left = new float[256];
var right = new float[256];
engine.SetMasterLevel(0.8f);
engine.SetDeckBuffer(tone, 48_000, 1, 0);
engine.Play(0);
engine.PostCommand(EngineCommand.SetSlip, deck: 0, f0: 1.0f);
engine.PostCommand(EngineCommand.Seek, deck: 0, f0: 0.001f);
engine.SetCue(0, 0.001f);
engine.SetHotCue(0, 0, 0.002f);
engine.SetLoop(0, 0.001f, 0.01f);
engine.SetRecordActive(true);
engine.Render(left, right);
var recorded = engine.DrainRecord(256);
if (recorded.Left.Length != 256 || recorded.Right.Length != 256 ||
    !recorded.Left.Any(sample => MathF.Abs(sample) > 1.0e-6f) ||
    engine.RecordDroppedFrames() != 0)
    throw new InvalidOperationException("C# native consumer received invalid record-ring data.");
var events = engine.PollEvents();
if (!events.Any(item => item.Type == EngineEventType.State && item.Deck == 0))
    throw new InvalidOperationException("C# native consumer did not receive a deck state event.");
engine.ResetRecord();
var stats = engine.GetStats();

if (stats.MasterFrame != 256 || stats.DeckCount != 2)
    throw new InvalidOperationException("C# native consumer received invalid engine statistics.");

Console.WriteLine($"C# native consumer passed at frame {stats.MasterFrame}.");
