import Foundation
import ParsoAudioCore
import ParsoAudioAnalysis
import ParsoAudioNeural

/// Human-listening acceptance for the Phase 7b/7c stem-separation seam
/// (`StemModelProviding` / `StemSeparator`, `Sources/ParsoAudioNeural/Separation.swift`).
///
/// Runs real Demucs inference (`DemucsStems.mlpackage`, already converted for
/// parso-tonearm — see ATTRIBUTION.md) over a Wikimedia Commons fixture and
/// writes each of the four separated voices as its own WAV, so a reviewer can
/// listen to vocals/drums/bass/other in isolation and against the mix. This
/// is a separate executable from `ParsoAcceptanceArtifacts` because its
/// output shape (four full-length WAVs, no video overlay) does not fit that
/// tool's one-WAV-per-scenario contract.
///
/// Spleeter — the actual *shipping* default backend — has no converted
/// `.mlpackage` yet (README.md "Spleeter's real limitation"); converting its
/// TF checkpoint is separate follow-up work. This tool takes any
/// `StemModelProviding` conformance, so pointing it at a Spleeter model once
/// one exists needs no changes here.
@main
struct ParsoStemsAcceptance {
    private struct Fixture: Decodable {
        let id: String
        let filename: String
    }

    private struct Manifest: Decodable { let tracks: [Fixture] }

    private struct Report: Encodable {
        let fixtureID: String
        let modelPath: String
        let sampleRate: Double
        let sourceDuration: TimeInterval
        let processedDuration: TimeInterval
        let voices: [String]
        let notes: [String]
    }

    private enum ToolError: LocalizedError {
        case usage(String)
        case message(String)
        var errorDescription: String? {
            switch self {
            case .usage(let m), .message(let m): return m
            }
        }
    }

    static func main() async throws {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            try await run(options)
        } catch {
            FileHandle.standardError.write(Data("ParsoStemsAcceptance: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }

    private static func run(_ options: Options) async throws {
        let manifestURL = URL(fileURLWithPath: options.manifest)
        let manifest = try JSONDecoder().decode(Manifest.self, from: try Data(contentsOf: manifestURL))
        guard let fixture = manifest.tracks.first(where: { $0.id == options.fixtureID }) else {
            let available = manifest.tracks.map(\.id).joined(separator: ", ")
            throw ToolError.message("unknown fixture '\(options.fixtureID)'; available: \(available)")
        }
        let audioURL = URL(fileURLWithPath: options.audioDirectory)
            .appendingPathComponent("\(fixture.id).\((fixture.filename as NSString).pathExtension)")
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw ToolError.message("fixture is not downloaded: \(audioURL.path)\nRun ./scripts/download-fixtures.sh first.")
        }
        guard FileManager.default.fileExists(atPath: options.modelPath) else {
            throw ToolError.message(
                "stem model not found: \(options.modelPath)\n" +
                "Pass --stems-model /path/to/DemucsStems.mlpackage (see parso-tonearm/Resources/Models)."
            )
        }

        let decoded = try AudioFileReader(url: audioURL).readAll()
        let clipped = try clip(decoded, maximumSeconds: options.maximumSeconds)
        let sourceDuration = duration(of: decoded)
        let processedDuration = duration(of: clipped)

        var channels: [[Float]] = []
        for c in 0..<clipped.channelCount {
            channels.append(Array(clipped.channel(c)))
        }
        let pcm = AnalysisAudio(sampleRate: clipped.format.sampleRate, channels: channels)

        let model = DemucsStemModelForAcceptance(modelURL: URL(fileURLWithPath: options.modelPath))
        let separator = StemSeparator(model: model)
        guard let separation = try await separator.separate(pcm: pcm) else {
            throw ToolError.message("the model reported unavailable at \(options.modelPath)")
        }

        try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        var voiceNames: [String] = []
        for (kind, chunk) in separation.all {
            let url = options.outputDirectory.appendingPathComponent("\(fixture.id)-\(kind.rawValue).wav")
            try write(chunk, sampleRate: separation.sampleRate, to: url)
            voiceNames.append(kind.rawValue)
            print("\(kind.rawValue): \(url.path)")
        }

        let jsonURL = options.outputDirectory.appendingPathComponent("\(fixture.id)-stems.json")
        let report = Report(
            fixtureID: fixture.id,
            modelPath: options.modelPath,
            sampleRate: separation.sampleRate,
            sourceDuration: sourceDuration,
            processedDuration: processedDuration,
            voices: voiceNames,
            notes: [
                "Backend: Demucs (DemucsStems.mlpackage) — a real converted model used to prove the " +
                "StemModelProviding/StemSeparator pipeline end-to-end. Spleeter is PAE's shipping " +
                "default backend but has no converted .mlpackage yet.",
                "Listen to each voice file alone, then against the original fixture audio, for bleed " +
                "(another instrument audible in a voice that should be isolated) and artifacts."
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: jsonURL, options: .atomic)
        print("report: \(jsonURL.path)")
    }

    private static func write(_ chunk: StemChunk, sampleRate: Double, to url: URL) throws {
        let format = AudioFormat(sampleRate: sampleRate, channelCount: 2)
        let buffer = PCMBuffer(format: format, capacity: chunk.frameCount)
        let left = buffer.channel(0)
        let right = buffer.channel(1)
        for i in 0..<chunk.frameCount {
            left[i] = chunk.left[i]
            right[i] = chunk.right[i]
        }
        let writer = try AudioFileWriter(url: url, format: format, codec: .wavPCM(bitDepth: 16))
        try writer.write(buffer)
        try writer.finish()
    }

    private static func duration(of buffer: PCMBuffer) -> TimeInterval {
        guard buffer.format.sampleRate > 0 else { return 0 }
        return Double(buffer.frameCount) / buffer.format.sampleRate
    }

    private static func clip(_ source: PCMBuffer, maximumSeconds: TimeInterval) throws -> PCMBuffer {
        guard maximumSeconds.isFinite, maximumSeconds > 0 else { return source }
        let frames = min(source.frameCount, Int(maximumSeconds * source.format.sampleRate))
        let output = PCMBuffer(format: source.format, capacity: frames)
        for channel in 0..<source.channelCount {
            for frame in 0..<frames { output.channel(channel)[frame] = source.channel(channel)[frame] }
        }
        return output
    }

    private struct Options {
        let fixtureID: String
        let manifest: String
        let audioDirectory: String
        let outputDirectory: URL
        let modelPath: String
        let maximumSeconds: TimeInterval

        init(arguments: [String]) throws {
            var values: [String: String] = [:]
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                guard argument.hasPrefix("--"), index + 1 < arguments.count else {
                    throw ToolError.usage(
                        "usage: swift run ParsoStemsAcceptance --fixture ID --stems-model PATH " +
                        "[--manifest PATH] [--audio-dir DIR] [--output-dir DIR] [--max-seconds N]")
                }
                values[String(argument.dropFirst(2))] = arguments[index + 1]
                index += 2
            }
            guard let fixtureID = values["fixture"], !fixtureID.isEmpty else {
                throw ToolError.usage("--fixture is required; use an id from Tests/Fixtures/fixtures.json")
            }
            guard let modelPath = values["stems-model"], !modelPath.isEmpty else {
                throw ToolError.usage("--stems-model is required (path to DemucsStems.mlpackage)")
            }
            self.fixtureID = fixtureID
            self.modelPath = modelPath
            self.manifest = values["manifest"] ?? "Tests/Fixtures/fixtures.json"
            self.audioDirectory = values["audio-dir"] ?? "Tests/Fixtures/audio"
            self.outputDirectory = URL(fileURLWithPath: values["output-dir"] ?? "artifacts/acceptance")
            self.maximumSeconds = TimeInterval(values["max-seconds"] ?? "0") ?? 0
        }
    }
}
