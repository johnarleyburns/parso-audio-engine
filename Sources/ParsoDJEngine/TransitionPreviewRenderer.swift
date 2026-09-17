import Foundation
import ParsoAudioCore
import ParsoAudioAnalysis

public struct TransitionPreviewConfiguration: Sendable, Equatable {
    public var preRollBars: Int
    public var postRollBars: Int
    public var sampleRate: Double

    public init(preRollBars: Int = 4, postRollBars: Int = 4,
                sampleRate: Double = 48_000) {
        self.preRollBars = max(0, preRollBars)
        self.postRollBars = max(0, postRollBars)
        self.sampleRate = sampleRate.isFinite && sampleRate > 0 ? sampleRate : 48_000
    }

    public static let `default` = TransitionPreviewConfiguration()
}

public struct TransitionPreviewSource: @unchecked Sendable {
    public let pcm: PCMBuffer
    public let analysis: FullAnalysisResult

    public init(pcm: PCMBuffer, analysis: FullAnalysisResult) {
        self.pcm = pcm
        self.analysis = analysis
    }
}

public struct TransitionPreview: @unchecked Sendable {
    public let pcm: PCMBuffer
    public let transitionStartFrame: Int64
    public let transitionEndFrame: Int64

    public init(pcm: PCMBuffer, transitionStartFrame: Int64,
                transitionEndFrame: Int64) {
        self.pcm = pcm
        self.transitionStartFrame = transitionStartFrame
        self.transitionEndFrame = transitionEndFrame
    }
}

@MainActor
public enum TransitionPreviewRenderer {
    public static func render(
        from outgoing: TransitionPreviewSource,
        to incoming: TransitionPreviewSource,
        proposal: AudioTransitionProposal,
        configuration: TransitionPreviewConfiguration = .default
    ) throws -> TransitionPreview {
        guard proposal.bars > 0, outgoing.pcm.frameCount > 0,
              incoming.pcm.frameCount > 0 else {
            throw TransitionSchedulingError.invalidAnchor
        }
        let sampleRate = configuration.sampleRate
        let engine = HeadlessDJEngine(sampleRate: sampleRate,
                                      maxFramesPerRender: 512,
                                      deckCount: 2, profile: .transitionLab)
        let outFormat = AudioFormat(sampleRate: outgoing.pcm.format.sampleRate, channelCount: 2)
        let inFormat = AudioFormat(sampleRate: incoming.pcm.format.sampleRate, channelCount: 2)
        engine.deckA.load(outgoing.analysis.trackAnalysis(format: outFormat), buffer: outgoing.pcm)
        engine.deckB.load(incoming.analysis.trackAnalysis(format: inFormat), buffer: incoming.pcm)
        engine.deckA.fader = 1
        engine.deckB.fader = 1
        engine.mixer.smartFader.isEnabled = true

        let bpm = max(1, outgoing.analysis.bpm ?? outgoing.analysis.beatGrid?.bpm ?? 120)
        let framesPerBar = max(1, Int((sampleRate * 60 / bpm * 4).rounded()))
        let preRoll = max(0, configuration.preRollBars) * framesPerBar
        let transitionFrames = max(1, Int((Double(proposal.bars) * Double(framesPerBar)).rounded()))
        let postRoll = max(0, configuration.postRollBars) * framesPerBar
        var left: [Float] = []
        var right: [Float] = []
        left.reserveCapacity(preRoll + transitionFrames + postRoll)
        right.reserveCapacity(preRoll + transitionFrames + postRoll)

        engine.deckA.seek(toSample: proposal.outSample, quantized: false)
        engine.deckB.seek(toSample: proposal.inSample, quantized: false)
        engine.deckA.play()
        append(render: engine.render(frames: preRoll), left: &left, right: &right)
        let transitionStart = engine.telemetry().masterSample
        try engine.mixer.smartFader.arm(from: engine.deckA, to: engine.deckB,
                                        proposal: proposal,
                                        startAtMasterFrame: transitionStart,
                                        tail: proposal.technique == .echoOut ? .echo : .none)
        append(render: engine.render(frames: transitionFrames), left: &left, right: &right)
        let transitionEnd = engine.telemetry().masterSample
        append(render: engine.render(frames: postRoll), left: &left, right: &right)

        let result = PCMBuffer(format: AudioFormat(sampleRate: sampleRate, channelCount: 2),
                               capacity: left.count)
        let outLeft = result.channel(0)
        let outRight = result.channel(1)
        for i in left.indices {
            outLeft[i] = left[i]
            outRight[i] = right[i]
        }
        return TransitionPreview(pcm: result,
                                 transitionStartFrame: transitionStart,
                                 transitionEndFrame: transitionEnd)
    }

    private static func append(
        render: (left: [Float], right: [Float]),
        left: inout [Float], right: inout [Float]
    ) {
        left.append(contentsOf: render.left)
        right.append(contentsOf: render.right)
    }
}
