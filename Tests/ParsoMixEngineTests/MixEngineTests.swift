//
//  MixEngineTests.swift
//  Timing, stereo and blend-curve behaviour of the stereo blend player.
//

import Testing
import Foundation
import ParsoAudioCore
import ParsoAudioAnalysis
import ParsoMixEngine

private let sr = 44_100.0

/// Stereo buffer with a short, sharp click every `spacing` frames (left and
/// right identical unless `rightScale` differs).
private func clickTrain(frames: Int, spacing: Int, rightScale: Float = 1) -> PCMBuffer {
    let buffer = PCMBuffer(format: AudioFormat(sampleRate: sr, channelCount: 2), capacity: frames)
    let left = buffer.channel(0), right = buffer.channel(1)
    // A quiet tone bed: real music is never silent, and Signalsmith passes long
    // silences straight through (which would not test its timing).
    for n in 0..<frames {
        let bed = 0.02 * Float(sin(2 * Double.pi * 220 * Double(n) / sr))
        left[n] = bed
        right[n] = bed * rightScale
    }
    var i = spacing / 2
    while i + 64 < frames {
        for k in 0..<64 {   // 64-sample decaying 3 kHz burst
            let v = Float(sin(2 * Double.pi * 3_000 * Double(k) / sr) * exp(-Double(k) / 12))
            left[i + k] += v
            right[i + k] += v * rightScale
        }
        i += spacing
    }
    return buffer
}

private func tone(frames: Int, hz: Double, amplitude: Float) -> PCMBuffer {
    let buffer = PCMBuffer(format: AudioFormat(sampleRate: sr, channelCount: 2), capacity: frames)
    let left = buffer.channel(0), right = buffer.channel(1)
    for i in 0..<frames {
        let v = amplitude * Float(sin(2 * Double.pi * hz * Double(i) / sr))
        left[i] = v
        right[i] = v
    }
    return buffer
}

/// Onset frames (first sample of each burst above a threshold after silence).
private func onsets(_ x: [Float], threshold: Float = 0.2, refractory: Int = 2_000) -> [Int] {
    var out: [Int] = []
    var last = -refractory
    for (i, v) in x.enumerated() where abs(v) >= threshold && i - last >= refractory {
        out.append(i)
        last = i
    }
    return out
}

/// RMS of `hz` in x[from..<to] (single-bin DFT, amplitude units).
private func level(_ x: [Float], hz: Double, from: Int, to: Int) -> Double {
    var re = 0.0, im = 0.0
    for i in from..<to {
        let w = 2 * Double.pi * hz * Double(i) / sr
        re += Double(x[i]) * cos(w); im += Double(x[i]) * sin(w)
    }
    return 2 * sqrt(re * re + im * im) / Double(to - from)
}

@Suite("Mix engine")
@MainActor
struct MixEngineTests {
    @Test func deckStartsOnItsExactFrameInsideABlock() throws {
        let engine = try MixEngine(sampleRate: sr)
        let source = tone(frames: 44_100, hz: 3_000, amplitude: 0.5)
        try engine.prepare(.a, buffer: source, sourcePosition: 0, tempo: 1)
        try engine.start(.a, atFrame: 1_000)   // 1000 = block 1 (512) + 488
        let out = engine.render(frames: 4_096)
        #expect(out.left[..<1_000].allSatisfy { $0 == 0 })
        #expect(out.left[1_000..<1_100].contains { $0 != 0 })
    }

    @Test func stereoIsKept() throws {
        let engine = try MixEngine(sampleRate: sr)
        let source = clickTrain(frames: 88_200, spacing: 11_025, rightScale: 0.25)
        try engine.prepare(.a, buffer: source, sourcePosition: 0, tempo: 1)
        try engine.start(.a, atFrame: 0)
        let out = engine.render(frames: 88_200)
        let l = out.left.map { abs($0) }.max() ?? 0, r = out.right.map { abs($0) }.max() ?? 0
        #expect(abs(r / l - 0.25) < 0.02)
    }

    /// The keylocked stretcher is primed so its first output is the start
    /// position, and its input is clocked from the master frame: the output
    /// lines up with an exact resample of the source at the start and still
    /// does a minute later (no latency, no drift).
    @Test(arguments: [1.0, 1.0015, 1.008, 1.0164, 0.9777, 1.04])
    func outputStaysOnTheTempoClock(tempo: Double) throws {
        let engine = try MixEngine(sampleRate: sr)
        let source = clickTrain(frames: Int(sr * 80), spacing: 22_050)
        let startPosition = 3_000.0, startFrame = 777
        try engine.prepare(.a, buffer: source, sourcePosition: startPosition, tempo: tempo)
        #expect(engine.isKeylocked(.a) == (abs(tempo - 1) > 0.002))
        try engine.start(.a, atFrame: Int64(startFrame))
        let n = Int(sr * 70)
        let out = engine.render(frames: n).left
        let reference = exactResample(source, frames: n, startFrame: startFrame,
                                      startPosition: startPosition, tempo: tempo)
        for (from, to) in [(startFrame + 2_000, startFrame + Int(sr * 10)), (n - Int(sr * 10), n - 2_000)] {
            let lag = envelopeLag(out, reference, from: from, to: to)
            #expect(abs(lag) < 0.5, "lag \(lag) ms at tempo \(tempo), frames \(from)..<\(to)")
        }
    }

    /// The bass-swap recipe: incoming highs in over 4 bars, basses swap on the
    /// midpoint downbeat, outgoing highs out over the last 4 bars; then the
    /// outgoing deck is released.
    @Test func bassSwapCurves() throws {
        let engine = try MixEngine(sampleRate: sr)
        let frames = Int(sr * 60)
        // Outgoing: 55 Hz bass + 2 kHz high. Incoming: 70 Hz bass + 3 kHz high.
        let a = tone(frames: frames, hz: 55, amplitude: 0.3), b = tone(frames: frames, hz: 70, amplitude: 0.3)
        for i in 0..<frames {
            a.channel(0)[i] += 0.2 * Float(sin(2 * Double.pi * 2_000 * Double(i) / sr)); a.channel(1)[i] = a.channel(0)[i]
            b.channel(0)[i] += 0.2 * Float(sin(2 * Double.pi * 3_000 * Double(i) / sr)); b.channel(1)[i] = b.channel(0)[i]
        }
        let fpb = sr * 0.5, start = sr * 2.0
        try engine.prepare(.a, buffer: a, sourcePosition: 0, tempo: 1)
        try engine.start(.a, atFrame: 0)
        try engine.prepare(.b, buffer: b, sourcePosition: 0, tempo: 1)
        try engine.start(.b, atFrame: Int64(start))
        engine.scheduleBassSwap(from: .a, to: .b, startFrame: start, framesPerBeat: fpb, overlapBeats: 64)
        let out = engine.render(frames: Int(start + 64 * fpb + sr * 2)).left
        func window(_ beat: Double) -> (Int, Int) {
            let c = Int(start + beat * fpb); return (c - 4_410, c + 4_410)
        }
        // Beat 8: incoming highs half in, no incoming bass, outgoing full.
        var (f, t) = window(8)
        #expect(level(out, hz: 70, from: f, to: t) < 0.01)
        #expect(level(out, hz: 55, from: f, to: t) > 0.25)
        #expect(abs(level(out, hz: 3_000, from: f, to: t) - 0.1) < 0.03)
        // Beat 31 (before the swap) vs beat 33 (after): basses exchanged.
        (f, t) = window(30.5)
        #expect(level(out, hz: 55, from: f, to: t) > 0.25 && level(out, hz: 70, from: f, to: t) < 0.02)   // LR4 leaves ~4.5 % of 70 Hz in the high band
        (f, t) = window(33)
        #expect(level(out, hz: 70, from: f, to: t) > 0.25 && level(out, hz: 55, from: f, to: t) < 0.01)
        // Beat 56: outgoing highs half out.
        (f, t) = window(56)
        #expect(abs(level(out, hz: 2_000, from: f, to: t) - 0.1) < 0.03)
        // After the blend: incoming alone, outgoing released.
        (f, t) = window(65)
        #expect(level(out, hz: 2_000, from: f, to: t) < 0.005 && level(out, hz: 3_000, from: f, to: t) > 0.18)
        #expect(engine.state(of: .a) == .finished)
        #expect(engine.state(of: .b) == .playing)
    }

    /// The crossover is in the path from the first sample, so a deck that is
    /// never touched by a recipe still sums flat (all-pass magnitude).
    @Test func crossoverSumsFlat() throws {
        let engine = try MixEngine(sampleRate: sr)
        for hz in [60.0, 150.0, 400.0, 5_000.0] {
            try engine.prepare(.a, buffer: tone(frames: 44_100, hz: hz, amplitude: 0.5), sourcePosition: 0, tempo: 1)
            try engine.start(.a, atFrame: engine.masterFrame)
            let start = Int(engine.masterFrame)
            let out = engine.render(frames: 22_050).left
            _ = start
            #expect(abs(level(out, hz: hz, from: 11_025, to: 22_050) - 0.5) < 0.01, "\(hz) Hz")
            engine.stop(.a)
            _ = engine.render(frames: 512)
            engine.reset(.a)
        }
    }
}

/// The source read at position startPosition + (m - startFrame) * tempo.
private func exactResample(_ source: PCMBuffer, frames: Int, startFrame: Int, startPosition: Double,
                           tempo: Double) -> [Float] {
    let src = source.channel(0)
    var ref = [Float](repeating: 0, count: frames)
    for m in startFrame..<frames {
        let p = startPosition + Double(m - startFrame) * tempo
        let i = Int(p), f = Float(p - Double(i))
        if i >= 0, i + 1 < source.frameCount { ref[m] = src[i] * (1 - f) + src[i + 1] * f }
    }
    return ref
}

/// Lag (ms) of x behind y over [from, to), from smoothed energy envelopes.
private func envelopeLag(_ x: [Float], _ y: [Float], from: Int, to: Int) -> Double {
    func envelope(_ v: [Float]) -> [Double] {
        var e = [Double](repeating: 0, count: v.count), s = 0.0
        for i in v.indices { s = 0.995 * s + 0.005 * Double(v[i] * v[i]); e[i] = s }
        return e
    }
    let ex = envelope(x), ey = envelope(y)
    var best = (lag: 0, score: -Double.infinity)
    for lag in -600...600 {
        var s = 0.0
        for i in stride(from: from + 600, to: to - 600, by: 4) { s += ex[i] * ey[i - lag] }
        if s > best.score { best = (lag, s) }
    }
    return Double(best.lag) / sr * 1_000
}

@Suite("Blend planning")
struct BlendPlanningTests {
    private func played(bpm: Double, seconds: Double) -> (PCMBuffer, BlendTrackAnalysis) {
        let period = 60 / bpm
        let audio = clickTrain(frames: Int(seconds * sr), spacing: Int((period * sr).rounded()))
        let analysis = BlendAnalyzer.analyze(audio, grid: BlendGrid(period: period, phase: period / 2, sharpness: 1))
        return (audio, analysis)
    }

    @Test func farTempoIsACutAtTheIncomingsOwnTempo() throws {
        let (a, aa) = played(bpm: 128, seconds: 90)
        let (b, ab) = played(bpm: 100, seconds: 60)
        let result = try #require(BlendPlanner.planBlend(outgoing: PlayedTrack(source: a, analysis: aa),
                                                         incoming: ab, incomingAudio: b))
        #expect(result.plans.map(\.style) == [BlendPlan.Style.phraseCut])
        #expect(result.plans[0].tempo == 1)
        #expect(result.incoming.audio.channelCount == 1)
        #expect(result.incoming.audio.frameCount == b.frameCount)
        #expect(result.incoming.analysis == ab)
    }

    @Test func incomingIsReturnedAsItWillPlay() throws {
        let (a, aa) = played(bpm: 126, seconds: 90)
        let (b, ab) = played(bpm: 124, seconds: 60)
        let result = try #require(BlendPlanner.planBlend(outgoing: PlayedTrack(source: a, analysis: aa),
                                                         incoming: ab, incomingAudio: b))
        let tempo = try #require(result.plans.first?.tempo)
        #expect(abs(tempo - 126.0 / 124.0) < 1e-9)
        #expect(result.incoming.audio.channelCount == 1)
        #expect(result.incoming.audio.frameCount == Int((Double(b.frameCount) / tempo).rounded(.down)))
        #expect(abs(result.incoming.analysis.grid.period - 60.0 / 126) < 1e-9)
    }
}
