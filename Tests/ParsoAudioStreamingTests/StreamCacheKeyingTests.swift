import Foundation
import Testing
@testable import ParsoAudioStreaming

@Suite("StreamCacheKeying")
struct StreamCacheKeyingTests {

    @Test("sha256WithExtension always keeps a trailing separator")
    func withExtension() {
        let k = CacheKeyStrategy.sha256WithExtension.key(URL(string: "https://x.test/a/song.mp3")!)
        #expect(k.hasSuffix("-mp3"))
        let none = CacheKeyStrategy.sha256WithExtension.key(URL(string: "https://x.test/stream")!)
        #expect(none.hasSuffix("-"))
    }

    @Test("sha256WithOptionalExtension omits the separator when there is no extension")
    func optionalExtension() {
        let none = CacheKeyStrategy.sha256WithOptionalExtension.key(URL(string: "https://x.test/stream")!)
        #expect(!none.contains("-"))
        let ext = CacheKeyStrategy.sha256WithOptionalExtension.key(URL(string: "https://x.test/a.flac")!)
        #expect(ext.hasSuffix("-flac"))
    }

    @Test("keys are stable and URL-specific")
    func stability() {
        let a = CacheKeyStrategy.sha256WithExtension.key(URL(string: "https://x.test/a.mp3")!)
        let a2 = CacheKeyStrategy.sha256WithExtension.key(URL(string: "https://x.test/a.mp3")!)
        let b = CacheKeyStrategy.sha256WithExtension.key(URL(string: "https://x.test/b.mp3")!)
        #expect(a == a2)
        #expect(a != b)
    }

    @Test("scheme swap round-trips")
    func schemeSwap() {
        let remote = URL(string: "https://cdn.test/path/track.m4a?token=abc")!
        let cache = RemoteAudioURL.cacheURL(for: remote, scheme: "pae-cache")
        #expect(cache.scheme == "pae-cache")
        #expect(RemoteAudioURL.networkURL(for: cache, customScheme: "pae-cache").scheme == "https")
        #expect(cache.query == "token=abc")
    }

    @Test("isCacheable only for http/https")
    func cacheable() {
        #expect(RemoteAudioURL.isCacheable(URL(string: "https://x.test/a")!))
        #expect(RemoteAudioURL.isCacheable(URL(string: "http://x.test/a")!))
        #expect(!RemoteAudioURL.isCacheable(URL(string: "file:///tmp/a")!))
        #expect(!RemoteAudioURL.isCacheable(URL(string: "pae-cache://x.test/a")!))
    }

    @Test("contentTypeUTI maps by extension and by trailing blob segment")
    func contentTypes() {
        #expect(RemoteAudioURL.contentTypeUTI(for: URL(string: "https://x.test/a.flac")!) == "org.xiph.flac")
        #expect(RemoteAudioURL.contentTypeUTI(for: URL(string: "https://x.test/a.m4b")!) == "public.mpeg-4-audio")
        // extension-less cache blob name "<hex>-mp3"
        #expect(RemoteAudioURL.contentTypeUTI(for: URL(string: "https://x.test/deadbeef-mp3")!) == "public.mp3")
        #expect(RemoteAudioURL.contentTypeUTI(for: URL(string: "https://x.test/unknown")!) == "public.audio")
    }
}
