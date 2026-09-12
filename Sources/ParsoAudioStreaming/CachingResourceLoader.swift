//
//  CachingResourceLoader.swift
//  Shared `AVAssetResourceLoaderDelegate` that streams a remote audio file
//  through a sparse on-disk cache. Generalized from Tonearm
//  `CachingResourceLoader` (the superset — `headers:`, `warm(upTo:)`, byte-range
//  fallback, redirect resolution, shared `URLSession`) and Voxglass's near-copy.
//  Authored by John Arley Burns and relicensed MIT — see ATTRIBUTION.md and
//  docs/UNIFICATION_PLAN.md §3.
//
//  The store and the cache-key strategy are injected so each app keeps its own
//  cache directory and on-disk key identity.
//
#if !os(watchOS)
import Foundation
@preconcurrency import AVFoundation

public struct CachingResourceLoaderConfig: Sendable {
    /// Custom URL scheme the `AVURLAsset` is built with and this loader answers.
    public var scheme: String
    /// Extra request headers (Tonearm's remote providers need auth; Voxglass
    /// passes none).
    public var headers: [String: String]
    public var keyStrategy: CacheKeyStrategy
    public var requestTimeout: TimeInterval
    public var resourceTimeout: TimeInterval
    public var chunkSize: Int

    public init(scheme: String,
                headers: [String: String] = [:],
                keyStrategy: CacheKeyStrategy = .sha256WithExtension,
                requestTimeout: TimeInterval = 30,
                resourceTimeout: TimeInterval = 3600,
                chunkSize: Int = 32 * 1024) {
        self.scheme = scheme
        self.headers = headers
        self.keyStrategy = keyStrategy
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.chunkSize = chunkSize
    }
}

public final class CachingResourceLoader: NSObject, @unchecked Sendable, AVAssetResourceLoaderDelegate {

    let originalURL: URL
    let store: SparseCacheStore
    let config: CachingResourceLoaderConfig
    public let cacheKey: String

    private let stateLock = NSLock()
    private var inFlight: [Task<Void, Never>] = []
    private var didShutdown = false
    private var fileHandle: FileHandle?
    private var resolvedURL: URL?
    private var resolvedContentType: String?
    private var resolvedSupportsByteRanges = true

    /// Optional injectable session (tests supply one backed by a `URLProtocol`
    /// stub). Defaults to a process-shared session so loaders don't leak one
    /// each.
    let session: URLSession

    private static let sharedSession: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        cfg.timeoutIntervalForResource = 3600
        return URLSession(configuration: cfg)
    }()

    public init(originalURL: URL,
                store: SparseCacheStore,
                config: CachingResourceLoaderConfig,
                session: URLSession? = nil) {
        self.originalURL = RemoteAudioURL.networkURL(for: originalURL, customScheme: config.scheme)
        self.store = store
        self.config = config
        self.cacheKey = config.keyStrategy.key(self.originalURL)
        self.session = session ?? Self.sharedSession
        super.init()
    }

    deinit { if let h = fileHandle { try? h.close() } }

    /// Rewrites a remote URL to this loader's custom scheme.
    public static func cacheURL(for remote: URL, scheme: String) -> URL {
        RemoteAudioURL.cacheURL(for: remote, scheme: scheme)
    }

    public func shutdown() {
        stateLock.lock()
        didShutdown = true
        let tasks = inFlight
        inFlight.removeAll()
        stateLock.unlock()
        tasks.forEach { $0.cancel() }
        if let h = fileHandle { try? h.close(); fileHandle = nil }
    }

    // MARK: - AVAssetResourceLoaderDelegate

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest) -> Bool {
        stateLock.lock()
        guard !didShutdown else { stateLock.unlock(); return false }
        let box = LoadingRequestBox(loadingRequest)
        let task = Task { [weak self, box] in
            guard let self else { return }
            await self.handle(box.value)
        }
        inFlight.append(task)
        stateLock.unlock()
        return true
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               didCancel loadingRequest: AVAssetResourceLoadingRequest) { }

    private func handle(_ request: AVAssetResourceLoadingRequest) async {
        guard !request.isCancelled else { return }
        do {
            let total = try await ensureResolvedLength()
            guard !request.isCancelled else { return }
            if let info = request.contentInformationRequest {
                info.contentLength = total
                info.isByteRangeAccessSupported = supportsByteRanges
                info.contentType = contentType
            }
            if let dataRequest = request.dataRequest, !request.isCancelled {
                try await serve(dataRequest, total: total)
            }
            guard !request.isCancelled else { return }
            request.finishLoading()
        } catch is CancellationError {
        } catch {
            request.finishLoading(with: error)
        }
    }

    // MARK: - Content type / byte-range state

    private var contentType: String {
        withLock { resolvedContentType } ?? RemoteAudioURL.contentTypeUTI(for: originalURL)
    }

    private var supportsByteRanges: Bool { withLock { resolvedSupportsByteRanges } }

    private func withLock<T>(_ body: () -> T) -> T {
        stateLock.lock(); defer { stateLock.unlock() }
        return body()
    }

    // MARK: - Content-length probe

    private func ensureResolvedLength() async throws -> Int64 {
        if let cached = await store.totalBytes(for: cacheKey), cached > 0 { return cached }
        var request = URLRequest(url: originalURL)
        for (f, v) in config.headers { request.setValue(v, forHTTPHeaderField: f) }
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        withLock {
            resolvedURL = http.url ?? originalURL
            if let mime = http.value(forHTTPHeaderField: "Content-Type")?
                .split(separator: ";", maxSplits: 1).first.map(String.init),
               let uti = utiForMIME(mime) {
                resolvedContentType = uti
            }
        }
        guard let probe = RemoteStreamingResponsePolicy.probeResult(
            statusCode: http.statusCode,
            contentRange: http.value(forHTTPHeaderField: "Content-Range"),
            expectedContentLength: http.expectedContentLength
        ) else {
            // HTTP 200 with no usable length: archive.org's on-the-fly
            // derivative files (and some CDN edges that ignore a `0-0` range)
            // answer chunked / `Content-Length`-less. Treat the resource as a
            // non-seekable full-body stream instead of failing playback.
            if http.statusCode == 200 {
                withLock { resolvedSupportsByteRanges = false }
                return 0
            }
            throw URLError(.badServerResponse)
        }
        withLock { resolvedSupportsByteRanges = probe.supportsByteRanges }
        if probe.totalBytes > 0 { await store.setContentLength(probe.totalBytes, for: cacheKey) }
        return probe.totalBytes
    }

    private func utiForMIME(_ mime: String) -> String? {
        switch mime.lowercased() {
        case "audio/mpeg", "audio/mp3": return "public.mp3"
        case "audio/mp4", "audio/aac", "audio/x-m4a": return "public.mpeg-4-audio"
        case "audio/flac", "audio/x-flac": return "org.xiph.flac"
        case "audio/wav", "audio/x-wav": return "com.microsoft.waveform-audio"
        case "audio/aiff", "audio/x-aiff": return "public.aiff-audio"
        default: return nil
        }
    }

    // MARK: - Progressive serve

    func serve(_ dr: ResourceServeSink, total: Int64) async throws {
        let start = dr.serveCurrentOffset
        var endRequested: Int64 = dr.serveRequestsAllDataToEnd
            ? (total > 0 ? total : Int64.max)
            : start + Int64(dr.serveRequestedLength)
        if total > 0 { endRequested = min(endRequested, total) }
        guard endRequested > start else { return }

        let fileURL = await store.fileURL(for: cacheKey)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        }

        var cursor = start
        while cursor < endRequested {
            try Task.checkCancellation()

            let cachedContiguous = await store.cachedContiguousBytes(for: cacheKey, from: cursor)
            if cachedContiguous > 0 {
                let chunkEnd = min(cursor + cachedContiguous, endRequested)
                if let data = readFile(fileURL, offset: cursor, length: chunkEnd - cursor), !data.isEmpty {
                    dr.serveRespond(with: data)
                    cursor += Int64(data.count)
                    continue
                }
            }

            let rangeHeader: String
            if endRequested < Int64.max && total > 0 {
                rangeHeader = "bytes=\(cursor)-\(endRequested - 1)"
            } else if total > 0, cursor < total {
                rangeHeader = "bytes=\(cursor)-\(total - 1)"
            } else {
                rangeHeader = "bytes=\(cursor)-"
            }

            var req = URLRequest(url: withLock { resolvedURL } ?? originalURL)
            for (f, v) in config.headers { req.setValue(v, forHTTPHeaderField: f) }
            if supportsByteRanges { req.setValue(rangeHeader, forHTTPHeaderField: "Range") }

            let (bytes, response) = try await session.bytes(for: req)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            let knownTotal = await store.totalBytes(for: cacheKey) ?? total
            let decision = RemoteStreamingResponsePolicy.dataResponse(
                statusCode: http.statusCode,
                contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                expectedContentLength: http.expectedContentLength,
                cursor: cursor,
                knownTotalBytes: knownTotal
            )
            var chunkedFullStream = false
            switch decision {
            case .ranged:
                break
            case .fullBody(let fullTotal):
                withLock { resolvedSupportsByteRanges = false }
                await store.setContentLength(fullTotal, for: cacheKey)
            case .none:
                // Chunked / no-Content-Length 200: the origin gave us neither a
                // `Content-Range` nor a usable length. Stream the whole body to
                // EOF and satisfy the request from the buffer instead of
                // throwing `.badServerResponse` (silent playback death).
                guard http.statusCode == 200, cursor == 0 else { throw URLError(.badServerResponse) }
                withLock { resolvedSupportsByteRanges = false }
                chunkedFullStream = true
                endRequested = Int64.max
            }

            var buf: [UInt8] = []
            buf.reserveCapacity(config.chunkSize)
            var written: [Range<Int64>] = []

            func flush() {
                guard !buf.isEmpty else { return }
                let chunk = Data(buf)
                writeFile(fileURL, offset: cursor, data: chunk)
                written.append(cursor..<(cursor + Int64(chunk.count)))
                if cursor < endRequested {
                    let usable = min(Int64(chunk.count), endRequested - cursor)
                    if usable > 0 { dr.serveRespond(with: chunk.prefix(Int(usable))) }
                }
                cursor += Int64(chunk.count)
                buf.removeAll(keepingCapacity: true)
            }

            for try await byte in bytes {
                buf.append(byte)
                if buf.count >= config.chunkSize {
                    try Task.checkCancellation()
                    flush()
                }
            }
            flush()

            for range in written.reversed() {
                await store.recordWrite(range: range, for: cacheKey)
            }
            if chunkedFullStream {
                // The body is now fully buffered on disk; pin the real length so
                // the entry reads back as complete for offline replay.
                if cursor > 0 {
                    await store.setContentLength(cursor, for: cacheKey)
                    await store.recordWrite(range: 0..<cursor, for: cacheKey)
                }
                break
            }
            if cursor >= endRequested { break }
        }
    }

    // MARK: - Sparse file IO

    private func readFile(_ url: URL, offset: Int64, length: Int64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: UInt64(offset))
        return try? handle.read(upToCount: Int(length))
    }

    private func writeFile(_ url: URL, offset: Int64, data: Data) {
        guard !data.isEmpty else { return }
        if fileHandle == nil { fileHandle = try? FileHandle(forWritingTo: url) }
        guard let handle = fileHandle else { return }
        try? handle.seek(toOffset: UInt64(offset))
        try? handle.write(contentsOf: data)
    }
}

private final class LoadingRequestBox: @unchecked Sendable {
    let value: AVAssetResourceLoadingRequest
    init(_ value: AVAssetResourceLoadingRequest) { self.value = value }
}

/// The subset of `AVAssetResourceLoadingDataRequest` the progressive serve loop
/// needs. Abstracted so the loop is drivable from tests without fabricating an
/// `AVAssetResourceLoadingRequest` (which has no public initializer).
protocol ResourceServeSink: AnyObject {
    var serveCurrentOffset: Int64 { get }
    var serveRequestedLength: Int { get }
    var serveRequestsAllDataToEnd: Bool { get }
    func serveRespond(with data: Data)
}

extension AVAssetResourceLoadingDataRequest: ResourceServeSink {
    var serveCurrentOffset: Int64 { currentOffset }
    var serveRequestedLength: Int { requestedLength }
    var serveRequestsAllDataToEnd: Bool { requestsAllDataToEndOfResource }
    func serveRespond(with data: Data) { respond(with: data) }
}

extension CachingResourceLoader {
    /// Test seam: the post-redirect URL the loader resolved on the first response.
    var resolvedNetworkURL: URL? { withLock { resolvedURL } }
    /// Test seam: whether the loader currently believes the origin honors ranges.
    var believesByteRangesSupported: Bool { supportsByteRanges }
    /// Test seam: run the content-length probe.
    func resolveLength() async throws -> Int64 { try await ensureResolvedLength() }
}
#endif
