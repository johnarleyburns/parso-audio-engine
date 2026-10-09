//
//  BlendPlanner.swift
//  Where and how two tracks blend: a port of parso-tonearm/tools/blend-lab/djmix.py
//  ("dj2", approved by ear 2026-10-08).
//
//  1. The incoming track is tempo-matched once (keylocked) to the outgoing tempo.
//  2. Structure: drops and bass exits snapped to the track's bar phase (the 4-beat
//     phase most events share) and its phrase phase (32 beats).
//  3. Incoming swap point: its first drop with 4+ bars before it; a phrase line when
//     its bass is in from the start; later drops; phrase lines.
//  4. Outgoing swap point, best first: double drop (an outgoing drop in its second
//     half), bass exit (breakdown or outro), the latest phrase lines.
//  5. Placement by the groove (ParsoAudioAnalysis.Groove): the outgoing over the 128
//     beats before the blend, the incoming over the 128 after it; a candidate is
//     used only when 3 of 4 bands agree. None agrees: a phrase cut.
//

import Foundation
import ParsoAudioCore
import ParsoAudioAnalysis

public struct BlendPlan: Sendable, Equatable {
    public enum Style: String, Sendable { case doubleDrop = "double-drop", bassSwap = "bass-swap", phraseCut = "phrase-cut" }

    public var style: Style
    /// Outgoing beat period (s); the incoming plays at this tempo too.
    public var period: Double
    /// Incoming source seconds per output second (its keylocked tempo factor).
    public var tempo: Double
    /// Linear gain on the incoming track (loudness match).
    public var incomingGain: Double
    /// Outgoing-track time (s) where the blend starts, or the cut for a phrase cut.
    public var blendStart: Double
    /// Outgoing-track time (s) at which incoming source time 0 plays:
    /// incoming source time = (t - incomingOffset) * tempo.
    public var incomingOffset: Double
    public var overlapBeats: Int
    /// Outgoing-track time of the bass swap (the midpoint downbeat).
    public var swapTime: Double { blendStart + Double(overlapBeats / 2) * period }
    public var blendEnd: Double { blendStart + Double(overlapBeats) * period }
    /// Groove lag removed by the placement, and each band's onset lag (s).
    public var grooveLag: Double
    public var bandOnsetLags: [Double]
    /// How close the groove's runner-up alignment came (0..1); see GrooveOffset.
    public var rivalPeak: Double = 0
    public var reason: String
}

public enum BlendPlanner {
    public static let overlapBeats = 64
    public static let grooveBeats = 128
    static var half: Int { overlapBeats / 2 }

    /// A track's structure on its beat grid, in the time base of `scale`
    /// (1 for the outgoing; 1 / tempo for the incoming, i.e. output time).
    struct Track {
        let beats: [Double]              // output-time beat positions
        let sourceBeats: [Double]        // the track's own time
        let db: [Double]
        let bar: Int
        let phrase: Int
        let drops: [Int]
        let exits: [Int]
        var n: Int { beats.count }

        init(_ a: BlendTrackAnalysis, scale: Double, sourceScale: Double = 1) {
            sourceBeats = a.beats.map { $0 * sourceScale }
            beats = a.beats.map { $0 * scale }
            db = a.bassDB
            let events = a.drops + a.exits
            let weights = a.dropStepDB + a.exitStepDB
            let barPhase = Track.phaseOf(events, weights, 4)
            bar = barPhase
            phrase = Track.phaseOf(events.map { Track.snap($0, barPhase) }, weights, 32)
            drops = Array(Set(a.drops.map { Track.snap($0, barPhase) })).sorted()
            exits = Array(Set(a.exits.map { Track.snap($0, barPhase) })).sorted()
        }

        static func phaseOf(_ events: [Int], _ weights: [Double], _ mod: Int) -> Int {
            guard !events.isEmpty else { return 0 }
            var score = [Double](repeating: 0, count: mod)
            for (i, w) in zip(events, weights) { score[((i % mod) + mod) % mod] += w }
            var best = 0
            for k in 1..<mod where score[k] > score[best] { best = k }
            return best
        }

        static func snap(_ i: Int, _ ph: Int, mod: Int = 4) -> Int {
            let d = (((ph - i + mod / 2) % mod) + mod) % mod
            return i + d - mod / 2
        }
    }

    public struct Candidate: Sendable {
        public let plan: BlendPlan
    }

    /// Plans a blend from `outgoing` into `incoming` (decoded at the same sample
    /// rate). Returns the best plan of each overlapping style found (double drop
    /// first), or a single phrase cut when no candidate's groove can be trusted.
    /// `log` receives one line per rejected candidate.
    public static func plan(outgoing a: BlendTrackAnalysis, outgoingAudio: PCMBuffer,
                            incoming source: BlendTrackAnalysis, incomingAudio: PCMBuffer,
                            log: ((String) -> Void)? = nil) -> [BlendPlan] {
        let pa = a.grid.period
        let tempo = source.grid.period / pa
        // Like the lab: everything about the incoming is read from it as it will
        // sound, i.e. after the deck's keylocked tempo change (stretching moves
        // how a soft groove reads; deep house flipped half a beat without this).
        guard let stretched = MixEngine.renderTempo(incomingAudio, tempo: tempo) else { return [] }
        let b = BlendAnalyzer.analyze(stretched, grid: BlendGrid(period: pa, phase: source.grid.phase / tempo,
                                                                 sharpness: source.grid.sharpness))
        let A = Track(a, scale: 1)
        let B = Track(b, scale: 1, sourceScale: tempo)
        let gain = pow(10, (a.rmsDB - b.rmsDB) / 20)
        let silenceBeat = B.beats.firstIndex { $0 >= b.leadingSilence } ?? B.n

        var profilesA: [Int: GrooveProfile?] = [:]
        var profilesB: [Int: GrooveProfile?] = [:]
        func profileA(_ sa: Int) -> GrooveProfile? {
            if let p = profilesA[sa] { return p }
            let start = A.beats[sa - half] - Double(grooveBeats) * pa
            let p = Groove.profile(outgoingAudio, start: start, beats: grooveBeats, period: pa)
            profilesA[sa] = p
            return p
        }
        func profileB(_ sb: Int) -> GrooveProfile? {
            if let p = profilesB[sb] { return p }
            // After the blend: from the incoming's swap beat + half the overlap.
            let start = B.beats[sb] + Double(half) * pa
            let p = Groove.profile(stretched, start: start, beats: grooveBeats, period: pa)
            profilesB[sb] = p
            return p
        }

        var plans: [BlendPlan] = []
        var done = Set<BlendPlan.Style>()
        for (sa, style) in outgoingPoints(A) {
            let kind: BlendPlan.Style = style == "double drop" ? .doubleDrop : .bassSwap
            if done.contains(kind) { continue }
            for (sb, why) in incomingPoints(B, silenceBeat: silenceBeat) {
                if kind == .bassSwap && done.contains(.bassSwap) { break }
                let startA = A.beats[sa - half]
                let startB = B.beats[sb] - Double(half) * pa
                guard let ga = profileA(sa), let gb = profileB(sb) else {
                    log?("\(style) \(mmss(A.beats[sa])) x \(mmss(B.sourceBeats[sb])): window off the track")
                    continue
                }
                let g = Groove.offset(outgoing: ga, incoming: gb, period: pa)
                guard g.agreeing >= Groove.minimumAgreeing else {
                    log?("\(style) \(mmss(A.beats[sa])) x \(mmss(B.sourceBeats[sb])): bands disagree "
                         + g.bandOnsetBeats.map { String(format: "%+.0f", $0 * pa * 1000) }.joined(separator: " ")
                         + String(format: " vs groove %+.0f ms, rival %.2f", g.lagBeats * pa * 1000, g.rivalPeak))
                    continue
                }
                let lag = g.lagBeats * pa
                // Incoming output time t_out = startB maps to blend start; remove the lag.
                let offset = startA - startB - lag
                plans.append(BlendPlan(style: kind, period: pa, tempo: tempo, incomingGain: gain,
                                       blendStart: startA, incomingOffset: offset, overlapBeats: overlapBeats,
                                       grooveLag: lag, bandOnsetLags: g.bandOnsetBeats.map { $0 * pa },
                                       rivalPeak: g.rivalPeak,
                                       reason: "swap on the outgoing's \(style) at \(mmss(A.beats[sa])) and the "
                                           + "incoming's \(why) at \(mmss(B.sourceBeats[sb])) of its own track"))
                done.insert(kind)
                break
            }
        }
        if !plans.isEmpty { return plans.sorted { $0.style == .doubleDrop && $1.style != .doubleDrop } }
        return [phraseCut(A: A, B: B, pa: pa, tempo: tempo, gain: gain, silenceBeat: silenceBeat)]
    }

    static func bassFromStart(_ T: Track, silenceBeat: Int) -> Bool {
        let first = Array(T.db[min(silenceBeat, T.db.count)..<min(silenceBeat + 16, T.db.count)])
        guard !first.isEmpty else { return false }
        return median(first) >= median(T.db) - 6
    }

    static func incomingPoints(_ B: Track, silenceBeat: Int) -> [(Int, String)] {
        var pts: [(Int, String)] = []
        let drops = B.drops.filter { $0 - 16 >= silenceBeat }
        if let first = drops.first { pts.append((first, "first drop")) }
        let phrases = stride(from: B.phrase, to: B.n / 2, by: 32).filter { $0 - 16 >= silenceBeat }
        if bassFromStart(B, silenceBeat: silenceBeat), let p0 = phrases.first {
            pts.append((phrases.first { $0 - half >= silenceBeat } ?? p0, "phrase line (its bass is in from the start)"))
        }
        pts += drops.dropFirst().filter { $0 < B.n / 2 }.map { ($0, "later drop") }
        pts += phrases.map { ($0, "phrase line") }
        var seen = Set<Int>(), out: [(Int, String)] = []
        for (i, why) in pts where !seen.contains(i) && i + half < B.n {
            seen.insert(i); out.append((i, why))
        }
        return out
    }

    static func outgoingPoints(_ A: Track) -> [(Int, String)] {
        let ok = { (i: Int) in i - half >= 0 && i + half < A.n - 1 }
        let halfway = A.n / 2
        var pts: [(Int, String)] = A.drops.reversed().filter { $0 >= halfway && ok($0) }.map { ($0, "double drop") }
        pts += A.exits.reversed().filter { $0 >= halfway && ok($0) }.map { ($0, "bass exit") }
        pts += stride(from: A.phrase, to: A.n, by: 32).reversed().filter { $0 >= halfway && ok($0) }.map { ($0, "phrase line") }
        return pts
    }

    /// No trustworthy groove: no overlap. The outgoing fades over its last bar into
    /// its latest phrase line that leaves the overlap after it; the incoming starts
    /// there on its first phrase line after its leading silence.
    static func phraseCut(A: Track, B: Track, pa: Double, tempo: Double, gain: Double, silenceBeat: Int) -> BlendPlan {
        let exits = stride(from: A.phrase, to: A.n, by: 32).filter { $0 + overlapBeats < A.n }
        let exit = exits.last ?? max(0, A.n - 1)
        let entry = stride(from: B.phrase, to: B.n, by: 32).first { $0 >= silenceBeat } ?? 0
        let cut = A.beats[exit]
        return BlendPlan(style: .phraseCut, period: pa, tempo: tempo, incomingGain: gain, blendStart: cut,
                         incomingOffset: cut - B.beats[entry], overlapBeats: 0, grooveLag: 0, bandOnsetLags: [], rivalPeak: 0,
                         reason: "no point where the groove reading is trustworthy: phrase cut at \(mmss(cut)) "
                             + "into the incoming's phrase line at \(mmss(B.sourceBeats[entry]))")
    }

    static func median(_ x: [Double]) -> Double {
        let s = x.sorted(), n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    public static func mmss(_ t: Double) -> String {
        String(format: "%d:%04.1f", Int(t / 60), t.truncatingRemainder(dividingBy: 60))
    }
}

// MARK: - Executing a plan

@MainActor
public extension MixEngine {
    /// Schedules `plan` with the outgoing track already playing on `outgoing`
    /// (`outgoingStartFrame` is the master frame where outgoing time 0 played).
    /// The incoming buffer must be at the engine's sample rate.
    func schedule(_ plan: BlendPlan, outgoing: MixDeck, outgoingStartFrame: Int64, incoming buffer: PCMBuffer) throws {
        let sr = sampleRate
        let incoming = outgoing.other
        // The incoming joins at the blend start (bass swap) or 3 ms before the cut.
        let joinTime = plan.style == .phraseCut ? plan.blendStart - 0.003 : plan.blendStart
        let joinFrame = outgoingStartFrame + Int64((joinTime * sr).rounded())
        let joinOutgoingTime = Double(joinFrame - outgoingStartFrame) / sr
        let sourcePosition = (joinOutgoingTime - plan.incomingOffset) * plan.tempo * sr
        try prepare(incoming, buffer: buffer, sourcePosition: sourcePosition, tempo: plan.tempo,
                    gain: Float(plan.incomingGain))
        try start(incoming, atFrame: joinFrame)
        let blendFrame = Double(outgoingStartFrame) + plan.blendStart * sr
        if plan.style == .phraseCut {
            scheduleCut(from: outgoing, to: incoming, cutFrame: blendFrame, fadeFrames: 4 * plan.period * sr)
        } else {
            scheduleBassSwap(from: outgoing, to: incoming, startFrame: blendFrame,
                             framesPerBeat: plan.period * sr, overlapBeats: plan.overlapBeats)
        }
    }
}
