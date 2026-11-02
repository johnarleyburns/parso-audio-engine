//
//  DropDetectorTests.swift
//  Ground truth on a synthesized kick-band step: no audio fixture, no ML.
//

import Testing
import Foundation
import ParsoAudioAnalysis

@Suite("Drop detector (synthetic)")
struct DropDetectorTests {
    /// A beat grid at `bpm` over `beats` beats, every `beatSamples.count - 1` interval holding a
    /// kick-band (80 Hz) tone whose amplitude is `before` up to `stepBeat` and `after` from there.
    private func stepSignal(bpm: Double, beats: Int, stepBeat: Int, before: Float, after: Float,
                            sampleRate: Double = 48_000) -> (AnalysisAudio, [Int64]) {
        let period = 60.0 / bpm
        let beatSamples = (0...beats).map { Int64(Double($0) * period * sampleRate) }
        let frameCount = Int(beatSamples.last!) + Int(period * sampleRate)
        var mono = [Float](repeating: 0, count: frameCount)
        let w = 2.0 * Double.pi * 80.0 / sampleRate
        for i in 0..<frameCount {
            let beatIndex = Int(Double(i) / sampleRate / period)
            let amplitude = beatIndex >= stepBeat ? after : before
            mono[i] = amplitude * Float(sin(w * Double(i)))
        }
        return (AnalysisAudio(sampleRate: sampleRate, channels: [mono]), beatSamples)
    }

    @Test func detectsADropAtTheStep() {
        let (audio, beats) = stepSignal(bpm: 120, beats: 64, stepBeat: 32, before: 0.05, after: 0.9)
        let result = DropDetector.dropsAndExits(audio, beatSamples: beats)
        #expect(result.drops.contains { abs($0 - 32) <= 1 })
        #expect(result.exits.isEmpty)
    }

    @Test func detectsABassExitAtTheStep() {
        let (audio, beats) = stepSignal(bpm: 120, beats: 64, stepBeat: 32, before: 0.9, after: 0.05)
        let result = DropDetector.dropsAndExits(audio, beatSamples: beats)
        #expect(result.exits.contains { abs($0 - 32) <= 1 })
        #expect(result.drops.isEmpty)
    }

    @Test func steadyLevelHasNoEvents() {
        let (audio, beats) = stepSignal(bpm: 120, beats: 64, stepBeat: 32, before: 0.5, after: 0.5)
        let result = DropDetector.dropsAndExits(audio, beatSamples: beats)
        #expect(result.drops.isEmpty)
        #expect(result.exits.isEmpty)
    }

    @Test func tooFewBeatsYieldsNoEvents() {
        let (audio, beats) = stepSignal(bpm: 120, beats: 4, stepBeat: 2, before: 0.1, after: 0.9)
        let result = DropDetector.dropsAndExits(audio, beatSamples: beats)
        #expect(result.drops.isEmpty)
        #expect(result.bassLevelsDB.count == beats.count - 1)
    }
}
