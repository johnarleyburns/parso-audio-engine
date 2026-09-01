# parso-audio-engine — Engineering Specification

**Repository:** `parso-audio-engine` (public) · **License:** MIT · **Language:** Swift 6 (strict concurrency)
**Deliverable:** three SPM library products — `ParsoAudioCore`, `ParsoAudioAnalysis`, `ParsoDJEngine` —
that together provide **complete software functional equivalence of the Pioneer DDJ-FLX4** (as used
with rekordbox), with **no copyleft dependencies**.

> This is a takeover spec for an autonomous coding agent. Every dependency, license, module boundary,
> API shape, algorithm, constant, and acceptance test needed to implement the package is specified
> here or in the scaffolded source/tests. Do **not** substitute GPL/AGPL/LGPL dependencies.

---

## 0. Non-negotiable inputs (locked)

1. **Three SPM library products**, layered: `ParsoAudioCore` ← `ParsoAudioAnalysis` ← `ParsoDJEngine`. Standalone; no dependency on any external app.
2. **MIT** first-party; third-party code may use **MIT / BSD / Apache-2.0 / APSL-2.0 / public-domain** terms, plus Apple frameworks. **No GPL/LGPL/AGPL.** APSL-2.0 code must retain its notices and license, mark modifications, and satisfy its source-availability and executable-notice requirements when externally deployed; it does not relicense unrelated project code. See `AGENTS.md` for the operational compliance checklist.
3. **Swift 6 language mode** package-wide (`swiftLanguageModes: [.v6]`, tools 6.0).
4. **Decode scope:** FLAC (libFLAC/`Cflac`), **Ogg Vorbis** (stb_vorbis/`Cvorbis`), **Opus** (libopus+libopusfile/`Copus`), plus Apple-native MP3/AAC/ALAC/WAV/AIFF/CAF and portable Glint MP3/ADTS-AAC on Linux.
5. **Encode scope:** WAV/PCM, FLAC (libFLAC), AAC + ALAC (AudioToolbox on Apple), and portable
   Glint MP3/ADTS-AAC. M4A/ALAC remains an explicit Linux gap until permissive ISO-BMFF container
   and AppleALAC integration is complete; Linux must reject it rather than write WAV bytes under an
   `.m4a` extension.
6. **Real-time DSP core is C/C++**; Swift is the API/orchestration skin. Apple-native (Accelerate/AVFoundation/AudioToolbox) where it is the best free option.
7. **Targets:** iOS 15+, iPadOS 15+, macCatalyst 15+, macOS 13+.
8. **Goal:** replicate the *audio + DJ* functionality of a DDJ-FLX4 in software. Physical-only aspects (jog motor, jacks, soundcard, USB, Bluetooth-in) are **N/A** (§15).

---

## 1. Layering & repo map

```
ParsoDJEngine (Swift, @MainActor)  decks · mixer · crossfader · cues · loops · 8 pad modes ·
   │                               Beat FX · Color FX · sampler · Smart Fader/CFX · mic · monitoring · sync
   │  commands (SPSC ring) + ControlBlock (atomics)     ▲ events (positions, meters)
   ▼                                                     │
CParsoEngine (C++/C-API)  real-time render graph, runs ON the audio thread
   ▼ uses
ParsoAudioCore (Swift)  file IO · encode · offline SRC · loudness · buffers · DSP wrappers
   ▼ uses
CParsoDSP (C++/C-API)  RT-safe kernels: EQ/filter · delay · reverb · flanger · phaser · bitcrush ·
                       limiter · interpolator · time-pitch (Signalsmith) · lock-free rings

ParsoAudioAnalysis (Swift + vDSP)  tempo/beatgrid · key · structure · waveform (offline)
```

Source targets: `Sources/{CParsoDSP,CParsoEngine,Cflac,Cebur128,Csrc,Cvorbis,Copus,ParsoAudioCore,ParsoAudioAnalysis,ParsoDJEngine}`.
The public Swift API is scaffolded in `Sources/Parso*/*.swift` (stubs calling `unimplemented()`); the
C-API contracts are in `Sources/CParso*/include/*.h`. `PCMBuffer` is already implemented.

**Reuse contract:** `ParsoAudioCore`/`CParsoDSP` and `ParsoAudioAnalysis` must contain **no** DJ
concept. Only `ParsoDJEngine`/`CParsoEngine` know about decks/crossfader/cues.

---

## 2. Dependency register

| Target | Dependency | License | Role |
|---|---|---|---|
| `Cflac` | libFLAC | BSD-3 | FLAC decode + encode (native FLAC; no Ogg/libogg) |
| `Cvorbis` | stb_vorbis | Public Domain / MIT-0 | Ogg Vorbis decode |
| `Copus` | libogg + libopus + libopusfile | BSD-3 | Opus decode |
| `Cebur128` | libebur128 | MIT | EBU R128 / BS.1770 loudness |
| `Csrc` | libsamplerate ≥ 0.2.2 | BSD-2 | Offline sample-rate conversion (**never < 0.1.9 — GPL**) |
| `CParsoDSP` | Signalsmith Stretch | MIT | Time-stretch + pitch-shift (key-lock) |
| — | Apple AVFoundation / AudioToolbox / Accelerate | Apple SDK | Engine graph, MP3/AAC/ALAC/WAV/AIFF decode, AAC/ALAC encode, FFT/vector |
| `CGlint` | Glint | MIT | Portable MP3/ADTS-AAC decode and MP3/AAC encode; pinned/vendored, macOS parity/fuzz gates remain |
| `Cminimp4` (candidate) | minimp4 | CC0 | Portable ISO BMFF/M4A container parsing; codec-independent |
| `Calac` (candidate) | AppleALAC | Apache-2.0 | Portable ALAC codec; M4A/CAF integration pending |
| — | Freeverb constants (§13.4) | Public Domain | Reverb tuning |

**Rejected (do not use):** Rubber Band, SoundTouch, sbsms, soxr, aubio, libKeyFinder, Essentia,
QM-DSP, BTrack, FFTW, JUCE. If one seems necessary, **stop and flag**.

---

## 3. Real-time safety (HARD CONSTRAINTS)

Inside `pe_render`/`pe_step` and every `CParsoDSP` kernel:
no heap allocation, no locks/mutexes/syscalls/IO/logging, no Swift/ObjC runtime, no exceptions across
the C boundary, FTZ/DAZ enabled, all continuous params one-pole smoothed (5–20 ms). Parameter flow is
lock-free: Swift → RT via `ControlBlock` atomics + an SPSC command ring; RT → Swift via an SPSC event
ring. Everything else (analysis, IO, loudness, decode, encode, waveform) is off the RT thread.

**Swift 6 concurrency:** control objects are `@MainActor`; the C-handle wrappers are `@unchecked
Sendable` with the invariant that handles are created/destroyed on the control actor and only POD is
exchanged with the RT thread. `PCMBuffer` is `@unchecked Sendable` (manual storage).

---

## 4. Two playback-rate modes

- **Varispeed** (scratch, pitch-bend, vinyl jog): fractional-rate resampling (§13.6). Pitch & tempo coupled.
- **Key-lock** (beatmatch without pitch change; Key Shift without tempo change): Signalsmith (§13.7).
Both behind `TimePitch` (`pd_timepitch`); a deck switches per gesture.

---

## 5. Analysis algorithm specs (implement exactly)

### 5.1 Tempo / beatgrid (`TempoEstimator`)
Mono → 22050 Hz. STFT Hann size 2048 hop 512. Onset envelope = spectral flux
`Σ max(0,|X_t[k]|−|X_{t−1}[k]|)`, minus 0.15 s moving average, half-wave rectified, normalized.
Tempo = autocorrelation of the envelope over lags for **40–220 BPM**, weighted by a log-Gaussian prior
centered **120 BPM** (σ≈0.5 in log2); test half/double/⅔/³⁄₂ multiples, keep best under the prior.
Beat phase: cross-correlate a pulse train at the period against the envelope for the offset.
Downbeats: choose the bar phase (of 4) with the most low-band (<200 Hz) accent (best-effort).
`isConstantTempo = true` for v1. `confidence` = autocorr peak sharpness × phase alignment.

### 5.2 Key (`KeyEstimator`)
Mono → 22050 Hz. STFT Hann 4096 hop 2048. 12-bin chroma: `pc = round(12·log2(f/440)+69) mod 12`,
100–5000 Hz, accumulate, normalize. Correlate (Pearson) against **Krumhansl–Kessler** profiles
(constants in `KeyProfiles`, already in source) rotated over 12 tonics; argmax → `(tonic, mode)`.
Map to Camelot + Open Key via a fixed table. `confidence` = (best − secondBest) scaled.

### 5.3 Structure (`StructureAnalyzer`, best-effort v1)
Beat-synchronous feature per beat (band energies + chroma) → cosine self-similarity matrix →
checkerboard-kernel novelty (radius ≈16 beats) → peak-pick boundaries → snap to 8/16/32-bar phrases →
heuristic labels by relative energy/centroid (`.unknown` allowed).

### 5.4 Waveform (`WaveformGenerator`)
Bucketize: per overview bucket store min/max; per detail bucket RMS; per bucket low/mid/high band
energy for color. Accelerate with vDSP.

---

## 6. DSP specs & constants
- **Biquads:** RBJ Audio EQ Cookbook (LPF/HPF/BPF/peaking/shelf/notch).
- **3-band isolator EQ:** low/high shelf + mid peak (or LR split), gain −∞(kill)…+6 dB, crossovers ≈200 Hz / 2 kHz.
- **Delay/Echo:** circular line, fractional read, feedback 0…0.95, beat-synced. `EchoOut` = feedback ramp + input mute on release.
- **Reverb (Freeverb):** 8 combs `1116,1188,1277,1356,1422,1491,1557,1617` → 4 allpasses `556,441,341,225` (samples @44.1 k, scale to SR); stereo spread +23 samples; `room` scales comb feedback 0.7…0.98; `damp` LPFs feedback.
- **Flanger:** modulated 0.5–5 ms delay, LFO 0.1–2 Hz, feedback, mix. **Phaser:** 4–8 cascaded allpass, LFO-swept, feedback, mix.
- **Interpolator (varispeed/scratch):** 4-point Hermite (fast) + optional 32×16 windowed-sinc polyphase (HQ), allocation-free.
- **Time-pitch (key-lock):** Signalsmith wrapper; `tempoRatio`→block-size ratio, `pitchSemitones`→transpose; `reset()` on seek.
- **Limiter:** look-ahead brickwall, ceiling ≈ −0.3 dBTP, 1–5 ms LA, 50–100 ms release.
- **Crossfader curves:** smooth (equal-power cos/sin), linear, sharp; `.thru` removes a channel.

---

## 7. Control plumbing
`pe_control` (atomics) — latest-wins continuous params. `pe_command` (SPSC ring) — discrete actions.
`pe_event` (SPSC ring) — playhead frames, peaks, state, end-of-track, buffer-released. Resident track
buffers are Swift-owned `PCMBuffer`s handed to the RT via `pe_deck_set_buffer`; kept alive until a
`PE_EVT_BUFFER_RELEASED` event. See `Sources/CParsoEngine/include/parso_engine.h`.

---

## 15. Acceptance criteria — DDJ-FLX4 → package mapping

Equivalence = all **[CORE]/[RB]** items in `docs/FLX4-feature-inventory.md` satisfied by these APIs.
Physical-only **[HW]** items are **N/A**. Each row has a test suite in `Tests/` (green as implemented).

| FLX4 area | Delivered by | Test suite |
|---|---|---|
| 2 decks, transport, cue, stutter | `Deck` | `Hot cues`, headless transport |
| Tempo ±6/10/16/WIDE, key-lock, pitch bend | `Deck`, `TimePitch` | `Time / pitch` |
| Jog scratch / vinyl / search | `Deck.jog*`, interpolator | `Time / pitch` (varispeed) |
| Loops (manual/auto/saved/active/roll/halve/double/move) | `Deck` loop API | `Loops` |
| 8 hot cues + cue/loop call | `Deck` | `Hot cues` |
| 8 pad modes | `PadMode` | `Pad modes` |
| Sampler (16 slots) | `Sampler` | `Pad modes` |
| 2-ch mixer, 3-band full-kill EQ, faders, VU | `Channel`, `Isolator3Band` | `Isolator EQ` |
| Color FX (filter default + assignable) | `Channel.colorFX` | (FX render) |
| Beat FX (selectable, synced, assign, release) | `BeatFXUnit` | (Beat-sync FX) |
| Crossfader + curve + assign + fader start | `Mixer`, `Channel.faderStart` | `Crossfader` |
| Smart Fader / Smart CFX | `SmartFader`, `SmartCFX` | `Smart Fader` |
| Master + limiter + master cue | `MasterOut` | (limiter ceiling) |
| Monitoring (PFL, cue/master, level) | `Monitoring` | (monitor mix) |
| Mic summed to master/record | `MicInput` | (mic sum) |
| Sync / master / quantize / slip | `Deck.sync/setAsMaster/quantize/slip` | `Sync`, `Slip mode` |
| Analysis (BPM/key/waveform/structure/loudness) | `ParsoAudioAnalysis`, `LoudnessAnalyzer` | `Tempo`, `Key`, `RealFixture *` |
| Recording (WAV/FLAC/AAC/ALAC + planned MP3) | `MixRecorder` | `Codec roundtrip` + Linux compatibility gates |
| Decode FLAC/OggVorbis/Opus/MP3/AAC/ALAC/WAV/AIFF | `AudioFileReader` | `RealFixture decode` |
| Library / streaming | **Out of scope** (app concern) | — |

---

## 16–17. Build / versioning
`swift build` + `swift test` on macOS; iOS-sim build via `xcodebuild`. CI: build+test, SPDX copyleft
guard, iOS build; a manual job runs `RealFixture` with downloaded fixtures. SemVer; **0.x unstable**
until validated by a first real integration; tag **1.0.0** thereafter.

## 18. Non-goals
Streaming-service integration, library/browser UI, DVS timecode, external-MIDI/controller mapping
(incl. mapping a real FLX4 — future), video.

## 19. Phased plan
1. Skeleton + CI green (**done** in scaffold). 2. Vendor Cflac/Cvorbis/Copus/Cebur128/Csrc; decode+encode+loudness+SRC tests pass. 3. `CParsoDSP` kernels + Signalsmith; Core DSP tests pass. 4. `ParsoAudioCore` IO/encode/SRC/loudness green. 5. `ParsoAudioAnalysis` tempo→key→structure→waveform; synthetic + real-fixture green. 6. `CParsoEngine` RT graph + plumbing + headless. 7. `ParsoDJEngine` decks/mixer/pads/FX/sampler/mic/monitoring/sync, then Smart Fader/CFX. 8. `MixRecorder`. 9. Acceptance pass over §15.

**Definition of done:** all three products build for iOS + macOS; `swift test` green (all suites
enabled); every §15 gate has a passing test; NOTICE/SPDX clean; public C headers C-clean;
`pe_render` asserts zero allocations.

### 19.1 Linux Swift compatibility workstream

This workstream runs before the final acceptance sign-off and is intentionally additive to the
Apple-native gates:

1. Audit and pin Glint; verify its MIT license, source provenance, generated assets, and decoder/
   encoder behavior against CoreAudio.
2. Add a C-clean `CGlint` bridge and use it for portable MP3 decode and opt-in MP3 encode on Linux
   and Apple platforms. Keep AudioToolbox as the Apple AAC/ALAC implementation.
3. Add `Cminimp4` only for the supported ISO BMFF/M4A profiles, with malformed-file, duration,
   seek, priming, and metadata tests.
4. Evaluate Apache-2.0 AppleALAC for Linux ALAC and cross-check lossless output with AudioToolbox.
5. Make Linux the independent correctness host for Swift, analysis, DSP, headless render, and all
   portable codecs. Keep macOS/iOS CI as the native Apple framework and hardware-family gate.
