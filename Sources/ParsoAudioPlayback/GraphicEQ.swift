//
//  GraphicEQ.swift
//  The n-band ISO graphic EQ shared by Tonearm and Voxglass (both grew their own
//  RBJ peaking cascade driven through an MTAudioProcessingTap — see
//  docs/UNIFICATION_PLAN.md §3). This layer owns the DSP only: the `Biquad`
//  primitive, the peaking cascade, and a `Codable` settings value. Presets and
//  their persistence stay app-side (author decision, 2026-09-02) — the apps
//  disagree on preset identity (Tonearm name-keyed, Voxglass UUID-keyed) and on
//  where the curves are stored.
//
//  The bit-transparent-at-0-dB contract is load-bearing: when every band is at
//  0 dB (or the EQ is bypassed) `process` returns the input untouched, sample for
//  sample. Tonearm's null test is preserved verbatim in `GraphicEQTests`.
//

import Foundation

/// A single biquad peaking-EQ section (Direct Form I), matched to one ISO band.
/// Coefficients follow the Audio EQ Cookbook (RBJ) peaking filter. State is kept
/// in `Double` regardless of the caller's sample type so coefficient precision is
/// not the limiting factor at 44.1/48 kHz.
public struct BiquadSection: Sendable {
    public var b0: Double = 1, b1: Double = 0, b2: Double = 0
    public var a1: Double = 0, a2: Double = 0

    // Per-channel state (up to 2 channels).
    private var x1: (Double, Double) = (0, 0)
    private var x2: (Double, Double) = (0, 0)
    private var y1: (Double, Double) = (0, 0)
    private var y2: (Double, Double) = (0, 0)

    public init() {}

    /// Peaking EQ coefficients for a center frequency, gain (dB), Q and rate.
    public static func peaking(frequency: Double, gainDB: Double, q: Double, sampleRate: Double) -> BiquadSection {
        var bq = BiquadSection()
        let a = pow(10, gainDB / 40)
        let w0 = 2 * Double.pi * frequency / sampleRate
        let cosw0 = cos(w0)
        let alpha = sin(w0) / (2 * q)

        let b0 = 1 + alpha * a
        let b1 = -2 * cosw0
        let b2 = 1 - alpha * a
        let a0 = 1 + alpha / a
        let a1 = -2 * cosw0
        let a2 = 1 - alpha / a

        bq.b0 = b0 / a0
        bq.b1 = b1 / a0
        bq.b2 = b2 / a0
        bq.a1 = a1 / a0
        bq.a2 = a2 / a0
        return bq
    }

    /// Identity (unity) section — passes samples through unchanged.
    public static var identity: BiquadSection { BiquadSection() }

    public mutating func reset() {
        x1 = (0, 0); x2 = (0, 0); y1 = (0, 0); y2 = (0, 0)
    }

    public mutating func process(_ x: Double, channel: Int) -> Double {
        if channel <= 0 {
            let y = b0 * x + b1 * x1.0 + b2 * x2.0 - a1 * y1.0 - a2 * y2.0
            x2.0 = x1.0; x1.0 = x
            y2.0 = y1.0; y1.0 = y
            return y
        } else {
            let y = b0 * x + b1 * x1.1 + b2 * x2.1 - a1 * y1.1 - a2 * y2.1
            x2.1 = x1.1; x1.1 = x
            y2.1 = y1.1; y1.1 = y
            return y
        }
    }
}

/// An n-band graphic EQ: a cascade of peaking biquads at the ISO center
/// frequencies. Flat (every band 0 dB) or bypassed is bit-transparent.
public struct GraphicEQ: Sendable {
    /// ISO 10-band centers (Hz). Both apps use exactly this set.
    public static let isoBandFrequencies: [Double] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]
    public static let bandCount = 10

    /// Tonearm's peaking Q. Voxglass drives its cascade at Q 1.0 — pass `q: 1.0`
    /// there so neither app's EQ sound changes on adoption (author decision).
    public static let defaultQ = 1.41

    public private(set) var gains: [Double]
    public var bypassed: Bool
    public let sampleRate: Double
    public let q: Double
    private var sections: [BiquadSection]

    public init(sampleRate: Double = 48000,
                q: Double = GraphicEQ.defaultQ,
                frequencies: [Double] = GraphicEQ.isoBandFrequencies,
                gains: [Double]? = nil,
                bypassed: Bool = false) {
        self.sampleRate = sampleRate
        self.q = q
        self.frequencies = frequencies
        self.gains = GraphicEQ.fit(gains ?? Array(repeating: 0, count: frequencies.count), to: frequencies.count)
        self.bypassed = bypassed
        self.sections = GraphicEQ.makeSections(frequencies: frequencies, gains: self.gains, q: q, sampleRate: sampleRate)
    }

    private let frequencies: [Double]

    private static func fit(_ gains: [Double], to count: Int) -> [Double] {
        if gains.count == count { return gains }
        if gains.count > count { return Array(gains.prefix(count)) }
        return gains + Array(repeating: 0, count: count - gains.count)
    }

    private static func makeSections(frequencies: [Double], gains: [Double], q: Double, sampleRate: Double) -> [BiquadSection] {
        zip(frequencies, gains).map { freq, gain in
            gain == 0 ? .identity : .peaking(frequency: freq, gainDB: gain, q: q, sampleRate: sampleRate)
        }
    }

    public mutating func setGains(_ newGains: [Double]) {
        gains = GraphicEQ.fit(newGains, to: frequencies.count)
        sections = GraphicEQ.makeSections(frequencies: frequencies, gains: gains, q: q, sampleRate: sampleRate)
    }

    public mutating func reset() {
        for i in sections.indices { sections[i].reset() }
    }

    /// True when the EQ makes no change (bypassed or perfectly flat).
    public var isTransparent: Bool {
        bypassed || gains.allSatisfy { $0 == 0 }
    }

    /// Processes one sample through the cascade. When transparent, returns the
    /// input untouched (bit-exact) so bypass is provably lossless.
    public mutating func process(_ sample: Double, channel: Int) -> Double {
        guard !isTransparent else { return sample }
        var s = sample
        for i in sections.indices {
            s = sections[i].process(s, channel: channel)
        }
        return s
    }

    /// `Float` convenience for realtime taps, which deliver non-interleaved
    /// `Float` buffers. Transparent path is still bit-exact.
    public mutating func process(_ sample: Float, channel: Int) -> Float {
        guard !isTransparent else { return sample }
        return Float(process(Double(sample), channel: channel))
    }

    /// Offline render of a buffer (per channel), for testing / non-realtime use.
    public mutating func render(_ input: [Double], channel: Int = 0) -> [Double] {
        input.map { process($0, channel: channel) }
    }
}

/// User-facing EQ state: the per-band curve and whether the EQ is engaged. A pure
/// value — no UI, no I/O. Presets (and where they live) stay in the apps; this
/// only carries the resolved curve.
public struct GraphicEQSettings: Equatable, Codable, Sendable {
    public var bands: [Double]
    public var enabled: Bool

    public static let minGainDB: Double = -12
    public static let maxGainDB: Double = 12

    public init(bands: [Double], enabled: Bool) {
        self.bands = bands
        self.enabled = enabled
    }

    public static let flat = GraphicEQSettings(
        bands: Array(repeating: 0, count: GraphicEQ.bandCount),
        enabled: false)

    /// Clamps each band to ±12 dB and pads/truncates to `bandCount`.
    public func normalized(bandCount: Int = GraphicEQ.bandCount) -> GraphicEQSettings {
        var b = Array(bands.prefix(bandCount))
        if b.count < bandCount { b.append(contentsOf: Array(repeating: 0, count: bandCount - b.count)) }
        b = b.map { min(Self.maxGainDB, max(Self.minGainDB, $0)) }
        return GraphicEQSettings(bands: b, enabled: enabled)
    }

    /// The curve actually applied: the normalized bands when engaged, otherwise flat.
    public func effectiveGains(bandCount: Int = GraphicEQ.bandCount) -> [Double] {
        enabled ? normalized(bandCount: bandCount).bands : Array(repeating: 0, count: bandCount)
    }

    public var floatBands: [Float] { bands.map(Float.init) }
}

/// Built-in curve shapes, as raw gain arrays. Tonearm and Voxglass historically
/// shipped slightly different numbers for the same names; these are Tonearm's,
/// the gentler set, adopted as canonical.
public enum GraphicEQPresetCurves {
    public static let flat: [Double] = Array(repeating: 0, count: GraphicEQ.bandCount)
    public static let concertHall: [Double] = [3, 2.5, 1.5, 0, -1, -1, 0, 1.5, 2.5, 3]
    public static let spoken: [Double] = [-6, -4, -1, 2, 3, 3, 2, 1, 0, -2]
    public static let seventyEight: [Double] = [-9, -7, -3, 2, 4, 4, 2, -2, -6, -10]
}

/// A named EQ curve — a built-in or a user-saved preset. Shared across both apps
/// (author decision 2026-09-03, reversing Phase 3's "presets stay app-side"):
/// identity is a `UUID` (Voxglass's model — rename-safe, collision-free), gains
/// are `[Double]` to match `GraphicEQ` / `GraphicEQSettings`, with `floatGains`
/// for the apps' `Float` stores and UI. Each app keeps its **own** persistence
/// (`UserDefaults` keys, sync); only the value type is shared.
public struct EQPreset: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var gains: [Double]
    public var isBuiltIn: Bool

    public init(id: UUID = UUID(), name: String, gains: [Double], isBuiltIn: Bool = false) {
        self.id = id
        self.name = name
        self.gains = gains
        self.isBuiltIn = isBuiltIn
    }

    public var floatGains: [Float] { gains.map(Float.init) }

    // Built-ins carry stable UUIDs so a persisted `activePresetID` survives
    // relaunch and (if an app chooses) syncs.
    public static let flat = EQPreset(
        id: UUID(uuidString: "E0000000-0000-0000-0000-000000000001")!,
        name: "Flat", gains: GraphicEQPresetCurves.flat, isBuiltIn: true)

    public static let concertHall = EQPreset(
        id: UUID(uuidString: "E0000000-0000-0000-0000-000000000002")!,
        name: "Concert Hall", gains: GraphicEQPresetCurves.concertHall, isBuiltIn: true)

    public static let spoken = EQPreset(
        id: UUID(uuidString: "E0000000-0000-0000-0000-000000000003")!,
        name: "Spoken", gains: GraphicEQPresetCurves.spoken, isBuiltIn: true)

    public static let seventyEight = EQPreset(
        id: UUID(uuidString: "E0000000-0000-0000-0000-000000000004")!,
        name: "78 rpm", gains: GraphicEQPresetCurves.seventyEight, isBuiltIn: true)

    public static let builtIns: [EQPreset] = [.flat, .concertHall, .spoken, .seventyEight]

    /// A trimmed user preset from the current curve, or `nil` if the name is blank.
    public static func user(named name: String, gains: [Double]) -> EQPreset? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return EQPreset(name: trimmed, gains: gains, isBuiltIn: false)
    }
}
