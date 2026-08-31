# Architecture

```
ParsoDJEngine (Swift)   decks · mixer · crossfader · cues · loops · 8 pad modes ·
   │                    Beat FX · Color FX · sampler · Smart Fader/CFX · mic · monitoring · sync
   │ commands (SPSC ring) + ControlBlock (atomics)      ▲ events (positions, meters)
   ▼                                                     │
CParsoEngine (C++/C-API)   real-time render graph — runs ON the audio thread
   │ 2 decks → channel proc → crossfader → master chain → limiter → output
   ▼ uses
ParsoAudioCore (Swift)   file IO (libFLAC + Apple) · AAC/ALAC/WAV encode ·
   │                     offline SRC (libsamplerate) · loudness (libebur128) · buffers · DSP wrappers
   ▼ uses
CParsoDSP (C++/C-API)    RT-safe kernels: biquad/EQ · delay · reverb · flanger · phaser ·
                         bitcrush · limiter · interpolator · time-pitch (Signalsmith) · lock-free rings

ParsoAudioAnalysis (Swift + vDSP)   tempo/beatgrid · key · structure · waveform (offline)
```

## Threading & Swift 6 concurrency
- **Audio (render) thread:** only C/C++ (`CParsoEngine`/`CParsoDSP`). No allocation, locks, syscalls,
  or Swift runtime. See docs/SPEC.md §7.
- **Control:** `DJEngine` and its sub-objects are `@MainActor`. Parameter writes go to an atomic
  `ControlBlock`; discrete actions go through a single-producer/single-consumer command ring.
- **Bridging:** the C handle wrappers are `@unchecked Sendable` with documented invariants (handles
  are created/destroyed on the control actor; only POD is exchanged with the RT thread).
- **Events:** the RT thread pushes POD events (playhead frames, peak meters) to an SPSC ring; a
  display-link drains them on `@MainActor` and republishes via `@Observable`.

## Two playback-rate modes
- **Varispeed** (scratch, pitch-bend, vinyl jog): fractional-rate resampling — pitch & tempo coupled.
- **Key-lock** (beatmatch without pitch change; Key Shift without tempo change): Signalsmith phase
  vocoder. Both sit behind one `TimePitch` type; a deck switches per gesture.
