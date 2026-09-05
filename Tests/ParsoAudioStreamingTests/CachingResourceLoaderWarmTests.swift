#if !os(watchOS)
import Foundation
import Testing
@testable import ParsoAudioStreaming

/// `URLProtocol` stub that answers ranged GETs from an in-memory blob.
final class StubRangeProtocol: URLProtocol {
    nonisolated(unsafe) static var blob = Data()
    nonisolated(unsafe) static var supportRanges = true
    /// Set true to simulate the network being unreachable — every request fails.
    nonisolated(unsafe) static var offline = false
    /// Headers seen on the most recent request, and a running request count.
    nonisolated(unsafe) static var lastRequestHeaders: [String: String] = [:]
    nonisolated(unsafe) static var requestCount = 0

    static func reset() {
        blob = Data(); supportRanges = true; offline = false
        lastRequestHeaders = [:]; requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.requestCount += 1
        Self.lastRequestHeaders = request.allHTTPHeaderFields ?? [:]
        if Self.offline {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let total = Self.blob.count
        let rangeHeader = request.value(forHTTPHeaderField: "Range")
        var status = 200
        var body = Self.blob
        var headers = ["Content-Type": "audio/mpeg"]

        if Self.supportRanges, let rangeHeader,
           let spec = rangeHeader.split(separator: "=").last {
            let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
            let lower = Int(parts.first ?? "") ?? 0
            let upper = (parts.count > 1 ? Int(parts[1]) : nil) ?? (total - 1)
            let clampedUpper = min(upper, total - 1)
            if lower <= clampedUpper {
                body = Self.blob.subdata(in: lower..<(clampedUpper + 1))
                status = 206
                headers["Content-Range"] = "bytes \(lower)-\(clampedUpper)/\(total)"
            }
        }
        headers["Content-Length"] = String(body.count)

        let response = HTTPURLResponse(url: request.url!, statusCode: status,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("CachingResourceLoader streaming cache", .serialized)
struct CachingResourceLoaderWarmTests {

    private func makeStore() -> SparseCacheStore {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CRLWarm-\(UUID().uuidString)", isDirectory: true)
        return SparseCacheStore(evictableRoot: base.appendingPathComponent("e"),
                                durableRoot: base.appendingPathComponent("d"))
    }

    private func loader(_ store: SparseCacheStore,
                        headers: [String: String] = [:]) -> CachingResourceLoader {
        CachingResourceLoader(
            originalURL: URL(string: "https://audio.test/chapter.mp3")!,
            store: store,
            config: .init(scheme: "pae-cache", headers: headers),
            session: stubSession())
    }

    private func stubSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubRangeProtocol.self]
        return URLSession(configuration: cfg)
    }

    @Test("warm fills the cache from a ranged server")
    func warmRanged() async throws {
        StubRangeProtocol.reset()
        StubRangeProtocol.blob = Data((0..<2048).map { UInt8($0 & 0xff) })
        let store = makeStore()
        let loader = CachingResourceLoader(
            originalURL: URL(string: "https://audio.test/track.mp3")!,
            store: store,
            config: .init(scheme: "pae-cache"),
            session: stubSession())

        loader.warm(upTo: 1024)
        try await pollUntil { await store.rangeMap(for: loader.cacheKey).contiguousBytes(from: 0) >= 1024 }

        let cached = await store.rangeMap(for: loader.cacheKey).contiguousBytes(from: 0)
        #expect(cached == 1024)
        let fileURL = await store.fileURL(for: loader.cacheKey)
        let onDisk = try Data(contentsOf: fileURL)
        #expect(onDisk.prefix(1024) == StubRangeProtocol.blob.prefix(1024))
    }

    @Test("warm does not re-download bytes already cached")
    func warmRespectsExistingCache() async throws {
        StubRangeProtocol.reset()
        StubRangeProtocol.blob = Data((0..<4096).map { UInt8($0 & 0xff) })
        let store = makeStore()
        let loader = CachingResourceLoader(
            originalURL: URL(string: "https://audio.test/track.mp3")!,
            store: store,
            config: .init(scheme: "pae-cache"),
            session: stubSession())

        loader.warm(upTo: 1000)
        try await pollUntil { await store.rangeMap(for: loader.cacheKey).contiguousBytes(from: 0) >= 1000 }
        loader.warm(upTo: 2000)
        try await pollUntil { await store.rangeMap(for: loader.cacheKey).contiguousBytes(from: 0) >= 2000 }

        #expect(await store.rangeMap(for: loader.cacheKey).contiguousBytes(from: 0) == 2000)
    }

    // MARK: - Serve / replay-offline (the old manual smoke steps)

    @Test("a streamed track replays from disk with the network gone")
    func replayOffline() async throws {
        StubRangeProtocol.reset()
        StubRangeProtocol.blob = Data((0..<8192).map { UInt8($0 & 0xff) })
        let store = makeStore()

        let first = loader(store)
        first.warm(upTo: 8192)
        try await pollUntil {
            await store.rangeMap(for: first.cacheKey).contiguousBytes(from: 0) >= 8192
        }
        first.shutdown()

        StubRangeProtocol.offline = true
        let countAfterFill = StubRangeProtocol.requestCount

        let key = first.cacheKey
        #expect(await store.cachedContiguousBytes(for: key, from: 0) == 8192)
        let onDisk = try Data(contentsOf: await store.fileURL(for: key))
        #expect(onDisk == StubRangeProtocol.blob)
        #expect(StubRangeProtocol.requestCount == countAfterFill)
    }

    @Test("provider auth headers are sent on every request")
    func headersOnEveryRequest() async throws {
        StubRangeProtocol.reset()
        StubRangeProtocol.blob = Data(repeating: 0xAB, count: 4096)
        let store = makeStore()

        let l = loader(store, headers: ["Authorization": "Bearer smoke-token"])
        l.warm(upTo: 4096)
        try await pollUntil {
            await store.rangeMap(for: l.cacheKey).contiguousBytes(from: 0) >= 4096
        }
        l.shutdown()

        #expect(StubRangeProtocol.requestCount > 0)
        #expect(StubRangeProtocol.lastRequestHeaders["Authorization"] == "Bearer smoke-token")
    }

    @Test("a server that refuses ranges still fills the cache from a full body")
    func fullBodyFallback() async throws {
        StubRangeProtocol.reset()
        StubRangeProtocol.blob = Data((0..<3000).map { UInt8($0 & 0xff) })
        StubRangeProtocol.supportRanges = false
        let store = makeStore()

        let l = loader(store)
        l.warm(upTo: 3000)
        try await pollUntil {
            await store.rangeMap(for: l.cacheKey).contiguousBytes(from: 0) >= 3000
        }
        l.shutdown()

        let onDisk = try Data(contentsOf: await store.fileURL(for: l.cacheKey))
        #expect(onDisk == StubRangeProtocol.blob)
    }

    /// `warm` runs on a detached `.background`-priority task, so on a
    /// CPU-saturated CI runner it gets essentially zero CPU until the other
    /// concurrent CPU-heavy suites (fixture-analysis FFT, Phase 7b/7c neural
    /// tokenization/pooling/quantization) finish, then completes within
    /// milliseconds. Observed CI totals for the whole test binary have run up
    /// to ~320s, so the deadline needs headroom above that, not just above a
    /// typical run — this is a reliability floor, not a performance budget.
    private func pollUntil(timeout: TimeInterval = 600,
                           _ condition: @Sendable () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        Issue.record("condition not met within \(timeout)s")
    }
}
#endif
