# AGENTS.md — Implementation Handoff for `parso-audio-engine`

You are an autonomous coding agent. Your job is to turn this **test-driven scaffold** into a working,
shipping Swift 6 package that reaches **DDJ-FLX4 software equivalence**, implementing it **phase by
phase** and keeping a live phase ledger in `current_status.md` after **every commit**.

> Rename or symlink this file to `CLAUDE.md` if your tool prefers that — the content is the same.

Read these before writing code: `docs/SPEC.md` (source of truth), `docs/architecture.md`,
`docs/FLX4-feature-inventory.md` (acceptance target), `README.md`. The **tests are the executable
specification** — make them pass; do not rewrite them to be easier.

---

## 1. The operating loop (do this for every unit of work)

1. **Open `current_status.md`.** It tells you the current phase and next action. If it doesn't exist, create it from the template in §3 (it is untracked — see §3).
2. **Implement the smallest useful slice** of the current phase (§5), following `docs/SPEC.md`.
3. **Enable the matching test(s):** delete the `.disabled("…")` trait from the suite(s) listed for that slice. Never add a new `.disabled` to something already enabled just to get green.
4. **Build and test:** `swift build` then `swift test` (or `swift test --filter <Suite>` while iterating). Fixture suites need `./scripts/download-fixtures.sh` first (run once, before Phase 3).
5. **Green? Commit** (conventional commits, §4). One logical change per commit; `main` stays green.
6. **Immediately after the commit, overwrite `current_status.md`** with the current reality (§3). This is mandatory and happens after *every* commit, including chores and vendor drops.
7. Repeat. When every suite in a phase is enabled and green, advance the phase in `current_status.md` and continue.

A tiny `post-commit` reminder hook is optional and provided in §6, but **you** are responsible for the ledger's content.

---

## 2. Golden rules (non-negotiable)

- **Licenses:** only MIT / BSD / Apache-2.0 / public-domain third-party code, plus Apple frameworks. **Never** add GPL / LGPL / AGPL. If a task seems to require one, **STOP**, record a blocker in `current_status.md`, and move to an unblocked slice. The CI SPDX guard will fail the build if copyleft text lands in the tree.
- **Vendor real libraries** per each `Sources/C*/VENDOR.md`: copy unmodified upstream source, keep its `LICENSE`, record the source commit, then delete that target's `*_shim.h` + `placeholder.c`. Update `NOTICE.md` if anything changed.
- **Real-time safety:** no heap allocation, locks, syscalls, logging, IO, or Swift/ObjC runtime inside `pe_render` / `pe_step` or any `CParsoDSP` kernel. Smooth every continuous parameter (5–20 ms). `pe_render` (device) and `pe_step` (tests) **must share one DSP implementation** — the headless path is what the tests validate, so they cannot diverge.
- **C headers stay C-clean:** everything in `Sources/CParso*/include/*.h` must compile as C (no C++ in the header). Implementation is C++ in `src/`.
- **Swift 6 strict concurrency:** keep control objects `@MainActor`; only use `@unchecked Sendable` with a documented invariant. Do not silence warnings by weakening isolation.
- **Don't fabricate analysis ground truth.** Real-fixture BPM/key tests assert determinism + plausibility until a human verifies values. Only fill `expected.bpm` / `expected.key` in `Tests/Fixtures/fixtures.json` after actual verification, and say so in the commit + ledger.
- **Preserve layering:** no DJ concept (deck, crossfader, cue) may appear in `ParsoAudioCore`, `CParsoDSP`, or `ParsoAudioAnalysis`.
- **The spec is authoritative.** If a test looks wrong, do not quietly delete it. Record a "Spec question" in the ledger, change `docs/SPEC.md` **and** the test together in a deliberate `docs:`/`test:` commit explaining why.
- **Never `git add current_status.md`.** It is intentionally untracked.

---

## 3. `current_status.md` protocol (the phase ledger)

- It is **untracked** (listed in `.gitignore`). Never commit it. Overwrite it in full after every commit so it always reflects the real `swift test` result.
- Keep it terse and truthful. Exact template:

```markdown
# current_status.md  (untracked — do not commit)

Phase: 3 of 8 — ParsoAudioAnalysis
Slice: KeyEstimator (chroma + Krumhansl–Kessler)
Updated: 2026-08-31T21:40Z
Last commit: a1b2c3d  feat(analysis): chroma extraction + KK correlation

## Test state (from last `swift test`)
- Passing suites: 9   Skipped(.disabled): 7   Failing: 0
- Just enabled: "Key (synthetic)"
- Still disabled toward this phase: "Structure (synthetic)", "RealFixture Key", "RealFixture full analysis"

## Fixtures
- Downloaded: yes (18/18)   Verified expected values: 0/18

## Blockers / Spec questions
- (none)   # or: "BLOCKED: … — reason, what I tried, what I need"

## Next action
- Implement StructureAnalyzer (SPEC §5.3); enable "Structure (synthetic)".
```

If `current_status.md` is missing on first run, create it with `Phase: 0` and begin at §5 Phase 0.

---

## 4. Commit conventions

Conventional Commits, scoped by module:
`feat(core|analysis|engine|dsp): …`, `chore(vendor): drop libFLAC 1.4.3 (BSD-3)`,
`test(engine): enable Crossfader suite`, `docs(spec): clarify §5.2`, `fix(dsp): denormal guard`.
Keep `main` green: tests pass before you commit. Do focused commits — a vendor drop, an implementation
slice, and enabling its suite can be one commit or a small sequence, but each committed state should build.

---

## 5. Phases (realizes `docs/SPEC.md §19`)

Advance strictly in order; later phases depend on earlier ones. For each, implement per the cited SPEC
sections, then remove `.disabled` from the listed suites and get them green.

### Phase 0 — Verify scaffold & CI
`git init` if needed; ensure `swift build` and `swift test` run (green with skips) and CI is wired.
Confirm the already-enabled suites pass: **PCMBuffer, Signal generators, Key profiles, RealFixture
manifest, DJ API surface**. DoD: clean baseline, ledger created at Phase 0 → advance to Phase 1.

### Phase 1 — Decoders + Core IO / encode / SRC / loudness  (SPEC §2, §9)
Vendor `Cflac`, `Cvorbis`, `Copus`, `Cebur128`, `Csrc`. Implement `AudioFileReader`/`AudioFileWriter`
(FLAC→libFLAC, Ogg→stb_vorbis, Opus→libopusfile, MP3/AAC/ALAC/WAV/AIFF→Apple; encode WAV/FLAC/AAC/ALAC,
**no MP3**), `SampleRateConverter` (libsamplerate ≥ 0.2.2), `LoudnessAnalyzer` (libebur128).
Run `./scripts/download-fixtures.sh`.
**Enable:** `Codec roundtrip`, `Sample-rate conversion`, `Loudness`, `RealFixture decode`.

### Phase 2 — CParsoDSP kernels + time-pitch  (SPEC §6, §13)
Implement biquads/EQ, `Isolator3Band`, `SweepFilter`, delay, `Reverb` (Freeverb constants), flanger,
phaser, limiter, interpolator, and `TimePitch` (varispeed resampler + Signalsmith key-lock). Vendor
Signalsmith into `Sources/CParsoDSP/vendor/signalsmith`.
**Enable:** `Isolator EQ`, `Time / pitch`.

### Phase 3 — ParsoAudioAnalysis  (SPEC §5)
Implement `TempoEstimator` → `KeyEstimator` → `StructureAnalyzer` → `WaveformGenerator` → `TrackAnalyzer`
with vDSP.
**Enable:** `Tempo (synthetic)`, `Key (synthetic)`, `Structure (synthetic)`, `Waveform (synthetic)`,
`RealFixture BPM`, `RealFixture Key`, `RealFixture full analysis`. After they pass on plausibility,
verify a few tracks by ear and fill their `expected` values (note it in the ledger).

### Phase 4 — CParsoEngine RT graph + plumbing + headless  (SPEC §3, §7, §11)
Implement `pe_create`/`pe_render`/`pe_step`, the `ControlBlock` atomics, SPSC command/event rings,
resident deck buffers, two-deck mix → channel proc → crossfader → master chain → limiter. Wire
`HeadlessDJEngine` to `pe_step`.
**Enable:** `Crossfader`.

### Phase 5 — ParsoDJEngine features  (SPEC §11, §15)
Decks (transport, cue, tempo/keylock, jog/scratch, nudge), loops, 8 hot cues, sync/master/quantize,
slip, all 8 pad modes, mixer (trim, EQ, Color FX), Beat FX, sampler, mic, monitoring.
**Enable:** `Sync`, `Loops`, `Hot cues`, `Slip mode`, `Pad modes`.

### Phase 6 — Smart Fader / Smart CFX  (SPEC §11.5)
Assisted transition (auto BPM match + low-EQ duck + level automation + echo/reverb tail); one-knob CFX.
**Enable:** `Smart Fader`.

### Phase 7 — MixRecorder  (SPEC §11)
Off-thread master capture to WAV/FLAC/AAC/ALAC (no MP3). Add/enable a recording suite mirroring the
`Codec roundtrip` guarantees for the recorded stream.

### Phase 8 — Acceptance pass  (SPEC §15)
Walk every `[CORE]`/`[RB]` row in `docs/FLX4-feature-inventory.md`; ensure each maps to a passing test.
All suites enabled and green on iOS + macOS; NOTICE/SPDX clean; `pe_render` asserts zero allocations.
Tag `1.0.0-rc`.

---

## 6. Optional: post-commit reminder hook

```bash
# .git/hooks/post-commit  (chmod +x). Reminder only — you still write the content.
echo "↳ Update current_status.md now (untracked phase ledger)." 1>&2
```

## 7. When you are blocked

Record it in `current_status.md` under **Blockers** with what you tried and what you need, keep `main`
green, and pick up an unblocked slice if one exists. Do **not** unblock yourself by adding a copyleft
dependency, weakening a test, or faking analysis values. Surface it and move on.
