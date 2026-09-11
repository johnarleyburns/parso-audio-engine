# Android, Linux, Windows, and Python 3 expansion plan

Status: implementation authorized; CP1 Linux build/headless slice is verified. CP0 contract/docs committed in `efa3d2f`; its baseline, detailed API/test inventory, and toolchain validation gates remain pending. Python 3 scope is specified for the next development session.

## Objective and scope

Keep the existing Swift products and add Kotlin/Android, Linux C/C++, Windows C/C++, Windows C#, and approachable Python 3 APIs over one shared native engine. The Windows C and C++ APIs use the versioned C ABI and C++17 wrapper; the C# API uses generated P/Invoke over that C ABI rather than binding to C++ types. Python should make file IO, analysis, DSP, mixing, and recording easy to use from scripts and interactive sessions. First deliver PCM-driven DSP/rendering, then complete file IO, DJ control, analysis, and recording parity. Playback, streaming, and neural products require their own acceptance inventory; they must not be implicitly advertised as portable when only the DJ engine is ready.

Proposed initial targets: Android API 26+, arm64-v8a devices and x86_64 emulators; Linux x86_64 and aarch64 with a documented glibc baseline; Windows x64 with MSVC and .NET. Preserve the Apple deployment targets in `Package.swift`. These are planning defaults, to be confirmed by the first toolchain/device spike. No Swift runtime should be needed on Android, Linux, or Windows native artifacts.

Windows support is a separate binding and platform gate. Linux will produce the best-effort Windows
cross-builds that can be reproduced locally, using CMake with an audited MinGW-w64 or LLVM/Clang
toolchain where available. Those artifacts are cross-compilation evidence, not a substitute for the
native Windows build: MSVC ABI, DLL loading, Windows SDK behavior, Win32/WASAPI adapters, and C# native
interop must be compiled and tested on a Windows runner. Toolchain/runtime licenses remain subject to
the repository allowlist; no copyleft dependency may be introduced to obtain the cross-build.

Python initially targets CPython 3 on Linux x86_64/aarch64. Select and document the minimum Python version and tested interpreter/architecture matrix during the packaging spike; Python 3.14.4 is available locally. Other OSes, interpreters, and free-threaded builds are not advertised until validated. Keep the user-facing Python API simple, with an installable package, context-managed resources, clear exceptions, and optional NumPy interoperability.

## Findings from this repository

- `CParsoDSP/include/parso_dsp.h` and `CParsoEngine/include/parso_engine.h` already expose C interfaces. Reuse their implementations; do not build a second render graph.
- `Package.swift` unconditionally enables `SIGNALSMITH_USE_ACCELERATE` and links Accelerate. Native portability needs a build change and numerical validation.
- `ParsoDJEngine.swift` owns substantial orchestration, including pads, Smart Fader, loading, and recording. Wrapping `pe_*` alone does not reproduce this API's behavior.
- Analysis uses Swift and Accelerate. File IO and device integration use Apple frameworks. Those services need portable implementations or platform adapters.
- The public surface now includes playback, streaming, neural features, multiple decks, and stems. The older three-product/two-deck description is not a complete inventory.
- CP0 revised SPEC's Apple-only scope and preserved the historical Linux Swift retirement in `UNIFICATION_PLAN.md` §4b. Extend the contract/docs to Python as implementation begins.
- The existing C interface exposes concrete control/command structs and caller-owned buffers. Treat it as an internal bridge until versioning, lifetime, and threading contracts are audited.
- Tool check (2026-09-10): GCC 15.2.0, CMake 4.2.3, and Python 3.14.4 are available. The user reports Swift is now installed, but this session cannot locate `swift` in PATH or the usual installation locations checked. Linux Swift does not provide Apple's Accelerate/AVFoundation/AudioToolbox frameworks or Xcode; the full existing Swift package baseline still requires Apple hardware/CI. The CP1 Linux build and CTest gate passed with the portable Signalsmith path; the Android CLI is not on PATH, but the preconfigured NDK cross-builds pass for both advertised ABIs and CI now provides a pinned Android NDK gate.

## Intended architecture

```text
Swift SDK       Kotlin Android SDK       Linux C/C++ API      Windows C/C++ API
    |                  | JNI                   |                 | C ABI
    |                  |                     |          Windows C# API
    |                  |                     |                 | P/Invoke
    |                  |                     +-----------------+
    |                  |                                       |
    +------------------+-------- versioned public C ABI --------+
                                    |
                            Python 3 package (FFI)
                 shared native services and DJ control
                 IO / analysis / recording / commands
                                    |
                      CParsoEngine -> CParsoDSP

Device adapters: Apple existing backend | Android Oboe | Linux host callback/backend | Windows WASAPI (later)
Builds:          SwiftPM               | Gradle + CMake | CMake                       | CMake/MSVC
Python packaging: Python build frontend + native CMake artifacts -> wheel / source distribution
```

Native Core and Analysis remain independent of DJ concepts. Shared DJ orchestration belongs in an engine/control module. Move behavior incrementally from Swift into native services and have Swift delegate to them, retaining its public API and strict concurrency. CMake and SwiftPM compile the same sources, with platform-specific settings.

## Delivery phases and acceptance gates

Every phase includes README/docs, runnable examples, unit tests, and integration tests for its new public behavior. These are completion requirements, not documentation cleanup deferred until release. Update the capability matrix and ledger with the actual evidence at each gate.

### CP0 — Establish the contract and baseline

1. Run `swift build` and the full fixture-enabled `swift test` on an Apple runner; record actual results and disabled suites.
2. Inventory every public API and FLX4 acceptance row into a matrix: Apple implementation, native coverage, Android/Linux/Python target, corresponding test, milestone.
3. Separate DJ parity from playback/streaming/neural follow-ups, including newer multi-deck/stem features already exposed by the engine.
4. Amend SPEC targets, layering, backend policy, and acceptance requirements; reconcile README requirements with Package.swift. Add this CP workstream to the handoff instructions without conflating it with the original phases.
5. Pin compiler, CMake, NDK, Gradle, SDK, Python packaging/FFI tools, and dependency versions after validating compatibility. Audit dependency configuration and licensing under the repository allowlist. Choose the Python version matrix and Linux wheel compatibility floor based on tested builds.

Gate: reproducible Apple baseline and an explicit cross-platform feature matrix. Existing failures remain visible; no weakened tests or fabricated fixture ground truth.

### CP1 — Portable native build and headless rendering

1. Add root CMake targets for existing DSP, engine, and required vendored dependencies; preserve vendor source/provenance and Apple SwiftPM builds.
2. Select Signalsmith's portable FFT path off Apple, verifying the vendored version's configuration. Keep Accelerate on Apple initially. Audit SIMD guards, denormals, atomics, aligned allocation, compiler flags, and timing calls for x86_64/ARM64.
3. Add CTest executables using deterministic signal generators and equivalent assertions from the Swift DSP/engine tests. Compare portable and Apple outputs within documented numerical tolerances, not blanket bit equality.
4. Exercise `pe_step` and `pe_render` with identical commands and buffers, including variable callback sizes and maximum-frame limits.

Gate: Linux native build plus Android NDK cross-build; device-free two-deck mix, EQ, crossfader, and time/pitch tests pass. No Apple or Swift linkage in portable artifacts.

### CP2 — Supported C SDK and C++ wrapper

1. Introduce a public facade, e.g. `Sources/CParsoAPI/include/parso.h`, over the existing internal `pe_*`/`pd_*` interfaces.
2. Specify opaque handles, fixed-width fields, version/size-tagged options, export visibility, capability queries, status codes, and off-thread error details. Catch exceptions at every C boundary.
3. Define PCM format, strides/layout, sample-rate policy, channel mapping, frame units, and 64-bit transport positions. Avoid pointer packing or language-dependent enums in the new ABI.
4. Define owning and borrowed buffer operations, asynchronous release acknowledgments, cancellation, queue-full behavior, event overflow, and shutdown order. Destruction must stop/join callbacks before freeing resources.
5. Enforce one serialized control producer and one event consumer. Audit current buffer setters and snapshots before permitting concurrent render/control access; verify required atomics are lock-free on each supported ABI.
6. Provide a move-only C++17 RAII wrapper over the C ABI, with explicit close/error handling and no STL types in exported ABI signatures.
7. Install headers, shared/static libraries, CMake package config, pkg-config metadata, and standalone C and C++ consumer examples.

Gate: independent C11 and C++17 consumer builds; lifetime, double-close protection, invalid-input, long-position, saturation, ASan/UBSan, and control/render stress tests pass.

### CP-WIN — Windows C/C++ and C# support

1. Build the shared C ABI and C++17 wrapper natively with MSVC on `windows-latest` using the Visual Studio 2022 x64 generator. Produce and test the Windows DLL/import library or static-library form, headers, CMake package, and standalone C11/C++17 consumers.
2. Add a Linux best-effort cross-build using a reproducible, license-audited MinGW-w64 or LLVM/Clang toolchain when available. Keep this job separate from the native Windows job; a Linux-produced artifact is cross-compilation evidence and is not the release authority for MSVC ABI, Windows SDK, DLL loading, or Windows runtime behavior.
3. Add a C# API over the versioned C ABI using source-generated `LibraryImport`/P/Invoke. Keep C ABI structs fixed-width and blittable where practical; do not expose C++ types. Define ownership, `SafeHandle` shutdown, status-to-exception mapping, buffer lifetime, architecture selection, and native library discovery.
4. Compile the managed Windows-targeted project on Linux with .NET Windows targeting enabled where the SDK supports it. Run managed marshaling/unit tests on Linux when they do not require Windows runtime APIs, then run the actual C# native consumer, DLL load, ABI, and Windows API/device-adapter tests on the native Windows runner.
5. Keep Windows-specific backends (for example WASAPI, device enumeration, and route changes) behind platform adapters. Cross-compilation may validate headers and linkage, but only native Windows execution can establish those behaviors. NativeAOT is an optional later packaging target and must be built/tested on Windows rather than assumed cross-compilable from Linux.
6. Add Windows x64 artifacts and a NuGet/CMake consumer smoke test only after the standalone consumers pass outside the repository. Consider Windows ARM64 as a follow-up matrix expansion after x64 is stable.

Gate: Linux host build passes; the reproducible Linux-to-Windows cross-build passes when its audited toolchain is available; GitHub Actions native macOS, Linux, and Windows jobs are green; native Windows C11/C++17 and C# consumers load and exercise the same ABI; and Windows-specific device/runtime tests pass without weakening the portable tests.

The managed codec slice now provides `CodecServices.GetCapabilities`, `Encode`, and `Decode` over
the same versioned ABI. Decode results are copied before the native owned buffer is released, and
the Windows consumer exercises an Xiph Ogg Vorbis encode/decode round trip. Linux verifies the
Windows-targeted assembly; native DLL loading remains a Windows-only gate.

The C# `Engine` binding also exposes activation, bounded drain, dropped-frame inspection, and reset
for the native master record ring; the Windows consumer includes that smoke path.

It now also copies and pins deck PCM planes, retains the pointer table until replacement or close,
and queues the portable play/pause commands. Linux verifies the managed assembly; signal and DLL
lifetime execution remains a native-Windows gate.

The CP-PY offline spike now provides `bindings/python`, a dependency-free `ctypes` package with
capability discovery, the same six native byte-codec selectors, native SRC/loudness wrappers, and
bounded headless rendering with retained deck-buffer ownership and shared command payloads. Its
source tests and Vorbis example pass
against the Linux CMake library. Fresh-venv installation is pending because this session's host has
no `pip`/`ensurepip`; wheel construction itself passes through setuptools.

The public event ABI now drains the native render-to-control ring without exposing internal engine
types. C++, Python, and C# consumers can observe copied transport/playhead/state/peak notifications
after a render boundary; the audio callback remains allocation-free and non-blocking.

The binding also includes a 30-second minimum `render_acceptance.py` seam that writes actual native
engine output through the public WAV service plus a JSON duration/event sidecar. It is intentionally
only the first acceptance artifact and does not claim full FLX4 scenario or analysis coverage.

The native CMake target `parso_native_acceptance_artifacts` provides the matching framework-free
C++ smoke artifact and is covered by CTest. The Python runner drains the record ring while the
C++ smoke currently captures its render output directly; both are initial acceptance seams, not
the completed fixture-analysis/DJ scenario matrix.

### CP3 — Shared offline services and DJ behavior

1. Expose native buffers, SRC, loudness, FLAC/Xiph-Vorbis/Opus bridges, and WAV IO. Audit CGlint's current decode/encode paths with real fixtures before advertising portable MP3 support.
2. Publish per-platform decode/encode/container capabilities. Android AAC can use a platform codec adapter after validation; Linux AAC/ALAC/AIFF/CAF require separately validated implementations or providers. Return explicit unsupported-format errors until implemented. Container support is a separate gate from codec support.
3. Extract DJ control in small slices: transport/cue/jog; loop/hot-cue/quantize/sync/slip; pads/sampler; mixer/monitoring/mic; Smart Fader/CFX. Keep all language wrappers on this shared behavior.
4. Port analysis in order: FFT/STFT, onsets, tempo/beatgrid, key, structure, waveform, full analysis. Preserve SPEC algorithms, normalization, frame conventions, and deterministic behavior. Evaluate the existing portable FFT facilities before adding a dependency.
5. Move recording orchestration into an off-thread native service consuming the existing record ring. Start with WAV/FLAC, expose dropped-frame accounting, then add supported platform codecs. No MP3 mix recording.

The first CP3 native slice is now the versioned C ABI's offline PCM/SRC/loudness contract:
`parso_capabilities_get` reports WAV and raw little-endian integer PCM support plus the validated SRC
and EBU R128 services. `parso_wav_*`, `parso_pcm_*`, `parso_src_convert`, and
`parso_loudness_measure` provide borrowed-input/owned-result operations, and independent C11/C++17
consumers cover round trips, malformed input, SRC frame-count metadata, loudness results, and
idempotent release. No unsupported container is advertised by this slice.

The next CP3 analysis slice adds `parso_analysis_measure` for a deterministic portable summary
(duration, RMS, peak, and energy-envelope BPM/confidence) plus caller-owned `parso_waveform_generate`
min/max buckets. The C11 consumer, Python binding, and C# consumer exercise the same summary API;
the native and Python 30-second artifacts include analysis and waveform JSON. A follow-on
`parso_key_measure` service now ports the Swift HPCP/Krumhansl-Schmuckler contract with a
dependency-free radix-2 STFT, and C11/Python/C# consumers cover a rooted A-minor vector. Structure
now has a bounded caller-owned `parso_structure_measure` service that mirrors Swift's deterministic
energy/coarse-band/zero-crossing novelty segmenter; C11/C++17/Python/C# consumers cover synthetic
transitions. Full phrase/self-similarity parity remains a separate gate.

The CP3 codec sub-phase now vendors Xiph libogg 1.3.5 plus libvorbis 1.3.7 (BSD-style), replacing
the former stb_vorbis decode-only target. The public byte ABI exposes Ogg Vorbis read/write through
the Xiph bridge, while Glint remains the MP3/AAC/portable Opus byte path and libFLAC remains the
FLAC byte path. Public capability bits and C11 fixture consumers cover the enabled formats; any
future platform-specific encoder can remain an injected provider without adding GPL code to this
package.

Gate: shared scenario vectors and real fixtures pass through native and Swift APIs. Cross-backend tolerances are justified per measurement. Missing formats remain explicit capability gaps and block any claim of full codec parity.

### CP4 — Kotlin/Android SDK and device output

1. Build an AAR with the native library and a small JNI bridge. Suggested API modules: core, analysis, and DJ; initially one AAR can carry them to avoid duplicated native runtimes.
2. Mirror concepts idiomatically: `AudioBuffer`, `TrackAnalysis`, `DJEngine`, `Deck`, `Mixer`, `MixRecorder`. Use explicit closeable ownership, suspend functions for IO/analysis, and immutable telemetry through Flow/StateFlow.
3. Serialize control calls on a dedicated dispatcher/executor. Cancellation must coordinate native job completion before releasing memory. JNI validates handles, buffer bounds, and status codes.
4. Keep JNI, JVM callbacks, object allocation, and GC-managed memory out of the audio callback. Copy/import PCM off-thread into native-owned storage; use direct buffers only with explicit lifetime contracts. Drain events on a control worker.
5. Add Oboe output/capture with preallocated planar/interleaved conversion and bounded callback-size handling. Negotiate actual sample rate, channel count, and burst size. Reconfigure safely on disconnect or route change.
6. Handle audio focus, interruptions, foreground/background lifecycle, microphone permission, URI/file-descriptor input, and unavailable cue/booth outputs. Background service policy belongs in the app integration/sample.
7. Supply a small sample: load two files, mix, EQ, cue/loop, analyze, record, display meters. Publish local Maven artifacts first; remote publication is a separate release action.

The first Android bridge slice now builds `libparso_android.so` for arm64-v8a and x86_64. Its
Kotlin-facing `ParsoNative` declaration uses direct `ByteBuffer` planes for bounded render calls
and exposes create/destroy/play/pause, mixer control, typed transport/loop commands, and copied
engine stats over the public C ABI. `ParsoEngine` adds the source-level
closeable wrapper: it validates direct native-order buffers and max-frame bounds, serializes
ownership by contract, retains direct deck PCM buffers until replacement/close, and makes close
idempotent. `Bindings/ParsoAudioAndroid` now builds a release AAR containing the Kotlin classes,
`libparso.so`, and `libparso_android.so` for arm64-v8a and x86_64. JVM lifetime tests, device
output, capture, audio focus, and route-change behavior remain required before Android support can
be advertised.

The Android preview now also exposes `ParsoAnalysis` summary/key/structure calls over borrowed direct
buffers, `ParsoVorbis` Xiph encode/decode with copied PCM ownership, `ParsoOffline` SRC/loudness
services, and `ParsoEngine`'s bounded record tap. These surfaces compile through the local Maven AAR
and an external application consumer. The consumer now includes a runnable sample activity and an
AndroidJUnit4 end-to-end scenario covering those services plus engine render/record drain;
instrumentation execution and performance remain hosted emulator/device gates.

Gate: JVM API/lifetime tests, the external AAR consumer build, JNI instrumentation compilation, and
16 KB page-size validation now pass locally and in CI. Instrumentation execution, emulator behavior,
and real-device playback/capture/route-change/underrun tests remain. Emulator tests do not establish
latency performance.

### CP5 — Linux playback and native SDK packaging

1. Make host-supplied audio callbacks the dependency-free baseline: applications can connect their own device system to the shared render path.
2. Evaluate an optional miniaudio device adapter, restricted to device IO, against the dependency policy. Review transitive/runtime audio dependencies separately; do not silently introduce a prohibited dependency through a backend.
3. Cover device enumeration, negotiated rate/layout, bounded conversion buffers, hot unplug, capture, master/cue/booth routing, and graceful shutdown. Report missing hardware routing as unavailable.
4. Provide headless render-to-WAV and live C/C++ mixer examples. Package versioned libraries, SONAME, headers, symbols, notices, and reproducible source-build instructions; establish the glibc floor in CI containers.

The dependency-free `parso_linux_host_callback` example now supplies the first host callback
contract. The host owns planar output buffers, chooses each bounded callback size, invokes
`parso_engine_render` once per callback, and drains events/stats only after the callback boundary.
An optional output path writes the rendered stereo signal as WAV. No device API, allocation,
logging, or file IO is required by the render call itself; a future ALSA, PipeWire, JACK, or
application-owned device adapter can connect to this same contract. Installed C11 and C++17 CMake-package
consumers exercise render/service lifetimes in addition to the Xiph Vorbis codec round trip.

Gate: clean external C/C++ consumers on Linux x86_64/aarch64, headless parity, and live playback/capture acceptance on documented hardware. A host callback SDK can ship before an optional device backend clears review.

### CP6 — Linux human listening acceptance

The maintainer has Linux and no Android hardware. Make Linux the primary human listening/review host, retaining separate Android automation and an explicitly pending Android hardware gate. Linux listening cannot establish Android device latency or routing correctness.

1. Add a native acceptance CLI under `Tools/NativeAcceptanceArtifacts`, built by CMake, that needs neither Swift nor Apple frameworks. Reuse `Tests/Fixtures/fixtures.json`, the existing scenario/event conventions, and the WAV + JSON contract consumed by `scripts/render-acceptance-video.py`.
2. Generate audio through the shipping public native API and shared engine, with the actual rendered signal in the WAV and matching events/analysis in the sidecar. Validate schema compatibility with the existing Python renderer. Do not overlay effect labels on an unchanged source track.
3. Preserve `docs/human-visible-acceptance.md` requirements: at least 30 seconds per listening artifact; full-song analysis before clip selection; full-track audio/video for phrase/structure review. Keep fixtures and generated artifacts untracked.
4. Supply a single Linux runner that downloads missing fixtures, builds the CLI, executes scenarios, validates WAV/JSON, and renders MP4s. Keep ffmpeg exclusively a developer tool. Produce an index with paths, scenario intent, and review status so the maintainer can audition the batch easily.
5. Cover source decode fidelity; varispeed versus key-lock; EQ full kill/sweeps; crossfader transitions; sync/quantize; loop/cue/roll boundaries; scratch/backspin/release; Beat FX tails; Smart Fader/CFX; sampler; mic mixing; recording roundtrip. Export master, monitor, and booth buses separately where relevant, even if the local device lacks enough outputs.
6. Include live Linux playback/capture and a recorded-session example to reveal device glitches that offline rendering misses. Use a deterministic mic fixture for repeatable offline checks and an optional real-mic session for capture review.
7. Offer dry/wet and Apple-reference/Linux A/B files with identical inputs, configuration, event timing, and explicit latency alignment. Level-match only when evaluating timbre; preserve unnormalized outputs for gain, limiter, and level-automation review. Missing Apple reference artifacts remain visible, not silently regenerated by Linux.
8. Write a review manifest with commit, fixture hashes, sample rate, scenario parameters, output paths, automated measurements, and manual results. Human fields record reviewer/date, pass/fail, timestamped audible issues, and retest status. Generated artifacts start as `pending`; only actual listening can mark them passed.
9. Run equivalent scenarios through the installed Python wrapper as well as the C/C++ CLI. The Python script must load, configure, render, analyze, and record through the public Python API, rather than merely launching the native acceptance executable. Produce separate WAV/JSON/MP4 artifacts and record package/interpreter/native-library versions and binding identity in the review manifest. Compare Python and native outputs with the same inputs, event timing, and tolerances. Require actual Linux human sign-off for Python decode, time/pitch, EQ, mix/FX, cue/loop, and recording scenarios. Add Python-driven live playback/capture review once the native device backend is ready; device callbacks remain native.

The dependency-free `scripts/index-linux-acceptance.py` now creates the review manifest for
generated WAV/JSON pairs. It records the current commit, SHA-256 hashes, parsed WAVE format,
actual and declared duration, scenario/fixture IDs, and an explicit pending human-review state;
missing pairs, malformed headers, short artifacts, and duration mismatches fail the command.

The Python binding now exposes the same bounded A/B crossfader control and can render a matching
two-deck `crossfader-sweep` artifact. Native and Python sidecars use the same four auditable event
names, so the indexer can review both bindings without treating one as a proxy for the other.
`scripts/compare-linux-acceptance.py` checks those sidecars and the decoded 16-bit PCM with an
explicit sample tolerance, emitting a machine-readable parity report before human listening.
`scripts/run-linux-acceptance.py` orchestrates the native build, Python render, index, and
comparison into one safe output directory without deleting prior artifacts.
The C# engine wrapper exposes the same bounded `SetCrossfader` control and its Windows-targeted
consumer exercises both endpoints; native DLL execution remains a Windows CI gate.

The native CMake build now has an opt-in `PARSO_ENABLE_SANITIZERS=ON` path for AddressSanitizer
and UndefinedBehaviorSanitizer. The portable core/public-API CTest subset has been run with that
instrumentation; normal builds leave sanitizer flags disabled.
`scripts/check-native-abi.py` records ELF class/machine, SHA-256, and required public C ABI exports;
the same checker accepts explicit JNI symbol lists for Android shared libraries.
The native `long_session_consumer` stress test renders beyond the record-ring capacity with
variable callback sizes, verifies command-queue saturation is reported, and checks monotonic frame
telemetry plus nonzero dropped-frame accounting.
`scripts/aggregate-release-evidence.py` combines these JSON gate results with the current commit
without copying generated audio or changing pending human-review status.

Gate: the maintainer can run and listen on Linux through both C/C++ and Python without Android or Swift; automated artifact checks pass and required scenarios have recorded human sign-off for each binding. Native CLI listening alone does not validate the Python wrapper. Audible defects become regressions with reproducible timelines. Update fixture BPM/key ground truth only after actual verification, as required by AGENTS.md.

### CP-PY — Python 3 wrapper and packaging (after CP3; device integration after CP5)

1. Add a Python package, proposed location `bindings/python`, over the versioned public C ABI. Select a small FFI approach in a documented spike (stdlib ctypes or an allowlisted extension/FFI dependency); verify error handling, ownership, native-library loading, and GIL behavior before committing to it. Do not expose internal C++ structures or reimplement algorithms in Python.
2. Provide discoverable Core, Analysis, and DJ APIs with type hints, docstrings, Python exceptions mapped from native statuses, context managers, idempotent `close()`, and explicit capability queries. Start with buffers and synchronous headless rendering, then file IO, SRC/loudness, analysis, DJ controls, and recording as native services become available.
3. Define PCM dtype, layout, strides, channel count, sample-rate and 64-bit frame semantics. Accept Python buffer-protocol data with validated bounds/contiguity; add optional NumPy convenience. Copy into native-owned storage by default off-thread; any zero-copy view must keep its owner alive and have documented mutability/release rules. Reject invalid, closed, stale, or incompatible handles safely.
4. Serialize control writes and event draining to respect the native SPSC contract. Release the GIL where supported for long native offline calls, retaining referenced storage until completion. Define cancellation and concurrent close behavior. No Python callbacks, interpreter work, GIL acquisition, or Python allocation may occur on the real-time audio thread; poll events off-thread and let native backends own live playback/capture.
5. Build versioned Linux wheels and a source distribution using CMake artifacts. Specify native-library discovery, ABI compatibility checks, supported CPython/architecture/glibc combinations, bundled dependency notices, and source-build prerequisites. Test clean virtual-environment installation outside the checkout without an existing system Parso library. Prefer local wheel validation first; publishing is a separate release action.
6. Add unit tests for conversions, shape/dtype/stride errors, status-to-exception mapping, context-manager/close semantics, object lifetimes, and control state. Add integration tests for decode -> analyze -> load -> render -> record -> decode through Python, numerical parity with native scenarios, repeated create/close, concurrency/cancellation, and unsupported capabilities. Run them against installed wheels across the declared Python matrix, with native sanitizers where compatible.
7. Add runnable Python 3 examples for file inspection/analysis, PCM DSP, two-track headless mixing and WAV export, optional NumPy use, recording, and native-backed Linux playback when available. CI runs examples in fresh virtual environments with documented fixtures and checks actual output artifacts.
8. Update README with Python installation, a short usable quickstart, requirements and capability gaps; add a Python guide/API reference covering ownership, exceptions, buffers, threading, packaging, and troubleshooting. Extend SPEC, architecture, feature matrix, and `docs/human-visible-acceptance.md` to Python. All commands must be verified against built package artifacts.
9. Supply a Python Linux listening runner meeting CP6's duration, full-track phrase, artifact, and manual review requirements. Reuse the existing video renderer only for presentation; the audio under review must come from the Python API.

Gate: documented Python APIs, installed-wheel unit/integration tests, runnable examples, and source-distribution builds pass on declared targets; CP6 records Python-specific Linux listening sign-off before claiming Python release acceptance. Other bindings keep their own gates.

### CP7 — Cross-platform release gate

- CI: existing Apple Swift tests plus native macOS CMake tests; Linux GCC/Clang native tests, sanitizers, and best-effort Windows cross-builds; native Windows MSVC/CMake/C/C++/C# tests; Python installed-wheel unit/integration/example tests across declared interpreter versions and architectures; Android NDK builds, Kotlin tests, emulator instrumentation, and a scheduled hardware run.
- Run matching serialized command scenarios through Swift, C, C++, C#, Kotlin, and Python, covering every matrix row. Use numeric audio tolerances and exact discrete-state assertions. Python release acceptance includes its own Linux human listening results, not only native results; C# Windows acceptance includes native DLL and platform-backend tests.
- Instrument allocation and prohibited operations around engine DSP calls, including transitions and queue pressure. Keep measurement outside RT kernels where it requires system calls. Verify zero allocations after preparation.
- Measure render time against actual callback deadlines, dropouts, memory, recording overflow, long-track precision, and long-session stability on named devices. Record measured budgets; do not promise universal latency.
- Verify dependency notices, source pins, SPDX policy, binary architecture/page alignment, exported symbols, and archive contents. Test consuming the packaged artifacts outside the monorepo.
- Publish SDK/API documentation and an honest platform capability table. Release candidates require Apple regression gates and all advertised portable features to pass; tag/publish only as a deliberate release step.

Android hardware validation may be performed later by a contributor or device lab. Until then, label Android device performance/routing unverified and the SDK preview as appropriate; do not block the Linux SDK release on unavailable Android hardware or claim that emulator/Linux results substitute for it.

The CI workflow now runs a pinned Android NDK 27.2.12479018 / CMake 3.22.1 matrix for
`arm64-v8a` and `x86_64`, builds `libparso_android.so`, and checks the JNI export set. This
establishes repeatable native ABI evidence only; it does not satisfy the Kotlin/Gradle, AAR,
emulator, or real-device gates.

## Documentation, examples, and test deliverables

| Area | Required updates and evidence |
|---|---|
| README | Explain the shared native architecture; SwiftPM, Gradle/Maven, and CMake installation; platform requirements; feature/codec gaps; runnable quickstarts; Linux listening command; links to full guides. Remove stale Apple-only and three-product claims as support lands. |
| Architecture/spec | Update `docs/SPEC.md`, `docs/architecture.md`, and the historical retirement note in `docs/UNIFICATION_PLAN.md`; document ownership, threading, C ABI compatibility, backend selection, and native module boundaries. |
| Feature acceptance | Extend `docs/FLX4-feature-inventory.md` with platform support, unit/integration test mapping, and Linux listening scenarios; separately inventory newer non-FLX4 APIs. |
| Platform/API guides | Add Android, Linux, and Windows build/integration guides, C/C++ ownership/error examples, C# `LibraryImport`/`SafeHandle` guidance, Kotlin coroutine/lifecycle guidance, codec capability tables, packaging instructions, and troubleshooting. Update NOTICE/VENDOR records for actual dependency changes. |
| Human review guide | Extend `docs/human-visible-acceptance.md` with native Linux commands, prerequisites, scenario coverage, A/B procedure, review manifest, live listening instructions, and honest pending hardware status. |
| Examples | Maintain Swift examples against migrated APIs; add standalone C headless renderer, C++ live mixer/recorder, Kotlin Android mixer app, and native Linux acceptance CLI. Build examples and smoke-test documented commands in CI where feasible. |
| Unit tests | Native DSP/control/analysis/codec correctness and boundary cases; C++ ownership/error behavior; Kotlin API state and cancellation; preserve Swift regressions. Test behavior, not merely forwarding calls. |
| Integration tests | End-to-end decode -> analyze -> load -> command -> render -> record -> decode; identical scenario replay across bindings; JNI/C# lifetime and queue pressure; Windows DLL load and native-backend behavior; device restart/route changes; installed CMake/NuGet/Maven/SwiftPM consumer builds. |
| Acceptance tests | Linux WAV/JSON/MP4 schema and duration checks, native Windows C/C++/C# consumer checks, human listening manifest, real-fixture plausibility, Apple/native comparison, long-session/RT safety, and separately tracked real-device Android checks. |

Each implementation PR must include the relevant rows above or explicitly identify why a row does not apply. No phase is complete with examples that do not build, undocumented public APIs, or pending tests for advertised behavior.

Python applies to every row of this table: README installation/quickstart, Python API and build docs, example scripts, unit and installed-package integration tests, wheel/source-distribution consumer checks, cross-binding parity, and Linux human listening artifacts/sign-off. CP-PY lists the concrete deliverables; these must accompany the wrapper implementation rather than follow later as cleanup.

## Recommended execution order

CP0 remaining verification -> CP1 -> CP2 -> CP-WIN -> CP3 -> CP-PY offline/package implementation -> CP5 -> CP-PY live-device integration -> CP6 (C/C++/C# and Python listening) -> CP4 -> CP7. Preserve the existing phase IDs; CP-WIN and CP-PY are additional milestones. Prioritize Linux and Python usability/listening before Android integration because Linux is the maintainer's available review platform, while Windows native behavior is validated in CI. Begin the native artifact CLI in CP2 and add scenarios with each feature; add C# and Python scenarios as their APIs land. CP6 is the full listening gate for the applicable bindings. A thin PCM-only Android smoke app can validate JNI/Oboe earlier, but must not be presented as the complete SDK.

Use focused conventional commits and update the untracked phase ledger after every commit. The verified CP1 Linux slice now provides CMake targets, C-clean header coverage, and `pe_step`/`pe_render` parity coverage with variable bounded callback sizes. Finish the detailed CP0 inventory/toolchain checks and obtain the Apple baseline separately; missing Apple hardware is an explicit verification gap, not a reason to skip Linux native progress or declare Apple tests passed. Discover the reported Swift installation, and add the Android NDK cross-build when that toolchain is available. Do not treat Linux Swift as a substitute for macOS/Xcode testing. Python implementation remains the later CP-PY milestone.

## External implementation references

- [Android Oboe overview](https://developer.android.com/games/sdk/oboe): native audio adapter candidate.
- [Android low-latency audio guidance](https://developer.android.com/games/sdk/oboe/low-latency-audio): stream configuration and callback constraints.
- [Oboe JNI/latency FAQ](https://github.com/google/oboe/blob/main/docs/FAQ.md): boundary and sample-rate considerations.
- [miniaudio upstream](https://github.com/mackron/miniaudio) and [license](https://github.com/mackron/miniaudio/blob/master/LICENSE): optional Linux device adapter candidate, offered under public-domain or MIT-0 terms; pin and audit the exact revision before integration.
