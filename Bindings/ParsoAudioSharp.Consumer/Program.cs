using ParsoAudioSharp;

using var engine = Engine.Create(maxFrames: 256);
var left = new float[256];
var right = new float[256];
engine.SetMasterLevel(0.8f);
engine.Render(left, right);
var stats = engine.GetStats();

if (stats.MasterFrame != 256 || stats.DeckCount != 2)
    throw new InvalidOperationException("C# native consumer received invalid engine statistics.");

Console.WriteLine($"C# native consumer passed at frame {stats.MasterFrame}.");
