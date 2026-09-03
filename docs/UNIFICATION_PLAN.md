# Unified Audio Engine Plan — Tonearm · Voxglass · parso-audio-engine

**Goal:** make `parso-audio-engine` (PAE) the single audio substrate for both apps,
extracting only what is genuinely shared and deliberately leaving app-identity code
in the apps.

## 0. Where things stand

| | Tonearm | Voxglass | PAE |
|---|---|---|---|
| License | GPLv3 | Proprietary | **MIT** |
| Package | `TonearmCore`, `TonearmDJ` | `VoxglassCore`, `VoxglassEncoders` | `ParsoAudioCore/Analysis/DJEngine` |
| Platforms | iOS 18, macOS 15, watchOS 11 | iOS 17, macOS 14, watchOS 10 | iOS 15, macCatalyst 15, macOS 13 — **no watchOS** |
| Codec C libs | none (AVFoundation + hand-rolled Ogg/Opus remux) | Lame + FLAC **binary xcframeworks** | vendored source: Cflac, Copus, Cvorbis, Cebur128, Csrc, CGlint |

MIT flows into GPLv3 and into proprietary without friction, so the license direction is
correct and one-way: **nothing GPL'd or proprietary may move into PAE.** Tonearm code
lifted into PAE must be relicensed by you as the sole copyright holder — record that
explicitly in `ATTRIBUTION.md` per file moved.

## 1. Confirmed duplication (the extraction targets)

Verified by inspection, strongest first:

1. **`ByteRangeMap.swift` — byte-identical** in `parso-tonearm/Sources/Audio/` and
   `parso-voxglass/Voxglass/Core/Services/Playback/` (`diff` is empty).
2. **Sparse HTTP cache + `AVAssetResourceLoader` streaming.** Tonearm
   `CachingResourceLoader` (364) + `CacheStore` (345); Voxglass `CachingResourceLoader`
   (256) + `StreamCacheStore` (593) + `StreamCacheUtils` + `CacheManager`. Same design,
   two implementations.
3. **10-band ISO graphic EQ.** Tonearm `EQEngine`/`Biquad`/`EQAudioTap`/`EQSettings`/
   `EQPreset`; Voxglass `EQAudioProcessor`/`BiquadFilter`/`EQPresetStore`/`EQSettingsStore`.
   Both are RBJ peaking cascades driven through an `MTAudioProcessingTap`. PAE has
   **no** graphic EQ at all today (only the DJ 3-band isolator).
4. **Decoders.** Voxglass ships `FLACDecoder` (436) + `AVFoundationDecoder` +
   `RoutingAudioDecoder` + `AudioResampler` against **binary** FLAC/Lame xcframeworks;
   PAE already has the same capability from vendored source (`Cflac`, `Csrc`,
   `AudioFileReader`, `SampleRateConverter`). Straight replacement, and it kills the
   binary-framework dependency.
5. **Loudness / normalization.** Tonearm `ReplayGain` (162) + `DJ/Analysis/Loudness` (278);
   Voxglass `VolumeNormalizer`; PAE `LoudnessAnalyzer` on `Cebur128` (EBU R128) — PAE's is
   the best of the three, but it lacks a ReplayGain-tag reader/writer.
6. **Analysis.** Tonearm `Sources/DJ/Analysis/*` (Beats, Tempo, Key, Onsets, STFT,
   SpectralFeatures, Energy, Phrase, Waveform, Loudness) overlaps
   `ParsoAudioAnalysis` (`TempoEstimator`, `KeyEstimator`, `StructureAnalyzer`,
   `WaveformGenerator`). Tonearm's is the more mature implementation and PAE's README
   already admits the v1 key estimator is unverified.
7. **Real-time DJ graph.** Tonearm `DJ/Engine/AudioGraph` (1258) + `Mixer` (469) +
   `PerformanceEngine` (542) + `RTCommand` vs PAE `ParsoDJEngine` + `CParsoEngine`.
   Two full two-deck engines. This is the largest single overlap and the riskiest move.

## 2. Target architecture

Five PAE products; the apps depend only on what they need.

```
ParsoAudioCore        buffers, decode/encode, SRC, loudness, DSP primitives   (exists)
ParsoAudioAnalysis    BPM/key/structure/waveform/energy                       (exists, to be upgraded)
ParsoAudioPlayback    NEW — graphic EQ, ReplayGain, crossfade, gapless queue,
                      silence skip, playback-rate, audio-session policy
ParsoAudioStreaming   NEW — sparse byte cache, ByteRangeMap, resource loader,
                      prefetch/pin/network policy
ParsoDJEngine         two decks, mixer, FX, sampler, recording                (exists)
```

`ParsoAudioPlayback` and `ParsoAudioStreaming` are new because both apps already need
them and neither PAE layer covers them. `ParsoDJEngine` stays Tonearm-only in practice.

### What stays in the apps (deliberately)

- **Tonearm:** library model & GRDB schema, remote-library providers (all 11), semantic
  search / embeddings / vector store, playlist generation, stems, MIDI hardware mapping,
  DJ UI (Workspace/Deck/Jog views), free-tier registry, Watch/Widgets/Share extension.
- **Voxglass:** LibriVox/Internet Archive catalog & selectors, bookmarks, position/resume
  durability (SQLite + UserDefaults + iCloud), recommendations, CarPlay, the entire
  Production suite (EPUB/TXT import, segmentation, takes, validation, packaging, sync),
  Watch app.
- **Both:** every SwiftUI view, persistence schema, sync, and monetization boundary.

Rule of thumb for the line: *if it takes samples in and gives samples or numbers out, it
belongs in PAE; if it knows what a book, a crate, or a subscription is, it does not.*

## 3. New APIs PAE must grow

Ordered; each is a self-contained deliverable with tests.

**`ParsoAudioStreaming`**
- `ByteRangeMap` — lift verbatim (identical in both apps; zero-risk first move).
- `SparseCacheStore` — sparse file + range map + eviction; union of Tonearm `CacheStore`
  and Voxglass `StreamCacheStore` (Voxglass's is the richer base).
- `CachingResourceLoader` — `AVAssetResourceLoaderDelegate`, range coalescing,
  redirect/response policy (Tonearm's `RemoteStreamingResponsePolicy` folds in here).
- Policy value types: `CacheLimitPolicy`, `PrefetchDepthPolicy`, `PinPolicy`, `NetworkPolicy`.
- Storage/URL-fetch injected as protocols so app cache directories and auth headers stay app-side.

**`ParsoAudioPlayback`**
- `GraphicEQ` — n-band RBJ peaking cascade, `Biquad` primitive, bit-transparent at 0 dB
  (keep Tonearm's null test as the contract), plus `EQPreset` and a `Codable` settings value.
- `EQTapInstaller` — one `MTAudioProcessingTap` per `AVPlayerItem`, with Voxglass's
  registry fix for gapless auto-advance. `#if !os(watchOS)`.
- `ReplayGainReader` (tag parse) and `NormalizationPlanner` mapping ReplayGain **or**
  measured EBU R128 to a playback gain — one policy, two sources.
- `CrossfadeCurve`, `SilenceDetector`, `PlaybackRate` value types (lift from the apps).
- `AudioSessionPolicy` — the shared category/route/interruption logic; the Watch variants
  in both apps collapse into it.

**`ParsoAudioCore` additions**
- `ReplayGain`/ID3/Vorbis-comment **tag read+write** (Voxglass `ID3Writer`, `AudioTags`).
- MP3 encode via `CGlint` so Voxglass can drop the **Lame binary xcframework**.
- Opus/Ogg remux helpers (Tonearm `OggPageReader`, `CAFOpusWriter`, `OpusRemuxer`) — these
  are container-level, not app-level.
- **watchOS support** (see §5).

**`ParsoAudioAnalysis` upgrades**
- Port Tonearm's `STFT`, `Onsets`, `Beats`, `Tempo`, `Key`, `Energy`, `Phrase`,
  `SpectralFeatures` in, replacing PAE's v1 estimators; keep PAE's public result types
  (`TempoResult`, `KeyResult`, `Section`) as the stable surface so the swap is internal.
- Add `EnergyResult` and phrase/downbeat output (Tonearm needs them; Voxglass does not).
- Keep `ThermalGovernor` and `AnalysisCoordinator` **in Tonearm** — they are scheduling
  and app-lifecycle policy, not DSP.

## 4. Sequencing

Each phase ends green on `swift test` in all three repos before the next starts.

- **Phase 0 — foundation.** Add `watchOS` to PAE platforms; raise the floor to iOS 17 /
  macOS 14 / watchOS 10 (Voxglass's floor is the binding one). Add the two new library
  products as empty targets. Set up local path-dependency overrides so both apps can build
  against a working copy of PAE.
- **Phase 1 — `ByteRangeMap`.** Move verbatim, both apps import it, delete both copies.
  This is the proof the pipeline works, and it is reversible in a commit.
- **Phase 1b — retire Linux** (§4b) and move the acceptance CLI out of the root package
  (§4c). Independent of the app migrations, and shrinks the surface every later phase has
  to keep compiling.
- **Phase 2 — streaming cache.** Land `SparseCacheStore` + `CachingResourceLoader` from
  the Voxglass base, port Tonearm's response/pin/prefetch policies onto it, migrate both
  apps. Highest duplication payoff.
- **Phase 3 — EQ + normalization.** ✅ done (2026-09-02). `GraphicEQ` + `GraphicEQSettings` +
  `EQTapInstaller`/`EQTapRegistry` + `ReplayGainReader`/`NormalizationPlanner` in
  `ParsoAudioPlayback`. Both apps' `EQEngine` is now a typealias/wrapper over `GraphicEQ`
  (Q is a parameter so neither app's sound changes); presets stay app-side. Tonearm's
  Phase 2 policy-dedup debt cleared. `EQTapInstaller` ships but neither app routes its tap
  through it yet — deliberate partial, see `current_status.md`.
- **Phase 4 — decoders.** Voxglass switches `FLACDecoder`/`AVFoundationDecoder`/
  `AudioResampler` to `ParsoAudioCore`; delete the FLAC xcframework. Then MP3 encode via
  `CGlint`; delete the Lame xcframework. Keep `SeekableAudioDecoding` as the app-side
  adapter protocol — PAE gains a bounded seekable range-decode API to satisfy it.
- **Phase 5 — analysis.** Port Tonearm's DSP into `ParsoAudioAnalysis` behind the existing
  public types; Tonearm's `AnalysisCoordinator` calls PAE. Voxglass gains cheap
  BPM/energy for free if it ever wants it.
- **Phase 6 — DJ engine (Tonearm only, decide first).** See §6.

## 4b. Phase 1b — retire Linux and the portable-codec scaffolding

Decision (2026-09-02): the package targets **Apple platforms only** — iOS, macCatalyst,
macOS and watchOS. Linux was a starter-step and is now removed outright. watchOS stays:
both apps ship Watch targets whose private audio code the shared layers are meant to
absorb.

### What is actually dead, and what only looks dead

The `#if canImport(AVFoundation)` fences are the Linux seam, but the vendored C is **not**
uniformly Linux-only. Verified call-site by call-site:

| Component | Verdict | Evidence |
|---|---|---|
| `Cflac`, `Cvorbis`, `Copus`, `Cebur128`, `Csrc` | **Keep — live on Apple** | FLAC/Vorbis/Opus decode, EBU R128 and SRC have no AVFoundation equivalent; reached unconditionally. |
| `CGlint` | **Keep — live on Apple** | `.mp3` encode calls `writeGlint` unconditionally (`ParsoAudioCore.swift:497`). AudioToolbox cannot *encode* MP3, so Glint is the only MP3 encoder on every platform. |
| `CGlint` decode (`decodeGlint`) | **Delete** | Only ever called from `#else` branches (lines 241, 247). |
| Portable ADTS-AAC encode branch | **Delete** | `#else`-only (line 483). |
| `MP4AACCodec` | **Delete** | Sole reference is line 257, inside `#else`. |
| `MP4ALACCodec` *parser* | **Keep — live on Apple** | `readMetadata` is called unconditionally at line 277; ~500 lines of pure-Swift MP4 box parsing with no Linux ties. |
| `MP4ALACCodec.decode` / `.write` | **Delete** | Unreferenced; they only call the `Calac` placeholder, which returns `PARSO_ALAC_CODEC_ERROR` by construction. |
| `Calac` target | **Delete** | Its only consumers are the two dead methods above and the `ALAC bridge` test that asserts it does nothing. ALAC-in-M4A decode/encode goes through AVFoundation on Apple. |

The trap to avoid: "remove the portable codecs" would take `CGlint` with it and silently
break MP3 export on every platform. Only the *decode* half of Glint is Linux-only.

### Work items

1. **Package.swift** — drop the two `.when(platforms: [.linux])` cSettings (`Cflac`
   `HAVE_CPUID_H`, `_POSIX_C_SOURCE`); remove the `Calac` target and its `ParsoAudioCore`
   dependency. Since every supported platform is now Apple, the `.when(platforms:)`
   qualifiers on the `AVFoundation` / `AudioToolbox` / `Accelerate` linker settings become
   noise — drop them too.
2. **ParsoAudioCore** — collapse all seven `#if canImport(AVFoundation)` fences to their
   Apple branch; delete `decodeGlint`, the portable AAC encode branch, and
   `Sources/ParsoAudioCore/MP4AACCodec.swift`; delete `MP4ALACCodec.decode`/`.write` and
   its `import Calac`, keeping the parser.
3. **ParsoDJEngine** — collapse its four `#if canImport(AVFoundation)` fences. `start()`
   and `stop()` become unconditional; `HeadlessDJEngine` is unaffected (it is the
   deterministic test path, not a Linux fallback).
4. **Tests** — delete the `ALAC bridge` suite (it asserts the placeholder is unavailable,
   which stops being a meaningful claim once the placeholder is gone).
5. **CI** — delete the `build-test-linux` job. Add a watchOS job (see §4c) so the platform
   we actually ship keeps a gate, rather than trading a real gate for none.
6. **Docs** — `docs/SPEC.md` §19.1 (the Linux compatibility workstream) is retired
   wholesale; §4 rows 67-69 and the decode/encode scope in §§19-22 lose their Linux
   caveats. `README.md` loses the Linux acceptance-tool claim (line 103), the portable
   MP3/ALAC roadmap (428-429) and the §19 pointer (460). `Sources/Calac/VENDOR.md` and
   `LICENSE` go with the target.

### One real thing given up

`docs/SPEC.md` §19.1 made Linux the **independent correctness host**: the non-Apple
cross-check that analysis, DSP, headless render and the portable codecs agreed with the
AudioToolbox paths. Removing it means a bug in an Apple framework path has no second
implementation disagreeing with it. That is an acceptable trade for two Apple-only apps —
and Phase 5 partly compensates, since porting Tonearm's analysis DSP in behind the
existing public types gives those algorithms a second independent implementation to
differ from during the swap — but it should be a deliberate loss, not an accidental one.

## 4c. Resolving the watchOS whole-package scheme

`xcodebuild -scheme parso-audio-engine-Package -sdk watchsimulator` fails, and no amount
of manifest conditioning fixes it: `ParsoAcceptanceArtifacts` is a command-line
executable, watchOS has no CLI executables to link, and `Package.swift` conditionals are
evaluated on the **host**, so `#if os(macOS)` there excludes nothing when the destination
is a watch.

**Resolution: move the tool into its own package.** `Tools/AcceptanceArtifacts/Package.swift`
declares the executable and depends on the root package by path. The root package then
contains only libraries, and the whole-package scheme builds for every destination.

- `swift run ParsoAcceptanceArtifacts …` becomes
  `swift run --package-path Tools/AcceptanceArtifacts ParsoAcceptanceArtifacts …`;
  update `README.md` and `docs/human-visible-acceptance.md`, which both document the
  old invocation.
- CI can then gate watchOS with one whole-package scheme build instead of naming the
  five library schemes.
- The root package keeps `Sources/ParsoAcceptanceArtifacts/` or moves it under
  `Tools/AcceptanceArtifacts/Sources/`; moving it is tidier and keeps the root `Sources/`
  tree exactly equal to the shipping products.


## 5. Cross-cutting issues to settle before Phase 1

- **watchOS.** PAE has no watchOS platform and the DSP/codec C targets have never been
  built for it. Gate everything `AVFoundation`/`MTAudioProcessingTap` with
  `#if !os(watchOS)`; verify each C target compiles for `arm64_32`. This is the most
  likely source of surprise breakage — do it in Phase 0, not later.
- **Platform floor.** Raised to iOS 17 / macCatalyst 17 / macOS 14 / watchOS 10 and
  **confirmed safe by the author** (2026-09-02): no third consumer needs the old iOS 15
  floor.
- **Concurrency.** PAE is strict Swift 6 (`swiftLanguageModes: [.v6]`); both apps are too.
  No adapter shims should be needed — but `@unchecked Sendable` classes crossing the
  boundary (`PCMBuffer`, `TimePitch`) need documented ownership rules.
- **Dependency wiring.** Tonearm's Xcode project (`project.yml`) and Voxglass's both need
  the SPM dependency added; use a branch/tag pin, with a local `.package(path:)` override
  during migration.
- **Relicensing record.** Every file moved out of Tonearm gets an `ATTRIBUTION.md` entry
  noting it was authored by you and relicensed MIT.

## 6. The DJ-engine question (open, needs your call)

Tonearm has a complete, tested, GPLv3 two-deck engine (`AudioGraph` + `Mixer` +
`PerformanceEngine` + `RTCommand`, ~2,500 lines). PAE has a complete, tested, MIT one
(`ParsoDJEngine` + `CParsoEngine`, ~1,200 Swift lines over a C++ render graph). They are
not partially overlapping — they are two answers to the same problem.

Three options:

1. **Tonearm adopts `ParsoDJEngine`, deletes its own.** Cleanest end state, largest single
   migration; the DJ UI is written against Tonearm's `RTCommand`/`WorkspaceModel` surface,
   so an adapter layer is unavoidable. Recommended if Platterhead DJ ships on PAE.
2. **PAE adopts Tonearm's engine** (relicensed MIT), deleting `ParsoDJEngine`/`CParsoEngine`.
   Keeps the shipping code path, but discards PAE's C++ allocation-free renderer and its
   FLX4-equivalence acceptance suite, which is the whole point of PAE.
3. **Defer.** Do Phases 0–5 (which are unambiguously shared), and leave two engines until
   Platterhead DJ's requirements are firm.

**Recommendation: option 3 now, option 1 as the destination.** Phases 0–5 remove the real
duplication and touch both apps; the DJ engine touches one app and is where a bad merge
costs the most. Decide it after Phase 5, when Tonearm already consumes PAE analysis and
the integration seam is proven.

## 7. What "done" looks like

- Zero `Biquad`, `ByteRangeMap`, `CachingResourceLoader`, FLAC-decode, or resampler
  implementations outside PAE.
- Voxglass ships no binary audio xcframeworks.
- Both apps' audio tests pass unchanged in behavior; PAE owns the DSP-level tests.
- Roughly 4,000–5,000 lines removed across the two apps, replaced by ~2,500 in PAE.
