# Changelog

All notable changes are documented here. Format: Keep a Changelog; scheme: SemVer.
The public API is **unstable (0.x)** until it has been validated by a first real integration
(see docs/SPEC.md §17).

## [Unreleased]
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

### Changed (cdj3000-parity, 0.x source-compat notes)
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
