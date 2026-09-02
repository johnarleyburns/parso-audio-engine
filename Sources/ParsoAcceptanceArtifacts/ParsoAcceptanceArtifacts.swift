import Foundation
import ParsoAudioAnalysis
import ParsoAudioCore
import ParsoDJEngine

/// Generates deterministic, human-inspectable acceptance inputs.
///
/// The Swift executable owns decoding, analysis, and WAV production. The companion
/// Python script turns the sidecar into a video using the machine's ffmpeg. Keeping
/// those responsibilities separate leaves ffmpeg out of the shipping library and
/// makes the JSON useful for review tools other than video.
@main
@MainActor
struct ParsoAcceptanceArtifacts {
    private static let minimumReviewDuration: TimeInterval = 30

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

    private struct Rendering {
        let buffer: PCMBuffer
        let waveform: Waveform
        let sourceFormat: String
        let renderedScenario: String
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

        let primaryURL = audioURL(for: fixture, directory: options.audioDirectory)
        guard FileManager.default.fileExists(atPath: primaryURL.path) else {
            throw ToolError.message("fixture is not downloaded: \(primaryURL.path)\nRun ./scripts/download-fixtures.sh first.")
        }

        let source = try AudioFileReader(url: primaryURL).readAll()
        let completeAnalysis = TrackAnalyzer().analyze(source)
        let rendering: Rendering
        switch options.scenario {
        case "waveform":
            let visible = try clipped(source, maximumSeconds: options.maximumSeconds)
            rendering = Rendering(
                buffer: visible,
                waveform: WaveformGenerator().generate(visible),
                sourceFormat: fixture.sourceFormat,
                renderedScenario: "source-analysis",
                events: [],
                notes: [
                    "Audio is the first \(String(format: "%.1f", duration(of: visible))) seconds of the downloaded fixture.",
                    "Beat and section annotations come from analysis of the complete source track.",
                    "This artifact validates source analysis and synchronization only; it does not claim Smart Fader/CFX or scratch parity."
                ]
            )
        case "phrase":
            rendering = Rendering(
                buffer: source,
                waveform: WaveformGenerator().generate(source),
                sourceFormat: fixture.sourceFormat,
                renderedScenario: "complete-source-phrase-analysis",
                events: [],
                notes: [
                    "Audio is the complete downloaded fixture; no clip is selected.",
                    "Beat, downbeat, waveform, and phrase annotations come from analysis of the complete source track.",
                    "This artifact is the full-song phrase/structure review and does not claim engine FX parity."
                ]
            )
        case "crossfader-sweep":
            let second = try secondFixture(for: fixture, in: manifest.tracks, requestedID: options.fixtureBID)
            let secondURL = audioURL(for: second, directory: options.audioDirectory)
            guard FileManager.default.fileExists(atPath: secondURL.path) else {
                throw ToolError.message("fixture-b is not downloaded: \(secondURL.path)")
            }
            let secondBuffer = try AudioFileReader(url: secondURL).readAll()
            let secondAnalysis = TrackAnalyzer().analyze(secondBuffer)
            rendering = try renderCrossfaderSweep(
                first: (source, completeAnalysis),
                second: (secondBuffer, secondAnalysis),
                sourceFormat: "\(fixture.sourceFormat) + \(second.sourceFormat)",
                maximumSeconds: options.maximumSeconds
            )
        default:
            throw ToolError.message(
                "scenario '\(options.scenario)' is not implemented; available scenarios: waveform, phrase, crossfader-sweep"
            )
        }
        let visible = rendering.buffer
        let visibleDuration = duration(of: visible)
        guard visibleDuration >= minimumReviewDuration else {
            throw ToolError.message(
                "human-acceptance artifacts must contain at least 30 seconds of audio; " +
                "the selected source/render is only \(String(format: "%.2f", visibleDuration)) seconds"
            )
        }

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
            sourceFormat: rendering.sourceFormat,
            scenario: options.scenario,
            renderedScenario: rendering.renderedScenario,
            sampleRate: visible.format.sampleRate,
            channelCount: visible.channelCount,
            frameCount: visible.frameCount,
            audioDuration: visibleDuration,
            analysisDuration: completeAnalysis.duration,
            bpm: completeAnalysis.tempo.bpm,
            tempoConfidence: completeAnalysis.tempo.confidence,
            key: key,
            keyConfidence: completeAnalysis.key.confidence,
            loudnessLUFS: LoudnessAnalyzer().measure(visible).integratedLUFS,
            beats: completeAnalysis.tempo.beatPositions.filter { $0 < visibleDuration },
            downbeats: completeAnalysis.tempo.downbeatPositions.filter { $0 < visibleDuration },
            sections: completeAnalysis.sections
                .filter { $0.start < visibleDuration }
                .map { SectionPoint(start: $0.start, kind: sectionName($0.kind), bar: $0.bar) },
            waveform: waveformPoints(rendering.waveform),
            events: rendering.events,
            notes: rendering.notes
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(artifact).write(to: jsonURL, options: .atomic)
        print("audio: \(wavURL.path)")
        print("analysis: \(jsonURL.path)")
    }

    private static func waveformPoints(_ waveform: Waveform) -> [WaveformPoint] {
        zip(waveform.overviewMinMax, zip(waveform.detailRMS, waveform.bandEnergy)).map { pair in
            let (bounds, detail) = pair
            let (rms, bands) = detail
            return WaveformPoint(
                min: bounds.x, max: bounds.y, rms: rms,
                low: bands.x, mid: bands.y, high: bands.z
            )
        }
    }

    private static func audioURL(for fixture: Fixture, directory: String) -> URL {
        URL(fileURLWithPath: directory)
            .appendingPathComponent("\(fixture.id).\((fixture.filename as NSString).pathExtension)")
    }

    private static func secondFixture(
        for first: Fixture,
        in fixtures: [Fixture],
        requestedID: String?
    ) throws -> Fixture {
        if let requestedID {
            guard let fixture = fixtures.first(where: { $0.id == requestedID }) else {
                throw ToolError.message("unknown fixture-b '\(requestedID)'")
            }
            return fixture
        }
        guard let fixture = fixtures.first(where: { $0.id != first.id && $0.sourceFormat != "flac" }) else {
            throw ToolError.message("manifest has no second fixture for crossfader-sweep")
        }
        return fixture
    }

    private static func renderCrossfaderSweep(
        first: (PCMBuffer, TrackAnalysis),
        second: (PCMBuffer, TrackAnalysis),
        sourceFormat: String,
        maximumSeconds: TimeInterval
    ) throws -> Rendering {
        let sampleRate = 48_000.0
        let requestedDuration = maximumSeconds > 0 && maximumSeconds.isFinite ? maximumSeconds : 30
        let duration = min(requestedDuration, 60)
        let frameCount = max(1, Int(duration * sampleRate))
        let engine = HeadlessDJEngine(sampleRate: sampleRate, maxFramesPerRender: 512)
        engine.deckA.load(first.1, buffer: first.0)
        engine.deckB.load(second.1, buffer: second.0)
        engine.mixer.crossfader = -1
        engine.deckA.play()
        engine.deckB.play()

        var left = [Float]()
        var right = [Float]()
        left.reserveCapacity(frameCount)
        right.reserveCapacity(frameCount)
        let blockSize = 512
        while left.count < frameCount {
            let time = Double(left.count) / sampleRate
            engine.mixer.crossfader = crossfaderValue(at: time, duration: duration)
            let block = engine.render(frames: min(blockSize, frameCount - left.count))
            left.append(contentsOf: block.left)
            right.append(contentsOf: block.right)
        }
        let output = PCMBuffer(format: AudioFormat(sampleRate: sampleRate, channelCount: 2), capacity: frameCount)
        for frame in 0..<frameCount {
            output.channel(0)[frame] = left[frame]
            output.channel(1)[frame] = right[frame]
        }
        return Rendering(
            buffer: output,
            waveform: WaveformGenerator().generate(output),
            sourceFormat: sourceFormat,
            renderedScenario: "headless-crossfader-sweep",
            events: [
                EventPoint(time: 0, type: "deck-a-play", deck: 0, value: nil),
                EventPoint(time: 0, type: "deck-b-play", deck: 1, value: nil),
                EventPoint(time: 0, type: "crossfader", deck: nil, value: -1),
                EventPoint(time: min(5, duration), type: "crossfader-ramp-start", deck: nil, value: -1),
                EventPoint(time: min(15, duration), type: "crossfader-ramp-end", deck: nil, value: 1),
            ],
            notes: [
                "Audio is the actual stereo output of HeadlessDJEngine with both decks playing.",
                "Crossfader is held at -1 for 5 seconds, swept to +1 over 10 seconds, then held at +1.",
                "Beat and section annotations are from fixture-a; inspect the event timeline alongside the audio."
            ]
        )
    }

    private static func crossfaderValue(at time: TimeInterval, duration: TimeInterval) -> Double {
        if time <= 5 || duration <= 5 { return -1 }
        if time >= min(15, duration) { return 1 }
        return -1 + 2 * ((time - 5) / 10)
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
        let fixtureBID: String?
        let maximumSeconds: TimeInterval

        init(arguments: [String]) throws {
            var values: [String: String] = [:]
            var index = 0
            while index < arguments.count {
                let argument = arguments[index]
                guard argument.hasPrefix("--"), index + 1 < arguments.count else {
                    throw ToolError.usage("usage: swift run ParsoAcceptanceArtifacts --fixture ID [--fixture-b ID] [--scenario waveform|phrase|crossfader-sweep] [--output-dir DIR] [--max-seconds N]")
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
            self.fixtureBID = values["fixture-b"]
            self.maximumSeconds = TimeInterval(values["max-seconds"] ?? "30") ?? 30
        }
    }
}
