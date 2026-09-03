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
