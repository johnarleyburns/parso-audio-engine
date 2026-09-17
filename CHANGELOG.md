# Changelog

All notable changes are documented here. Format: Keep a Changelog; scheme: SemVer.
The public API reached **1.0.0** after validation by the first real integrations
(see docs/SPEC.md §17). The `1.1.0` feature line is tagged; the current release is `1.2.0`.

## [Unreleased]

## [1.2.0] - 2026-09-16
### Added
- Versioned portable analysis persistence, staged/cancellable analysis, and phrase-local descriptors.
- Deterministic phrase-aware TransitionPlanner with explainable clash metrics and score breakdowns.
- Sample-clock SmartFader recipes, explicit transition techniques, offline previews, and host-owned audio integration.
- Lightweight Transition Lab profile, Codable preparation snapshots, semantic similarity helpers, and Platterhead contract APIs.

### Changed
- Existing 1.1.1 SmartFader entry points now delegate to the frame-clock scheduler; no model weights ship.

## [1.1.1] - 2026-09-16
### Added
- Complete portable turntablism control coverage for baby, scribble, drag, forward/backward,
  chirp, flare, orbit, transform, crab, tear, twiddle, boomerang, platter pitch bend,
  motor-off, hydroplane, tone-play, beat-juggling, and phasing/flanging scenarios.
- Reusable `ScratchBank` patterns with editing, recording, playback, technique recognition,
  mobile platter-touch lifecycle, and four-point Hermite scratch interpolation.
- Real-music turntablism acceptance artifacts using hip-hop/disco material, with an optional
  Linux Pocket TTS guide generator for human review.

### Changed
- Refined scratch motion, fader-cut ramps, explicit one-/two-click flare patterns, Orbit
  topology, and captured touch modes to keep the scratch sound continuous and musical.
- Added per-technique API recipes and mobile gesture guidance in `docs/turntablism-api.md`,
  linked from the README.

### Accepted
- Maintainer human listening review passed for all source and optional TTS-guided Linux
  turntablism scenarios on 2026-09-16, including scratch combinations, beat juggling, and
  phasing/flanging. Windows and Android physical-device tests remain out of scope because the
  required hardware is unavailable; DVS/timecode is a documented non-goal.

### Fixed
- Resolve Swift analysis pitches between FFT bins and preserve full-register chord evidence,
  correcting bass-bin and chord-inversion key errors. Bound the tempo preference and refine
  autocorrelation periods to avoid prior-driven tempo-family errors and coarse-frame BPM bias;
  use amplitude-domain rhythmic evidence so downbeat accents do not force half-time estimates.
- Split the native C++ API and engine translation units so the public API builds cleanly with
  subobject-linkage warnings treated as errors.
- Align CMake, Python, JavaScript, Android, CI, documentation, and fixture-download metadata on
  the `1.1.1` release candidate.
- Record the maintainer-confirmed Swift two-app and Linux desktop acceptance scope, with Windows and
  Android hardware gates explicitly unavailable rather than implied to be validated.

## [1.1.0] - 2026-09-12
### Added
- **CDJ-3000 / DJM-A9 parity** (`docs/CDJ3000-parity-research.md`, branch
  `cdj3000-parity`): the DJ engine steps up from the DDJ-FLX4 target to the
  pro-booth tier.
  - **4 decks / 4 channels.** `CParsoEngine` is `PE_MAX_DECKS`-wide;
    `DJEngine`/`HeadlessDJEngine` take `deckCount: Int = 4` and expose
    `decks: [Deck]` / `Mixer.channels: [Channel]` (+ `deckA…deckD` /
    `channelA…channelD` aliases). 2-deck output is byte-preserved.
  - **`MasterClock`** value type + `setExternalClock` / `clearExternalClock`
    (app-bridged, e.g. Ableton Link); `Deck.quantizeJumps` fires cue / hot-cue /
    beat-jump actions on the next (master-relative) grid line.
  - **Key Sync** (`Deck.keySync(to:)`, `soundingKey`, `DJEngine.masterKey`),
    **reverse + Slip Reverse**, **Vinyl Speed Adjust** (`brakeTime` / `spinUpTime`).
  - Mixer pro tier: per-channel `FaderCurve`, master isolator, booth output
    (`pe_render_booth` / `renderBooth`), RT insert seam (`RealtimeInsert` +
    `Mixer.setInsert(_:at:)`), mic strip (2-band EQ / talkover / FX send),
    Split Cue, peak-hold metering.
  - Beat FX: 20 kinds (Ping Pong / Mobius / Triplet Filter+Roll / Enigma /
    Shimmer added), each with real per-sample DSP (SVF, allpass phaser, gate,
    beat-latched roll, Schroeder reverb, …); X-Pad; FX-send band limit.
    Sound Color FX parameter knob + Center Lock.
  - Player extras: hot-cue banks, fade-in cue points, Auto Cue level, arbitrary
    `loopResize`, `emergencyHold`.
  - Reverb: `pd_fdnverb` (8-line feedback delay network) and `pd_conv`
    (partitioned-FFT convolution running real IRs) on the master reverb send —
    `MasterOut.reverbMode` / `DJEngine.loadReverbImpulseResponse`.
  - `SmartCFX` and the full timed `SmartFader` transition implemented (were
    data-only shells); `Sampler` one-shot / loop / gate modes + per-slot and
    master gain wired to the engine.
  - CC0/CC-BY built-in sample & IR sourcing: `SampleLibrary/manifest.json`,
    `scripts/download-samples.sh`, `SAMPLES-NOTICE.md` (fetched, not committed).
- Initial repository scaffold: three SPM library products (ParsoAudioCore, ParsoAudioAnalysis, ParsoDJEngine).

### Changed (cdj3000-parity, 1.0.0 source-compat notes)
- `DJEngine.init` / `HeadlessDJEngine.init` gain `deckCount: Int = 4` (defaulted).
  `deckA`/`deckB`/`channelA`/`channelB` are now computed aliases over
  `decks`/`channels` — same instances, source-compatible.
- `EngineStats` gains `deck{EffectiveBPM,BeatPhase,Synced}All: [T]` fields; a
  caller using its memberwise initializer directly must add them (the struct is
  normally engine-produced).
- `BeatFXUnit.Kind` and `SmartFader.Tail` gain cases (additive); the reverb send
  is fully dry / bit-transparent by default.
- Full engineering specification (docs/SPEC.md), FLX4 feature target (docs/FLX4-feature-inventory.md), sourcing map (docs/audio-library-sourcing.md).
- Extensive test suite (synthetic + real Creative Commons fixtures) as executable specification.
- Decode support scope: FLAC (libFLAC), Ogg Vorbis (Xiph libvorbisfile), Opus (libopus/libopusfile), plus Apple-native MP3/AAC/ALAC/WAV/AIFF/CAF.
- Fixtures pipeline for Creative Commons House / disco / hip-hop tracks (download only; library decodes natively).
