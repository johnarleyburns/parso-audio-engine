# Audio Fixture Attribution

The following Creative Commons audio works are used **only as test fixtures**. They are
**downloaded at test time and are not redistributed in this repository**. Each work's
license and author are shown on its linked Wikimedia Commons page — consult that page for
the exact license (CC0 / CC-BY / CC-BY-SA, etc.) and required attribution before reusing.

| Track | Genre | Format | Commons page |
|---|---|---|---|
| Audial - Waking Up | house | oggVorbis | https://commons.wikimedia.org/wiki/File:Audial_-_Waking_Up.ogg |
| BANDA & DACHY - RALLY HOUSE | house | oggVorbis | https://commons.wikimedia.org/wiki/File:BANDA_%26_DACHY_-_RALLY_HOUSE.ogg |
| Casey - Fly High | house | oggVorbis | https://commons.wikimedia.org/wiki/File:Casey_-_Fly_High.ogg |
| Cihangir - Turn to Dust feat. Miss Bee (Manic Depresion Mix) | house | oggVorbis | https://commons.wikimedia.org/wiki/File:Cihangir_-_Turn_to_Dust_feat._Miss_Bee_(Manic_Depresion_Mix).ogg |
| Gostreyshen - World | house | mp3 | https://commons.wikimedia.org/wiki/File:Gostreyshen_-_World.mp3 |
| Kingdom-of-darkness-by-Kjartan-Abel | unknown | oggVorbis | https://commons.wikimedia.org/wiki/File:Kingdom-of-darkness-by-Kjartan-Abel.ogg |
| Lukas - Berlin | house | oggVorbis | https://commons.wikimedia.org/wiki/File:Lukas_-_Berlin.ogg |
| MCT - Benevolence | house | oggVorbis | https://commons.wikimedia.org/wiki/File:MCT_-_Benevolence.ogg |
| Tim Derry - COLD LOVE | house | oggVorbis | https://commons.wikimedia.org/wiki/File:Tim_Derry_-_COLD_LOVE.ogg |
| Wolflund - Watching Over Me (feat. Melissa Pixel) | house | oggVorbis | https://commons.wikimedia.org/wiki/File:Wolflund_-_Watching_Over_Me_(feat._Melissa_Pixel).ogg |
| Nctrnm - Queue | disco | oggVorbis | https://commons.wikimedia.org/wiki/File:Nctrnm_-_Queue.ogg |
| Bobby Jimmy and the Critters - Ugly Knuckle Butt | hip-hop | oggVorbis | https://commons.wikimedia.org/wiki/File:Bobby_Jimmy_and_the_Critters_-_Ugly_Knuckle_Butt.ogg |
| Offbeatninja - The Hunt Is On ( Hunter X Hunter Bump ) | hip-hop | oggVorbis | https://commons.wikimedia.org/wiki/File:Offbeatninja_-_The_Hunt_Is_On_(_Hunter_X_Hunter_Bump_).ogg |
| Raspberrymusic - Lofi Hip Hop Upbeat | lofi-hip-hop | oggVorbis | https://commons.wikimedia.org/wiki/File:Raspberrymusic_-_Lofi_Hip_Hop_Upbeat.ogg |
| Razrfish - Mocassins | hip-hop | opus | https://commons.wikimedia.org/wiki/File:Razrfish_-_Mocassins.opus |
| Wikipedia Chanukah | non-dance | flac | https://commons.wikimedia.org/wiki/File:Wikipedia_Chanukah.flac |
| ᴼᴬᵇᵉᵃᵗˢ - I Need U (Deep House Instrumental Vocal Deep Slap House Type Beat) | slap-house | opus | https://commons.wikimedia.org/wiki/File:%E1%B4%BC%E1%B4%AC%E1%B5%87%E1%B5%89%E1%B5%83%E1%B5%97%CB%A2_-_I_Need_U_(Deep_House_Instrumental_Vocal_Deep_Slap_House_Type_Beat).opus |
| ᴼᴬᵇᵉᵃᵗˢ - Universe | slap-house | opus | https://commons.wikimedia.org/wiki/File:%E1%B4%BC%E1%B4%AC%E1%B5%87%E1%B5%89%E1%B5%83%E1%B5%97%CB%A2_-_Universe.opus |

| Harlequin - Persona | neurofunk | oggVorbis | https://commons.wikimedia.org/wiki/File:Harlequin_-_Persona.ogg |
| Ars Niemo - Small Talk Build IV | electronic | oggVorbis | https://commons.wikimedia.org/wiki/File:Ars_Niemo_-_Small_Talk_Build_IV.ogg |
| Aces.R - Temple Dab | electronic | oggVorbis | https://commons.wikimedia.org/wiki/File:Aces.R_-_Temple_Dab.ogg |
| CrookedCop | hip-hop | oggVorbis | https://commons.wikimedia.org/wiki/File:CrookedCop.ogg |
| Tea Roots (ISRC USUAN1100472) | electronic | mp3 | https://commons.wikimedia.org/wiki/File:Tea_Roots_(ISRC_USUAN1100472).mp3 |
| Elysian Bailey - 01 - Come Home | electronic | oggVorbis | https://commons.wikimedia.org/wiki/File:Elysian_Bailey_-_01_-_Come_Home.ogg |
| Josh Woodward - 17 - Little Tomcat | unknown | oggVorbis | https://commons.wikimedia.org/wiki/File:Josh_Woodward_-_17_-_Little_Tomcat.ogg |
| Bach, Toccata und Fuge d-moll BWV 565, Norbert Schenk | classical | mp3 | https://commons.wikimedia.org/wiki/File:Bach,_Toccata_und_Fuge_d-moll_BWV_565,_Norbert_Schenk.mp3 |
| Enrique Granados - danza espanola, op. 37, h. 142 - xii. arabesca | classical | oggVorbis | https://commons.wikimedia.org/wiki/File:Enrique_Granados_-_danza_espanola,_op._37,_h._142_-_xii._arabesca.ogg |

> To lock verified BPM/key ground truth for regression tests, edit the matching
> `expected` entry in `Tests/Fixtures/fixtures.json`.

---

# First-party code relicensed into this package

Source files migrated here from the author's own applications during the audio-engine
unification (`docs/UNIFICATION_PLAN.md`). Every file below was authored solely by
John Arley Burns, who as sole copyright holder relicenses it under this package's MIT
license. No third-party or copyleft-licensed code is included.

| File here | Origin | Notes |
|---|---|---|
| `Sources/ParsoAudioStreaming/ByteRangeMap.swift` | `parso-tonearm/Sources/Audio/ByteRangeMap.swift` and `parso-voxglass/Voxglass/Core/Services/Playback/ByteRangeMap.swift` | The two originals were byte-identical; migrated verbatim. |
| `Sources/ParsoAudioStreaming/RemoteStreamingResponsePolicy.swift` | `parso-tonearm/Sources/Audio/RemoteStreamingResponsePolicy.swift` | Migrated verbatim (types marked `Sendable`). Voxglass had no equivalent. |
| `Sources/ParsoAudioStreaming/SparseCacheStore.swift` | `parso-tonearm/Sources/Audio/CacheStore.swift` + `parso-voxglass/Voxglass/Core/Services/Playback/StreamCacheStore.swift` | Generalized union, not a verbatim lift: Voxglass's two-tree durable/evictable model is the base; Tonearm's `cafBytes` becomes a generic named derived-artifact slot and `pinned` becomes the durable tier; entry `kind` is an opaque tag; storage roots and limit are injected. `SparseCacheLayout` generalizes Tonearm's `nonisolated static` `CacheStore.fileURL`/`completeCacheExists`/`cafURL` helpers into an actor-free view of the on-disk layout. |
| `Sources/ParsoAudioStreaming/CachingResourceLoader.swift` | `parso-tonearm/Sources/Audio/CachingResourceLoader.swift` + `parso-voxglass/Voxglass/Core/Services/Playback/CachingResourceLoader.swift` | Tonearm's (the superset — `headers:`, `warm(upTo:)`, byte-range fallback, redirect resolution) generalized: the `SparseCacheStore` and `CacheKeyStrategy` are injected via `CachingResourceLoaderConfig`; `URLSession` is injectable for tests. |
| `Sources/ParsoAudioStreaming/StreamCacheKeying.swift` | `parso-tonearm/Sources/Audio/CacheKeyGenerator.swift` + `parso-voxglass/Voxglass/Core/Services/Playback/StreamCacheUtils.swift` | Both apps' SHA256 key schemes offered as `CacheKeyStrategy` presets (they differ only in empty-extension handling); scheme-swap / content-type helpers merged. `RemoteAudioURL.contentTypeMIME` generalizes Voxglass's `StreamCacheUtils.audioMIMEType` (for `AVURLAssetOverrideMIMETypeKey`). |
| `Sources/ParsoAudioStreaming/CachePolicies.swift` | `parso-tonearm/Sources/Audio/CacheLimitPolicy.swift` + `NetworkPolicy.swift` + `PrefetchDepthPolicy.swift` | Migrated verbatim (Phase 2 step 3), types marked `Sendable`. Voxglass had no equivalent. Tonearm's originals were deleted in Phase 3. |
| `Sources/ParsoAudioPlayback/GraphicEQ.swift` | `parso-tonearm/Sources/Audio/EQ/EQEngine.swift` + `EQPreset.swift` + `parso-voxglass/Voxglass/Core/Services/Playback/EQ/BiquadFilter.swift` | 10-band ISO graphic EQ. Tonearm's `Biquad`/`EQEngine` structure is the base (`BiquadSection`, `GraphicEQ`); the peaking Q is a caller parameter (Tonearm 1.41, Voxglass 1.0) so neither app's sound changes. `GraphicEQSettings` is a new pure `Codable` value. `EQPreset` merges both apps' preset types: Voxglass's UUID identity + `isBuiltIn`, Tonearm's `[Double]` gains + `floatGains` + gentler built-in curves; canonical names `Flat`/`Concert Hall`/`Spoken`/`78 rpm`. Both apps' originals became typealiases / thin wrappers; each app keeps its own preset persistence. |
| `Sources/ParsoAudioPlayback/EQTapInstaller.swift` | `parso-voxglass/Voxglass/Core/Services/Playback/EQ/EQTapRegistry.swift` + `parso-tonearm/Sources/Audio/EQ/EQAudioTap.swift` | `EQTapRegistry` migrated verbatim from Voxglass. `EQTapInstaller` is new — generic `MTAudioProcessingTap` lifecycle (Pre/PostEffects) driving a caller `RealtimeAudioProcessor`, keeping the `passRetained` tap-storage ownership that was a Voxglass field-crash fix. |
| `Sources/ParsoAudioPlayback/Normalization.swift` | `parso-tonearm/Sources/Audio/ReplayGain.swift` | `ReplayGainReader` is the `replaygain_*` tag parser lifted verbatim; `NormalizationPlanner` generalizes `ReplayGain.appliedGain` to accept either RG tags or a measured EBU R128 loudness. Tonearm's `ReplayGain` is now a thin shim over these. |
| `Sources/CflacBridge/*` + `Sources/ParsoAudioCore/ParsoAudioCore.swift` (`AudioFileReader.decodeRange`, `ExportCodec.flacDelivery`) | `parso-voxglass/Voxglass/Core/Encoders/FLACDecoder.swift` + `FLACEncoder.swift` | Phase 4: PAE's FLAC bridge gained a bounded `parso_flac_decode_range` (libFLAC `seek_absolute`, the design carried over from Voxglass's callback-based range path) and a `parso_flac_encode_file_tagged` delivery path (caller bit depth + Vorbis comments, no PFLT block — the `AudioTags` → Vorbis-comment mapping `TITLE/ARTIST/ALBUM/…` is Voxglass's). Voxglass's `FLACDecoder`/`FLACEncoder` become thin shims over these; the `FLAC.xcframework` is deleted. |
| `Sources/ParsoAudioAnalysis/AnalysisAudio.swift` | `parso-tonearm/Sources/DJ/Analysis/AudioDecode.swift` | Phase 5: `PCMBuffer` → `AnalysisAudio`, `AudioDecoder` → `AnalysisDecoder`; the AVFoundation 48 kHz decode is gated `#if canImport(AVFoundation) && !os(watchOS)`, the buffer type itself is portable. |
| `Sources/ParsoAudioAnalysis/STFTKernel.swift` | `parso-tonearm/Sources/DJ/Analysis/STFT.swift` | Phase 5: verbatim (vDSP real-FFT STFT); `AudioDecoder.workingSampleRate` → `AnalysisDecoder.workingSampleRate`. |
| `Sources/ParsoAudioAnalysis/SpectralFeatures.swift` | `parso-tonearm/Sources/DJ/Analysis/SpectralFeatures.swift` | Phase 5: verbatim. |
| `Sources/ParsoAudioAnalysis/Onsets.swift` | `parso-tonearm/Sources/DJ/Analysis/Onsets.swift` | Phase 5: verbatim (multi-band spectral-flux onset envelope + adaptive peak-picking). |
| `Sources/ParsoAudioAnalysis/Tempo.swift` | `parso-tonearm/Sources/DJ/Analysis/Tempo.swift` | Phase 5: verbatim (autocorrelation comb + IOI histogram + octave resolution). |
| `Sources/ParsoAudioAnalysis/Beats.swift` | `parso-tonearm/Sources/DJ/Analysis/Beats.swift` | Phase 5: verbatim (Ellis-style DP beat tracker + downbeats). |
| `Sources/ParsoAudioAnalysis/Key.swift` | `parso-tonearm/Sources/DJ/Analysis/Key.swift` | Phase 5: verbatim (HPCP chroma + Krumhansl–Schmuckler correlation + Camelot wheel). |
| `Sources/ParsoAudioAnalysis/Energy.swift` | `parso-tonearm/Sources/DJ/Analysis/Energy.swift` | Phase 5: verbatim + a new `EnergyResult` value bundling the scalar, curve and hop. |
| `Sources/ParsoAudioAnalysis/Phrase.swift` | `parso-tonearm/Sources/DJ/Analysis/Phrase.swift` | Phase 5: verbatim (self-similarity + Foote checkerboard + energy-contour phrase segmentation). |
| `Sources/ParsoAudioAnalysis/WaveformPyramid.swift` | `parso-tonearm/Sources/DJ/Analysis/Waveform.swift` + `parso-tonearm/Sources/DJ/Engine/Mixer.swift` (`Biquad`, `LinkwitzRiley`) | Phase 5: `Waveform.swift` verbatim (file renamed to avoid a clash with the facade `Waveform` struct); the mixer's `Biquad`/`LinkwitzRiley` LR4 crossover carried as a file-private copy (`WFBiquad`/`WFLinkwitzRiley`) since it lives in the mixer, not the analysis dir — the 200 Hz / 2 kHz split matches §35.2 exactly. |
| `Sources/ParsoAudioAnalysis/FullAnalysis.swift` | `parso-tonearm/Sources/DJ/Analysis/AnalysisCoordinator.swift` (`AnalyzePipeline.run`) | Phase 5: the 12-step Stage-1 sequence minus the GRDB persist coupling → `FullAnalysisResult`; the loudness step bridges `AnalysisAudio` → `ParsoAudioCore.PCMBuffer` and calls `ParsoAudioCore.LoudnessAnalyzer` (libebur128) instead of the deleted hand-rolled `Loudness.swift`. |
| `Sources/ParsoAudioNeural/Semantic.swift` | `parso-tonearm/Sources/DJ/Semantic/EmbeddingModel.swift` | Phase 7b: `EmbeddingModelSpec`, `SemanticModel`, `CoreMLSemanticModel`, `DeterministicFakeSemanticModel`, `CLAPEmbedder` — verbatim, watchOS-gated with the rest of `ParsoAudioNeural`'s CoreML surface. App-side ODR/`ModelResourceService` wiring, `EmbeddingCoordinator` (GRDB scheduling) stay in `parso-tonearm`. |
| `Sources/ParsoAudioNeural/RoBERTaTokenizer.swift` | `parso-tonearm/Sources/DJ/Semantic/RoBERTaTokenizer.swift` | Phase 7b: verbatim (GPT-2/RoBERTa byte-level BPE). Not watchOS-gated — pure, no CoreML dependency. |
| `Sources/ParsoAudioNeural/SemanticPreprocess.swift` | `parso-tonearm/Sources/DJ/Semantic/Preprocess.swift` | Phase 7b: the CLAP log-mel frontend, renamed `Preprocess` → `SemanticPreprocess` to avoid a name clash with any future PAE preprocessing type; `PCMBuffer` → `ParsoAudioAnalysis.AnalysisAudio`. Algorithm unchanged. |
| `Sources/ParsoAudioNeural/SemanticPooling.swift` | `parso-tonearm/Sources/DJ/Semantic/Pooling.swift` | Phase 7b: verbatim (mean/attention pooling), renamed `Pooling` → `SemanticPooling`. |
| `Sources/ParsoAudioNeural/VectorQuantization.swift` | `parso-tonearm/Sources/DJ/Semantic/Quantization.swift` | Phase 7b: verbatim (symmetric per-row int8 quantization), renamed `Quantization` → `VectorQuantization`. |
| `Sources/ParsoAudioNeural/VectorMatrixScanner.swift` | `parso-tonearm/Sources/DJ/Semantic/VectorStore.swift` (`VectorMatch`/`VectorMatrixScanner` only) | Phase 7b: the pure brute-force cosine scanner moved verbatim, generalized `trackID` → `rowID` (storage-agnostic — the GRDB-backed `VectorStore`/`VectorStoreTierA` persistence layer is app policy and stays in `parso-tonearm`, now built on this scanner). |
| `Sources/ParsoAudioNeural/HybridRanking.swift` | `parso-tonearm/Sources/DJ/Semantic/Ranking.swift` | Phase 7b: verbatim hybrid scorer (`HybridRanker`, `RankWeights/Candidate/Target/Breakdown`, `RankedMatch`), `trackID` → `rowID`; now depends on `ParsoAudioAnalysis.CamelotKey`/`Camelot` (already ported in Phase 5) instead of `TonearmCore`'s copy. |
| `Sources/ParsoAudioNeural/Separation.swift` | `parso-tonearm/Sources/DJ/Stems/StemModel.swift` + `StemSeparator.swift` (the model-agnostic seam only) | Phase 7c: `StemKind` → `SeparationVoice` (renamed to avoid colliding with the unrelated, pre-existing `ParsoDJEngine.StemKind`), plus `StemChunk`, `StemSeparation`, `StemModelProviding`, `StemChunking`, `StemSeparator` generalized — `PCMBuffer` → `AnalysisAudio`; `StemModelError` trimmed to the two backend-agnostic cases. The model-specific `DemucsStemModel`/`DemucsSpectrogram` are not ported (see current_status.md "Phase 7" for why Demucs weights are not shippable) and stay in `parso-tonearm` as one optional, non-default `StemModelProviding` conformance the app may still register. |
| `Sources/ParsoAudioNeural/SeparationBackendRegistry.swift` | — (new) | Phase 7c: the runtime-swappable backend registry; not a port. |
| `Sources/ParsoAudioNeural/SpleeterSpectrogram.swift`, `SpleeterStemModel.swift` | — (new) | Phase 7c: the default `StemModelProviding` conformance, wrapping a Core ML conversion of Deezer's Spleeter (`github.com/deezer/spleeter`, MIT code + weights). Not a port of Spleeter's Python/TensorFlow source — an independent Swift/Accelerate reimplementation of its published STFT/masking frontend and I/O contract. See that file's header for the licensing determination and current_status.md "Phase 7" for the quality/licensing trade-off and the BS-RoFormer-class successor plan. |
