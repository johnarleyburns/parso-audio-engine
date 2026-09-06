# CDJ-3000 (+ DJM-A9) parity research — the level above DDJ-FLX4

**Question:** what does PAE need added to be 100% software-equivalent to a Pioneer **CDJ-3000**
setup — the pro-booth tier above the FLX4 target — excepting proprietary hardware and
streaming services? And where the CDJ ecosystem ships built-in sample/FX content, what
Creative-Commons / public-domain material can fill that gap?

Scope note: a CDJ-3000 is a *player*, not a mixer. "CDJ-3000 equivalence" in practice means
**4 × CDJ-3000 players + a DJM-A9 (or DJM-V10) mixer + rekordbox Performance mode**, which is
the standard pro-booth. This doc treats that whole rig as the target, because that is what
"the level above the FLX4" means to a working DJ.

The FLX4 target (`docs/FLX4-feature-inventory.md`) is essentially "rekordbox Performance mode,
**2-deck** scope + Smart macros." The CDJ-3000 target is "rekordbox Performance mode, **4-deck**
scope + a pro mixer's FX/routing + the CDJ-3000's own player-side creative tools."

---

## 1. Where PAE already meets or exceeds the CDJ-3000

The player-side feature list is closer than expected — most of the CDJ-3000's transport,
loop and cue surface is already in `Deck`:

| CDJ-3000 feature | PAE today |
|---|---|
| 8 hot cues, per-cue colour | `setHotCue`/`jumpHotCue`/`deleteHotCue` (8) — colour is an app concern |
| 4-beat + 8-beat loop, fractional/odd loops | `autoBeatLoop(beats:)` takes any `Double` incl. `0.25`…`512` |
| Beat Jump 1/2–64 beats | `beatJump(beats:)`, `beatJumpSize`, `.beatJump` pad mode |
| Loop In/Out, Loop Adjust, Loop Move, Halve/Double | `loopIn/loopOut`, `adjustLoopIn/Out`, `loopMove`, `loopHalve/loopDouble` |
| 4 loop memories + Cue/Loop Call | `saveLoop`/`callLoop`, `setActiveLoop` |
| Loop Roll / Slip Loop | `loopRoll`, `slip` |
| Quantize with adjustable grid (1, 1/2, 1/4, 1/8) | `quantize` + `QuantizeResolution` (1/8 beat … 4 bars) |
| Master Tempo (key lock), tempo ranges | `keyLock`, `tempoRange` ±6/±10/±16/WIDE |
| Beat Sync + tempo-master deck | `sync()`, `setAsMaster()`, `EngineStats.masterBPM/downbeatPhase` |
| Slip mode | `slip` |
| Vinyl mode / scratch / pitch bend / frame + fast search | `vinylMode`, `jog*`, `frameSearch`, `fastSearch`, `nudge` |
| Key Shift pad mode (pitch-only semitone shift) | `.keyShift` pad mode, `pitchSemitones` |
| Per-deck stems (CDJ-3000 got this via firmware v3, 2023) | `armStems`/`setStemGain/Mute/Solo` (4 voices) |
| 96 kHz source files, all formats CDJ reads | `AudioFileReader` (FLAC/ALAC/WAV/AIFF/AAC/MP3/Ogg/Opus) |

So the player gap is **narrow and specific**, not structural — except for deck count.

---

## 2. Player-side gaps (CDJ-3000 `Deck` / engine)

### 2.1 Four decks, not two — the one structural change
`CParsoEngine` is a "two-deck render graph"; `DJEngine` exposes `deckA`/`deckB`; the mixer has
`channelA`/`channelB`. The CDJ-3000 workflow is **4 players → 4 mixer channels**, with any deck
assignable as tempo master and inter-deck quantized cueing across all four.

Needed:
- `CParsoEngine` render graph generalised to `N` decks (target 4; keep the allocation-free
  contract — fixed `N` at engine init is fine, no dynamic allocation).
- `DJEngine.decks: [Deck]` (keep `deckA`/`deckB` as aliases).
- `Mixer` → 4 `Channel`s.
- Tempo-master election across 4 decks; `sync()` phase-locks any deck to the elected master;
  master can also be "none / external clock" (see §3.1).
- Quantized hot-cue / loop triggering **relative to the master grid**, so dropping deck 3 on
  beat snaps to decks 1/2/4 — PAE quantizes to the deck's *own* grid today.

### 2.2 Key Sync + key-aware transpose + master key
CDJ-3000 firmware: **Key Sync** shifts the current track to sit harmonically with the master
deck's key; the display shows detected key and the shifted key; on-screen **Key Shift** ± is
independent of tempo.

PAE has `pitchSemitones` and a `.keyShift` pad mode, but no notion of "the track's analysed
key" feeding the engine, and no "match the master deck." `ParsoAudioAnalysis` already produces
`KeyResult` (Camelot / open-key) — it just isn't wired into `Deck`.

Needed:
- `Deck.detectedKey` (from the loaded `TrackAnalysis`).
- `Deck.keySync(to:)` — compute the minimal semitone shift (respecting Camelot adjacency /
  relative-major-minor) to align with a reference deck, apply via the existing key-lock path.
- `DJEngine.masterKey` surfaced in `EngineStats`.
- Optional: "key range" clamp so Key Sync never shifts more than ±N semitones (CDJ behaviour).

### 2.3 Reverse play + Slip Reverse
The CDJ-3000 has a **Reverse** (play backwards) and **Slip Reverse** (play backwards while the
shadow playhead keeps advancing; release → jump forward to where you'd have been). PAE has
**no reverse playback at all** — `effectiveRate` is always ≥ 0. This is a real DSP gap: the
varispeed interpolator and the loop/slip bookkeeping both assume forward motion.

Needed:
- Negative-rate path in the varispeed interpolator (Hermite/sinc already there — needs
  reverse addressing + buffer-edge handling).
- `Deck.reverse: Bool`; `Deck.slipReverse()` / release, reusing the existing slip shadow.

### 2.4 Vinyl Speed Adjust (Touch/Brake + Release/Start curves)
CDJ-3000: separate adjustable **brake time** (Touch/Stop — how fast it stops when you hit
pause / touch the platter) and **release/start time** (spin-up back to speed). PAE has binary
`jogTouchBegan`/`jogTouchEnded` (instant) and a `vinylBrake` *Beat FX*, but not the
transport-level configurable decel/accel envelope.

Needed: `Deck.brakeTime` / `Deck.releaseTime` (seconds), applied as a rate envelope on
pause/play and jog touch/release.

### 2.5 Smaller player items
- **Hot Cue Bank** — rekordbox groups hot cues into banks (A/B/C/D), so a track effectively
  has > 8. PAE has a fixed 8. Add `Deck.hotCueBank` (index) over an `[[HotCue?]]`.
- **Fade In / Fade Out cue points** — rekordbox stores cue points that auto-fade the channel
  in/out on trigger. PAE cues are instant. Add optional `fadeIn`/`fadeOut` durations to the
  cue model + a per-deck fade envelope the render graph applies.
- **Auto Cue level threshold** — PAE has `autoCue: Bool` but the CDJ sets the first cue at a
  configurable dB threshold (−36…−78 dB, or from the analysed first transient). Add
  `autoCueThresholdDB` and use the analysis onset if present.
- **Needle / playing-address seek** — `seek(toSample:)` exists; a normalised
  `seek(toFraction:)` + "jump to phrase/section" (analysis already yields sections) would
  match the touch-strip + phrase jump.
- **Loop Cut / Loop Quadruple beyond halve/double** — cheap: `loopResize(factor:)`.
- **Emergency Loop** — CDJ auto-loops from its RAM buffer if the source stalls. Relevant to
  `ParsoAudioStreaming`: when `CachingResourceLoader` underruns, the engine should fall into a
  beat-loop of the last buffered bar instead of dropping to silence. New: a "starvation loop"
  mode driven off `EngineStats.starvedFrames`.

---

## 3. Mixer-side gaps — DJM-A9 / DJM-V10 tier

This is the larger gap. PAE's `Mixer` is a faithful **FLX4 2-channel** mixer. A pro mixer adds:

### 3.1 Channels & routing
- **4 channels** (§2.1) — and for V10 parity, 6, but 4 is the CDJ-3000 standard.
- **Booth output** with independent level + (A9) a 2-band booth EQ / (V10) 3-band. New
  `BoothOut` bus tapping the master pre-master-limiter.
- **Master isolator** — a dedicated 3-band master EQ/isolator separate from `MasterOut.level`.
  New `MasterOut.isolator` (reuse `Isolator3Band`).
- **Channel fader curve** — PAE has `crossfaderCurve` but not per-channel fader curve
  (steep/linear). Add `Mixer.channelFaderCurve`.
- **Send / Return (external FX loop)** — the A9's big feature: a true insert/send point,
  per-channel or post-EQ, with return-to-master. PAE has no plugin insert seam at all. Add a
  `MixerInsert` protocol (RT-safe process callback) at defined tap points (per-channel
  post-EQ, master pre-limiter) so an app can host AU/AUv3 or an external hardware loop.
  This also future-proofs "bring your own effect," matching the BYO-codec philosophy.

### 3.2 Beat FX — expand the unit
`BeatFXUnit.Kind` has 14: `echo, echoOut, reverb, delay, multiTapDelay, flanger, phaser,
trans, roll, spiral, pitch, lowCutEcho, vinylBrake, helix`. The DJM-A9 set (also 14, but a
different 14) adds: **Ping Pong**, **Mobius (Saw/Tri, up + down)**, **Triplet Filter**,
**Triplet Roll**, **Enigma**, **Shimmer/Reverb variants**, **Space**. DJM-900NXS2 also has
**Sweep, Enigma, Helix** as full Beat FX.

Needed:
- Add `pingPong`, `mobiusUp`, `mobiusDown`, `tripletFilter`, `tripletRoll`, `enigma`,
  `shimmer` to the enum + kernels in `CParsoDSP`.
- **X-Pad**: a continuous 0…1 control that sweeps the current Beat FX's primary parameter
  (beat division / pitch / cutoff). New `BeatFXUnit.xpad: Double`.
- **Channel-select as a first-class control** (A9 made it a dedicated button) — `assign`
  already covers this; add per-channel + "MIC" as targets.
- **Quantized FX on/off** to the master grid.
- **FX Frequency filter** (DJM low/mid/high band-limit of the FX input) — `BeatFXUnit.band`.

### 3.3 Sound Color FX
`ColorFX` = `filter, space, dubEcho, sweep, noise, crush, pitch` — this **already matches** the
DJM-A9's six (filter/space/dub echo/sweep/noise/crush) plus pitch. Add:
- **Center Lock** (A9 "world's first") — a mode flag so the knob can't cross the hi/lo detent
  accidentally. `Channel.colorFXCenterLock: Bool`.
- **Sound Color FX parameter knob** (the second, "PARAMETER" control on the mixer) — depth /
  resonance per FX. `Channel.colorParameter: Double`.

### 3.4 Microphone section
`MicInput` is level + mute. DJM adds: **2-band mic EQ**, **talkover** (auto-ducks music by a
set dB when mic signal present, with adjustable threshold/level), **mic FX send**, **mic to
booth**. Needed: `MicInput.eqLow/eqHigh`, `MicInput.talkover` (`enabled`, `depthDB`,
`threshold`), route mic into the Beat FX assign targets.

### 3.5 Headphone / monitoring
`Monitoring` has PFL + cue/master blend + level. Add **Split Cue** (cue summed to mono in the
left ear, master mono in the right) — `Monitoring.splitCue: Bool`. (`cueMode` enum exists —
extend it.)

### 3.6 Metering
`EngineStats` has `renderLoad`/`starvedFrames`; channels/master expose `peakMeter`. A pro
mixer shows **per-channel + master full segmented meters with peak-hold** and the FLX4-style
**needle**. Mostly an app concern, but add peak-hold + true-peak (analysis has true-peak
already) to the published meter events.

---

## 4. Explicitly out of scope (proprietary hardware / streaming — per the question)

- **PRO DJ LINK** the wire protocol, link cable, Ethernet/USB device discovery, "on-air"
  tally, quantised link across physical CDJs. PAE's equivalent is an *in-process* shared
  master clock (§2.1, §3.1) — a `MasterClock` type any number of decks phase-lock to, and
  which can itself be slaved to an external `AsyncStream` of tempo/phase (so an app *could*
  bridge it to Ableton Link, which is a permissive option worth noting — Ableton Link SDK is
  GPLv2+ **or** a commercial licence, so it stays an app-side integration, not a PAE dep).
- CDJ-3000 hardware: 9" touch display, jog display, jog feel/torque, Touch Cue / Touch
  Preview, hardware pads, MIDI Out, the RJ-45/USB/SD slots, high-res audio DAC.
- **Streaming services** — Beatport / Beatsource / SoundCloud / TIDAL / Dropbox, KUVO,
  Cloud Direct Play, rekordbox CloudDirectPlay / mobile library sync. (SPEC §18 non-goal.)
- **DVS / timecode control vinyl** (SPEC §18 non-goal).
- rekordbox library management, browser, playlist/crate UI, cloud analysis (app concern).

---

## 5. Built-in sample & FX content — CC / public-domain sourcing

The CDJ ecosystem ships bundled content in three places PAE would need to fill:

1. **rekordbox Sampler** default content (drum kits, one-shots, loops, vocal shots, FX
   sweeps/impacts) — ~hundreds of files across a few banks + the Sequencer.
2. **DJM Beat FX** internal audio — almost none is actually sampled: Noise is a generator,
   Vinyl Brake / Spiral / Reverb / Echo are pure DSP. **Reverb / Space** is the one place a
   real **impulse response** materially raises quality.
3. **Vinyl-simulation textures** — needle-drop / surface-noise / brake for Vinyl Speed Adjust
   and the "78 rpm" flavour. Can be DSP-generated *or* sampled.

### 5.1 Licensing rule for sample content (mirrors the codec / stem-model policy)
- **CC0 / public domain** — ideal. Ship freely, no attribution obligation, no share-alike.
- **CC-BY 4.0** — acceptable *for a data pack* if a per-file `SAMPLES-NOTICE.md` manifest
  (source, author, licence, URL) ships with it. Attribution is a documentation task.
- **CC-BY-SA 4.0** — tolerable for a standalone sample pack (it is data, not linked code, so
  it does **not** infect PAE's MIT code the way GPL would), but the pack itself becomes
  share-alike. Prefer to avoid; never mix SA and non-SA in one distributed pack.
- **CC-BY-NC / "NC" of any kind — disqualified.** Same trap as the MUSDB18 stem models: a
  commercial app can't redistribute it. This rules out Philharmonia Orchestra samples, the
  BBC RemArc SFX library, most ccMixter "NC" packs, and CC-BY-NC Freesound entries.
- Follow the existing precedent: consider a **manifest + download-at-first-run** (like
  `scripts/download-fixtures.sh` / `ATTRIBUTION.md`) rather than committing audio blobs into
  the repo, so the tree stays licence-clean and small.

### 5.2 Recommended sources

**Tonal / instrument one-shots & phrases (for Sampler banks, Keyboard pad mode):**
- **VCSL — Versilian Community Sample Library** — **CC0**. Dozens of orchestral / world /
  keyboard / mallet / experimental instruments, professionally edited. The single best
  starting point. <https://github.com/sgossner/VCSL>
- **VSCO 2 Community Edition** (Versilian Studios Chamber Orchestra) — **CC0**. Full-ish
  orchestra; great for stabs / hits / pads.
- **Virtuosity Drums** (Versilian) — **CC0**. Acoustic drum kit multisamples.
- **University of Iowa Electronic Music Studios instrument samples** — freely usable
  (public-domain-style terms); clean chromatic single notes.

**Drums / electronic one-shots & loops (the core Sampler content):**
- **Freesound.org**, filtered to **CC0** and **CC-BY 4.0** only (the site exposes a licence
  facet; avoid CC-BY-NC and legacy "Sampling+"). Huge pool of kicks/snares/hats/percussion/
  risers/impacts/foley. Build a curated manifest.
- **CC0 drum-machine sample sets** — there are community CC0 recreations of 808/909/CR-78-style
  kits (e.g. the "hexawe" CC0 808 set and similar). **Roland's own 8/909 sample packs are NOT
  free** — verify provenance of any "808 samples" before shipping; treat casually-tagged
  packs the way the repo treats casually-MIT-tagged model checkpoints.
- **99Sounds / BPB "Cassette 808" and similar** — royalty-free; check the exact grant permits
  *redistribution as part of software* (some permit use-in-your-music but not re-bundling).
- **ccMixter "dig" sample packs** — per-track CC, some **CC0 / CC-BY**; verify each. Good for
  loops and (rights permitting) vocal shots.

**Vocal shots / spoken FX:**
- **LibriVox** (public domain) and **Voice of America** (US-gov public domain) for chopped
  spoken hits.
- ccMixter a cappella stems that are explicitly CC-BY / CC0 (many are BY-NC — filter hard).

**Impulse responses (Reverb / Space Beat FX, convolution):**
- **OpenAIR** (Univ. of York, openairlib.net) — mostly **CC-BY** real-space IRs (cathedrals,
  halls, tunnels, plate). Attribution manifest required; excellent quality.
- **EchoThief** — free for any use, ~1000 spaces.
- **Voxengo free IR pack** — free redistribution-friendly halls/rooms/plates.
- These feed a convolution Reverb kernel — a genuine quality step over the current Freeverb
  (`docs/SPEC.md §6`), and the DJM-A9's Reverb/Shimmer is the FX most worth this treatment.

**Vinyl / surface noise / needle textures:**
- **archive.org Great 78 Project** — many recordings are public domain / CC; lead-in/lead-out
  groove noise can be extracted for authentic crackle.
- Or **DSP-generate** (filtered noise + click model) — no licensing surface at all; likely the
  better call for Noise Color FX and Vinyl Brake, matching how the DJM actually does it.

**Sci-fi / textural FX (impacts, drones, sweeps):**
- **NASA audio collections** — public domain.
- Freesound CC0 field recordings / synth textures.

### 5.3 What does NOT need sampling (DSP-generate, no licence surface)
Noise Color FX, white/pink noise beds, sine/siren risers, Vinyl Brake / spin-up, Crush
(bitcrush), Sweep (filter), metronome click, Trans (gate), basic Roll. The DJM does these as
algorithms and so should PAE.

---

## 6. Suggested phasing

### Progress

- **C1 — done.** `CParsoEngine` render graph is `PE_MAX_DECKS`-wide (4), deck
  count fixed at `pe_create` time and clamped to 2…4. `pe_control` / `pe_stats`
  per-deck arrays widened; `validDeck` is engine-aware; crossfader "thru" assign
  generalised (even decks track the A side, odd the B side, preserving the
  classic 2-deck default). Swift: `DJEngine` / `HeadlessDJEngine` expose
  `decks: [Deck]` (+ `deckA…deckD` aliases), `Mixer` exposes `channels: [Channel]`
  (+ `channelA…channelD`); both take `deckCount: Int = 4`. `EngineStats` gains
  `deck{EffectiveBPM,BeatPhase,Synced}All` arrays covering every deck. Event
  routing in `HeadlessDJEngine.drainEvents` is index-generic. `MasterClock` as a
  standalone type + inter-deck grid-relative quantize is deferred to a C1b
  follow-up; the existing per-deck `sync()` / `setAsMaster()` already works for
  any of the 4. 5 new tests (`FourDeckTests`); full suite 252/252 green
  (`swift test -c release`).
- **C2 — done.**
  - *C2a Key Sync:* `KeyResult.transposed(by:)` / `.shortestShift(to:)`;
    `Deck.detectedKey` / `soundingKey` / `keySync(to:)` / `keyReset()` /
    `keySyncRange`; `DJEngine.masterKey`. 7 tests.
  - *C2b Reverse:* `PE_CMD_SET_REVERSE`; negative-rate transport in
    `renderChunk` (forward-advancing slip shadow, reverse loop wrap, stop at
    frame 0); `Deck.reverse`, `slipReversePress()/Release()`. Key-lock is
    bypassed while reversed. 4 tests.
  - *C2c Vinyl Speed Adjust:* `PE_CMD_VINYL_SPEED`; per-deck `motorLevel`
    easing to `motorTarget` at brake / spin-up rates, scaling the transport
    increment; pause/vinyl-touch brake to a coast-stop, play/release spin up;
    key-lock bypassed mid-ramp (the turntable pitch drop). `Deck.brakeTime` /
    `spinUpTime`. 3 tests.
  Full suite 266/266 green.
- **C3 — done.**
  - *C3a:* `FaderCurve` {linear, smooth, sharp} on `Channel.faderCurve`
    (Swift-side taper, `.linear` byte-identical to pre-C3). Master isolator —
    `pe_control.master_eq_*` + a `pd_eq3` on the master bus post-fader /
    pre-limiter; `MasterOut.isolatorLow/Mid/High`. 4 tests.
  - *C3b:* Booth output — `pe_render_booth` applies `MasterOut.boothLevel` +
    `boothEq{Low,Mid,High}` to a snapshot of the last rendered master;
    `HeadlessDJEngine.renderBooth(frames:)`. 3 tests.
  - *C3c:* Insert / send-return seam — `pe_insert_fn` + `pe_set_insert` at
    5 points (`PE_INSERT_CH0…CH3`, `PE_INSERT_MASTER`); Swift `RealtimeInsert`
    protocol + `Mixer.setInsert(_:at:)` with an `InsertPoint`. RT-thread
    callback, app owns RT-safety (BYO-effect, mirrors BYO-codec). 3 tests.
  Full suite 276/276 green.
- **C4 — done.** Beat FX: 6 new kinds (`pingPong, mobius, tripletFilter,
  tripletRoll, enigma, shimmer` → 20 total) as approximations on the existing
  delay-line engine (same quality bar as the pre-existing kernels; a proper DSP
  pass is future work). X-Pad — `BeatFXUnit.xPad: Double?` sweeps the beat
  division exponentially (1/16…4) when touched. `beatfx_band` / `BeatFXUnit.Band`
  band-limits the FX **send** (dry path untouched). Sound Color FX: `Channel.
  colorParameter` (0…1, 0.5 neutral / byte-identical to pre-C4) scales effect
  intensity + filter resonance; `Channel.colorFXCenterLock` latches the knob to
  one side (DJM-A9 Center Lock), enforced Swift-side. 6 tests; full suite
  282/282 green.
- **C5 — done.** Mic strip: `pe_control.mic_eq_low/high` (2-band, via a `pd_eq3`
  in a mic pre-pass), `mic_talkover_*` (block-RMS gate → smoothed music duck),
  `mic_fx_on` (mic rides in `channelSum` for the all/master Beat FX assigns).
  `MicInput.eqLow/eqHigh/talkover/talkoverDepthDB/talkoverThreshold/routeToFX`.
  `Monitoring.splitCue` convenience over `.splitOutput`. `Channel` / `MasterOut`
  `peakHold` (instant attack, ×0.92/event decay). 5 tests; full suite 287/287.
- **C6 — done.** `Deck.hotCueBank` (0…3) over a `[[TimeInterval?]]` store,
  re-points the engine's 8 slots on switch (rekordbox A/B/C/D). Fade-in cues:
  `setHotCue(_:fadeIn:)` + `PE_CMD_HOTCUE_JUMP` f0 drives a `DeckState.cueFade`
  one-shot ramp 0→1. `Deck.autoCueThresholdDB` — Auto Cue prefers the first
  analysed onset, else scans the buffer for the first sample over threshold and
  places an integer-sample cue. `Deck.loopResize(_:)` (arbitrary scale factor).
  `Deck.emergencyHold(beats:)` — app-callable instant beat-loop for a stream
  underrun (PAE's resident-buffer engine has no starvation of its own). 6 tests;
  full suite 293/293.
- **C7 — done (a + b); C7c is a follow-up.**
  - *C7a:* `SampleLibrary/manifest.json` + `scripts/download-samples.sh` +
    `SAMPLES-NOTICE.md` — the CC0/CC-BY pack list (VCSL, VSCO 2 CE, Virtuosity
    Drums; OpenAIR / EchoThief / Voxengo IRs), fetched-not-committed, mirroring
    the fixture-download pattern.
  - *C7b:* `pd_fdnverb` — an 8-line feedback-delay-network reverb (orthonormal
    Hadamard feedback, per-line one-pole damping, slow delay modulation), a
    real quality step above the Freeverb topology, RT-safe and allocation-free.
    Wired as a **master reverb send** (`pe_control.master_reverb_*`,
    post-isolator / pre-limiter, stereo tail); `MasterOut.reverbSend/reverbSize/
    reverbDecay/reverbDamp`, `send 0` bit-transparent. This is the "synthetic
    fallback" path — it needs no bundled audio.
  - *C7c (not done):* a partitioned-FFT **convolution** kernel that runs the
    real OpenAIR / EchoThief IRs, and routing the DJM Reverb / SHIMMER Beat FX
    kinds through `pd_fdnverb` / the convolver instead of the delay-line
    approximation. Left as a follow-up — the FDN already delivers the audible
    improvement; convolution is the enhancement on top.

### Table

| Phase | Scope | Status |
|---|---|---|
| **C1** | `CParsoEngine` → 4 decks / 4 channels; `MasterClock`; inter-deck quantize | ✅ done (MasterClock type + grid-relative inter-deck quantize → C1b) |
| **C2** | Key Sync / detected-key wiring / master key; reverse + Slip Reverse; Vinyl Speed Adjust | ✅ done |
| **C3** | Mixer pro tier: booth bus, master isolator, channel fader curve, `MixerInsert` send/return seam | ✅ done |
| **C4** | Beat FX expansion (Ping Pong / Mobius / Triplet* / Enigma / Shimmer) + X-Pad + FX band filter; Sound Color FX Center Lock + parameter knob | ✅ done (new kinds are approximations; DSP pass → C4b) |
| **C5** | Mic section (EQ / talkover / FX send); Split Cue; peak-hold / true-peak metering | ✅ done |
| **C6** | Small player items: hot-cue banks, fade-in/out cues, auto-cue threshold, loop cut/×4, emergency/starvation loop | ✅ done |
| **C7** | Convolution Reverb kernel + curated CC0/CC-BY IR manifest; Sampler default-content manifest + downloader (`SAMPLES-NOTICE.md`) | ✅ C7a manifest + C7b FDN reverb done; partitioned-FFT convolution → C7c |

Nothing here breaks the MIT / permissive-only / RT-safety constraints. The only genuinely new
architectural piece is the **N-deck render graph + shared master clock** (C1); everything else
is additive API on the existing engine, plus DSP kernels and a content-manifest pipeline that
reuses the fixture-download pattern already in the repo.

---

## Sources

- [Pioneer DJ — CDJ-3000 announcement](https://www.pioneerdj.com/en/news/2020/cdj-3000-professional-dj-multi-player/)
- [We Are Crossfader — CDJ-3000 review/guide](https://wearecrossfader.co.uk/blog/pioneer-cdj-3000-review/)
- [Digital DJ Tips — CDJ-3000 review](https://www.digitaldjtips.com/reviews/pioneer-dj-cdj-3000/)
- [Pioneer DJ — DJM-A9 announcement](https://www.pioneerdj.com/en/news/2023/djm-a9-4-channel-professional-dj-mixer/)
- [We Are Crossfader — DJM-A9 review](https://wearecrossfader.co.uk/blog/pioneer-dj-djm-a9/)
- [VCSL — Versilian Community Sample Library (CC0)](https://github.com/sgossner/VCSL)
- [Versilian Studios — VCSL](https://versilian-studios.com/vcsl/)
- [OpenAIR impulse response library](https://sonicfield.org/openair-a-collective-library-of-impulse-responses)
- [Voxengo free impulse responses](https://www.voxengo.com/impulses/)
