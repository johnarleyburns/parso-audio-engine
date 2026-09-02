import Foundation
import CGlint

/// A deliberately narrow ISO-BMFF profile for portable AAC-LC files.
///
/// The demuxer accepts one audio track, one AAC-LC (`mp4a`) sample
/// description, ordinary (non-fragmented) ISO-BMFF sample tables, and one or
/// more media chunks. Raw MPEG-4 AAC access units are wrapped in synthetic
/// ADTS headers before they are handed to the existing Glint decoder.
enum MP4AACCodec {
    private struct Atom {
        let type: String
        let start: Int
        let payload: Range<Int>
        let end: Int
    }

    private struct Description {
        let sampleRate: Double
        let sampleRateIndex: Int
        let channels: Int
        let channelConfiguration: Int
    }

    private struct Track {
        let description: Description
        let packetRanges: [Range<Int>]
        let mediaFrameCount: Int
        let mediaStartFrame: Int
        let frameCount: Int
    }

    private static let containerTypes: Set<String> = [
        "moov", "trak", "edts", "mdia", "minf", "stbl", "dinf", "udta", "meta", "ilst"
    ]

    private static let sampleRates = [
        96_000, 88_200, 64_000, 48_000, 44_100, 32_000,
        24_000, 22_050, 16_000, 12_000, 11_025, 8_000, 7_350
    ]

    static func decode(_ data: Data) throws -> PCMBuffer {
        let track = try parse(data)
        var adts = Data()
        for packetRange in track.packetRanges {
            let packet = Data(data[packetRange])
            adts.append(try makeADTSHeader(for: packet.count, description: track.description))
            adts.append(packet)
        }
        guard !adts.isEmpty, adts.count <= Int(Int32.max) else {
            throw AudioFileError.invalidFile("AAC media data is empty or too large")
        }

        var sampleRate: Int32 = 0
        var channels: Int32 = 0
        var decodedFrames: Int32 = 0
        let decoded: UnsafeMutablePointer<Float>? = adts.withUnsafeBytes {
            (rawBuffer: UnsafeRawBufferPointer) -> UnsafeMutablePointer<Float>? in
            guard let baseAddress = rawBuffer.baseAddress else { return nil }
            return glint_decode_audio(
                baseAddress.assumingMemoryBound(to: UInt8.self),
                Int32(adts.count),
                &sampleRate,
                &channels,
                &decodedFrames
            )
        }
        guard let decoded, track.mediaFrameCount <= Int(Int32.max),
              track.mediaStartFrame <= Int(Int32.max), track.frameCount <= Int(Int32.max),
              sampleRate == Int32(track.description.sampleRate),
              channels == Int32(track.description.channels),
              decodedFrames >= Int32(track.mediaStartFrame),
              decodedFrames - Int32(track.mediaStartFrame) >= Int32(track.frameCount) else {
            if let decoded { glint_free(decoded) }
            throw AudioFileError.invalidFile("Glint AAC decode failed")
        }
        defer { glint_free(decoded) }

        let output = PCMBuffer(
            format: AudioFormat(sampleRate: track.description.sampleRate, channelCount: Int(channels)),
            capacity: track.frameCount
        )
        for frame in 0..<track.frameCount {
            let sourceFrame = track.mediaStartFrame + frame
            for channel in 0..<Int(channels) {
                output.channel(channel)[frame] = decoded[sourceFrame * Int(channels) + channel]
            }
        }
        return output
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
              let mvhd = nested.first(where: { $0.type == "mvhd" }),
              let stsd = nested.first(where: { $0.type == "stsd" }),
              let stts = nested.first(where: { $0.type == "stts" }),
              let stsc = nested.first(where: { $0.type == "stsc" }),
              let stsz = nested.first(where: { $0.type == "stsz" }),
              let chunkTable = nested.first(where: { $0.type == "stco" || $0.type == "co64" }) else {
            throw AudioFileError.invalidFile("missing AAC sample tables")
        }

        let description = try parseDescription(data, atom: stsd)
        let sampleRate = try parseTimescale(data, atom: mdhd)
        let movieTimescale = try parseTimescale(data, atom: mvhd)
        guard abs(sampleRate - description.sampleRate) < 0.5 else {
            throw AudioFileError.invalidFile("AAC sample description rate disagrees with mdhd")
        }

        let packetDurations = try parseTimeToSample(data, atom: stts)
        let packetSizes = try parseSampleSizes(data, atom: stsz)
        let chunkOffsets = try parseChunkOffsets(data, atom: chunkTable)
        let samplesPerChunk = try parseSampleToChunk(
            data, atom: stsc, chunkCount: chunkOffsets.count, packetCount: packetSizes.count
        )
        guard packetDurations.count == packetSizes.count else {
            throw AudioFileError.invalidFile("AAC sample table counts disagree")
        }

        var packetRanges: [Range<Int>] = []
        packetRanges.reserveCapacity(packetSizes.count)
        var packetIndex = 0
        for (chunkOffset, sampleCount) in zip(chunkOffsets, samplesPerChunk) {
            var offset = chunkOffset
            for _ in 0..<sampleCount {
                let size = packetSizes[packetIndex]
                guard size >= 1, size <= 8_184,
                      offset >= mdat.payload.lowerBound,
                      size <= Int.max - offset,
                      offset + size <= mdat.payload.upperBound else {
                    throw AudioFileError.invalidFile("AAC chunk points outside mdat")
                }
                packetRanges.append(offset..<(offset + size))
                offset += size
                packetIndex += 1
            }
        }
        guard packetIndex == packetSizes.count else {
            throw AudioFileError.invalidFile("AAC sample-to-chunk table does not cover samples")
        }

        let mediaFrameCount = packetDurations.reduce(into: 0) { result, duration in
            guard result <= Int.max - Int(duration) else { result = Int.max; return }
            result += Int(duration)
        }
        guard mediaFrameCount < Int.max else { throw AudioFileError.invalidFile("AAC duration is too large") }
        let editWindow = try parseEditWindow(
            data,
            atom: nested.first(where: { $0.type == "elst" }),
            mediaFrameCount: mediaFrameCount,
            mediaTimescale: sampleRate,
            movieTimescale: movieTimescale
        )
        return Track(
            description: description,
            packetRanges: packetRanges,
            mediaFrameCount: mediaFrameCount,
            mediaStartFrame: editWindow.start,
            frameCount: editWindow.count
        )
    }

    private static func parseDescription(_ data: Data, atom: Atom) throws -> Description {
        guard atom.payload.count >= 8 else { throw AudioFileError.invalidFile("invalid AAC sample description") }
        let entryStart = atom.payload.lowerBound + 8
        guard entryStart + 36 <= atom.payload.upperBound else {
            throw AudioFileError.invalidFile("truncated AAC sample entry")
        }
        let entrySize = Int(readBE32(data, at: entryStart))
        guard entrySize >= 36, entrySize <= atom.payload.upperBound - entryStart,
              type(data, at: entryStart + 4) == "mp4a" else {
            throw AudioFileError.invalidFile("unsupported audio sample entry")
        }
        let channels = Int(readBE16(data, at: entryStart + 24))
        let bitDepth = Int(readBE16(data, at: entryStart + 26))
        let sampleRateFixed = readBE32(data, at: entryStart + 32)
        let sampleRate = Double(sampleRateFixed) / 65_536.0
        let childStart = entryStart + 36
        let children = try parseAtoms(data, range: childStart..<(entryStart + entrySize))
        guard let esds = children.first(where: { $0.type == "esds" }),
              channels == 1 || channels == 2,
              bitDepth == 16 || bitDepth == 0,
              sampleRate.isFinite, sampleRate > 0 else {
            throw AudioFileError.invalidFile("unsupported AAC sample description")
        }
        let config = try decoderSpecificInfo(data, atom: esds)
        let parsedConfig = try parseAudioSpecificConfig(config)
        guard abs(parsedConfig.sampleRate - sampleRate) < 0.5,
              parsedConfig.channels == channels else {
            throw AudioFileError.invalidFile("AAC decoder configuration disagrees with sample entry")
        }
        return Description(
            sampleRate: parsedConfig.sampleRate,
            sampleRateIndex: parsedConfig.sampleRateIndex,
            channels: channels,
            channelConfiguration: parsedConfig.channelConfiguration
        )
    }

    private static func decoderSpecificInfo(_ data: Data, atom: Atom) throws -> Data {
        guard atom.payload.count >= 5 else { throw AudioFileError.invalidFile("invalid esds atom") }
        let searchRange = (atom.payload.lowerBound + 4)..<atom.payload.upperBound
        var offset = searchRange.lowerBound
        while offset < searchRange.upperBound {
            guard searchRange.upperBound - offset >= 2 else { break }
            if data[offset] == 0x05,
               let (length, headerBytes) = descriptorLength(data, at: offset + 1,
                                                              upperBound: searchRange.upperBound),
               headerBytes <= searchRange.upperBound - (offset + 1),
               length <= searchRange.upperBound - (offset + 1 + headerBytes) {
                let start = offset + 1 + headerBytes
                return Data(data[start..<(start + length)])
            }
            offset += 1
        }
        throw AudioFileError.invalidFile("esds has no decoder configuration")
    }

    private static func descriptorLength(_ data: Data, at offset: Int,
                                         upperBound: Int) -> (length: Int, headerBytes: Int)? {
        var value = 0
        for byteIndex in 0..<4 {
            let current = offset + byteIndex
            guard current < upperBound else { return nil }
            let byte = Int(data[current])
            guard value <= (Int.max >> 7) else { return nil }
            value = (value << 7) | (byte & 0x7F)
            if byte & 0x80 == 0 { return (value, byteIndex + 1) }
        }
        return nil
    }

    private static func parseAudioSpecificConfig(_ config: Data) throws ->
        (sampleRate: Double, sampleRateIndex: Int, channels: Int, channelConfiguration: Int) {
        var bitOffset = 0
        guard let objectTypeBits = readBits(config, offset: &bitOffset, count: 5) else {
            throw AudioFileError.invalidFile("truncated AAC decoder configuration")
        }
        var objectType = Int(objectTypeBits)
        if objectType == 31 {
            guard let extended = readBits(config, offset: &bitOffset, count: 6) else {
                throw AudioFileError.invalidFile("truncated AAC object type")
            }
            objectType = 32 + Int(extended)
        }
        guard objectType == 2 else {
            throw AudioFileError.invalidFile("only AAC-LC M4A is supported")
        }

        guard let frequencyBits = readBits(config, offset: &bitOffset, count: 4) else {
            throw AudioFileError.invalidFile("truncated AAC sample rate")
        }
        let sampleRateIndex = Int(frequencyBits)
        let sampleRate: Double
        if sampleRateIndex == 15 {
            guard let explicit = readBits(config, offset: &bitOffset, count: 24), explicit > 0 else {
                throw AudioFileError.invalidFile("invalid explicit AAC sample rate")
            }
            sampleRate = Double(explicit)
        } else {
            guard sampleRateIndex < sampleRates.count else {
                throw AudioFileError.invalidFile("unsupported AAC sample rate")
            }
            sampleRate = Double(sampleRates[sampleRateIndex])
        }

        guard let channelBits = readBits(config, offset: &bitOffset, count: 4) else {
            throw AudioFileError.invalidFile("truncated AAC channel configuration")
        }
        let channelConfiguration = Int(channelBits)
        let channels: Int
        switch channelConfiguration {
        case 1: channels = 1
        case 2: channels = 2
        default: throw AudioFileError.invalidFile("unsupported AAC channel configuration")
        }
        guard sampleRateIndex != 15 else {
            throw AudioFileError.invalidFile("explicit AAC sample rates cannot form ADTS headers")
        }
        return (sampleRate, sampleRateIndex, channels, channelConfiguration)
    }

    private static func readBits(_ data: Data, offset: inout Int, count: Int) -> UInt32? {
        guard count > 0, count <= 32, offset >= 0, offset <= data.count * 8 - count else { return nil }
        var result: UInt32 = 0
        for _ in 0..<count {
            let byte = offset / 8
            let bit = 7 - offset % 8
            result = (result << 1) | UInt32((data[byte] >> bit) & 1)
            offset += 1
        }
        return result
    }

    private static func makeADTSHeader(for payloadBytes: Int, description: Description) throws -> Data {
        let frameLength = payloadBytes + 7
        guard frameLength >= 7, frameLength <= 8_191,
              description.sampleRateIndex < 15,
              description.channelConfiguration > 0,
              description.channelConfiguration <= 7 else {
            throw AudioFileError.invalidFile("AAC access unit cannot be represented as ADTS")
        }
        let profile = 1 // AAC-LC object type 2, encoded as object type minus one.
        return Data([
            0xFF,
            0xF1,
            UInt8((profile << 6) | (description.sampleRateIndex << 2) |
                  ((description.channelConfiguration >> 2) & 1)),
            UInt8((description.channelConfiguration & 3) << 6 | ((frameLength >> 11) & 3)),
            UInt8((frameLength >> 3) & 0xFF),
            UInt8((frameLength & 7) << 5 | 0x1F),
            0xFC
        ])
    }

    private static func parseTimescale(_ data: Data, atom: Atom) throws -> Double {
        guard atom.payload.count >= 20, data[atom.payload.lowerBound] == 0 else {
            throw AudioFileError.invalidFile("unsupported versioned movie header")
        }
        let timescale = readBE32(data, at: atom.payload.lowerBound + 12)
        guard timescale > 0 else { throw AudioFileError.invalidFile("invalid movie timescale") }
        return Double(timescale)
    }

    private static func parseTimeToSample(_ data: Data, atom: Atom) throws -> [UInt32] {
        guard atom.payload.count >= 8 else { throw AudioFileError.invalidFile("invalid stts atom") }
        let count = Int(readBE32(data, at: atom.payload.lowerBound + 4))
        guard count > 0, count <= (atom.payload.count - 8) / 8 else {
            throw AudioFileError.invalidFile("invalid stts entry count")
        }
        var durations: [UInt32] = []
        for index in 0..<count {
            let entry = atom.payload.lowerBound + 8 + index * 8
            let samples = Int(readBE32(data, at: entry))
            let duration = readBE32(data, at: entry + 4)
            guard samples > 0, duration > 0,
                  durations.count <= 1_000_000 - samples else {
                throw AudioFileError.invalidFile("invalid stts layout")
            }
            durations.append(contentsOf: repeatElement(duration, count: samples))
        }
        return durations
    }

    private static func parseSampleSizes(_ data: Data, atom: Atom) throws -> [Int] {
        guard atom.payload.count >= 12 else { throw AudioFileError.invalidFile("invalid stsz atom") }
        let fixed = Int(readBE32(data, at: atom.payload.lowerBound + 4))
        let count = Int(readBE32(data, at: atom.payload.lowerBound + 8))
        guard count > 0, count <= 1_000_000,
              fixed == 0 ? count <= (atom.payload.count - 12) / 4 : true else {
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

    private static func parseSampleToChunk(_ data: Data, atom: Atom, chunkCount: Int,
                                           packetCount: Int) throws -> [Int] {
        guard atom.payload.count >= 8, chunkCount > 0 else {
            throw AudioFileError.invalidFile("invalid stsc atom")
        }
        let count = Int(readBE32(data, at: atom.payload.lowerBound + 4))
        guard count > 0, count <= (atom.payload.count - 8) / 12 else {
            throw AudioFileError.invalidFile("invalid stsc entry count")
        }

        struct Entry {
            let firstChunk: Int
            let samplesPerChunk: Int
        }
        var entries: [Entry] = []
        entries.reserveCapacity(count)
        var previousFirstChunk = 0
        for index in 0..<count {
            let entry = atom.payload.lowerBound + 8 + index * 12
            let firstChunk = Int(readBE32(data, at: entry))
            let samplesPerChunk = Int(readBE32(data, at: entry + 4))
            let sampleDescriptionIndex = readBE32(data, at: entry + 8)
            guard firstChunk > previousFirstChunk, firstChunk >= 1, firstChunk <= chunkCount,
                  samplesPerChunk > 0, samplesPerChunk <= packetCount,
                  sampleDescriptionIndex == 1 else {
                throw AudioFileError.invalidFile("unsupported stsc layout")
            }
            entries.append(Entry(firstChunk: firstChunk, samplesPerChunk: samplesPerChunk))
            previousFirstChunk = firstChunk
        }
        guard entries[0].firstChunk == 1 else {
            throw AudioFileError.invalidFile("stsc does not start at the first chunk")
        }

        var samplesPerChunk: [Int] = []
        samplesPerChunk.reserveCapacity(chunkCount)
        var entryIndex = 0
        var packetTotal = 0
        for chunk in 1...chunkCount {
            while entryIndex + 1 < entries.count && entries[entryIndex + 1].firstChunk <= chunk {
                entryIndex += 1
            }
            let samples = entries[entryIndex].samplesPerChunk
            guard packetTotal <= packetCount - samples else {
                throw AudioFileError.invalidFile("stsc contains too many samples")
            }
            samplesPerChunk.append(samples)
            packetTotal += samples
        }
        guard packetTotal == packetCount else {
            throw AudioFileError.invalidFile("stsc does not cover every sample")
        }
        return samplesPerChunk
    }

    private static func parseEditWindow(_ data: Data, atom: Atom?, mediaFrameCount: Int,
                                        mediaTimescale: Double, movieTimescale: Double) throws ->
        (start: Int, count: Int) {
        guard let atom else { return (0, mediaFrameCount) }
        guard atom.payload.count >= 8, data[atom.payload.lowerBound] == 0 else {
            throw AudioFileError.invalidFile("unsupported versioned edit list")
        }
        let entryCount = Int(readBE32(data, at: atom.payload.lowerBound + 4))
        guard entryCount > 0, entryCount <= (atom.payload.count - 8) / 12 else {
            throw AudioFileError.invalidFile("invalid edit list entry count")
        }

        var mediaEntry: (start: Int, count: Int)?
        for index in 0..<entryCount {
            let entry = atom.payload.lowerBound + 8 + index * 12
            let segmentDuration = Double(readBE32(data, at: entry))
            let mediaTime = Int32(bitPattern: readBE32(data, at: entry + 4))
            let mediaRateInteger = Int16(bitPattern: readBE16(data, at: entry + 8))
            let mediaRateFraction = readBE16(data, at: entry + 10)
            guard mediaRateInteger == 1, mediaRateFraction == 0 else {
                throw AudioFileError.invalidFile("unsupported edit media rate")
            }
            if mediaTime == -1 { continue }
            guard mediaTime >= 0, mediaEntry == nil else {
                throw AudioFileError.invalidFile("unsupported multiple media edits")
            }
            let start = Int(mediaTime)
            guard start < mediaFrameCount else { throw AudioFileError.invalidFile("edit starts past AAC media") }
            let requestedCount: Int
            if segmentDuration == 0 {
                requestedCount = mediaFrameCount - start
            } else {
                let frames = (segmentDuration / movieTimescale * mediaTimescale).rounded()
                guard frames.isFinite, frames > 0, frames <= Double(Int.max) else {
                    throw AudioFileError.invalidFile("invalid edit duration")
                }
                requestedCount = min(mediaFrameCount - start, Int(frames))
            }
            guard requestedCount > 0 else { throw AudioFileError.invalidFile("empty AAC media edit") }
            mediaEntry = (start, requestedCount)
        }
        guard let mediaEntry else { throw AudioFileError.invalidFile("edit list has no media entry") }
        return mediaEntry
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
                guard Int(size64) <= range.upperBound - offset else { throw AudioFileError.invalidFile("atom exceeds parent") }
                end = offset + Int(size64)
            } else if size32 == 0 {
                end = range.upperBound
            } else {
                guard size32 >= 8, Int(size32) <= range.upperBound - offset else {
                    throw AudioFileError.invalidFile("atom exceeds parent")
                }
                end = offset + Int(size32)
            }
            guard end > offset, end <= range.upperBound else { throw AudioFileError.invalidFile("atom exceeds parent") }
            let payloadStart = offset + headerSize
            result.append(Atom(type: atomType, start: offset, payload: payloadStart..<end, end: end))
            if containerTypes.contains(atomType) {
                let childStart = atomType == "meta" ? min(end, payloadStart + 4) : payloadStart
                if childStart < end {
                    result.append(contentsOf: try parseAtoms(data, range: childStart..<end))
                }
            }
            offset = end
        }
        return result
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
}
