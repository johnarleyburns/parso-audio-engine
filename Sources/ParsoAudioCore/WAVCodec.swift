import Foundation

enum WAVCodec {
    static func decode(_ data: Data) throws -> PCMBuffer {
        guard data.count >= 12, bytes(data, equalTo: [0x52, 0x49, 0x46, 0x46], at: 0),
              bytes(data, equalTo: [0x57, 0x41, 0x56, 0x45], at: 8) else {
            throw AudioFileError.invalidFile("not a RIFF/WAVE file")
        }
        var formatCode = 0
        var channels = 0
        var sampleRate = 0
        var bitsPerSample = 0
        var blockAlign = 0
        var audioRange: Range<Int>?
        var offset = 12
        while offset + 8 <= data.count {
            let size = Int(readUInt32(data, at: offset + 4))
            let payload = offset + 8
            guard size >= 0, payload <= data.count, size <= data.count - payload else {
                throw AudioFileError.invalidFile("truncated WAVE chunk")
            }
            if bytes(data, equalTo: [0x66, 0x6D, 0x74, 0x20], at: offset) {
                guard size >= 16 else { throw AudioFileError.invalidFile("invalid WAVE format chunk") }
                formatCode = Int(readUInt16(data, at: payload))
                channels = Int(readUInt16(data, at: payload + 2))
                sampleRate = Int(readUInt32(data, at: payload + 4))
                blockAlign = Int(readUInt16(data, at: payload + 12))
                bitsPerSample = Int(readUInt16(data, at: payload + 14))
            } else if bytes(data, equalTo: [0x64, 0x61, 0x74, 0x61], at: offset) {
                audioRange = payload..<(payload + size)
            }
            let next = payload + size + (size & 1)
            guard next > offset else { throw AudioFileError.invalidFile("invalid WAVE chunk size") }
            offset = next
        }
        guard (formatCode == 1 || formatCode == 3), channels > 0, channels <= 32,
              sampleRate > 0, (bitsPerSample == 8 || bitsPerSample == 16 || bitsPerSample == 24 || bitsPerSample == 32),
              let audioRange, blockAlign >= channels * (bitsPerSample / 8),
              audioRange.count % blockAlign == 0 else {
            throw AudioFileError.invalidFile("unsupported WAVE format")
        }
        if formatCode == 3 && bitsPerSample != 32 {
            throw AudioFileError.invalidFile("only 32-bit float WAVE is supported")
        }
        let frames = audioRange.count / blockAlign
        let output = PCMBuffer(
            format: AudioFormat(sampleRate: Double(sampleRate), channelCount: channels),
            capacity: frames
        )
        for frame in 0..<frames {
            let frameOffset = audioRange.lowerBound + frame * blockAlign
            for channel in 0..<channels {
                let sampleOffset = frameOffset + channel * (bitsPerSample / 8)
                output.channel(channel)[frame] = decodeSample(
                    data, at: sampleOffset, formatCode: formatCode, bitsPerSample: bitsPerSample
                )
            }
        }
        return output
    }

    static func write(_ buffer: PCMBuffer, bitDepth: Int, to url: URL) throws {
        guard bitDepth == 8 || bitDepth == 16 || bitDepth == 24 || bitDepth == 32 else {
            throw AudioFileError.invalidFile("WAVE bit depth must be 8, 16, 24, or 32")
        }
        let bytesPerSample = bitDepth / 8
        let blockAlign = buffer.channelCount * bytesPerSample
        let dataSize = buffer.frameCount * blockAlign
        guard dataSize <= Int(UInt32.max), dataSize <= Int.max - 44 else {
            throw AudioFileError.writeFailed("WAVE file is too large")
        }
        var data = Data()
        data.reserveCapacity(44 + dataSize)
        data.append(contentsOf: [0x52, 0x49, 0x46, 0x46])
        appendUInt32(&data, UInt32(36 + dataSize))
        data.append(contentsOf: [0x57, 0x41, 0x56, 0x45])
        data.append(contentsOf: [0x66, 0x6D, 0x74, 0x20])
        appendUInt32(&data, 16)
        appendUInt16(&data, 1)
        appendUInt16(&data, UInt16(buffer.channelCount))
        appendUInt32(&data, UInt32(buffer.format.sampleRate.rounded()))
        appendUInt32(&data, UInt32(buffer.format.sampleRate.rounded()) * UInt32(blockAlign))
        appendUInt16(&data, UInt16(blockAlign))
        appendUInt16(&data, UInt16(bitDepth))
        data.append(contentsOf: [0x64, 0x61, 0x74, 0x61])
        appendUInt32(&data, UInt32(dataSize))
        for frame in 0..<buffer.frameCount {
            for channel in 0..<buffer.channelCount {
                let value = Double(buffer.channel(channel)[frame])
                switch bitDepth {
                case 8:
                    data.append(UInt8(max(0, min(255, Int((value * 127.5 + 128).rounded())))))
                case 16:
                    appendUInt16(&data, UInt16(bitPattern: Int16(quantize(value, scale: 32_768, min: -32_768, max: 32_767))))
                case 24:
                    let sample = quantize(value, scale: 8_388_608, min: -8_388_608, max: 8_388_607)
                    let raw = UInt32(bitPattern: Int32(sample))
                    data.append(UInt8(truncatingIfNeeded: raw))
                    data.append(UInt8(truncatingIfNeeded: raw >> 8))
                    data.append(UInt8(truncatingIfNeeded: raw >> 16))
                case 32:
                    appendUInt32(&data, UInt32(bitPattern: Int32(quantize(value, scale: 2_147_483_648, min: -2_147_483_648, max: 2_147_483_647))))
                default: break
                }
            }
        }
        try data.write(to: url, options: .atomic)
    }

    private static func decodeSample(_ data: Data, at offset: Int, formatCode: Int, bitsPerSample: Int) -> Float {
        if formatCode == 3 {
            return Float(bitPattern: readUInt32(data, at: offset))
        }
        switch bitsPerSample {
        case 8:
            return (Float(data[offset]) - 128) * (1.0 / 128.0)
        case 16:
            return Float(Int16(bitPattern: readUInt16(data, at: offset))) * (1.0 / 32_768.0)
        case 24:
            let raw = Int32(data[offset]) |
                (Int32(data[offset + 1]) << 8) |
                (Int32(data[offset + 2]) << 16)
            let signed = (raw & 0x0080_0000) != 0 ? raw | ~0x00FF_FFFF : raw
            return Float(signed) * (1.0 / 8_388_608.0)
        case 32:
            return Float(Int32(bitPattern: readUInt32(data, at: offset))) * (1.0 / 2_147_483_648.0)
        default:
            return 0
        }
    }

    private static func bytes(_ data: Data, equalTo expected: [UInt8], at offset: Int) -> Bool {
        guard offset >= 0, offset <= data.count, expected.count <= data.count - offset else { return false }
        return expected.indices.allSatisfy { data[offset + $0] == expected[$0] }
    }

    private static func readUInt16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) |
            (UInt32(data[offset + 1]) << 8) |
            (UInt32(data[offset + 2]) << 16) |
            (UInt32(data[offset + 3]) << 24)
    }

    private static func appendUInt16(_ data: inout Data, _ value: UInt16) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func quantize(_ value: Double, scale: Double, min lowerBound: Double, max upperBound: Double) -> Int64 {
        Int64(Swift.max(lowerBound, Swift.min(upperBound, (Swift.max(-1, Swift.min(0.9999999995343387, value)) * scale).rounded())))
    }
}


