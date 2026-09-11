# Cross-platform support matrix

This is the CP0 contract and inventory. “Planned” means the implementation and its tests do not exist yet. “Supported” means an implementation and evidence exist for that platform; release advertising still depends on the linked unit, integration, packaging, acceptance, device, and human-review gates.

| Surface | Swift / Apple | C/C++ / Linux | Windows C/C++ | Windows C# | Kotlin / Android | CP0 evidence | First implementation phase |
|---|---|---|---|---|---|---|---|
| Real-time DSP and render graph | Supported through `CParsoDSP` / `CParsoEngine` | Supported through CMake/CTest plus dependency-free host callback; device backend pending | MSVC/native runtime pending; Linux cross-build only | Managed wrapper built; native runtime pending | Same native library builds through NDK/JNI; device pending | CMake 18-test suite, allocator-instrumented variable callback test, sanitizer subset, host callback, and ABI export checks | CP1 / CP-WIN |
| Headless `pe_step` rendering | Existing test path | Supported public facade and CTest | Native CTest/runtime pending | Managed render, retained deck PCM, play/pause, record, crossfader, and synchronized lifetime surface built; native Windows run pending | JNI direct-buffer render, mixer commands, copied stats/events, and record tap pass on arm64-v8a/x86_64 and the API 36 x86_64 emulator; physical device pending | `pe_step` is the common deterministic seam | CP2 / CP4 / CP-WIN |
| DJ controls and state | Swift `ParsoDJEngine` | Partial shared command ABI: transport, cues, loops, hot cues, slip/keylock, crossfader; full parity pending | Shared native runtime pending | Matching managed command/control surface built; native run pending | Kotlin exposes mixer control plus typed cue/hot-cue/loop/seek/sync/key-lock/slip commands; JNI lifecycle/render/control pass on the API 36 x86_64 emulator; broader DJ API and physical runtime pending | C11/C++17/Python/C#/Kotlin command consumers cover implemented selectors; Android producer instrumentation 3/3 and external consumer instrumentation 1/1 | CP3 / CP-WIN |
| Analysis | Swift + Accelerate | Native summary, key, and deterministic structure service; full phrase parity planned | Shared C ABI summary/key/structure path; native Windows execution pending | C# summary/waveform/key/structure call surface built; native Windows execution pending | `ParsoAnalysis` wraps summary/key/structure over direct buffers; device runtime pending | Synthetic 120 BPM summary, waveform, rooted A-minor key, structure transitions, real Ogg/FLAC summary, and sidecar gates pass | CP3 / CP4 / CP-WIN |
| FLAC / Vorbis / Opus | Supported through vendored C | Xiph Vorbis plus native FLAC/Opus bridges are fixture-gated and pass | Cross-build/capability evidence; native MSVC runtime pending | Managed capability and byte-codec wrapper built; native Windows run pending | `ParsoVorbis` encode/decode passes through the AAR on the API 36 x86_64 emulator; physical codec/runtime fixture gate pending | Permissive vendor records, real fixture consumers, ABI capability checks, and Android instrumentation | CP1/CP3 / CP4 / CP-WIN |
| WAV / PCM | Supported | Supported through `parso_wav_*` / `parso_pcm_*` and installed consumers | Native C/C++ runtime pending | C# buffer/marshaling surface built; native consumer pending | Direct-buffer JNI input/output seam and published AAR pass on the API 36 x86_64 emulator; physical device pending | C11/C++17 CTest, installed package consumer, AAR, and external consumer instrumentation pass | CP3 / CP-WIN |
| SRC / loudness | Supported through `Csrc` / `Cebur128` | Supported through `parso_src_convert` / `parso_loudness_measure` | Native runtime pending | `CodecServices` wraps copied SRC and EBU R128 results; native DLL execution pending | `ParsoOffline` wraps copied SRC and EBU R128 results; producer instrumentation passes on the API 36 x86_64 emulator; physical device pending | C11/C++17/Python/C# service consumers, installed package consumers, real fixture measurements, and Android instrumentation pass | CP3 / CP4 / CP-WIN |
| MP3 / AAC / ALAC / AIFF / CAF | Apple-supported paths plus Glint MP3 encode | Capability-specific; no unsupported format is implied | Capability-specific; Windows codecs require explicit adapter validation | Capability-specific managed errors | Capability-specific; Android codec adapter requires device tests | Platform codec gaps called out in plan | CP3 / CP-WIN |
| Recording | Swift `MixRecorder` | C ABI record tap plus C++17 `MixRecorder` and Python control-side WAV/FLAC/AAC encoders | Public bounded record tap and native acceptance drain; full file service partial | `MixRecorder` encodes drained stereo blocks to WAV/FLAC/AAC; native DLL execution pending | `ParsoEngine` activation/drain/drop/reset and `ParsoRecorder` WAV encoding pass through the AAR on the API 36 x86_64 emulator; device runtime pending | Record-ring overflow/long-session, C++/C#/Python round trips, and Android producer/consumer instrumentation pass | CP3 / CP4 / CP-WIN |
| Device playback / capture | Apple audio frameworks | Host callback plus PipeWire `pw-cat` adapter supported; bounded process restart and named-route recording recovery covered; physical hot-unplug/latency acceptance pending | WASAPI adapter/routes pending | Device facade pending | Oboe adapter/routes pending | `parso_linux_pipewire_host` live playback/capture, no-device contract, deterministic recovery CTest, and 30-second named-route restart runner | CP4/CP5 / CP-WIN |
| Human listening acceptance | Existing Swift artifact tools | Native/Python 30-second real-MP3-deck WAV/JSON artifacts, index, runner, parity report, and 30-second named-route recording bundle built; human sign-off pending | Native Windows render/consumer checks pending; listening hardware separate | C# artifacts not runtime-verified | Device review pending hardware | Existing WAV + JSON + MP4 contract reused | CP6 / CP-WIN |
| Packaging | SwiftPM / Xcode | CMake package, pkg-config metadata, installed C11/C++17 consumers, and ABI reports pass | CMake/DLL/import package pending native Windows validation | NuGet package/runtime pending | Release AAR, local Maven publication, external consumer APK, and emulator scenarios pass locally with pinned NDK/CMake; physical device gate pending | External Linux C11/C++17 consumers, Android AAR/APK contents, JNI exports, 16 KiB ELF alignment, and producer/consumer instrumentation pass | CP2/CP4/CP5 / CP-WIN |

## Required test layers

### Python 3 / Linux (additional binding; implemented preview with release gates pending)

Python shares the public C ABI and native implementations listed above. Its release evidence is independent of the C/C++ consumer results. CP-PY follows the native services work and CP6 includes Python-specific listening acceptance.

| Python surface | Implementation status | Required evidence |
|---|---|---|
| Buffers / DSP / headless render | Implemented through stdlib `ctypes`, retained deck storage, and bounded native render | 19 binding tests, host runner, and native/Python crossfader parity report pass |
| File IO / SRC / loudness / analysis | Implemented native codec/SRC/loudness/summary/waveform services | Real Ogg/FLAC integration, capability errors, and acceptance sidecars pass |
| DJ controls / mixing / recording | Implemented transport/cue/loop/hot-cue/slip/keylock/crossfader, channel/master EQ, Beat FX, reverb, tempo ratio, and record tap surfaces | 21 binding tests plus seven real-MP3 scenario renders pass; full DJ parity pending |
| Ownership / concurrency | Context managers, explicit close, retained buffers, serialized control/render/close calls, off-thread event polling | Repeated close, invalid input/handle, event, record-ring, and threaded close/render tests pass; cancellation stress pending |
| Linux playback / capture | Python controls the native Linux backend | Python-driven playback/capture example and device tests; callback runs entirely in native code |
| Packaging / docs | Pure-Python wheel/source build and documented native-library discovery | Wheel build and ABI/load checks pass; fresh-venv installation remains CI-only pending local pip/venv tooling |
| Human listening | Three real MP3 fixtures rendered through the native engine behind the Python API | Seven separate 30-second scenario WAVs, index, native/Python A/B, and pending review manifest pass; human sign-off pending for the expanded set |

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
