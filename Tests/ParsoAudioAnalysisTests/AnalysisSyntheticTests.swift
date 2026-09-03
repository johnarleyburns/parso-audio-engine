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
        // The DP grid can compress the first beat toward the leading onset; the
        // steady-state interval is the meaningful check (mirrors the tolerance
        // in parso-tonearm's own beat-grid tests).
        if r.beatPositions.count >= 6 {
            let period = r.beatPositions[5] - r.beatPositions[4]
            #expect(abs(period - 60.0 / bpm) < 0.04)
        }
    }
}

@Suite("Key (synthetic)")
struct KeySyntheticTests {
    /// A root-anchored chord: the sustained triad plus its root one octave below.
    /// A bare equal-power triad (C-E-G) is genuinely ambiguous with its relative
    /// (A minor) to a template-correlation key finder — the bass is the cue that
    /// disambiguates, exactly as `parso-tonearm`'s own key tests reinforce the
    /// root register.
    private func rootedChord(tonic: Int, major: Bool, seconds: Double) -> PCMBuffer {
        let triad = SignalGenerators.triad(tonic: tonic, major: major, seconds: seconds)
        let rootHz = 261.63 / 2 * pow(2.0, Double(tonic) / 12.0)
        let bass = SignalGenerators.sine(frequency: rootHz, seconds: seconds, amplitude: 0.25)
        let out = PCMBuffer(format: triad.format, capacity: triad.frameCount)
        let o = out.channel(0), t = triad.channel(0), b = bass.channel(0)
        for i in 0..<triad.frameCount { o[i] = t[i] + (i < bass.frameCount ? b[i] : 0) }
        return out
    }

    @Test(arguments: [0, 5, 7, 9])   // C, F, G, A
    func detectsMajorTriadTonic(tonic: Int) {
        let r = KeyEstimator().analyze(rootedChord(tonic: tonic, major: true, seconds: 6))
        #expect(r.tonic == tonic)
        #expect(r.mode == .major)
    }

    @Test func detectsMinorMode() {
        let r = KeyEstimator().analyze(rootedChord(tonic: 9, major: false, seconds: 6)) // A minor
        #expect(r.tonic == 9)
        #expect(r.mode == .minor)
    }
}

@Suite("Structure (synthetic)")
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

@Suite("Waveform (synthetic)")
struct WaveformSyntheticTests {
    @Test func bucketInvariants() {
        let w = WaveformGenerator().generate(SignalGenerators.sine(frequency: 440, seconds: 2), overviewBuckets: 512)
        #expect(w.overviewMinMax.count == 512)
        for mm in w.overviewMinMax { #expect(mm.x <= mm.y) }   // min <= max
    }
}
