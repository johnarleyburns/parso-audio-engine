//
//  FixtureLibrary.swift
//  Loads Tests/Fixtures/fixtures.json and locates downloaded audio. Real, dependency-free.
//  Real-fixture tests gate on `FixtureLibrary.isAvailable` so `swift test` stays green
//  (they auto-skip) when fixtures have not been downloaded.
//

import Foundation

public struct FixtureExpectation: Decodable, Sendable {
    public let bpm: Double?
    public let bpmTolerance: Double?
    public let key: String?
    public let confidenceFloor: Double?
}

public struct Fixture: Decodable, Sendable {
    public let id: String
    public let filename: String
    public let commonsPage: String
    public let sourceFormat: String       // flac | oggVorbis | opus | mp3 | wav | aiff
    public let genre: String?
    public let beatBased: Bool
    public let roles: [String]
    public let expected: FixtureExpectation

    /// On-disk extension used by the download script (`<id>.<ext>`).
    public var fileExtension: String { (filename as NSString).pathExtension }
}

public struct FixtureManifest: Decodable, Sendable {
    public let targetLUFS: Double
    public let plausibleBPMRange: [Double]
    public let tracks: [Fixture]

    enum CodingKeys: String, CodingKey { case targetLUFS, plausibleBPMRange, tracks }
}

public enum FixtureLibrary {

    /// Repo root derived from this file's path: …/Tests/Support/FixtureLibrary.swift
    public static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)          // .../Tests/Support/FixtureLibrary.swift
            .deletingLastPathComponent()         // .../Tests/Support
            .deletingLastPathComponent()         // .../Tests
            .deletingLastPathComponent()         // repo root
    }

    /// Downloaded audio directory (override with PARSO_FIXTURES_DIR).
    public static var audioDir: URL {
        if let env = ProcessInfo.processInfo.environment["PARSO_FIXTURES_DIR"] {
            return URL(fileURLWithPath: env, isDirectory: true)
        }
        return repoRoot.appendingPathComponent("Tests/Fixtures/audio", isDirectory: true)
    }

    public static let manifest: FixtureManifest = {
        let url = repoRoot.appendingPathComponent("Tests/Fixtures/fixtures.json")
        guard let data = try? Data(contentsOf: url),
              let m = try? JSONDecoder().decode(FixtureManifest.self, from: data)
        else {
            return FixtureManifest(targetLUFS: -14, plausibleBPMRange: [60, 190], tracks: [])
        }
        return m
    }()

    public static var all: [Fixture] { manifest.tracks }
    public static var beatBased: [Fixture] { manifest.tracks.filter { $0.beatBased } }

    /// Fixture files that this platform can decode through the package's native
    /// or portable/Apple-backed readers.
    public static var decodeFixtures: [Fixture] {
        return all
    }

    public static func withRole(_ role: String) -> [Fixture] {
        manifest.tracks.filter { $0.roles.contains(role) }
    }

    /// Local file URL for a downloaded fixture (may not exist yet).
    public static func url(for fixture: Fixture) -> URL {
        audioDir.appendingPathComponent("\(fixture.id).\(fixture.fileExtension)")
    }

    public static func isPresent(_ fixture: Fixture) -> Bool {
        FileManager.default.fileExists(atPath: url(for: fixture).path)
    }

    /// True when at least one fixture has been downloaded. Used to gate real-audio tests.
    public static var isAvailable: Bool { manifest.tracks.contains(where: isPresent) }

    public static var plausibleBPMRange: ClosedRange<Double> {
        let r = manifest.plausibleBPMRange
        return (r.first ?? 60)...(r.last ?? 190)
    }
}
