import Testing
import Foundation
import ParsoAudioStreaming

@Suite("ByteRangeMap")
struct ByteRangeMapTests {
    @Test("empty map covers nothing")
    func empty() {
        let map = ByteRangeMap()
        #expect(map.ranges.isEmpty)
        #expect(map.totalBytes() == 0)
        #expect(map.contiguousBytes(from: 0) == 0)
        #expect(map.covers(total: 1) == false)
        #expect(map.covers(total: 0) == false)
    }

    @Test("empty and inverted ranges are ignored")
    func degenerateInserts() {
        var map = ByteRangeMap()
        map.insert(10..<10)
        #expect(map.ranges.isEmpty)
    }

    @Test("disjoint ranges stay separate and sorted")
    func disjoint() {
        var map = ByteRangeMap()
        map.insert(100..<200)
        map.insert(0..<50)
        #expect(map.ranges == [0..<50, 100..<200])
        #expect(map.totalBytes() == 150)
    }

    @Test("overlapping and adjacent ranges coalesce")
    func coalesce() {
        var map = ByteRangeMap()
        map.insert(0..<100)
        map.insert(50..<150)   // overlapping
        #expect(map.ranges == [0..<150])
        map.insert(150..<200)  // adjacent
        #expect(map.ranges == [0..<200])
    }

    @Test("an inserted range bridges two existing islands")
    func bridge() {
        var map = ByteRangeMap()
        map.insert(0..<100)
        map.insert(200..<300)
        map.insert(90..<210)
        #expect(map.ranges == [0..<300])
        #expect(map.totalBytes() == 300)
    }

    @Test("contiguousBytes measures from the offset, not the range start")
    func contiguousFromOffset() {
        var map = ByteRangeMap()
        map.insert(0..<1000)
        #expect(map.contiguousBytes(from: 0) == 1000)
        #expect(map.contiguousBytes(from: 400) == 600)
        #expect(map.contiguousBytes(from: 1000) == 0)  // upper bound is exclusive
        #expect(map.contiguousBytes(from: 2000) == 0)
    }

    @Test("a hole at the head means the file is not covered")
    func coverage() {
        var map = ByteRangeMap()
        map.insert(10..<1000)
        #expect(map.covers(total: 1000) == false)
        map.insert(0..<10)
        #expect(map.covers(total: 1000) == true)
        #expect(map.covers(total: 1001) == false)
    }

    @Test("round-trips through its persisted encoding")
    func roundTrip() {
        var map = ByteRangeMap()
        map.insert(0..<100)
        map.insert(500..<900)
        let restored = ByteRangeMap(data: map.encoded())
        #expect(restored == map)
    }

    @Test("garbage data decodes to an empty map rather than throwing")
    func corruptData() {
        let restored = ByteRangeMap(data: Data("not json".utf8))
        #expect(restored == ByteRangeMap())
    }
}
