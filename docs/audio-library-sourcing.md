# Audio Library Sourcing — Permissive-Only

Why the dependency set is what it is. Constraint: **MIT / BSD / Apache / APSL-2.0 / public-domain** (no
GPL/LGPL/AGPL), shippable in the App Store, Apple-native where that is the best free option, and
as much of the behavior as possible independently testable on Linux.

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
| Portable MP3 decode/encode | Glint | MIT | Linux + Apple fallback; pinned and covered by round-trip tests |
| Portable M4A container (candidate) | minimp4 | CC0 | ISO BMFF demux/mux only; not an AAC/ALAC codec |
| Portable ALAC codec | None currently | — | Apple public-source implementation removed after legal review; independently authored BSD-only replacement pending |
| Sample-rate conversion (offline) | libsamplerate ≥ 0.2.2 | BSD-2 | never < 0.1.9 (GPL) |
| Time-stretch + pitch (key-lock) | Signalsmith Stretch | MIT | Accelerate FFT flag |
| Varispeed / scratch | custom Hermite / windowed-sinc | — | RT-safe, in `CParsoDSP` |
| FFT / vector | Accelerate (vDSP) | Apple | analysis + Signalsmith |
| EQ / filters | vDSP biquads + RBJ formulas | Apple / public | easy DSP |
| Effects (Beat FX / Color FX) | DIY (Freeverb, RBJ, standard) | PD / public | reverb constants in SPEC §6 |
| Loudness / auto-gain | libebur128 | MIT | EBU R128 |

## Linux Swift compatibility workstream

This is a deliberate compatibility layer, not a replacement for the Apple implementation. The
Apple path remains authoritative for AVFoundation, AudioToolbox, native device I/O, and final
AAC/ALAC behavior. Linux should exercise the same public `AudioFileReader`, `AudioFileWriter`,
analysis, and headless-engine contracts wherever a permissive implementation is available.

Recommended order:

1. **Glint investigation and legal/security audit.** Pin an upstream revision, verify the complete
   source tree and generated tables, confirm the MIT license, fuzz/fixture-test the MP3 and AAC-LC
   decoders, and measure output against CoreAudio on macOS. The pinned source is now vendored in
   `Sources/CGlint` with its upstream MIT license; fuzzing and macOS parity remain follow-up gates.
2. **Glint bridge and portable codec IO.** Route Linux MP3 decode through Glint and use the same
   encoder on Linux and Apple. ADTS AAC decode/encode is also available on Linux; AudioToolbox
   AAC/ALAC remains authoritative on Apple. MP3 output is an explicit opt-in codec and never runs
   in the real-time path.
3. **M4A/ISO-BMFF compatibility.** Evaluate `minimp4` for safe extraction of AAC and ALAC sample
   descriptions, edit lists, priming/padding, and metadata. Add malformed-container and audiobook
   duration/seek tests before using it in production.
4. **ALAC codec integration.** Do not use implementation code from Apple's public-source ALAC
   repository. Retained upstream Apache-2.0 headers are not compiled or linked. Create an
   independently authored BSD-only ALAC implementation for Linux, initially target CAF and a
   narrowly defined M4A profile, then cross-check bit-exact lossless round trips against AudioToolbox.
5. **Portable test parity.** Add Linux tests for MP3 decode/encode and supported M4A/ALAC profiles;
   retain macOS tests for AVAudioEngine, AVAudioFile, AudioToolbox AAC/ALAC, and all native Apple
   containers. Unsupported profiles must fail explicitly rather than silently writing WAV bytes
   under an `.m4a` extension.

Glint: https://github.com/CrispStrobe/glint
minimp4: https://github.com/lieff/minimp4
AppleALAC public-source repository (headers retained only; implementation not used): https://github.com/macosforge/alac

This workstream does not relax the copyleft policy. FAAD2 is GPL, FDK-AAC has a separate license
with patent conditions, and FFmpeg/libavcodec or LGPL audio stacks are not acceptable dependencies
for this package.

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

Linux is the portable correctness host: it must build Swift 6, run all analysis/DSP/headless-engine
tests, and run every vendored-codec test. macOS GitHub Actions remains the native reference host for
Apple frameworks, device-style audio output, AAC/ALAC, and cross-checks between portable codecs and
CoreAudio. iOS simulator/device builds remain compile and integration gates, not a substitute for
Linux-independent deterministic tests.
