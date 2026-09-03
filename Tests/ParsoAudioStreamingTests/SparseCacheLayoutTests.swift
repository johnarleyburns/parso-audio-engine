import Foundation
import Testing
@testable import ParsoAudioStreaming

@Suite("SparseCacheLayout")
struct SparseCacheLayoutTests {

    private func roots() -> (evictable: URL, durable: URL) {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("Layout-\(UUID().uuidString)", isDirectory: true)
        return (base.appendingPathComponent("e"), base.appendingPathComponent("d"))
    }

    @Test("completeBlobExists tracks a completed entry and rejects a purged blob")
    func completeBlobExists() async throws {
        let (e, d) = roots()
        let store = SparseCacheStore(evictableRoot: e, durableRoot: d)
        let key = "abc123-mp3"

        #expect(store.layout.completeBlobExists(for: key) == false)

        let blob = await store.fileURL(for: key)
        try FileManager.default.createDirectory(at: blob.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: blob)
        await store.setContentLength(100, for: key)
        await store.recordWrite(range: 0..<100, for: key)

        #expect(store.layout.completeBlobExists(for: key) == true)

        try FileManager.default.removeItem(at: blob)
        #expect(store.layout.completeBlobExists(for: key) == false)
    }

    @Test("blobURL prefers the durable root once an entry is pinned there")
    func durablePreference() async throws {
        let (e, d) = roots()
        let store = SparseCacheStore(evictableRoot: e, durableRoot: d)
        let key = "pinned-flac"

        let blob = await store.fileURL(for: key)
        try FileManager.default.createDirectory(at: blob.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(repeating: 2, count: 50).write(to: blob)
        await store.setContentLength(50, for: key)
        await store.recordWrite(range: 0..<50, for: key)
        #expect(store.layout.blobURL(for: key).path.contains("/e/"))

        await store.setDurable(true, for: key)
        #expect(store.layout.blobURL(for: key).path.contains("/d/"))
        #expect(store.layout.completeBlobExists(for: key) == true)
    }

    @Test("a standalone layout resolves the same paths as its store")
    func standaloneMatchesStore() async {
        let (e, d) = roots()
        let store = SparseCacheStore(evictableRoot: e, durableRoot: d)
        let standalone = SparseCacheLayout(evictableRoot: e, durableRoot: d)
        let key = "x-mp3"
        #expect(standalone.blobURL(for: key) == store.layout.blobURL(for: key))
        #expect(standalone.metaURL(for: key) == store.layout.metaURL(for: key))
    }
}

@Suite("RemoteAudioURL.contentTypeMIME")
struct ContentTypeMIMETests {

    @Test("maps by real extension")
    func byExtension() {
        #expect(RemoteAudioURL.contentTypeMIME(for: URL(string: "https://a.test/t.mp3")!) == "audio/mpeg")
        #expect(RemoteAudioURL.contentTypeMIME(for: URL(string: "https://a.test/t.flac")!) == "audio/flac")
        #expect(RemoteAudioURL.contentTypeMIME(for: URL(string: "https://a.test/t.m4b")!) == "audio/mp4")
    }

    @Test("maps by the trailing segment of an extension-less cache-blob name")
    func byBlobSuffix() {
        let blob = URL(fileURLWithPath: "/cache/9f8e7d-mp3")
        #expect(RemoteAudioURL.contentTypeMIME(for: blob) == "audio/mpeg")
    }

    @Test("unknown formats return nil")
    func unknown() {
        #expect(RemoteAudioURL.contentTypeMIME(for: URL(string: "https://a.test/t.ogg")!) == nil)
    }
}
