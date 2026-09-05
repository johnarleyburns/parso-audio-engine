# Human-visible acceptance artifacts

The acceptance harness produces an MP4 with the same audio that was analyzed and a frame-by-frame
overlay of the analysis results. This makes beat-grid phase, downbeats, waveform boundaries, and
phrase labels reviewable by ear and eye instead of relying only on numeric tests.

## Review-duration requirements

Every human-acceptance MP4 must contain at least 30 seconds of audio. Shorter clips do not provide
enough material to confirm an effect, so both artifact generation and MP4 rendering reject a
shorter sidecar. A source track shorter than 30 seconds is therefore not eligible for this review.

Phrase/structure acceptance is a separate full-track review: use the `phrase` scenario with
`--max-seconds 0`. Its MP4 must cover the entire source song, and the sidecar's `audioDuration`
must equal the complete `analysisDuration`, so every detected phrase can be checked.

## First artifact: source analysis

Install `ffmpeg` as a developer tool, download the Wikimedia Commons fixtures, then run:

```bash
./scripts/download-fixtures.sh
swift run --package-path Tools/AcceptanceArtifacts ParsoAcceptanceArtifacts \
  --fixture gostreyshen_world \
  --scenario waveform \
  --max-seconds 30 \
  --output-dir artifacts/acceptance/gostreyshen
python3 scripts/render-acceptance-video.py \
  --audio artifacts/acceptance/gostreyshen/gostreyshen_world-waveform.wav \
  --analysis artifacts/acceptance/gostreyshen/gostreyshen_world-waveform.json \
  --output artifacts/acceptance/gostreyshen/gostreyshen_world-waveform.mp4

# Phrase/structure review: render the entire song.
swift run --package-path Tools/AcceptanceArtifacts ParsoAcceptanceArtifacts \
  --fixture gostreyshen_world \
  --scenario phrase \
  --max-seconds 0 \
  --output-dir artifacts/acceptance/gostreyshen
python3 scripts/render-acceptance-video.py \
  --audio artifacts/acceptance/gostreyshen/gostreyshen_world-phrase.wav \
  --analysis artifacts/acceptance/gostreyshen/gostreyshen_world-phrase.json \
  --output artifacts/acceptance/gostreyshen/gostreyshen_world-phrase.mp4
```

The JSON sidecar is intentionally part of the review output. It records the fixture, source and
rendered scenario, audio duration, BPM/key/loudness, beats, downbeats, section labels, and waveform
points. The video uses the first 30 seconds by default; set `--max-seconds 0` to render the complete
track. The analysis itself runs on the complete source track before the visible clip is selected,
except that the `phrase` scenario also keeps the complete source visible for phrase review.

The waveform is multi-colored by measured frequency energy: blue is low-band, green is mid-band,
and red is high-band; brightness follows the bucket's peak/RMS intensity. Yellow markers are
downbeats; blue markers are ordinary beats; magenta ticks are engine control events; the white line is the synchronized playhead. Section
labels use the analyzer's current best-effort classifications (`intro`,
`buildup`, `drop`, `verse`, `chorus`, `breakdown`, and `outro`). A generated artifact is an
acceptance aid, not ground truth: verify questionable phrases by listening and record verified
values in the fixture ledger.

## Stem separation and CLAP semantic search (Phase 7b/7c)

These two neural features don't fit the WAV+JSON+video-overlay contract above (stems produce
four full-length audio files, not one; CLAP is a text→track ranking, not a per-track render), so
they're separate executables in the same `Tools/AcceptanceArtifacts` package: `ParsoStemsAcceptance`
and `ParsoClapAcceptance`. Both take real, caller-supplied `.mlpackage` weights — this repo never
ships them (`Sources/ParsoAudioNeural/Semantic.swift`, `Separation.swift`) — and neither tool
attempts to fake or bypass a missing model; each errors out with the expected path if the model
isn't there.

### Stem separation

Runs real Demucs inference (`DemucsStems.mlpackage`, already converted for `parso-tonearm` — see
`ATTRIBUTION.md`) through the same `StemModelProviding`/`StemSeparator` seam PAE ships, and writes
each of the four voices as its own WAV so you can listen to vocals/drums/bass/other in isolation
and against the mix:

```bash
swift run --package-path Tools/AcceptanceArtifacts ParsoStemsAcceptance \
  --fixture josh_woodward_anchor \
  --stems-model /path/to/parso-tonearm/Resources/Models/DemucsStems.mlpackage \
  --output-dir artifacts/acceptance/stems
```

`--max-seconds N` clips the source before separating (omit or `0` for the complete track — Demucs
runs in ~7.8 s chunks with 50% overlap-add, so the full track gives the most representative
listening review). `josh_woodward_anchor` and `josh_woodward_invisible_light` are vocal-forward
full-band fixtures added specifically for this review (`Tests/Fixtures/fixtures.json`, role
`stems`) — the tempo/key analysis fixtures skew instrumental house/disco and are a worse test of
vocal isolation.

Demucs is a real converted model used here to prove the separation pipeline end-to-end; it is
**not** PAE's shipping default (Spleeter is — see README.md "On-device neural"). Spleeter has no
converted `.mlpackage` yet — converting its TF checkpoint is separate follow-up work — so this tool
takes any `StemModelProviding` conformance and needs no changes once one exists; pass its path to
`--stems-model` instead.

A `.mlpackage` must be compiled before `MLModel` can load it (an Xcode app target does this at
build time automatically; this standalone CLI does it itself via `MLModel.compileModel(at:)`).

### CLAP semantic search

Embeds each given fixture once with the CLAP audio encoder, embeds each text query once with the
text encoder, ranks the fixtures by cosine similarity, and writes/prints the ranking so you can
listen through it top-to-bottom and judge relevance — this is a search-relevance review, not a
per-track effect:

```bash
swift run --package-path Tools/AcceptanceArtifacts ParsoClapAcceptance \
  --fixtures audial_waking_up,bach_toccata_fugue_d_minor_norbert_schenk,josh_woodward_anchor \
  --query "driving house beat" \
  --query "melancholy piano" \
  --text-model /path/to/CLAPTextEncoder.mlmodelc \
  --audio-model /path/to/CLAPAudioEncoder.mlmodelc \
  --tokenizer-dir /path/to/parso-tonearm/Resources/CLAP \
  --mel-filterbank /path/to/parso-tonearm/Resources/CLAP/mel_filterbank_slaney_64.bin \
  --output-dir artifacts/acceptance/clap
```

The CLAP models, tokenizer vocab/merges, and mel filterbank are the ones already converted for
`parso-tonearm` (`Resources/Models/CLAPTextEncoder.mlpackage` / `CLAPAudioEncoder.mlpackage`,
`Resources/CLAP/`) — see `ATTRIBUTION.md`. Unlike the stems tool, `--text-model`/`--audio-model`
must already be compiled `.mlmodelc` directories (`CoreMLSemanticModel` itself, unlike this tool's
Demucs wrapper, does not compile a raw `.mlpackage`); compile once with:

```bash
xcrun coremlcompiler compile /path/to/CLAPTextEncoder.mlpackage /path/to/compiled-dir
xcrun coremlcompiler compile /path/to/CLAPAudioEncoder.mlpackage /path/to/compiled-dir
```

## Engine scenario matrix

The same sidecar schema will be used for rendered headless-engine scenarios. Each scenario must
render its actual output WAV and list its control events, so the reviewer can hear the result while
seeing the exact crossfader, EQ, FX, loop, or scratch timeline. Planned scenario names are:

| Scenario | Review target | Current status |
|---|---|---|
| `crossfader-sweep` | manual auto/long-cut style crossfades | implemented through `HeadlessDJEngine` |
| `smart-fader` | BPM match, bass duck, level automation, echo/reverb tail | Smart Fader automation incomplete |
| `smart-cfx` | one-knob filter/space/dub-echo chains | Smart CFX rendering incomplete |
| `beatfx-echo-out` | tail release and drop timing | engine scenario adapter next |
| `scratch` | vinyl, backspin, baby, transformer, and release behavior | scratch fixture scenarios next |
| `loop-and-cue` | quantized loop edges, roll, cue and hot-cue jumps | controls implemented; artifact adapter next |

“Auto fade”, “long cut”, “bass fade cut”, “drop cut”, and “snap back” should be represented as
named event timelines once their engine automation is implemented. The harness must not synthesize
those labels over a plain source track.

## Tooling boundary

`ParsoAcceptanceArtifacts` and the Python renderer are developer/test tooling. `ffmpeg` is used only
to encode the review MP4 and is not a SwiftPM dependency, vendored library, or runtime requirement
of the shipping products. The tool lives in its own package (`Tools/AcceptanceArtifacts`) so the
root package holds only libraries and its scheme builds for every Apple destination; macOS CI
remains responsible for native AVFoundation/AudioToolbox and device-style acceptance.
