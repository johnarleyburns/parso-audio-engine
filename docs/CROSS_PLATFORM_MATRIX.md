# Cross-platform support matrix

This is the CP0 contract and inventory. “Planned” means the implementation and its tests do not exist yet; it is not a product capability claim. A row may move to “supported” only when the linked unit, integration, packaging, and acceptance gates pass.

| Surface | Swift / Apple | C/C++ / Linux | Kotlin / Android | CP0 evidence | First implementation phase |
|---|---|---|---|---|---|
| Real-time DSP and render graph | Supported through `CParsoDSP` / `CParsoEngine` | Planned; shared native sources via CMake | Planned; same native library via NDK/JNI | Existing C-clean headers reviewed | CP1 portable build |
| Headless `pe_step` rendering | Existing test path | Planned public facade and CTest | Planned JNI smoke path | `pe_step` is the common deterministic seam | CP2 C API |
| DJ controls and state | Swift `ParsoDJEngine` | Planned shared native control module | Planned Kotlin facade | Current control behavior identified as migration scope | CP3 shared services |
| Analysis | Swift + Accelerate | Planned portable FFT/vector backend | Planned through native analysis API | Algorithms and result types specified in `SPEC.md` | CP3 analysis |
| FLAC / Vorbis / Opus | Supported through vendored C | Planned after CMake build and fixture gates | Planned after NDK fixture gates | Vendor licenses and targets inventoried | CP1/CP3 |
| WAV / PCM | Supported | Planned | Planned | PCM is the first cross-binding contract | CP2 |
| MP3 / AAC / ALAC / AIFF / CAF | Apple-supported paths plus Glint MP3 encode | Capability-specific; no unsupported format is implied | Capability-specific; Android codec adapter requires device tests | Platform codec gaps called out in plan | CP3 |
| Recording | Swift `MixRecorder` | Planned native off-thread recorder | Planned native service with Kotlin lifecycle API | Existing record ring is the native seam | CP3 |
| Device playback / capture | Apple audio frameworks | Planned host callback, then optional device backend | Planned Oboe adapter | Device APIs deliberately isolated from engine | CP4/CP5 |
| Human listening acceptance | Existing Swift artifact tools | Required Linux native artifact CLI and sign-off | Device review pending hardware | Existing WAV + JSON + MP4 contract reused | CP6 |
| Packaging | SwiftPM / Xcode | Planned CMake, pkg-config, SONAME | Planned AAR / Maven | Package-consumer tests required | CP2/CP4/CP5 |

## Required test layers

Every supported row needs all applicable layers below. A forwarding test alone is insufficient.

| Layer | Purpose | Examples |
|---|---|---|
| Unit | Algorithm and state behavior | DSP kernels, transport, queue overflow, analysis, codec metadata |
| Native integration | Shared pipeline behavior | decode → analyze → load → command → render → record |
| Binding integration | ABI and ownership behavior | C/C++ consumer, JNI handles, cancellation, close order |
| Packaging | External-consumer usability | CMake install, pkg-config, AAR/Maven, SwiftPM |
| Device | Callback and route behavior | Linux device restart/capture; Android Oboe route changes |
| Human acceptance | Audible behavior | Linux scenario WAV/JSON/MP4, reviewer manifest, A/B against Apple artifacts |

The matrix is updated with the commit, test command, artifact path, and reviewer/date when a row changes state.
