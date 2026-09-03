import Testing
import Foundation
@testable import ParsoAudioPlayback

@Suite("ReplayGainReader")
struct ReplayGainReaderTests {
    @Test("parses Vorbis-comment style items")
    func vorbisComments() {
        let tags = ReplayGainReader.parse(items: [
            .init(key: "REPLAYGAIN_TRACK_GAIN", stringValue: "-6.48 dB"),
            .init(key: "REPLAYGAIN_TRACK_PEAK", stringValue: "0.988553"),
            .init(key: "REPLAYGAIN_ALBUM_GAIN", stringValue: "-7.02 dB"),
        ])
        #expect(tags.trackGainDB == -6.48)
        #expect(tags.trackPeak == 0.988553)
        #expect(tags.albumGainDB == -7.02)
    }

    @Test("parses iTunes ---- atom payloads by string match")
    func itunesAtoms() {
        let tags = ReplayGainReader.parse(items: [
            .init(identifier: "com.apple.iTunes", stringValue: "replaygain_track_gain=+3.21 dB"),
        ])
        #expect(tags.trackGainDB == 3.21)
    }

    @Test("comma decimal separator")
    func commaDecimal() {
        let tags = ReplayGainReader.parse(items: [.init(key: "replaygain_track_gain", stringValue: "-4,5 dB")])
        #expect(tags.trackGainDB == -4.5)
    }

    @Test("no tags -> empty")
    func empty() {
        #expect(ReplayGainReader.parse(items: [.init(key: "TITLE", stringValue: "x")]).isEmpty)
    }
}

@Suite("NormalizationPlanner")
struct NormalizationPlannerTests {
    @Test("off mode is unity")
    func off() {
        let p = NormalizationPlanner(mode: .off)
        #expect(p.gain(from: ReplayGainTags(trackGainDB: -6)) == 1)
    }

    @Test("track gain -> linear")
    func trackGain() {
        let p = NormalizationPlanner(mode: .track)
        #expect(abs(p.gain(from: ReplayGainTags(trackGainDB: -6)) - pow(10, -6.0 / 20)) < 1e-12)
    }

    @Test("album mode falls back to track gain")
    func albumFallback() {
        let p = NormalizationPlanner(mode: .album)
        #expect(abs(p.gain(from: ReplayGainTags(trackGainDB: -6)) - pow(10, -6.0 / 20)) < 1e-12)
    }

    @Test("clipping prevention caps gain at 1/peak")
    func clipping() {
        let p = NormalizationPlanner(mode: .track, preampDB: 12)
        let g = p.gain(from: ReplayGainTags(trackGainDB: 6, trackPeak: 0.9))
        #expect(abs(g - 1 / 0.9) < 1e-12)
    }

    @Test("measured LUFS path: gain is reference - measured")
    func measured() {
        let p = NormalizationPlanner(mode: .track, referenceLUFS: -18)
        #expect(abs(p.gain(fromIntegratedLUFS: -12) - pow(10, -6.0 / 20)) < 1e-12)
    }

    @Test("tags preferred over measurement, measurement used when no tag")
    func preference() {
        let p = NormalizationPlanner(mode: .track, referenceLUFS: -18)
        // has tag -> tag wins
        let withTag = p.gain(from: ReplayGainTags(trackGainDB: -3), orIntegratedLUFS: -30)
        #expect(abs(withTag - pow(10, -3.0 / 20)) < 1e-12)
        // no tag -> measurement
        let noTag = p.gain(from: .empty, orIntegratedLUFS: -12)
        #expect(abs(noTag - pow(10, -6.0 / 20)) < 1e-12)
        // neither -> unity
        #expect(p.gain(from: .empty, orIntegratedLUFS: nil) == 1)
    }
}

@Suite("EQTapRegistry")
struct EQTapRegistryTests {
    final class Item {}

    @Test("one entry per identity; evict removes")
    func lifecycle() {
        let r = EQTapRegistry()
        let a = Item(), b = Item()
        #expect(r.attach(a) == true)
        #expect(r.attach(a) == false)
        #expect(r.attach(b) == true)
        #expect(r.count == 2)
        #expect(r.isAttached(a))
        #expect(r.evict(a) == true)
        #expect(r.evict(a) == false)
        #expect(r.count == 1)
        r.evictAll()
        #expect(r.isEmpty)
    }
}
