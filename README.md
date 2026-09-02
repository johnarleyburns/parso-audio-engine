# parso-audio-engine

A permissively-licensed (MIT) Swift 6 package suite that reproduces the **full software
functionality of a Pioneer DDJ-FLX4** — two decks, a two-channel mixer, hot cues, loops, all eight
performance-pad modes, Beat FX / Color FX, Smart Fader / Smart CFX, a sampler, mic, monitoring, sync,
recording, and offline track analysis (BPM, key, waveform, structure, loudness) — with **no copyleft
dependencies** and Apple-native audio where it's the best free option.

It ships as three layered products so you can take only what you need:

| Product | What it gives you | Depends on |
|---|---|---|
| **ParsoAudioCore** | Buffers, file decode/encode, sample-rate conversion, loudness, DSP wrappers | — |
| **ParsoAudioAnalysis** | Offline BPM / key / structure / waveform | ParsoAudioCore |
| **ParsoDJEngine** | The complete two-deck DJ engine (FLX4-equivalent) | Core + Analysis |

---

## ⚠️ Status: test-driven scaffold

This repository is a **specification + scaffold**, not a finished build. It contains the full public
API, the complete engineering spec (`docs/SPEC.md`), and an **extensive test suite that acts as the
executable specification**. Most implementations are stubs that call `unimplemented()`; `PCMBuffer`
and all test-support/signal-generation code are real.

- `swift test` on a fresh clone is **green with skips**: the suites that exercise real plumbing
  (buffers, generators, the fixtures manifest, key-profile constants, DJ API surface) run and pass;
  suites that need the stubbed DSP/analysis/engine are written in full but marked `.disabled(...)`
  with a `docs/SPEC.md` reference. Remove the `.disabled` trait as you implement each layer.
- The C/C++ targets (`Cflac`, `Cvorbis`, `Copus`, `Cebur128`, `Csrc`, `CParsoDSP`, `CParsoEngine`)
  are **placeholder modules** that compile but do nothing; vendor the real permissive libraries per
  each `Sources/C*/VENDOR.md` and `docs/SPEC.md §2`.

Implement in the phase order in `docs/SPEC.md §19`; each phase turns a group of `.disabled` suites
green.

---

## Requirements

- **Swift 6** toolchain (Xcode 16+). The package sets `swiftLanguageModes: [.v6]` (strict concurrency).
- Platforms: **iOS 15+, iPadOS 15+, macCatalyst 15+, macOS 13+**.
- To run the real-audio fixture tests: `curl` + `python3` (both come with the Xcode command-line tools).

## Install (Swift Package Manager)

```swift
// Package.swift
dependencies: [
    .package(url: "https://github.com/<you>/parso-audio-engine.git", branch: "main")
],
targets: [
    .target(name: "YourDJApp", dependencies: [
        .product(name: "ParsoDJEngine", package: "parso-audio-engine")
    ])
]
```

## Repository layout

```
Sources/
  CParsoDSP/       real-time DSP kernels (C-API over C++); include/parso_dsp.h
  CParsoEngine/    real-time DJ render graph;               include/parso_engine.h
  Cflac Cvorbis Copus Cebur128 Csrc/  vendored decoders/loudness/SRC (placeholders + VENDOR.md)
  ParsoAudioCore/  Swift: buffers, IO, encode, SRC, loudness, DSP wrappers
  ParsoAudioAnalysis/ Swift + vDSP: tempo, key, structure, waveform
  ParsoDJEngine/   Swift @MainActor: decks, mixer, pads, FX, sampler, sync, recording
Tests/
  Support/         real signal generators, measurement, fixture loader
  Parso*Tests/     extensive Swift Testing suites (synthetic + real fixtures)
  Fixtures/        fixtures.json + downloaded audio (git-ignored)
docs/              SPEC.md · FLX4-feature-inventory.md · audio-library-sourcing.md · architecture.md
scripts/           download-fixtures.sh
```

## Vendoring the C dependencies

Each C target has a `VENDOR.md` with exact upstream + steps. Summary (all permissive):
libFLAC (BSD-3), stb_vorbis (public domain), libogg+libopus+libopusfile (BSD-3), libebur128 (MIT),
libsamplerate ≥ 0.2.2 (BSD-2), Signalsmith Stretch (MIT). CI fails if any GPL/LGPL/AGPL text lands in
the tree.

## Test fixtures (real Creative Commons tracks)

BPM/key/decode tests run against real House / disco / hip-hop / lofi tracks from Wikimedia Commons.
They are **downloaded at test time, never committed** (see `ATTRIBUTION.md`). The library decodes
every fixture format natively (FLAC, Ogg Vorbis, Opus, MP3), so no ffmpeg/transcode step is needed.

```bash
./scripts/download-fixtures.sh          # fetch into Tests/Fixtures/audio/ (git-ignored)
swift test                              # real-fixture suites auto-run once files are present
swift test --filter RealFixture         # just the fixture suites
```

Without the download, the fixture suites simply skip. To turn a track into a strict BPM/key
regression test, fill its verified `expected.bpm` / `expected.key` in `Tests/Fixtures/fixtures.json`
(until then those tests assert **determinism + plausibility**, not exact values).

## Human-visible acceptance videos

The Linux-compatible acceptance tool can produce a WAV plus JSON analysis sidecar, then render a
reviewable MP4 with waveform, beat/downbeat markers, section labels, and a synchronized playhead.
See [`docs/human-visible-acceptance.md`](docs/human-visible-acceptance.md). It uses system `ffmpeg`
only as developer tooling; ffmpeg is not a product dependency.

```bash
swift run ParsoAcceptanceArtifacts \
  --fixture gostreyshen_world \
  --scenario waveform \
  --output-dir artifacts/acceptance/gostreyshen_world
python3 scripts/render-acceptance-video.py \
  --audio artifacts/acceptance/gostreyshen_world/gostreyshen_world-waveform.wav \
  --analysis artifacts/acceptance/gostreyshen_world/gostreyshen_world-waveform.json \
  --output artifacts/acceptance/gostreyshen_world/gostreyshen_world-waveform.mp4
```

---

# Cookbook — one sample per FLX4 feature

These compile against the public API in `Sources/ParsoDJEngine`. All control objects are
`@MainActor`, so call from the main actor (e.g. inside SwiftUI actions or an `@MainActor` type).

### Create the engine & start audio

```swift
import ParsoDJEngine

@MainActor final class Rig {
    let engine = DJEngine(sampleRate: 48_000, maxFramesPerRender: 512)
    func boot() throws { try engine.start() }   // installs the render block
    func shutdown()     { engine.stop() }
}
```

### Load a track onto a deck (decode + analyze once, then hand off)

```swift
import ParsoAudioCore
import ParsoAudioAnalysis

func loadTrack(at url: URL, into deck: Deck) throws {
    let pcm = try AudioFileReader(url: url).readAll()          // FLAC/Ogg/Opus/MP3/AAC/WAV…
    let analysis = TrackAnalyzer(targetLUFS: -14).analyze(pcm) // BPM, key, waveform, structure, gain
    deck.load(analysis, buffer: pcm)
}
```

### Transport: play, pause, cue, stutter-start

```swift
deck.play()
deck.pause()
deck.setCue()          // set temp cue at current (paused) position
deck.jumpToCue()       // stutter/return to cue
```

### Temporary cue preview (hold to audition, release to return)

```swift
deck.cuePlayPress()    // preview from cue while held
deck.cuePlayRelease()  // snap back to cue on release
```

### Tempo range, tempo fader, and key lock (Master Tempo)

```swift
deck.tempoRange = .p16      // ±6 / ±10 / ±16 / .wide
deck.tempoPercent = -3.5    // move the tempo fader (percent within range)
deck.keyLock = true         // change tempo without changing pitch
```

### Pitch bend / nudge (temporary tempo push)

```swift
deck.nudge(+0.02)   // bend up to catch a beat
deck.nudge(-0.02)   // bend down
```

### Jog: scratch (vinyl mode) and search

```swift
deck.vinylMode = true          // ON = scratch, OFF = pitch bend
deck.jogTouchBegan()           // platter touched
deck.jogMoved(deltaSamples: 240)   // feed motion (samples of travel)
deck.jogTouchEnded()           // release → resume
```

### Loops: manual in/out, reloop/exit, auto beat loop, halve/double, move

```swift
deck.loopIn(); deck.loopOut()  // manual loop
deck.reloopExit()              // toggle the last loop on/off
deck.autoBeatLoop(beats: 4)    // instant 4-beat loop
deck.loopHalve(); deck.loopDouble()
deck.loopMove(beats: 1)        // shift the loop region
```

### Saved loops, active loop, and loop roll

```swift
deck.saveLoop(2)               // store the current loop in slot 2
deck.callLoop(2)               // recall it
deck.setActiveLoop(true)       // auto-activate a stored loop on approach
deck.autoBeatLoop(beats: 0.25) // "roll": a tiny slip-style loop (use slip, below)
```

### Eight hot cues (set / jump / delete)

```swift
deck.setHotCue(0)              // pads 0…7
deck.jumpHotCue(0)
deck.deleteHotCue(0)
```

### Beat Sync, master deck, quantize

```swift
deck.quantize = true           // snap actions to the beatgrid
deckA.setAsMaster()            // sync reference
deckB.sync()                   // match tempo + phase to master
```

### Slip mode

```swift
deck.slip = true               // playback continues underneath loops/cues…
deck.autoBeatLoop(beats: 1)
deck.reloopExit()              // …and resumes at the "shadow" position on exit
```

### Performance pads — mode 1: Hot Cue

```swift
deck.padMode = .hotCue
deck.padPress(3)               // jump to (or set) hot cue 3
```

### Pad mode 2: Keyboard (pitch-play a hot cue chromatically)

```swift
deck.padMode = .keyboard
deck.keyboardCueIndex = 0      // which hot cue is pitched across the pads
deck.padPress(5)               // play that cue +5 semitones
```

### Pad modes 3 & 4: Pad FX 1 / Pad FX 2 (assignable, momentary or latched)

```swift
deck.assignPadFX(bank: 1, pad: 0, effect: .roll,   hold: true)   // momentary
deck.assignPadFX(bank: 2, pad: 3, effect: .reverb, hold: false)  // latched
deck.padMode = .padFX1
deck.padPress(0); deck.padRelease(0)
```

### Pad mode 5: Beat Jump

```swift
deck.padMode = .beatJump
deck.beatJumpSize = 4
deck.padPress(0)   // jump back
deck.padPress(1)   // jump forward
```

### Pad mode 6: Beat Loop (instant fixed-length loops)

```swift
deck.padMode = .beatLoop
deck.padPress(2)   // e.g. a 4-beat instant loop mapped to pad 2
```

### Pad mode 7: Sampler (16 slots)

```swift
engine.sampler.load(0, buffer: try AudioFileReader(url: hitURL).readAll())
engine.sampler.setMode(0, .oneShot)
deck.padMode = .sampler
deck.padPress(0)   // trigger slot 0
// or directly: engine.sampler.trigger(0)
```

### Pad mode 8: Key Shift

```swift
deck.padMode = .keyShift
deck.padPress(7)   // shift the playing track up N semitones (pitch only; tempo unchanged)
```

### Channel trim / gain

```swift
engine.mixer.channelA.trim = 0.6
```

### 3-band EQ with full kill

```swift
let ch = engine.mixer.channelA
ch.eqLow = -.infinity   // kill the bass
ch.eqMid = 0
ch.eqHigh = 2           // +2 dB
```

### Color FX (default Filter, plus assignable variants)

```swift
ch.colorFX = .filter    // .filter/.space/.dubEcho/.sweep/.noise/.crush/.pitch
ch.colorAmount = -0.4   // left of center = LPF sweep, right = HPF (for .filter)
```

### Beat FX (select, beats, depth, assign, on, release-with-tail)

```swift
let fx = engine.mixer.beatFX
fx.kind = .echo         // 14 kinds incl. .reverb .flanger .phaser .roll .spiral .vinylBrake …
fx.beats = 0.5          // tempo-synced division
fx.depth = 0.6
fx.assign = .chA        // .chA/.chB/.both/.master
fx.isOn = true
fx.releaseFX()          // let the tail ring out
```

### Crossfader, curve, assignment, and fader start

```swift
engine.mixer.crossfader = -1          // −1 = A, +1 = B
engine.mixer.crossfaderCurve = .sharp // .smooth (equal-power) / .linear / .sharp
engine.mixer.channelA.crossfaderAssign = .a
engine.mixer.channelA.faderStart = true  // moving the fader up starts the deck from cue
```

### Headphone monitoring (PFL, cue/master blend, level)

```swift
engine.mixer.channelA.cuePFL = true   // pre-listen channel A
engine.monitoring.cueMasterMix = 0.3  // 0 = cue only … 1 = master only
engine.monitoring.headphoneLevel = 0.7
engine.monitoring.masterCue = false
```

### Master level, limiter, master cue, and metering

```swift
engine.mixer.master.level = 0.85
engine.mixer.master.limiterCeilingDB = -0.3
engine.mixer.master.masterCue = true
let peak = engine.mixer.master.peakMeter      // 0…1, for a VU meter
let chPeak = engine.mixer.channelA.peakMeter
```

### Microphone (summed to master + recording)

```swift
engine.mic.isMuted = false
engine.mic.level = 0.5
engine.mic.submit(capturedMicBuffer)   // app supplies the capture path
```

### Smart Fader (assisted transition: BPM match + EQ + level + tail)

```swift
let sf = engine.mixer.smartFader
sf.isEnabled = true
sf.tail = .echo                                   // or .reverb
sf.performTransition(from: engine.deckA, to: engine.deckB, over: 4)  // 4-bar auto blend
```

### Smart CFX (one-knob multi-effect presets)

```swift
engine.mixer.smartCFX.isEnabled = true
engine.mixer.smartCFX.preset = 1
engine.mixer.smartCFX.amount = 0.7   // single control drives a curated chain
```

### Record the mix (WAV / FLAC / AAC / ALAC — no MP3)

```swift
let rec = try MixRecorder(codec: .aac(bitrate: 256_000), url: outURL)
rec.start()
// … perform …
try rec.stop()
// Other codecs: .wavPCM(bitDepth: 24), .flac(compression: 5), .alac
```

---

## Standalone analysis (no engine needed)

```swift
import ParsoAudioCore
import ParsoAudioAnalysis

let pcm = try AudioFileReader(url: url).readAll()
let a = TrackAnalyzer(targetLUFS: -14).analyze(pcm)

print(a.tempo.bpm, a.tempo.confidence)
print(a.key.camelot, a.key.openKey)          // e.g. "8A", "1m"
print(a.loudness.integratedLUFS, a.loudness.gainToTargetDB)
print(a.sections.map(\.kind))                // best-effort phrase labels
let overview = a.waveform.overviewMinMax     // draw this
```

Run individual estimators if you only need one:

```swift
let bpm = TempoEstimator().analyze(pcm).bpm
let key = KeyEstimator().analyze(pcm)
```

## Decoding & encoding formats

```swift
// Decode (auto-detects container; routes FLAC→libFLAC, Ogg→stb_vorbis, Opus→libopusfile, else Apple)
let pcm = try AudioFileReader(url: url).readAll()

// Explicit container
let opus = try AudioFileReader(url: url, container: .opus).readAll()

// Encode
let w = try AudioFileWriter(url: outURL, format: pcm.format, codec: .flac(compression: 5))
try w.write(pcm); try w.finish()
```

Supported decode: FLAC, Ogg Vorbis, Opus, MP3, AAC, WAV, AIFF, CAF, and Apple-native ALAC.
Supported encode: WAV/PCM, FLAC, AAC, and Apple-native ALAC. Portable MP3 encode is planned through
the Linux Swift compatibility workstream using an audited permissive codec. Portable ALAC is
currently unavailable: no implementation code from Apple's public-source ALAC repository is used;
only its permitted headers remain uncompiled while an independently authored BSD-only replacement
is pending. Apple AAC/ALAC remains the native path.

## Loudness / auto-gain

```swift
let r = LoudnessAnalyzer(targetLUFS: -14).measure(pcm)
let normalizedGainDB = r.gainToTargetDB   // apply on load for consistent deck levels
```

---

## Swift 6 concurrency model

Control objects (`DJEngine`, `Deck`, `Mixer`, …) are `@MainActor`. Real-time audio runs entirely in
C/C++ (`CParsoEngine`), fed by lock-free atomics + an SPSC command ring; the engine publishes playhead
and meter events back through an SPSC event ring drained on the main actor. `PCMBuffer` is
`@unchecked Sendable` (manually managed storage) so it can be handed to the render thread as a
resident buffer. See `docs/architecture.md` and `docs/SPEC.md §3`.

## Testing philosophy

The suite is the spec. Synthetic tests assert exact behavior against generated signals (a click track
at a known BPM must detect that BPM; a killed EQ band must drop >60 dB; key-lock must scale time but
not pitch). Real-fixture tests assert **determinism + plausibility** on real tracks and become strict
regressions once you record verified values. See `Tests/` and `docs/SPEC.md §5, §15`.

## Roadmap

Phased implementation plan in `docs/SPEC.md §19`, including the Linux Swift compatibility
workstream in §19.1. If you're handing this to a coding agent, start it
at **`AGENTS.md`** — it defines the implement → enable-tests → commit → update-`current_status.md` loop
and the exact phase order. The public API is **0.x / unstable** until validated by a first real
integration, then tagged 1.0.0.

## License & attribution

MIT (`LICENSE`). Third-party permissive components: `NOTICE.md`. Test-fixture audio (Creative Commons,
fetched not redistributed): `ATTRIBUTION.md`.

The portable-codec policy is BSD-only permissive (BSD-2-Clause/BSD-3-Clause, or public domain) for
replacement implementation code. This project does not use any implementation code from Apple's
public-source ALAC repository; only permitted upstream header declarations remain uncompiled.
