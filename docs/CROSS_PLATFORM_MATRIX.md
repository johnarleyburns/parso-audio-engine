# Cross-platform support matrix

This is the CP0 contract and inventory. “Planned” means the implementation and its tests do not exist yet; it is not a product capability claim. A row may move to “supported” only when the linked unit, integration, packaging, and acceptance gates pass.

| Surface | Swift / Apple | C/C++ / Linux | Windows C/C++ | Windows C# | Kotlin / Android | CP0 evidence | First implementation phase |
|---|---|---|---|---|---|---|---|
| Real-time DSP and render graph | Supported through `CParsoDSP` / `CParsoEngine` | Planned; shared native sources via CMake | Planned native MSVC build of shared C ABI/C++17 wrapper | Planned managed wrapper over C ABI | Planned; same native library via NDK/JNI | Existing C-clean headers reviewed; native Windows CI exists | CP1 / CP-WIN |
| Headless `pe_step` rendering | Existing test path | Public facade and CTest in progress | Native CTest on `windows-latest` | Planned C# consumer smoke test | Planned JNI smoke path | `pe_step` is the common deterministic seam | CP2 / CP-WIN |
| DJ controls and state | Swift `ParsoDJEngine` | Planned shared native control module | Planned shared native control module | Planned C# API over shared control module | Planned Kotlin facade | Current control behavior identified as migration scope | CP3 / CP-WIN |
| Analysis | Swift + Accelerate | Planned portable FFT/vector backend | Planned shared native backend | Planned managed result types and error mapping | Planned through native analysis API | Algorithms and result types specified in `SPEC.md` | CP3 / CP-WIN |
| FLAC / Vorbis / Opus | Supported through vendored C | Planned after CMake build and fixture gates | Planned native MSVC and cross-build capability checks | Planned managed capability queries | Planned after NDK fixture gates | Vendor licenses and targets inventoried | CP1/CP3 / CP-WIN |
| WAV / PCM | Supported | Supported through `parso_wav_*` / `parso_pcm_*` | Native C/C++ offline consumers pass with the shared ABI | C# buffer/marshaling consumer planned | Planned | CP3 native capability + ownership slice is covered by independent C11/C++17 CTest consumers; packaging remains pending | CP3 / CP-WIN |
| SRC / loudness | Supported through `Csrc` / `Cebur128` | Supported through `parso_src_convert` / `parso_loudness_measure` | Independent C11/C++17 service consumers pass with CMake/CTest | Planned managed result/options wrappers | Planned | CP3 native service contract is covered; platform packaging remains pending | CP3 / CP-WIN |
| MP3 / AAC / ALAC / AIFF / CAF | Apple-supported paths plus Glint MP3 encode | Capability-specific; no unsupported format is implied | Capability-specific; Windows codecs require explicit adapter validation | Capability-specific managed errors | Capability-specific; Android codec adapter requires device tests | Platform codec gaps called out in plan | CP3 / CP-WIN |
| Recording | Swift `MixRecorder` | Planned native off-thread recorder | Planned native recorder and Windows consumer tests | Planned C# recording API | Planned native service with Kotlin lifecycle API | Existing record ring is the native seam | CP3 / CP-WIN |
| Device playback / capture | Apple audio frameworks | Planned host callback, then optional device backend | Planned WASAPI adapter and native route tests | Planned C# device facade | Planned Oboe adapter | Device APIs deliberately isolated from engine | CP4/CP5 / CP-WIN |
| Human listening acceptance | Existing Swift artifact tools | Required Linux native artifact CLI and sign-off | Native Windows render/consumer checks; listening hardware separately tracked | C#-generated artifacts reviewed separately | Device review pending hardware | Existing WAV + JSON + MP4 contract reused | CP6 / CP-WIN |
| Packaging | SwiftPM / Xcode | Planned CMake, pkg-config, SONAME | Planned CMake package, DLL/import library, and external consumer | Planned NuGet package over native runtime | Planned AAR / Maven | Package-consumer tests required | CP2/CP4/CP5 / CP-WIN |

## Required test layers

### Python 3 / Linux (additional binding; all surfaces planned)

Python shares the public C ABI and native implementations listed above. Its release evidence is independent of the C/C++ consumer results. CP-PY follows the native services work and CP6 includes Python-specific listening acceptance.

| Python surface | Planned implementation | Required evidence |
|---|---|---|
| Buffers / DSP / headless render | Python buffer protocol, optional NumPy helpers, shared native DSP | Unit tests for dtype/layout/strides/bounds; native/Python render parity; PCM example |
| File IO / SRC / loudness / analysis | Python objects and exceptions over native services | Real-fixture integration tests; file-analysis example; capability errors for unavailable codecs |
| DJ controls / mixing / recording | Shared native control and recording APIs | End-to-end decode/analyze/mix/record/decode test; mixer and recording examples |
| Ownership / concurrency | Context managers, explicit close, serialized control, off-thread event polling | Lifetime, repeated close, cancellation, invalid-handle and concurrent-use tests; no Python on RT thread |
| Linux playback / capture | Python controls the native Linux backend | Python-driven playback/capture example and device tests; callback runs entirely in native code |
| Packaging / docs | Linux CPython wheels and source distribution | Fresh-venv installation outside checkout, declared interpreter/architecture matrix, ABI/load checks, README quickstart and full Python guide |
| Human listening | Audio generated through the installed Python API; matching WAV/JSON/MP4 | At least 30-second scenarios, full-track phrase review, Python/native A/B, Python-specific reviewer/date/result manifest |

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

The portable C ABI currently advertises only the formats implemented by the native build: WAV
container read/write and raw little-endian integer PCM read/write at 8/16/24/32 bits. It also
advertises one-shot libsamplerate SRC and libebur128 EBU R128 loudness services. Reads and SRC
results return owned interleaved float32 buffers; writes return owned byte buffers. Owned buffers are
released through idempotent ABI functions. FLAC, Ogg Vorbis, Opus, MP3, AAC, ALAC, AIFF, and CAF
remain unset in the capability masks until native implementations and their fixture gates pass.
