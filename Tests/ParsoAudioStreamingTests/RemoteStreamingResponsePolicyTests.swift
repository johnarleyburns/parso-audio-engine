import Testing
@testable import ParsoAudioStreaming

@Suite("RemoteStreamingResponsePolicy")
struct RemoteStreamingResponsePolicyTests {

    @Test("206 with Content-Range parses total from the slash suffix")
    func probeRanged() {
        let r = RemoteStreamingResponsePolicy.probeResult(
            statusCode: 206, contentRange: "bytes 0-1023/8192", expectedContentLength: 1024)
        #expect(r == .ranged(totalBytes: 8192))
        #expect(r?.supportsByteRanges == true)
    }

    @Test("200 falls back to a full body of the expected length")
    func probeFullBody() {
        let r = RemoteStreamingResponsePolicy.probeResult(
            statusCode: 200, contentRange: nil, expectedContentLength: 4096)
        #expect(r == .fullBody(totalBytes: 4096))
        #expect(r?.supportsByteRanges == false)
    }

    @Test("unusable responses return nil")
    func probeNil() {
        #expect(RemoteStreamingResponsePolicy.probeResult(
            statusCode: 500, contentRange: nil, expectedContentLength: 1) == nil)
        #expect(RemoteStreamingResponsePolicy.probeResult(
            statusCode: 200, contentRange: nil, expectedContentLength: 0) == nil)
    }

    @Test("dataResponse rejects a 206 whose range start does not match the cursor")
    func dataResponseCursorMismatch() {
        #expect(RemoteStreamingResponsePolicy.dataResponse(
            statusCode: 206, contentRange: "bytes 100-199/500",
            expectedContentLength: 100, cursor: 0, knownTotalBytes: 500) == nil)
        #expect(RemoteStreamingResponsePolicy.dataResponse(
            statusCode: 206, contentRange: "bytes 100-199/500",
            expectedContentLength: 100, cursor: 100, knownTotalBytes: 500) == .ranged(start: 100))
    }

    @Test("dataResponse accepts a 200 full body only at cursor 0")
    func dataResponseFullBody() {
        #expect(RemoteStreamingResponsePolicy.dataResponse(
            statusCode: 200, contentRange: nil, expectedContentLength: 0,
            cursor: 0, knownTotalBytes: 700) == .fullBody(totalBytes: 700))
        #expect(RemoteStreamingResponsePolicy.dataResponse(
            statusCode: 200, contentRange: nil, expectedContentLength: 700,
            cursor: 50, knownTotalBytes: 700) == nil)
    }
}
