"""Render every Linux headless-engine listening scenario from real audio fixtures."""

from __future__ import annotations

import argparse
from array import array
from dataclasses import dataclass
import json
import math
from pathlib import Path
from typing import Callable

from parso_audio import AudioCodec, CodecOptions, CodecServices, Engine, EngineCommand, IsolatorProfile
from parso_audio.acceptance import mp3_prefix


SAMPLE_RATE = 48_000
BLOCK_SIZE = 512
SCENARIO_SECONDS = 30.0


@dataclass(frozen=True)
class Track:
    fixture_id: str
    path: Path
    source_format: str
    samples: array
    sample_rate_hz: int
    channel_count: int
    bpm: float


@dataclass(frozen=True)
class Scenario:
    name: str
    description: str
    deck_a: str
    deck_b: str | None


SCENARIOS = (
    Scenario("crossfader-sweep", "manual rotary crossfade", "house", "electronic"),
    Scenario("smart-fader", "BPM-matched same-genre transition with bass duck and echo tail", "smart-fader-a", "smart-fader-b"),
    Scenario("smart-cfx", "one-track wash, filter, and sweep CFX presets", "smart-cfx", None),
    Scenario("beatfx-echo-out", "beat-synced echo-out release before the incoming track", "beatfx-a", "beatfx-b"),
    Scenario("scratch", "overview of record-control and fader scratch primitives", "scratch", None),
    Scenario("scratch-foundations", "baby, scribble, drag, forward, and backward foundation scratches", "scratch", None),
    Scenario("scratch-cuts", "chirp, one- and two-click flare, orbit, transform, and crab scratches", "scratch", None),
    Scenario("scratch-combos", "tear, twiddle, and boomerang combination scratches", "scratch", None),
    Scenario("turntable-manipulation", "pitch bend, platter drag, motor-off, hydroplane, and tone play", "scratch", None),
    Scenario("beat-juggle", "two-deck beat juggling with a second hip-hop record", "scratch", "scratch-b"),
    Scenario("phasing-flanging", "two copies of the disco record drifting into phase and flange", "scratch", "scratch"),
    Scenario("loop-and-cue", "cue, hot-cue jump, quantized loop, and exit before the incoming track", "loop-a", "loop-b"),
    Scenario("warm2-isolator", "one-track 300 Hz/4 kHz fourth-order three-band master isolator", "warm2", None),
)

TRACK_SLOTS = (
    "house", "electronic", "smart-fader-a", "smart-fader-b", "smart-cfx",
    "beatfx-a", "beatfx-b", "scratch", "scratch-b", "loop-a", "loop-b", "warm2",
)

SCRATCH_INVENTORY = {
    "scratch": ["record-control overview"],
    "scratch-foundations": ["baby scratch", "scribble", "drag / strobe", "forward cutting", "backward cutting"],
    "scratch-cuts": ["chirp", "1-click flare", "2-click flare", "orbit", "transform", "crab"],
    "scratch-combos": ["tear", "twiddle", "boomerang"],
    "turntable-manipulation": ["pitch bend / platter", "motor off", "hydroplane", "tone play"],
    "beat-juggle": ["beat juggling with distinct disco and hip-hop records"],
    "phasing-flanging": ["phasing / flanging with two copies of the disco record"],
}


def clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def event(time: float, event_type: str) -> dict[str, float | str]:
    return {"time": round(time, 3), "type": event_type}


def render_scenario(
    scenario: Scenario,
    tracks: dict[str, Track],
    seconds: float,
    library_path: str | None,
) -> tuple[array, array, list[dict[str, float | str]]]:
    total_frames = int(seconds * SAMPLE_RATE)
    track_a = tracks[scenario.deck_a]
    track_b = tracks[scenario.deck_b] if scenario.deck_b else None
    delayed_deck_b = scenario.name in {"beatfx-echo-out", "loop-and-cue"}
    isolated_deck = scenario.deck_b is None
    events: list[dict[str, float | str]] = [event(0.0, "play-deck-a")]
    if not delayed_deck_b and not isolated_deck:
        events.append(event(0.0, "play-deck-b"))
    pending: list[tuple[float, str, Callable[[Engine], None]]] = []

    def add(time: float, name: str, action: Callable[[Engine], None]) -> None:
        pending.append((time, name, action))

    def jog_sequence(start: float, name: str, deltas: tuple[float, ...], interval: float = 0.14,
                     release: bool = True) -> None:
        """Schedule a named vinyl-hand pattern from real jog commands."""

        events.append(event(start, f"{name}-start"))
        add(start, f"{name}-start", lambda engine: engine.jog_touch(0, vinyl_mode=True, was_playing=True))
        for index, delta in enumerate(deltas):
            time = start + 0.08 + index * interval
            events.append(event(time, f"{name}-stroke"))
            add(time, f"{name}-stroke", lambda engine, delta=delta: engine.jog_move(0, delta))
        if release:
            end = start + 0.08 + len(deltas) * interval
            events.append(event(end, f"{name}-end"))
            add(end, f"{name}-end", lambda engine: engine.jog_release(0, vinyl_mode=True, was_playing=True))

    if scenario.name == "crossfader-sweep":
        events.extend((event(0.0, "crossfader-start-minus-one"), event(seconds, "crossfader-end-plus-one")))
    elif scenario.name == "smart-fader":
        events.extend((event(0.0, "smart-fader-start-house-pair"), event(21.0, "smart-fader-echo-tail"), event(24.0, "smart-fader-complete")))
    elif scenario.name == "smart-cfx":
        for time, name in ((0.0, "smart-cfx-wash"), (10.0, "smart-cfx-filter"), (20.0, "smart-cfx-sweep"), (30.0, "smart-cfx-off")):
            events.append(event(time, name))
    elif scenario.name == "beatfx-echo-out":
        events.extend((event(8.0, "beatfx-echo-out-engage"),
                       event(22.0, "beatfx-echo-out-release"),
                       event(24.0, "play-deck-b-after-echo-tail")))
        add(22.0, "beatfx-echo-out-release", lambda engine: engine.post_command(EngineCommand.BEATFX_RELEASE))
        add(24.0, "play-deck-b-after-echo-tail", lambda engine: engine.play(1))
    elif scenario.name == "scratch":
        jog_sequence(3.0, "baby-scratch", (2200.0, -2200.0, 1800.0, -1800.0, 1400.0, -1400.0), 0.24)
        jog_sequence(7.0, "chirp-scratch", (900.0, -450.0, 900.0, -450.0, 650.0, -325.0), 0.24)
        jog_sequence(11.0, "scribble-scratch", (260.0, -260.0) * 12, 0.07)
        jog_sequence(14.5, "transform-scratch", (700.0, -700.0) * 7, 0.20)
        add(18.0, "backspin-start", lambda engine: (engine.set_slip(0, True), engine.set_reverse(0, True)))
        add(20.0, "backspin-release", lambda engine: engine.set_reverse(0, False))
        events.append(event(20.0, "backspin-release"))
    elif scenario.name == "scratch-foundations":
        jog_sequence(3.0, "baby-scratch", (2400.0, -2400.0, 1900.0, -1900.0, 1500.0, -1500.0), 0.24)
        jog_sequence(7.0, "scribble-scratch", (280.0, -280.0) * 18, 0.06)
        jog_sequence(11.0, "drag-strobe", (360.0,) * 15, 0.18)
        jog_sequence(16.0, "forward-cut", (1900.0, -900.0, 1600.0, -700.0, 1300.0, -500.0), 0.28)
        jog_sequence(21.0, "backward-cut", (-1900.0, 900.0, -1600.0, 700.0, -1300.0, 500.0), 0.28)
    elif scenario.name == "scratch-cuts":
        jog_sequence(3.0, "chirp-scratch", (1100.0, -550.0, 1100.0, -550.0, 850.0, -425.0, 850.0, -425.0), 0.20)
        jog_sequence(8.0, "one-click-flare", (1200.0, -700.0) * 8, 0.16)
        jog_sequence(13.0, "two-click-flare", (1200.0, -700.0) * 8, 0.12)
        jog_sequence(18.0, "orbit-flare", (1000.0, -500.0, -1000.0, 500.0) * 4, 0.14)
        jog_sequence(23.0, "transform-scratch", (650.0, -650.0) * 7, 0.18)
        jog_sequence(27.0, "crab-scratch", (420.0, -420.0) * 8, 0.09)
    elif scenario.name == "scratch-combos":
        jog_sequence(3.0, "tear-scratch", (1300.0, 0.0, 900.0, -1200.0, 0.0, -800.0, 1100.0, 0.0, 700.0), 0.42)
        jog_sequence(10.0, "twiddle-scratch", (850.0, -425.0) * 8, 0.16)
        jog_sequence(17.0, "boomerang-scratch", (1200.0, -500.0, 300.0, -1100.0,
                                                    1100.0, -300.0, 500.0, -1200.0) * 2, 0.20)
    elif scenario.name == "turntable-manipulation":
        events.extend((event(3.0, "pitch-bend-platters-start"), event(7.0, "pitch-bend-platters-end"),
                       event(13.0, "motor-off-start"), event(18.0, "motor-off-release"),
                       event(20.0, "hydroplane-start"), event(24.0, "hydroplane-end"),
                       event(25.0, "tone-play-start"), event(29.0, "tone-play-end")))
        add(13.0, "motor-off-start", lambda engine: (engine.set_vinyl_speed(0, 3.0, 1.0), engine.pause(0)))
        add(18.0, "motor-off-release", lambda engine: engine.play(0))
        jog_sequence(20.0, "hydroplane", (240.0,) * 16, 0.20)
    elif scenario.name == "beat-juggle":
        events.extend((event(3.0, "beat-juggle-start"), event(13.0, "beat-juggle-end")))
        add(3.0, "beat-juggle-start", lambda engine: (engine.set_hotcue(0, 0, 0.5), engine.set_hotcue(1, 0, 0.5)))
        add(13.0, "beat-juggle-end", lambda engine: (engine.set_slip(0, False), engine.set_slip(1, False)))
        for index in range(8):
            time = 4.0 + index * 1.0
            deck = index % 2
            events.append(event(time, "beat-juggle-hotcue-a" if deck == 0 else "beat-juggle-hotcue-b"))
            add(time, "beat-juggle-hotcue", lambda engine, deck=deck: engine.jump_hotcue(deck, 0))
    elif scenario.name == "phasing-flanging":
        events.extend((event(3.0, "phasing-flanging-start"), event(13.0, "phasing-flanging-drift"),
                       event(27.0, "phasing-flanging-end")))
        add(3.0, "phasing-flanging-start", lambda engine: (engine.seek(0, 1.0), engine.seek(1, 1.0)))
    elif scenario.name == "loop-and-cue":
        events.extend((event(3.0, "set-primary-cue"), event(6.0, "set-hotcue-1"),
                       event(10.0, "quantized-four-beat-loop"), event(18.0, "jump-hotcue-1"),
                       event(24.0, "loop-exit"), event(26.0, "play-deck-b-after-loop-cue")))
        add(3.0, "set-primary-cue", lambda engine: engine.set_cue(0))
        add(6.0, "set-hotcue-1", lambda engine: engine.set_hotcue(0, 0))
        add(10.0, "quantized-four-beat-loop", lambda engine: engine.beat_loop(0, 4.0))
        add(18.0, "jump-hotcue-1", lambda engine: engine.jump_hotcue(0, 0))
        add(24.0, "loop-exit", lambda engine: engine.post_command(EngineCommand.RELOOP_EXIT, 0))
        add(26.0, "play-deck-b-after-loop-cue", lambda engine: engine.play(1))
    elif scenario.name == "warm2-isolator":
        events.extend((event(5.0, "warm2-bass-cut"), event(10.0, "warm2-mid-cut"), event(15.0, "warm2-treble-cut"), event(20.0, "warm2-all-band-boost"), event(25.0, "warm2-flat-restore")))

    pending.sort(key=lambda item: item[0])
    left = array("f")
    right = array("f")
    profile = IsolatorProfile.WARM2 if scenario.name == "warm2-isolator" else IsolatorProfile.GENERIC
    with Engine(max_frames=BLOCK_SIZE, isolator_profile=profile, library_path=library_path) as engine:
        engine.set_deck_buffer(0, track_a.samples, track_a.sample_rate_hz, track_a.channel_count)
        if track_b:
            engine.set_deck_buffer(1, track_b.samples, track_b.sample_rate_hz, track_b.channel_count)
        engine.play(0)
        if not delayed_deck_b and not isolated_deck:
            engine.play(1)
        rendered = 0
        event_index = 0
        while rendered < total_frames:
            time = rendered / SAMPLE_RATE
            while event_index < len(pending) and pending[event_index][0] <= time + 1e-9:
                pending[event_index][2](engine)
                event_index += 1

            crossfader = 0.0
            eq_low = [0.0, 0.0, 0.0, 0.0]
            color_amount = [0.0, 0.0, 0.0, 0.0]
            color_kind = [0.0, 0.0, 0.0, 0.0]
            color_param = [0.5, 0.5, 0.5, 0.5]
            faders = [1.0, 1.0, 1.0, 1.0]
            beatfx_kind = 0.0
            beatfx_beats = 0.5
            beatfx_depth = 0.0
            beatfx_assign = 3.0
            beatfx_on = False
            reverb_send = 0.0
            time_ratio = [1.0, 1.0, 1.0, 1.0]
            deck_pitch = [0.0, 0.0, 0.0, 0.0]
            deck_keylock = [1.0, 1.0, 0.0, 0.0]
            master_eq = [0.0, 0.0, 0.0]

            if scenario.name == "crossfader-sweep":
                crossfader = -1.0 + 2.0 * rendered / max(1, total_frames - 1)
            elif scenario.name == "smart-fader":
                p = clamp(time / 24.0, 0.0, 1.0)
                eased = 0.5 - 0.5 * math.cos(math.pi * p)
                crossfader = -1.0 + 2.0 * eased
                incoming_gain = min(1.0, p / 0.6)
                outgoing_cut = (p - 0.6) / 0.4 if p > 0.6 else 0.0
                eq_low[1] = -24.0 * (1.0 - incoming_gain)
                eq_low[0] = -24.0 * clamp(outgoing_cut, 0.0, 1.0)
                if track_a.bpm > 0 and track_b.bpm > 0:
                    time_ratio[1] = clamp(track_a.bpm / track_b.bpm, 0.5, 2.0)
                if 16.8 <= time < 24.0:
                    beatfx_kind, beatfx_depth, beatfx_on = 1.0, 0.6, True
            elif scenario.name == "smart-cfx":
                preset = min(2, int(time / 10.0))
                beatfx_kind = (2.0, 6.0, 5.0)[preset]
                beatfx_beats = (0.5, 1.0, 0.5)[preset]
                beatfx_depth = (0.55, 0.65, 0.60)[preset]
                beatfx_on = time < 30.0
                reverb_send = (0.35, 0.12, 0.25)[preset]
            elif scenario.name == "beatfx-echo-out":
                crossfader = -1.0 if time < 24.0 else -1.0 + 2.0 * clamp((time - 24.0) / 6.0, 0.0, 1.0)
                if 8.0 <= time < 22.0:
                    beatfx_kind, beatfx_depth, beatfx_on = 1.0, 0.72, True
                elif time >= 22.0:
                    beatfx_kind, beatfx_depth, beatfx_on = 1.0, 0.72, False
            elif scenario.name == "scratch":
                crossfader = -1.0
                if 18.0 <= time < 20.0:
                    faders[0] = 0.0 if int((time - 18.0) * 8.0) % 2 else 1.0
                deck_keylock[0] = 0.0
            elif scenario.name == "scratch-foundations":
                crossfader = -1.0
                deck_keylock[0] = 0.0
                if 16.0 <= time < 24.0:
                    faders[0] = 0.0 if int((time - 16.0) * 2.0) % 2 else 1.0
            elif scenario.name == "scratch-cuts":
                crossfader = -1.0
                deck_keylock[0] = 0.0
                if 8.0 <= time < 13.0:
                    faders[0] = 0.0 if int((time - 8.0) / 0.24) % 2 else 1.0
                elif 13.0 <= time < 18.0:
                    faders[0] = 0.0 if int((time - 13.0) / 0.14) % 2 else 1.0
                elif 18.0 <= time < 23.0:
                    faders[0] = 0.0 if int((time - 18.0) / 0.16) % 2 else 1.0
                elif 23.0 <= time < 27.0:
                    faders[0] = 0.0 if int((time - 23.0) / 0.10) % 2 else 1.0
                elif 27.0 <= time:
                    faders[0] = 0.0 if int((time - 27.0) / 0.045) % 2 else 1.0
            elif scenario.name == "scratch-combos":
                crossfader = -1.0
                deck_keylock[0] = 0.0
                if 10.0 <= time < 17.0:
                    faders[0] = 0.0 if int((time - 10.0) / 0.16) % 2 else 1.0
                elif 17.0 <= time:
                    faders[0] = 0.0 if int((time - 17.0) / 0.18) % 2 else 1.0
            elif scenario.name == "turntable-manipulation":
                crossfader = -1.0
                deck_keylock[0] = 0.0
                if 3.0 <= time < 7.0:
                    phase = (time - 3.0) / 4.0
                    time_ratio[0] = 0.90 + 0.20 * (0.5 - 0.5 * math.cos(2.0 * math.pi * phase))
                elif 25.0 <= time:
                    tone_step = min(4, int((time - 25.0) / 0.8))
                    time_ratio[0] = (0.50, 0.75, 1.00, 1.25, 1.50)[tone_step]
            elif scenario.name == "beat-juggle":
                deck_keylock[0] = 0.0
                deck_keylock[1] = 0.0
                if track_a.bpm > 0 and track_b and track_b.bpm > 0:
                    time_ratio[1] = clamp(track_a.bpm / track_b.bpm, 0.5, 2.0)
                crossfader = -1.0 if time < 3.0 else (1.0 if time < 13.0 and int((time - 3.0) * 2.0) % 2 else -1.0)
            elif scenario.name == "phasing-flanging":
                deck_keylock[0] = 0.0
                deck_keylock[1] = 0.0
                crossfader = 0.0
                drift = 0.0015 * math.sin((time - 13.0) * math.pi / 4.0) if 13.0 <= time < 27.0 else 0.0
                time_ratio[1] = 1.0 + drift
            elif scenario.name == "loop-and-cue":
                crossfader = -1.0 if time < 26.0 else -1.0 + 2.0 * clamp((time - 26.0) / 4.0, 0.0, 1.0)
            elif scenario.name == "warm2-isolator":
                crossfader = -0.15 + 0.3 * clamp((time - 2.0) / 26.0, 0.0, 1.0)
                if 5.0 <= time < 10.0:
                    master_eq[0] = -70.0
                elif 10.0 <= time < 15.0:
                    master_eq[1] = -40.0
                elif 15.0 <= time < 20.0:
                    master_eq[2] = -70.0
                elif 20.0 <= time < 25.0:
                    master_eq = [12.0, 12.0, 12.0]

            engine.set_mixer_controls(
                crossfader=crossfader,
                xfade_assign=(0.0, 1.0, 2.0, 2.0),
                fader=tuple(faders),
                trim=(1.0, 1.0, 0.5, 0.5),
                eq_low=tuple(eq_low),
                color_amount=tuple(color_amount),
                color_kind=tuple(color_kind),
                color_param=tuple(color_param),
                deck_time_ratio=tuple(time_ratio),
                deck_pitch=tuple(deck_pitch),
                deck_keylock=tuple(deck_keylock),
                beatfx_kind=beatfx_kind,
                beatfx_beats=beatfx_beats,
                beatfx_depth=beatfx_depth,
                beatfx_assign=beatfx_assign,
                beatfx_on=beatfx_on,
                master_reverb_send=reverb_send,
                master_eq_low=master_eq[0],
                master_eq_mid=master_eq[1],
                master_eq_high=master_eq[2],
            )
            block = min(BLOCK_SIZE, total_frames - rendered)
            block_left, block_right = engine.render(block)
            left.extend(block_left)
            right.extend(block_right)
            rendered += block
    events.sort(key=lambda item: float(item["time"]))
    return left, right, events


def encode_wav(left: array, right: array, audio: CodecServices) -> bytes:
    interleaved = array("f")
    for left_sample, right_sample in zip(left, right):
        interleaved.extend((left_sample, right_sample))
    return audio.encode(interleaved, SAMPLE_RATE, 2, AudioCodec.WAV, CodecOptions(bits_per_sample=16))


def write_pair(
    output_dir: Path,
    stem: str,
    scenario: str,
    description: str,
    left: array,
    right: array,
    events: list[dict[str, float | str]],
    sources: list[Track],
    audio: CodecServices,
) -> None:
    wav = encode_wav(left, right, audio)
    decoded = audio.decode(wav, AudioCodec.WAV)
    analysis = audio.analyze(decoded.samples, decoded.sample_rate_hz, decoded.channel_count)
    minimum, maximum = audio.waveform(decoded.samples, decoded.sample_rate_hz, decoded.channel_count, 32)
    output_dir.mkdir(parents=True, exist_ok=True)
    (output_dir / f"{stem}.wav").write_bytes(wav)
    sidecar = {
        "fixtureID": f"linux-music-{scenario}",
        "scenario": scenario,
        "description": description,
        "scratchInventory": SCRATCH_INVENTORY.get(scenario, []),
        "audioDuration": len(left) / SAMPLE_RATE,
        "analysisDuration": len(left) / SAMPLE_RATE,
        "sampleRateHz": SAMPLE_RATE,
        "channelCount": 2,
        "sourceTracks": [
            {"fixtureID": track.fixture_id, "format": track.source_format, "path": str(track.path)}
            for track in sources
        ],
        "analysis": {
            "durationSeconds": analysis.duration_seconds,
            "rms": analysis.rms,
            "peak": analysis.peak,
            "bpm": analysis.bpm,
            "bpmConfidence": analysis.bpm_confidence,
        },
        "waveform": {"min": list(minimum), "max": list(maximum)},
        "events": events,
    }
    (output_dir / f"{stem}.json").write_text(json.dumps(sidecar, indent=2) + "\n", encoding="utf-8")


def render_all(
    output_dir: Path,
    tracks: dict[str, Track],
    library_path: str | None,
    seconds: float,
) -> None:
    with CodecServices(library_path) as audio:
        for scenario in SCENARIOS:
            left, right, events = render_scenario(scenario, tracks, seconds, library_path)
            sources = [tracks[scenario.deck_a]]
            if scenario.deck_b:
                sources.append(tracks[scenario.deck_b])
            write_pair(output_dir, f"python-{scenario.name}", scenario.name, scenario.description, left, right, events, sources, audio)


def load_track(path: Path, fixture_id: str, seconds: float, library_path: str | None) -> Track:
    suffix = path.suffix.lower()
    if suffix == ".mp3":
        source = mp3_prefix(path.read_bytes(), seconds)
        codec = AudioCodec.MP3
        source_format = "mp3"
    elif suffix == ".ogg":
        source = path.read_bytes()
        codec = AudioCodec.OGG_VORBIS
        source_format = "oggVorbis"
    else:
        raise ValueError(f"unsupported listening source format: {path}")
    with CodecServices(library_path) as audio:
        decoded = audio.decode(source, codec)
        analysis = audio.analyze(decoded.samples, decoded.sample_rate_hz, decoded.channel_count)
    needed = seconds * decoded.sample_rate_hz / SAMPLE_RATE
    if decoded.frames < needed:
        raise RuntimeError(f"{path} decoded to {decoded.frames} frames; need at least {needed:.0f}")
    return Track(fixture_id, path.resolve(), source_format, decoded.samples, decoded.sample_rate_hz, decoded.channel_count, analysis.bpm)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--library", default=None)
    parser.add_argument("--seconds", type=float, default=SCENARIO_SECONDS)
    for slot in TRACK_SLOTS:
        argument_slot = slot.replace("-", "_")
        parser.add_argument(f"--input-mp3-{slot}", f"--input-audio-{slot}", type=Path, required=True,
                            dest=f"input_mp3_{argument_slot}")
        parser.add_argument(f"--fixture-{slot}", required=True,
                            dest=f"fixture_{argument_slot}")
    args = parser.parse_args()
    if args.seconds < SCENARIO_SECONDS:
        parser.error("each scenario must contain at least 30 seconds")
    paths = {
        slot: (getattr(args, f"input_mp3_{slot.replace('-', '_')}"),
               getattr(args, f"fixture_{slot.replace('-', '_')}"))
        for slot in TRACK_SLOTS
    }
    if len({fixture_id for _, fixture_id in paths.values()}) != len(TRACK_SLOTS):
        parser.error("every listening slot must use a distinct MP3 fixture")
    tracks = {name: load_track(path, fixture_id, args.seconds, args.library) for name, (path, fixture_id) in paths.items()}
    render_all(args.output_dir, tracks, args.library, args.seconds)
    print(args.output_dir)


if __name__ == "__main__":
    main()
