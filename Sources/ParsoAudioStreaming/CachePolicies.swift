//
//  CachePolicies.swift
//  Pure streaming-cache policy value types, lifted verbatim from Tonearm
//  (`Sources/Audio/CacheLimitPolicy.swift`, `NetworkPolicy.swift`,
//  `PrefetchDepthPolicy.swift`). Authored by John Arley Burns and relicensed MIT
//  — see ATTRIBUTION.md and docs/UNIFICATION_PLAN.md §3. Voxglass had no
//  equivalent; its prefetch/network gating lived in higher-level managers.
//
//  `PinPolicy` (Pro/free tier) and `CacheGlyphState` (UI vocabulary) deliberately
//  stay in Tonearm.
//
import Foundation

/// Clamps a user-requested cache size against a floor and 80% of free disk.
public struct CacheLimitPolicy: Sendable {
    public static let minimumBytes: Int64 = 100 * 1024 * 1024

    public struct Result: Equatable, Sendable {
        public var requestedBytes: Int64
        public var allowedBytes: Int64
        public var reason: String?

        public init(requestedBytes: Int64, allowedBytes: Int64, reason: String?) {
            self.requestedBytes = requestedBytes
            self.allowedBytes = allowedBytes
            self.reason = reason
        }
    }

    public static func validate(requestedBytes: Int64, freeDiskBytes: Int64) -> Result {
        guard requestedBytes > 0 else {
            return Result(
                requestedBytes: requestedBytes,
                allowedBytes: minAllowedBytes(freeDiskBytes: freeDiskBytes),
                reason: "Cache must be at least 100 MB."
            )
        }

        let ceiling = max(0, freeDiskBytes / 5 * 4)
        guard ceiling > 0 else {
            return Result(
                requestedBytes: requestedBytes,
                allowedBytes: 0,
                reason: "No free disk space is available for cache."
            )
        }

        if requestedBytes < minimumBytes {
            return Result(
                requestedBytes: requestedBytes,
                allowedBytes: min(minimumBytes, ceiling),
                reason: "Cache must be at least 100 MB."
            )
        }

        if requestedBytes > ceiling {
            return Result(
                requestedBytes: requestedBytes,
                allowedBytes: ceiling,
                reason: "Cache is limited to 80% of free disk space."
            )
        }

        return Result(requestedBytes: requestedBytes, allowedBytes: requestedBytes, reason: nil)
    }

    private static func minAllowedBytes(freeDiskBytes: Int64) -> Int64 {
        let ceiling = max(0, freeDiskBytes / 5 * 4)
        guard ceiling > 0 else { return 0 }
        return min(minimumBytes, ceiling)
    }
}

public enum PlaybackDecision: Equatable, Sendable {
    case play
    case skipWiFiOnly
    case playFromCache
}

/// Decides whether a track may start given its cache state and the current
/// network path, and walks a queue to the next track that may.
public struct NetworkPolicy: Sendable {
    public enum AssetKind: Equatable, Sendable {
        case local
        case remote
    }

    public static func decide(assetKind: AssetKind,
                              isCached: Bool,
                              pathIsExpensive: Bool,
                              streamOnCellular: Bool) -> PlaybackDecision {
        if assetKind == .local { return .play }
        if isCached { return .playFromCache }
        if pathIsExpensive && !streamOnCellular { return .skipWiFiOnly }
        return .play
    }

    public static func nextPlayableIndex(after currentIndex: Int,
                                         count: Int,
                                         repeatAll: Bool,
                                         decisionAt: (Int) -> PlaybackDecision) -> Int? {
        guard count > 0 else { return nil }
        var candidate = currentIndex
        var visited = 0
        while visited < count {
            if candidate < count - 1 {
                candidate += 1
            } else if repeatAll {
                candidate = 0
            } else {
                return nil
            }
            visited += 1
            if candidate == currentIndex { return nil }
            if decisionAt(candidate) != .skipWiFiOnly {
                return candidate
            }
        }
        return nil
    }
}

/// Clamps a prefetch depth (how many upcoming tracks to warm) to `0...5`.
public struct PrefetchDepthPolicy: Sendable {
    public static let minimum = 0
    public static let maximum = 5

    public static func clamp(_ value: Int) -> Int {
        min(maximum, max(minimum, value))
    }
}
