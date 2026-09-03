# Audio Library Sourcing — Permissive-Only

Why the dependency set is what it is. Constraint: **MIT / BSD / Apache / APSL-2.0 / public-domain** (no
GPL/LGPL/AGPL), shippable in the App Store, Apple-native where that is the best free option, and
as much of the behavior as possible independently testable.

## The licensing reality
- **GPL/AGPL = a wall on the App Store.** Rubber Band's own license forbids App Store distribution
  without a paid commercial licence. This removes the best time-stretch and *every* strong analysis
  library (aubio, libKeyFinder, Essentia, QM-DSP, BTrack).
- **LGPL is excluded here too** to keep static linking + distribution unambiguous.
- **Permissive = link freely** (attribution only). This is the target tier for MIT/BSD/Apache/public
  domain dependencies. APSL-2.0 is also permitted, but it requires preserving notices and the license,
  marking modifications, and meeting its source-availability and executable-notice terms for external
  deployments; follow the checklist in `AGENTS.md`.

## What we use, by function

| Function | Pick | License | Notes |
|---|---|---|---|
| Engine / IO | AVAudioEngine + Core Audio | Apple | RT graph + output |
| Decode FLAC | libFLAC | BSD-3 | native FLAC, no libogg |
| Decode Ogg Vorbis | stb_vorbis | PD / MIT-0 | single-file decoder |
| Decode Opus | libogg + libopus + libopusfile | BSD-3 | `op_open_file` / `op_read_float` |
| Decode MP3/AAC/ALAC/WAV/AIFF | AVAudioFile / AudioToolbox | Apple | native |
| Encode WAV | AVAudioFile / ExtAudioFile | Apple | PCM |
| Encode FLAC | libFLAC | BSD-3 | lossless |
| Encode lossy | AAC (AudioToolbox) | Apple | **no MP3 encoder exists permissively** |
| MP3 encode | Glint | MIT | The only MP3 encoder on every platform — AudioToolbox has none; pinned and covered by round-trip tests |
| Portable M4A container (candidate) | minimp4 | CC0 | ISO BMFF demux/mux only; not an AAC/ALAC codec |
| Portable ALAC codec | None currently | — | Apple public-source implementation removed after legal review; independently authored BSD-only replacement pending |
| Sample-rate conversion (offline) | libsamplerate ≥ 0.2.2 | BSD-2 | never < 0.1.9 (GPL) |
| Time-stretch + pitch (key-lock) | Signalsmith Stretch | MIT | Accelerate FFT flag |
| Varispeed / scratch | custom Hermite / windowed-sinc | — | RT-safe, in `CParsoDSP` |
| FFT / vector | Accelerate (vDSP) | Apple | analysis + Signalsmith |
| EQ / filters | vDSP biquads + RBJ formulas | Apple / public | easy DSP |
| Effects (Beat FX / Color FX) | DIY (Freeverb, RBJ, standard) | PD / public | reverb constants in SPEC §6 |
| Loudness / auto-gain | libebur128 | MIT | EBU R128 |

## Apple-only scope

Linux support was retired in Phase 1b (2026-09-02); see `docs/UNIFICATION_PLAN.md` §4b.
The vendored C libraries stay because they carry their own weight on Apple: `Cflac`,
`Cvorbis` and `Copus` decode formats AVFoundation does not, `Cebur128` and `Csrc` provide
EBU R128 and high-quality SRC, and `CGlint` is the only MP3 *encoder* available, since
AudioToolbox cannot encode MP3.

## The gaps — no permissive library exists; built in-house
- **BPM / beatgrid** — aubio/BTrack/QM-DSP are GPL. → `TempoEstimator` (SPEC §5.1).
- **Key detection** — libKeyFinder GPL, Essentia AGPL. → `KeyEstimator` (SPEC §5.2).
- **Phrase / structure** — research/GPL/ML. → `StructureAnalyzer` (SPEC §5.3, best-effort).
- **Scratch physics, beat sync, Smart macros** — always DJ-domain code, no library.

## Two engines for playback rate
- **Varispeed** (scratch/pitch-bend/vinyl): resampling — pitch & tempo coupled.
- **Key-lock** (beatmatch / Key Shift): Signalsmith phase vocoder — independent.

## Quality ceiling to be aware of
The best-quality stretch (Rubber Band) is GPL/App-Store-forbidden. Signalsmith (MIT) + Apple's
`AVAudioUnitTimePitch` cover the DJ tempo range; exceeding them later is a commercial-licence
decision, cleanly isolated behind the `TimePitch` type.

## Platform contract

macOS GitHub Actions is the correctness host: it builds Swift 6 and runs every analysis, DSP,
headless-engine and vendored-codec test, as well as the native Apple framework paths — AAC/ALAC
and device-style audio output. iOS and watchOS simulator builds are compile and integration gates,
not a substitute for the deterministic test run.

Note what retiring Linux cost: there is no longer a second, non-Apple implementation of the decode
and analysis paths to disagree with the AVFoundation ones. The deterministic `HeadlessDJEngine`
render path and the synthetic-signal suites carry that burden alone now.
