#if !os(watchOS)
import Foundation
import Testing
@testable import ParsoAudioStreaming

/// `URLProtocol` stub that answers ranged GETs from an in-memory blob.
final class StubRangeProtocol: URLProtocol {
    nonisolated(unsafe) static var blob = Data()
    nonisolated(unsafe) static var supportRanges = true

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
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

@Suite("CachingResourceLoader.warm", .serialized)
struct CachingResourceLoaderWarmTests {

    private func makeStore() -> SparseCacheStore {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CRLWarm-\(UUID().uuidString)", isDirectory: true)
        return SparseCacheStore(evictableRoot: base.appendingPathComponent("e"),
                                durableRoot: base.appendingPathComponent("d"))
    }

    private func stubSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubRangeProtocol.self]
        return URLSession(configuration: cfg)
    }

    @Test("warm fills the cache from a ranged server")
    func warmRanged() async throws {
        StubRangeProtocol.blob = Data((0..<2048).map { UInt8($0 & 0xff) })
        StubRangeProtocol.supportRanges = true
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
        StubRangeProtocol.blob = Data((0..<4096).map { UInt8($0 & 0xff) })
        StubRangeProtocol.supportRanges = true
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

    private func pollUntil(timeout: TimeInterval = 3,
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
