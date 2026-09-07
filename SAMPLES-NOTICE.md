# Built-in sample & impulse-response content

PAE ships **no** audio sample data. This file documents the CC0 / CC-BY sources
an app can draw on for a built-in sampler and for the convolution Reverb / Space
Beat FX (see `docs/CDJ3000-parity-research.md` §5 and phases C5 / C7), and the
attribution obligations that come with them. Fetch them with
`scripts/download-samples.sh` (into `SampleLibrary/downloads/`, git-ignored);
`SampleLibrary/manifest.json` is the machine-readable list.

## License policy (mirrors the codec / stem-model policy)

| Tier | Rule |
|---|---|
| **CC0 / public domain** | Ship freely. No attribution obligation, no share-alike. Preferred. |
| **CC-BY 4.0** | OK for a *data pack* only if a per-file entry (source, author, licence, URL) ships with the app. Attribution is a docs task, not a code constraint. |
| **CC-BY-SA 4.0** | Tolerable for a standalone pack (data, not linked code — it does not infect PAE's MIT code). The pack itself becomes share-alike. Prefer to avoid; never mix SA and non-SA in one distributed pack. |
| **Any "NC" clause** | **Disqualified** for a commercially redistributable app — the same trap the MUSDB18 stem models fall into. |

Anything DSP can synthesise — white/pink noise, sirens, risers, bitcrush,
vinyl-brake, metronome, gate/trans — is generated, not sampled, and carries no
licensing surface.

## Sources

### CC0 — sampler content (no attribution required)

| Pack | Content | Homepage |
|---|---|---|
| **VCSL** (Versilian Community Sample Library) | orchestral / world / keys / mallets / experimental instrument one-shots | <https://versilian-studios.com/vcsl/> |
| **VSCO 2 Community Edition** | chamber-orchestra strings / brass / woodwinds / percussion | <https://vis.versilstudios.com/vsco-community.html> |
| **Virtuosity Drums** (Versilian) | acoustic drum-kit one-shots | <https://vis.versilstudios.com/virtuosity-drums.html> |
| **Freesound.org**, filtered to the `CC0` licence facet | kicks / snares / hats / perc / risers / impacts / foley | <https://freesound.org/> |

Verify the provenance of any "free 808/909" pack before shipping — treat a
casually-applied licence tag the way this project treats a casually-MIT-tagged
model checkpoint. Roland's own 808/909 sample packs are **not** free.

### CC-BY 4.0 / free-for-any-use — impulse responses (attribution table required)

| Pack | Content | Licence | Homepage |
|---|---|---|---|
| **OpenAIR** (Univ. of York) | real halls / cathedrals / tunnels / plates / rooms | CC-BY 4.0 (per space; each space page lists its contributor) | <https://www.openair.hosted.york.ac.uk/> |
| **EchoThief** | ~1000 real spaces | free for any use | <http://www.echothief.com/> |
| **Voxengo IR pack** | halls / rooms / plates | free redistribution | <https://www.voxengo.com/impulses/> |

**If you ship any OpenAIR IR, add a row here** for each one: space name,
contributor, the space's OpenAIR page URL, and "CC-BY 4.0". EchoThief / Voxengo
need only a general credit.

<!-- app maintainers: append shipped-IR attribution rows below this line -->
