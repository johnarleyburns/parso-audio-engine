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

## Status: implemented

All three layers are implemented and the full `swift test` suite is green, including the
real-audio fixture suites (FLAC / Ogg Vorbis / Opus / MP3 decode + BPM/key/structure/loudness
analysis) once `./scripts/download-fixtures.sh` has run. `docs/SPEC.md` remains the design
source of truth and the test suite remains the executable specification.

- **DSP / RT engine:** `CParsoDSP` (isolator EQ, sweep filter, time/pitch via Signalsmith
  Stretch, delay, Freeverb reverb, look-ahead limiter, lock-free SPSC ring) and `CParsoEngine`
  (allocation-free two-deck render graph) are real. `pe_render` (device) and `pe_step` (tests)
  share one DSP implementation.
- **Codecs:** the native containers (WAV, AIFF, CAF, MP3, AAC, ALAC-in-M4A) go through
  AVFoundation / AudioToolbox. FLAC, Ogg Vorbis and Opus use vendored permissive C
  (`Cflac`, `Cvorbis`, `Copus`); loudness and SRC use `Cebur128` / `Csrc`; MP3 *encode*
  uses `CGlint`, because AudioToolbox has no MP3 encoder.
- **Analysis:** tempo / beatgrid / key / structure / waveform run through an
  Accelerate-backed pipeline ported from `parso-tonearm` (audio-engine unification, Phase 5).
  The strict `expected` key/BPM values in `Tests/Fixtures/fixtures.json` are still being
  re-verified against the ported estimators; most remain `null` pending that pass.

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

The acceptance tool can produce a WAV plus JSON analysis sidecar, then render a
reviewable MP4 with waveform, beat/downbeat markers, section labels, and a synchronized playhead.
See [`docs/human-visible-acceptance.md`](docs/human-visible-acceptance.md). It uses system `ffmpeg`
only as developer tooling; ffmpeg is not a product dependency.

```bash
swift run --package-path Tools/AcceptanceArtifacts ParsoAcceptanceArtifacts \
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
Supported encode: WAV/PCM, FLAC, MP3, AAC and ALAC. AAC and ALAC use AVFoundation; MP3 uses the
vendored Glint encoder, since AudioToolbox cannot encode MP3. No implementation code from Apple's
public-source ALAC repository is used.

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

## On-device neural: CLAP search, and why there's no vocal stem separation

Phase 7 (`current_status.md` "Phase 7") is adding on-device CoreML-backed features
behind a new, deliberately **watchOS-excluded** `ParsoAudioNeural` target
(`#if !os(watchOS)`, since CoreML — unlike AudioToolbox — is actually present on
watchOS 10, so `canImport` alone wouldn't exclude it; watchOS keeps building via
plain SPM with zero neural dependency). Like every other PAE target, it ships
**protocol surface and license-clean plumbing only** — no model weights, ever; a
library has no On-Demand Resources mechanism, so the app supplies the actual
`.mlpackage`.

Two capabilities are in scope, and they are not equally clearable:

- **Semantic/mood search (CLAP)** — moving into PAE. LAION CLAP
  (`music_audioset_epoch_15_esc_90.14.pt`, HTSAT-base) is **Apache-2.0**, stated
  explicitly by the upstream project and independently verified here.
- **Vocal stem separation — deliberately NOT included.** This needs its own
  explanation, because it's a real gap, not an oversight.

### What a vocals-capable stem model needs, and why nothing available today qualifies

Splitting a mix into vocals/drums/bass/other requires a *supervised* model trained on
paired **(mixed track, isolated stems)** examples — you cannot learn vocal separation
from mixed recordings alone. Shipping such a model inside an MIT-licensed library
redistributed to third parties requires the **training data's license**, not just the
code's, to permit commercial use — a permissive code license does not imply a
permissive weights license, and that distinction is exactly what trips up every
option surveyed:

| Model | Code license | Weights / training-data reality |
|---|---|---|
| Demucs / htdemucs (Meta) | MIT | **Not commercially usable.** The author stated directly, on record, that the weights are "not covered by the MIT license, and are provided only for scientific purposes" ([facebookresearch/demucs#327](https://github.com/facebookresearch/demucs/issues/327)). Trained on MUSDB18/MUSDB18-HQ, itself academic-use-only, several tracks CC BY-NC-SA. |
| Spleeter (Deezer) | MIT | Weights license **unresolved on record** — a direct GitHub issue asking this exact question has no maintainer answer. Trained on Deezer's undocumented internal dataset. |
| Open-Unmix | MIT-ish | One published checkpoint is explicitly CC BY-NC-SA; the default is trained on the same tainted MUSDB18. |
| MDX-Challenge / community models (MVSEP, HuggingFace mirrors) | varies | Increasingly trained on MoisesDB, also CC BY-NC-SA, non-commercial. |

**Every real-recording, vocal-capable separation model in current circulation traces
back to non-commercial training data.** This is not a licensing technicality to route
around — MUSDB18, MUSDB18-HQ, and MoisesDB are the field's dominant training sets
precisely because assembling *real, vocal-inclusive, isolated-stem* multitrack audio
at scale is hard, and nobody has done it yet under commercial-safe terms.

### Why Slakh2100 is the current fallback, and its real limitation

[Slakh2100](https://zenodo.org/records/4599666) is the one dataset found in this
survey with unambiguous commercial terms: **CC-BY-4.0**, 2,100 tracks / 145 hours,
individual instrument stems. The catch: it's **synthetic** — sample-library
instrument renders from the Lakh MIDI Dataset, not real recordings — and because it's
MIDI-derived, **it has no vocal stems** (there is no sung-vocal MIDI to render). PAE's
Phase 7c ships an **instrumental-only** (drums/bass/other) separator trained on
Slakh2100. This is a genuine, licensing-clean capability, and a genuine limitation:
no vocal isolation, and the model never saw a real mixed recording during training,
only synthetic renders.

### A proposed project: a real, vocals-included, openly-licensed stems dataset

For vocal separation to become possible without waiting on Meta or another rightsholder
to grant a commercial license, someone needs to build the dataset that doesn't
currently exist: real recordings, paired with isolated vocal + instrumental stems,
under CC0 / CC-BY / CC-BY-SA terms that explicitly permit commercial redistribution of
derivative model weights (CC-BY-**NC**-SA does not qualify — the "NC" is exactly the
trap every existing option falls into).

**What it needs, concretely:**

1. **Scale.** htdemucs itself trained on ~950 professionally mixed songs (MUSDB18-HQ's
   150 + an internal Meta 800-song set). A from-scratch commercial-clean equivalent
   should target the same order of magnitude — **realistically 400–600 tracks as a
   minimum viable training set** (with aggressive data augmentation: pitch shift,
   tempo stretch, in-batch remixing of the separately-available stems, all standard
   in this literature and already used by Demucs's own training pipeline), **800–1,000+
   to approach htdemucs-class quality**. Fewer than ~300 clean tracks is unlikely to
   produce a usable vocal separator regardless of augmentation.
2. **Sourcing.** No existing archive (Wikimedia Commons hosts finished mixes, not
   paired stems, and is a non-starter for this) has this at scale today. Realistic
   sources, in likely order of yield:
   - **Commission originals directly under CC0.** Pay session vocalists/musicians to
     record short (60–120s) song sections with vocals + a few instrument stems,
     explicit CC0 release. Most control over quality and licensing; highest direct cost
     per track (session musician day rates), lowest legal risk.
     - Given typical indie session rates, budget roughly **$150–$400 per finished,
       fully-stemmed, CC0-cleared track** (musician time, a mix engineer's pass to
       confirm stem isolation is clean, and rights paperwork) — so 400 tracks is
       roughly **$60,000–$160,000**, 800 tracks roughly **$120,000–$320,000**. This is
       the dominant cost of the whole project, dwarfing the compute cost below.
   - **Remix-competition communities** (ccMixter and similar) — real vocal +
     instrumental stems already exist there with per-track CC licensing, some
     commercial-permitting. Free, but uncurated, inconsistent per-track licensing that
     needs individual verification, and unlikely alone to reach the scale above —
     treat as a supplement, not the primary source.
   - **Public-domain vocal recordings** (pre-1929 US recordings, some archival
     folk/field recordings) paired with newly-recorded CC0 instrumental beds — a hybrid
     approach; scarcer and harder to isolate cleanly (period recordings are rarely
     multitrack), but worth a scoping pass.
3. **Curation/QA procedure.** Every track needs: (a) a license check confirming CC0/
   CC-BY/CC-BY-SA with no NC clause, recorded in a per-track manifest (source, license,
   URL/contact, date); (b) a stem-isolation quality check (no bleed between stems,
   levels normalized, sample-rate/bit-depth consistent — 48 kHz/24-bit is a reasonable
   house standard matching PAE's existing analysis pipeline); (c) genre/tempo/key
   tagging for balanced train/val/test splits (a dataset that's 90% one genre trains a
   model that only works on that genre). Budget **~15–30 minutes of curator time per
   track** for this pass — for 400–800 tracks, that's roughly **100–400 curator-hours**
   (2.5–10 weeks of one person working full-time), separate from the recording cost
   above.
4. **Training procedure.** Architecture: htdemucs's hybrid transformer design (or a
   lighter HDemucs v3 convolutional-only variant if the smaller dataset doesn't
   support the transformer stage's appetite for data) trained from scratch — do not
   fine-tune from htdemucs's actual checkpoint, since its weights carry the same
   non-commercial taint being avoided. Standard supervised source-separation training
   loop: L1/SDR loss per stem, augmentation as in (1), held-out validation split (an
   80/10/10 track-level split, never track-overlapping across splits) for early
   stopping.
5. **Testing before any release.** Two gates, not one: (a) **quantitative** — SDR
   (signal-to-distortion ratio) per stem on the held-out test split, reported against
   the Slakh2100 baseline and, where legally comparable, published htdemucs SDR numbers
   as context (not a claim of parity); (b) **human listening QA** — a blind A/B panel
   (the author + at least 2–3 other listeners) on ≥10 held-out real tracks spanning the
   dataset's genre spread, checking for audible bleed, artifacts, and whether the
   result is usable for actual DJ/remix work, not just a good SDR number. Do not ship
   without both gates passing.
6. **Hardware and compute cost.** This part is the cheap part by comparison. htdemucs's
   own training used 8× Nvidia V100 32GB GPUs
   ([arXiv:2211.08553](https://arxiv.org/abs/2211.08553)); a comparable run today on
   rented cloud A100s (~$1–3/GPU-hr depending on provider) is realistically a
   multi-day 8-GPU job, putting total compute in the **rough low-thousands-of-dollars
   range** (order-of-magnitude estimate — Meta never published an exact figure). **A
   laptop is not a realistic training venue** — Apple Silicon's MPS backend is roughly
   an order of magnitude or more slower than a single A100 on transformer-heavy
   architectures, turning a multi-day cluster job into weeks-to-months.

**Net honest assessment:** the compute and engineering are the tractable 10% of this
project; assembling a large-enough, real, vocals-included, genuinely commercial-clean
dataset is the hard 90%, and it costs real money (rough total project estimate,
recording-dominated: **$150,000–$400,000+ and 3–6 months**, not a side project). This
is why PAE ships instrumental-only separation now rather than waiting — and why the
vocals gap is tracked as an open, fundable project rather than a near-term deliverable.
See the tracking issue on this repo for the current status of this proposal.

## Roadmap

Phased implementation plan in `docs/SPEC.md §19`. The current workstream is the three-repo
audio unification in `docs/UNIFICATION_PLAN.md`, tracked in `current_status.md`.
If you're handing this to a coding agent, start it
at **`AGENTS.md`** — it defines the implement → enable-tests → commit → update-`current_status.md` loop
and the exact phase order. The public API is **0.x / unstable** until validated by a first real
integration, then tagged 1.0.0.

## License & attribution

MIT (`LICENSE`). Third-party permissive components: `NOTICE.md`. Test-fixture audio (Creative Commons,
fetched not redistributed): `ATTRIBUTION.md`.

The vendored-codec policy is BSD-only permissive (BSD-2-Clause/BSD-3-Clause, or public domain).
This project does not use any implementation code from Apple's public-source ALAC repository.
