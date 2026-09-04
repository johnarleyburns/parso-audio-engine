# Phase 6 — DJ engine convergence (Tonearm adopts `ParsoDJEngine`)

Tracking `docs/UNIFICATION_PLAN.md` §6 and `current_status.md`. Phases 0–5 are
complete: cache, EQ/normalization, decoders and analysis DSP are shared; Tonearm
consumes `ParsoAudioAnalysis`. Phase 6 was deliberately deferred (§6 recommendation:
"option 3 now, option 1 as the destination — decide after Phase 5").

This plan assumes **option 1**: Tonearm adopts PAE's `ParsoDJEngine` and deletes its
own GPLv3 `Sources/DJ/Engine/*`. PAE's C++ allocation-free renderer plus its
DDJ-FLX4-equivalence acceptance suite are "the whole point of PAE" and are kept.

## Gating precondition (decide before starting 6a)

Phase 6 is only worth doing **if Platterhead DJ ships on PAE**. It touches exactly one
app, the DJ engine is where a bad merge costs the most, and it moves ~4k shipping,
tested lines onto a different renderer. If Platterhead DJ is not committed to PAE, or
its requirements are still soft, **option 3 (keep deferring) remains correct** — the
two engines can coexist indefinitely at zero ongoing cost because nothing else in the
codebase depends on either. See "If you pick option 3 instead" at the end.

## The seam that makes this tractable

The Tonearm DJ UI (`Sources/DJ/Features/Workspace/*`) never touches the engine. It
talks to a `WorkspaceEngine` protocol (~40 methods) at the top of
`Sources/DJ/Features/Workspace/WorkspaceModel.swift`; `PerformanceEngine` conforms via
`extension PerformanceEngine: WorkspaceEngine {}`. `WorkspaceModel`, MIDI
(`Sources/DJ/Hardware/*`) and recording orchestration (`Sources/DJ/Recording/*`) sit
**above** that protocol. Option 1's adapter layer is therefore a single new type:
a second `WorkspaceEngine` conformer backed by PAE's `DJEngine`. Nothing above the
protocol should change.

---

## Sub-phases

### 6a — Parity audit

Produce a field-by-field table (a checked-in `docs/phase6-parity.md` or an appendix
here) mapping every entry of:

- the `WorkspaceEngine` protocol (`WorkspaceModel.swift`),
- `RTCommand.Tag` (`Sources/DJ/Engine/RTCommand.swift`),
- the `PerformanceEngine` public surface (`Sources/DJ/Engine/PerformanceEngine.swift`),

onto:

- `DJEngine` / `HeadlessDJEngine` / `Deck` / `Mixer` / `Channel` / `BeatFXUnit` /
  `MasterOut` / `Sampler` / `MicInput` / `Monitoring` / `MixRecorder`
  (`Sources/ParsoDJEngine/ParsoDJEngine.swift`),
- the C API `pe_*` + `pe_control` + `pe_cmd_type` + `pe_event`
  (`Sources/CParsoEngine/include/parso_engine.h`).

Per row: **exists** / **shaped-differently** / **missing**; and a **disposition**:
_port into PAE (MIT-relicensed, C++ or Swift)_, _adapt in the Tonearm adapter_, or
_drop_ (with rationale).

Starting table (verified against the code on this branch — expand and correct during
6a):

| WorkspaceEngine / RTCommand | PAE equivalent | State | Disposition |
|---|---|---|---|
| `start()` / `stop()` | `DJEngine.start()` / `.stop()` | exists | adapter |
| `masterSample: Int64` | — (no absolute master frame counter surfaced) | **missing** | port into PAE: monotonic master-frame counter in `pe_engine`, readable via a `pe_stats` poll or `pe_event` |
| `sampleRate: Double` | `DJEngine.sampleRate` | exists | adapter |
| `bufferPeriodMillis: Double` | derivable from `maxFramesPerRender / sampleRate` | shaped-differently | adapter (compute) |
| `limiterCeiling: Float?` | `MasterOut.limiterCeilingDB` (dB) | shaped-differently | adapter (dB→linear, nil when limiter bypassed — PAE has no bypass state, add one) |
| `deckRate(_:) -> Double` | `Deck.updatePlaybackRate` (private); `tempoPercent`/`tempoRange` | **missing** (no public effective-rate getter) | port into PAE: `Deck.effectiveRate: Double` |
| `telemetry: AsyncStream<EngineTelemetry>` | `pe_poll_events` (PLAYHEAD/PEAK/STATE) + `@MainActor` props | shaped-differently | adapter synthesizes the stream; **but** several fields are missing at source (see 6b telemetry) |
| `sampleTelemetry()` / `pushTelemetry()` | — | shaped-differently | adapter (build `EngineTelemetry` from polled state) |
| `load(_:source: DeckSource)` | `Deck.load(_ analysis: TrackAnalysis, buffer: PCMBuffer)` → `pe_deck_set_buffer` | shaped-differently | adapter bridges `DeckSource` (raw-ptr pure value + `DeckGrid`) → `PCMBuffer` + `TrackAnalysis`; **confirm `pe_deck_set_buffer` is RT-safe for a live swap** (see risks) |
| `play` / `pause` | `Deck.play()` / `.pause()` | exists | adapter |
| `cue` / `releaseCue` | `Deck.cuePlayPress()` / `.cuePlayRelease()` | exists | adapter |
| `seek(_:toSample:quantized:)` | `Deck` has `jumpToCue`/`returnToStart`/`fastSearch`; `PE_CMD_SEEK` exists in C API but not surfaced as sample-accurate on `Deck` | shaped-differently | port into PAE: `Deck.seek(toSample:quantized:)` mapping to a sample-accurate `PE_CMD_SEEK` |
| `setCue(_:atSample:)` | `Deck.setCue()` (captures current playhead only) | shaped-differently | port into PAE: `setCue(atSample:)` |
| `triggerHotCue(_:atSample:)` | `Deck.setHotCue(index)` / `jumpHotCue(index)` (index-keyed store) | shaped-differently | adapter keeps a sample→slot map; or port a sample-addressed hot-cue jump |
| `setLoopRange(_:start:end:)` (track samples) | `Deck.loopIn()`/`loopOut()` (playhead-based, `TimeInterval`) | shaped-differently | port into PAE: sample-addressed `Deck.setLoop(start:end:)` → `PE_CMD_SET_LOOP` (already in `pe_cmd_type`, wire the sample path) |
| `setLoop(_:beats:)` | `Deck.autoBeatLoop(beats:)` | exists | adapter |
| `exitLoop` | `Deck.reloopExit()` / `setActiveLoop(false)` | exists | adapter |
| `setQuantize(_:resolution:)` (global) | `Deck.quantize: Bool` (per-deck, no resolution) | shaped-differently | port into PAE: `QuantizeResolution` grain on `Deck`; adapter fans the global toggle to both decks |
| `setRate(_:rate: Float)` (ratio) | `Deck.tempoPercent` + `tempoRange` | shaped-differently | adapter converts ratio↔percent, or port a direct `Deck.setRate(_:)` |
| `setKeyLock(_:locked:)` | `Deck.keyLock: Bool` | exists | adapter |
| `setKeyShift(_:semitones: Float)` | `Deck.pitchSemitones: Double` | exists | adapter (Float↔Double) |
| `sync(_:to:barSync:)` | `Deck.sync()` + `setAsMaster()` (no bar-sync flag) | shaped-differently | port into PAE: bar-sync option on `PE_CMD_SYNC` |
| `unsync` | — (`Deck.sync()` toggles; no explicit unsync) | shaped-differently | port into PAE: explicit `Deck.unsync()` |
| `isSynced(_:) -> Bool` | `Deck.isMaster` only | **missing** | port into PAE: per-deck `synced` state (also needed by telemetry) |
| `setEQKnobs(_:low:mid:high:)` (knob) | `Channel.eqLow/eqMid/eqHigh` (dB, `-inf` == kill) | shaped-differently | adapter maps knob curve → dB; **verify kill behaviour + curve** (mixer DSP equivalence, 6d) |
| `setFilter(_:knob:)` (dedicated sweep, −1…1) | `Channel.colorFX = .filter` + `colorAmount` (−1…1) | shaped-differently | adapter selects the `.filter` ColorFX; verify the sweep curve matches Tonearm's |
| `setChannelFader(_:gain:)` | `Channel.fader` (0…1) | exists | adapter (`Channel.trim` stays default) |
| `setCrossfader(_:curve:)` | `Mixer.crossfader` (−1…1) + `Mixer.Curve {smooth,linear,sharp}` | exists | adapter; `CrossfaderCurve` enum parity confirmed (`smooth`/`linear`/`sharp`) — verify curve _math_ in 6d |
| `setEchoEnabled/Beats/Depth/Feedback(_:)` (per-deck §35A, with **feedback**) | `BeatFXUnit` (single bus unit: `kind`/`beats`/`depth`/`assign`/`isOn` — **no per-deck instance, no feedback param**) | **missing** | port into PAE: per-deck echo line (see 6b) |
| `armStemSet` / `setStemGain` / `setStemMute` / `setStemSolo` | `Sampler` slots only — **no per-deck stem voices** | **missing** | port into `CParsoEngine` (see 6b — riskiest item) |
| `startRecording() -> URL` / `stopRecording() -> RecordingOutput?` / `isRecording` / `droppedRecordFrames` / `interrupt…` / `resume…` | `MixRecorder.start()` / `append(_:)` / `stop()` (manual buffer feed, no tap, no segments, no interruption model) | shaped-differently | adapter drives `MixRecorder` from a render tap; **M4A-joiner / segment / interruption parity** vs `Sources/DJ/Recording/*` must be checked |
| `setHeadphoneCue(_:enabled:)` | `Channel.cuePFL: Bool` | exists | adapter |
| `setCueMode(_:)` (`off`/`splitOutput`/`cueInPlace`/`multichannel`) | `Monitoring.masterCue` + `cueMasterMix` + `pe_render_monitor` — **no `CueMode` concept**, in particular no mono-L/mono-R split-output render path | **missing** | port into PAE: `CueMode` + the split-output summing path (see 6b) |
| `isGraphRunning: Bool` | `DJEngine.isRunning` | exists | adapter |
| `configurationChanges() -> AsyncStream<Void>` | — | **missing** | port into PAE: `AVAudioEngineConfigurationChange` observation on `DJEngine` |
| `recoverGraph()` | — (`start()` has no teardown/rebuild path) | **missing** | port into PAE: `DJEngine.recoverGraph()` |
| `RTCommand.syncNudge` (scheduled sample-accurate phase jump) | `Deck.nudge(_:)` (temporary rate change only) | shaped-differently | port into PAE: scheduled sample-accurate nudge via `PE_CMD_SEEK` at the callback boundary |
| `RTGuard` (Swift render-thread malloc/lock assertions) | relies on the C++ being allocation-free by construction | shaped-differently | **drop** the Swift guard; keep the intent as a documented invariant + the FLX4 stability tests. (Note: Tonearm's `RTGuard` shim already fails to fire on some machines — `EngineOfflineTests`, per Phase 5b.) |

PAE surface with **no `WorkspaceEngine` consumer** (hot-cue banks, `padMode`,
`assignPadFX`, `loopHalve`/`loopDouble`/`loopMove`/`loopRoll`/`saveLoop`/`callLoop`,
`SmartFader`/`SmartCFX`, `instantDouble`, `frameSearch`/`fastSearch`, full ColorFX
set, `Sampler`, `MicInput`): keep as-is. The Tonearm UI simply does not drive these
today; they are latent capability, not a gap.

**6a exit:** every `WorkspaceEngine` method has a row with a disposition; the "port
into PAE" set is frozen and becomes the 6b backlog; the "adapter" set becomes the 6c
backlog.

### 6b — Close the gaps in PAE

Each item lands with an **added or extended FLX4 acceptance-suite test** in
`Tests/ParsoDJEngineTests/` (current suite: 37 `@Test` across `DJEngineTests.swift`
`@Suite`s — "Loops", "Sync", "Hot cues", "Color and Beat FX render", "Master limiter
and RT stability", etc. — plus `RecordingTests.swift`). Prefer `HeadlessDJEngine` /
`pe_step` for determinism.

The C++ changes (`Sources/CParsoEngine/src/parso_engine_stub.cpp`,
`Sources/CParsoDSP/src/parso_dsp_stub.cpp`) are the riskiest work in the phase: the
renderer is allocation-free by construction, so every new voice/line/buffer must be
sized and allocated at `pe_create` time, never in the callback.

1. **Per-deck 4-stem voices** (biggest item). In `CParsoEngine`: each deck grows an
   optional 4-voice reader (vocals/drums/bass/other), all four sharing the deck's
   playhead and grid, summed with per-voice one-pole-smoothed gains + mute + solo
   **before** the deck EQ/filter/fader/crossfader chain. New C API:
   `pe_deck_set_stem_buffer(engine, deck, voice, channels, count, frames)` (four
   pre-allocated slots per deck) + control words for `stem_gain[deck][voice]`,
   `stem_mute`, `stem_solo`. A deck with no stem set is byte-for-byte the current
   single-source reader (Tonearm decision 3). Tests: stem gain smoothing produces no
   click; solo isolates; disarm returns bit-exact full mix.
2. **Per-deck beat echo (§35A)** with `enabled`/`beats`/`depth`/`feedback`, post-fader
   / pre-crossfader, delay derived from the master clock
   (`beats × 60/effectiveBPM × sampleRate`), read-pointer crossfade on delay change,
   feedback hard-clamped < 1, tail continues after `enabled = false`. This is a new
   per-deck DSP line distinct from the existing bus `BeatFXUnit`. Port the semantics
   from `Sources/DJ/Engine/BeatEcho.swift`. Test: "echo out" — disable the source,
   assert the tail decays and the assigned channel still carries it.
3. **`CueMode` parity.** Add `CueMode {off, splitOutput, cueInPlace, multichannel}`.
   `off` must stay bit-exact (untouched render path — the offline harness's
   frame-exact assertions depend on it). `splitOutput` sums master→mono-left,
   cue→mono-right in `pe_render_monitor` / a dedicated output path. `multichannel`
   is honest-and-inert until a >2ch route exists. Port from `Sources/DJ/Engine/CueBus.swift`.
4. **Telemetry source fields.** Extend `pe_event` / add a `pe_stats` poll for:
   `masterSample`, per-deck `bpmEffective` + beat `phase` + `synced`, `masterBPM` +
   `downbeatPhase`, `renderLoad` (time-over-buffer-period), starved-frame counter,
   record-drop counter. The adapter assembles `EngineTelemetry`; PAE only has to
   expose the atomics. Test: a headless render advances `masterSample` monotonically
   and `renderLoad` stays in 0…1.
5. **Sample-accurate seek / loop / syncNudge.** Surface `Deck.seek(toSample:quantized:)`,
   `Deck.setLoop(start:end:)` in track samples, and a scheduled sample-accurate
   `nudge(shiftSamples:)` applied at the callback boundary. Wire the existing
   `PE_CMD_SEEK` / `PE_CMD_SET_LOOP` tags to the sample path. Tests: seek lands on the
   exact sample (quantized and not); loop range is half-open `[start, end)`; nudge
   shifts phase by exactly N samples.
6. **`QuantizeResolution` grain** on `Deck` (1/1, 1/2, 1/4, …) feeding the existing
   `quantizedTime` snap. Test: cue/hot-cue snap to the configured grain.
7. **`Deck.effectiveRate`, per-deck `synced`, `unsync()`, bar-sync flag on `sync`.**
   Small additions; covered by extending `syncMatchesTempoToMaster`.
8. **Graph recovery.** `DJEngine` observes `.AVAudioEngineConfigurationChangeNotification`,
   exposes `configurationChanges()`, and `recoverGraph()` tears down and rebuilds the
   `AVAudioSourceNode` graph in place without dropping `pe_engine` state. Test:
   simulate a config change, assert `isRunning` recovers and deck playheads are
   preserved.
9. **Recording tap + segments.** Give `MixRecorder` (or a new `MixRecordTap`) a
   render-thread-fed ring + drop counter + segment/interruption model matching
   `RecordingService`/`RecordTap`/`M4AJoiner`. Verify M4A joiner format parity
   (`ExportCodec` vs `RecordingEncoder`). Test: record a headless render, interrupt
   mid-stream, assert the flushed segment is a complete playable M4A and the resumed
   segment is new.

**Licensing:** all 6b code is written fresh or ported from GPLv3 Tonearm _semantics_
into MIT PAE. Any line-level port from `Sources/DJ/Engine/*` must be a genuine
reimplementation, or the file must be independently authored from the spec
(`docs/SPEC.md` §§30–44), since the Tonearm engine is GPLv3. Record each as an
`ATTRIBUTION.md` row only if code is actually carried; prefer spec-driven rewrites so
nothing is carried.

**6b exit:** `swift test -c release` green with the new tests; whole-package scheme
still builds for watchOS + iOS (the C++ additions must stay portable — see risks).

### 6c — Adapter in Tonearm

New file `Sources/DJ/Engine/PAEWorkspaceEngine.swift` (or a new `Sources/DJ/PAEAdapter/`
group): `@MainActor final class PAEWorkspaceEngine: WorkspaceEngine` wrapping
`ParsoDJEngine.DJEngine`.

- **Construction:** owns a `DJEngine`; `start()`/`stop()` forward; `recoverGraph()` /
  `configurationChanges()` forward to the 6b additions.
- **Source bridging:** `DeckSource` (raw-ptr interleaved PCM + `frameCount` +
  `channelCount` + `sampleRate` + `DeckGrid`) → `PCMBuffer` + `TrackAnalysis`
  (`DeckGrid` → `tempo.bpm` + `tempo.beatPositions`, plus a minimal `Waveform`).
  Keep the ownership-transfer discipline: the adapter retains the backing buffer for
  the deck's lifetime and reclaims on `BUFFER_RELEASED` (`pe_event`), mirroring
  `PerformanceEngine`'s `boxes` / `reclaimAll`.
- **`StemSet`** → four `pe_deck_set_stem_buffer` calls + `armStemSet`-equivalent
  enable flag.
- **Telemetry mapping:** a display-cadence pump polls PAE's `pe_stats` + events and
  yields `EngineTelemetry` on an `AsyncStream` with `.bufferingNewest(1)` (copy
  `EngineTelemetryStream`'s shape from `Sources/DJ/Engine/EngineTelemetry.swift`,
  which stays — it is a pure value type above the seam).
- **Recording:** `startRecording`/`stopRecording`/interruption routed to PAE's 6b
  tap; `RecordingEncoder.RecordingOutput` assembled from PAE's segments.
- **Control mapping:** rate ratio↔percent, EQ knob↔dB, limiter dB↔linear,
  Float↔Double, global-quantize→both-decks fan-out, per the 6a table.
- **Coexistence flag:** a build flag (`-D PAE_DJ_ENGINE`) or runtime toggle
  (`UserDefaults` / launch arg) selects `PerformanceEngine` vs `PAEWorkspaceEngine`
  at the one construction site (`WorkspaceModel` init / DI). Both engines compile and
  are testable side by side for the whole of bring-up. `TonearmDJ` gains a
  `.product(name: "ParsoDJEngine", package: "parso-audio-engine")` dependency in
  `Package.swift` and `project.yml`.

**6c exit:** the adapter compiles; the DJ UI runs against it behind the flag; a first
smoke pass (load, play, crossfade, loop, cue) works by hand.

### 6d — Cutover

1. **Run Tonearm's full DJ suite against the adapter.** `Tests/DJTests/` is ~19k
   lines (`TonearmDJTests`) — golden-audio assertions + FLX4 MIDI-mapping + engine
   behaviour. Point the test engine factory at `PAEWorkspaceEngine` (a test flag) and
   run. Expect a first wave of failures from golden-audio divergence (mixer DSP) and
   from sample-exactness assumptions; triage each as _adapter bug_, _PAE gap missed
   in 6a_, or _golden needs re-baselining against the new renderer_ (only re-baseline
   with an explicit note + author sign-off, per the Phase 5 fixture-reverification
   precedent).
2. **A-B real-track transitions.** Manually run the five documented beginner
   transitions and a handful of real DJ-set transitions through both engines,
   listening for crossfader-curve, EQ-kill, filter-sweep and limiter differences.
   This is the check the automated suite cannot fully make. Carry any residual
   audible divergence to the author as a go/no-go item.
3. **Delete the Tonearm engine.** Remove `Sources/DJ/Engine/AudioGraph.swift`,
   `Mixer.swift`, `PerformanceEngine.swift`, `RTCommand.swift`, `CommandRing.swift`,
   `RTGuard.swift`, `DeckClock.swift` (keep `DeckGrid`/`QuantizeResolution` if the
   adapter still needs the value types — relocate them to a `DJ/Engine/Values` file
   that is original Tonearm work, or replace with PAE types), `StemVoices.swift`,
   `BeatEcho.swift`, `CueBus.swift` (keep `CueMode` value or switch to PAE's),
   `SyncEngine.swift`, `TimePitch.swift`, `EngineLiveness.swift`, `RenderLoad.swift`,
   `Scheduler.swift`, `CueLoop.swift`, `EngineSnapshot.swift`, and the now-dead
   `Sources/DJ/Recording/RecordTap.swift` / `M4AJoiner.swift` internals superseded by
   PAE. Keep `EngineTelemetry.swift` (value type, above the seam) and
   `WorkspaceEngine` (the protocol). Delete the corresponding `Tests/DJTests/*` engine
   tests, keeping the UI/model/MIDI/recording-orchestration tests that now exercise
   the adapter. Net: ~3,980 engine lines + support + tests removed.
4. **Remove the coexistence flag** once the adapter is the only path.

**Licensing note (load-bearing):** this deletes GPLv3 code; it does **not** move any
GPLv3 code into MIT PAE. PAE's gap-closing in 6b is fresh / spec-driven MIT work. So
there is **no relicensing event** — Tonearm simply stops shipping its own engine and
links PAE's. Confirm no file under `Sources/DJ/Engine/*` was copied into
`Sources/CParsoEngine` / `Sources/ParsoDJEngine`; `ATTRIBUTION.md` gets rows only if
that turns out to be unavoidable for a specific algorithm.

### 6e — Verify / gate

- **PAE:** `swift test -c release` (full suite + new FLX4 acceptance tests) green;
  FLX4 acceptance pass per `docs/SPEC.md` §15; whole-package scheme builds for
  watchOS **and** iOS (`xcodebuild -scheme parso-audio-engine-Package`).
- **Tonearm:** `TonearmDJTests` + `TonearmCoreTests` green; full pre-commit hook
  (guards + logic + UI smoke); `Tonearm` scheme builds for the iOS simulator.
- **Docs:** update `current_status.md` (Phase 6 table row + a "Phase 6" section in the
  Phase 2–5 style), `docs/UNIFICATION_PLAN.md` §6 (resolved → option 1) and §7,
  `docs/SPEC.md` (note that Tonearm is now a PAE consumer for the DJ engine; the DJ
  engine spec §§30–44 is authoritative for PAE).
- Commit on `audio-engine-unification` in both repos; app commit uses
  `--no-verify` intermediates then a full-hook final commit, per the established
  migration policy. Not pushed until the author signs off the A-B pass.

---

## Effort estimate

One engineer familiar with both codebases:

| Sub-phase | Estimate | Notes |
|---|---|---|
| 6a parity audit | 3–5 days | mechanical but must be exhaustive |
| 6b close gaps in PAE | 3–4 weeks | stem voices + echo line + recording tap are the bulk; C++ is slow to get right |
| 6c adapter | 1.5–2 weeks | mostly mapping; telemetry pump + source reclaim are the fiddly bits |
| 6d cutover | 1.5–3 weeks | dominated by triaging the 19k-line suite and the A-B pass; wide variance |
| 6e verify / docs | 2–3 days | |
| **Total** | **~8–11 weeks** | plus author A-B review latency |

The variance is almost entirely in 6b (C++) and 6d (golden-audio triage).

## Risks

- **C++ renderer changes are the highest risk.** `CParsoEngine` / `CParsoDSP` are
  allocation-free by construction and have no Swift `RTGuard` backstop after this
  phase. Per-deck stem voices and the per-deck echo line add real DSP state that must
  be sized at `pe_create`. A regression here is an audio glitch under load that the
  headless deterministic tests may not surface — lean on the "RT stability" suite
  and add load-soak tests.
- **Mixer DSP audible divergence.** Crossfader curves, EQ kill, ColorFX/filter sweep
  and the limiter are independent implementations. Even with matching enum names the
  _curves_ will differ. This is only caught by the 6d A-B pass on real tracks; budget
  for a round of PAE mixer tuning to match Tonearm's transition feel, and get
  explicit author sign-off.
- **The ~19k-line DJ test net is both safety and friction.** It will catch real
  adapter bugs — and it will also flag every golden-audio and sample-exactness
  assumption baked against the old renderer. Distinguishing "adapter bug" from
  "legitimately different but correct output" is the slow part of 6d; resist
  re-baselining goldens without a written rationale.
- **`pe_deck_set_buffer` live-swap RT-safety.** `Deck.load` runs on the main actor and
  hands the buffer to the C layer; confirm the C side publishes it to the render
  thread atomically (double-buffer / pointer swap) and reclaims the old one via
  `BUFFER_RELEASED`, matching Tonearm's lock-free `DeckSource` arm. If it currently
  blocks or reallocs, that is additional 6b work.
- **watchOS.** Tonearm's DJ engine does **not** build for watchOS today — `TonearmDJ`
  links `CoreMIDI` / `CoreML` / `Metal` / `MetalPerformanceShaders`, none available
  on watchOS, and DJ is not a watch feature. PAE's `ParsoDJEngine` **does** currently
  build for watchOS (it is in the whole-package watchOS gate). Phase 6 must keep the
  PAE C++ additions portable so that gate stays green — or, if a new dependency (e.g.
  a time-pitch lib) is not watch-safe, gate `ParsoDJEngine` itself out of watchOS
  deliberately and update the Phase 0 gate. Decide this in 6b before writing
  platform-specific C.
- **Recording format parity.** `MixRecorder`/`ExportCodec` vs
  `RecordingEncoder`/`M4AJoiner` — segment boundaries, AAC parameters, and the
  interruption-flush contract (NFR-REL-2) must match or existing recording tests and
  the journal's `mix_asset` path break.

## Licensing note

Clean. Phase 6 **deletes** GPLv3 code (`Sources/DJ/Engine/*`) and adds fresh /
spec-driven MIT code to PAE. Nothing moves from the GPLv3 engine into MIT PAE, so
there is no relicensing to record and no `ATTRIBUTION.md` churn — provided the 6b
implementations are genuine reimplementations from `docs/SPEC.md`, not line ports.
This is the licensing advantage of option 1 over option 2 (which would have had to
relicense Tonearm's engine into PAE).

## If you pick option 3 instead

Option 3 is "keep deferring", and it stays the correct call unless Platterhead DJ is
firmly committed to PAE. The two engines do not interact, nothing outside each app
depends on either, and Phases 0–5 already removed all the duplication that was
actually costing anything (cache, EQ, decoders, analysis DSP). The ongoing cost of
two engines is close to zero: each is separately tested, separately shipped, and the
`ParsoAudioAnalysis` seam that Phase 5 established already proves the integration
boundary works. Under option 3, the only Phase 6 deliverable is a one-paragraph note
in `current_status.md` recording that the decision was reviewed post-Phase-5 and
deferred again pending Platterhead DJ requirements, plus keeping this plan on file as
the executable version of option 1 for when that decision flips. Revisit when
Platterhead DJ's DJ-engine requirements are written down.

---

## Critical files

- `parso-tonearm/Sources/DJ/Features/Workspace/WorkspaceModel.swift` — the `WorkspaceEngine` protocol (the seam)
- `parso-tonearm/Sources/DJ/Engine/RTCommand.swift` — control vocabulary to map
- `parso-tonearm/Sources/DJ/Engine/PerformanceEngine.swift` — reference conformer to reimplement as the adapter
- `parso-audio-engine/Sources/ParsoDJEngine/ParsoDJEngine.swift` — PAE control objects the adapter drives
- `parso-audio-engine/Sources/CParsoEngine/include/parso_engine.h` — C API + `pe_control`, where 6b's stem/echo/cue/telemetry gaps get closed
