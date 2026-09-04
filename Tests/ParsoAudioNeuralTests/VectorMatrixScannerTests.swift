import Foundation
import Testing
@testable import ParsoAudioNeural

@Suite
struct VectorMatrixScannerTests {
    private func row(_ vector: [Float]) -> Data {
        let (int8, scale) = VectorQuantization.quantize(vector)
        var data = Data()
        withUnsafeBytes(of: scale) { data.append(contentsOf: $0) }
        data.append(VectorQuantization.data(int8))
        return data
    }

    @Test
    func scanReturnsExactMatchFirst() {
        let dims = 4
        let vectors: [[Float]] = [
            [1, 0, 0, 0],
            [0, 1, 0, 0],
            [0.9, 0.1, 0, 0],
        ]
        var matrix = Data()
        for v in vectors { matrix.append(row(v)) }

        let results = VectorMatrixScanner.scan(matrix: matrix, dims: dims,
                                               query: [1, 0, 0, 0],
                                               rowMapping: nil, topK: 3,
                                               isCancelled: { false })
        #expect(results.count == 3)
        #expect(results.first?.rowID == 0)
    }

    @Test
    func rowMappingSkipsUnmappedTombstonedRows() {
        let dims = 2
        var matrix = Data()
        matrix.append(row([1, 0]))
        matrix.append(row([1, 0]))
        // Only physical row 1 is live, mapped to logical id 42.
        let results = VectorMatrixScanner.scan(matrix: matrix, dims: dims,
                                               query: [1, 0],
                                               rowMapping: [1: 42], topK: 5,
                                               isCancelled: { false })
        #expect(results.count == 1)
        #expect(results.first?.rowID == 42)
    }

    @Test
    func cancellationStopsTheScanEarly() {
        let dims = 2
        var matrix = Data()
        for _ in 0..<5_000 { matrix.append(row([1, 0])) }
        let results = VectorMatrixScanner.scan(matrix: matrix, dims: dims,
                                               query: [1, 0],
                                               rowMapping: nil, topK: 10,
                                               isCancelled: { true })
        #expect(results.isEmpty)
    }
}
