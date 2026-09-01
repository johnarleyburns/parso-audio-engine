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
swift run ParsoAcceptanceArtifacts \
  --fixture gostreyshen_world \
  --scenario waveform \
  --max-seconds 30 \
  --output-dir artifacts/acceptance/gostreyshen
python3 scripts/render-acceptance-video.py \
  --audio artifacts/acceptance/gostreyshen/gostreyshen_world-waveform.wav \
  --analysis artifacts/acceptance/gostreyshen/gostreyshen_world-waveform.json \
  --output artifacts/acceptance/gostreyshen/gostreyshen_world-waveform.mp4

# Phrase/structure review: render the entire song.
swift run ParsoAcceptanceArtifacts \
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
of the Apple/Linux products. Linux can therefore generate and inspect the same review artifacts;
macOS CI remains responsible for native AVFoundation/AudioToolbox and device-style acceptance.
