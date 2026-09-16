# Turntablism API

This guide maps the turntablism vocabulary to the portable `ParsoDJEngine`
control API. The API is control-side and `@MainActor`; the audio render remains
in the shared real-time engine. A UI should feed touch samples from a display
link or gesture callback and should not schedule work from the audio callback.

## Shared setup

Load an analyzed `PCMBuffer` into a deck, then choose vinyl mode for record
movement. In vinyl mode, touching the platter temporarily takes over the
playhead and releasing it resumes playback if the deck was playing before the
touch.

```swift
@MainActor
func beginTurntablism(engine: DJEngine) {
    let deck = engine.deckA
    let channel = engine.mixer.channelA

    deck.vinylMode = true
    channel.fader = 1
    deck.jogTouchBegan()
    deck.jogMoved(deltaSamples: 1_600)
    deck.jogMoved(deltaSamples: -1_600)
    deck.jogTouchEnded()
}
```

`deltaSamples` is signed source-frame travel. Positive values move forward and
negative values move backward. For a phone or iPad, use
`MobilePlatterGestureMapper` and `MobilePlatterGestureSession`:

```swift
@MainActor
func connectPlatter(session: MobilePlatterGestureSession,
                    position: Double,
                    time: TimeInterval,
                    pressure: Double) {
    if !session.isActive {
        _ = session.begin(at: position, timestamp: time, pressure: pressure)
    } else {
        _ = session.update(to: position, timestamp: time, pressure: pressure)
    }
}
```

Always end the session on touch-up, cancellation, or gesture failure:

```swift
session.end()
```

The session handles the platter seam, velocity, pressure, and touch lifecycle.
Pressure `0` holds the record without moving it; values between `0` and `1`
scale the scratch movement.

For scratch cuts, use the deck's channel fader. `1` is open and `0` is closed:

```swift
engine.mixer.channelA.fader = 1       // sound open
engine.mixer.channelA.fader = 0       // sound closed
```

Use the mixer crossfader for deck-to-deck performance:

```swift
engine.mixer.crossfader = -1          // channel A
engine.mixer.crossfader = 1           // channel B
engine.mixer.crossfaderCurve = .sharp
```

## Scratch Bank patterns

The built-in catalog contains ready-to-trigger versions of every named scratch
in this guide. Assign patterns to the eight Scratch Bank slots and trigger them
on a deck:

```swift
@MainActor
func installScratchBank(_ engine: DJEngine) {
    let patterns: [ScratchPattern] = [
        .baby, .scribble, .drag, .forward,
        .backward, .chirp, .flareOneClick, .flareTwoClick
    ]
    for (slot, pattern) in patterns.enumerated() {
        _ = engine.scratchBank.assign(pattern, to: slot)
    }
    _ = engine.triggerScratch(slot: 0, on: engine.deckA)
}

@MainActor
func stopScratch(_ engine: DJEngine) {
    engine.stopScratch(on: engine.deckA)
}
```

The remaining built-ins are `.orbit`, `.transform`, `.crab`, `.tear`,
`.twiddle`, and `.boomerang`. Scratch Bank playback uses the same jog and
channel-fader controls as a live gesture. Pass `looping: true` to repeat a
pattern until `stopScratch` is called.

For user-created routines, record the same events a gesture coordinator sends:

```swift
@MainActor
func recordScratchTake() -> ScratchPattern? {
    let recorder = ScratchPatternRecorder(name: "my take", technique: .baby)
    recorder.start()
    _ = recorder.record(at: 0.00, deltaSamples: 1_600, label: "forward")
    _ = recorder.record(at: 0.14, deltaSamples: -1_600, label: "backward")
    _ = recorder.record(at: 0.28, deltaSamples: 1_600, label: "forward")
    _ = recorder.record(at: 0.42, deltaSamples: -1_600, label: "backward")
    return recorder.finishRecognized()
}
```

`ScratchTechniqueRecognizer` provides a deterministic initial label. Keep the
captured event stream as the source of truth and let the user correct the label
in `ScratchPatternEditor` when a take is ambiguous.

## Foundation scratches

### Baby scratch

Keep the channel fader open and alternate equal forward/backward platter
movements. There are no fader clicks.

```swift
channel.fader = 1
deck.jogTouchBegan()
deck.jogMoved(deltaSamples: 1_600)
deck.jogMoved(deltaSamples: -1_600)
deck.jogMoved(deltaSamples: 1_600)
deck.jogMoved(deltaSamples: -1_600)
deck.jogTouchEnded()
```

Use `ScratchPattern.baby` for a reusable four-stroke version.

### Scribble

Use the same open-fader topology as Baby, but send many smaller alternating
movements at a high touch-update rate. `ScratchPattern.scribble` is the
eight-stroke example.

### Drag / Strobe

Keep the fader open and send a large movement over a longer wall-clock
interval, using several small `jogMoved` updates rather than one jump. A slow
reverse release can finish the drag. `ScratchPattern.drag` provides the
portable preset.

### Forward and Backward

For Forward, open the fader during the forward stroke and close it before the
record returns. For Backward, use the same cut topology in the reverse
direction:

```swift
channel.fader = 1
deck.jogTouchBegan()
deck.jogMoved(deltaSamples: 2_000)
channel.fader = 0
deck.jogTouchEnded()
```

Use `ScratchPattern.forward` or `.backward` when a deterministic pad action is
preferred.

## Fader-controlled scratches

### Chirp

Start open, move forward, close the channel fader at the end of the forward
stroke, then move backward and reopen for the return. Use
`ScratchPattern.chirp` or reproduce that fader sequence around `jogMoved`.

### Flare

Keep the record moving while briefly toggling the fader closed and open. The
catalog exposes `.flareOneClick` and `.flareTwoClick`; `.flare` is the compact
two-click-compatible entry. A click is a deliberate `fader = 0` followed by
`fader = 1`, not an audio impulse added to the signal.

### Orbit

Perform a flare topology across both directions: forward movement, a click,
backward movement, another click, and a final forward return. Trigger
`ScratchPattern.orbit` or record the same alternating direction/click topology.

### Transform

Move the record slowly in one direction while tapping the fader repeatedly
off/on. The motion continues through the taps; the taps create the robotic
stutter. `ScratchPattern.transform` contains three taps over one slow stroke.

### Crab

Hold one platter stroke and make a rapid sequence of short fader taps, usually
four finger-style taps. The API representation is the same as Transform—a
continuous platter movement plus fader state events—but Crab uses a shorter,
denser click burst. Use `ScratchPattern.crab` as the reference timing.

## Tear and combination scratches

### Tear

Do not cut the fader. Split a single record stroke into two movements with a
short pause or a change in movement size, then repeat in reverse. The built-in
`.tear` pattern demonstrates this four-event topology.

### Twiddle

Start a record stroke, make two rapid fader clicks, and finish with the return
stroke. Use `.twiddle`; its event stream keeps the clicks separate from the
platter movement so an editor can retime them.

### Boomerang

Subdivide the forward movement into two pieces, click between them, then
subdivide the backward movement into two pieces with the same rhythmic shape.
Use `.boomerang` for the symmetric four-stroke/fader-click routine.

## Turntable manipulation

### Pitch bending / platter pressure

Set `vinylMode` to `false` for a non-vinyl jog. Jog movement then bends playback
rate without seeking the record position:

```swift
deck.vinylMode = false
deck.jogTouchBegan()
deck.jogMoved(deltaSamples: 240, pressure: 0.35)
deck.jogMoved(deltaSamples: -120, pressure: 0.35)
deck.jogTouchEnded()
```

For button or tempo-wheel nudges, use the bounded temporary rate control:

```swift
deck.nudge(+0.02)
deck.nudge(0)       // return to the normal playback rate
```

### Motor-off effect

Set a nonzero brake time and pause the deck. Set spin-up time if the deck will
be restarted with a gradual motor ramp:

```swift
deck.brakeTime = 2.0
deck.spinUpTime = 1.0
deck.pause()
// later:
deck.play()
```

Zero values give an instant stop/start. The values are clamped by the deck to
the supported range.

### Hydroplane

Use vinyl mode and feed small, smooth movements with light pressure. Do not
alternate large signed jumps; the effect comes from continuous friction-like
slowing while the record remains engaged:

```swift
deck.vinylMode = true
deck.jogTouchBegan(pressure: 0.25)
deck.jogMoved(deltaSamples: 80, pressure: 0.25)
deck.jogMoved(deltaSamples: 60, pressure: 0.18)
deck.jogMoved(deltaSamples: 35, pressure: 0.10)
deck.jogTouchEnded()
```

For a real touch surface, pass the measured pressure through
`MobilePlatterGestureSession` instead of hard-coding these values.

### Tone play

Store several cue points, jump to the selected cue, and vary pitch while
re-triggering it. The keyboard pad mode gives a ready-made chromatic surface;
direct control can use `pitchSemitones` and `jumpHotCue`:

```swift
deck.setHotCue(0)
deck.jumpHotCue(0)
deck.pitchSemitones = -3
deck.jumpHotCue(0)
deck.pitchSemitones = 0
```

For a pad UI, select `.keyboard`, set `keyboardCueIndex`, then call
`padPress(_:)` and `padRelease(_:)`; releasing the pad restores the native
pitch.

## Multi-deck techniques

### Beat juggling

Load two copies of a break, or two compatible tracks, into `deckA` and
`deckB`. Store matching beat positions as hot cues, make one deck the master,
sync the other, and alternate cue jumps while cutting the crossfader:

```swift
deckA.setAsMaster()
deckB.sync()
deckA.setHotCue(0)
deckA.setHotCue(1)
deckB.setHotCue(0)
deckB.setHotCue(1)

deckA.play()
deckB.play()
engine.mixer.crossfader = -1
deckA.jumpHotCue(0)
engine.mixer.crossfader = 1
deckB.jumpHotCue(0)
```

For a pad-driven implementation, use `.hotCue` mode and alternate
`padPress(_:)` on the two decks. Quantized jumps are enabled with
`deck.quantize = true`; use `quantizeJumps` when jumps should wait for the next
beat boundary.

### Phasing / flanging

Load the same source section into both decks, start them aligned, and introduce
a small temporary speed difference on one deck. Return the nudge to zero after
the phase offset is audible:

```swift
deckA.setAsMaster()
deckB.sync()
deckA.play()
deckB.play()
deckB.nudge(+0.003)
deckB.nudge(0)
```

Keep both channels open and blend them with the crossfader centered or with
both channel faders raised. The controlled fractional-rate drift creates the
moving comb-filter/metallic sweep; a second copy of the same track is required
for this effect.

## Related performance controls

These controls commonly surround a turntablism routine:

```swift
deck.reverse = true                 // latching reverse
deck.slipReversePress()             // momentary reverse with slip shadow
deck.slipReverseRelease()
deck.frameSearch(frames: 2_048)     // precise source-frame search
deck.fastSearch(seconds: -0.25)     // time-based search
deck.autoBeatLoop(beats: 0.25)      // roll / stutter loop
deck.loopRollRelease()
```

Use `deck.slip = true` when loops or cue work should resume at the hidden
playhead after the routine. Use `engine.mixer.beatFX` for tempo-synced echo,
roll, reverb, flanger, or phaser tails around a scratch or transition.

## Out of scope

This API does not claim to implement physical turntable hardware integration,
MIDI/HID mapping, motorized platter feedback, or DVS/timecode decoding. Those
are platform/application layers above this control surface. The portable engine
does provide the software gesture, timing, resampling, fader, cue, loop, and
multi-deck primitives needed by such an application.
