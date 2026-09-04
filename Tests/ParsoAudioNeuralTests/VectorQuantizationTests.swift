import Foundation
import Testing
@testable import ParsoAudioNeural

@Suite
struct VectorQuantizationTests {
    @Test
    func quantizeDequantizeRoundTripsWithinTolerance() {
        let vector: [Float] = (0..<64).map { i in sin(Float(i) * 0.3) }
        let normalized = vector.map { $0 / sqrt(vector.reduce(Float(0)) { $0 + $1 * $1 }) }
        let (int8, scale) = VectorQuantization.quantize(normalized)
        let back = VectorQuantization.dequantize(int8, scale: scale)
        for (a, b) in zip(normalized, back) {
            #expect(abs(a - b) < 0.01)
        }
    }

    @Test
    func quantizeAllZeroVectorHasZeroScale() {
        let (int8, scale) = VectorQuantization.quantize([Float](repeating: 0, count: 8))
        #expect(scale == 0)
        #expect(int8.allSatisfy { $0 == 0 })
    }

    @Test
    func dataRoundTripsBytes() {
        let int8: [Int8] = [1, -1, 127, -127, 0]
        let data = VectorQuantization.data(int8)
        #expect(data.count == int8.count)
    }
}
