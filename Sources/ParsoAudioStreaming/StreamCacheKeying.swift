//
//  StreamCacheKeying.swift
//  Cross-platform (iOS + watchOS) cache-key and URL-scheme helpers for the
//  streaming cache. Generalized from Tonearm `CacheKeyGenerator` /
//  `CachingResourceLoader.key` and Voxglass `StreamCacheUtils` — the two apps
//  used the *same* SHA256 scheme with a one-character difference in how an empty
//  extension is handled, so per-app key generation stays injectable
//  (docs/UNIFICATION_PLAN.md §3, "app cache directories and keys stay app-side").
//
import Foundation
import CryptoKit

/// How a remote URL maps to a stable on-disk cache key. Injected into
/// `CachingResourceLoader` so each app keeps its existing key identity (and thus
/// its existing on-disk cache) across the migration.
public struct CacheKeyStrategy: Sendable {
    public let key: @Sendable (URL) -> String

    public init(_ key: @Sendable @escaping (URL) -> String) { self.key = key }

    private static func sha256Hex(_ url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8))
            .map { String(format: "%02x", $0) }.joined()
    }

    /// `<sha256hex>-<ext>`, always with the trailing separator even when the URL
    /// has no extension. Matches Tonearm's historical keys.
    public static let sha256WithExtension = CacheKeyStrategy { url in
        sha256Hex(url) + "-" + (url.lastPathComponent as NSString).pathExtension.lowercased()
    }

    /// `<sha256hex>` when the URL has no extension, else `<sha256hex>-<ext>`.
    /// Matches Voxglass's historical keys.
    public static let sha256WithOptionalExtension = CacheKeyStrategy { url in
        let hex = sha256Hex(url)
        let ext = (url.lastPathComponent as NSString).pathExtension.lowercased()
        return ext.isEmpty ? hex : hex + "-" + ext
    }
}

public enum RemoteAudioURL {
    /// True when the URL should be routed through the streaming cache.
    public static func isCacheable(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https"
    }

    /// Rewrites the URL's scheme to `customScheme` so an `AVURLAsset` hands its
    /// loading requests to a `CachingResourceLoader` registered for that scheme.
    public static func cacheURL(for remote: URL, scheme customScheme: String) -> URL {
        guard var comps = URLComponents(url: remote, resolvingAgainstBaseURL: false) else { return remote }
        comps.scheme = customScheme
        return comps.url ?? remote
    }

    /// Reverses `cacheURL(for:scheme:)`: restores an `http`/`https` scheme.
    public static func networkURL(for cacheURL: URL, customScheme: String) -> URL {
        guard var comps = URLComponents(url: cacheURL, resolvingAgainstBaseURL: false) else { return cacheURL }
        if comps.scheme?.lowercased() == customScheme.lowercased() { comps.scheme = "https" }
        return comps.url ?? cacheURL
    }

    /// The audio format extension for `url`: its path extension, or — for an
    /// extension-less cache-blob name like `<sha256>-mp3` — the trailing segment.
    private static func audioExtension(for url: URL) -> String {
        url.pathExtension.lowercased().isEmpty
            ? (url.lastPathComponent.split(separator: "-").last.map(String.init)?.lowercased() ?? "")
            : url.pathExtension.lowercased()
    }

    /// MIME type for `AVURLAssetOverrideMIMETypeKey`. AVFoundation needs an
    /// explicit format hint when the URL (or the historical cache-blob name) has
    /// no real filename extension. `nil` when the format is unknown.
    public static func contentTypeMIME(for url: URL) -> String? {
        switch audioExtension(for: url) {
        case "mp3": return "audio/mpeg"
        case "m4a", "m4b", "mp4": return "audio/mp4"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        case "aif", "aiff": return "audio/aiff"
        default: return nil
        }
    }

    /// UTI for AVFoundation from a URL's path extension. Falls back to sniffing a
    /// trailing `-ext` segment on an extension-less cache-blob name.
    public static func contentTypeUTI(for url: URL) -> String {
        let ext = audioExtension(for: url)
        switch ext {
        case "flac": return "org.xiph.flac"
        case "mp3": return "public.mp3"
        case "m4a", "m4b", "aac", "mp4": return "public.mpeg-4-audio"
        case "wav": return "com.microsoft.waveform-audio"
        case "aif", "aiff": return "public.aiff-audio"
        default: return "public.audio"
        }
    }
}
