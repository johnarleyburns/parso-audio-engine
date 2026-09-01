import Foundation
import ParsoAudioAnalysis
import ParsoAudioCore

/// Generates deterministic, human-inspectable acceptance inputs.
///
/// The Swift executable owns decoding, analysis, and WAV production. The companion
/// Python script turns the sidecar into a video using the machine's ffmpeg. Keeping
/// those responsibilities separate leaves ffmpeg out of the shipping library and
/// makes the JSON useful for review tools other than video.
@main
@MainActor
struct ParsoAcceptanceArtifacts {
    private struct Fixture: Decodable {
        let id: String
        let filename: String
        let sourceFormat: String
    }

    private struct Manifest: Decodable { let tracks: [Fixture] }

    private struct WaveformPoint: Encodable {
        let min: Float
        let max: Float
        let rms: Float
        let low: Float
        let mid: Float
        let high: Float
    }

    private struct SectionPoint: Encodable {
        let start: TimeInterval
        let kind: String
        let bar: Int
    }

    private struct EventPoint: Encodable {
        let time: TimeInterval
        let type: String
        let deck: Int?
        let value: Double?
    }

    private struct Artifact: Encodable {
        let schema: Int
        let fixtureID: String
        let sourceFormat: String
        let scenario: String
        let renderedScenario: String
        let sampleRate: Double
        let channelCount: Int
        let frameCount: Int
        let audioDuration: TimeInterval
        let analysisDuration: TimeInterval
        let bpm: Double
        let tempoConfidence: Double
        let key: String
        let keyConfidence: Double
        let loudnessLUFS: Double
        let beats: [TimeInterval]
        let downbeats: [TimeInterval]
        let sections: [SectionPoint]
        let waveform: [WaveformPoint]
        let events: [EventPoint]
        let notes: [String]
    }

    private enum ToolError: LocalizedError {
        case usage(String)
        case message(String)

        var errorDescription: String? {
            switch self {
            case .usage(let message), .message(let message): return message
            }
        }
    }

    static func main() throws {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            try generate(options)
        } catch {
            let message = "ParsoAcceptanceArtifacts: \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            exit(2)
        }
    }

    private static func generate(_ options: Options) throws {
        guard options.scenario == "waveform" else {
            throw ToolError.message(
                "scenario '\(options.scenario)' is not implemented; available scenario: waveform"
            )
        }

        let manifestURL = URL(fileURLWithPath: options.manifest)
        let manifestData: Data
        do { manifestData = try Data(contentsOf: manifestURL) }
        catch { throw ToolError.message("cannot read manifest \(manifestURL.path): \(error.localizedDescription)") }
        let manifest: Manifest
        do { manifest = try JSONDecoder().decode(Manifest.self, from: manifestData) }
        catch { throw ToolError.message("cannot decode manifest: \(error.localizedDescription)") }
        guard let fixture = manifest.tracks.first(where: { $0.id == options.fixtureID }) else {
            let available = manifest.tracks.map(\.id).joined(separator: ", ")
            throw ToolError.message("unknown fixture '\(options.fixtureID)'; available: \(available)")
        }

        let audioURL = URL(fileURLWithPath: options.audioDirectory)
            .appendingPathComponent("\(fixture.id).\((fixture.filename as NSString).pathExtension)")
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw ToolError.message("fixture is not downloaded: \(audioURL.path)\nRun ./scripts/download-fixtures.sh first.")
        }

        let source = try AudioFileReader(url: audioURL).readAll()
        let completeAnalysis = TrackAnalyzer().analyze(source)
        let visible = try clipped(source, maximumSeconds: options.maximumSeconds)
        let visibleWaveform = WaveformGenerator().generate(visible)
        let visibleDuration = duration(of: visible)

        try FileManager.default.createDirectory(
            at: options.outputDirectory,
            withIntermediateDirectories: true
        )
        let wavURL = options.outputDirectory.appendingPathComponent("\(fixture.id)-\(options.scenario).wav")
        let jsonURL = options.outputDirectory.appendingPathComponent("\(fixture.id)-\(options.scenario).json")
        let writer = try AudioFileWriter(
            url: wavURL,
            format: visible.format,
            codec: .wavPCM(bitDepth: 16)
        )
        try writer.write(visible)
        try writer.finish()

        let key = switch completeAnalysis.key.mode {
        case .major: "\(KeyProfiles.pitchClassNames[completeAnalysis.key.tonic]) major"
        case .minor: "\(KeyProfiles.pitchClassNames[completeAnalysis.key.tonic]) minor"
        }
        let artifact = Artifact(
            schema: 1,
            fixtureID: fixture.id,
            sourceFormat: fixture.sourceFormat,
            scenario: options.scenario,
            renderedScenario: "source-analysis",
            sampleRate: visible.format.sampleRate,
            channelCount: visible.channelCount,
            frameCount: visible.frameCount,
            audioDuration: visibleDuration,
            analysisDuration: completeAnalysis.duration,
            bpm: completeAnalysis.tempo.bpm,
            tempoConfidence: completeAnalysis.tempo.confidence,
            key: key,
            keyConfidence: completeAnalysis.key.confidence,
            loudnessLUFS: completeAnalysis.loudness.integratedLUFS,
            beats: completeAnalysis.tempo.beatPositions.filter { $0 < visibleDuration },
            downbeats: completeAnalysis.tempo.downbeatPositions.filter { $0 < visibleDuration },
            sections: completeAnalysis.sections
                .filter { $0.start < visibleDuration }
                .map { SectionPoint(start: $0.start, kind: sectionName($0.kind), bar: $0.bar) },
            waveform: zip(
                visibleWaveform.overviewMinMax,
                zip(visibleWaveform.detailRMS, visibleWaveform.bandEnergy)
            ).map { pair in
                let (bounds, detail) = pair
                let (rms, bands) = detail
                return WaveformPoint(
                    min: bounds.x, max: bounds.y, rms: rms,
                    low: bands.x, mid: bands.y, high: bands.z
                )
            },
            events: [],
            notes: [
                "Audio is the first \(String(format: "%.1f", visibleDuration)) seconds of the downloaded fixture.",
                "Beat and section annotations come from analysis of the complete source track.",
                "This artifact validates source analysis and synchronization only; it does not claim Smart Fader/CFX or scratch parity."
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(artifact).write(to: jsonURL, options: .atomic)
        print("audio: \(wavURL.path)")
        print("analysis: \(jsonURL.path)")
    }

    private static func duration(of buffer: PCMBuffer) -> TimeInterval {
        guard buffer.format.sampleRate > 0 else { return 0 }
        return Double(buffer.frameCount) / buffer.format.sampleRate
    }

    private static func clipped(_ source: PCMBuffer, maximumSeconds: TimeInterval) throws -> PCMBuffer {
        guard maximumSeconds.isFinite, maximumSeconds > 0 else { return source }
        let frames = min(source.frameCount, Int(maximumSeconds * source.format.sampleRate))
        let output = PCMBuffer(format: source.format, capacity: frames)
        for channel in 0..<source.channelCount {
            for frame in 0..<frames { output.channel(channel)[frame] = source.channel(channel)[frame] }
        }
        return output
    }

    private static func sectionName(_ kind: Section.Kind) -> String {
        switch kind {
        case .intro: "intro"
        case .buildup: "buildup"
        case .drop: "drop"
        case .verse: "verse"
        case .chorus: "chorus"
        case .breakdown: "breakdown"
        case .outro: "outro"
        case .unknown: "unknown"
        }
    }

    private struct Options {
        let fixtureID: String
        let manifest: String
        let audioDirectory: String
        let outputDirectory: URL
        let scenario: String
        let maximumSeconds: TimeInterval

        init(arguments: [String]) throws {
            var values: [String: String] = [:]
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                guard argument.hasPrefix("--"), index + 1 < arguments.count else {
                    throw ToolError.usage("usage: swift run ParsoAcceptanceArtifacts --fixture ID [--scenario waveform] [--output-dir DIR] [--max-seconds N]")
                }
                values[String(argument.dropFirst(2))] = arguments[index + 1]
                index += 2
            }
            guard let fixtureID = values["fixture"], !fixtureID.isEmpty else {
                throw ToolError.usage("--fixture is required; use an id from Tests/Fixtures/fixtures.json")
            }
            self.fixtureID = fixtureID
            self.manifest = values["manifest"] ?? "Tests/Fixtures/fixtures.json"
            self.audioDirectory = values["audio-dir"] ?? "Tests/Fixtures/audio"
            self.outputDirectory = URL(fileURLWithPath: values["output-dir"] ?? "artifacts/acceptance")
            self.scenario = values["scenario"] ?? "waveform"
            self.maximumSeconds = TimeInterval(values["max-seconds"] ?? "30") ?? 30
        }
    }
}
