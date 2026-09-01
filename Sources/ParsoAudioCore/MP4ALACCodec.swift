import Foundation
import Calac

/// A deliberately narrow ISO-BMFF profile for portable ALAC files.
///
/// The parser accepts one audio track, one ALAC sample description, one sample
/// per chunk, and explicit packet/sample tables. That is enough for files this
/// package writes while making malformed or unsupported profiles fail closed.
enum MP4ALACCodec {
    private struct Atom {
        let type: String
        let start: Int
        let payload: Range<Int>
        let end: Int
    }

    private struct Description {
        let cookie: Data
        let sampleRate: Double
        let channels: Int
        let bitDepth: Int
    }

    private struct Track {
        let description: Description
        let packetRanges: [Range<Int>]
        let packetFrames: [UInt32]
        let frameCount: Int
    }

    private static let containerTypes: Set<String> = [
        "moov", "trak", "mdia", "minf", "stbl", "dinf", "udta", "meta", "ilst"
    ]

    static func decode(_ data: Data) throws -> PCMBuffer {
        let track = try parse(data)
        var decoder: OpaquePointer?
        let createResult = track.description.cookie.withUnsafeBytes { rawBuffer in
            parso_alac_decoder_create(
                rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                UInt32(track.description.cookie.count),
                &decoder
            )
        }
        guard createResult == PARSO_ALAC_OK, let decoder else {
            throw AudioFileError.invalidFile("ALAC decoder rejected the magic cookie")
        }
        defer { parso_alac_decoder_destroy(decoder) }

        let output = PCMBuffer(
            format: AudioFormat(sampleRate: track.description.sampleRate, channelCount: track.description.channels),
            capacity: track.frameCount
        )
        let bytesPerSample = (track.description.bitDepth + 7) / 8
        let bytesPerFrame = track.description.channels * bytesPerSample
        let maximumPacketBytes = Int(parso_alac_decoder_frames_per_packet(decoder)) * bytesPerFrame
        guard maximumPacketBytes > 0 else {
            throw AudioFileError.invalidFile("invalid ALAC packet geometry")
        }

        var outputFrame = 0
        for (index, packetRange) in track.packetRanges.enumerated() {
            let packet = Data(data[packetRange])
            var decoded = [UInt8](repeating: 0, count: maximumPacketBytes)
            var decodedFrames: UInt32 = 0
            let result = packet.withUnsafeBytes { packetBytes in
                decoded.withUnsafeMutableBufferPointer { decodedBytes in
                    parso_alac_decoder_decode(
                        decoder,
                        packetBytes.baseAddress?.assumingMemoryBound(to: UInt8.self),
                        UInt32(packet.count),
                        decodedBytes.baseAddress,
                        UInt32(decodedBytes.count),
                        &decodedFrames
                    )
                }
            }
            guard result == PARSO_ALAC_OK,
                  decodedFrames > 0,
                  Int(decodedFrames) <= track.packetFrames[index] + 1 else {
                throw AudioFileError.invalidFile("ALAC packet decode failed")
            }

            let frames = min(Int(decodedFrames), track.frameCount - outputFrame)
            for frame in 0..<frames {
                for channel in 0..<track.description.channels {
                    let sampleOffset = frame * bytesPerFrame + channel * bytesPerSample
                    let integer: Int32
                    switch bytesPerSample {
                    case 2:
                        integer = Int32(Int16(bitPattern: readLE16(decoded, at: sampleOffset)))
                    case 3:
                        let raw = Int32(decoded[sampleOffset]) |
                            (Int32(decoded[sampleOffset + 1]) << 8) |
                            (Int32(decoded[sampleOffset + 2]) << 16)
                        integer = (raw & 0x0080_0000) != 0 ? raw | ~0x00FF_FFFF : raw
                    default:
                        integer = Int32(bitPattern: readLE32(decoded, at: sampleOffset))
                    }
                    let scale = pow(2.0, Double(track.description.bitDepth))
                    let storedScale = track.description.bitDepth == 20 ? scale * 16.0 : scale
                    output.channel(channel)[outputFrame + frame] = Float(Double(integer) / storedScale)
                }
            }
            outputFrame += frames
        }
        guard outputFrame == track.frameCount else {
            throw AudioFileError.invalidFile("ALAC sample tables do not match decoded frame count")
        }
        return output
    }

    static func write(_ buffer: PCMBuffer, to url: URL) throws {
        guard buffer.channelCount <= 8,
              buffer.format.sampleRate <= Double(UInt32.max),
              buffer.frameCount <= Int(UInt32.max) else {
            throw AudioFileError.formatMismatch
        }

        var encoder: OpaquePointer?
        let createResult = parso_alac_encoder_create(
            UInt32(buffer.format.sampleRate.rounded()),
            UInt32(buffer.channelCount),
            32,
            4096,
            0,
            &encoder
        )
        guard createResult == PARSO_ALAC_OK, let encoder else {
            throw AudioFileError.writeFailed("portable ALAC encoder could not be created")
        }
        defer { parso_alac_encoder_destroy(encoder) }

        var cookie = [UInt8](repeating: 0, count: 48)
        var cookieSize = UInt32(cookie.count)
        let cookieResult = cookie.withUnsafeMutableBufferPointer {
            parso_alac_encoder_copy_magic_cookie(encoder, $0.baseAddress, UInt32($0.count), &cookieSize)
        }
        guard cookieResult == PARSO_ALAC_OK else {
            throw AudioFileError.writeFailed("portable ALAC encoder did not provide a magic cookie")
        }
        let magicCookie = Data(cookie.prefix(Int(cookieSize)))

        var packets: [Data] = []
        var packetFrames: [UInt32] = []
        var offset = 0
        while offset < buffer.frameCount {
            let frames = min(4096, buffer.frameCount - offset)
            var pcm = Data()
            pcm.reserveCapacity(frames * buffer.channelCount * 4)
            for frame in 0..<frames {
                for channel in 0..<buffer.channelCount {
                    let value = max(-1.0, min(0.9999999995343387, Double(buffer.channel(channel)[offset + frame])))
                    let scaled = Int64((value * 2_147_483_648.0).rounded())
                    appendLE32(&pcm, UInt32(bitPattern: Int32(max(-2_147_483_648, min(2_147_483_647, scaled)))))
                }
            }
            var packet: UnsafeMutablePointer<UInt8>?
            var packetBytes: UInt32 = 0
            let result = pcm.withUnsafeBytes { rawBuffer in
                parso_alac_encoder_encode(
                    encoder,
                    rawBuffer.baseAddress?.assumingMemoryBound(to: UInt8.self),
                    UInt32(frames),
                    &packet,
                    &packetBytes
                )
            }
            guard result == PARSO_ALAC_OK, let packet, packetBytes > 0 else {
                if let packet { parso_alac_free(packet) }
                throw AudioFileError.writeFailed("portable ALAC packet encode failed")
            }
            packets.append(Data(bytes: packet, count: Int(packetBytes)))
            parso_alac_free(packet)
            packetFrames.append(UInt32(frames))
            offset += frames
        }

        var mediaData = Data()
        for packet in packets { mediaData.append(packet) }
        let ftyp = makeAtom("ftyp", data: Data([0x4D, 0x34, 0x41, 0x20, 0, 0, 0, 0,
                                                   0x4D, 0x34, 0x41, 0x20, 0x69, 0x73, 0x6F, 0x6D,
                                                   0x6D, 0x70, 0x34, 0x32]))
        let provisionalMoov = makeMoov(
            sampleRate: UInt32(buffer.format.sampleRate.rounded()),
            channels: buffer.channelCount,
            bitDepth: 32,
            frameCount: buffer.frameCount,
            magicCookie: magicCookie,
            packetFrames: packetFrames,
            packetSizes: packets.map { $0.count },
            packetOffsets: Array(repeating: 0, count: packets.count)
        )
        let mediaStart = ftyp.count + provisionalMoov.count + 8
        var packetOffsets: [Int] = []
        var packetOffset = mediaStart
        for packet in packets {
            packetOffsets.append(packetOffset)
            packetOffset += packet.count
        }
        let moov = makeMoov(
            sampleRate: UInt32(buffer.format.sampleRate.rounded()),
            channels: buffer.channelCount,
            bitDepth: 32,
            frameCount: buffer.frameCount,
            magicCookie: magicCookie,
            packetFrames: packetFrames,
            packetSizes: packets.map { $0.count },
            packetOffsets: packetOffsets
        )
        var file = Data()
        file.append(ftyp)
        file.append(moov)
        file.append(makeAtom("mdat", data: mediaData))
        do { try file.write(to: url, options: .atomic) }
        catch { throw AudioFileError.writeFailed(error.localizedDescription) }
    }

    private static func parse(_ data: Data) throws -> Track {
        guard data.count >= 16 else { throw AudioFileError.invalidFile("truncated ISO-BMFF file") }
        let atoms = try parseAtoms(data, range: 0..<data.count)
        guard atoms.contains(where: { $0.type == "ftyp" }),
              let moov = atoms.first(where: { $0.type == "moov" }),
              let mdat = atoms.first(where: { $0.type == "mdat" }) else {
            throw AudioFileError.invalidFile("missing ISO-BMFF movie or media data")
        }
        let nested = try parseAtoms(data, range: moov.payload)
        guard let mdhd = nested.first(where: { $0.type == "mdhd" }),
              let stsd = nested.first(where: { $0.type == "stsd" }),
              let stts = nested.first(where: { $0.type == "stts" }),
              let stsc = nested.first(where: { $0.type == "stsc" }),
              let stsz = nested.first(where: { $0.type == "stsz" }),
              let chunkTable = nested.first(where: { $0.type == "stco" || $0.type == "co64" }) else {
            throw AudioFileError.invalidFile("missing ALAC sample tables")
        }
        let description = try parseDescription(data, atom: stsd)
        let sampleRate = try parseTimescale(data, atom: mdhd)
        let packetFrames = try parseTimeToSample(data, atom: stts)
        let packetSizes = try parseSampleSizes(data, atom: stsz)
        let chunkOffsets = try parseChunkOffsets(data, atom: chunkTable)
        try validateSampleToChunk(data, atom: stsc, packetCount: packetSizes.count)
        guard packetFrames.count == packetSizes.count,
              chunkOffsets.count == packetSizes.count else {
            throw AudioFileError.invalidFile("ALAC sample table counts disagree")
        }
        let packetRanges = try zip(chunkOffsets, packetSizes).map { offset, size -> Range<Int> in
            guard offset >= mdat.payload.lowerBound,
                  size <= Int.max - offset,
                  offset + size <= mdat.payload.upperBound else {
                throw AudioFileError.invalidFile("ALAC chunk points outside mdat")
            }
            return offset..<(offset + size)
        }
        let totalFrames = packetFrames.reduce(into: 0) { result, count in
            guard result <= Int.max - Int(count) else { result = Int.max; return }
            result += Int(count)
        }
        guard totalFrames < Int.max else { throw AudioFileError.invalidFile("ALAC duration is too large") }
        return Track(
            description: Description(
                cookie: description.cookie,
                sampleRate: sampleRate,
                channels: description.channels,
                bitDepth: description.bitDepth
            ),
            packetRanges: packetRanges,
            packetFrames: packetFrames,
            frameCount: totalFrames
        )
    }

    private static func parseDescription(_ data: Data, atom: Atom) throws -> Description {
        guard atom.payload.count >= 8 else { throw AudioFileError.invalidFile("invalid ALAC sample description") }
        let entryStart = atom.payload.lowerBound + 8
        guard entryStart + 36 <= atom.payload.upperBound else {
            throw AudioFileError.invalidFile("truncated ALAC sample entry")
        }
        let entrySize = Int(readBE32(data, at: entryStart))
        guard entrySize >= 44, entrySize <= atom.payload.upperBound - entryStart,
              type(data, at: entryStart + 4) == "alac" else {
            throw AudioFileError.invalidFile("unsupported audio sample entry")
        }
        let channels = Int(readBE16(data, at: entryStart + 24))
        let bitDepth = Int(readBE16(data, at: entryStart + 26))
        let sampleRateFixed = readBE32(data, at: entryStart + 32)
        let childStart = entryStart + 36
        let children = try parseAtoms(data, range: childStart..<(entryStart + entrySize))
        guard let config = children.first(where: { $0.type == "alac" && ($0.payload.count == 28 || $0.payload.count == 52) }),
              channels > 0, channels <= 8,
              bitDepth == 16 || bitDepth == 20 || bitDepth == 24 || bitDepth == 32 else {
            throw AudioFileError.invalidFile("unsupported ALAC sample description")
        }
        return Description(
            cookie: Data(data[(config.payload.lowerBound + 4)..<config.payload.upperBound]),
            sampleRate: Double(sampleRateFixed) / 65_536.0,
            channels: channels,
            bitDepth: bitDepth
        )
    }

    private static func parseTimescale(_ data: Data, atom: Atom) throws -> Double {
        guard atom.payload.count >= 20 else { throw AudioFileError.invalidFile("invalid mdhd atom") }
        let version = data[atom.payload.lowerBound]
        if version == 0 {
            let timescale = readBE32(data, at: atom.payload.lowerBound + 12)
            guard timescale > 0 else { throw AudioFileError.invalidFile("invalid audio timescale") }
            return Double(timescale)
        }
        throw AudioFileError.invalidFile("version 1 mdhd is not supported")
    }

    private static func parseTimeToSample(_ data: Data, atom: Atom) throws -> [UInt32] {
        guard atom.payload.count >= 8 else { throw AudioFileError.invalidFile("invalid stts atom") }
        let count = Int(readBE32(data, at: atom.payload.lowerBound + 4))
        guard count > 0, count <= (atom.payload.count - 8) / 8 else {
            throw AudioFileError.invalidFile("invalid stts entry count")
        }
        var frames: [UInt32] = []
        for index in 0..<count {
            let entry = atom.payload.lowerBound + 8 + index * 8
            let samples = readBE32(data, at: entry)
            let delta = readBE32(data, at: entry + 4)
            guard samples == 1, delta > 0 else {
                throw AudioFileError.invalidFile("unsupported stts layout")
            }
            frames.append(delta)
        }
        return frames
    }

    private static func parseSampleSizes(_ data: Data, atom: Atom) throws -> [Int] {
        guard atom.payload.count >= 12 else { throw AudioFileError.invalidFile("invalid stsz atom") }
        let fixed = Int(readBE32(data, at: atom.payload.lowerBound + 4))
        let count = Int(readBE32(data, at: atom.payload.lowerBound + 8))
        guard count > 0, count <= (atom.payload.count - 12) / 4 else {
            throw AudioFileError.invalidFile("invalid stsz entry count")
        }
        if fixed > 0 { return Array(repeating: fixed, count: count) }
        return (0..<count).map { index in
            Int(readBE32(data, at: atom.payload.lowerBound + 12 + index * 4))
        }
    }

    private static func parseChunkOffsets(_ data: Data, atom: Atom) throws -> [Int] {
        guard atom.payload.count >= 8 else { throw AudioFileError.invalidFile("invalid chunk offset atom") }
        let count = Int(readBE32(data, at: atom.payload.lowerBound + 4))
        let entrySize = atom.type == "co64" ? 8 : 4
        guard count > 0, count <= (atom.payload.count - 8) / entrySize else {
            throw AudioFileError.invalidFile("invalid chunk offset count")
        }
        return try (0..<count).map { index in
            let entry = atom.payload.lowerBound + 8 + index * entrySize
            let value: UInt64 = atom.type == "co64" ? readBE64(data, at: entry) : UInt64(readBE32(data, at: entry))
            guard value <= UInt64(Int.max) else { throw AudioFileError.invalidFile("chunk offset is too large") }
            return Int(value)
        }
    }

    private static func validateSampleToChunk(_ data: Data, atom: Atom, packetCount: Int) throws {
        guard atom.payload.count >= 8 else { throw AudioFileError.invalidFile("invalid stsc atom") }
        let count = Int(readBE32(data, at: atom.payload.lowerBound + 4))
        guard count == 1, atom.payload.count >= 16,
              readBE32(data, at: atom.payload.lowerBound + 8) == 1,
              readBE32(data, at: atom.payload.lowerBound + 12) == 1,
              readBE32(data, at: atom.payload.lowerBound + 16) == 1,
              packetCount > 0 else {
            throw AudioFileError.invalidFile("unsupported stsc layout")
        }
    }

    private static func parseAtoms(_ data: Data, range: Range<Int>) throws -> [Atom] {
        var result: [Atom] = []
        var offset = range.lowerBound
        while offset < range.upperBound {
            guard range.upperBound - offset >= 8 else { throw AudioFileError.invalidFile("truncated ISO-BMFF atom") }
            let size32 = readBE32(data, at: offset)
            let atomType = type(data, at: offset + 4)
            var headerSize = 8
            let end: Int
            if size32 == 1 {
                guard range.upperBound - offset >= 16 else { throw AudioFileError.invalidFile("truncated extended atom") }
                let size64 = readBE64(data, at: offset + 8)
                guard size64 >= 16, size64 <= UInt64(Int.max) else { throw AudioFileError.invalidFile("invalid extended atom size") }
                headerSize = 16
                end = offset + Int(size64)
            } else if size32 == 0 {
                end = range.upperBound
            } else {
                guard size32 >= 8 else { throw AudioFileError.invalidFile("invalid atom size") }
                end = offset + Int(size32)
            }
            guard end > offset, end <= range.upperBound else { throw AudioFileError.invalidFile("atom exceeds parent") }
            let payloadStart = offset + headerSize
            let atom = Atom(type: atomType, start: offset, payload: payloadStart..<end, end: end)
            result.append(atom)
            if containerTypes.contains(atomType) {
                let childStart = atomType == "meta" ? min(atom.payload.upperBound, atom.payload.lowerBound + 4) : atom.payload.lowerBound
                if childStart < atom.payload.upperBound {
                    result.append(contentsOf: try parseAtoms(data, range: childStart..<atom.payload.upperBound))
                }
            }
            offset = end
        }
        return result
    }

    private static func makeMoov(sampleRate: UInt32, channels: Int, bitDepth: Int, frameCount: Int,
                                 magicCookie: Data, packetFrames: [UInt32], packetSizes: [Int], packetOffsets: [Int]) -> Data {
        var mvhd = Data(repeating: 0, count: 100)
        putBE32(&mvhd, at: 12, value: 1_000)
        putBE32(&mvhd, at: 16, value: UInt32(min(frameCount * 1_000 / max(1, Int(sampleRate)), Int(UInt32.max))))
        putBE32(&mvhd, at: 20, value: 0x0001_0000)
        putBE16(&mvhd, at: 24, value: 0x0100)

        var tkhd = Data(repeating: 0, count: 84)
        putBE32(&tkhd, at: 0, value: 7)
        putBE32(&tkhd, at: 12, value: 1)
        putBE32(&tkhd, at: 20, value: UInt32(min(frameCount, Int(UInt32.max))))
        putBE32(&tkhd, at: 36, value: 0x0001_0000)
        putBE32(&tkhd, at: 52, value: 0x0001_0000)
        putBE32(&tkhd, at: 56, value: 0x0001_0000)

        var mdhd = Data(repeating: 0, count: 24)
        putBE32(&mdhd, at: 12, value: sampleRate)
        putBE32(&mdhd, at: 16, value: UInt32(min(frameCount, Int(UInt32.max))))
        putBE16(&mdhd, at: 20, value: 0x55C4)

        var hdlr = Data(repeating: 0, count: 24)
        hdlr.replaceSubrange(8..<12, with: [0x73, 0x6F, 0x75, 0x6E])
        hdlr.append(contentsOf: Array("Parso ALAC".utf8) + [0])

        let smhd = Data(repeating: 0, count: 8)
        var url = Data(repeating: 0, count: 4)
        putBE32(&url, at: 0, value: 1)
        var dref = Data(repeating: 0, count: 8)
        putBE32(&dref, at: 4, value: 1)
        dref.append(makeAtom("url ", data: url))
        let dinf = makeAtom("dinf", data: makeAtom("dref", data: dref))

        var sampleEntry = Data(repeating: 0, count: 28)
        putBE16(&sampleEntry, at: 6, value: 1)
        putBE16(&sampleEntry, at: 16, value: UInt16(channels))
        putBE16(&sampleEntry, at: 18, value: UInt16(bitDepth))
        putBE32(&sampleEntry, at: 24, value: sampleRate << 16)
        sampleEntry.append(makeAtom("alac", data: Data(repeating: 0, count: 4) + magicCookie))
        let sampleDescription = makeAtom("alac", data: sampleEntry)
        var stsd = Data(repeating: 0, count: 8)
        putBE32(&stsd, at: 4, value: 1)
        stsd.append(sampleDescription)

        var stts = Data(repeating: 0, count: 8 + packetFrames.count * 8)
        putBE32(&stts, at: 4, value: UInt32(packetFrames.count))
        for (index, frames) in packetFrames.enumerated() {
            putBE32(&stts, at: 8 + index * 8, value: 1)
            putBE32(&stts, at: 12 + index * 8, value: frames)
        }
        var stsc = Data(repeating: 0, count: 20)
        putBE32(&stsc, at: 4, value: 1)
        putBE32(&stsc, at: 8, value: 1)
        putBE32(&stsc, at: 12, value: 1)
        putBE32(&stsc, at: 16, value: 1)
        var stsz = Data(repeating: 0, count: 12 + packetSizes.count * 4)
        putBE32(&stsz, at: 8, value: UInt32(packetSizes.count))
        for (index, size) in packetSizes.enumerated() { putBE32(&stsz, at: 12 + index * 4, value: UInt32(size)) }
        var stco = Data(repeating: 0, count: 8 + packetOffsets.count * 4)
        putBE32(&stco, at: 4, value: UInt32(packetOffsets.count))
        for (index, offset) in packetOffsets.enumerated() { putBE32(&stco, at: 8 + index * 4, value: UInt32(offset)) }
        let stbl = makeAtom("stbl", data: makeAtom("stsd", data: stsd) +
                            makeAtom("stts", data: stts) + makeAtom("stsc", data: stsc) + makeAtom("stsz", data: stsz) + makeAtom("stco", data: stco))
        let minf = makeAtom("minf", data: makeAtom("smhd", data: smhd) + dinf + stbl)
        let mdia = makeAtom("mdia", data: makeAtom("mdhd", data: mdhd) + makeAtom("hdlr", data: hdlr) + minf)
        let trak = makeAtom("trak", data: makeAtom("tkhd", data: tkhd) + mdia)
        return makeAtom("moov", data: makeAtom("mvhd", data: mvhd) + trak)
    }

    private static func makeAtom(_ type: String, data: Data) -> Data {
        var atom = Data()
        appendBE32(&atom, UInt32(8 + data.count))
        atom.append(contentsOf: type.utf8)
        atom.append(data)
        return atom
    }

    private static func type(_ data: Data, at offset: Int) -> String {
        String(bytes: data[offset..<(offset + 4)], encoding: .ascii) ?? ""
    }

    private static func readBE16(_ data: Data, at offset: Int) -> UInt16 {
        UInt16(data[offset]) << 8 | UInt16(data[offset + 1])
    }

    private static func readBE32(_ data: Data, at offset: Int) -> UInt32 {
        UInt32(data[offset]) << 24 | UInt32(data[offset + 1]) << 16 |
            UInt32(data[offset + 2]) << 8 | UInt32(data[offset + 3])
    }

    private static func readBE64(_ data: Data, at offset: Int) -> UInt64 {
        var result: UInt64 = 0
        for index in 0..<8 { result = (result << 8) | UInt64(data[offset + index]) }
        return result
    }

    private static func readLE16(_ data: [UInt8], at offset: Int) -> UInt16 {
        UInt16(data[offset]) | UInt16(data[offset + 1]) << 8
    }

    private static func readLE32(_ data: [UInt8], at offset: Int) -> UInt32 {
        UInt32(data[offset]) | UInt32(data[offset + 1]) << 8 |
            UInt32(data[offset + 2]) << 16 | UInt32(data[offset + 3]) << 24
    }

    private static func appendBE32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(truncatingIfNeeded: value >> 24))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value))
    }

    private static func appendLE32(_ data: inout Data, _ value: UInt32) {
        data.append(UInt8(truncatingIfNeeded: value))
        data.append(UInt8(truncatingIfNeeded: value >> 8))
        data.append(UInt8(truncatingIfNeeded: value >> 16))
        data.append(UInt8(truncatingIfNeeded: value >> 24))
    }

    private static func putBE16(_ data: inout Data, at offset: Int, value: UInt16) {
        data[offset] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 1] = UInt8(truncatingIfNeeded: value)
    }

    private static func putBE32(_ data: inout Data, at offset: Int, value: UInt32) {
        data[offset] = UInt8(truncatingIfNeeded: value >> 24)
        data[offset + 1] = UInt8(truncatingIfNeeded: value >> 16)
        data[offset + 2] = UInt8(truncatingIfNeeded: value >> 8)
        data[offset + 3] = UInt8(truncatingIfNeeded: value)
    }
}
