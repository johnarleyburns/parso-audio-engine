//
//  SparseCacheStore.swift
//  Generalized sparse byte-range cache: the union of Tonearm `CacheStore` and
//  Voxglass `StreamCacheStore` (docs/UNIFICATION_PLAN.md §3, Phase 2).
//
//  Authored by John Arley Burns; the Tonearm-derived shape (`cafBytes` →
//  derived-artifact slot, `pinned` → durable tier) is relicensed MIT here — see
//  ATTRIBUTION.md.
//
//  Design notes (why this is not just one app's store with the other's fields
//  bolted on, per the plan's "trap to avoid"):
//
//  - **Durable tier, not a `pinned` boolean.** Voxglass's two-tree model is the
//    stronger design: entries the user pinned for offline use live in a separate
//    root the OS never reclaims, and are excluded from the streaming budget.
//    `setDurable(_:for:)` moves the blob + meta + derived files between roots.
//  - **Opaque entry kind.** The store does not know what "artwork" is; `kind` is
//    a free-form tag (nil == "audio" for back-compat) used only for counting.
//  - **Generic derived-artifact slot.** Tonearm keeps a remuxed Opus→CAF sibling
//    next to the cached blob. Instead of a CAF-shaped field the store offers a
//    named derived-file slot (`derivedURL(for:name:)`, `recordDerivedBytes`),
//    whose bytes count toward eviction.
//  - **Roots and limit injected**, so app cache directories and Pro/free limit
//    policy stay app-side.
//
import Foundation

/// One storage root: a blob directory, a meta directory and a derived-file
/// directory. The evictable root lives under Caches; the durable root under a
/// location the OS never reclaims (Application Support), excluded from backup.
struct Root: Sendable {
    let blobDir: URL
    let metaDir: URL
    let derivedDir: URL

    init(_ base: URL) {
        blobDir = base.appendingPathComponent("blobs", isDirectory: true)
        metaDir = base.appendingPathComponent("meta", isDirectory: true)
        derivedDir = base.appendingPathComponent("derived", isDirectory: true)
    }

    func create(excludedFromBackup: Bool) {
        let fm = FileManager.default
        for dir in [blobDir, metaDir, derivedDir] {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if excludedFromBackup {
            for dir in [blobDir, metaDir, derivedDir] {
                var url = dir
                var values = URLResourceValues()
                values.isExcludedFromBackup = true
                try? url.setResourceValues(values)
            }
        }
    }

    func metaURL(_ key: String) -> URL { metaDir.appendingPathComponent("\(key).json") }
    func blobURL(_ key: String) -> URL { blobDir.appendingPathComponent(key) }
    func derivedURL(_ key: String, _ name: String) -> URL {
        derivedDir.appendingPathComponent(key, isDirectory: true).appendingPathComponent(name)
    }
}

public actor SparseCacheStore {

    // MARK: - Metadata

    public struct Meta: Codable, Sendable, Equatable {
        public var totalBytes: Int64?
        public var cachedBytes: Int64
        public var complete: Bool
        public var lastAccessedAt: Date
        public var createdAt: Date
        public var rangeMap: ByteRangeMap
        /// Free-form entry tag. `nil` decodes as `"audio"` for legacy JSON.
        public var kind: String?
        /// `nil`/`false` decodes as an evictable (streaming) entry.
        public var durable: Bool?
        /// Byte size of each named derived artifact sitting beside the blob.
        public var derivedBytes: [String: Int64]?

        public var effectiveKind: String { kind ?? "audio" }
        public var isDurable: Bool { durable ?? false }
        public var derivedTotal: Int64 { (derivedBytes ?? [:]).values.reduce(0, +) }

        public init(totalBytes: Int64?, cachedBytes: Int64, complete: Bool,
                    lastAccessedAt: Date, createdAt: Date, rangeMap: ByteRangeMap,
                    kind: String? = nil, durable: Bool? = nil,
                    derivedBytes: [String: Int64]? = nil) {
            self.totalBytes = totalBytes
            self.cachedBytes = cachedBytes
            self.complete = complete
            self.lastAccessedAt = lastAccessedAt
            self.createdAt = createdAt
            self.rangeMap = rangeMap
            self.kind = kind
            self.durable = durable
            self.derivedBytes = derivedBytes
        }

        // Lenient decode: a partly-written or older-schema metadata file must not
        // throw (a silent decode failure would drop a user's cached entry).
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let now = Date()
            totalBytes = try c.decodeIfPresent(Int64.self, forKey: .totalBytes) ?? nil
            cachedBytes = try c.decodeIfPresent(Int64.self, forKey: .cachedBytes) ?? 0
            complete = try c.decodeIfPresent(Bool.self, forKey: .complete) ?? false
            lastAccessedAt = try c.decodeIfPresent(Date.self, forKey: .lastAccessedAt) ?? now
            createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? now
            rangeMap = try c.decodeIfPresent(ByteRangeMap.self, forKey: .rangeMap) ?? ByteRangeMap()
            kind = try c.decodeIfPresent(String.self, forKey: .kind)
            durable = try c.decodeIfPresent(Bool.self, forKey: .durable)
            derivedBytes = try c.decodeIfPresent([String: Int64].self, forKey: .derivedBytes)
        }
    }

    // MARK: - Layout

    private let evictable: Root
    private let durable: Root
    private var metas: [String: Meta] = [:]
    private var limitBytes: Int64
    private var protectedKeys: Set<String> = []

    /// Nonisolated view of the same on-disk layout, for callers that need a
    /// synchronous "is this blob complete on disk" check without touching the
    /// actor (Tonearm's watchOS download adapter, the DJ crate importer). It
    /// reads the persisted metadata files, so it can lag the actor's in-memory
    /// state by one `persistMeta` — fine for the read-only paths that use it.
    public nonisolated let layout: SparseCacheLayout

    public static let defaultLimit: Int64 = 500 * 1024 * 1024

    /// - Parameters:
    ///   - evictableRoot: base directory for streaming (purgeable) entries.
    ///   - durableRoot: base directory for pinned/offline entries; if `nil`,
    ///     durable entries share the evictable root (single-tier mode).
    public init(evictableRoot: URL, durableRoot: URL? = nil, limitBytes: Int64 = defaultLimit) {
        evictable = Root(evictableRoot)
        durable = Root(durableRoot ?? evictableRoot)
        layout = SparseCacheLayout(evictableRoot: evictableRoot, durableRoot: durableRoot)
        self.limitBytes = limitBytes
        evictable.create(excludedFromBackup: false)
        durable.create(excludedFromBackup: durableRoot != nil)
        var loaded = Self.loadMetas(from: evictable.metaDir)
        for (k, m) in Self.loadMetas(from: durable.metaDir) { loaded[k] = m }
        metas = loaded
    }

    private func root(for key: String) -> Root {
        (metas[key]?.isDurable ?? false) ? durable : evictable
    }

    // MARK: - Accounting

    public func currentLimit() -> Int64 { limitBytes }

    public func setLimit(_ bytes: Int64) async {
        limitBytes = bytes
        await evictToFit(protecting: nil)
    }

    /// Streaming-budget total: durable entries are excluded.
    public func totalCachedBytes() -> Int64 {
        metas.values
            .filter { !$0.isDurable }
            .reduce(0) { $0 + $1.cachedBytes + $1.derivedTotal }
    }

    public func totalStoredBytes() -> Int64 {
        metas.values.reduce(0) { $0 + $1.cachedBytes + $1.derivedTotal }
    }

    public func contains(_ key: String) -> Bool { metas[key] != nil }

    public func isComplete(_ key: String) -> Bool { completeFileURL(for: key) != nil }

    public func isDurable(_ key: String) -> Bool { metas[key]?.isDurable ?? false }

    public func meta(for key: String) -> Meta? { metas[key] }

    /// Count of complete entries, optionally filtered to one kind.
    public func completeEntryCount(kind: String? = nil) -> Int {
        metas.values.filter { $0.complete && (kind == nil || $0.effectiveKind == kind) }.count
    }

    public func durableEntryCount() -> Int {
        metas.values.filter { $0.isDurable }.count
    }

    public func rangeMap(for key: String) -> ByteRangeMap {
        metas[key]?.rangeMap ?? ByteRangeMap()
    }

    public func totalBytes(for key: String) -> Int64? { metas[key]?.totalBytes }

    public func fileURL(for key: String) -> URL { root(for: key).blobURL(key) }

    public func derivedURL(for key: String, name: String) -> URL {
        root(for: key).derivedURL(key, name)
    }

    public func hasDerived(for key: String, name: String) -> Bool {
        FileManager.default.fileExists(atPath: derivedURL(for: key, name: name).path)
    }

    /// A real on-disk URL only when metadata and blob agree on a complete file.
    /// Repairs metadata that trusted a response length rather than the finished
    /// file's actual size; clears metadata whose blob was purged/truncated.
    public func completeFileURL(for key: String) -> URL? {
        guard let meta = metas[key], meta.complete else { return nil }
        let url = fileURL(for: key)
        guard let size = Self.fileSize(url), size > 0 else {
            discardCachedBytes(for: key)
            return nil
        }
        if meta.totalBytes != size || meta.cachedBytes != size || !meta.rangeMap.covers(total: size) {
            var repaired = meta
            var map = ByteRangeMap()
            map.insert(0..<size)
            repaired.totalBytes = size
            repaired.cachedBytes = size
            repaired.rangeMap = map
            repaired.complete = true
            repaired.lastAccessedAt = Date()
            metas[key] = repaired
            persistMeta(key)
        }
        touch(key)
        return url
    }

    /// Contiguous cached bytes from `offset` that a readable file actually backs.
    public func cachedContiguousBytes(for key: String, from offset: Int64) -> Int64 {
        guard let meta = metas[key] else { return 0 }
        let contiguous = meta.rangeMap.contiguousBytes(from: offset)
        guard contiguous > 0 else { return 0 }
        guard let size = Self.fileSize(fileURL(for: key)), size >= offset + contiguous else {
            discardCachedBytes(for: key)
            return 0
        }
        touch(key)
        return contiguous
    }

    // MARK: - Mutation (driven by the resource loader)

    public func setContentLength(_ length: Int64, for key: String) {
        var m = metas[key] ?? Self.newMeta()
        m.totalBytes = length
        metas[key] = m
        persistMeta(key)
    }

    public func recordWrite(range: Range<Int64>, for key: String) async {
        var m = metas[key] ?? Self.newMeta()
        m.rangeMap.insert(range)
        m.cachedBytes = m.rangeMap.totalBytes()
        if let total = m.totalBytes, m.rangeMap.covers(total: total) { m.complete = true }
        m.lastAccessedAt = Date()
        metas[key] = m
        persistMeta(key)
        await evictToFit(protecting: key)
    }

    /// Adopts a file written in one operation (background download) as a
    /// complete entry. `durable: true` also moves it into the durable root.
    public func adoptCompleteFile(byteCount: Int64, for key: String,
                                  kind: String? = nil, durable makeDurable: Bool = false) async {
        var m = metas[key] ?? Self.newMeta()
        m.kind = kind ?? m.kind
        var map = ByteRangeMap()
        if byteCount > 0 { map.insert(0..<byteCount) }
        m.rangeMap = map
        m.totalBytes = byteCount
        m.cachedBytes = map.totalBytes()
        m.complete = byteCount >= 0 && m.cachedBytes == byteCount
        m.lastAccessedAt = Date()
        metas[key] = m
        persistMeta(key)
        if makeDurable { setDurable(true, for: key) }
        await evictToFit(protecting: key)
    }

    /// Ingests a fully-downloaded temp file: moves it into the durable root,
    /// records the full range, marks it complete and durable.
    public func ingestCompleteFile(at tempURL: URL, key: String,
                                   totalBytes: Int64, kind: String? = nil) async {
        let fm = FileManager.default
        // Land the blob in the durable tree.
        var m = metas[key] ?? Self.newMeta()
        m.kind = kind ?? m.kind
        m.durable = true
        metas[key] = m
        let destination = durable.blobURL(key)
        try? fm.removeItem(at: destination)
        do { try fm.moveItem(at: tempURL, to: destination) }
        catch { try? fm.copyItem(at: tempURL, to: destination) }

        let actual = Self.fileSize(destination) ?? 0
        let resolved = actual > 0 ? actual : max(totalBytes, 0)
        var map = ByteRangeMap()
        if resolved > 0 { map.insert(0..<resolved) }
        let now = Date()
        metas[key] = Meta(totalBytes: resolved, cachedBytes: resolved, complete: true,
                          lastAccessedAt: now, createdAt: metas[key]?.createdAt ?? now,
                          rangeMap: map, kind: kind ?? metas[key]?.kind, durable: true,
                          derivedBytes: metas[key]?.derivedBytes)
        persistMeta(key)
    }

    /// Upserts a complete entry from a single known blob size (artwork-style).
    public func registerComplete(key: String, bytes: Int64, kind: String) async {
        let now = Date()
        var m = metas[key] ?? Self.newMeta()
        m.kind = kind
        m.complete = true
        m.cachedBytes = bytes
        m.totalBytes = bytes
        m.lastAccessedAt = now
        metas[key] = m
        persistMeta(key)
        await evictToFit(protecting: nil)
    }

    /// Records the byte size of a named derived artifact so it counts toward the
    /// cache budget. The caller has already written the file to `derivedURL`.
    public func recordDerivedBytes(_ bytes: Int64, name: String, for key: String) async {
        guard var m = metas[key] else { return }
        var derived = m.derivedBytes ?? [:]
        derived[name] = bytes
        m.derivedBytes = derived
        m.lastAccessedAt = Date()
        metas[key] = m
        persistMeta(key)
        await evictToFit(protecting: key)
    }

    public func touch(_ key: String) {
        guard var m = metas[key] else { return }
        m.lastAccessedAt = Date()
        metas[key] = m
        persistMeta(key)
    }

    // MARK: - Durable tier

    /// Moves an entry between the evictable and durable roots (pin / unpin).
    public func setDurable(_ makeDurable: Bool, for key: String) {
        guard var m = metas[key], m.isDurable != makeDurable else {
            if var m = metas[key] { m.durable = makeDurable; metas[key] = m }
            return
        }
        let from = makeDurable ? evictable : durable
        let to = makeDurable ? durable : evictable
        let fm = FileManager.default

        // Single-tier mode (durableRoot == evictableRoot): the roots share every
        // path, so there is nothing to move — just flip the flag.
        guard from.blobURL(key) != to.blobURL(key) else {
            m.durable = makeDurable
            metas[key] = m
            persistMeta(key)
            return
        }

        moveFile(from: from.blobURL(key), to: to.blobURL(key))
        if let names = m.derivedBytes?.keys {
            try? fm.createDirectory(at: to.derivedDir.appendingPathComponent(key, isDirectory: true),
                                    withIntermediateDirectories: true)
            for name in names {
                moveFile(from: from.derivedURL(key, name), to: to.derivedURL(key, name))
            }
            try? fm.removeItem(at: from.derivedDir.appendingPathComponent(key, isDirectory: true))
        }
        try? fm.removeItem(at: from.metaURL(key))
        m.durable = makeDurable
        metas[key] = m
        persistMeta(key)
    }

    public func setProtectedKeys(_ keys: Set<String>) { protectedKeys = keys }

    // MARK: - Removal

    public func remove(keys: [String]) {
        for key in keys { remove(key) }
    }

    public func clearAll() {
        for key in Array(metas.keys) { remove(key) }
        for root in [evictable, durable] {
            for dir in [root.blobDir, root.metaDir, root.derivedDir] {
                if let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) {
                    for f in files { try? FileManager.default.removeItem(at: f) }
                }
            }
        }
        metas.removeAll()
    }

    /// GC partial (incomplete) segments not touched in the last 7 days.
    public func garbageCollectStalePartials() {
        garbageCollectStalePartials(olderThan: Date().addingTimeInterval(-7 * 24 * 3600))
    }

    /// GC partial (incomplete) segments last touched before `cutoff`. Durable
    /// entries are always kept.
    public func garbageCollectStalePartials(olderThan cutoff: Date) {
        for (key, m) in metas where !m.complete && !m.isDurable && m.lastAccessedAt < cutoff {
            remove(key)
        }
    }

    // MARK: - Eviction

    private func evictToFit(protecting extraKey: String?) async {
        guard limitBytes > 0 else { return }
        var protected = protectedKeys
        if let extraKey { protected.insert(extraKey) }

        var total = metas
            .filter { !$0.value.isDurable }
            .reduce(Int64(0)) { $0 + $1.value.cachedBytes + $1.value.derivedTotal }
        guard total > limitBytes else { return }

        let candidates = metas
            .filter { !$0.value.isDurable && !protected.contains($0.key) }
            .sorted { lhs, rhs in
                lhs.value.lastAccessedAt == rhs.value.lastAccessedAt
                    ? lhs.key < rhs.key
                    : lhs.value.lastAccessedAt < rhs.value.lastAccessedAt
            }
        for (key, m) in candidates {
            if total <= limitBytes { break }
            remove(key)
            total -= m.cachedBytes + m.derivedTotal
        }
    }

    // MARK: - Internals

    private func remove(_ key: String) {
        let fm = FileManager.default
        for root in [evictable, durable] {
            try? fm.removeItem(at: root.blobURL(key))
            try? fm.removeItem(at: root.metaURL(key))
            try? fm.removeItem(at: root.derivedDir.appendingPathComponent(key, isDirectory: true))
        }
        metas.removeValue(forKey: key)
    }

    private func discardCachedBytes(for key: String) {
        let root = root(for: key)
        try? FileManager.default.removeItem(at: root.blobURL(key))
        guard var meta = metas[key] else { return }
        meta.cachedBytes = 0
        meta.complete = false
        meta.rangeMap = ByteRangeMap()
        meta.lastAccessedAt = Date()
        metas[key] = meta
        persistMeta(key)
    }

    private func moveFile(from: URL, to: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: from.path) else { return }
        if fm.fileExists(atPath: to.path) {
            try? fm.removeItem(at: from)
        } else {
            do { try fm.moveItem(at: from, to: to) }
            catch { try? fm.copyItem(at: from, to: to); try? fm.removeItem(at: from) }
        }
    }

    private static func newMeta() -> Meta {
        let now = Date()
        return Meta(totalBytes: nil, cachedBytes: 0, complete: false,
                    lastAccessedAt: now, createdAt: now, rangeMap: ByteRangeMap())
    }

    private static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    private func persistMeta(_ key: String) {
        guard let m = metas[key] else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(m) else { return }
        try? data.write(to: root(for: key).metaURL(key))
    }

    private static func loadMetas(from metaDir: URL) -> [String: Meta] {
        var result: [String: Meta] = [:]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: metaDir, includingPropertiesForKeys: nil) else { return result }
        for file in files where file.pathExtension == "json" {
            let key = file.deletingPathExtension().lastPathComponent
            if let data = try? Data(contentsOf: file),
               let m = try? JSONDecoder().decode(Meta.self, from: data) {
                result[key] = m
            }
        }
        return result
    }
}

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
