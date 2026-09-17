import Foundation
import ParsoAudioAnalysis

public enum TransitionEnergyDirection: String, Codable, Sendable {
    case steady, build, coolDown
}

public enum TransitionTechnique: String, Codable, Sendable, CaseIterable {
    case longBlend
    case bassSwap
    case filterBlend
    case echoOut
    case quickCut
}

public struct TransitionPlanningIntent: Codable, Sendable, Equatable {
    public var energyDirection: TransitionEnergyDirection
    public var maxTempoStretch: Double
    public var preferredBars: [Int]
    public var allowKeySync: Bool
    public var limit: Int

    public init(energyDirection: TransitionEnergyDirection = .steady,
                maxTempoStretch: Double = 0.06,
                preferredBars: [Int] = [8, 4, 16],
                allowKeySync: Bool = true, limit: Int = 5) {
        self.energyDirection = energyDirection
        self.maxTempoStretch = max(0, maxTempoStretch.isFinite ? maxTempoStretch : 0.06)
        self.preferredBars = preferredBars.filter { $0 > 0 }
        self.allowKeySync = allowKeySync
        self.limit = max(0, limit)
    }

    public static let `default` = TransitionPlanningIntent()
}

public struct TransitionVocalEvidence: Codable, Sendable, Equatable {
    /// Estimated share of the overlap containing simultaneous vocal material.
    public var overlap: Double
    public var confidence: Double

    public init(overlap: Double, confidence: Double = 1) {
        self.overlap = max(0, min(1, overlap.isFinite ? overlap : 0))
        self.confidence = max(0, min(1, confidence.isFinite ? confidence : 0))
    }
}

public struct TransitionClashMetrics: Codable, Sendable, Equatable {
    public var bassCollision: Double
    public var harmonicTension: Double
    public var spectralDensityOverlap: Double
    public var transientCompetition: Double
    public var vocalOverlap: Double?
    public var combined: Double

    public init(bassCollision: Double, harmonicTension: Double,
                spectralDensityOverlap: Double, transientCompetition: Double,
                vocalOverlap: Double? = nil, combined: Double? = nil) {
        self.bassCollision = Self.clamp(bassCollision)
        self.harmonicTension = Self.clamp(harmonicTension)
        self.spectralDensityOverlap = Self.clamp(spectralDensityOverlap)
        self.transientCompetition = Self.clamp(transientCompetition)
        self.vocalOverlap = vocalOverlap.map(Self.clamp)
        let base = self.bassCollision * 0.30 + self.harmonicTension * 0.25 +
            self.spectralDensityOverlap * 0.20 + self.transientCompetition * 0.15
        let result = combined ?? (self.vocalOverlap.map { (base + $0 * 0.10) / 1.10 } ?? base)
        self.combined = Self.clamp(result)
    }

    fileprivate static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, min(1, value))
    }
}

public struct TransitionScoreBreakdown: Codable, Sendable, Equatable {
    public var tempoFit: Double
    public var keyFit: Double
    public var phraseFit: Double
    public var energyFit: Double
    public var clashFit: Double
    public var semanticFit: Double?
    public var anchorConfidence: Double
    public var finalScore: Double

    public init(tempoFit: Double, keyFit: Double, phraseFit: Double,
                energyFit: Double, clashFit: Double, semanticFit: Double? = nil,
                anchorConfidence: Double, finalScore: Double) {
        self.tempoFit = Self.clamp(tempoFit)
        self.keyFit = Self.clamp(keyFit)
        self.phraseFit = Self.clamp(phraseFit)
        self.energyFit = Self.clamp(energyFit)
        self.clashFit = Self.clamp(clashFit)
        self.semanticFit = semanticFit.map(Self.clamp)
        self.anchorConfidence = Self.clamp(anchorConfidence)
        self.finalScore = Self.clamp(finalScore)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, min(1, value))
    }
}

public struct AudioTransitionProposal: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var outSample: Int64
    public var inSample: Int64
    public var outPhraseIndex: Int
    public var inPhraseIndex: Int
    public var bars: Int
    public var technique: TransitionTechnique
    public var incomingTempoRatio: Double
    public var keySyncRecommended: Bool
    public var keyShiftSemitones: Int?
    public var score: Double
    public var confidence: Double
    public var clashes: TransitionClashMetrics
    public var breakdown: TransitionScoreBreakdown

    public init(id: String, outSample: Int64, inSample: Int64,
                outPhraseIndex: Int, inPhraseIndex: Int, bars: Int,
                technique: TransitionTechnique, incomingTempoRatio: Double,
                keySyncRecommended: Bool, keyShiftSemitones: Int?, score: Double,
                confidence: Double, clashes: TransitionClashMetrics,
                breakdown: TransitionScoreBreakdown) {
        self.id = id
        self.outSample = outSample
        self.inSample = inSample
        self.outPhraseIndex = outPhraseIndex
        self.inPhraseIndex = inPhraseIndex
        self.bars = bars
        self.technique = technique
        self.incomingTempoRatio = incomingTempoRatio
        self.keySyncRecommended = keySyncRecommended
        self.keyShiftSemitones = keyShiftSemitones
        self.score = score
        self.confidence = confidence
        self.clashes = clashes
        self.breakdown = breakdown
    }
}

public enum TransitionPlanningError: Error, Sendable, Equatable {
    case insufficientAnalysis
    case incompatibleSampleDomain
}

public enum TransitionSchedulingError: Error, Sendable, Equatable {
    case invalidDeck
    case trackNotLoaded
    case invalidAnchor
    case invalidBarCount
    case tempoStretchExceeded
    case scheduleInPast
}

public enum TransitionPlanner {
    public static func proposals(
        from: FullAnalysisResult,
        to: FullAnalysisResult,
        intent: TransitionPlanningIntent = .default,
        semanticSimilarity: Double? = nil,
        vocalEvidence: TransitionVocalEvidence? = nil
    ) -> [AudioTransitionProposal] {
        guard intent.limit > 0 else { return [] }
        let outBPM = from.bpm ?? from.beatGrid?.bpm ?? 0
        let inBPM = to.bpm ?? to.beatGrid?.bpm ?? 0
        guard outBPM > 0, inBPM > 0 else { return [] }
        let outBeats = from.beatGrid?.beatSamples ?? []
        let inBeats = to.beatGrid?.beatSamples ?? []
        let outPhrases = usablePhrases(from, beats: outBeats)
        let inPhrases = usablePhrases(to, beats: inBeats)
        guard !outPhrases.isEmpty, !inPhrases.isEmpty else { return [] }
        let ratio = outBPM / inBPM
        let stretch = abs(ratio - 1)
        guard ratio.isFinite, ratio > 0,
              stretch <= intent.maxTempoStretch + 1e-9 else { return [] }

        var candidates: [AudioTransitionProposal] = []
        let bars = (intent.preferredBars.isEmpty ? [8, 4, 16] : intent.preferredBars)
        for (outIndex, outPhrase) in outPhrases.enumerated() {
            for (inIndex, inPhrase) in inPhrases.enumerated() {
                let baseClash = clashMetrics(outPhrase: outPhrase, inPhrase: inPhrase,
                                             fromKey: from.key, toKey: to.key,
                                             technique: .longBlend,
                                             vocalEvidence: vocalEvidence)
                let shift = keyShift(from: to.key, to: from.key)
                let keySync = intent.allowKeySync && shift.map({ abs($0) <= 6 }) == true &&
                    baseClash.harmonicTension > 0.30
                let keyFit = harmonicFit(out: outPhrase, to: inPhrase,
                                         fromKey: from.key, toKey: to.key,
                                         keySync: keySync)
                for bar in bars {
                    guard bar > 0 else { continue }
                    let technique = chooseTechnique(clash: baseClash, out: outPhrase,
                                                    incoming: inPhrase, bars: bar,
                                                    direction: intent.energyDirection)
                    let clashes = clashMetrics(outPhrase: outPhrase, inPhrase: inPhrase,
                                               fromKey: from.key, toKey: to.key,
                                               technique: technique, vocalEvidence: vocalEvidence)
                    let tempoFit = exp(-0.5 * pow(stretch / max(intent.maxTempoStretch, 0.01), 2))
                    let phraseFit = phraseFit(out: outPhrase, incoming: inPhrase, bars: bar)
                    let energy = energyFit(out: outPhrase, incoming: inPhrase,
                                           direction: intent.energyDirection)
                    let anchorConfidence = max(0, min(1,
                        (Double(outPhrase.confidence) + Double(inPhrase.confidence)) * 0.5))
                    let semantic = semanticSimilarity.map { max(0, min(1, $0.isFinite ? $0 : 0.5)) }
                    let keyValue = keySync ? max(keyFit, 0.85) : keyFit
                    let final = weightedScore(tempo: tempoFit, key: keyValue,
                                              phrase: phraseFit, energy: energy,
                                              clash: 1 - clashes.combined,
                                              anchor: anchorConfidence,
                                              semantic: semantic)
                    let breakdown = TransitionScoreBreakdown(
                        tempoFit: tempoFit, keyFit: keyValue, phraseFit: phraseFit,
                        energyFit: energy, clashFit: 1 - clashes.combined,
                        semanticFit: semantic, anchorConfidence: anchorConfidence,
                        finalScore: final)
                    let id = "\(outPhrase.startSample)-\(inPhrase.startSample)-\(bar)-\(technique.rawValue)"
                    candidates.append(AudioTransitionProposal(
                        id: id, outSample: outPhrase.startSample,
                        inSample: inPhrase.startSample, outPhraseIndex: outIndex,
                        inPhraseIndex: inIndex, bars: bar, technique: technique,
                        incomingTempoRatio: ratio, keySyncRecommended: keySync,
                        keyShiftSemitones: keySync ? shift : nil, score: final,
                        confidence: anchorConfidence, clashes: clashes,
                        breakdown: breakdown))
                }
            }
        }
        candidates.sort(by: stableOrder)
        var seen = Set<String>()
        return candidates.filter { seen.insert($0.id).inserted }.prefix(intent.limit).map { $0 }
    }

    public static func proposals(
        from: PortableAnalysisV1,
        to: PortableAnalysisV1,
        intent: TransitionPlanningIntent = .default,
        semanticSimilarity: Double? = nil,
        vocalEvidence: TransitionVocalEvidence? = nil
    ) -> [AudioTransitionProposal] {
        guard let a = try? from.fullAnalysisResult(), let b = try? to.fullAnalysisResult() else { return [] }
        return proposals(from: a, to: b, intent: intent,
                         semanticSimilarity: semanticSimilarity,
                         vocalEvidence: vocalEvidence)
    }

    private static func usablePhrases(_ result: FullAnalysisResult, beats: [Int64]) -> [Phrase] {
        if !result.phrases.isEmpty { return result.phrases }
        guard let first = beats.first else { return [] }
        let end = beats.last ?? first
        return [Phrase(startSample: first, endSample: end, startBeat: 0,
                       lengthBeats: max(4, beats.count), type: .build,
                       energy: result.energy?.scalar ?? 5, confidence: 0.35)]
    }

    private static func chooseTechnique(clash: TransitionClashMetrics, out: Phrase,
                                        incoming: Phrase, bars: Int,
                                        direction: TransitionEnergyDirection) -> TransitionTechnique {
        if clash.bassCollision > 0.62 { return .bassSwap }
        if clash.combined > 0.72 { return bars <= 4 ? .quickCut : .echoOut }
        if clash.spectralDensityOverlap > 0.48 { return .filterBlend }
        if bars >= 8 && (out.type == .outro || incoming.type == .intro || direction == .steady) {
            return .longBlend
        }
        return .filterBlend
    }

    private static func clashMetrics(outPhrase: Phrase, inPhrase: Phrase,
                                    fromKey: KeyEstimate?, toKey: KeyEstimate?,
                                    technique: TransitionTechnique,
                                    vocalEvidence: TransitionVocalEvidence?) -> TransitionClashMetrics {
        let a = outPhrase.descriptors
        let b = inPhrase.descriptors
        let bassA = a?.bassEnergy ?? 0.5
        let bassB = b?.bassEnergy ?? 0.5
        let bassDiscount = technique == .bassSwap ? 0.35 : 1
        let densityA = a?.spectralDensity ?? 0.5
        let densityB = b?.spectralDensity ?? 0.5
        let transientA = a?.transientDensity ?? 0.5
        let transientB = b?.transientDensity ?? 0.5
        let harmonic = harmonicTension(out: a?.localKey, incoming: b?.localKey,
                                       from: fromKey, to: toKey)
        return TransitionClashMetrics(
            bassCollision: bassA * bassB * bassDiscount,
            harmonicTension: harmonic,
            spectralDensityOverlap: densityA * densityB,
            transientCompetition: transientA * transientB,
            vocalOverlap: vocalEvidence.map { $0.overlap * $0.confidence })
    }

    private static func harmonicTension(out: PortableKey?, incoming: PortableKey?,
                                        from: KeyEstimate?, to: KeyEstimate?) -> Double {
        let a = out.flatMap { CamelotKey(code: $0.camelot) } ?? from?.camelot
        let b = incoming.flatMap { CamelotKey(code: $0.camelot) } ?? to?.camelot
        return Camelot.distance(a, b)
    }

    private static func harmonicFit(out: Phrase, to incoming: Phrase,
                                    fromKey: KeyEstimate?, toKey: KeyEstimate?,
                                    keySync: Bool) -> Double {
        if keySync { return 0.9 }
        return 1 - harmonicTension(out: out.descriptors?.localKey,
                                    incoming: incoming.descriptors?.localKey,
                                    from: fromKey, to: toKey)
    }

    private static func keyShift(from incoming: KeyEstimate?, to outgoing: KeyEstimate?) -> Int? {
        guard let incoming, let outgoing else { return nil }
        var delta = (outgoing.tonic - incoming.tonic) % 12
        if delta > 6 { delta -= 12 }
        if delta < -6 { delta += 12 }
        return delta
    }

    private static func phraseFit(out: Phrase, incoming: Phrase, bars: Int) -> Double {
        let expected = Double(max(1, bars * 4))
        let a = Double(max(1, out.lengthBeats))
        let b = Double(max(1, incoming.lengthBeats))
        let fitA = 1 - min(1, abs(a - expected) / max(a, expected))
        let fitB = 1 - min(1, abs(b - expected) / max(b, expected))
        return (fitA + fitB) * 0.5
    }

    private static func energyFit(out: Phrase, incoming: Phrase,
                                  direction: TransitionEnergyDirection) -> Double {
        let a = Double(out.descriptors?.energy ?? Double(out.energy)) / 10
        let b = Double(incoming.descriptors?.energy ?? Double(incoming.energy)) / 10
        let jump = abs(b - a)
        switch direction {
        case .steady: return max(0, 1 - jump)
        case .build: return max(0, min(1, 0.65 + (b - a) * 1.5))
        case .coolDown: return max(0, min(1, 0.65 + (a - b) * 1.5))
        }
    }

    private static func weightedScore(tempo: Double, key: Double, phrase: Double,
                                      energy: Double, clash: Double, anchor: Double,
                                      semantic: Double?) -> Double {
        let base = tempo * 0.20 + key * 0.17 + phrase * 0.20 + energy * 0.13 +
            clash * 0.20 + anchor * 0.10
        guard let semantic else { return clamp(base) }
        return clamp(base * 0.90 + semantic * 0.10)
    }

    private static func stableOrder(_ a: AudioTransitionProposal,
                                    _ b: AudioTransitionProposal) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.clashes.combined != b.clashes.combined { return a.clashes.combined < b.clashes.combined }
        if a.confidence != b.confidence { return a.confidence > b.confidence }
        if a.outSample != b.outSample { return a.outSample < b.outSample }
        if a.inSample != b.inSample { return a.inSample < b.inSample }
        return a.technique.rawValue < b.technique.rawValue
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return max(0, min(1, value))
    }
}
