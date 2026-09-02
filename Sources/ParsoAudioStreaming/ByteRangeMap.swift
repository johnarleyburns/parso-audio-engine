//
//  ByteRangeMap.swift
//  Lifted verbatim from Tonearm (`Sources/Audio/ByteRangeMap.swift`) and
//  Voxglass (`Core/Services/Playback/ByteRangeMap.swift`), whose copies were
//  byte-identical. Authored by John Arley Burns and relicensed MIT here — see
//  ATTRIBUTION.md and docs/UNIFICATION_PLAN.md §1.
//

import Foundation

/// Persisted set of contiguous byte ranges present in a sparse cache file.
public struct ByteRangeMap: Codable, Equatable, Sendable {
    public private(set) var ranges: [Range<Int64>] = []

    public init() {}

    public init(data: Data) {
        if let decoded = try? JSONDecoder().decode(ByteRangeMap.self, from: data) {
            self = decoded
        }
    }

    public func encoded() -> Data {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    public mutating func insert(_ range: Range<Int64>) {
        guard range.lowerBound < range.upperBound else { return }
        var merged: [Range<Int64>] = []
        var newRange = range
        for r in ranges {
            if r.upperBound < newRange.lowerBound || r.lowerBound > newRange.upperBound {
                merged.append(r)
            } else {
                newRange = min(r.lowerBound, newRange.lowerBound)..<max(r.upperBound, newRange.upperBound)
            }
        }
        merged.append(newRange)
        ranges = merged.sorted { $0.lowerBound < $1.lowerBound }
    }

    /// Number of contiguous cached bytes starting at `offset`.
    public func contiguousBytes(from offset: Int64) -> Int64 {
        for r in ranges where r.contains(offset) {
            return r.upperBound - offset
        }
        return 0
    }

    public func totalBytes() -> Int64 {
        ranges.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
    }

    public func covers(total: Int64) -> Bool {
        guard total > 0 else { return false }
        return contiguousBytes(from: 0) >= total
    }
}
