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

0. **Wire `CParsoDSP` kernels into `render()`** — ✅ **done** (`9171ab7`).
   `parso_engine_stub.cpp` `render()` was rebuilt as a 4-pass, 512-frame-blocked
   pipeline over the real kernels: `pd_eq3` (SPEC §35.2 isolator, 200 Hz / 2 kHz
   crossovers, −∞…+6 dB) per deck replaces the hand-rolled 2-band one-pole;
   `pd_filter` (resonant sweep) drives Color-FX "Filter" (kind 0); `pd_limiter`
   (SPEC §35.5 look-ahead brickwall) replaces the per-sample soft limiter. Added
   `pd_limiter_set_ceiling` to `CParsoDSP` for the runtime ceiling. Non-filter
   Color-FX kinds (space/dub/sweep/noise/crush/pitch) keep the existing
   per-sample `processColorFX` (no kernel exists). The dead `processEQ` /
   `processLimiter` / `dbToGain` are gone. Kernels are engine-owned (created in
   `pe_create`, freed in `pe_destroy`); `pe_create` returns `nullptr` if any
   kernel fails to allocate. Tests: `isolatorEQKillsByBand`,
   `limiterCeilingChangeIsHonored` + all 39 existing DJ-engine tests green;
   whole-package builds for watchOS + iOS. **Golden re-baseline (6d) is now
   against real DSP, not the stub.**

1. **Per-deck 4-stem voices** — ✅ (commit on `audio-engine-unification`).
   `pe_deck_set_stem_buffer` / `pe_deck_clear_stems` + `PE_CMD_STEM_GAIN/_MUTE/
   _SOLO`. `DeckState.stems[4]` + `stemsArmed`; Pass 1 sums present voices with
   one-pole-smoothed gain, mute, and any-soloed⇒only-soloed, **before** the
   EQ/filter/fader chain. `stemsArmed == false` ⇒ the exact prior single-source
   reader. Swift: `Deck.armStems([StemKind: PCMBuffer])` / `disarmStems()` /
   `setStemGain/Mute/Solo`. *Tests: disarmed-deck render is bit-exact vs
   never-armed; solo isolates a voice (goertzel); mute drops a voice; finite
   under a gain change.*
2. **Render-side master clock + telemetry + continuous-ish sync** — ✅ (partial,
   see note). Monotonic `pe_engine.masterFrame`; `pe_stats` poll (`renderLoad`,
   per-deck effective BPM / beat phase / `synced`, `masterBpm`, `downbeatPhase`);
   `pe_set_master_clock` / `pe_set_deck_sync` published from the control actor;
   `pe_record_dropped_frames`. `Deck.effectiveRate`, explicit `unsync()` +
   `PE_CMD_UNSYNC`, `sync(barSync:)` (aligns to `downbeatPositions`).
   **Continuous drag: done control-side** — `EngineBridge.setDeckPlayback`
   re-derives the synced deck whenever the master's rate changes (finding C4),
   with a re-entrancy guard. **Deferred to 6c/author:** a fully render-side
   per-callback rate integrator (the `SyncEngine.swift` spec re-derivation) —
   the control-side re-derivation covers the observable "master pitch move drags
   the synced deck" behaviour and the C `pe_set_deck_sync` atomics carry the
   telemetry; a render-side integrator only matters for sample-locked phase
   under sustained master automation and is a bigger, riskier change best done
   with the 6d A-B pass. `RTCommand.syncNudge` sample-accurate scheduling also
   deferred (nudge remains transient-rate, as `Deck.nudge`). *Tests:
   `masterFrame` monotonic + `renderLoad` finite; `effectiveRate` tracks the
   fader; master pitch move drags the synced deck without a fresh `sync()`;
   `unsync()` disengages.*
2a. **Key-lock wiring** — ✅. Per-deck `pd_timepitch` (signalsmith-stretch),
   created in `pe_create`, freed in `pe_destroy`. New render Pass 1.5: when
   `deck_keylock` is set **and** the deck is off nominal speed (|ratio−1|>1e-3
   or |semis|>1e-2), the block is run through `PD_TP_KEYLOCK` at unity length to
   undo the varispeed pitch shift and apply `−12·log2(ratio) + semitones`. Flat
   or key-lock off ⇒ the block is untouched (bit-exact). `Deck.keyLock` didSet
   publishes `control.deck_keylock`. *Test: key-lock vs varispeed outputs
   diverge at +12 % and stay finite.*
3. **Per-deck beat echo (§35A)** — ✅. `PE_CMD_ECHO_SET` (`i0`=on, `f0`=beats,
   `f1`=depth, `i1`=feedback·1000, `i2`=keep-tail). A `pd_delay` line per deck in
   the deck chain (after EQ/filter), period = `beats · 60/effectiveBPM`; live =
   dry + depth·repeats, released = repeats-only with a 3 s decaying tail.
   `Deck.setEcho(enabled:beats:depth:feedback:)`. *Test: tail is audible right
   after disable and decays.*
4. **Record tap + segments + interruption** — ✅. `pe_record_set_active` /
   `pe_record_drain` / `pe_record_dropped_frames` / `pe_record_reset`; a ~4 s
   stereo ring the render thread fills and the control side drains (drop-and-
   count when it falls behind — the render thread never blocks). `MixRecorder`
   gains `flushSegment(to:)` + `droppedFrames`; `DJEngine`/`HeadlessDJEngine`
   get `startRecording(_:)` / `interruptRecording(to:)` / `stopRecording()` /
   `droppedRecordFrames`; `HeadlessDJEngine.render` auto-drains, `DJEngine` runs
   a 20 Hz `Task` pump. *Tests: a headless render feeds the tap and yields a
   playable WAV at the right tone with zero drops; interrupt mid-stream flushes
   a complete segment file and the resumed take is its own file.* **Carried:**
   M4A-joiner byte parity vs Tonearm's `M4AJoiner` is a 6d check — PAE encodes
   each segment as a standalone file via `ExportCodec`, no cross-segment
   container joining.
5. **`CueMode` + split-output** — ✅. `control.cue_mode`; `Monitoring.cueMode`
   (`CueMode { off, splitOutput, cueInPlace, multichannel }`). `splitOutput`
   sums master→mono-left, cue→mono-right in `pe_render_monitor`; `off` and
   `cueInPlace` keep the exact blended-mono path (offline harness unaffected);
   `multichannel` is honest-inert. *Tests: split-output carries master on L and
   cue on R; `off` ≡ `cueInPlace` render.*
6. **Integer-sample transport** — ✅. `PE_CMD_SEEK` / `PE_CMD_SET_CUE` /
   `PE_CMD_HOTCUE_SET` take `i1` int32 samples when `i2 == 1`; `PE_CMD_SET_LOOP`
   takes `i0`=active / `i1`=start / `i2`=end when `f0 == -1`. Half-open loops via
   the existing wrap logic. Swift: `Deck.seek(toSample:quantized:)`,
   `setCue(atSample:)`, `setLoop(startSample:endSample:)`,
   `triggerHotCue(_:atSample:)`. Float-seconds paths untouched. *Tests: seek
   lands on the exact sample; integer loop bounds are `[start, end)`.*
7. **`QuantizeResolution` grain** — ✅. `QuantizeResolution` enum
   (⅛-beat … 4-bar); `Deck.quantizeResolution` feeds `quantizedTime` — sub-beat
   / multi-beat grains snap to `anchor + round((t−anchor)/step)·step`; `.beat`
   reproduces the prior grid/quarter-note snap. Control-side (no C change), per
   finding 6. *Test: half-beat grain snaps a 0.32 s cue to 0.25 s.*
8. **Limiter bypass state** — ✅. `control.limiter_enabled` (default 1);
   `render()` Pass 4 skips `pd_limiter_process` when 0. `MasterOut.limiterEnabled`.
   *Test: bypass lets the master peak exceed a −12 dB ceiling.*
9. **Graph recovery** — ✅. `DJEngine.recoverGraph()` tears down and rebuilds the
   `AVAudioSourceNode` graph via a shared `buildGraph()` without recreating the
   `EngineBridge` (deck buffers / playheads / control survive);
   `configurationChanges() -> AsyncStream<Void>` observes
   `.AVAudioEngineConfigurationChange`. `sampleRate` / `bufferPeriodMillis`
   surfaced. *Tests: `recoverGraph()` keeps `isRunning` + the loaded deck; the
   change stream is vended.*

**6b exit:** `swift test --filter ParsoDJEngineTests` **60/60**;
`swift test -c release` green; whole-package scheme builds for watchOS + iOS
(no new platform deps — `signalsmith-stretch` / `pd_delay` / `pd_timepitch`
were already vendored and portable).

### 6b — deferred slivers (carried to 6c / the author, with rationale)

- **Render-side continuous sync integrator** (part of item 2). The control-side
  re-derivation delivers the observable behaviour and telemetry; a per-callback
  render-side rate integrator (spec re-derivation of `SyncClock`/`SyncCorrection`)
  is a larger, higher-risk change whose only additional benefit is sample-locked
  phase under sustained master tempo automation. Do it with the 6d A-B pass.
- **`syncNudge` sample-accurate scheduling** (part of item 2). `Deck.nudge`
  stays a transient rate bend; a scheduled sample-exact playhead shift at the
  callback boundary is a small follow-up once the render-side integrator lands.
- **M4A cross-segment joiner parity** (part of item 4). PAE writes each segment
  as a standalone `ExportCodec` file; matching Tonearm's `M4AJoiner` container
  concatenation byte-for-byte is a 6d recording-parity check.

## 6c — the adapter ✅ (2026-09-04, `parso-tonearm` `audio-engine-unification`)

`parso-tonearm/Sources/DJ/Engine/PAEWorkspaceEngine.swift` —
`@MainActor final class PAEWorkspaceEngine: WorkspaceEngine` over
`ParsoDJEngine.DJEngine`. Every one of the 55 `WorkspaceEngine` members maps to
PAE control objects; nothing downstream of the seam changed.

- **Build wiring:** `TonearmDJ` + `TonearmDJTests` gain
  `.product(name: "ParsoDJEngine", package: "parso-audio-engine")` in
  `Package.swift`. `DJEntryModel.makeModel` selects the engine at its one
  construction site: `#if PAE_DJ_ENGINE` → `PAEWorkspaceEngine`, else the
  GPLv3 `PerformanceEngine` (unchanged, still the default). Both conform to
  `WorkspaceEngine`; `WorkspaceModel(engine: any WorkspaceEngine)` is untouched.
- **`DeckSource` bridge:** `pcmBuffer(from:)` de-interleaves the raw
  `UnsafeRawPointer` PCM into a `ParsoAudioCore.PCMBuffer`; `trackAnalysis(from:)`
  synthesises the minimal `ParsoAudioAnalysis.TrackAnalysis` PAE's `Deck.load`
  needs from `DeckGrid` (bpm → `tempo.bpm`; grid → `beatPositions` +
  `downbeatPositions` at `beatsPerBar`). The adapter keeps its own strong refs
  to every backing buffer (deck + 4 stem voices) — the `SourceBoxRegistry`
  analogue — so a reload cannot free memory an in-flight callback still reads.
- **Control mapping:** fresh EQ knob→dB curve (`eqKnobToDB` — 0 → unity,
  +1 → +6 dB, −1 → −∞ kill, `30x/(1+x)` dB taper between; **not**
  `ThreeBandEQ.knobToGain`); crossfader `CrossfaderCurve {constantPower,linear,
  sharp}` → `Mixer.Curve {smooth,linear,sharp}`; limiter dB↔linear with `nil`
  when `limiterEnabled == false`; rate ratio → `tempoPercent` on `tempoRange
  .wide`; global quantize → both decks + grid grain; Tonearm `QuantizeResolution`
  / `StemKind` / `CueMode` → the PAE enums (by case / rawValue); per-deck echo
  params accumulated and pushed together to `Deck.setEcho`; sample-addressed
  hot cues kept in a rotating 8-slot map over PAE's index-keyed API.
- **Telemetry:** `sampleTelemetry()` builds `EngineTelemetry` from
  `DJEngine.telemetry()` (`EngineStats`) + the `@MainActor` deck/channel/master
  props; `EngineTelemetryStream` (Tonearm's, already AVFoundation-free) vends it.
- **Recording:** `MixRecorder` per session dir (`.aac(bitrate: 256_000)` M4A);
  `interruptRecordingForInterruption` flushes a complete segment via
  `DJEngine.interruptRecording(to:)` and appends it to the segment list;
  `stopRecording` assembles `RecordingEncoder.RecordingOutput` from the
  segments (`totalFrames` from the master-sample delta — see 6d checks).
- **Tests:** `Tests/DJTests/PAEWorkspaceEngineTests.swift` (4) — conformance +
  control calls without a graph, the EQ knob curve, the `DeckSource`
  de-interleave + grid synthesis, a finite telemetry snapshot. Both build
  configs compile: default (`PerformanceEngine`) and `-D PAE_DJ_ENGINE`
  (`PAEWorkspaceEngine`). `swift build --target TonearmDJ[Tests]` green in both.

### 6c — carried into 6d

1. **`PerformanceEngine.Deck` is still the seam's deck-enum type.** The
   `WorkspaceEngine` protocol types every deck arg as `PerformanceEngine.Deck`.
   When 6d deletes `PerformanceEngine.swift`, extract a standalone
   `public enum Deck: UInt8 { case a, b }` and repoint the protocol + adapter.
2. **Golden-audio re-baseline (author decision).** `Tests/DJTests` EQ / filter /
   crossfader / limiter goldens are cut against `PerformanceEngine`'s
   `render()`. They must be re-baselined against the PAE renderer (via
   `HeadlessDJEngine` or `ParsoDJEngineTests`) with a written rationale — "PAE
   ships the `pd_eq3` RBJ isolator + `pd_filter` + look-ahead `pd_limiter`; the
   knob curves are the adapter's, the DSP is PAE's" — plus the **author A-B
   perceptual pass on ≥3 real tracks** the plan gates the cutover on.
3. **`EngineOfflineTests` has no `PAEWorkspaceEngine` path.** Those sample-exact
   assertions drive `PerformanceEngine.render()`. 6d either rewrites them onto
   `HeadlessDJEngine` or accepts `ParsoDJEngineTests`' 60 FLX4 acceptance tests
   as the replacement coverage (they already assert sample-exact transport).
4. **Recording frame-count + M4A parity.** `totalFrames` is a master-sample
   delta, not an exact encoder count; cross-segment M4A joining is PAE
   per-segment `ExportCodec` files vs Tonearm's `M4AJoiner`. Already flagged in
   "6b — deferred slivers"; confirm against `RecordingEncoderTests` in 6d.
5. **Stems `StemKind` uses `rawValue` string bridging** — Tonearm and PAE both
   spell the four voices `vocals/drums/bass/other`, so `init(rawValue:)` is a
   total map; a rename on either side would silently drop a voice. Pin with a
   round-trip test in 6d.

## 6d backlog (the cutover) — not started

Delete the GPLv3 `parso-tonearm/Sources/DJ/Engine/` renderer files
(`AudioGraph`, `PerformanceEngine`, `Mixer`, `BeatEcho`, `CommandRing`,
`CueLoop`, `RTCommand`, `RTGuard`, `Scheduler`, `SyncEngine`, `RenderLoad`,
`EngineLiveness`, `EngineSnapshot`, `TimePitch`); **keep** the value types the
6a C5 table marks original-work (`DeckGrid`/`DeckSource` in `DeckClock.swift`,
`StemSet`, `QuantizeResolution`, `CueMode`, `CrossfaderCurve` enum,
`EngineTelemetry`). Make `-D PAE_DJ_ENGINE` the default (or drop the flag).
Re-baseline the goldens (item 2 above) + the author A-B pass. Full Tonearm
pre-commit hook on the final commit.

## 6c backlog (the "adapter" set) — as originally frozen

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

## Pre-6b close-out (2026-09-03) — the three "still owed" items, resolved

Full line reads done: `parso_engine_stub.cpp` (1072), `parso_dsp_stub.cpp`
(776), `parso_engine.h`, `ParsoDJEngine.swift` sync/load/master paths, and the
Tonearm value types (`DeckClock.swift`, `StemVoices.swift`, `SyncEngine.swift`,
`EngineTelemetry.swift`, `RTCommand.swift`, `CueBus.swift`, `Mixer.swift`,
`StemModel.swift`). New findings, and corrections to rows above:

### C1 — `parso_engine_stub.cpp` is literally a stub; the mature DSP is unused

`render()` / `renderMonitor()` hand-roll their own one-pole 2-band EQ
(`processEQ`, 200 Hz / 2 kHz splits), a bounded 6-kind ColorFX
(`processColorFX`, 24000-sample fixed delay), a 13-kind bus BeatFX
(`processBeatFX`, 48000-sample delay), and a per-sample soft limiter
(`processLimiter`). **None of `CParsoDSP`'s kernels (`pd_eq3` RBJ isolator,
`pd_filter` resonant sweep, `pd_delay`, `pd_reverb` Freeverb, `pd_limiter`
look-ahead) are called by the engine.** So:

- **Mixer parity re-baseline (§35 rows) is against `processEQ`/`processColorFX`/
  `crossfadeGains`/`processLimiter`, not the RBJ kernels.** The engine's EQ is
  2-band (low/high one-pole, mid = residue), not a 3-band isolator — knob→dB
  mapping in the adapter has to target *that*. This is a bigger delta from
  Tonearm's `ThreeBandEQ` than the audit assumed; the golden re-baseline
  rationale must say "PAE ships a 2-band shelving approximation in the stub
  renderer" explicitly.
- **6b decision point:** either (a) wire the `CParsoDSP` kernels into
  `render()` (they exist, are allocation-free, already unit-tested) and
  re-baseline once against the good DSP, or (b) keep the stub math and
  re-baseline against it. (a) is more work now but is the only path that makes
  the "PAE mixer is the reference" decision actually mean a Pioneer-grade
  mixer. **Recommend (a); add as 6b item 0.**

### C2 — time-pitch / key-lock is vendored but NOT wired (corrects finding 4)

`pd_timepitch` (signalsmith-stretch, `pd_tp_process`, KEYLOCK vs VARISPEED) is
compiled and C-wrapped, but `parso_engine_stub.cpp` never instantiates or calls
it. The deck render path does varispeed only, by linear interpolation in
`sampleAt` + `positionIncrement` scaling. `PE_CMD_SET_KEYLOCK` is in the
`applyCommand` switch as an explicit no-op (L379). `control.deck_pitch[]` /
`pd_tp_set_pitch_semitones` is stored and never read. `ParsoDJEngine`'s
`Deck.keyLock` / `pitchSemitones` therefore currently change **nothing
audible**.
→ The lib worry is indeed moot (header-only, portable, done). But wiring
signalsmith into each deck's reader — block-based `pd_tp_process` feeding the
deck output, mode follows `keyLock`, transpose follows `pitchSemitones`,
`timeRatio` follows the sync/tempo rate — is **new 6b work**, not a
finding-4 freebie. Add as 6b item 2a (alongside the master clock, since the
synced-deck rate has to drive `pd_tp_set_time_ratio`).

### C3 — `pe_deck_set_buffer` is not RT-safe for a live swap; no `PE_EVT_BUFFER_RELEASED`

`PE_EVT_BUFFER_RELEASED` appears only in the header enum — **it is never
pushed anywhere in `parso_engine_stub.cpp`.** `pe_deck_set_buffer` mutates
`DeckState` fields (channel pointers, `frames`, `sampleRate`, `position`, loop
state, the 24000-float `colorDelay` array zeroed in a loop) directly on the
calling thread with no double-buffer and no atomic publish, while `render()`
reads the same fields on the RT thread. `ParsoDJEngine.Deck.load` calls it
synchronously from `@MainActor` and keeps the `PCMBuffer` alive only by holding
one strong `self.buffer` ref — the previous buffer is freed the instant that
property is reassigned, with no fence against an in-flight callback still
holding the old raw channel pointers.
→ 6b item (was "verify" on the `load(_:source:)` row, now a confirmed port):
a real RT-safe deck buffer publish — pointer-swap via an atomic generation
counter or a pending-slot the RT thread adopts at the top of `render()`, plus
`PE_EVT_BUFFER_RELEASED` emitted with the retired pointer so the control side
(the adapter's `SourceBoxRegistry` equivalent) frees on the event, not on
reassignment. Applies equally to `pe_deck_set_stem_buffer` (6b item 1).

### C4 — sync one-shot confirmed at the source (reinforces finding 1)

`Deck.refreshSyncFromMasterIfNeeded()` is called from exactly two places:
`Deck.sync()` and `EngineBridge.setMaster()` (L173–175). `updatePlaybackRate()`
— the `tempoPercent` / `pitchSemitones` / `tempoRange` `didSet` — does **not**
re-run it. So a master-deck pitch move provably does not drag the synced deck;
the only "sync" is the single `PE_CMD_SYNC` seek at engage time. `PE_CMD_SYNC`
in the C++ (L447–458) is a bare position seek; there is no `unsync`, no master
BPM, no `barSync`. Finding 1's "single biggest item after stems" stands.

### C5 — value-type dispositions (resolves item 3)

| Tonearm type | Shape | Adapter disposition |
|---|---|---|
| `DeckGrid` (`DeckClock.swift`) | `referenceSample:Double, bpm, beatsPerBar:Int, sampleRate` + `beatPhase`/`barPhase`/`samplesPerBeat` pure kernels | **keep as original-work file** in `Sources/DJ/Engine/` (spec-derived math, §30.1/§32.3; re-header as MIT-or-app-owned, no engine deps). Adapter builds it from `TrackAnalysis.tempo`. |
| `DeckSource` | `pcm:UnsafeRawPointer, frameCount:Int64, channelCount:Int, sampleRate, grid:DeckGrid` — pure POD, boxed for `loadArm` | **keep**; the adapter's bridge target. Maps to `PCMBuffer` + minimal `TrackAnalysis` for `Deck.load`, OR (better, if the RT-safe C path lands per C3) straight to a new `pe_deck_set_buffer` variant taking the grid. |
| `StemSet` | 4× `DeckSource` (vocals/drums/bass/other), equal-length/equal-rate preconditions | **keep**; feeds 4× `pe_deck_set_stem_buffer` (6b item 1). |
| `StemKind` (`Sources/DJ/Stems/StemModel.swift`) | `String` enum + `.index` 0–3 + `.fileName` | **keep** (already app-side, not engine). `.index` is the RT payload. |
| `QuantizeResolution` (`DeckClock.swift`) | `UInt8` enum `halfBeat/beat/bar/fourBars` + `divisionCount(beatsPerBar:)` | **keep**; adapter holds it (control-side snap per finding 6). PAE's `Deck.quantize` is a bare `Bool` — no PAE type to replace it with. |
| `CueMode` (`CueBus.swift`) | `String` enum `off/splitOutput/cueInPlace/multichannel` + `displayName` | **keep**; drives 6b item 5. `off` must stay bit-exact (offline harness). |
| `CrossfaderCurve` (`Mixer.swift`) | `Float` enum — **`constantPower=0` / `linear=1` / `sharp=2`** (audit row §35 wrongly said `smooth`) + free `crossfaderGains(_:_:)` | **keep the enum**; do **not** keep `crossfaderGains` (GPLv3, and PAE's `crossfadeGains` curve buckets differ: `<0.25` cos/sin, `<0.75` linear, else hard-at-0.5, vs Tonearm's `0.4` overlap on sharp). Adapter maps enum → PAE `xfade_curve` 0.0/0.5/1.0. Re-baseline crossfader goldens. |
| `SyncClock` / `SyncCorrection` / `SyncEngine` (`SyncEngine.swift`) | pure §32.3 math, value types only | **re-derive spec-side** into PAE (`ParsoDJEngine`) as the render-side master-clock/continuous-rate kernel (6b item 2). Semantics only from `SyncEngine.swift` — it is GPLv3. The math is small: `targetRate = masterEffBPM / syncedGridBPM`; `continuousRate = masterRate·masterBPM/syncedBPM`; phase diff in `(−0.5, 0.5]`. |
| `EngineTelemetry` (`EngineTelemetry.swift`) | `masterSample:Int64, masterBPM, downbeatPhase, deckA/deckB:{playheadSample:Int64, bpmEffective, phase, level:Float, playing, synced}, masterLevel:Float, renderLoad:Double` — **no `droppedRecordFrames`, no starved-frame field** (those are on the `WorkspaceEngine` protocol, not this struct) | **keep the struct** (pure value above the seam, plan already said so). The pump must fill: `masterSample` ← C3-adjacent master frame counter; `masterBPM`/`downbeatPhase` ← 6b master clock; per-deck `playheadSample` ← `PE_EVT_PLAYHEAD.frame`; `bpmEffective`/`phase`/`synced` ← 6b render-side effective-rate + sync state (finding-2 atomics); `level` ← `PE_EVT_PEAK`; `playing` ← `PE_EVT_STATE`; `masterLevel` ← `PE_EVT_PEAK deck −1`; `renderLoad` ← new atomic (6b, telemetry-fields row). `EngineTelemetryStream` stays verbatim (already AVFoundation-free, `.bufferingNewest(1)`). |

`WorkspaceEngine.droppedRecordFrames` and the starved-frame counter stay in the
recording-tap / render-load 6b items — they are protocol members the adapter
synthesizes from polled atomics, not `EngineTelemetry` struct fields.

### Net effect on the 6b backlog

Add **item 0** (wire `CParsoDSP` kernels into `render()` + one mixer-golden
re-baseline) and fold **key-lock/pitch wiring** into item 2 as **2a**. Item on
the `load` row is upgraded from "verify" to a confirmed port (C3). Everything
else in the frozen backlog stands.
