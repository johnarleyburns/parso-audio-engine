//
//  BlendAnalysisTests.swift
//  Beat grid, structure and groove readings used by automatic blends.
//

import Testing
import Foundation
import ParsoAudioCore
@testable import ParsoAudioAnalysis

private let sr = 44_100.0

/// A synthetic four-to-the-floor track: a 55 Hz kick with a fast pitch drop on
/// every beat from `firstBeat`, off-beat hats, and (after `dropBeat`) a bass
/// note under every beat (about +8 dB in the kick band). Stereo.
private func dance(bpm: Double, seconds: Double, firstBeat: Double, dropBeat: Int = .max) -> PCMBuffer {
    let frames = Int(seconds * sr)
    let buffer = PCMBuffer(format: AudioFormat(sampleRate: sr, channelCount: 2), capacity: frames)
    let left = buffer.channel(0), right = buffer.channel(1)
    let period = 60 / bpm
    var beat = 0
    var t = firstBeat
    var noise: UInt32 = 12_345
    while t < seconds - 1 {
        let start = Int(t * sr)
        for k in 0..<Int(0.25 * sr) where start + k < frames {
            let x = Double(k) / sr
            let kick = sin(2 * Double.pi * (55 * x + 60 * (1 - exp(-x * 30)) / 30)) * exp(-x * 9)
            left[start + k] += Float(0.6 * kick)
        }
        let hat = Int((t + period / 2) * sr)
        for k in 0..<Int(0.03 * sr) where hat + k < frames {
            noise = noise &* 1_664_525 &+ 1_013_904_223
            let v = (Double(noise) / Double(UInt32.max) * 2 - 1) * exp(-Double(k) / sr * 150)
            left[hat + k] += Float(0.15 * v)
        }
        if beat >= dropBeat {
            for k in 0..<Int(period * sr) where start + k < frames {
                left[start + k] += Float(0.5 * sin(2 * Double.pi * 49 * Double(start + k) / sr))
            }
        }
        beat += 1
        t += period
    }
    for i in 0..<frames { right[i] = left[i] }
    return buffer
}

@Suite("Blend analysis")
struct BlendAnalysisTests {
    @Test func gridFindsPeriodAndKickPhase() {
        let track = dance(bpm: 128, seconds: 90, firstBeat: 0.137)
        let a = BlendAnalyzer.analyze(track, approximateBPM: 127.5)
        #expect(abs(a.grid.bpm - 128) < 0.01, "bpm \(a.grid.bpm)")
        // The phase is where the kick attack rises in the kick band.
        let err = (a.grid.phase - 0.137).truncatingRemainder(dividingBy: a.grid.period)
        #expect(abs(err) < 0.006 || abs(abs(err) - a.grid.period) < 0.006, "phase \(a.grid.phase)")
    }

    @Test func dropIsFoundOnItsBeat() {
        let track = dance(bpm: 125, seconds: 80, firstBeat: 0.2, dropBeat: 64)
        let a = BlendAnalyzer.analyze(track, approximateBPM: 125)
        #expect(a.drops.contains { abs($0 - 64) <= 1 }, "drops \(a.drops)")
    }

    @Test func grooveOffsetReadsAShift() throws {
        let period = 60 / 126.0
        let a = dance(bpm: 126, seconds: 80, firstBeat: 0.1)
        let b = dance(bpm: 126, seconds: 80, firstBeat: 0.1 + 0.023)   // incoming 23 ms late
        let pa = try #require(Groove.profile(a, start: 5, beats: 128, period: period))
        let pb = try #require(Groove.profile(b, start: 5, beats: 128, period: period))
        let g = Groove.offset(outgoing: pa, incoming: pb, period: period)
        #expect(abs(g.lagBeats * period - 0.023) < 0.001, "lag \(g.lagBeats * period)")
        #expect(g.agreeing >= Groove.minimumAgreeing)
    }

    @Test func profileIsNilOffTheTrack() {
        let a = dance(bpm: 126, seconds: 30, firstBeat: 0.1)
        #expect(Groove.profile(a, start: 10, beats: 128, period: 60 / 126.0) == nil)
    }
}
