import Accelerate
import Foundation
import ParsoAudioCore
import ParsoAudioAnalysis
import ParsoAudioNeural

private extension String {
    func leftPadded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

/// Human-listening acceptance for the Phase 7b CLAP semantic-search seam
/// (`CoreMLSemanticModel`, `SemanticPreprocess`, `SemanticPooling` —
/// `Sources/ParsoAudioNeural/Semantic.swift` and friends).
///
/// This is search, not a per-track effect, so the artifact is a ranked list:
/// embed every given fixture once, embed each text query once, rank by
/// cosine similarity, and print/write the ranking so a reviewer can listen
/// through it top-to-bottom and judge relevance. Uses the real CLAP
/// `.mlpackage` weights already converted for parso-tonearm (never shipped
/// in this repo — see ATTRIBUTION.md and Sources/ParsoAudioNeural/Semantic.swift).
@main
struct ParsoClapAcceptance {
    private struct Fixture: Decodable {
        let id: String
        let filename: String
    }

    private struct Manifest: Decodable { let tracks: [Fixture] }

    private struct RankedTrack: Encodable {
        let fixtureID: String
        let audioPath: String
        let score: Float
    }

    private struct QueryResult: Encodable {
        let query: String
        let ranked: [RankedTrack]
    }

    private struct Report: Encodable {
        let textModelPath: String
        let audioModelPath: String
        let fixturesEmbedded: [String]
        let results: [QueryResult]
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
            FileHandle.standardError.write(Data("ParsoClapAcceptance: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }

    private static func run(_ options: Options) async throws {
        let manifestURL = URL(fileURLWithPath: options.manifest)
        let manifest = try JSONDecoder().decode(Manifest.self, from: try Data(contentsOf: manifestURL))

        for path in [options.textModelPath, options.audioModelPath, options.vocabPath,
                     options.mergesPath, options.melFilterbankPath] {
            guard FileManager.default.fileExists(atPath: path) else {
                throw ToolError.message("required file not found: \(path)")
            }
        }

        let melFilterBank = try EmbeddingModelSpec.loadMelFilterBank(
            from: URL(fileURLWithPath: options.melFilterbankPath))
        let spec = EmbeddingModelSpec.musicCLAP(melFilterBank: melFilterBank)
        let tokenizer = try RoBERTaTokenizer(
            vocabURL: URL(fileURLWithPath: options.vocabPath),
            mergesURL: URL(fileURLWithPath: options.mergesPath))

        let textModel = CoreMLSemanticModel(
            kind: .text, url: URL(fileURLWithPath: options.textModelPath),
            spec: spec, tokenizer: tokenizer)
        let audioModel = CoreMLSemanticModel(
            kind: .audio, url: URL(fileURLWithPath: options.audioModelPath), spec: spec)

        guard await textModel.isAvailable(), await audioModel.isAvailable() else {
            throw ToolError.message("a CLAP model file is present on disk but not readable as an .mlpackage")
        }

        var trackEmbeddings: [(id: String, path: String, vector: [Float])] = []
        for id in options.fixtureIDs {
            guard let fixture = manifest.tracks.first(where: { $0.id == id }) else {
                throw ToolError.message("unknown fixture '\(id)'; check Tests/Fixtures/fixtures.json")
            }
            let audioURL = URL(fileURLWithPath: options.audioDirectory)
                .appendingPathComponent("\(fixture.id).\((fixture.filename as NSString).pathExtension)")
            guard FileManager.default.fileExists(atPath: audioURL.path) else {
                throw ToolError.message("fixture is not downloaded: \(audioURL.path)\nRun ./scripts/download-fixtures.sh first.")
            }
            print("embedding \(fixture.id) ...")
            let decoded = try AudioFileReader(url: audioURL).readAll()
            var channels: [[Float]] = []
            for c in 0..<decoded.channelCount { channels.append(Array(decoded.channel(c))) }
            let pcm = AnalysisAudio(sampleRate: decoded.format.sampleRate, channels: channels)

            let windows = try SemanticPreprocess.logMel(pcm: pcm, spec: spec)
            guard !windows.isEmpty else {
                throw ToolError.message("no audio to embed for fixture '\(fixture.id)'")
            }
            var vectors: [[Float]] = []
            vectors.reserveCapacity(windows.count)
            for window in windows {
                vectors.append(try await audioModel.embedAudio(logMel: window.logMel))
            }
            let pooled = SemanticPooling.pool(vectors, strategy: spec.pooling)
            trackEmbeddings.append((fixture.id, audioURL.path, pooled))
        }

        var results: [QueryResult] = []
        for query in options.queries {
            let raw = try await textModel.embedText(query)
            let textVector = SemanticPooling.l2Normalized(raw)
            let ranked = trackEmbeddings
                .map { entry -> RankedTrack in
                    var score: Float = 0
                    vDSP_dotpr(textVector, 1, entry.vector, 1, &score, vDSP_Length(textVector.count))
                    return RankedTrack(fixtureID: entry.id, audioPath: entry.path, score: score)
                }
                .sorted { $0.score > $1.score }
            results.append(QueryResult(query: query, ranked: ranked))
            print("\nquery: \"\(query)\"")
            for (rank, track) in ranked.enumerated() {
                let rankLabel = String(rank + 1).leftPadded(to: 2)
                let idLabel = track.fixtureID.padding(toLength: max(track.fixtureID.count, 32),
                                                      withPad: " ", startingAt: 0)
                let scoreLabel = String(format: "%.4f", track.score)
                print("  \(rankLabel). \(idLabel) \(scoreLabel)  \(track.audioPath)")
            }
        }

        try FileManager.default.createDirectory(at: options.outputDirectory, withIntermediateDirectories: true)
        let jsonURL = options.outputDirectory.appendingPathComponent("clap-ranking.json")
        let report = Report(
            textModelPath: options.textModelPath,
            audioModelPath: options.audioModelPath,
            fixturesEmbedded: trackEmbeddings.map(\.id),
            results: results,
            notes: [
                "Score is cosine similarity between the L2-normalized text query embedding and the " +
                "pooled per-track audio embedding (SemanticPooling.pool, strategy = \(spec.pooling)).",
                "Listen through each query's ranking top-to-bottom against audioPath and judge whether " +
                "the ranking matches the query's intent — this is a relevance review, not a numeric test."
            ]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: jsonURL, options: .atomic)
        print("\nreport: \(jsonURL.path)")
    }

    private struct Options {
        let manifest: String
        let audioDirectory: String
        let outputDirectory: URL
        let fixtureIDs: [String]
        let queries: [String]
        let textModelPath: String
        let audioModelPath: String
        let vocabPath: String
        let mergesPath: String
        let melFilterbankPath: String

        init(arguments: [String]) throws {
            var values: [String: String] = [:]
            var queries: [String] = []
            var index = 0
            let usage = "usage: swift run ParsoClapAcceptance --fixtures id1,id2,... " +
                "--query \"text\" [--query \"text2\" ...] --text-model PATH --audio-model PATH " +
                "--tokenizer-dir DIR --mel-filterbank PATH [--manifest PATH] [--audio-dir DIR] [--output-dir DIR]"
            while index < arguments.count {
                let argument = arguments[index]
                guard argument.hasPrefix("--"), index + 1 < arguments.count else {
                    throw ToolError.usage(usage)
                }
                let key = String(argument.dropFirst(2))
                let value = arguments[index + 1]
                if key == "query" {
                    queries.append(value)
                } else {
                    values[key] = value
                }
                index += 2
            }
            guard let fixturesRaw = values["fixtures"], !fixturesRaw.isEmpty else {
                throw ToolError.usage("--fixtures is required (comma-separated ids from Tests/Fixtures/fixtures.json)\n" + usage)
            }
            guard !queries.isEmpty else {
                throw ToolError.usage("at least one --query is required\n" + usage)
            }
            guard let textModelPath = values["text-model"], !textModelPath.isEmpty else {
                throw ToolError.usage("--text-model is required (path to CLAPTextEncoder.mlpackage)\n" + usage)
            }
            guard let audioModelPath = values["audio-model"], !audioModelPath.isEmpty else {
                throw ToolError.usage("--audio-model is required (path to CLAPAudioEncoder.mlpackage)\n" + usage)
            }
            guard let tokenizerDir = values["tokenizer-dir"], !tokenizerDir.isEmpty else {
                throw ToolError.usage("--tokenizer-dir is required (directory with vocab.json + merges.txt)\n" + usage)
            }
            guard let melFilterbankPath = values["mel-filterbank"], !melFilterbankPath.isEmpty else {
                throw ToolError.usage("--mel-filterbank is required (path to mel_filterbank_slaney_64.bin)\n" + usage)
            }
            self.fixtureIDs = fixturesRaw.split(separator: ",").map { String($0) }
            self.queries = queries
            self.textModelPath = textModelPath
            self.audioModelPath = audioModelPath
            self.vocabPath = tokenizerDir + "/vocab.json"
            self.mergesPath = tokenizerDir + "/merges.txt"
            self.melFilterbankPath = melFilterbankPath
            self.manifest = values["manifest"] ?? "Tests/Fixtures/fixtures.json"
            self.audioDirectory = values["audio-dir"] ?? "Tests/Fixtures/audio"
            self.outputDirectory = URL(fileURLWithPath: values["output-dir"] ?? "artifacts/acceptance")
        }
    }
}
