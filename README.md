# parso-audio-engine

A permissively-licensed (MIT) audio engine that reproduces the **full software
functionality of a Pioneer DDJ-FLX4** — two decks, a two-channel mixer, hot cues, loops, all eight
performance-pad modes, Beat FX / Color FX, Smart Fader / Smart CFX, a sampler, mic, monitoring, sync,
recording, and offline track analysis (BPM, key, waveform, structure, loudness) — with **no copyleft
dependencies**. Swift is the current Apple API; portable C/C++ and Kotlin/Android preview APIs now
share the native render and DSP core. See
[`docs/CROSS_PLATFORM_PLAN.md`](docs/CROSS_PLATFORM_PLAN.md) and the support
[`docs/CROSS_PLATFORM_MATRIX.md`](docs/CROSS_PLATFORM_MATRIX.md). Portable support is not complete
until the matrix rows have passed their stated tests and Linux listening review.

The current Swift package ships these layered products:

| Product | What it gives you | Depends on |
|---|---|---|
| **ParsoAudioCore** | Buffers, file decode/encode, sample-rate conversion, loudness, DSP wrappers | — |
| **ParsoAudioAnalysis** | Offline BPM / key / structure / waveform | ParsoAudioCore |
| **ParsoDJEngine** | The complete two-deck DJ engine (FLX4-equivalent) | Core + Analysis |
| **ParsoAudioPlayback / Streaming / Neural** | Playback, streaming, and optional neural services | Core (and Analysis where applicable) |

---

## Status: Apple implementation complete; portable expansion in progress

The Apple layers are implemented and the full `swift test` suite is green on the supported Apple
toolchain, including the
real-audio fixture suites (FLAC / Ogg Vorbis / Opus / MP3 decode + BPM/key/structure/loudness
analysis) once `./scripts/download-fixtures.sh` has run. `docs/SPEC.md` remains the design
source of truth and the test suite remains the executable specification.

- **DSP / RT engine:** `CParsoDSP` (isolator EQ, sweep filter, time/pitch via Signalsmith
  Stretch, delay, Freeverb reverb, look-ahead limiter, lock-free SPSC ring) and `CParsoEngine`
  (allocation-free two-deck render graph) are real. `pe_render` (device) and `pe_step` (tests)
  share one DSP implementation.
- **Codecs:** Apple targets cover WAV, AIFF, CAF, Ogg Vorbis, MP3, AAC, ALAC-in-M4A, and AAC-in-M4B
  audiobook output through AVFoundation / AudioToolbox plus the Xiph Vorbis bridge. Native portable targets cover WAV plus
  fixture-gated FLAC, Ogg Vorbis, Opus, MP3, and AAC paths; portable ALAC/M4A/M4B remain explicitly
  gated pending a permissive codec/container implementation. FLAC, Ogg Vorbis and Opus use vendored permissive C
  (`Cflac`, Xiph `Cvorbis`, `Copus`); Ogg Vorbis uses the BSD-style Xiph encoder/decoder; loudness and SRC use `Cebur128` / `Csrc`; MP3 *encode*
  uses `CGlint` by default, because AudioToolbox has no MP3 encoder — an app under a
  compatible license can supply its own encoder (e.g. LAME) instead via
  `AudioFileWriter`'s `mp3Encoder: (any MP3Encoding)?` parameter, with PAE never
  depending on that encoder itself. See `docs/BYO-CODEC.md`.
- **Analysis:** tempo / beatgrid / key / structure / waveform run through an
  Accelerate-backed pipeline ported from `parso-tonearm` (audio-engine unification, Phase 5).
  The strict `expected` key/BPM values in `Tests/Fixtures/fixtures.json` are still being
  re-verified against the ported estimators; most remain `null` pending that pass.

---

## Requirements

- **Swift 6** toolchain (Xcode 16+). The package sets `swiftLanguageModes: [.v6]` (strict concurrency).
- Apple API: **iOS 17+, iPadOS 17+, macCatalyst 17+, macOS 14+, watchOS 10+** (see `Package.swift`).
- Native preview API: Linux x86_64/aarch64 with a documented glibc baseline; Android API 26+ with
  arm64-v8a and x86_64 AAR artifacts. These portable targets are not yet shipping.
- Linux setup additionally uses `ffmpeg`, `python3-pip`, and `python3-venv` for acceptance video
  and fresh-package checks; `pipewire-bin` is needed only for live device playback/capture.
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

## Portable native SDK preview

The cross-platform work starts with the existing C/C++ real-time targets and a versioned, C-clean
facade. Linux provides a C11/C++17 SDK built with CMake, a host-callback render example, and an
optional PipeWire device adapter. Android packages the same native library in an AAR with a small JNI
bridge and an Oboe device adapter with bounded capture, focus, and route lifecycle seams. Control and offline work move into shared native services gradually;
Swift remains a compatibility API during that migration. No Swift runtime or Apple framework will be
required by the native artifacts.

The first portable examples are intentionally headless: a C renderer and a C++ mixer/recorder on
Linux, plus a Kotlin PCM/JNI smoke app on Android. They will be accompanied by unit tests, native
integration tests, installed-package consumer builds, and Linux human-listening artifacts. See the
[cross-platform plan](docs/CROSS_PLATFORM_PLAN.md) for phase gates and the
[matrix](docs/CROSS_PLATFORM_MATRIX.md) for support status.

The Android source seam includes a closeable `ParsoEngine` wrapper around direct native-order
`ByteBuffer` planes and is packaged by `Bindings/ParsoAudioAndroid` into a release AAR for
arm64-v8a and x86_64. It requires serialized ownership and callback shutdown before `close`;
`ParsoAudioDevice` uses Oboe with preallocated render buffers and a bounded capture ring, while
`ParsoAudioRoute` owns Android audio focus and route-change reopen handling. AAR, external
consumer, and static ABI/package gates pass locally and in CI; Android runtime execution is
intentionally excluded from CI. Physical output, capture quality, latency, route behavior,
and human-listening acceptance remain manual hardware gates.

The native CP1 smoke build is available through CMake:

```bash
cmake -S . -B build-native -DPARSO_BUILD_TESTS=ON
cmake --build build-native
ctest --test-dir build-native --output-on-failure
```

For a portable memory/undefined-behavior check, use a separate build directory so shipping
artifacts remain uninstrumented:

```bash
cmake -S . -B build-native-sanitize -DPARSO_BUILD_TESTS=ON \
  -DPARSO_ENABLE_SANITIZERS=ON -DPARSO_BUILD_CODEC_FIXTURE_TESTS=OFF
cmake --build build-native-sanitize
ctest --test-dir build-native-sanitize --output-on-failure
```

The sanitizer configuration intentionally omits the external installed-package process because
that consumer needs the sanitizer runtime injected by its host environment; the normal
un-instrumented build retains the installed SDK gate.

Check shared-library exports and ELF identity for a release artifact:

```bash
python3 scripts/check-native-abi.py \
  --library build-native/libparso.so \
  --output /tmp/parso-abi.json
```

Aggregate machine-readable release evidence without copying generated media:

```bash
python3 scripts/aggregate-release-evidence.py \
  --gate native-abi=/tmp/parso-native-abi.json \
  --gate android-abi=/tmp/parso-android-abi.json \
  --gate cross-backend=/tmp/parso-crossfader-comparison.json \
  --output /tmp/parso-release-evidence.json
```

The versioned native C ABI also exposes the first CP3 offline service slice: capability reporting,
WAV read/write, raw little-endian integer PCM read/write, sample-rate conversion, and EBU R128
loudness measurement. PCM reads and SRC produce owned interleaved float32 buffers; writers produce
owned byte buffers; all owned results have idempotent release functions. Only implemented formats
are advertised: the current native capability mask includes WAV, FLAC, Ogg Vorbis, Opus, MP3, and
AAC. ALAC, AIFF, and CAF remain unset until their native gates pass. Independent C11 and C++17 consumer tests
exercise the PCM, SRC, and loudness contracts through `ctest`.

The native acceptance target `parso_native_acceptance_artifacts` renders a 30-second headless
artifact through the public ABI and writes a WAV plus JSON duration/event sidecar. The Linux
human-listening runner uses a different real MP3 fixture for each listening slot, compares native
and Python renders of the crossfader timeline, and renders each named engine listening scenario
as its own WAV/JSON pair. Python is only the scenario orchestration layer:
those renders still execute the native C ABI and shared C++ DSP. The native CTest
`native_scenario_smoke` independently exercises the non-crossfader control/command paths,
including Color FX, Beat FX, reverb, time/pitch, loop/scratch transport, automated transition,
and WARM2 band isolation. The generated-tone target remains a
deterministic CTest smoke path; see [`docs/human-visible-acceptance.md`](docs/human-visible-acceptance.md)
for the music gate.

The dependency-free Linux host-callback example is built as `parso_linux_host_callback` and
covered by CTest. Run it with an optional output path to produce a stereo WAV:

```bash
./build-native/parso_linux_host_callback /tmp/parso-host-callback.wav
```

The application owns the output planes and callback schedule; `parso_engine_render` only fills
the bounded block. Device adapters remain outside the engine, so ALSA, PipeWire, JACK, or a
host application's callback can be added without changing the render ABI. Installed C11 and C++17
package consumers check this engine path alongside the Xiph Ogg Vorbis encode/decode service.

For live Linux playback and capture, `parso_linux_pipewire_host` provides the optional device
adapter. It launches `pw-cat` workers around the same public callback contract, keeps system I/O
off the engine render call, supports independent master/monitor/booth targets, and can drain the
native record tap to WAV. The adapter does not link PipeWire or ALSA into `libparso`; install
`pipewire-bin` with `scripts/setup-linux.sh` and see [`docs/linux-device-backend.md`](docs/linux-device-backend.md)
for target discovery and routing. CI uses `--no-device`; named-route restart recording can be
reviewed with [`scripts/run-linux-route-restart-acceptance.py`](scripts/run-linux-route-restart-acceptance.py),
while physical hot-unplug/latency and human listening still require named Linux hardware.

This currently exercises the shared C++ headless render core, including an allocator-instrumented variable-block RT smoke test, and fixture-gated native codec bridges. CI builds and tests these native CMake
targets on native macOS, Linux, and Windows runners; Windows uses the Visual Studio 2022 x64 toolchain. A pinned Android NDK matrix
cross-builds the public library for `arm64-v8a` and `x86_64`; a separate Gradle/AAR job builds the Oboe-backed JNI library, validates every
shipped ELF's 16 KiB alignment and JNI exports, compiles the producer/consumer instrumentation,
and builds an external Maven consumer. Emulator/simulator and attached-device execution are
intentionally excluded from CI; physical-device route, latency, capture-quality, and
human-listening gates remain separate.
The shared `parso` library is also emitted for managed interop. The CP-WIN preview adds a source-generated
C# wrapper under `Bindings/ParsoAudioSharp`; Linux CI cross-compiles its Windows-targeted assembly, while
the native Windows job builds and runs the C# consumer against the MSVC-built DLL. This does not claim
complete Linux codec, device, Python, Android, or Apple-framework support; those require the later gates
in the plan.

The Windows-targeted C# binding exposes the same capability and byte-codec contract through
`CodecServices`. It copies native-owned decode results into managed arrays and releases native
buffers deterministically, and also exposes SRC, EBU R128 loudness, and the control-side
`MixRecorder` for WAV/FLAC/AAC recording. Engine render, control, event, record, and disposal
entry points are serialized per instance for managed lifetime safety. For example:

```csharp
var caps = CodecServices.GetCapabilities();
if (!caps.EncodeContainers.HasFlag(ContainerCapability.OggVorbis))
    throw new InvalidOperationException("Ogg Vorbis is unavailable in this native build.");
var encoded = CodecServices.Encode(samples, 48_000, 2, AudioCodec.OggVorbis);
var decoded = CodecServices.Decode(encoded, AudioCodec.OggVorbis);
```

The Windows C/C++ preview also includes `parso_windows_wasapi_host`, an event-driven shared-mode
WASAPI host. It negotiates default render/capture endpoint formats, feeds the common native
render graph, and publishes bounded capture blocks to the engine mic seam. Linux MinGW validates
its PE build and linkage; endpoint execution, route recovery, latency, and human listening remain
Windows-runner/device gates. Use `--allow-unavailable` only for CI machines without an audio
endpoint; strict hardware runs omit that flag.

The CP-PY preview in `bindings/python` provides synchronous codec, SRC, loudness, summary/key/
structure analysis, headless DJ controls, and record-tap services through standard-library
`ctypes`; see [`docs/python.md`](docs/python.md) for native-library discovery, ownership, and
local verification. Device IO and fresh installed-wheel execution remain separate release gates.

The JavaScript binding in `bindings/javascript` provides the same current C-ABI service surface
for Electron through a stable Node-API addon and for React Native through a documented
`NativeModules.ParsoAudio` host contract. See [`docs/javascript.md`](docs/javascript.md) for
installation, typed-array ownership, and the rule that device callbacks stay native rather than
crossing the JavaScript bridge.

For the Linux native, Windows cross-build, and Android native toolchains on Debian/Ubuntu x86_64, run:

```bash
./scripts/setup-linux.sh
```

The script installs the official Android CLI, SDK platform-tools/build-tools, a pinned NDK/CMake pair,
JDK 17, and Gradle 8.9; configures `ANDROID_HOME`/`ANDROID_NDK_HOME` alongside the Linux/.NET/Windows
cross-build environment; cross-builds `arm64-v8a` and `x86_64`; then runs the Kotlin unit tests, release
AAR/publication checks, and external consumer APK build. It does not require an emulator or device.
Use `--no-build` to install without compiling, `--no-windows-cross-build` or `--no-android-build` to
skip one verification target, `--no-android` to skip Android installation, or pin versions with
`PARSO_ANDROID_NDK_PACKAGE`, `PARSO_ANDROID_CMAKE_PACKAGE`, and `PARSO_GRADLE_VERSION`.

The Linux setup also installs CMake/Ninja, the MinGW-w64 x86_64 toolchain, and the .NET 8 SDK, then
verifies the Linux CTest targets, Windows-targeted C# project, and Windows GNU shared-library build.
On Ubuntu, it uses the Ubuntu .NET backports repository when the requested SDK is not in the built-in
feed (including Ubuntu 26.04, where Microsoft's feed no longer publishes .NET packages); Debian uses
Microsoft's package repository as the fallback.
Native Windows/MSVC validation remains in GitHub Actions and `scripts/setup-windows.ps1`.

Linux CI also installs Swift 6 for a portable Swift smoke lane. It directly compiles and runs the
framework-free shared streaming/playback policy types; the complete SwiftPM package remains an
Apple-framework package and is built/tested on macOS. The Linux MinGW lane builds the shared DLL
and the public C11/C++17 consumer executables but does not execute Windows binaries; execution is
covered by the native Windows CI job.

CI treats first-party Swift, C, C++, and C# warnings as errors where the platform toolchain
supports that setting. Vendored headers remain unmodified and are isolated with narrow system-include
boundaries when their upstream diagnostics would otherwise be reported by strict builds.

On Windows 10/11, run an elevated PowerShell prompt:

```powershell
.\scripts\setup-windows.ps1
```

The script uses `winget` to install Visual Studio 2022 C++ Build Tools, CMake, Ninja, Git, and .NET 8,
plus the official Android CLI, SDK platform-tools, a stable NDK, and Android CMake. It then builds/tests
the native C/C++ targets, runs the C# consumer against the MSVC-built `parso.dll`, and cross-builds
Android `arm64-v8a` and `x86_64`. Use `-NoInstall`, `-NoBuild`, `-NoAndroid`, or `-NoAndroidBuild` to
limit the work.

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
libFLAC (BSD-3), libogg+libvorbis+libvorbisfile (BSD-style), libopus+libopusfile (BSD-3), libebur128 (MIT),
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

### Apple CI baseline

The Apple Swift CI gates were verified on arm64 Apple hardware on 2026-09-10 with macOS 26.5.1,
Xcode 26.6, and Swift 6.3.3: 29/29 fixtures present, `swift build -c release
-Xswiftc -warnings-as-errors`, and the full `swift test -c release -Xswiftc -warnings-as-errors`
suite passed (326 tests in 103 suites). The acceptance-tool build and the whole-package watchOS
and iOS Simulator builds also passed. The Cvorbis target excludes Xiph's standalone analysis
utilities, which define `main` and are not codec sources.

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

Linux portable acceptance will use the same WAV + JSON + MP4 contract through a native CMake CLI.
It requires at least 30 seconds per artifact and a full-track review for phrase/structure scenarios;
the reviewer records audible results in a manifest. Android hardware listening remains pending until
a device is available.

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

### Ecler WARM2-style three-knob master isolator

Parso Audio Engine includes an independent digital profile for an Ecler WARM2-style
master isolator. It uses separate BASS, MID, and TREBLE controls with 300 Hz and
4 kHz crossover points and fourth-order (24 dB/octave) band splits. The supported
control ranges are BASS `-70...+12 dB`, MID `-40...+12 dB`, and TREBLE `-70...+12 dB`.
The isolator is a master control and is separate from each channel's three-band EQ.
See [`docs/ecler-warm2-parity.md`](docs/ecler-warm2-parity.md) for the implementation
notes and source references.

This is an independent, compatibility-oriented implementation. It is not made,
sponsored, endorsed, certified, or authorized by Ecler or NEEC Audio Barcelona, and
it is not an official Ecler implementation. “Ecler” and “WARM2” are used only to
describe the reference control behavior.

In portable DJ software, select the profile when creating the engine, then drive the
three master fields from the application's three large isolator knobs:

```python
from parso_audio import Engine, IsolatorProfile

with Engine(
    sample_rate_hz=48_000,
    max_frames=512,
    isolator_profile=IsolatorProfile.WARM2,
    library_path="/absolute/path/to/libparso.so",
) as engine:
    def set_isolator_knobs(bass_db: float, mid_db: float, treble_db: float) -> None:
        engine.set_mixer_controls(
            master_eq_low=bass_db,
            master_eq_mid=mid_db,
            master_eq_high=treble_db,
        )

    set_isolator_knobs(-70.0, 0.0, 0.0)   # BASS kill
    set_isolator_knobs(0.0, -40.0, 0.0)   # MID kill
    set_isolator_knobs(0.0, 0.0, -70.0)   # TREBLE kill
    set_isolator_knobs(0.0, 0.0, 0.0)     # centre / flat
```

The same mapping is available through the C ABI for a native DJ application:

```c
parso_engine_options_t options;
parso_engine_options_init(&options);
options.isolator_profile = PARSO_ISOLATOR_PROFILE_WARM2;

parso_control_t control;
parso_control_init(&control);
control.master_eq_low = bass_knob_db;
control.master_eq_mid = mid_knob_db;
control.master_eq_high = treble_knob_db;
parso_engine_set_control(engine, &control);
```

For a real-time UI, call the setter from each knob's value callback and keep the
audio callback limited to rendering. The engine smooths the three targets on the
audio thread; the UI should pass dB values in the ranges above and use `0 dB` as
the centre position.

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

### Record the mix (WAV / FLAC / Ogg Vorbis / AAC / ALAC / MP3)

```swift
let rec = try MixRecorder(url: outURL) // AAC-LC, 320 kbps default
rec.start()
// … perform …
try rec.stop()
// Other codecs: .wavPCM(bitDepth: 24), .flac(compression: 5), .alac,
// .oggVorbis(bitrate: 192), .mp3Default (CBR 320 kbps)
```

AAC and MP3 export/recording default to 320 kbps through
`ExportCodec.aacDefault` and `ExportCodec.mp3Default`. Use
`.aac(bitrate: 256_000)` or `.mp3(bitrate: 192)` when an explicit bitrate is required.

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
// Decode (auto-detects container; routes FLAC→libFLAC, Ogg→Xiph libvorbisfile, Opus→libopusfile, else Apple)
let pcm = try AudioFileReader(url: url).readAll()

// Explicit container
let opus = try AudioFileReader(url: url, container: .opus).readAll()

// Encode
let w = try AudioFileWriter(url: outURL, format: pcm.format, codec: .flac(compression: 5))
try w.write(pcm); try w.finish()
```

Supported decode: FLAC, Ogg Vorbis, Opus, MP3, AAC, WAV, AIFF, CAF, and Apple-native ALAC.
Supported encode: WAV/PCM, FLAC, Ogg Vorbis, MP3, AAC and ALAC. Ogg Vorbis uses the BSD-style Xiph
encoder; AAC and ALAC use AVFoundation; MP3 uses the vendored Glint encoder, since AudioToolbox cannot encode MP3. No implementation code from Apple's
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

## On-device neural: CLAP search, and stem separation

Phase 7 (`current_status.md` "Phase 7") adds on-device CoreML-backed features
behind a new, deliberately **watchOS-excluded** `ParsoAudioNeural` target
(`#if !os(watchOS)`, since CoreML — unlike AudioToolbox — is actually present on
watchOS 10, so `canImport` alone wouldn't exclude it; watchOS keeps building via
plain SPM with zero neural dependency). Like every other PAE target, it ships
**protocol surface and license-clean plumbing only** — no model weights, ever; a
library has no On-Demand Resources mechanism, so the app supplies the actual
`.mlpackage`.

- **Semantic/mood search (CLAP).** LAION CLAP
  (`music_audioset_epoch_15_esc_90.14.pt`, HTSAT-base) is **Apache-2.0**, stated
  explicitly by the upstream project and independently verified here.
- **Stem separation** — `SeparationVoice`/`StemChunk`/`StemSeparation`/
  `StemModelProviding`/`StemSeparator` in `Separation.swift` define a
  model-agnostic seam; `SeparationBackendRegistry` makes **which model runs a
  runtime choice**, not a compile-time one (register any number of
  `StemModelProviding` conformances, switch the active one with no code
  change elsewhere). The shipping default is **Spleeter**; see below for why,
  and for the honest limitation that comes with it.

### The licensing survey, and why it matters here

Splitting a mix into vocals/drums/bass/other requires a *supervised* model trained on
paired **(mixed track, isolated stems)** examples — you cannot learn separation
from mixed recordings alone. Shipping such a model behind an MIT-licensed library
redistributed to third parties requires the **training data's license**, not just the
code's, to permit commercial use — a permissive code license does not imply a
permissive weights license, and that distinction is exactly what trips up most of the
field:

| Model | Code license | Weights / training-data reality |
|---|---|---|
| Demucs / htdemucs (Meta) | MIT | **Not commercially usable.** The author stated directly, on record, that the weights are "not covered by the MIT license, and are provided only for scientific purposes" ([facebookresearch/demucs#327](https://github.com/facebookresearch/demucs/issues/327)). Trained on MUSDB18/MUSDB18-HQ, itself academic-use-only, several tracks CC BY-NC-SA. Kept in `parso-tonearm` as a registered-but-**non-default** `StemModelProviding` (see that repo's docs) rather than removed outright, but not PAE's default and not recommended for a commercial ship. |
| **Spleeter (Deezer)** | MIT | **Author's determination: usable.** Deezer ships both code and pretrained weights under MIT, trained on Deezer's own production catalogue — not MUSDB18/MoisesDB. This determination is the app author's own, made after this project's own survey (an earlier pass) had logged Spleeter's weights license as "unresolved on record"; the author's own review is what resolved it here. **This is PAE's shipping default separation backend.** |
| Community "MIT-tagged" RoFormer/UVR checkpoints (e.g. Kim Mel-Band RoFormer) | tag says MIT | **Investigated and rejected as a drop-in.** Traced to a checkpoint trained on MUSDB18 (the same restricted dataset above), MIT-tagged casually by an individual uploader with no legal review of whether relicensing weights derived from NC-restricted training data is actually valid — by the uploader's own words in the public relicensing thread, they did not understand licensing when the tag was first applied. A shinier badge on the same unresolved MUSDB18 problem, not a real fix. |
| Open-Unmix | MIT-ish | One published checkpoint is explicitly CC BY-NC-SA; the default is trained on the same tainted MUSDB18. |
| MDX-Challenge / community models (MVSEP, HuggingFace mirrors) | varies | Increasingly trained on MoisesDB, also CC BY-NC-SA, non-commercial. |

### Spleeter's real limitation, and the actual target

Spleeter is a **2018-era 2D U-Net magnitude-masking model** — materially behind
current transformer-based separators (BS-RoFormer / Mel-Band RoFormer-class
architectures) on separation quality, especially vocal bleed into `other` and
transient smearing on percussive material. It ships as the default because it is
the best backend currently believed to be cleanly commercially licensed, **not**
because it is the best available separator.

**The eventual target is a BS-RoFormer-class model.** Every BS-RoFormer/Mel-Band
RoFormer checkpoint surveyed so far traces back to MUSDB18 or another
non-commercially-restricted training set with no clean rights story (see the table
above) — so none is registered yet. The moment a genuinely cleanly-licensed one
exists (a direct commercial license, a from-scratch train on clean data, or a
maintainer credibly resolving the rights question), swapping it in is exactly:
implement `StemModelProviding`, register it in `SeparationBackendRegistry`, call
`setActive`. Nothing else in the separation pipeline (`StemSeparator`, a cache, a
UI) changes. Track this on the tracking issue for this repo (see below).

### Slakh2100 — the from-scratch instrumental fallback, and its real limitation

[Slakh2100](https://zenodo.org/records/4599666) is the one dataset found in this
survey with unambiguous commercial terms for **training a new model from scratch**:
**CC-BY-4.0**, 2,100 tracks / 145 hours, individual instrument stems. The catch: it's
**synthetic** — sample-library instrument renders from the Lakh MIDI Dataset, not
real recordings — and because it's MIDI-derived, **it has no vocal stems** (there is
no sung-vocal MIDI to render). A from-scratch Slakh2100-trained instrumental-only
(drums/bass/other) model is scaffolded (the `StemModelProviding` surface it would
conform to already exists) but **not trained** — that's a real multi-day GPU compute
job, not something executed in a coding session, and needs the author's explicit
go-ahead on committing that compute budget before it starts. Until then, Spleeter is
the shipping default; Slakh2100-training remains a possible future registered
backend alongside it, not a replacement.

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
from-scratch vocals-capable project remains one path to closing the gap Spleeter's
2018-era architecture leaves open; a cleanly-licensed BS-RoFormer-class release from
elsewhere (see above) is the other, and would likely arrive faster. Both are tracked
on the tracking issue for this repo, which also names BS-RoFormer as the target
architecture once either path clears.

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
