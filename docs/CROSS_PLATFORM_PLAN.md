# Android and Linux expansion plan

Status: proposed; implementation has not started. Baseline inspected: `9de9035`.

## Objective and scope

Keep the existing Swift products and add a Kotlin/Android SDK and a Linux C/C++ SDK over one shared native engine. First deliver PCM-driven DSP/rendering, then complete file IO, DJ control, analysis, and recording parity. Playback, streaming, and neural products require their own acceptance inventory; they must not be implicitly advertised as portable when only the DJ engine is ready.

Proposed initial targets: Android API 26+, arm64-v8a devices and x86_64 emulators; Linux x86_64 and aarch64 with a documented glibc baseline. Preserve the Apple deployment targets in `Package.swift`. These are planning defaults, to be confirmed by the first toolchain/device spike. No Swift runtime should be needed on Android or Linux.

## Findings from this repository

- `CParsoDSP/include/parso_dsp.h` and `CParsoEngine/include/parso_engine.h` already expose C interfaces. Reuse their implementations; do not build a second render graph.
- `Package.swift` unconditionally enables `SIGNALSMITH_USE_ACCELERATE` and links Accelerate. Native portability needs a build change and numerical validation.
- `ParsoDJEngine.swift` owns substantial orchestration, including pads, Smart Fader, loading, and recording. Wrapping `pe_*` alone does not reproduce this API's behavior.
- Analysis uses Swift and Accelerate. File IO and device integration use Apple frameworks. Those services need portable implementations or platform adapters.
- The public surface now includes playback, streaming, neural features, multiple decks, and stems. The older three-product/two-deck description is not a complete inventory.
- `SPEC.md` §0 explicitly targets Apple only; `UNIFICATION_PLAN.md` §4b deliberately retired Linux. Revise these deliberately before implementation, preserving the historical rationale.
- The existing C interface exposes concrete control/command structs and caller-owned buffers. Treat it as an internal bridge until versioning, lifetime, and threading contracts are audited.
- No phase ledger was present. Swift is unavailable in this Linux workspace; the README's green-suite claim was not independently verified.

## Intended architecture

```text
Swift SDK                 Kotlin Android SDK              Linux C++ convenience API
    |                            | JNI                              |
    +---------------- versioned public C API -----------------------+
                                    |
                 shared native services and DJ control
                 IO / analysis / recording / commands
                                    |
                      CParsoEngine -> CParsoDSP

Device adapters: Apple existing backend | Android Oboe | Linux host callback/backend
Builds:          SwiftPM               | Gradle + CMake | CMake
```

Native Core and Analysis remain independent of DJ concepts. Shared DJ orchestration belongs in an engine/control module. Move behavior incrementally from Swift into native services and have Swift delegate to them, retaining its public API and strict concurrency. CMake and SwiftPM compile the same sources, with platform-specific settings.

## Delivery phases and acceptance gates

Every phase includes README/docs, runnable examples, unit tests, and integration tests for its new public behavior. These are completion requirements, not documentation cleanup deferred until release. Update the capability matrix and ledger with the actual evidence at each gate.

### CP0 — Establish the contract and baseline

1. Run `swift build` and the full fixture-enabled `swift test` on an Apple runner; record actual results and disabled suites.
2. Inventory every public API and FLX4 acceptance row into a matrix: Apple implementation, native coverage, Android/Linux target, corresponding test, milestone.
3. Separate DJ parity from playback/streaming/neural follow-ups, including newer multi-deck/stem features already exposed by the engine.
4. Amend SPEC targets, layering, backend policy, and acceptance requirements; reconcile README requirements with Package.swift. Add this CP workstream to the handoff instructions without conflating it with the original phases.
5. Pin compiler, CMake, NDK, Gradle, SDK, and dependency versions after validating compatibility. Audit dependency configuration and licensing under the repository allowlist.

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

### CP3 — Shared offline services and DJ behavior

1. Expose native buffers, SRC, loudness, FLAC/Vorbis/Opus bridges, and WAV IO. Audit CGlint's current decode/encode paths with real fixtures before advertising portable MP3 support.
2. Publish per-platform decode/encode/container capabilities. Android AAC can use a platform codec adapter after validation; Linux AAC/ALAC/AIFF/CAF require separately validated implementations or providers. Return explicit unsupported-format errors until implemented. Container support is a separate gate from codec support.
3. Extract DJ control in small slices: transport/cue/jog; loop/hot-cue/quantize/sync/slip; pads/sampler; mixer/monitoring/mic; Smart Fader/CFX. Keep all language wrappers on this shared behavior.
4. Port analysis in order: FFT/STFT, onsets, tempo/beatgrid, key, structure, waveform, full analysis. Preserve SPEC algorithms, normalization, frame conventions, and deterministic behavior. Evaluate the existing portable FFT facilities before adding a dependency.
5. Move recording orchestration into an off-thread native service consuming the existing record ring. Start with WAV/FLAC, expose dropped-frame accounting, then add supported platform codecs. No MP3 mix recording.

Gate: shared scenario vectors and real fixtures pass through native and Swift APIs. Cross-backend tolerances are justified per measurement. Missing formats remain explicit capability gaps and block any claim of full codec parity.

### CP4 — Kotlin/Android SDK and device output

1. Build an AAR with the native library and a small JNI bridge. Suggested API modules: core, analysis, and DJ; initially one AAR can carry them to avoid duplicated native runtimes.
2. Mirror concepts idiomatically: `AudioBuffer`, `TrackAnalysis`, `DJEngine`, `Deck`, `Mixer`, `MixRecorder`. Use explicit closeable ownership, suspend functions for IO/analysis, and immutable telemetry through Flow/StateFlow.
3. Serialize control calls on a dedicated dispatcher/executor. Cancellation must coordinate native job completion before releasing memory. JNI validates handles, buffer bounds, and status codes.
4. Keep JNI, JVM callbacks, object allocation, and GC-managed memory out of the audio callback. Copy/import PCM off-thread into native-owned storage; use direct buffers only with explicit lifetime contracts. Drain events on a control worker.
5. Add Oboe output/capture with preallocated planar/interleaved conversion and bounded callback-size handling. Negotiate actual sample rate, channel count, and burst size. Reconfigure safely on disconnect or route change.
6. Handle audio focus, interruptions, foreground/background lifecycle, microphone permission, URI/file-descriptor input, and unavailable cue/booth outputs. Background service policy belongs in the app integration/sample.
7. Supply a small sample: load two files, mix, EQ, cue/loop, analyze, record, display meters. Publish local Maven artifacts first; remote publication is a separate release action.

Gate: JVM API/lifetime tests, JNI instrumentation, AAR consumer build, 16 KB page-size validation, and real-device playback/capture/route-change/underrun tests. Emulator tests do not establish latency performance.

### CP5 — Linux playback and native SDK packaging

1. Make host-supplied audio callbacks the dependency-free baseline: applications can connect their own device system to the shared render path.
2. Evaluate an optional miniaudio device adapter, restricted to device IO, against the dependency policy. Review transitive/runtime audio dependencies separately; do not silently introduce a prohibited dependency through a backend.
3. Cover device enumeration, negotiated rate/layout, bounded conversion buffers, hot unplug, capture, master/cue/booth routing, and graceful shutdown. Report missing hardware routing as unavailable.
4. Provide headless render-to-WAV and live C/C++ mixer examples. Package versioned libraries, SONAME, headers, symbols, notices, and reproducible source-build instructions; establish the glibc floor in CI containers.

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

Gate: the maintainer can run and listen on Linux without Android or Swift; automated artifact checks pass and required scenarios have recorded human sign-off. Audible defects become regressions with reproducible timelines. Update fixture BPM/key ground truth only after actual verification, as required by AGENTS.md.

### CP7 — Cross-platform release gate

- CI: existing Apple Swift tests; Linux GCC/Clang native tests and sanitizers; Android NDK builds, Kotlin tests, emulator instrumentation, and a scheduled hardware run.
- Run matching serialized command scenarios through Swift, C, C++, and Kotlin, covering every matrix row. Use numeric audio tolerances and exact discrete-state assertions.
- Instrument allocation and prohibited operations around engine DSP calls, including transitions and queue pressure. Keep measurement outside RT kernels where it requires system calls. Verify zero allocations after preparation.
- Measure render time against actual callback deadlines, dropouts, memory, recording overflow, long-track precision, and long-session stability on named devices. Record measured budgets; do not promise universal latency.
- Verify dependency notices, source pins, SPDX policy, binary architecture/page alignment, exported symbols, and archive contents. Test consuming the packaged artifacts outside the monorepo.
- Publish SDK/API documentation and an honest platform capability table. Release candidates require Apple regression gates and all advertised portable features to pass; tag/publish only as a deliberate release step.

Android hardware validation may be performed later by a contributor or device lab. Until then, label Android device performance/routing unverified and the SDK preview as appropriate; do not block the Linux SDK release on unavailable Android hardware or claim that emulator/Linux results substitute for it.

## Documentation, examples, and test deliverables

| Area | Required updates and evidence |
|---|---|
| README | Explain the shared native architecture; SwiftPM, Gradle/Maven, and CMake installation; platform requirements; feature/codec gaps; runnable quickstarts; Linux listening command; links to full guides. Remove stale Apple-only and three-product claims as support lands. |
| Architecture/spec | Update `docs/SPEC.md`, `docs/architecture.md`, and the historical retirement note in `docs/UNIFICATION_PLAN.md`; document ownership, threading, C ABI compatibility, backend selection, and native module boundaries. |
| Feature acceptance | Extend `docs/FLX4-feature-inventory.md` with platform support, unit/integration test mapping, and Linux listening scenarios; separately inventory newer non-FLX4 APIs. |
| Platform/API guides | Add Android and Linux build/integration guides, C/C++ ownership/error examples, Kotlin coroutine/lifecycle guidance, codec capability tables, packaging instructions, and troubleshooting. Update NOTICE/VENDOR records for actual dependency changes. |
| Human review guide | Extend `docs/human-visible-acceptance.md` with native Linux commands, prerequisites, scenario coverage, A/B procedure, review manifest, live listening instructions, and honest pending hardware status. |
| Examples | Maintain Swift examples against migrated APIs; add standalone C headless renderer, C++ live mixer/recorder, Kotlin Android mixer app, and native Linux acceptance CLI. Build examples and smoke-test documented commands in CI where feasible. |
| Unit tests | Native DSP/control/analysis/codec correctness and boundary cases; C++ ownership/error behavior; Kotlin API state and cancellation; preserve Swift regressions. Test behavior, not merely forwarding calls. |
| Integration tests | End-to-end decode -> analyze -> load -> command -> render -> record -> decode; identical scenario replay across bindings; JNI lifetime/queue pressure; device restart/route changes; installed CMake/Maven/SwiftPM consumer builds. |
| Acceptance tests | Linux WAV/JSON/MP4 schema and duration checks, human listening manifest, real-fixture plausibility, Apple/native comparison, long-session/RT safety, and separately tracked real-device Android checks. |

Each implementation PR must include the relevant rows above or explicitly identify why a row does not apply. No phase is complete with examples that do not build, undocumented public APIs, or pending tests for advertised behavior.

## Recommended execution order

CP0 -> CP1 -> CP2 -> CP3 -> CP5 -> CP6 -> CP4 -> CP7. Prioritize Linux device support and human listening before Android integration because that is the maintainer's available review platform. Begin the native artifact CLI in CP2 and add scenarios with each feature; CP6 is its full acceptance gate. A thin PCM-only Android smoke app can validate JNI/Oboe earlier, but must not be presented as the complete SDK. First useful shipping increment: C/C++ headless SDK and Linux listening artifacts; next: shared DJ/file/analysis/recording parity and Kotlin integration.

Use focused conventional commits and update the untracked phase ledger after every commit. A planning-only change does not establish any build/test gate. The first implementation slice should be CMake + portable Signalsmith + a native headless smoke test, after the Apple baseline/spec update.

## External implementation references

- [Android Oboe overview](https://developer.android.com/games/sdk/oboe): native audio adapter candidate.
- [Android low-latency audio guidance](https://developer.android.com/games/sdk/oboe/low-latency-audio): stream configuration and callback constraints.
- [Oboe JNI/latency FAQ](https://github.com/google/oboe/blob/main/docs/FAQ.md): boundary and sample-rate considerations.
- [miniaudio upstream](https://github.com/mackron/miniaudio) and [license](https://github.com/mackron/miniaudio/blob/master/LICENSE): optional Linux device adapter candidate, offered under public-domain or MIT-0 terms; pin and audit the exact revision before integration.
