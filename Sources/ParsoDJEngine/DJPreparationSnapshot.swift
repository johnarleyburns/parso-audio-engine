import Foundation

public enum PreparationSnapshotError: Error, Sendable, Equatable {
    case unsupportedSchema(Int)
    case incompatibleDeckCount
    case invalidCueSlot(Int)
    case invalidDeckState
}

public struct HotCueSnapshot: Codable, Sendable, Equatable {
    public var slot: Int
    public var sample: Int64

    public init(slot: Int, sample: Int64) {
        self.slot = slot
        self.sample = sample
    }
}

public struct LoopSnapshot: Codable, Sendable, Equatable {
    public var startSample: Int64
    public var lengthBeats: Int
    public var isActive: Bool

    public init(startSample: Int64, lengthBeats: Int, isActive: Bool) {
        self.startSample = startSample
        self.lengthBeats = lengthBeats
        self.isActive = isActive
    }
}

public struct DeckPreparationSnapshot: Codable, Sendable, Equatable {
    public var playheadSample: Int64
    public var tempoPercent: Double
    public var keyLockEnabled: Bool
    public var keyShiftSemitones: Int
    public var hotCues: [HotCueSnapshot]
    public var loop: LoopSnapshot?

    public init(playheadSample: Int64, tempoPercent: Double,
                keyLockEnabled: Bool, keyShiftSemitones: Int,
                hotCues: [HotCueSnapshot], loop: LoopSnapshot?) {
        self.playheadSample = playheadSample
        self.tempoPercent = tempoPercent
        self.keyLockEnabled = keyLockEnabled
        self.keyShiftSemitones = keyShiftSemitones
        self.hotCues = hotCues
        self.loop = loop
    }
}

public struct DJPreparationSnapshot: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 1
    public var schemaVersion: Int
    public var decks: [DeckPreparationSnapshot]
    public var crossfader: Double

    public init(schemaVersion: Int = currentSchemaVersion,
                decks: [DeckPreparationSnapshot], crossfader: Double) {
        self.schemaVersion = schemaVersion
        self.decks = decks
        self.crossfader = crossfader
    }
}
