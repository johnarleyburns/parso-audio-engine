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

    // MARK: - Layout

    fileprivate let evictable: Root
    fileprivate let durable: Root
    fileprivate var metas: [String: Meta] = [:]
    fileprivate var limitBytes: Int64
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

    fileprivate func root(for key: String) -> Root {
        (metas[key]?.isDurable ?? false) ? durable : evictable
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

    fileprivate func evictToFit(protecting extraKey: String?) async {
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

    fileprivate func discardCachedBytes(for key: String) {
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

    fileprivate static func fileSize(_ url: URL) -> Int64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    fileprivate func persistMeta(_ key: String) {
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
