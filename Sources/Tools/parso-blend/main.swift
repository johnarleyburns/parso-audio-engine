// parso-blend — plan and render a two-track blend offline with the shipping code
// (BlendAnalyzer + BlendPlanner + MixEngine), for listening tests before a release.
//
// Usage: parso-blend <outgoing> <incoming> <out-dir> <label> [--bpm <outgoing> <incoming>]
// Writes <label>__<style>.wav (the outgoing from its start through the blend to
// the incoming's end, 16-bit) and <label>.json with the plans and listening marks.
// Without --bpm the approximate tempo comes from TrackAnalyzer, as on the phone.

import Foundation
import ParsoAudioCore
import ParsoAudioAnalysis
import ParsoMixEngine

@MainActor
func run() throws {
    var args = Array(CommandLine.arguments.dropFirst())
    if args.first == "--decode", args.count == 3 {
        // Debug: the decoded audio as raw float32 interleaved stereo.
        let buffer = try AudioFileReader(url: URL(fileURLWithPath: args[1])).readAll()
        var data = Data(capacity: buffer.frameCount * 8)
        let l = buffer.channel(0), r = buffer.channel(buffer.channelCount > 1 ? 1 : 0)
        for i in 0..<buffer.frameCount { var x = l[i], y = r[i]; data.append(Data(bytes: &x, count: 4)); data.append(Data(bytes: &y, count: 4)) }
        try data.write(to: URL(fileURLWithPath: args[2]))
        print(buffer.format.sampleRate, buffer.frameCount)
        return
    }
    if args.first == "--profile", args.count == 5, let start = Double(args[2]), let beats = Int(args[3]),
       let period = Double(args[4]) {
        // Debug: the groove profile of one window, as JSON (4 bands x bins).
        let buffer = try AudioFileReader(url: URL(fileURLWithPath: args[1])).readAll()
        let p = Groove.profile(buffer, start: start, beats: beats, period: period)
        let json = try JSONSerialization.data(withJSONObject: p?.envelopes.map { $0.map(Double.init) } ?? [])
        FileHandle.standardOutput.write(json)
        return
    }
    var bpms: (Double, Double)?
    if let i = args.firstIndex(of: "--bpm"), i + 2 < args.count, let x = Double(args[i + 1]), let y = Double(args[i + 2]) {
        bpms = (x, y)
        args.removeSubrange(i...(i + 2))
    }
    guard args.count == 4 else {
        FileHandle.standardError.write("usage: parso-blend <outgoing> <incoming> <out-dir> <label> [--bpm A B]\n".data(using: .utf8)!)
        exit(2)
    }
    let outDir = URL(fileURLWithPath: args[2])
    let label = args[3]
    try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    let a = try AudioFileReader(url: URL(fileURLWithPath: args[0])).readAll()
    var b = try AudioFileReader(url: URL(fileURLWithPath: args[1])).readAll()
    let sr = a.format.sampleRate
    if abs(b.format.sampleRate - sr) >= 0.5 {
        b = try SampleRateConverter(from: b.format.sampleRate, to: sr, channels: b.channelCount).convert(b)
    }
    let approxA = bpms?.0 ?? TrackAnalyzer().analyze(a).tempo.bpm
    let approxB = bpms?.1 ?? TrackAnalyzer().analyze(b).tempo.bpm
    let clock = ContinuousClock()
    let t0 = clock.now
    let aa = BlendAnalyzer.analyze(a, approximateBPM: approxA)
    let ab = BlendAnalyzer.analyze(b, approximateBPM: approxB)
    let t1 = clock.now
    print("\(label): \(String(format: "%.2f -> %.2f BPM (approx %.1f / %.1f), x%.5f", aa.grid.bpm, ab.grid.bpm, approxA, approxB, ab.grid.period / aa.grid.period))")
    print(String(format: "  grids: outgoing period %.6f phase %.4f (sharp %.2f), incoming period %.6f phase %.4f (sharp %.2f)",
                 aa.grid.period, aa.grid.phase, aa.grid.sharpness, ab.grid.period, ab.grid.phase, ab.grid.sharpness))
    print("  outgoing drops \(aa.drops.map { BlendPlanner.mmss(aa.beats[$0]) }), exits \(aa.exits.map { BlendPlanner.mmss(aa.beats[$0]) })")
    print("  incoming drops \(ab.drops.map { BlendPlanner.mmss(ab.beats[$0]) }), exits \(ab.exits.map { BlendPlanner.mmss(ab.beats[$0]) })")
    var rejected: [String] = []
    let plans = BlendPlanner.plan(outgoing: aa, outgoingAudio: a, incoming: ab, incomingAudio: b) { rejected.append($0) }
    let t2 = clock.now
    print("  analysis \(t1 - t0), planning \(t2 - t1)")

    var summary: [[String: Any]] = []
    for plan in plans {
        let engine = try MixEngine(sampleRate: sr)
        try engine.prepare(.a, buffer: a, sourcePosition: 0, tempo: 1)
        try engine.start(.a, atFrame: 0)
        try engine.schedule(plan, outgoing: .a, outgoingStartFrame: 0, incoming: b)
        let end = plan.incomingOffset + Double(b.frameCount) / sr / plan.tempo + 0.5
        let frames = Int(end * sr)
        var left = [Float](), right = [Float]()
        left.reserveCapacity(frames); right.reserveCapacity(frames)
        var done = 0
        while done < frames {
            let n = min(Int(sr) * 10, frames - done)
            let block = engine.render(frames: n)
            left += block.left; right += block.right
            done += n
        }
        let file = outDir.appendingPathComponent("\(label)__\(plan.style.rawValue).wav")
        try writeWAV(file, left: left, right: right, sampleRate: sr)
        let marks: [(String, Double)] = plan.style == .phraseCut
            ? [("outgoing fades over its last bar", plan.blendStart - 4 * plan.period),
               ("incoming starts on the phrase downbeat", plan.blendStart)]
            : [("blend starts: incoming highs fade in (no bass)", plan.blendStart),
               ("incoming highs at full", plan.blendStart + 16 * plan.period),
               ("bass swap on the downbeat", plan.swapTime),
               ("outgoing highs start fading out", plan.blendStart + 48 * plan.period),
               ("blend ends: incoming alone", plan.blendEnd)]
        print("  \(plan.style.rawValue): \(plan.reason); groove was \(String(format: "%+.1f", plan.grooveLag * 1000)) ms late "
              + "(band onsets \(plan.bandOnsetLags.map { String(format: "%+.0f", $0 * 1000) }.joined(separator: " ")), rival \(String(format: "%.2f", plan.rivalPeak)))")
        print("    \(file.path)  " + marks.map { BlendPlanner.mmss($0.1) }.joined(separator: " · "))
        summary.append(["file": file.path, "label": label, "style": plan.style.rawValue, "reason": plan.reason,
                        "period": plan.period, "tempo": plan.tempo, "gain": plan.incomingGain,
                        "blendStart": plan.blendStart, "incomingOffset": plan.incomingOffset,
                        "grooveLagMs": plan.grooveLag * 1000, "overlapBeats": plan.style == .phraseCut ? 0 : plan.overlapBeats,
                        "marks": marks.map { [$0.0, $0.1] as [Any] }])
    }
    if !rejected.isEmpty {
        print("  rejected (\(rejected.count)):\n    " + rejected.prefix(8).joined(separator: "\n    "))
    }
    let json = try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: outDir.appendingPathComponent("\(label).json"))
}

func writeWAV(_ url: URL, left: [Float], right: [Float], sampleRate: Double) throws {
    var peak: Float = 0
    for v in left { peak = max(peak, abs(v)) }
    for v in right { peak = max(peak, abs(v)) }
    let scale: Float = peak > 0.98 ? 0.98 / peak : 1
    var data = Data()
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
    let bytes = UInt32(left.count * 4)
    data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); data.append(contentsOf: Array("WAVEfmt ".utf8))
    u32(16); u16(1); u16(2); u32(UInt32(sampleRate)); u32(UInt32(sampleRate) * 4); u16(4); u16(16)
    data.append(contentsOf: Array("data".utf8)); u32(bytes)
    var pcm = [Int16](repeating: 0, count: left.count * 2)
    for i in left.indices {
        pcm[2 * i] = Int16(max(-1, min(1, left[i] * scale)) * 32767)
        pcm[2 * i + 1] = Int16(max(-1, min(1, right[i] * scale)) * 32767)
    }
    pcm.withUnsafeBytes { data.append(contentsOf: $0) }
    try data.write(to: url)
}

MainActor.assumeIsolated {
    do { try run() } catch {
        FileHandle.standardError.write("parso-blend: \(error)\n".data(using: .utf8)!)
        exit(1)
    }
}
