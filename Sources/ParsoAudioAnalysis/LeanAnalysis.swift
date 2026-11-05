//
//  LeanAnalysis.swift
//  A trimmed sibling of `FullAnalysis` for callers that only need bpm,
//  beatgrid, key, and energy — the facts a BPM/Camelot-compatible next-track
//  picker needs, nothing else. Shares its exact computation with
//  `FullAnalysis` (both call `FullAnalysis.musicalCore`), so the two can
//  never silently drift apart; skips `FullAnalysis`'s loudness measurement
//  (built for DJ headroom matching), phrase/structure segmentation, and
//  waveform pyramid (built for a DJ deck's visual display) — none of which
//  this needs, and all three of which are the expensive stages.
//

import Foundation

public struct LeanAnalysisResult: Equatable, Sendable {
    public var bpm: Double?
    public var beatGrid: BeatGrid?
    public var downbeats: [Int]
    public var key: KeyEstimate?
    public var energy: EnergyResult?

    public init(bpm: Double? = nil,
                beatGrid: BeatGrid? = nil,
                downbeats: [Int] = [],
                key: KeyEstimate? = nil,
                energy: EnergyResult? = nil) {
        self.bpm = bpm
        self.beatGrid = beatGrid
        self.downbeats = downbeats
        self.key = key
        self.energy = energy
    }
}

public enum LeanAnalysis {
    public static func run(url: URL) throws -> LeanAnalysisResult {
        try run(AnalysisDecoder.decode(url))
    }

    public static func run(_ pcm: AnalysisAudio) -> LeanAnalysisResult {
        let core = FullAnalysis.musicalCore(pcm)
        return LeanAnalysisResult(bpm: core.bpm, beatGrid: core.beatGrid,
                                  downbeats: core.downbeatIndices, key: core.key,
                                  energy: core.energy)
    }
}
