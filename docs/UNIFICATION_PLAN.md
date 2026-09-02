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
- **Phase 2 — streaming cache.** Land `SparseCacheStore` + `CachingResourceLoader` from
  the Voxglass base, port Tonearm's response/pin/prefetch policies onto it, migrate both
  apps. Highest duplication payoff.
- **Phase 3 — EQ + normalization.** `GraphicEQ`, tap installer, ReplayGain/R128 planner.
  Both apps' EQ views bind to the shared engine; presets and settings storage stay app-side.
- **Phase 4 — decoders.** Voxglass switches `FLACDecoder`/`AVFoundationDecoder`/
  `AudioResampler` to `ParsoAudioCore`; delete the FLAC xcframework. Then MP3 encode via
  `CGlint`; delete the Lame xcframework. Keep `SeekableAudioDecoding` as the app-side
  adapter protocol — PAE gains a bounded seekable range-decode API to satisfy it.
- **Phase 5 — analysis.** Port Tonearm's DSP into `ParsoAudioAnalysis` behind the existing
  public types; Tonearm's `AnalysisCoordinator` calls PAE. Voxglass gains cheap
  BPM/energy for free if it ever wants it.
- **Phase 6 — DJ engine (Tonearm only, decide first).** See §6.

## 5. Cross-cutting issues to settle before Phase 1

- **watchOS.** PAE has no watchOS platform and the DSP/codec C targets have never been
  built for it. Gate everything `AVFoundation`/`MTAudioProcessingTap` with
  `#if !os(watchOS)`; verify each C target compiles for `arm64_32`. This is the most
  likely source of surprise breakage — do it in Phase 0, not later.
- **Platform floor.** PAE's iOS 15 floor is generous; raising it to 17 simplifies the
  Swift 6 concurrency surface. Confirm no third consumer needs 15.
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
