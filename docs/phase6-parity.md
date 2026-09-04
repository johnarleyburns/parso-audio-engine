# Phase 6a — DJ engine parity audit

Maps every control/telemetry entry of Tonearm's `WorkspaceEngine` seam onto
PAE's `ParsoDJEngine` + `CParsoEngine` surface, with a disposition per row.
Companion to `docs/PHASE_6_PLAN.md`. Author decisions in effect (2026-09-03):

- **Platterhead DJ = parso-tonearm rebranded.** Phase 6 is option 1: Tonearm
  adopts `ParsoDJEngine`, deletes its GPLv3 `Sources/DJ/Engine/*`.
- **PAE's mixer curves are the reference.** Where crossfader / EQ-kill / filter /
  limiter math differs, the adapter maps knob→param and Tonearm's golden-audio
  tests get re-baselined against the PAE renderer with a written rationale — no
  PAE mixer DSP tuning to match Tonearm's feel.

Sources audited (branch `audio-engine-unification` in both repos):

| File | Role |
|---|---|
| `parso-tonearm/Sources/DJ/Features/Workspace/WorkspaceModel.swift` L1–110 | `WorkspaceEngine` protocol — the seam (55 members) |
| `parso-tonearm/Sources/DJ/Engine/RTCommand.swift` | control vocabulary (33 tags) |
| `parso-tonearm/Sources/DJ/Engine/PerformanceEngine.swift` | reference conformer |
| `parso-audio-engine/Sources/ParsoDJEngine/ParsoDJEngine.swift` | PAE control objects |
| `parso-audio-engine/Sources/CParsoEngine/include/parso_engine.h` | C API |
| `parso-audio-engine/Sources/CParsoEngine/src/parso_engine_stub.cpp` | C++ renderer (spot-checked; **full read owed in 6b**) |
| `parso-audio-engine/Sources/CParsoDSP/src/parso_dsp_stub.cpp` | DSP kernels (EQ / filter / time-pitch via signalsmith-stretch) |

---

## Headline findings (differences from `PHASE_6_PLAN.md`'s starting assumptions)

1. **`ParsoDJEngine`'s sync is one-shot, not continuous.** `Deck.sync()` /
   `refreshSyncFromMasterIfNeeded()` compute a tempo-percent on the *control
   actor* and post a single `PE_CMD_SYNC` that just seeks the deck to a phase-
   matched position. The C++ engine has **no master clock, no BPM, no per-deck
   sync state, no effective-rate** — `grep` for `masterFrame|bpm|isSynced|
   masterClock` in `parso_engine_stub.cpp` returns nothing. Tonearm's
   `RTCommand.sync` re-derives the synced deck's rate *every callback* so a
   master pitch move drags the synced deck with it (`RTCommand.swift` L52–56).
   **Closing this is the single biggest 6b item after stems** — PAE needs a
   render-side master clock + continuous rate tracking, not just a getter.

2. **No master-frame counter anywhere.** `WorkspaceEngine.masterSample: Int64`
   (the model renders all playheads as clock time from it) has no PAE source.
   The C API exposes per-deck playhead via `PE_EVT_PLAYHEAD` only. Port: a
   monotonic `uint64` frame counter in `pe_engine`, readable via a new poll.

3. **Seek / loop / hot-cue endpoints cross the C boundary as `float` seconds**
   (`pe_command.f0 * deck.sampleRate`, verified in `parso_engine_stub.cpp`
   L426–L560). Float32 holds integer sample precision only to ~2^24 samples
   (~5.8 min at 48 kHz); past that, `seek(toSample:)` and `setLoopRange` lose
   sample accuracy. `WorkspaceEngine` types these as `Int64` track samples.
   Port: an integer sample path on `PE_CMD_SEEK` / `PE_CMD_SET_LOOP` /
   `PE_CMD_HOTCUE_SET` (use `pe_command.i0`, int32 → 12.4 h at 48 kHz, ample).

4. **Time-pitch / key-lock is already done and portable.** `CParsoDSP` embeds
   `signalsmith-stretch` (header-only C++, no platform deps) with
   `pd_tp_set_time_ratio` / `pd_tp_set_pitch_semitones` / `PD_TP_KEYLOCK` vs
   `PD_TP_VARISPEED`. The plan's watchOS worry about needing a non-portable
   time-pitch lib is **moot** — nothing new is needed here, and the whole-
   package watchOS gate can stay green.

5. **`pe_command` has no free int64.** Fields are `int32 i0,i1,i2` + `float
   f0,f1`. Any ported sample-addressed command fits in an int32 (12.4 h @ 48k).
   `syncNudge`'s signed sample shift likewise fits.

6. **Quantize is control-side in PAE.** `Deck.quantize: Bool` +
   `quantizedTime()` snap to the analysis grid happen on the main actor; the
   C++ has no quantize state and no resolution grain. Tonearm pushes a
   `setQuantize(on:resolution:)` to the RT side. Disposition: the adapter keeps
   PAE's control-side snapping and holds the global on/off + `QuantizeResolution`
   itself (it already has the `TrackAnalysis` grid) — **no C++ change needed**,
   downgrading a plan "port" row to "adapter".

---

## `WorkspaceEngine` member-by-member

Legend — **State**: `exists` (direct PAE equivalent) / `shaped` (present but
different type/granularity) / `missing` (no PAE source).
**Disposition**: `adapter` (map in `PAEWorkspaceEngine`) / `port` (new PAE/C++
work, becomes 6b backlog) / `drop`.

### Lifecycle & graph

| WorkspaceEngine | PAE equivalent | State | Disposition |
|---|---|---|---|
| `start() throws` | `DJEngine.start()` | exists | adapter |
| `stop()` | `DJEngine.stop()` | exists | adapter |
| `isGraphRunning: Bool` | `DJEngine.isRunning` | exists | adapter |
| `configurationChanges() -> AsyncStream<Void>` | — | missing | **port**: observe `.AVAudioEngineConfigurationChangeNotification` on `DJEngine`, expose the stream |
| `recoverGraph() throws` | — (`start()` has no teardown/rebuild) | missing | **port**: `DJEngine.recoverGraph()` — rebuild the `AVAudioSourceNode` graph in place, preserve `pe_engine` state |

### Clock & readouts

| WorkspaceEngine | PAE equivalent | State | Disposition |
|---|---|---|---|
| `masterSample: Int64` | — | missing | **port**: monotonic frame counter in `pe_engine` + poll accessor |
| `sampleRate: Double` | `DJEngine.sampleRate` (private) → expose | shaped | adapter (surface it) |
| `bufferPeriodMillis: Double` | `maxFramesPerRender / sampleRate` | shaped | adapter (compute) |
| `limiterCeiling: Float?` | `MasterOut.limiterCeilingDB` (dB, always set) | shaped | adapter (dB→linear); **port** a limiter-bypass state so `nil` is representable |
| `deckRate(_:) -> Double` | `Deck` computes `playbackRatio` privately; `PE_EVT` carries none | missing | **port**: `Deck.effectiveRate` published from the render side (needed by sync + telemetry too) |

### Transport & loading

| WorkspaceEngine | PAE equivalent | State | Disposition |
|---|---|---|---|
| `load(_:source: DeckSource)` | `Deck.load(_ analysis: TrackAnalysis, buffer: PCMBuffer)` → `pe_deck_set_buffer` | shaped | adapter: bridge `DeckSource` (raw interleaved PCM + `frameCount` + `channelCount` + `sampleRate` + `DeckGrid`) → `PCMBuffer` + a minimal `TrackAnalysis` (`DeckGrid` → `tempo.bpm` + `beatPositions`). **Verify `pe_deck_set_buffer` publishes to the render thread atomically + reclaims the old buffer via `PE_EVT_BUFFER_RELEASED`** (the event exists; confirm the C++ arms it on re-load — full read owed) |
| `play(_:)` / `pause(_:)` | `Deck.play()` / `.pause()` | exists | adapter |
| `cue(_:)` / `releaseCue(_:)` | `Deck.cuePlayPress()` / `.cuePlayRelease()` | exists | adapter |
| `seek(_:toSample:quantized:)` | `Deck.returnToStart()` etc. post `PE_CMD_SEEK` with `f0` = **float** frame | shaped | **port**: integer-sample `PE_CMD_SEEK` (`i0`); adapter does the quantize snap against its grid |
| `setCue(_:atSample:)` | `Deck.setCue()` captures the *current* playhead only | shaped | **port**: `PE_CMD_SET_CUE` integer-sample arg (`i0`), or adapter seeks-then-setCue (worse — transient playhead move). Prefer the C path. |
| `triggerHotCue(_:atSample:)` | `Deck.setHotCue(index)` / `jumpHotCue(index)` — index-keyed, 8 slots | shaped | adapter keeps a `sample → slot` map and calls the index API; **or** port a sample-addressed hot-cue jump. Adapter map is simpler and needs no C change. |
| `setLoopRange(_:start:end:)` (track samples) | `Deck.loopIn()`/`loopOut()` (playhead-based `TimeInterval`); `PE_CMD_SET_LOOP` takes float-seconds `f0/f1` | shaped | **port**: integer-sample `PE_CMD_SET_LOOP` (`i0` start, `i1` end); half-open `[start, end)` |
| `setLoop(_:beats:)` | `Deck.autoBeatLoop(beats:)` | exists | adapter |
| `exitLoop(_:)` | `Deck.reloopExit()` / `setActiveLoop(false)` | exists | adapter |
| `setQuantize(_:resolution:)` (global) | `Deck.quantize: Bool` (per deck, no resolution); snap is control-side | shaped | adapter: hold the global toggle + `QuantizeResolution`, fan to both decks, snap against the analysis grid. **No C++ change.** |

### Tempo / pitch / key

| WorkspaceEngine | PAE equivalent | State | Disposition |
|---|---|---|---|
| `setRate(_:rate: Float)` (ratio) | `Deck.tempoPercent` + `tempoRange` → `deck_time_ratio` | shaped | adapter: ratio ↔ percent (or add `Deck.setRate(_:)` — trivial, cleaner) |
| `setKeyLock(_:locked:)` | `Deck.keyLock: Bool` → `PE_CMD_SET_KEYLOCK` + `pd_tp` mode | exists | adapter |
| `setKeyShift(_:semitones: Float)` | `Deck.pitchSemitones: Double` → `control.deck_pitch` → `pd_tp_set_pitch_semitones` | exists | adapter (Float↔Double) |

### Sync (§32)

| WorkspaceEngine | PAE equivalent | State | Disposition |
|---|---|---|---|
| `sync(_:to:barSync:)` | `Deck.sync()` + `setAsMaster()` — **one-shot, control-side tempo match + position seek**; no `barSync` | shaped | **port** (large): render-side master clock in `pe_engine`; continuous per-callback rate tracking for a synced deck (`PE_CMD_SYNC` becomes "engage", not "seek once"); `barSync` flag aligns downbeats vs beats |
| `unsync(_:)` | — (`Deck.sync()` toggles `isSynced`; no explicit disengage command) | shaped | **port**: explicit disengage on `PE_CMD_SYNC` / a new tag |
| `isSynced(_:) -> Bool` | `Deck.isSynced` (control-side bool only) | shaped | **port**: authoritative per-deck `synced` from the render side (also a telemetry field) |
| `RTCommand.syncNudge` (scheduled sample-accurate phase jump) | `Deck.nudge(_:)` = transient rate change only | shaped | **port**: scheduled sample-accurate playhead shift applied at the callback boundary (`i0` signed samples) |

### Mixer — EQ / filter / faders / crossfader (§35)

PAE mixer curves are the reference (author decision) — every row here is
`adapter` + a golden re-baseline note; no PAE DSP tuning.

| WorkspaceEngine | PAE equivalent | State | Disposition |
|---|---|---|---|
| `setEQKnobs(_:low:mid:high:)` (knob −1…+1) | `Channel.eqLow/eqMid/eqHigh` (dB, `-inf` == kill) | shaped | adapter: knob→dB curve **in the adapter** (do not reuse `ThreeBandEQ.knobToGain` — that's Tonearm GPLv3; write a fresh curve). Re-baseline `Tests/DJTests` EQ goldens. |
| `setFilter(_:knob:)` (−1…1, centre bypass) | `Channel.colorFX = .filter` + `colorAmount` (−1…1) | shaped | adapter: select `.filter` ColorFX, pass knob as `colorAmount`. Re-baseline filter-sweep goldens. |
| `setChannelFader(_:gain:)` (0…1) | `Channel.fader` (0…1) | exists | adapter (`Channel.trim` stays at default 0.5) |
| `setCrossfader(_:curve:)` (−1…1) | `Mixer.crossfader` (−1…1) + `Mixer.Curve {smooth,linear,sharp}` | exists | adapter: `CrossfaderCurve {smooth,linear,sharp}` enum names match; **curve math differs** (PAE maps to `xfade_curve` 0/0.5/1) — re-baseline crossfader goldens |
| `limiterCeiling` writes | `MasterOut.limiterCeilingDB` | exists | adapter |

### Beat FX — per-deck §35A echo

| WorkspaceEngine | PAE equivalent | State | Disposition |
|---|---|---|---|
| `setEchoEnabled/Beats/Depth/Feedback(_:)` (per **deck**, incl. **feedback**, post-fader / pre-crossfader) | `BeatFXUnit` — one **bus** unit: `kind`/`beats`/`depth`/`assign`/`isOn`; **no per-deck instance, no feedback param** | missing | **port** (large): a per-deck echo line in `CParsoEngine`, `enabled`/`beats`/`depth`/`feedback`, delay from the master clock, read-pointer crossfade on delay change, feedback hard-clamped < 1, tail continues after disable. Distinct from the existing bus `BeatFXUnit`. Spec-driven from `docs/SPEC.md §35A` (Tonearm's `BeatEcho.swift` is GPLv3 — semantics only). |

### Stems — per-deck 4-voice (§35.1)

| WorkspaceEngine | PAE equivalent | State | Disposition |
|---|---|---|---|
| `armStemSet(_:stemSet:)` | `Sampler` slots only — no per-deck stem voices | missing | **port** (largest item): each deck grows an optional 4-voice reader (vocals/drums/bass/other) sharing the deck playhead+grid, summed with per-voice one-pole-smoothed gain + mute + solo **before** the deck EQ/filter/fader/crossfader chain. New C API `pe_deck_set_stem_buffer(engine, deck, voice, channels, count, frames)` — 4 pre-allocated slots/deck. A deck with no stem set is byte-for-byte the current single-source reader. |
| `setStemGain(_:stem:gain:)` | — | missing | **port**: `stem_gain[deck][voice]` control word, one-pole smoothed |
| `setStemMute(_:stem:muted:)` | — | missing | **port**: `stem_mute` control word |
| `setStemSolo(_:stem:soloed:)` | — | missing | **port**: `stem_solo` control word; any-soloed ⇒ only-soloed sound |

### Cue monitoring (§44.2a)

| WorkspaceEngine | PAE equivalent | State | Disposition |
|---|---|---|---|
| `setHeadphoneCue(_:enabled:)` | `Channel.cuePFL: Bool` → `control.cue_pfl` | exists | adapter |
| `setCueMode(_:)` (`off`/`splitOutput`/`cueInPlace`/`multichannel`) | `Monitoring.masterCue` + `cueMasterMix` + `pe_render_monitor` — **no `CueMode` concept**, no mono-L/mono-R split-output path | missing | **port**: `CueMode` enum + `off` stays bit-exact (offline harness frame assertions depend on it); `splitOutput` sums master→mono-L, cue→mono-R; `multichannel` honest-inert until a >2ch route exists. Spec-driven from §44.2a (`CueBus.swift` GPLv3). |

### Telemetry

| WorkspaceEngine | PAE equivalent | State | Disposition |
|---|---|---|---|
| `telemetry: AsyncStream<EngineTelemetry>` | `pe_poll_events` (PLAYHEAD/PEAK/STATE/END_OF_TRACK) + `@MainActor` props on `Deck`/`Channel`/`MasterOut` | shaped | adapter synthesizes the stream from a display-cadence poll |
| `sampleTelemetry() -> EngineTelemetry` | — | shaped | adapter builds `EngineTelemetry` from polled state |
| `pushTelemetry()` | — | shaped | adapter (pump yields onto the stream) |
| `droppedRecordFrames: UInt64` | `MixRecorder` has no tap / no drop counter | missing | **port** (with recording tap, below) |
| **telemetry source fields** the adapter cannot synthesize: per-deck `bpmEffective`, beat `phase`, `synced`; `masterBPM`, `downbeatPhase`; `renderLoad`; starved-frame counter | none in C API | missing | **port**: extend the event/poll surface with these atomics (mostly falls out of the master-clock + effective-rate work above) |

### Recording (§37.2 / §34A.4)

| WorkspaceEngine | PAE equivalent | State | Disposition |
|---|---|---|---|
| `startRecording() async throws -> URL` | `MixRecorder.start()` (manual `append(_:)` buffer feed; no render tap) | shaped | **port**: a render-thread-fed ring + drop counter feeding `MixRecorder` (or a new `MixRecordTap`) |
| `stopRecording() async throws -> RecordingEncoder.RecordingOutput?` | `MixRecorder.stop()` writes one file | shaped | **port**: segment model + `RecordingOutput`-shaped result; adapter assembles Tonearm's `RecordingEncoder.RecordingOutput` from PAE segments |
| `isRecording: Bool` | `MixRecorder.isRecording` | exists | adapter |
| `interruptRecordingForInterruption()` / `resumeRecordingFromInterruption()` | — (no interruption model) | missing | **port**: segment flush on `.began` (complete playable M4A), new segment on `.ended`. Verify M4A container parity: PAE `ExportCodec` vs Tonearm `RecordingEncoder`/`M4AJoiner` — AAC params, segment boundaries, NFR-REL-2 flush contract |

---

## `RTCommand.Tag` coverage (33 tags)

| Tag | PAE path | Disposition |
|---|---|---|
| `play` / `pause` | `PE_CMD_PLAY` / `PE_CMD_PAUSE` | exists |
| `setRate` | `control.deck_time_ratio` | adapter |
| `loadArm` | `pe_deck_set_buffer` | adapter (verify RT-safe live swap) |
| `seek` | `PE_CMD_SEEK` (float sec) | **port** integer-sample |
| `setCue` | `PE_CMD_SET_CUE` (current playhead) | **port** explicit-sample |
| `cuePress` / `cueRelease` | `PE_CMD_JUMP_CUE` + play/pause | adapter |
| `triggerHotCue` | `PE_CMD_HOTCUE_SET/JUMP` (index) | adapter (sample→slot map) |
| `setLoop` | `PE_CMD_SET_LOOP` (float sec) | **port** integer-sample |
| `exitLoop` | `PE_CMD_RELOOP_EXIT` / `PE_CMD_SET_LOOP_ACTIVE` | adapter |
| `setQuantize` (on + resolution) | control-side only | adapter (no C change) |
| `setKeyLock` | `PE_CMD_SET_KEYLOCK` | adapter |
| `setKeyShift` | `control.deck_pitch` | adapter |
| `setEQ` (linear l/m/h) | `control.eq_*` (dB) | adapter (knob→dB curve, fresh) |
| `setFilter` | `control.color_*` (ColorFX `.filter`) | adapter |
| `setFader` (trim) | `control.trim` / `control.fader` | adapter |
| `setCrossfader` (pos + curve) | `control.crossfader` + `xfade_curve` | adapter (re-baseline curve goldens) |
| `sync` (continuous) | `PE_CMD_SYNC` (one-shot seek) | **port** continuous render-side sync |
| `unsync` | — | **port** |
| `syncNudge` (scheduled sample shift) | `Deck.nudge` (transient rate) | **port** scheduled sample-accurate nudge |
| `setEchoEnabled/Beats/Depth/Feedback` | bus `BeatFXUnit` only | **port** per-deck echo line |
| `armStemSet` / `setStemGain` / `setStemMute` / `setStemSolo` | — | **port** per-deck stem voices |
| `setCueEnabled` | `control.cue_pfl` | adapter |
| `setCueMode` | — | **port** `CueMode` + split-output path |

PAE `pe_cmd_type` values with **no `WorkspaceEngine` need**, left as-is:
`PE_CMD_LOOP_SCALE`, `PE_CMD_LOOP_MOVE`, `PE_CMD_BEATJUMP`, `PE_CMD_SET_SLIP`,
`PE_CMD_JOG_TOUCH/MOVE/RELEASE`, `PE_CMD_COLORFX_KIND`, `PE_CMD_BEATFX_*`,
`PE_CMD_SAMPLER_*`, `PE_CMD_SET_MASTER`, `PE_CMD_LOAD`. PAE `Deck`/`Mixer`
surface with no seam consumer (hot-cue banks, `padMode`, `assignPadFX`,
`loopHalve/Double/Move/Roll/saveLoop/callLoop`, `SmartFader`/`SmartCFX`,
`instantDouble`, `frameSearch`/`fastSearch`, full ColorFX set, `Sampler`,
`MicInput`): latent capability, keep.

| `RTGuard` (Swift render-thread malloc/lock assertions) | C++ allocation-free by construction | **drop** the Swift guard; keep the invariant documented + lean on the "RT stability" acceptance suite. (Tonearm's `RTGuard` shim already misfires on some machines — Phase 5b `EngineOfflineTests`.) |

---

## Frozen 6b backlog (the "port into PAE" set)

Ordered by risk/size. Each lands with an added/extended FLX4 acceptance test in
`Tests/ParsoDJEngineTests/` (prefer `HeadlessDJEngine` / `pe_step`). All code
fresh or spec-driven from `docs/SPEC.md §§30–44` — **no line ports** from the
GPLv3 `Sources/DJ/Engine/*`.

1. **Per-deck 4-stem voices** — `pe_deck_set_stem_buffer` + `stem_gain/mute/solo`
   control words; sum pre-EQ; one-pole gain smoothing; disarm ⇒ bit-exact single
   source. *Tests: no click on gain ramp; solo isolates; disarm = bit-exact.*
2. **Render-side master clock + continuous sync** — monotonic master frame
   counter; master BPM + downbeat phase; per-deck effective rate + `synced`
   state published from the render side; `PE_CMD_SYNC` becomes engage/disengage
   with per-callback rate tracking; `barSync` flag; scheduled sample-accurate
   `syncNudge`. *Tests: extend `syncMatchesTempoToMaster`; master pitch move
   drags the synced deck; nudge shifts phase by exactly N samples.*
3. **Per-deck beat echo (§35A)** — new per-deck DSP line, `enabled/beats/depth/
   feedback`, master-clock-derived delay, read-pointer crossfade, feedback
   clamped < 1, tail after disable. *Test: "echo out" — disable source, tail
   decays on the assigned channel.*
4. **Recording tap + segments + interruption** — render-fed ring + drop counter;
   segment/interruption model; M4A joiner parity vs `ExportCodec`. *Test: record
   a headless render, interrupt mid-stream, flushed segment is a complete
   playable M4A, resumed segment is new.*
5. **`CueMode` + split-output** — `{off, splitOutput, cueInPlace, multichannel}`;
   `off` bit-exact; `splitOutput` mono-L master / mono-R cue in
   `pe_render_monitor`. *Test: `off` unchanged; `splitOutput` channel isolation.*
6. **Integer-sample transport** — `PE_CMD_SEEK` / `PE_CMD_SET_CUE` /
   `PE_CMD_SET_LOOP` / `PE_CMD_HOTCUE_SET` take `i0`(/`i1`) int32 samples;
   half-open `[start, end)` loops. *Tests: seek lands on the exact sample; loop
   bounds exact.*
7. **`QuantizeResolution` grain** — 1/1…1/32 on `Deck`, feeds the snap. (Small;
   may stay adapter-side — decide in implementation.)
8. **Limiter bypass state** — so `limiterCeiling` can be `nil`.
9. **Graph recovery** — `DJEngine.recoverGraph()` +
   `configurationChanges()` observing `.AVAudioEngineConfigurationChangeNotification`;
   rebuild the source-node graph without dropping `pe_engine` state. *Test:
   simulate a config change, `isRunning` recovers, playheads preserved.*

**6b exit:** `swift test -c release` green with new tests; whole-package scheme
still builds for watchOS + iOS (C++ additions stay portable — no new platform
deps; `signalsmith-stretch` already covers time-pitch).

## 6c backlog (the "adapter" set)

New `parso-tonearm/Sources/DJ/Engine/PAEWorkspaceEngine.swift`:
`@MainActor final class PAEWorkspaceEngine: WorkspaceEngine` wrapping
`ParsoDJEngine.DJEngine`.

- `DeckSource` → `PCMBuffer` + minimal `TrackAnalysis`; retain the backing
  buffer for the deck's lifetime, reclaim on `PE_EVT_BUFFER_RELEASED` (mirror
  `PerformanceEngine`'s `SourceBoxRegistry`).
- `StemSet` → 4× `pe_deck_set_stem_buffer` + arm flag.
- Telemetry pump: display-cadence poll of the 6b atomics/events → `EngineTelemetry`
  on an `AsyncStream` with `.bufferingNewest(1)`. `EngineTelemetry.swift` stays
  (pure value type above the seam).
- Recording: route to the 6b tap; assemble `RecordingEncoder.RecordingOutput`
  from PAE segments.
- Control mapping: rate ratio↔percent, **fresh** EQ knob→dB curve, limiter
  dB↔linear, Float↔Double, global-quantize→both-decks fan-out + grid snap.
- Coexistence: `-D PAE_DJ_ENGINE` (or a launch-arg toggle) selects
  `PerformanceEngine` vs `PAEWorkspaceEngine` at the one construction site.
  `TonearmDJ` gains `.product(name: "ParsoDJEngine", package: "parso-audio-engine")`
  in `Package.swift` + `project.yml`.

## Still owed before 6b starts

- **Full read of `parso_engine_stub.cpp` (1072 lines) and `parso_dsp_stub.cpp`
  (776 lines).** This audit spot-checked the command dispatch, seek/loop/hot-cue
  handlers, and the time-pitch kernel. The buffer-swap RT-safety of
  `pe_deck_set_buffer`, the exact `PE_EVT_BUFFER_RELEASED` arming, the existing
  bus `BeatFXUnit` DSP, and the monitor-bus summing all need a line read before
  their rows are final.
- **`EngineTelemetry` / `EngineTelemetryStream` field list** from
  `parso-tonearm/Sources/DJ/Engine/EngineTelemetry.swift` — enumerate every
  field the pump must fill, cross-check against finding 2/telemetry rows.
- **`DeckSource` / `DeckGrid` / `StemSet` / `StemKind` / `CueMode` /
  `CrossfaderCurve` / `QuantizeResolution` exact shapes** from
  `parso-tonearm/Sources/DJ/Engine/*` — which are pure value types the adapter
  can keep (relocated to an original-work file) vs must be replaced with PAE
  types.
