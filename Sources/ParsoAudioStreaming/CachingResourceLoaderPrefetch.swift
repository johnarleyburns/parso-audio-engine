#if !os(watchOS)
import Foundation

extension CachingResourceLoader {
    /// Fills the cache up to `bytes` on the same path the loader uses, at
    /// background priority and without AVFoundation. The loader must stay alive
    /// until this returns or `shutdown()` is called.
    public func warm(upTo bytes: Int64) {
        let key = cacheKey
        let url = originalURL
        let cfg = config
        let store = store
        let session = session
        Task.detached(priority: .background) { [key, url, cfg, store, session, bytes] in
            guard bytes > 0 else { return }
            let fileURL = await store.fileURL(for: key)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                FileManager.default.createFile(atPath: fileURL.path, contents: nil)
            }
            let already = await store.rangeMap(for: key).contiguousBytes(from: 0)
            guard already < bytes else { return }
            var req = URLRequest(url: url)
            for (f, v) in cfg.headers { req.setValue(v, forHTTPHeaderField: f) }
            req.setValue("bytes=\(already)-\(bytes - 1)", forHTTPHeaderField: "Range")
            do {
                let (body, response) = try await session.data(for: req)
                guard let http = response as? HTTPURLResponse else { return }
                guard let decision = RemoteStreamingResponsePolicy.dataResponse(
                    statusCode: http.statusCode,
                    contentRange: http.value(forHTTPHeaderField: "Content-Range"),
                    expectedContentLength: http.expectedContentLength,
                    cursor: already,
                    knownTotalBytes: await store.totalBytes(for: key) ?? 0
                ) else { return }
                let writeOffset: Int64
                switch decision {
                case .ranged(let start):
                    guard start == already else { return }
                    writeOffset = already
                case .fullBody(let total):
                    if already > 0 { return }
                    await store.setContentLength(total, for: key)
                    writeOffset = 0
                }
                let fh = try FileHandle(forWritingTo: fileURL)
                defer { try? fh.close() }
                try fh.seek(toOffset: UInt64(writeOffset))
                try fh.write(contentsOf: body)
                await store.recordWrite(range: writeOffset..<(writeOffset + Int64(body.count)), for: key)
            } catch {}
        }
    }
}
#endif
