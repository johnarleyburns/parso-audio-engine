#if !os(watchOS)
import Foundation
import Testing
@testable import ParsoAudioStreaming

/// A raw serve target that records everything the loader hands back.
private final class RecordingSink: ResourceServeSink, @unchecked Sendable {
    let serveCurrentOffset: Int64
    let serveRequestedLength: Int
    let serveRequestsAllDataToEnd: Bool
    private(set) var received = Data()

    init(offset: Int64 = 0, requestedLength: Int = 0, toEnd: Bool = true) {
        serveCurrentOffset = offset
        serveRequestedLength = requestedLength
        serveRequestsAllDataToEnd = toEnd
    }

    func serveRespond(with data: Data) { received.append(data) }
}

/// `URLProtocol` stub that can 302-redirect to a second host and can answer a
/// chunked (no `Content-Length`) 200.
private final class StubRedirectChunkedProtocol: URLProtocol {
    struct Config {
        /// Host (path kept) that the origin 302-redirects to; nil = no redirect.
        var redirectHost: String?
        /// Serve the body as a chunked 200 with no `Content-Length`.
        var chunked = false
        var blob = Data()
    }
    nonisolated(unsafe) static var config = Config()
    /// Hosts that actually received a body request, in order.
    nonisolated(unsafe) static var servedHosts: [String] = []
    nonisolated(unsafe) static var rangeHeaders: [String] = []

    static func reset() { config = Config(); servedHosts = []; rangeHeaders = [] }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let url = request.url!
        let host = url.host ?? ""

        if let redirectHost = Self.config.redirectHost, host != redirectHost {
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)!
            comps.host = redirectHost
            let dest = comps.url!
            let resp = HTTPURLResponse(url: url, statusCode: 302, httpVersion: "HTTP/1.1",
                                       headerFields: ["Location": dest.absoluteString])!
            // URLSession follows the redirect and re-issues against `dest`.
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: dest), redirectResponse: resp)
            return
        }

        if let range = request.value(forHTTPHeaderField: "Range") { Self.rangeHeaders.append(range) }

        let blob = Self.config.blob
        if Self.config.chunked {
            Self.servedHosts.append(host)
            let headers = ["Content-Type": "audio/mpeg", "Transfer-Encoding": "chunked"]
            let resp = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: headers)!
            client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: blob)
            client?.urlProtocolDidFinishLoading(self)
            return
        }

        // Ranged 206 (or full 200 for an open-ended request).
        Self.servedHosts.append(host)
        let total = blob.count
        var status = 200
        var body = blob
        var headers = ["Content-Type": "audio/mpeg"]
        if let spec = request.value(forHTTPHeaderField: "Range")?.split(separator: "=").last {
            let parts = spec.split(separator: "-", omittingEmptySubsequences: false)
            let lower = Int(parts.first ?? "") ?? 0
            let upper = (parts.count > 1 ? Int(parts[1]) : nil) ?? (total - 1)
            let clampedUpper = min(upper, total - 1)
            if lower <= clampedUpper {
                body = blob.subdata(in: lower..<(clampedUpper + 1))
                status = 206
                headers["Content-Range"] = "bytes \(lower)-\(clampedUpper)/\(total)"
            }
        }
        headers["Content-Length"] = String(body.count)
        let resp = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: headers)!
        client?.urlProtocol(self, didReceive: resp, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

@Suite("CachingResourceLoader — key / redirect / chunked", .serialized)
struct CachingResourceLoaderStreamingTests {

    private func makeStore() -> SparseCacheStore {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("CRLStream-\(UUID().uuidString)", isDirectory: true)
        return SparseCacheStore(evictableRoot: base.appendingPathComponent("e"),
                                durableRoot: base.appendingPathComponent("d"))
    }

    private func stubSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [StubRedirectChunkedProtocol.self]
        return URLSession(configuration: cfg)
    }

    // MARK: - 1. Cache-key invariance vs. an external caller's raw-URL key

    @Test("cacheKey matches the key an external caller computes from the raw URL",
          arguments: [
            "https://archive.org/download/gd77/gd77-05-08 d1t01.flac",
            "https://archive.org/download/x/Song (Reprise)!.mp3",
            "https://archive.org/download/x/already%20encoded.flac",
            "https://cdn.example.com/audio/plain-ascii.mp3",
          ])
    func cacheKeyInvariance(raw rawString: String) throws {
        let raw = try #require(URL(string: rawString, encodingInvalidCharacters: true))
        for strategy in [CacheKeyStrategy.sha256WithExtension,
                         CacheKeyStrategy.sha256WithOptionalExtension] {
            let loader = CachingResourceLoader(
                originalURL: raw,
                store: makeStore(),
                config: .init(scheme: "pae-cache", keyStrategy: strategy),
                session: stubSession())
            #expect(loader.cacheKey == strategy.key(raw))
        }
    }

    @Test("custom-scheme input is still normalized back to https for keying")
    func customSchemeInputStillNormalized() {
        let https = URL(string: "https://cdn.example.com/a/track.m4a?t=1")!
        let custom = CachingResourceLoader.cacheURL(for: https, scheme: "pae-cache")
        let viaCustom = CachingResourceLoader(
            originalURL: custom, store: makeStore(),
            config: .init(scheme: "pae-cache"), session: stubSession())
        let viaHTTPS = CachingResourceLoader(
            originalURL: https, store: makeStore(),
            config: .init(scheme: "pae-cache"), session: stubSession())
        #expect(viaCustom.cacheKey == viaHTTPS.cacheKey)
    }

    // MARK: - 2. Redirect resolution

    @Test("range requests follow the origin's 302 to the redirected host")
    func redirectResolution() async throws {
        StubRedirectChunkedProtocol.reset()
        StubRedirectChunkedProtocol.config.redirectHost = "d1.us.archive.org"
        StubRedirectChunkedProtocol.config.blob = Data((0..<4096).map { UInt8($0 & 0xff) })

        let store = makeStore()
        let loader = CachingResourceLoader(
            originalURL: URL(string: "https://archive.org/download/x/track.mp3")!,
            store: store,
            config: .init(scheme: "pae-cache"),
            session: stubSession())

        let total = try await loader.resolveLength()
        #expect(total == 4096)
        #expect(loader.resolvedNetworkURL?.host == "d1.us.archive.org")

        let sink = RecordingSink(toEnd: true)
        try await loader.serve(sink, total: total)

        #expect(sink.received == StubRedirectChunkedProtocol.config.blob)
        #expect(StubRedirectChunkedProtocol.servedHosts.allSatisfy { $0 == "d1.us.archive.org" })
        #expect(!StubRedirectChunkedProtocol.servedHosts.isEmpty)
    }

    // MARK: - 3. Chunked / no-Content-Length 200

    @Test("a chunked 200 with no Content-Length streams to EOF instead of erroring")
    func chunkedNoContentLength() async throws {
        StubRedirectChunkedProtocol.reset()
        StubRedirectChunkedProtocol.config.chunked = true
        StubRedirectChunkedProtocol.config.blob = Data((0..<5000).map { UInt8($0 & 0xff) })

        let store = makeStore()
        let loader = CachingResourceLoader(
            originalURL: URL(string: "https://archive.org/download/x/derive.mp3")!,
            store: store,
            config: .init(scheme: "pae-cache"),
            session: stubSession())

        // Probe no longer throws; it reports "no seekable length".
        let total = try await loader.resolveLength()
        #expect(total == 0)
        #expect(loader.believesByteRangesSupported == false)
        let rangeHeadersAfterProbe = StubRedirectChunkedProtocol.rangeHeaders

        let sink = RecordingSink(offset: 0, requestedLength: 2, toEnd: false)
        try await loader.serve(sink, total: total)

        #expect(sink.received == StubRedirectChunkedProtocol.config.blob)
        // Full body buffered and pinned as complete for offline replay.
        #expect(await store.cachedContiguousBytes(for: loader.cacheKey, from: 0) == 5000)
        #expect(await store.totalBytes(for: loader.cacheKey) == 5000)
        // The serve phase sent no Range header for a stream it can't seek.
        #expect(StubRedirectChunkedProtocol.rangeHeaders == rangeHeadersAfterProbe)
    }
}
#endif
