# DDJ-FLX4 Feature Inventory — Equivalence Target

The functional target for `parso-audio-engine`: the Pioneer DDJ-FLX4 as used with rekordbox
(Performance mode), scoped to its 2-deck / 2-channel workflow.

**Legend** — `[CORE]` software must replicate · `[RB]` rekordbox software feature surfaced through
the controller (replicate the behavior) · `[HW]` hardware/physical only — **N/A** for a software mixer.

## Decks & transport
- `[CORE]` 2 independent decks (mirror L/R)
- `[CORE]` Play/Pause; Cue (temp cue): set on pause, hold-to-preview, release-to-cue; stutter start
- `[CORE]` Return to start; load to specific deck; instant doubles
- `[CORE]` Playhead/elapsed/remaining; end-of-track warning
- `[RB]` Per-deck waveform, beatgrid, phase meter

## Tempo / pitch / sync
- `[CORE]` Tempo fader; ranges ±6/±10/±16/WIDE; Master Tempo (key lock)
- `[RB]` Beat Sync (BPM + beatgrid + phase); master-deck assignment
- `[CORE]` Tempo reset; BPM display; tap/re-analyze

## Jog (behaviors — jog hardware is `[HW]`)
- `[CORE]` Scratch (vinyl mode on); pitch bend (vinyl mode off); vinyl-mode toggle
- `[CORE]` Frame search; fast search (shift+jog); touch-pause / release-play

## Looping
- `[CORE]` Manual in/out; loop in/out adjust; reloop/exit; auto 4-beat loop; halve/double; move
- `[RB]` Saved loops; active loop; beat-loop sizes; loop roll (slip-style)

## Cueing & hot cues
- `[CORE]` Temporary cue
- `[RB]` 8 hot cues/deck (set/jump/delete); color labels; cue/loop call; auto-set first cue

## Performance pads — 8 modes (rekordbox)
- `[RB]` Hot Cue · Keyboard (pitch play) · Pad FX 1 · Pad FX 2 · Beat Jump · Beat Loop · Sampler (16 slots) · Key Shift

## Mixer (×2 channels)
- `[CORE]` Trim/gain; channel fader; VU meter; crossfader assignment; fader start
- `[CORE]` 3-band EQ (High/Mid/Low, full-kill)
- `[RB]` Sound Color FX knob (default Filter; assignable: Space, Dub Echo, Sweep, Noise, Crush, Pitch)

## Beat FX (one selectable unit)
- `[RB]` Select one FX; beat/time division; level/depth; on/off; assign ch1/ch2/both/master; release FX; tempo-synced
- Representative FX: Echo, Echo Out, Low Cut Echo, Multi-Tap Delay, Delay, Reverb, Spiral, Trans, Enigma/Helix, Flanger, Phaser, Pitch, Slip Roll, Roll, Vinyl Brake

## Smart features (FLX4 differentiators)
- `[RB]` Smart Fader (assisted transition: auto BPM match + EQ-low + level automation + echo/reverb tail)
- `[RB]` Smart CFX (one-knob multi-effect presets)

## Master / monitoring / mic
- `[CORE]` Master level + limiter + master cue + VU; `[HW]` RCA out
- `[CORE]` Headphone: per-channel PFL, master cue, cue/master blend, headphone level; `[HW]` 3.5 mm jack
- `[CORE]` Mic level; mic summed to master + record + stream (mic-over-USB); `[HW]` ¼" jack

## Global
- `[RB]` Quantize; slip; auto cue; independent deck state
- `[HW]` Bluetooth audio-in (mobile rekordbox)

## Track analysis (rekordbox engine)
- `[RB]` BPM, beatgrid (editable), key, waveform, phrase/structure, auto-gain (loudness)

## Recording / streaming
- `[RB]` Record mix (master + mic); `[CORE]` export file; single-device livestream path
- `[RB]` Streaming services — **out of scope** (licensing)

## Hardware-only (N/A for a software mixer)
- `[HW]` Jog wheels, pad hardware, RCA/¼"/3.5 mm jacks, built-in soundcard, USB bus power, Bluetooth-in

---

**Bottom line:** ~80% of the FLX4's feature list is rekordbox Performance mode; the equivalence
target is *"rekordbox Performance mode, 2-deck scope"* + the two Smart macros. Analysis (BPM, key,
structure) has no permissive library and is implemented in-house per `docs/SPEC.md §5`.
