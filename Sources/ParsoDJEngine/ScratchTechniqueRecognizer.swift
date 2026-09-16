//
//  ScratchTechniqueRecognizer.swift
//  Control-side classification of recorded platter and fader gestures.
//

import Foundation

/// A named classification of a recorded scratch gesture and its confidence.
public struct ScratchTechniqueRecognition: Equatable, Sendable {
    public let technique: ScratchTechnique
    public let confidence: Double

    public init(technique: ScratchTechnique, confidence: Double) {
        precondition(confidence.isFinite && (0...1).contains(confidence),
                     "Scratch recognition confidence must be within 0...1")
        self.technique = technique
        self.confidence = confidence
    }
}

/// Recognizes the control vocabulary of a scratch recording.
///
/// This is deliberately a small deterministic classifier rather than a
/// machine-learning dependency: technique names are driven by motion direction,
/// click count, and timing topology, so an editor can offer an immediate label
/// while preserving the original events for human correction. It runs on the
/// control actor or in an off-thread editor and never touches the audio graph.
public struct ScratchTechniqueRecognizer: Sendable {
    public init() {}

    public func recognize(_ pattern: ScratchPattern) -> ScratchTechniqueRecognition? {
        recognize(events: pattern.events)
    }

    public func recognize(events: [ScratchPatternEvent]) -> ScratchTechniqueRecognition? {
        guard !events.isEmpty else { return nil }
        let motion = events.filter { abs($0.deltaSamples) > 0.001 }
        guard !motion.isEmpty else { return nil }

        let signs = motion.map { $0.deltaSamples.sign == .minus ? -1 : 1 }
        let directionChanges = zip(signs, signs.dropFirst()).reduce(into: 0) { count, pair in
            if pair.0 != pair.1 { count += 1 }
        }
        let zeroMotion = events.count - motion.count
        let closedClicks = events.filter { !$0.faderOpen && abs($0.deltaSamples) <= 0.001 }.count
        let meanMovement = motion.map { abs($0.deltaSamples) }.reduce(0, +) / Double(motion.count)

        func result(_ technique: ScratchTechnique, _ confidence: Double) -> ScratchTechniqueRecognition {
            ScratchTechniqueRecognition(technique: technique, confidence: min(1, max(0, confidence)))
        }

        // Fader topologies are more distinctive than movement magnitude.
        if closedClicks > 0 {
            if signs == [1, -1, -1, 1] && closedClicks >= 2 {
                return result(.orbit, 0.91)
            }
            if motion.count >= 4 && directionChanges == 1 && closedClicks >= 2 {
                return result(.boomerang, 0.89)
            }
            if motion.count == 1 && closedClicks >= 2 && zeroMotion >= 3 {
                return result(.crab, 0.88)
            }
            if zeroMotion >= 5 {
                return result(.transform, 0.92)
            }
            if motion.count == 2 && closedClicks == 1 {
                // Chirp opens the fader for the return stroke; twiddle inserts
                // an open zero-motion interval before that return.
                if events.count > 2, abs(events[2].deltaSamples) <= 0.001 {
                    return result(.twiddle, 0.87)
                }
                return result(.chirp, 0.86)
            }
            if closedClicks >= 2 {
                return result(.flare, 0.80)
            }
            return result(.flare, 0.70)
        }

        if motion.count == 1 {
            return result(signs[0] > 0 ? .forward : .backward, 0.90)
        }
        if motion.count == 2 && directionChanges == 1 && meanMovement > 1_000 {
            return result(.drag, 0.82)
        }
        if motion.count >= 4 && directionChanges == 1 {
            return result(.tear, 0.84)
        }
        if directionChanges >= 3 && meanMovement < 700 {
            return result(.scribble, 0.90)
        }
        if directionChanges >= 2 {
            return result(.baby, 0.82)
        }
        return result(.drag, 0.65)
    }
}
