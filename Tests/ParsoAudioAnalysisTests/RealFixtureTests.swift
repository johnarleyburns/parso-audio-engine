//
//  RealFixtureTests.swift
//  Uses the Creative Commons tracks from Tests/Fixtures/fixtures.json.
//
//  • Manifest-integrity tests run immediately (no audio needed).
//  • Decode + analysis tests are gated on `FixtureLibrary.isAvailable` (auto-skip until you run
//    `scripts/download-fixtures.sh`) AND `.disabled` until the relevant layer is implemented.
//
//  Test names beginning with "RealFixture" match the CI filter `swift test --filter RealFixture`.
//

import Testing
import Foundation
import ParsoAudioCore
import ParsoAudioAnalysis
import ParsoTestSupport

// MARK: - Runs now: fixture wiring is correct

@Suite("RealFixture manifest")
struct FixtureManifestTests {
    @Test func manifestLoadsAndHasTracks() {
        #expect(FixtureLibrary.all.count >= 18)
    }

    @Test func idsAreUnique() {
        let ids = FixtureLibrary.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyTrackHasSupportedContainer() {
        let supported: Set<String> = ["flac", "oggVorbis", "opus", "mp3", "wav", "aiff", "caf", "m4a"]
        for f in FixtureLibrary.all { #expect(supported.contains(f.sourceFormat)) }
    }

    @Test func plausibleRangeCoversHouseDiscoHipHopLofi() {
        let r = FixtureLibrary.plausibleBPMRange
        #expect(r.contains(72))    // lofi / hip-hop
        #expect(r.contains(115))   // disco
        #expect(r.contains(126))   // house
    }

    @Test func corpusSpansMultipleGenres() {
        let genres = Set(FixtureLibrary.all.compactMap(\.genre))
        #expect(genres.contains("house"))
        #expect(genres.contains("hip-hop"))
        #expect(genres.contains("disco"))
    }
}

// MARK: - Gated: real decode paths (docs/SPEC.md §9)

@Suite("RealFixture decode", .disabled("Implement AudioFileReader — docs/SPEC.md §9"))
struct FixtureDecodeTests {
    @Test(.enabled(if: FixtureLibrary.isAvailable), arguments: FixtureLibrary.all)
    func decodesToNonEmptyPCM(_ fixture: Fixture) throws {
        try withKnownIssueIfMissing(fixture) {
            let reader = try AudioFileReader(url: FixtureLibrary.url(for: fixture))
            let pcm = try reader.readAll()
            #expect(pcm.frameCount > 0)
            #expect(pcm.format.sampleRate >= 8_000)
            #expect(Measure.peak(pcm) > 0)
        }
    }
}

// MARK: - Gated: BPM (docs/SPEC.md §10.2)

@Suite("RealFixture BPM", .disabled("Implement TempoEstimator — docs/SPEC.md §10.2"))
struct FixtureTempoTests {
    /// Analysis must be deterministic for identical input.
    @Test(.enabled(if: FixtureLibrary.isAvailable), arguments: FixtureLibrary.beatBased)
    func bpmIsDeterministicAndPlausible(_ fixture: Fixture) throws {
        let pcm = try AudioFileReader(url: FixtureLibrary.url(for: fixture)).readAll()
        let a = TempoEstimator().analyze(pcm)
        let b = TempoEstimator().analyze(pcm)
        #expect(a.bpm == b.bpm)                                 // deterministic
        #expect(FixtureLibrary.plausibleBPMRange.contains(a.bpm))
        #expect(a.confidence > 0.2)

        // Strict regression once ground truth is filled in fixtures.json.
        if let expected = fixture.expected.bpm {
            let tol = fixture.expected.bpmTolerance ?? 2.0
            let candidates = [a.bpm, a.bpm * 2, a.bpm / 2]
            #expect(candidates.contains { abs($0 - expected) <= tol })
        }
    }
}

// MARK: - Gated: Key (docs/SPEC.md §10.3)

@Suite("RealFixture Key", .disabled("Implement KeyEstimator — docs/SPEC.md §10.3"))
struct FixtureKeyTests {
    @Test(.enabled(if: FixtureLibrary.isAvailable), arguments: FixtureLibrary.beatBased)
    func keyIsValidAndDeterministic(_ fixture: Fixture) throws {
        let pcm = try AudioFileReader(url: FixtureLibrary.url(for: fixture)).readAll()
        let a = KeyEstimator().analyze(pcm)
        let b = KeyEstimator().analyze(pcm)
        #expect((0...11).contains(a.tonic))
        #expect(a.tonic == b.tonic && a.mode == b.mode)        // deterministic
        #expect(!a.camelot.isEmpty)

        if let expectedKey = fixture.expected.key {
            #expect(a.camelot == expectedKey || a.openKey == expectedKey)
        }
    }
}

// MARK: - Gated: full pipeline sanity

@Suite("RealFixture full analysis", .disabled("Implement TrackAnalyzer — docs/SPEC.md §10"))
struct FixtureFullAnalysisTests {
    @Test(.enabled(if: FixtureLibrary.isAvailable))
    func analyzesEveryTrackWithoutCrashing() throws {
        for fixture in FixtureLibrary.all {
            let pcm = try AudioFileReader(url: FixtureLibrary.url(for: fixture)).readAll()
            let analysis = TrackAnalyzer(targetLUFS: FixtureLibrary.manifest.targetLUFS).analyze(pcm)
            #expect(analysis.duration > 0)
            #expect(analysis.waveform.overviewMinMax.count > 0)
        }
    }
}

// Helper: turn a missing on-disk file into a recorded known-issue rather than a hard failure,
// so a partial download does not fail the whole suite.
private func withKnownIssueIfMissing(_ fixture: Fixture, _ body: () throws -> Void) rethrows {
    if !FixtureLibrary.isPresent(fixture) {
        withKnownIssue("fixture not downloaded: \(fixture.id)") { }
        return
    }
    try body()
}
