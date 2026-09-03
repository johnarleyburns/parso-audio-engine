//
//  PortedPipelineTests.swift
//  Stage-level determinism / behaviour tests for the Accelerate pipeline ported
//  from parso-tonearm (docs/UNIFICATION_PLAN.md §4 Phase 5). Adapted from
//  parso-tonearm's DSPTests / TempoBeatTests / KeyPhraseWaveformTests /
//  GoldenTempoBeatTests to swift-testing; the GRDB blob round-trip tests stay
//  in parso-tonearm (persistence).
//

import Testing
import Foundation
import Accelerate
import ParsoAudioCore
import ParsoAudioAnalysis

// MARK: - Synthetic signal helpers (48 kHz, no files)

private enum Synth {
    static let rate = 48_000.0

    /// Accented click track: a half-frame Hann-windowed 1 kHz burst per beat,
    /// louder on beat 1 of every bar. Returns mono @ 48 kHz.
    static func clickTrack(bpm: Double, seconds: Double, beatsPerBar: Int = 4) -> [Float] {
        let beatInterval = 60.0 / bpm
        var s = [Float](repeating: 0, count: Int(rate * seconds))
        var i = Int(0.5 * rate)
        var beat = 0
        while Double(i) / rate < seconds {
            let amp: Float = beat % beatsPerBar == 0 ? 0.9 : 0.45
            for j in 0..<2048 where i + j < s.count {
                let t = Double(j) / rate
                let hann = 0.5 - 0.5 * cos(2 * Double.pi * Double(j) / 2047)
                s[i + j] = amp * Float(sin(2 * Double.pi * 1000 * t)) * Float(hann)
            }
            i += Int(beatInterval * rate); beat += 1
        }
        return s
    }

    static func tone(_ freqs: [Double], seconds: Double) -> [Float] {
        var s = [Float](repeating: 0, count: Int(rate * seconds))
        for k in s.indices {
            var v: Float = 0
            for f in freqs { v += Float(sin(2 * Double.pi * f * Double(k) / rate)) }
            s[k] = v
        }
        return s
    }

    static func onsetEnvelope(_ samples: [Float]) -> ([Float], Double) {
        let cfg = STFTConfig()
        let spectra = samples.withUnsafeBufferPointer { STFTKernel(config: cfg).spectra($0) }
        return (OnsetDetector.envelope(spectra: spectra), Double(cfg.hopSize) / cfg.sampleRate)
    }
}

// MARK: - STFT

@Suite("Ported STFT")
struct PortedSTFTTests {
    @Test func pureTonePeaksAtExpectedBin() {
        let cfg = STFTConfig()
        let kernel = STFTKernel(config: cfg)
        var frame = [Float](repeating: 0, count: cfg.fftSize)
        for i in frame.indices { frame[i] = Float(sin(2 * Double.pi * 1000 * Double(i) / 48_000)) }
        let spec = frame.withUnsafeBufferPointer { kernel.spectrum($0.baseAddress!) }
        let expected = Int((1000 / spec.binHz).rounded())
        let peak = spec.power.indices.max { spec.power[$0] < spec.power[$1] } ?? 0
        #expect(peak == expected)
        #expect(spec.power.count == cfg.fftSize / 2)
    }

    @Test func spectraSlidesByHop() {
        let samples = Synth.tone([440], seconds: 2)
        let spectra = samples.withUnsafeBufferPointer { STFTKernel().spectra($0) }
        #expect(spectra.count > 40 && spectra.count < 50)
    }
}

// MARK: - Onset / Tempo / Beat

@Suite("Ported tempo + beat")
struct PortedTempoBeatTests {
    @Test(arguments: [90.0, 100.0, 124.0, 128.0])
    func combTempoMatchesClickTrack(bpm: Double) {
        let (env, hop) = Synth.onsetEnvelope(Synth.clickTrack(bpm: bpm, seconds: 8))
        let best = TempoAnalyzer.estimate(novelty: env, hopSeconds: hop).first
        #expect(best != nil)
        #expect(abs((best?.bpm ?? 0) - bpm) <= 1.0)
    }

    @Test func octaveErrorResolvesToTrueTempo() {
        let (env, hop) = Synth.onsetEnvelope(Synth.clickTrack(bpm: 120, seconds: 8))
        let best = TempoAnalyzer.estimate(novelty: env, hopSeconds: hop).first
        #expect(abs((best?.bpm ?? 0) - 120) <= 1.0)
    }

    @Test func rankingIsDeterministicAndDescending() {
        let (env, hop) = Synth.onsetEnvelope(Synth.clickTrack(bpm: 128, seconds: 8))
        let a = TempoAnalyzer.estimate(novelty: env, hopSeconds: hop, topK: 3)
        let b = TempoAnalyzer.estimate(novelty: env, hopSeconds: hop, topK: 3)
        #expect(a.map(\.rank) == [0, 1, 2])
        #expect(a.map(\.bpm) == b.map(\.bpm))          // deterministic
        #expect(a[0].confidence >= a[1].confidence)
    }

    @Test func gridLandsOnClickBeatsAndIsDeterministic() {
        let bpm = 124.0
        let (env, hop) = Synth.onsetEnvelope(Synth.clickTrack(bpm: bpm, seconds: 8))
        let peaks = OnsetDetector.peaks(env, frameRateHz: 1 / hop)
        let best = TempoAnalyzer.estimate(novelty: env, hopSeconds: hop).first!
        let g1 = BeatTracker.grid(novelty: env, hopSeconds: hop, sampleRate: 48_000,
                                  onsets: peaks, bpm: best.bpm)
        let g2 = BeatTracker.grid(novelty: env, hopSeconds: hop, sampleRate: 48_000,
                                  onsets: peaks, bpm: best.bpm)
        #expect(g1 != nil)
        #expect(g1?.beatSamples == g2?.beatSamples)
        #expect(abs((g1?.bpm ?? 0) - bpm) <= 0.5)
        #expect(g1?.isConstantTempo == true)
        // Steady-state beats sit ~0.484 s apart (124 BPM).
        if let g = g1, g.beatSamples.count > 6 {
            let dt = Double(g.beatSamples[5] - g.beatSamples[4]) / 48_000
            #expect(abs(dt - 60.0 / bpm) < 0.02)
        }
    }

    @Test func downbeatsPickTheAccentedOffset() {
        let (env, hop) = Synth.onsetEnvelope(Synth.clickTrack(bpm: 120, seconds: 8))
        let peaks = OnsetDetector.peaks(env, frameRateHz: 1 / hop)
        let best = TempoAnalyzer.estimate(novelty: env, hopSeconds: hop).first!
        let grid = BeatTracker.grid(novelty: env, hopSeconds: hop, sampleRate: 48_000,
                                    onsets: peaks, bpm: best.bpm)!
        let downbeats = BeatTracker.downbeats(beatSamples: grid.beatSamples, novelty: env,
                                              hopSeconds: hop, sampleRate: 48_000)
        #expect(!downbeats.isEmpty)
        #expect(downbeats.first == 0)
    }

    @Test func quietNoiseProducesFewOnsets() {
        var noise = [Float](repeating: 0, count: 48_000)
        var seed: UInt64 = 0x0A1B_2C3D
        for i in noise.indices {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            noise[i] = (Float(seed >> 40) / Float(1 << 24) - 0.5) * 0.01
        }
        let (env, hop) = Synth.onsetEnvelope(noise)
        #expect(OnsetDetector.peaks(env, frameRateHz: 1 / hop).count < 3)
    }
}

// MARK: - Key

@Suite("Ported key")
struct PortedKeyTests {
    private func chroma(_ freqs: [Double], seconds: Double) -> [HPCP] {
        let spectra = Synth.tone(freqs, seconds: seconds).withUnsafeBufferPointer { STFTKernel().spectra($0) }
        return spectra.map { KeyDetector.chroma($0) }
    }

    @Test func pureToneDetectsPitchClass() {
        let est = KeyDetector.estimate(chroma([440], seconds: 2))
        #expect(est?.tonic == 9)                        // A
        #expect(est?.musicalKey == "A major")
    }

    @Test func rootReinforcedAMajorChord() {
        let est = KeyDetector.estimate(chroma([220, 440, 880, 277.18, 554.37, 329.63, 659.25], seconds: 2))
        #expect(est?.tonic == 9)
        #expect(est?.isMinor == false)
        #expect(est?.camelot.code == "11B")
    }

    @Test func estimateIsDeterministic() {
        let frames = chroma([220, 440, 880, 277.18, 554.37, 329.63, 659.25], seconds: 2)
        #expect(KeyDetector.estimate(frames)?.tonic == KeyDetector.estimate(frames)?.tonic)
    }

    @Test func camelotWheelTable() {
        #expect(Camelot.from(tonic: 0, isMinor: false)?.code == "8B")   // C major
        #expect(Camelot.from(tonic: 9, isMinor: true)?.code == "8A")    // A minor
        #expect(Camelot.compatibility(CamelotKey(number: 8, letter: "A"),
                                      CamelotKey(number: 8, letter: "B")) == 0.9)
    }
}

// MARK: - Energy / Waveform / Phrase

@Suite("Ported energy + waveform + phrase")
struct PortedEnergyWaveformPhraseTests {
    @Test func energyCurveRisesWithAmplitude() {
        let rms = (0..<32).map { Float($0 + 1) / 32 }
        let beats = (0..<32).map { Int64($0 * 12_000) }
        let curve = EnergyAnalyzer.curve(frames: rms.map { SpectralFrame(rms: $0) },
                                         beatSamples: beats, frameRateHz: 4, sampleRate: 48_000)
        #expect(curve.count == 32)
        #expect(curve.allSatisfy { $0 >= 0 && $0 <= 1 })
        #expect((curve.first ?? 1) < (curve.last ?? 0))
        #expect(EnergyAnalyzer.scalar([Float](repeating: 0.8, count: 16)) == 8)
    }

    @Test func waveformPyramidShapeAndSymmetry() {
        var s = [Float](repeating: 0, count: 48_000)
        for i in s.indices { s[i] = Float(sin(2 * Double.pi * 440 * Double(i) / 48_000)) }
        let pyramid = s.withUnsafeBufferPointer { WaveformPyramidBuilder.build($0, sampleRate: 48_000) }
        #expect(pyramid.baseSamplesPerBin == 256)
        #expect(pyramid.levels.first?.count == Int(ceil(48_000.0 / 256.0)))
        #expect(pyramid.levels.count > 1)
        #expect(pyramid.levels.last!.count < pyramid.levels.first!.count)
        for bin in pyramid.levels[0].prefix(20) {
            #expect(abs(bin.min + bin.max) < 1e-3)      // symmetric envelope
        }
    }

    @Test func phraseSegmenterFindsIntroDropOutro() {
        var intro = HPCP(); intro[0] = 0.8; intro[4] = 0.2; intro[7] = 0.1; intro.normalize()
        var drop = HPCP(); drop[0] = 0.5; drop[4] = 0.3; drop[7] = 0.4; drop.normalize()
        var outro = HPCP(); outro[0] = 0.7; outro[3] = 0.3; outro[10] = 0.2; outro.normalize()
        let features = (0..<48).map { beat -> BeatFeature in
            let e: Float = beat < 16 ? 0.1 : (beat < 32 ? 0.9 : 0.1)
            return BeatFeature(chroma: beat < 16 ? intro : (beat < 32 ? drop : outro), energy: e)
        }
        let beats = (0..<48).map { Int64($0 * 12_000) }
        let phrases = PhraseSegmenter.segment(features: features, beats: beats,
                                              downbeats: Array(stride(from: 0, to: 48, by: 4)),
                                              sampleRate: 48_000)
        #expect(!phrases.isEmpty)
        #expect(phrases.first?.type == .intro)
        #expect(phrases.last?.type == .outro)
        #expect(phrases.allSatisfy { $0.startBeat % 4 == 0 && $0.energy >= 0 && $0.energy <= 10 })
    }
}

// MARK: - FullAnalysis orchestrator

@Suite("FullAnalysis")
struct FullAnalysisTests {
    @Test func runOverClickTrackPopulatesStages() {
        let samples = Synth.clickTrack(bpm: 128, seconds: 12)
        let audio = AnalysisAudio(sampleRate: 48_000, channels: [samples])
        let r = FullAnalysis.run(audio)
        #expect(r.hopSeconds > 0)
        #expect(r.bpm != nil)
        #expect(abs((r.bpm ?? 0) - 128) <= 2)
        #expect(r.beatGrid != nil)
        #expect(r.waveform != nil)
        #expect(r.loudness.integratedLUFS.isFinite)
        // Determinism.
        let r2 = FullAnalysis.run(AnalysisAudio(sampleRate: 48_000, channels: [samples]))
        #expect(r.beatGrid?.beatSamples == r2.beatGrid?.beatSamples)
    }

    @Test func emptyAudioDegradesGracefully() {
        let r = FullAnalysis.run(AnalysisAudio(sampleRate: 48_000, channels: [[]]))
        #expect(r.bpm == nil)
        #expect(r.beatGrid == nil)
        #expect(r.phrases.isEmpty)
    }
}
