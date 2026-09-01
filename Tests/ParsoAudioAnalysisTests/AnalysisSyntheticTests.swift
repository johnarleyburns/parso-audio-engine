//
//  AnalysisSyntheticTests.swift
//  Ground-truth analysis tests on synthesized signals. The KeyProfiles sanity suite runs now;
//  estimator suites are `.disabled` until implemented (docs/SPEC.md §10).
//

import Testing
import Foundation
import ParsoAudioCore
import ParsoAudioAnalysis
import ParsoTestSupport

// MARK: - Real now (constants only)

@Suite("Key profiles")
struct KeyProfileTests {
    @Test func profilesHaveTwelveBins() {
        #expect(KeyProfiles.major.count == 12)
        #expect(KeyProfiles.minor.count == 12)
        #expect(KeyProfiles.pitchClassNames.count == 12)
    }
    @Test func tonicIsTheStrongestDegree() {
        #expect(KeyProfiles.major.firstIndex(of: KeyProfiles.major.max()!) == 0)
        #expect(KeyProfiles.minor.firstIndex(of: KeyProfiles.minor.max()!) == 0)
    }
}

// MARK: - Pending implementation (docs/SPEC.md §10)

@Suite("Tempo (synthetic)")
struct TempoSyntheticTests {
    @Test(arguments: [90.0, 100.0, 120.0, 124.0, 128.0, 140.0, 174.0])
    func detectsClickTrackTempo(bpm: Double) {
        let track = SignalGenerators.clickTrack(bpm: bpm, seconds: 20)
        let r = TempoEstimator().analyze(track)
        // Accept exact, or half/double (octave) resolution.
        let candidates = [r.bpm, r.bpm * 2, r.bpm / 2]
        #expect(candidates.contains { abs($0 - bpm) <= 1.0 })
        #expect(r.confidence > 0.3)
    }

    @Test func reportsBeatPositionsAlignedToClicks() {
        let bpm = 120.0
        let r = TempoEstimator().analyze(SignalGenerators.clickTrack(bpm: bpm, seconds: 10))
        #expect(!r.beatPositions.isEmpty)
        if r.beatPositions.count >= 2 {
            let period = r.beatPositions[1] - r.beatPositions[0]
            #expect(abs(period - 60.0 / bpm) < 0.02)
        }
    }
}

@Suite("Key (synthetic)", .disabled("Implement KeyEstimator — docs/SPEC.md §10.3"))
struct KeySyntheticTests {
    @Test(arguments: [0, 5, 7, 9])   // C, F, G, A
    func detectsMajorTriadTonic(tonic: Int) {
        let sig = SignalGenerators.triad(tonic: tonic, major: true, seconds: 6)
        let r = KeyEstimator().analyze(sig)
        #expect(r.tonic == tonic)
        #expect(r.mode == .major)
    }

    @Test func detectsMinorMode() {
        let r = KeyEstimator().analyze(SignalGenerators.triad(tonic: 9, major: false, seconds: 6)) // A minor
        #expect(r.tonic == 9)
        #expect(r.mode == .minor)
    }
}

@Suite("Structure (synthetic)", .disabled("Implement StructureAnalyzer — docs/SPEC.md §10.4"))
struct StructureSyntheticTests {
    @Test func findsEnergyBoundaries() {
        // silence -> low tone -> full-energy noise -> low tone
        let sig = SignalGenerators.concat([
            SignalGenerators.silence(seconds: 4),
            SignalGenerators.sine(frequency: 110, seconds: 8, amplitude: 0.1),
            SignalGenerators.whiteNoise(seconds: 8, amplitude: 0.5),
            SignalGenerators.sine(frequency: 110, seconds: 8, amplitude: 0.1),
        ])
        let tempo = TempoResult(bpm: 120, confidence: 1, beatPositions: [], downbeatPositions: [], isConstantTempo: true)
        let sections = StructureAnalyzer().analyze(sig, tempo: tempo)
        #expect(sections.count >= 3)
    }
}

@Suite("Waveform (synthetic)", .disabled("Implement WaveformGenerator — docs/SPEC.md §10.5"))
struct WaveformSyntheticTests {
    @Test func bucketInvariants() {
        let w = WaveformGenerator().generate(SignalGenerators.sine(frequency: 440, seconds: 2), overviewBuckets: 512)
        #expect(w.overviewMinMax.count == 512)
        for mm in w.overviewMinMax { #expect(mm.x <= mm.y) }   // min <= max
    }
}
