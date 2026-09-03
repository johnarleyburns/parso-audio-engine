import Testing
@testable import ParsoAudioStreaming

@Suite("CacheLimitPolicy")
struct CacheLimitPolicyTests {
    let mb: Int64 = 1024 * 1024

    @Test("a request below the 100 MB floor is raised to the floor")
    func belowFloor() {
        let r = CacheLimitPolicy.validate(requestedBytes: 10 * mb, freeDiskBytes: 100_000 * mb)
        #expect(r.allowedBytes == CacheLimitPolicy.minimumBytes)
        #expect(r.reason != nil)
    }

    @Test("a request above 80% of free disk is capped to the ceiling")
    func aboveCeiling() {
        let free = 1000 * mb
        let r = CacheLimitPolicy.validate(requestedBytes: 999 * mb, freeDiskBytes: free)
        #expect(r.allowedBytes == free / 5 * 4)
        #expect(r.reason == "Cache is limited to 80% of free disk space.")
    }

    @Test("a valid request passes through unchanged")
    func valid() {
        let r = CacheLimitPolicy.validate(requestedBytes: 500 * mb, freeDiskBytes: 100_000 * mb)
        #expect(r.allowedBytes == 500 * mb)
        #expect(r.reason == nil)
    }

    @Test("no free disk yields a zero allowance")
    func noDisk() {
        let r = CacheLimitPolicy.validate(requestedBytes: 500 * mb, freeDiskBytes: 0)
        #expect(r.allowedBytes == 0)
    }
}

@Suite("NetworkPolicy")
struct NetworkPolicyTests {
    @Test("local always plays; cached remote plays from cache")
    func localAndCached() {
        #expect(NetworkPolicy.decide(assetKind: .local, isCached: false,
                                     pathIsExpensive: true, streamOnCellular: false) == .play)
        #expect(NetworkPolicy.decide(assetKind: .remote, isCached: true,
                                     pathIsExpensive: true, streamOnCellular: false) == .playFromCache)
    }

    @Test("uncached remote on an expensive path is skipped unless cellular streaming is on")
    func expensivePath() {
        #expect(NetworkPolicy.decide(assetKind: .remote, isCached: false,
                                     pathIsExpensive: true, streamOnCellular: false) == .skipWiFiOnly)
        #expect(NetworkPolicy.decide(assetKind: .remote, isCached: false,
                                     pathIsExpensive: true, streamOnCellular: true) == .play)
    }

    @Test("nextPlayableIndex skips skipWiFiOnly entries and respects repeatAll")
    func nextPlayable() {
        let decisions: [PlaybackDecision] = [.play, .skipWiFiOnly, .skipWiFiOnly, .play]
        let next = NetworkPolicy.nextPlayableIndex(after: 0, count: 4, repeatAll: false) { decisions[$0] }
        #expect(next == 3)
        let none = NetworkPolicy.nextPlayableIndex(after: 3, count: 4, repeatAll: false) { decisions[$0] }
        #expect(none == nil)
        let wrap = NetworkPolicy.nextPlayableIndex(after: 3, count: 4, repeatAll: true) { decisions[$0] }
        #expect(wrap == 0)
    }
}

@Suite("PrefetchDepthPolicy")
struct PrefetchDepthPolicyTests {
    @Test("clamps to 0...5")
    func clamp() {
        #expect(PrefetchDepthPolicy.clamp(-3) == 0)
        #expect(PrefetchDepthPolicy.clamp(3) == 3)
        #expect(PrefetchDepthPolicy.clamp(99) == 5)
    }
}
