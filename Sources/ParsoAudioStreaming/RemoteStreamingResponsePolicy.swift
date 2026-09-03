//
//  RemoteStreamingResponsePolicy.swift
//  Lifted verbatim from Tonearm (`Sources/Audio/RemoteStreamingResponsePolicy.swift`).
//  Authored by John Arley Burns and relicensed MIT here — see ATTRIBUTION.md and
//  docs/UNIFICATION_PLAN.md §3. Voxglass had no equivalent; its loader simply
//  assumed byte-range support.
//
//  Pure decision logic over an HTTP response: given a status code, `Content-Range`
//  header and expected length, decide whether the server is serving a ranged
//  slice or a full body, and what the total length is. `CachingResourceLoader`
//  (Phase 2, step 2) drives its `AVAssetResourceLoaderDelegate` off this.
//
import Foundation

public enum RemoteStreamProbeResult: Equatable, Sendable {
    case ranged(totalBytes: Int64)
    case fullBody(totalBytes: Int64)

    public var totalBytes: Int64 {
        switch self {
        case .ranged(let total), .fullBody(let total): return total
        }
    }

    public var supportsByteRanges: Bool {
        switch self {
        case .ranged: return true
        case .fullBody: return false
        }
    }
}

public enum RemoteStreamDataResponse: Equatable, Sendable {
    case ranged(start: Int64)
    case fullBody(totalBytes: Int64)
}

public enum RemoteStreamingResponsePolicy {
    public static func probeResult(statusCode: Int,
                                   contentRange: String?,
                                   expectedContentLength: Int64) -> RemoteStreamProbeResult? {
        switch statusCode {
        case 206:
            let total = totalLength(contentRange: contentRange, expectedContentLength: expectedContentLength)
            return total > 0 ? .ranged(totalBytes: total) : nil
        case 200:
            return expectedContentLength > 0 ? .fullBody(totalBytes: expectedContentLength) : nil
        default:
            return nil
        }
    }

    public static func dataResponse(statusCode: Int,
                                    contentRange: String?,
                                    expectedContentLength: Int64,
                                    cursor: Int64,
                                    knownTotalBytes: Int64) -> RemoteStreamDataResponse? {
        switch statusCode {
        case 206:
            guard let start = rangeStart(contentRange), start == cursor else { return nil }
            return .ranged(start: start)
        case 200 where cursor == 0:
            let total = expectedContentLength > 0 ? expectedContentLength : knownTotalBytes
            return total > 0 ? .fullBody(totalBytes: total) : nil
        default:
            return nil
        }
    }

    public static func totalLength(contentRange: String?, expectedContentLength: Int64) -> Int64 {
        if let contentRange,
           let slash = contentRange.split(separator: "/").last,
           let total = Int64(slash) {
            return total
        }
        return expectedContentLength > 0 ? expectedContentLength : 0
    }

    private static func rangeStart(_ contentRange: String?) -> Int64? {
        guard let contentRange else { return nil }
        return contentRange
            .split(separator: " ")
            .dropFirst()
            .first?
            .split(separator: "-")
            .first
            .flatMap { Int64(String($0)) }
    }
}
