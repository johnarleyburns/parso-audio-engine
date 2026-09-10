// Linux-only Swift portability smoke test.
//
// This is intentionally compiled directly with swiftc instead of through
// Package.swift: the shipping Swift package includes Apple framework adapters,
// while these shared value/DSP-policy types are framework-free and should stay
// type-checkable on Linux.

import Foundation

@main
struct LinuxPortableSmoke {
    static func main() {
        var ranges = ByteRangeMap()
        ranges.insert(0..<32)
        ranges.insert(32..<64)
        precondition(ranges.covers(total: 64))
        precondition(ranges.contiguousBytes(from: 16) == 48)

        precondition(NetworkPolicy.decide(
            assetKind: .remote,
            isCached: false,
            pathIsExpensive: true,
            streamOnCellular: false
        ) == .skipWiFiOnly)
        precondition(PrefetchDepthPolicy.clamp(99) == 5)

        var eq = GraphicEQ(sampleRate: 48_000)
        let sample = 0.25
        precondition(eq.isTransparent)
        precondition(eq.process(sample, channel: 0) == sample)

        let gain = NormalizationPlanner(referenceLUFS: -14)
            .gain(fromIntegratedLUFS: -20)
        precondition(abs(gain - pow(10, 6 / 20)) < 1e-12)

        let probe = RemoteStreamingResponsePolicy.probeResult(
            statusCode: 206,
            contentRange: "bytes 0-99/1000",
            expectedContentLength: 100
        )
        precondition(probe == .ranged(totalBytes: 1000))

        print("Linux portable Swift smoke passed")
    }
}
