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

using var engine = Engine.Create(maxFrames: 256);
var left = new float[256];
var right = new float[256];
engine.SetMasterLevel(0.8f);
engine.SetDeckBuffer(tone, 48_000, 1, 0);
engine.Play(0);
engine.SetRecordActive(true);
engine.Render(left, right);
var recorded = engine.DrainRecord(256);
if (recorded.Left.Length != 256 || recorded.Right.Length != 256 ||
    !recorded.Left.Any(sample => MathF.Abs(sample) > 1.0e-6f) ||
    engine.RecordDroppedFrames() != 0)
    throw new InvalidOperationException("C# native consumer received invalid record-ring data.");
engine.ResetRecord();
var stats = engine.GetStats();

if (stats.MasterFrame != 256 || stats.DeckCount != 2)
    throw new InvalidOperationException("C# native consumer received invalid engine statistics.");

Console.WriteLine($"C# native consumer passed at frame {stats.MasterFrame}.");
