import Foundation
import Testing
@testable import ParsoAudioStreaming

@Suite("SparseCacheStore")
struct SparseCacheStoreTests {

    /// Fresh isolated temp directory per test.
    private func makeRoots() -> (evictable: URL, durable: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SparseCacheStoreTests-\(UUID().uuidString)", isDirectory: true)
        return (base.appendingPathComponent("evictable"), base.appendingPathComponent("durable"))
    }

    private func writeBlob(_ url: URL, bytes: Int) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? Data(count: bytes).write(to: url)
    }

    @Test("recordWrite accumulates ranges and completes at content length")
    func recordWriteCompletes() async {
        let roots = makeRoots()
        let store = SparseCacheStore(evictableRoot: roots.evictable, durableRoot: roots.durable)
        await store.setContentLength(100, for: "k")
        await store.recordWrite(range: 0..<40, for: "k")
        #expect(await store.isComplete("k") == false)
        #expect(await store.rangeMap(for: "k").totalBytes() == 40)
        await store.recordWrite(range: 40..<100, for: "k")
        // Not "complete" until a real blob backs it.
        writeBlob(await store.fileURL(for: "k"), bytes: 100)
        #expect(await store.completeFileURL(for: "k") != nil)
    }

    @Test("LRU eviction removes the oldest evictable entry, protecting the active key")
    func lruEviction() async {
        let roots = makeRoots()
        let store = SparseCacheStore(evictableRoot: roots.evictable, durableRoot: roots.durable,
                                     limitBytes: 150)
        for key in ["a", "b", "c"] {
            await store.setContentLength(100, for: key)
            writeBlob(await store.fileURL(for: key), bytes: 100)
            await store.recordWrite(range: 0..<100, for: key)
        }
        // Budget 150, three 100-byte entries: writing "c" evicts by LRU but
        // protects "c" itself. "a" is the oldest → evicted.
        #expect(await store.contains("a") == false)
        #expect(await store.contains("c") == true)
        #expect(await store.totalCachedBytes() <= 150)
    }

    @Test("durable entries are excluded from the streaming budget and never evicted")
    func durableExcludedFromBudget() async {
        let roots = makeRoots()
        let store = SparseCacheStore(evictableRoot: roots.evictable, durableRoot: roots.durable,
                                     limitBytes: 120)
        await store.setContentLength(100, for: "pinned")
        writeBlob(await store.fileURL(for: "pinned"), bytes: 100)
        await store.recordWrite(range: 0..<100, for: "pinned")
        await store.setDurable(true, for: "pinned")
        #expect(await store.isDurable("pinned") == true)
        #expect(await store.totalCachedBytes() == 0)

        // A large streaming entry must not evict the pinned one.
        await store.setContentLength(100, for: "stream")
        writeBlob(await store.fileURL(for: "stream"), bytes: 100)
        await store.recordWrite(range: 0..<100, for: "stream")
        #expect(await store.contains("pinned") == true)
        #expect(await store.completeFileURL(for: "pinned") != nil)
    }

    @Test("setDurable moves the blob between roots")
    func setDurableMovesBlob() async {
        let roots = makeRoots()
        let store = SparseCacheStore(evictableRoot: roots.evictable, durableRoot: roots.durable)
        await store.adoptCompleteFile(byteCount: 0, for: "k")
        writeBlob(await store.fileURL(for: "k"), bytes: 10)
        let evictablePath = roots.evictable.appendingPathComponent("blobs/k").path
        #expect(FileManager.default.fileExists(atPath: evictablePath))
        await store.setDurable(true, for: "k")
        #expect(FileManager.default.fileExists(atPath: evictablePath) == false)
        #expect(FileManager.default.fileExists(atPath: roots.durable.appendingPathComponent("blobs/k").path))
        await store.setDurable(false, for: "k")
        #expect(FileManager.default.fileExists(atPath: evictablePath))
    }

    @Test("derived-artifact bytes count toward the budget")
    func derivedBytesCounted() async {
        let roots = makeRoots()
        let store = SparseCacheStore(evictableRoot: roots.evictable, durableRoot: roots.durable)
        await store.adoptCompleteFile(byteCount: 100, for: "k")
        await store.recordDerivedBytes(50, name: "remux.caf", for: "k")
        #expect(await store.totalStoredBytes() == 150)
        #expect(await store.derivedURL(for: "k", name: "remux.caf").lastPathComponent == "remux.caf")
    }

    @Test("ingestCompleteFile lands a durable, complete entry")
    func ingestCompleteFile() async {
        let roots = makeRoots()
        let store = SparseCacheStore(evictableRoot: roots.evictable, durableRoot: roots.durable)
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ingest-\(UUID().uuidString)")
        try? Data(count: 512).write(to: temp)
        await store.ingestCompleteFile(at: temp, key: "book", totalBytes: 0, kind: "audio")
        #expect(await store.isDurable("book") == true)
        #expect(await store.completeFileURL(for: "book") != nil)
        #expect(await store.totalBytes(for: "book") == 512)
    }

    @Test("completeFileURL clears metadata whose blob was purged")
    func purgedBlobClearsMeta() async {
        let roots = makeRoots()
        let store = SparseCacheStore(evictableRoot: roots.evictable, durableRoot: roots.durable)
        await store.adoptCompleteFile(byteCount: 100, for: "k")
        writeBlob(await store.fileURL(for: "k"), bytes: 100)
        #expect(await store.completeFileURL(for: "k") != nil)
        try? FileManager.default.removeItem(at: await store.fileURL(for: "k"))
        #expect(await store.completeFileURL(for: "k") == nil)
        #expect(await store.isComplete("k") == false)
    }

    @Test("metadata survives a reload from disk")
    func reloadFromDisk() async {
        let roots = makeRoots()
        do {
            let store = SparseCacheStore(evictableRoot: roots.evictable, durableRoot: roots.durable)
            await store.adoptCompleteFile(byteCount: 100, for: "s")
            await store.adoptCompleteFile(byteCount: 200, for: "d", durable: true)
        }
        let reopened = SparseCacheStore(evictableRoot: roots.evictable, durableRoot: roots.durable)
        #expect(await reopened.contains("s") == true)
        #expect(await reopened.isDurable("d") == true)
        #expect(await reopened.totalBytes(for: "d") == 200)
    }

    @Test("legacy metadata without kind/durable decodes as evictable audio")
    func legacyMetaDecodes() async {
        let roots = makeRoots()
        let metaDir = roots.evictable.appendingPathComponent("meta")
        try? FileManager.default.createDirectory(at: metaDir, withIntermediateDirectories: true)
        let legacy = """
        {"cachedBytes":10,"complete":false,"createdAt":0,"lastAccessedAt":0,"rangeMap":{"ranges":[]},"totalBytes":10}
        """
        try? legacy.data(using: .utf8)!.write(to: metaDir.appendingPathComponent("legacy.json"))
        let store = SparseCacheStore(evictableRoot: roots.evictable, durableRoot: roots.durable)
        #expect(await store.contains("legacy") == true)
        #expect(await store.meta(for: "legacy")?.effectiveKind == "audio")
        #expect(await store.isDurable("legacy") == false)
    }

    @Test("garbageCollectStalePartials drops old incomplete entries only")
    func gcStalePartials() async {
        let roots = makeRoots()
        let store = SparseCacheStore(evictableRoot: roots.evictable, durableRoot: roots.durable)
        await store.setContentLength(100, for: "partial")
        await store.recordWrite(range: 0..<10, for: "partial")
        await store.adoptCompleteFile(byteCount: 100, for: "done")
        await store.garbageCollectStalePartials(olderThan: Date().addingTimeInterval(3600))
        #expect(await store.contains("partial") == false)
        #expect(await store.contains("done") == true)
    }
}
