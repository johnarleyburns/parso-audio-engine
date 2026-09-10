# Cross-platform support matrix

This is the CP0 contract and inventory. “Planned” means the implementation and its tests do not exist yet. “Supported” means an implementation and evidence exist for that platform; release advertising still depends on the linked unit, integration, packaging, acceptance, device, and human-review gates.

| Surface | Swift / Apple | C/C++ / Linux | Windows C/C++ | Windows C# | Kotlin / Android | CP0 evidence | First implementation phase |
|---|---|---|---|---|---|---|---|
| Real-time DSP and render graph | Supported through `CParsoDSP` / `CParsoEngine` | Supported through CMake/CTest plus dependency-free host callback; device backend pending | MSVC/native runtime pending; Linux cross-build only | Managed wrapper built; native runtime pending | Same native library builds through NDK/JNI; device pending | CMake 17-test suite, sanitizer subset, host callback, and ABI export checks | CP1 / CP-WIN |
| Headless `pe_step` rendering | Existing test path | Supported public facade and CTest | Native CTest/runtime pending | Managed render, retained deck PCM, play/pause, record, and crossfader surface built; native run pending | JNI direct-buffer create/destroy/set-buffer/play/pause/render builds for arm64-v8a/x86_64; device pending | `pe_step` is the common deterministic seam | CP2 / CP4 / CP-WIN |
| DJ controls and state | Swift `ParsoDJEngine` | Partial shared command ABI: transport, cues, loops, hot cues, slip/keylock, crossfader; full parity pending | Shared native runtime pending | Matching managed command/control surface built; native run pending | Kotlin currently exposes play/pause and PCM/render lifecycle; broader DJ API pending | C11/C++17/Python/C# command and event consumers pass for implemented selectors | CP3 / CP-WIN |
| Analysis | Swift + Accelerate | Native summary analysis (duration/levels/tempo) supported; key/structure planned | Shared C ABI summary path; native Windows execution pending | C# summary/waveform call surface built; native Windows execution pending | Native analysis API not yet wrapped | Synthetic 120 BPM summary, waveform, real Ogg/FLAC summary, and sidecar gates pass | CP3 / CP-WIN |
| FLAC / Vorbis / Opus | Supported through vendored C | Xiph Vorbis plus native FLAC/Opus bridges are fixture-gated and pass | Cross-build/capability evidence; native MSVC runtime pending | Managed capability and byte-codec wrapper built; native Windows run pending | NDK library builds; Android codec/runtime fixture gate pending | Permissive vendor records, real fixture consumers, and ABI capability checks | CP1/CP3 / CP-WIN |
| WAV / PCM | Supported | Supported through `parso_wav_*` / `parso_pcm_*` and installed consumers | Native C/C++ runtime pending | C# buffer/marshaling surface built; native consumer pending | Direct-buffer JNI input/output seam builds; AAR/device pending | C11/C++17 CTest and installed package consumer pass | CP3 / CP-WIN |
| SRC / loudness | Supported through `Csrc` / `Cebur128` | Supported through `parso_src_convert` / `parso_loudness_measure` | Native runtime pending | Managed wrappers not yet advertised | Not yet wrapped | C11/C++17/Python service consumers and real fixture measurements pass | CP3 / CP-WIN |
| MP3 / AAC / ALAC / AIFF / CAF | Apple-supported paths plus Glint MP3 encode | Capability-specific; no unsupported format is implied | Capability-specific; Windows codecs require explicit adapter validation | Capability-specific managed errors | Capability-specific; Android codec adapter requires device tests | Platform codec gaps called out in plan | CP3 / CP-WIN |
| Recording | Swift `MixRecorder` | Public bounded record tap, native acceptance drain, and C++/Python control surfaces; full file service partial | Native runtime pending | Managed record-tap methods built; native consumer pending | JNI/Kotlin recording API pending | Record-ring overflow/long-session and 30-second artifact gates pass | CP3 / CP-WIN |
| Device playback / capture | Apple audio frameworks | Host callback baseline supported; optional ALSA/PipeWire/JACK backend pending | WASAPI adapter/routes pending | Device facade pending | Oboe adapter/routes pending | Device APIs deliberately isolated from engine | CP4/CP5 / CP-WIN |
| Human listening acceptance | Existing Swift artifact tools | Native/Python 30-second WAV/JSON artifacts, index, runner, and parity report built; human sign-off pending | Native Windows render/consumer checks pending; listening hardware separate | C# artifacts not runtime-verified | Device review pending hardware | Existing WAV + JSON + MP4 contract reused | CP6 / CP-WIN |
| Packaging | SwiftPM / Xcode | CMake package, pkg-config metadata, shared/static consumers, and ABI reports pass | CMake/DLL/import package pending native Windows validation | NuGet package/runtime pending | Release AAR builds; Maven publication/device validation pending | External Linux C11 consumer, Android AAR contents, and relocatable metadata pass | CP2/CP4/CP5 / CP-WIN |

## Required test layers

### Python 3 / Linux (additional binding; implemented preview with release gates pending)

Python shares the public C ABI and native implementations listed above. Its release evidence is independent of the C/C++ consumer results. CP-PY follows the native services work and CP6 includes Python-specific listening acceptance.

| Python surface | Implementation status | Required evidence |
|---|---|---|
| Buffers / DSP / headless render | Implemented through stdlib `ctypes`, retained deck storage, and bounded native render | 16 binding tests, host runner, and native/Python crossfader parity report pass |
| File IO / SRC / loudness / analysis | Implemented native codec/SRC/loudness/summary/waveform services | Real Ogg/FLAC integration, capability errors, and acceptance sidecars pass |
| DJ controls / mixing / recording | Implemented transport/cue/loop/hot-cue/slip/keylock/crossfader and record tap surfaces | 16 binding tests plus 30-second crossfader/recording example pass; full DJ parity pending |
| Ownership / concurrency | Context managers, explicit close, retained buffers, serialized control, off-thread event polling | Repeated close, invalid input/handle, event and record-ring tests pass; cancellation/concurrency stress pending |
| Linux playback / capture | Python controls the native Linux backend | Python-driven playback/capture example and device tests; callback runs entirely in native code |
| Packaging / docs | Pure-Python wheel/source build and documented native-library discovery | Wheel build and ABI/load checks pass; fresh-venv installation remains CI-only pending local pip/venv tooling |
| Human listening | Audio generated through the Python API with matching native artifacts | 30-second crossfader scenarios, index, native/Python A/B, and pending review manifest pass; human sign-off pending |

The Python minimum version, FFI choice, and wheel compatibility floor are decisions for the packaging spike. Other Python platforms/interpreters remain unadvertised until tested. CP-PY and CP6 in `CROSS_PLATFORM_PLAN.md` define the implementation and listening gates.

### Shared test layers

Every supported row needs all applicable layers below. A forwarding test alone is insufficient.

| Layer | Purpose | Examples |
|---|---|---|
| Unit | Algorithm and state behavior | DSP kernels, transport, queue overflow, analysis, codec metadata |
| Native integration | Shared pipeline behavior | decode → analyze → load → command → render → record |
| Binding integration | ABI and ownership behavior | C/C++ consumer, JNI/Python handles, cancellation, close order, native/Python scenario parity |
| Packaging | External-consumer usability | CMake install, pkg-config, AAR/Maven, SwiftPM, Python wheels/source distributions in fresh virtual environments |
| Device | Callback and route behavior | Linux device restart/capture; Android Oboe route changes |
| Human acceptance | Audible behavior | C/C++ and Python Linux scenario WAV/JSON/MP4, separate binding review results, A/B against Apple artifacts |

The matrix is updated with the commit, test command, artifact path, and reviewer/date when a row changes state.

### CP3 native offline slice

The portable C ABI advertises the native build's fixture-gated WAV, FLAC, Ogg Vorbis, Opus, MP3,
and AAC byte services, plus raw little-endian integer PCM read/write at 8/16/24/32 bits. It also
advertises one-shot libsamplerate SRC and libebur128 EBU R128 loudness services. Reads and SRC
results return owned interleaved float32 buffers; writes return owned byte buffers. Owned buffers are
released through idempotent ABI functions. ALAC, AIFF, and CAF remain unset until platform or
portable implementations and their fixture gates pass.
