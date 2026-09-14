//
//  Key.swift
//  Ported verbatim from parso-tonearm/Sources/DJ/Analysis/Key.swift
//  (audio-engine unification, docs/UNIFICATION_PLAN.md §4 Phase 5).
//

import Foundation
import Accelerate

/// Chroma (HPCP) configuration (§24.1). The CQT is a precomputed sparse kernel
/// applied to the STFT spectrum, folding log-spaced bins into 12 pitch classes.
public struct ChromaConfig: Sendable, Equatable {
    public var binsPerOctave: Int = 36
    public var minFreqHz: Double = 65.4      // C2
    public var octaves: Int = 5
    /// Upper frequency used by the sparse chroma projection.
    public var maxFreqHz: Double = 8_000
    /// Compression applied to spectral magnitudes before folding. Values
    /// below one reduce the dominance of a single loud partial.
    public var magnitudeExponent: Double = 1.0
    /// Harmonic weighting sharpens the tonic: each spectral partial also votes
    /// for the likely fundamental at 1/2×, 1/3× and 1/4× its frequency.
    public var harmonicWeighting: Bool = true

    public init(binsPerOctave: Int = 36, minFreqHz: Double = 65.4,
                octaves: Int = 5, harmonicWeighting: Bool = true,
                maxFreqHz: Double = 8_000, magnitudeExponent: Double = 1.0) {
        self.binsPerOctave = binsPerOctave
        self.minFreqHz = minFreqHz
        self.octaves = octaves
        self.harmonicWeighting = harmonicWeighting
        self.maxFreqHz = maxFreqHz
        self.magnitudeExponent = magnitudeExponent
    }
}

/// A 12-bin pitch-class energy profile (chroma / HPCP), indexed 0=C … 11=B.
public struct HPCP: Equatable, Sendable {
    public var values: [Float]

    public init(_ values: [Float] = [Float](repeating: 0, count: 12)) {
        precondition(values.count == 12)
        self.values = values
    }

    public subscript(_ pc: Int) -> Float {
        get { values[pc] }
        set { values[pc] = newValue }
    }

    public var sum: Float { values.reduce(0, +) }

    /// L1-normalize in place; returns `.zero` for a silent frame.
    public mutating func normalize() {
        let s = sum
        if s > 0 {
            for i in 0..<12 { values[i] /= s }
        } else {
            values = [Float](repeating: 0, count: 12)
        }
    }

    public func normalized() -> HPCP {
        var copy = self
        copy.normalize()
        return copy
    }
}

/// Key estimate (§24.2): tonic pitch class, mode, Camelot code and confidence.
public struct KeyEstimate: Equatable, Sendable {
    /// Tonic pitch class, 0=C … 11=B.
    public var tonic: Int
    public var isMinor: Bool
    public var camelot: CamelotKey
    /// Correlation margin, normalized to 0...1 (1 = unambiguous).
    public var confidence: Double
    /// Human-readable key name, e.g. "A minor".
    public var musicalKey: String

    public init(tonic: Int, isMinor: Bool, camelot: CamelotKey,
                confidence: Double, musicalKey: String) {
        self.tonic = tonic
        self.isMinor = isMinor
        self.camelot = camelot
        self.confidence = confidence
        self.musicalKey = musicalKey
    }
}

/// Camelot key notation (Appendix B): a wheel number 1...12 and a letter
/// A (minor) / B (major). Adjacent numbers on the wheel are harmonically close.
public struct CamelotKey: Hashable, Codable, Sendable {
    public var number: Int
    public var letter: Character

    public init(number: Int, letter: Character) {
        self.number = number
        self.letter = letter
    }

    /// Parse a stored Camelot code like "8A" or "12B". The letter is required;
    /// the number is 1...12. Returns nil for anything else.
    public init?(code: String) {
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let letter = trimmed.last, letter == "A" || letter == "B" else { return nil }
        let numberString = trimmed.dropLast()
        guard let number = Int(numberString), (1...12).contains(number) else { return nil }
        self.init(number: number, letter: letter)
    }

    public var code: String { "\(number)\(letter)" }

    // MARK: Codable — encoded as the "8A" code string, which round-trips and
    // keeps `VibeQuery`'s synthesized Codable unambiguous.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let code = try container.decode(String.self)
        guard let parsed = CamelotKey(code: code) else {
            throw DecodingError.dataCorruptedError(in: container,
                debugDescription: "Invalid Camelot code: \(code)")
        }
        self = parsed
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }

    /// The relative-major/minor partner (same number, other letter).
    public var relative: CamelotKey {
        CamelotKey(number: number, letter: letter == "A" ? "B" : "A")
    }
}

public enum KeyDetector {

    // MARK: - Per-frame chroma

    /// Per-frame HPCP from one spectrum (App. F.6, §24.1). Each FFT bin's
    /// magnitude folds into the nearest pitch class with a Gaussian weight
    /// (tuning tolerance, ~50 cents), so a tone off A440 still lands cleanly on
    /// its class instead of smearing. Optional harmonic weighting reinforces the
    /// tonic by also folding each observed partial at ÷2/÷3/÷4 to its likely
    /// fundamental with decaying weight.
    public static func chroma(_ spectrum: Spectrum, config: ChromaConfig = ChromaConfig()) -> HPCP {
        var c = HPCP()
        let binHz = spectrum.binHz
        // Gaussian half-width in semitones (~25 cents): wide enough to absorb
        // detuned instruments and FFT-bin quantization, narrow enough that a
        // tone folds onto exactly one pitch class.
        let tolerance = 0.25

        func fold(_ frequency: Double, _ weight: Float) {
            guard frequency >= config.minFreqHz / 2, frequency <= config.maxFreqHz else { return }
            let midi = 69 + 12 * log2(frequency / 440.0)
            let nearest = midi.rounded()
            let pc = ((Int(nearest) % 12) + 12) % 12
            // Gaussian distance in semitones → weight.
            let d = (midi - nearest) / tolerance
            let w = Float(exp(-0.5 * d * d))
            c[pc] += weight * w
        }

        for k in 1..<spectrum.power.count {
            let f = Double(k) * binHz
            let mag = spectrum.power[k].squareRoot()
            // Integrating every FFT-bin skirt counts broadband energy as if it
            // were tonal evidence. Keep local spectral maxima so a loud kick,
            // cymbal, or codec-noise shelf cannot overwhelm the pitch classes
            // carried by the musical partials.
            let previous = spectrum.power[k - 1].squareRoot()
            let next = k + 1 < spectrum.power.count
                ? spectrum.power[k + 1].squareRoot()
                : 0
            guard mag >= previous && mag >= next && mag > 1e-6 else { continue }
            let tonalMagnitude = Float(pow(Double(mag), config.magnitudeExponent))
            fold(f, tonalMagnitude)
            if config.harmonicWeighting {
                for h in 2...4 {
                    fold(f / Double(h), tonalMagnitude / Float(h))
                }
            }
        }
        return c.normalized()
    }

    /// Fuse broad-spectrum chroma with a mid-band tonal chroma. Dense mixes
    /// often contain fifths more prominently than their roots in the upper
    /// partials; the mid band carries stable vocal and melodic evidence while
    /// the broad view preserves the track's overall tonal field.
    public static func fusedChroma(_ spectrum: Spectrum) -> HPCP {
        let broad = chroma(spectrum, config: ChromaConfig(harmonicWeighting: false,
                                                           magnitudeExponent: 0.5))
        let mid = chroma(spectrum, config: ChromaConfig(harmonicWeighting: false,
                                                        minFreqHz: 500,
                                                        maxFreqHz: 2_000,
                                                        magnitudeExponent: 0.5))
        var fused = HPCP()
        for i in 0..<12 {
            // Keep the full tonal field present, while letting the mid band
            // carry more of the decision than sub-bass or codec/high-shelf
            // artefacts. Geometric agreement suppresses isolated resonances.
            let corroboratedMid = sqrt(broad[i] * mid[i])
            fused[i] = broad[i] * 0.35 + corroboratedMid * 0.65
        }
        return fused.normalized()
    }

    // MARK: - Key profiles

    /// Krumhansl–Schmuckler key profiles (major/minor), indexed by pitch class
    /// with the tonic at index 0. Correlated against all 12 rotations (§24.2).
    public static let krumhanslMajor: [Float] = [
        6.35, 2.23, 3.48, 2.33, 4.38, 4.09, 2.52, 5.19, 2.39, 3.66, 2.29, 2.88,
    ]
    public static let krumhanslMinor: [Float] = [
        6.33, 2.68, 3.52, 5.38, 2.60, 3.53, 2.54, 4.75, 3.98, 2.69, 3.34, 3.17,
    ]

    /// Pearson correlation between two length-12 vectors.
    static func correlate(_ a: [Float], _ b: [Float]) -> Double {
        var ma: Double = 0, mb: Double = 0
        for x in a { ma += Double(x) }
        for x in b { mb += Double(x) }
        ma /= 12; mb /= 12
        var num = 0.0, da = 0.0, db = 0.0
        for i in 0..<12 {
            let x = Double(a[i]) - ma
            let y = Double(b[i]) - mb
            num += x * y
            da += x * x
            db += y * y
        }
        let denom = sqrt(da * db)
        return denom > 1e-12 ? num / denom : 0
    }

    /// Average the per-frame chroma into one 12-vector (§24.2), optionally
    /// ignoring low-energy frames.
    public static func aggregate(_ frames: [HPCP]) -> HPCP {
        guard !frames.isEmpty else { return HPCP() }
        var sum = [Float](repeating: 0, count: 12)
        for f in frames {
            for i in 0..<12 { sum[i] += f.values[i] }
        }
        var out = HPCP(sum)
        out.normalize()
        return out
    }

    /// Aggregate only the stable part of a recording's chroma. A plain mean
    /// gives a short kick, fill, or codec artefact the same influence as a
    /// sustained harmonic frame. The per-pitch-class median is deliberately
    /// conservative: it preserves notes present through most of the track and
    /// suppresses one-frame transients without changing the public `aggregate`
    /// helper's documented arithmetic-mean semantics.
    static func stableAggregate(_ frames: [HPCP]) -> HPCP {
        guard !frames.isEmpty else { return HPCP() }
        var values = [Float](repeating: 0, count: frames.count)
        var median = [Float](repeating: 0, count: 12)
        for pc in 0..<12 {
            for (index, frame) in frames.enumerated() { values[index] = frame[pc] }
            values.sort()
            let middle = values.count / 2
            median[pc] = values.count.isMultiple(of: 2)
                ? (values[middle - 1] + values[middle]) * 0.5
                : values[middle]
        }
        var out = HPCP(median)
        out.normalize()
        return out
    }

    /// Estimate key from per-frame chroma (App. F.6, §24.2): correlate the
    /// aggregated profile against the 24 major/minor templates, pick the argmax,
    /// and derive confidence from the winner's margin over the runner-up.
    public static func estimate(_ frames: [HPCP],
                                config: KeyConfig = KeyConfig()) -> KeyEstimate? {
        guard !frames.isEmpty else { return nil }
        // Blend the stable and mean profiles. Median-only aggregation can
        // discard a legitimate section change, while mean-only aggregation is
        // too sensitive to isolated percussive frames; the stable profile gets
        // the stronger vote without discarding the track's overall evidence.
        let mean = aggregate(frames)
        let stable = stableAggregate(frames)
        let chroma = (0..<12).map { mean[$0] * 0.4 + stable[$0] * 0.6 }

        var bestTonic = 0
        var bestMinor = false
        var bestScore = -Double.greatestFiniteMagnitude
        var scores: [Double] = []

        for rot in 0..<12 {
            let rotated = (0..<12).map { chroma[(rot + $0) % 12] }
            let sMaj = correlate(rotated, krumhanslMajor)
            let sMin = correlate(rotated, krumhanslMinor)
            scores.append(sMaj)
            scores.append(sMin)
            if sMaj > bestScore { bestScore = sMaj; bestTonic = rot; bestMinor = false }
            if sMin > bestScore { bestScore = sMin; bestTonic = rot; bestMinor = true }
        }

        let secondBest = scores.sorted(by: >).dropFirst().first ?? 0
        let margin = max(0, bestScore - secondBest)
        let confidence = min(1.0, margin / 0.2)

        guard let camelot = Camelot.from(tonic: bestTonic, isMinor: bestMinor) else {
            return nil
        }
        let musicalKey = keyName(tonic: bestTonic, isMinor: bestMinor)
        return KeyEstimate(tonic: bestTonic, isMinor: bestMinor, camelot: camelot,
                           confidence: confidence, musicalKey: musicalKey)
    }

    /// "C major" / "F# minor" style display name.
    public static func keyName(tonic: Int, isMinor: Bool) -> String {
        let names = ["C", "C♯", "D", "E♭", "E", "F", "F♯", "G", "A♭", "A", "B♭", "B"]
        let pc = ((tonic % 12) + 12) % 12
        return "\(names[pc]) \(isMinor ? "minor" : "major")"
    }
}

/// Key detection configuration (§24.2).
public struct KeyConfig: Sendable, Equatable {
    public var minConfidence: Double = 0.3

    public init(minConfidence: Double = 0.3) {
        self.minConfidence = minConfidence
    }
}

/// Camelot wheel (§24.3, Appendix B): mapping from (tonic, mode) to the wheel,
/// plus harmonic-compatibility scoring shared with search re-rank.
public enum Camelot {

    /// Map a minor tonic's pitch class to its wheel number (Appendix B).
    /// 1A=A♭m … 12A=C♯m.
    static let minorNumber: [Int] = [
        /* 0 C  */ 5, /* 1 C♯ */ 12, /* 2 D  */ 7, /* 3 E♭ */ 2,
        /* 4 E  */ 9, /* 5 F  */ 4,  /* 6 F♯ */ 11, /* 7 G  */ 6,
        /* 8 A♭ */ 1, /* 9 A  */ 8,  /* 10 B♭ */ 3, /* 11 B */ 10,
    ]

    public static func from(tonic: Int, isMinor: Bool) -> CamelotKey? {
        let pc = ((tonic % 12) + 12) % 12
        if isMinor {
            return CamelotKey(number: minorNumber[pc], letter: "A")
        }
        // Major: wheel B at the same number as the relative minor (tonic − 3).
        let relativeMinor = ((pc - 3) % 12 + 12) % 12
        return CamelotKey(number: minorNumber[relativeMinor], letter: "B")
    }

    /// Compatible keys (Appendix B): same code, adjacent numbers on the wheel
    /// (±1 same letter), and the relative major/minor toggle.
    public static func compatible(_ key: CamelotKey) -> Set<CamelotKey> {
        var result: Set<CamelotKey> = [key, key.relative]
        for n in [key.number - 1, key.number + 1] {
            let wrapped = ((n - 1 + 12) % 12) + 1
            result.insert(CamelotKey(number: wrapped, letter: key.letter))
        }
        return result
    }

    /// Graded harmonic compatibility (§24.4): 1.0 identical, 0.9 relative
    /// maj/min, 0.7 ±1 same letter, 0.5 energy-boost (+7 semitones), 0.0 else.
    public static func compatibility(_ a: CamelotKey, _ b: CamelotKey) -> Float {
        if a == b { return 1.0 }
        if a.relative == b { return 0.9 }
        let da = ((a.number - b.number - 1 + 12) % 12) + 1
        if a.letter == b.letter && (da == 1 || da == 11) { return 0.7 }
        // Energy boost: +7 semitones maps A minor → the key a fifth above minor
        // degree — approximated as the number half a wheel away.
        let halfWheel = ((da - 1 + 12) % 12) + 1
        if halfWheel == 6 { return 0.5 }
        return 0.0
    }

    /// Camelot wheel distance in [0,1] for the sequencer's transition cost
    /// (§28A.2): `1 − compatibility`, so there is exactly one scoring
    /// implementation (§49.3). same 0.0, relative 0.1, ±1 same-letter 0.3,
    /// energy-boost 0.5, else 1.0. Either key missing → neutral 0.5 (the
    /// missing-attribute convention).
    public static func distance(_ a: CamelotKey?, _ b: CamelotKey?) -> Double {
        guard let a, let b else { return 0.5 }
        return 1 - Double(compatibility(a, b))
    }
}
