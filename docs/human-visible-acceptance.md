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

## Linux native music artifacts

The framework-free native acceptance seam can be built and run on Linux while the
Swift analyzer remains Apple-only. The deterministic CTest tone remains available
as a smoke test, but the human-listening gate uses a different downloaded real MP3
fixture for every listening slot:

```text
crossfader-sweep: Tests/Fixtures/audio/gostreyshen_world.mp3 + tea_roots_isrc_usuan1100472.mp3
smart-fader: Tests/Fixtures/audio/lukas_lucas_impala.mp3 + tech_live.mp3 (122.5/124 BPM)
smart-cfx: Tests/Fixtures/audio/porch_blues.mp3
beatfx-echo-out: Tests/Fixtures/audio/mary_stafford_royal_garden_blues.mp3 + st_louis_blues.mp3
scratch: Tests/Fixtures/audio/upbeat_forever.mp3
loop-and-cue: Tests/Fixtures/audio/divertimento_k131.mp3 + divertissement_pizzicato.mp3
warm2-isolator: Tests/Fixtures/audio/in_a_heartbeat.mp3
```

Run the complete native/Python music gate with:

```bash
./scripts/download-fixtures.sh
cmake -S . -B build-native -DPARSO_BUILD_TESTS=ON -DCMAKE_BUILD_TYPE=Release
python3 scripts/run-linux-acceptance.py \
  --build-dir build-native \
  --output-dir /tmp/parso-linux-music-review
```

The runner decodes the first 30 seconds of each real MP3 through the portable codec
path. It keeps the native/Python crossfader render as a parity anchor, then renders
every engine listening scenario through the native engine behind the Python facade.
Single-deck scenarios (Smart CFX, scratch, and WARM2) contain one source only.
Echo-out and loop/cue keep the incoming deck silent until the outgoing effect or
transport operation has completed. Smart Fader uses the close-BPM pair above,
starts beat-aligned at frame zero, applies the measured tempo ratio, and transitions
over the second half of the clip. Every scenario is a separate WAV/JSON pair.

The generated review WAVs can be played directly through PipeWire:

```bash
pw-play --volume 0.5 \
  /tmp/parso-linux-music-review/python/python-crossfader-sweep.wav
```

To listen to the separate scenario files:

```bash
for scenario in \
  crossfader-sweep smart-fader smart-cfx beatfx-echo-out \
  scratch loop-and-cue warm2-isolator; do
  pw-play --volume 0.5 \
    "/tmp/parso-linux-music-review/python/python-${scenario}.wav"
done
```

The individual files are the authoritative listening artifacts; the loop is
intentionally sequential but each scenario can also be launched on its own.

Index generated Linux artifacts before review so the files, native commit, format, duration, and
human status are recorded together:

```bash
python3 scripts/index-linux-acceptance.py \
  --root /tmp/parso-native-acceptance \
  --output /tmp/parso-native-acceptance/manifest.json
```

The indexer rejects missing pairs, malformed WAV headers, durations below 30 seconds, and sidecar
duration mismatches. Every valid artifact starts with `reviewStatus: "pending"`; only a human
listening pass should change that field in a review copy. Generated manifests and media remain
outside the repository.

The lower-level native command is also available when testing a different pair of
MP3 files:

```bash
./build-native/parso_native_acceptance_artifacts \
  --output-dir /tmp/parso-crossfader-acceptance --seconds 30 \
  --scenario crossfader-sweep \
  --input-mp3-a Tests/Fixtures/audio/gostreyshen_world.mp3 \
  --input-mp3-b Tests/Fixtures/audio/tea_roots_isrc_usuan1100472.mp3 \
  --fixture-a gostreyshen_world --fixture-b tea_roots_isrc_usuan1100472
python3 scripts/index-linux-acceptance.py \
  --root /tmp/parso-crossfader-acceptance \
  --output /tmp/parso-crossfader-acceptance/manifest.json
```

Compare native and Python renders from the same timeline with the explicit cross-backend gate:

```bash
python3 scripts/compare-linux-acceptance.py \
  --left /tmp/parso-crossfader-acceptance/native-crossfader-sweep.json \
  --right /tmp/parso-python-crossfader/python-crossfader-sweep.json \
  --tolerance 2 \
  --output /tmp/parso-crossfader-comparison.json
```

The report checks scenario/event parity, WAVE format and frame count, then records maximum and
mean absolute 16-bit sample differences. The default tolerance is two integer counts; a passing
comparison still requires separate human listening review.

The complete Linux gate can be run with one safe orchestration command. Its output directory must
be new or empty; the runner never deletes prior artifacts:

```bash
python3 scripts/run-linux-acceptance.py \
  --build-dir build-native \
  --output-dir /tmp/parso-linux-crossfader-review
```

It builds the native acceptance executable, renders native and Python artifacts, writes
`manifest.json`, writes `comparison.json`, and finishes with `summary.json`.

The waveform is multi-colored by measured frequency energy: blue is low-band, green is mid-band,
and red is high-band; brightness follows the bucket's peak/RMS intensity. Yellow markers are
downbeats; blue markers are ordinary beats; magenta ticks are engine control events; the white line is the synchronized playhead. The music artifact is an
acceptance aid, not ground truth: verify audible crossfader behavior and record review status in
a copy of the manifest. The runner's comparator remains a deterministic parity check, not a
substitute for listening.

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
| `smart-fader` | BPM match, bass duck, level automation, echo/reverb tail | rendered through portable engine controls |
| `smart-cfx` | one-knob filter/space/dub-echo chains on one track | rendered as wash/filter/sweep preset timeline |
| `beatfx-echo-out` | tail release before the incoming track starts | rendered through Beat FX release, then delayed deck-B start |
| `scratch` | vinyl, baby, chirp, scribble, backspin, transformer, and release behavior on one track | rendered through jog gestures/reverse/fader controls |
| `loop-and-cue` | quantized loop edges, roll, cue and hot-cue jumps before the incoming track starts | rendered through transport commands, then delayed deck-B start |
| `warm2-isolator` | 300 Hz/4 kHz fourth-order low/mid/high master isolation | rendered with the WARM2 engine profile |

“Auto fade”, “long cut”, “bass fade cut”, “drop cut”, and “snap back” should be represented as
named event timelines once their engine automation is implemented. The harness must not synthesize
those labels over a plain source track.

## Tooling boundary

`ParsoAcceptanceArtifacts` and the Python renderer are developer/test tooling. `ffmpeg` is used only
to encode the review MP4 and is not a SwiftPM dependency, vendored library, or runtime requirement
of the shipping products. The tool lives in its own package (`Tools/AcceptanceArtifacts`) so the
root package holds only libraries and its scheme builds for every Apple destination; macOS CI
remains responsible for native AVFoundation/AudioToolbox and device-style acceptance.
