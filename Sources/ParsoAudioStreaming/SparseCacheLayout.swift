import Foundation

/// A synchronous, actor-free view of a `SparseCacheStore`'s on-disk layout.
///
/// Some call sites need to answer "is the complete blob for this key already on
/// disk?" without `await` — Tonearm's watchOS `PhoneWatchDownloadAdapter` and the
/// DJ `PlaylistCrateImporter` both decide file-vs-stream synchronously while
/// building a play request. This type reads the persisted metadata + blob files
/// directly; it can lag the owning actor by one `persistMeta`, which is
/// acceptable for those read-only decisions.
public struct SparseCacheLayout: Sendable {
    private let evictable: Root
    private let durable: Root

    public init(evictableRoot: URL, durableRoot: URL? = nil) {
        evictable = Root(evictableRoot)
        durable = Root(durableRoot ?? evictableRoot)
    }

    /// The evictable-tier blob directory. For the uncommon case of an app that
    /// writes a blob to disk itself and then registers it with the store
    /// (Voxglass's artwork tier): write into here, then call `registerComplete`.
    public var evictableBlobsDirectory: URL { evictable.blobDir }

    /// Blob URL for `key`, preferring the durable root when a blob is present
    /// there, else the evictable root (even if nothing exists yet).
    public func blobURL(for key: String) -> URL {
        let durableBlob = durable.blobURL(key)
        return FileManager.default.fileExists(atPath: durableBlob.path)
            ? durableBlob : evictable.blobURL(key)
    }

    /// Metadata file URL for `key`, with the same durable-then-evictable
    /// preference as `blobURL(for:)`.
    public func metaURL(for key: String) -> URL {
        let durableMeta = durable.metaURL(key)
        return FileManager.default.fileExists(atPath: durableMeta.path)
            ? durableMeta : evictable.metaURL(key)
    }

    /// Named derived-artifact URL for `key` (e.g. Tonearm's Opus→CAF sibling).
    public func derivedURL(for key: String, name: String) -> URL {
        let durableDerived = durable.derivedURL(key, name)
        return FileManager.default.fileExists(atPath: durableDerived.path)
            ? durableDerived : evictable.derivedURL(key, name)
    }

    /// True when a persisted metadata file marks `key` complete and a non-empty
    /// blob backing it is on disk (covering the recorded total when known).
    public func completeBlobExists(for key: String) -> Bool {
        guard let data = try? Data(contentsOf: metaURL(for: key)),
              let meta = try? JSONDecoder().decode(SparseCacheStore.Meta.self, from: data),
              meta.complete else { return false }
        guard let size = (try? FileManager.default
            .attributesOfItem(atPath: blobURL(for: key).path)[.size] as? NSNumber)?.int64Value,
              size > 0 else { return false }
        if let total = meta.totalBytes, total > 0 { return size >= total }
        return true
    }
}


