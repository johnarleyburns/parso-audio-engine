//
//  MasterOutputRouteTests.swift
//  Single-output split-cue combine logic (master + monitor bus -> one stereo
//  output), added so a device with no separate headphone bus (iPhone) can
//  still do the classic "cue in one ear, master in the other" trick.
//
//  `combineRoute` is the pure, allocation-free per-sample step the real-time
//  render block calls after rendering both buses; it is tested directly here
//  with plain buffers so this suite needs neither `AVAudioEngine` nor a real
//  audio device, and is exercised the same way whether CI has audio hardware
//  or not.
//

import Testing
import Foundation
@testable import ParsoDJEngine

@Suite("Master output route — single-output split cue")
struct MasterOutputRouteTests {
    /// Fills a small buffer, calls `combineRoute`, and returns the two output
    /// channels as plain arrays for easy assertion.
    private func combine(route: Int32, master: (l: Float, r: Float), cue: (l: Float, r: Float),
                          frames: Int = 4) -> (left: [Float], right: [Float]) {
        let masterL = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let masterR = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let cueL = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let cueR = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let outLeft = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let outRight = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        defer {
            masterL.deallocate(); masterR.deallocate(); cueL.deallocate(); cueR.deallocate()
            outLeft.deallocate(); outRight.deallocate()
        }
        for i in 0..<frames {
            masterL[i] = master.l; masterR[i] = master.r
            cueL[i] = cue.l; cueR[i] = cue.r
        }
        DJEngine.combineRoute(route, frameCount: frames, masterL: masterL, masterR: masterR,
                               cueL: cueL, cueR: cueR, outLeft: outLeft, outRight: outRight)
        return ((0..<frames).map { outLeft[$0] }, (0..<frames).map { outRight[$0] })
    }

    @Test func splitLeftPutsTheCueSignalOnTheLeftChannelAndMasterOnTheRight() {
        // Master is a full-scale stereo signal; cue is a distinct, easily
        // distinguished signal (as if a different, PFL-selected deck).
        let (left, right) = combine(route: 1, master: (l: 1.0, r: 1.0), cue: (l: -0.5, r: -0.5))
        #expect(left.allSatisfy { $0 == -0.5 })   // cue, mono-summed, on the left
        #expect(right.allSatisfy { $0 == 1.0 })   // master, mono-summed, on the right
    }

    @Test func splitRightPutsTheMasterOnTheLeftChannelAndCueOnTheRight() {
        let (left, right) = combine(route: 2, master: (l: 1.0, r: 1.0), cue: (l: -0.5, r: -0.5))
        #expect(left.allSatisfy { $0 == 1.0 })    // master, mono-summed, on the left
        #expect(right.allSatisfy { $0 == -0.5 })  // cue, mono-summed, on the right
    }

    @Test func monoSumAveragesRatherThanAddsSoAPannedSignalDoesNotClip() {
        // A signal hard-panned to one channel (e.g. L=1, R=0) must mono-sum to
        // 0.5, not 1.0 — a naive add would double full-scale content.
        let (left, right) = combine(route: 1, master: (l: 1.0, r: 0.0), cue: (l: 0.0, r: 1.0))
        #expect(left == [0.5, 0.5, 0.5, 0.5])
        #expect(right == [0.5, 0.5, 0.5, 0.5])
    }

    @Test func anyNonStereoRouteOtherThanSplitLeftBehavesAsSplitRight() {
        // combineRoute is only ever called (by makeRenderBlock) for a
        // non-zero route; any value other than 1 must fall back to the
        // splitRight placement rather than silently doing nothing.
        let (left, right) = combine(route: 99, master: (l: 1.0, r: 1.0), cue: (l: -0.5, r: -0.5))
        #expect(left.allSatisfy { $0 == 1.0 })
        #expect(right.allSatisfy { $0 == -0.5 })
    }
}

@Suite("Master output route — DJEngine public API")
@MainActor
struct MasterOutputRoutePublicAPITests {
    @Test func defaultsToStereoAndRoundTrips() {
        let engine = DJEngine()
        #expect(engine.masterOutputRoute == .stereo)
        engine.masterOutputRoute = .splitLeft
        #expect(engine.masterOutputRoute == .splitLeft)
        engine.masterOutputRoute = .splitRight
        #expect(engine.masterOutputRoute == .splitRight)
        engine.masterOutputRoute = .stereo
        #expect(engine.masterOutputRoute == .stereo)
    }

    @Test func allCasesAreStereoSplitLeftSplitRight() {
        #expect(Set(MasterOutputRoute.allCases) == [.stereo, .splitLeft, .splitRight])
    }
}
