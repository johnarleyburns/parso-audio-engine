import Testing
import Foundation
@testable import ParsoAudioPlayback

/// The graphic-EQ DSP contract, carried over from Tonearm's `EQTests` and
/// Voxglass's equivalent: bit-transparent bypass, flat is a no-op, non-flat
/// curves actually change the signal, and Q is a caller-supplied parameter so
/// neither app's EQ sound shifts on adoption.
@Suite("GraphicEQ")
struct GraphicEQTests {
    private func signal(count: Int = 4096, sampleRate: Double = 48000) -> [Double] {
        (0..<count).map { i in
            let t = Double(i) / sampleRate
            return 0.5 * sin(2 * .pi * 1000 * t) + 0.3 * sin(2 * .pi * 4000 * t)
        }
    }

    @Test("bypass is bit-transparent")
    func bypassTransparent() {
        var eq = GraphicEQ(gains: [3, -2, 4, 0, 0, 1, 2, -3, 5, 0], bypassed: true)
        let input = signal()
        #expect(eq.render(input) == input)
    }

    @Test("flat curve is bit-transparent")
    func flatTransparent() {
        var eq = GraphicEQ(gains: Array(repeating: 0, count: GraphicEQ.bandCount))
        #expect(eq.isTransparent)
        let input = signal()
        #expect(eq.render(input) == input)
    }

    @Test("a non-flat band changes the signal")
    func nonFlatChanges() {
        var eq = GraphicEQ(gains: [0, 0, 0, 0, 0, 6, 0, 0, 0, 0])
        let input = signal()
        let output = eq.render(input)
        let maxDiff = zip(input, output).map { abs($0 - $1) }.max() ?? 0
        #expect(maxDiff > 0.001)
    }

    @Test("disengage restores exact transparency")
    func disengageRestores() {
        var eq = GraphicEQ(gains: Array(repeating: 5, count: 10))
        let input = signal()
        _ = eq.render(input)
        eq.reset()
        eq.bypassed = true
        #expect(eq.render(input) == input)
    }

    @Test("ISO 10-band centers")
    func isoBands() {
        #expect(GraphicEQ.isoBandFrequencies == [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000])
    }

    @Test("Q is a parameter — Voxglass's 1.0 and Tonearm's 1.41 differ")
    func qParameter() {
        let input = signal()
        var wide = GraphicEQ(q: 1.0, gains: [0, 0, 0, 0, 0, 6, 0, 0, 0, 0])
        var narrow = GraphicEQ(q: 1.41, gains: [0, 0, 0, 0, 0, 6, 0, 0, 0, 0])
        #expect(wide.render(input) != narrow.render(input))
    }

    @Test("gains shorter/longer than band count are fitted")
    func gainsFitted() {
        let short = GraphicEQ(gains: [1, 2, 3])
        #expect(short.gains.count == GraphicEQ.bandCount)
        #expect(short.gains.suffix(7).allSatisfy { $0 == 0 })
        let long = GraphicEQ(gains: Array(repeating: 1, count: 20))
        #expect(long.gains.count == GraphicEQ.bandCount)
    }

    @Test("stereo channels have independent filter state")
    func stereoIndependent() {
        var eq = GraphicEQ(gains: [0, 0, 0, 0, 0, 6, 0, 0, 0, 0])
        let l = eq.process(0.5, channel: 0)
        let r = eq.process(0.5, channel: 1)
        #expect(l == r) // first sample, both channels start from zero state
        _ = eq.process(0.3, channel: 0)
        // channel 1 state untouched by the extra channel-0 sample
        let r2 = eq.process(0.5, channel: 1)
        var ref = GraphicEQ(gains: [0, 0, 0, 0, 0, 6, 0, 0, 0, 0])
        _ = ref.process(0.5, channel: 1)
        #expect(r2 == ref.process(0.5, channel: 1))
    }
}

@Suite("GraphicEQSettings")
struct GraphicEQSettingsTests {
    @Test("normalize clamps to ±12 dB and pads to band count")
    func normalize() {
        let s = GraphicEQSettings(bands: [99, -99, 3], enabled: true).normalized()
        #expect(s.bands == [12, -12, 3, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test("effective gains are flat when disengaged")
    func effectiveWhenDisengaged() {
        let s = GraphicEQSettings(bands: Array(repeating: 6, count: 10), enabled: false)
        #expect(s.effectiveGains() == Array(repeating: 0, count: 10))
    }

    @Test("Codable round-trip")
    func codable() throws {
        let s = GraphicEQSettings(bands: [1, -2, 3, 0, 0, 0, 0, 0, 0, 0], enabled: true)
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(GraphicEQSettings.self, from: data) == s)
    }

    @Test("preset curves are 10 bands")
    func presetCurves() {
        let curves: [[Double]] = [GraphicEQPresetCurves.flat, GraphicEQPresetCurves.concertHall,
                                  GraphicEQPresetCurves.spoken, GraphicEQPresetCurves.seventyEight]
        for c in curves {
            #expect(c.count == GraphicEQ.bandCount)
        }
    }
}
