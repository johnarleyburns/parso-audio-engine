//
//  VectorMatrixScanner.swift
//  The brute-force cosine top-K scanner over a quantized vector matrix,
//  ported from parso-tonearm/Sources/DJ/Semantic/VectorStore.swift (the
//  `VectorMatch`/`VectorMatrixScanner` half only — the GRDB-backed
//  `VectorStore` persistence layer is storage-agnostic per-app policy and
//  stays in the consuming app). See ATTRIBUTION.md.
//
import Foundation
import Accelerate

/// One search hit: a caller-defined row id and its cosine similarity (≈ dot
/// for normalized vectors) to the query.
public struct VectorMatch: Sendable, Equatable {
    public let rowID: Int64
    public let similarity: Float

    public init(rowID: Int64, similarity: Float) {
        self.rowID = rowID
        self.similarity = similarity
    }
}

/// A pure brute-force cosine scanner: takes the mmap'd matrix bytes and the
/// query, returns the fixed-min-heap top-K. Deterministic and benchmarkable
/// in isolation — storage (what backs `matrix` and how `rowMapping` is built)
/// is entirely the caller's concern.
///
/// `vectors.i8`-style row layout: `Float32 scale (LE) + Int8[dims]`. The
/// per-row scale dequantizes the int8 row in one multiply, so a scan is a
/// block `vDSP_vflt8` + `vDSP_dotpr` per row — no per-element Swift work.
public enum VectorMatrixScanner {
    /// Bytes of the per-row scale prefix.
    public static let scaleByteCount = 4

    public static func rowBytes(dims: Int) -> Int { scaleByteCount + dims }

    /// Scan for the top-K nearest live rows. `query` must be L2-normalized.
    /// `rowMapping` maps physical row → a caller-defined row id for live rows;
    /// rows absent from it (tombstoned/orphaned) are skipped. Pass nil to
    /// treat every row as live with identity ids (the benchmark shape).
    /// `isCancelled` is polled between blocks so a caller can abandon the scan.
    public static func scan(matrix: Data,
                            dims: Int,
                            query: [Float],
                            rowMapping: [Int64: Int64]?,
                            topK: Int,
                            isCancelled: @escaping @Sendable () -> Bool) -> [VectorMatch] {
        guard dims > 0, topK > 0, query.count == dims else { return [] }
        let bytesPerRow = rowBytes(dims: dims)
        let rowCount = matrix.count / bytesPerRow
        guard rowCount > 0 else { return [] }

        var heap = FixedMinHeap(capacity: topK)
        let blockSize = 1_024
        matrix.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var blockFloats = [Float](repeating: 0, count: dims)
            var row = 0
            while row < rowCount {
                if isCancelled() { break }
                let end = min(row + blockSize, rowCount)
                while row < end {
                    if rowMapping == nil || rowMapping?[Int64(row)] != nil {
                        let pointer = base.advanced(by: row * bytesPerRow)
                        let scale = pointer.loadUnaligned(as: Float.self)
                        let int8 = pointer.advanced(by: scaleByteCount)
                            .assumingMemoryBound(to: Int8.self)
                        vDSP_vflt8(int8, 1, &blockFloats, 1, vDSP_Length(dims))
                        var dot: Float = 0
                        vDSP_dotpr(query, 1, blockFloats, 1, &dot, vDSP_Length(dims))
                        let rowID = rowMapping?[Int64(row)] ?? Int64(row)
                        heap.push(VectorMatch(rowID: rowID, similarity: scale * dot))
                    }
                    row += 1
                }
            }
        }
        return heap.sortedDescending()
    }
}

/// A fixed-capacity min-heap over `VectorMatch` by similarity — keeps only
/// the top-K seen so far, O(log K) per push, so a scan never materializes
/// the pool.
private struct FixedMinHeap {
    private var items: [VectorMatch] = []
    private let capacity: Int

    init(capacity: Int) {
        self.capacity = capacity
    }

    mutating func push(_ item: VectorMatch) {
        if items.count < capacity {
            items.append(item)
            siftUp(items.count - 1)
        } else if item.similarity > items[0].similarity {
            items[0] = item
            siftDown(0)
        }
    }

    /// The items in descending similarity order.
    func sortedDescending() -> [VectorMatch] {
        var heap = self
        var out: [VectorMatch] = []
        out.reserveCapacity(heap.items.count)
        while !heap.items.isEmpty {
            out.append(heap.items[0])
            guard heap.items.count > 1 else { break }
            heap.items[0] = heap.items.removeLast()
            heap.siftDown(0)
        }
        return out.reversed()
    }

    private mutating func siftUp(_ start: Int) {
        var child = start
        while child > 0 {
            let parent = (child - 1) / 2
            guard items[child].similarity < items[parent].similarity else { break }
            items.swapAt(child, parent)
            child = parent
        }
    }

    private mutating func siftDown(_ start: Int) {
        var parent = start
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var smallest = parent
            if left < items.count, items[left].similarity < items[smallest].similarity {
                smallest = left
            }
            if right < items.count, items[right].similarity < items[smallest].similarity {
                smallest = right
            }
            guard smallest != parent else { break }
            items.swapAt(parent, smallest)
            parent = smallest
        }
    }
}
