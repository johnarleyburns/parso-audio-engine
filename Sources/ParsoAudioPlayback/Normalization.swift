//
//  Normalization.swift
//  ReplayGain tag parsing + a normalization planner that maps *either* ReplayGain
//  tags *or* a measured EBU R128 loudness to a single linear playback gain — one
//  policy, two sources (docs/UNIFICATION_PLAN.md §3). Lifted from Tonearm's
//  `ReplayGain` (the tag parser and gain math) and generalized: the `Track`
//  convenience stays in Tonearm, Voxglass's `VolumeNormalizer` (a realtime RMS
//  rider, a different job) stays in Voxglass.
//

import Foundation

/// ReplayGain tag values read off a file's metadata.
public struct ReplayGainTags: Equatable, Sendable {
    public var trackGainDB: Double?
    public var albumGainDB: Double?
    public var trackPeak: Double?
    public var albumPeak: Double?

    public init(trackGainDB: Double? = nil, albumGainDB: Double? = nil,
                trackPeak: Double? = nil, albumPeak: Double? = nil) {
        self.trackGainDB = trackGainDB
        self.albumGainDB = albumGainDB
        self.trackPeak = trackPeak
        self.albumPeak = albumPeak
    }

    public static let empty = ReplayGainTags()

    public var isEmpty: Bool { self == .empty }
}

/// A single metadata item, shaped so callers can feed `AVMetadataItem` fields
/// (or ID3 / Vorbis-comment entries) without importing AVFoundation here.
public struct ReplayGainTagItem: Equatable, Sendable {
    public var key: String?
    public var commonKey: String?
    public var identifier: String?
    public var keySpace: String?
    public var stringValue: String?
    public var dataValue: Data?

    public init(key: String? = nil, commonKey: String? = nil, identifier: String? = nil,
                keySpace: String? = nil, stringValue: String? = nil, dataValue: Data? = nil) {
        self.key = key
        self.commonKey = commonKey
        self.identifier = identifier
        self.keySpace = keySpace
        self.stringValue = stringValue
        self.dataValue = dataValue
    }
}

/// Parses `replaygain_*` fields out of a metadata item list. Tolerant of the many
/// shapes these tags take (ID3 TXXX, Vorbis comments, iTunes `----` atoms):
/// matches on identifier/key/keySpace *and* on the raw string payload.
public enum ReplayGainReader {
    public static func parse(items: [ReplayGainTagItem]) -> ReplayGainTags {
        var tags = ReplayGainTags()
        for item in items {
            guard let field = field(for: item),
                  let value = value(for: item, field: field) else { continue }
            switch field {
            case .trackGain: tags.trackGainDB = number(in: value)
            case .albumGain: tags.albumGainDB = number(in: value)
            case .trackPeak: tags.trackPeak = positiveNumber(in: value)
            case .albumPeak: tags.albumPeak = positiveNumber(in: value)
            }
        }
        return tags
    }

    /// Parse a single gain value ("-6.48 dB", "-6,48") to dB.
    public static func gainDB(from raw: String?) -> Double? { number(in: raw) }

    /// Parse a single peak value; nil unless finite and > 0.
    public static func peak(from raw: String?) -> Double? { positiveNumber(in: raw) }

    private enum Field: CaseIterable {
        case trackGain, albumGain, trackPeak, albumPeak
        var tag: String {
            switch self {
            case .trackGain: return "replaygain_track_gain"
            case .albumGain: return "replaygain_album_gain"
            case .trackPeak: return "replaygain_track_peak"
            case .albumPeak: return "replaygain_album_peak"
            }
        }
    }

    private static func field(for item: ReplayGainTagItem) -> Field? {
        let tokens = [item.identifier, item.commonKey, item.key, item.keySpace]
            .compactMap { $0?.lowercased() }
            .joined(separator: " ")
        for f in Field.allCases where contains(tokens, tag: f.tag) { return f }

        let value = (item.stringValue ?? dataString(item.dataValue) ?? "").lowercased()
        for f in Field.allCases where value.contains(f.tag) { return f }
        return nil
    }

    private static func contains(_ tokens: String, tag: String) -> Bool {
        tokens.contains(tag) || tokens.contains(tag.replacingOccurrences(of: "_", with: " "))
    }

    private static func value(for item: ReplayGainTagItem, field: Field) -> String? {
        guard let raw = item.stringValue ?? dataString(item.dataValue) else { return nil }
        let lowered = raw.lowercased()
        guard let range = lowered.range(of: field.tag) else { return raw }
        let trimmed = String(raw[range.upperBound...])
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{0}:= "))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? raw : trimmed
    }

    private static func number(in raw: String?) -> Double? {
        guard let raw else { return nil }
        let normalized = raw.replacingOccurrences(of: ",", with: ".")
        guard let range = normalized.range(of: #"[-+]?\d+(?:\.\d+)?"#, options: .regularExpression),
              let value = Double(normalized[range]), value.isFinite else { return nil }
        return value
    }

    private static func positiveNumber(in raw: String?) -> Double? {
        guard let value = number(in: raw), value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func dataString(_ data: Data?) -> String? {
        data.flatMap { String(data: $0, encoding: .utf8) }
    }
}

/// Maps a normalization intent + its input (ReplayGain tags and/or a measured
/// EBU R128 integrated loudness) to a single linear gain to multiply into the
/// playback path. `1.0` means "no change".
public struct NormalizationPlanner: Sendable {
    public enum Mode: String, Codable, Sendable, CaseIterable {
        case off, track, album
    }

    /// Target loudness for the measured-R128 path (LUFS). ReplayGain tags carry
    /// their own reference (typically -18 or -14 LUFS) baked into the gain value,
    /// so `referenceLUFS` only applies when planning from a measurement.
    public var mode: Mode
    public var preampDB: Double
    public var preventClipping: Bool
    public var referenceLUFS: Double

    public init(mode: Mode = .track, preampDB: Double = 0,
                preventClipping: Bool = true, referenceLUFS: Double = -18.0) {
        self.mode = mode
        self.preampDB = preampDB
        self.preventClipping = preventClipping
        self.referenceLUFS = referenceLUFS
    }

    /// Plan from ReplayGain tags. Album mode falls back to track gain when no
    /// album gain is present.
    public func gain(from tags: ReplayGainTags) -> Double {
        guard mode != .off else { return 1 }
        let selected: (gainDB: Double, peak: Double?)?
        switch mode {
        case .off:
            selected = nil
        case .track:
            selected = tags.trackGainDB.map { ($0, tags.trackPeak) }
        case .album:
            if let g = tags.albumGainDB { selected = (g, tags.albumPeak) }
            else { selected = tags.trackGainDB.map { ($0, tags.trackPeak) } }
        }
        guard let selected else { return 1 }
        return linearGain(gainDB: selected.gainDB, peak: selected.peak)
    }

    /// Plan from a measured integrated loudness (LUFS) and optional true peak
    /// (dBTP). The gain needed is `referenceLUFS - measuredLUFS`.
    public func gain(fromIntegratedLUFS measuredLUFS: Double, truePeakDBTP: Double? = nil) -> Double {
        guard mode != .off, measuredLUFS.isFinite else { return 1 }
        let gainDB = referenceLUFS - measuredLUFS
        let peak = truePeakDBTP.map { pow(10, $0 / 20) }
        return linearGain(gainDB: gainDB, peak: peak)
    }

    /// Prefer ReplayGain tags when present; otherwise fall back to a measurement.
    public func gain(from tags: ReplayGainTags, orIntegratedLUFS measuredLUFS: Double?,
                     truePeakDBTP: Double? = nil) -> Double {
        let relevantTag = mode == .album ? (tags.albumGainDB ?? tags.trackGainDB) : tags.trackGainDB
        if relevantTag != nil { return gain(from: tags) }
        if let measuredLUFS { return gain(fromIntegratedLUFS: measuredLUFS, truePeakDBTP: truePeakDBTP) }
        return 1
    }

    private func linearGain(gainDB: Double, peak: Double?) -> Double {
        var gain = pow(10, (gainDB + preampDB) / 20)
        if preventClipping, let peak, peak.isFinite, peak > 0, gain * peak > 1 {
            gain = 1 / peak
        }
        return gain.isFinite && gain > 0 ? gain : 1
    }
}
