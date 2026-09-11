"""Render every Linux headless-engine listening scenario from real MP3 fixtures."""

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
    samples: array
    sample_rate_hz: int
    channel_count: int
    bpm: float


@dataclass(frozen=True)
class Scenario:
    name: str
    description: str
    deck_a: str
    deck_b: str


SCENARIOS = (
    Scenario("crossfader-sweep", "manual rotary crossfade", "house", "electronic"),
    Scenario("smart-fader", "BPM match, bass duck, eased transition, echo tail", "electronic", "classical"),
    Scenario("smart-cfx", "wash, filter, and gated one-knob CFX presets", "classical", "house"),
    Scenario("beatfx-echo-out", "beat-synced echo-out release and tail", "house", "classical"),
    Scenario("scratch", "vinyl touch, baby scratch, backspin, transformer, release", "classical", "electronic"),
    Scenario("loop-and-cue", "cue, hot-cue jump, quantized loop, and exit", "electronic", "house"),
    Scenario("warm2-isolator", "300 Hz/4 kHz fourth-order three-band master isolator", "house", "electronic"),
)


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
    track_b = tracks[scenario.deck_b]
    events: list[dict[str, float | str]] = [event(0.0, "play-deck-a"), event(0.0, "play-deck-b")]
    pending: list[tuple[float, str, Callable[[Engine], None]]] = []

    def add(time: float, name: str, action: Callable[[Engine], None]) -> None:
        pending.append((time, name, action))

    if scenario.name == "crossfader-sweep":
        events.extend((event(0.0, "crossfader-start-minus-one"), event(seconds, "crossfader-end-plus-one")))
    elif scenario.name == "smart-fader":
        events.extend((event(0.0, "smart-fader-start"), event(21.0, "smart-fader-echo-tail"), event(24.0, "smart-fader-complete")))
    elif scenario.name == "smart-cfx":
        for time, name in ((0.0, "smart-cfx-wash"), (10.0, "smart-cfx-filter"), (20.0, "smart-cfx-gate"), (30.0, "smart-cfx-off")):
            events.append(event(time, name))
    elif scenario.name == "beatfx-echo-out":
        events.extend((event(8.0, "beatfx-echo-out-engage"), event(22.0, "beatfx-echo-out-release")))
        add(22.0, "beatfx-echo-out-release", lambda engine: engine.post_command(EngineCommand.BEATFX_RELEASE))
    elif scenario.name == "scratch":
        events.extend((event(6.0, "vinyl-touch"), event(6.15, "baby-scratch-back"), event(6.45, "baby-scratch-forward"), event(6.8, "vinyl-release"), event(12.0, "backspin-start"), event(13.2, "backspin-release"), event(18.0, "transformer-gate"), event(20.0, "transformer-open")))
        add(6.0, "vinyl-touch", lambda engine: engine.post_command(EngineCommand.JOG_TOUCH, 0, i0=1, i1=1))
        add(6.15, "baby-scratch-back", lambda engine: engine.post_command(EngineCommand.JOG_MOVE, 0, f0=-18_000.0))
        add(6.45, "baby-scratch-forward", lambda engine: engine.post_command(EngineCommand.JOG_MOVE, 0, f0=24_000.0))
        add(6.8, "vinyl-release", lambda engine: engine.post_command(EngineCommand.JOG_RELEASE, 0, i0=1, i1=1))
        add(12.0, "backspin-start", lambda engine: (engine.set_slip(0, True), engine.post_command(EngineCommand.SET_REVERSE, 0, i0=1)))
        add(13.2, "backspin-release", lambda engine: engine.post_command(EngineCommand.SET_REVERSE, 0, i0=0))
    elif scenario.name == "loop-and-cue":
        events.extend((event(3.0, "set-primary-cue"), event(6.0, "set-hotcue-1"), event(10.0, "quantized-four-beat-loop"), event(18.0, "jump-hotcue-1"), event(24.0, "loop-exit")))
        add(3.0, "set-primary-cue", lambda engine: engine.set_cue(0))
        add(6.0, "set-hotcue-1", lambda engine: engine.set_hotcue(0, 0))
        add(10.0, "quantized-four-beat-loop", lambda engine: engine.beat_loop(0, 4.0))
        add(18.0, "jump-hotcue-1", lambda engine: engine.jump_hotcue(0, 0))
        add(24.0, "loop-exit", lambda engine: engine.post_command(EngineCommand.RELOOP_EXIT, 0))
    elif scenario.name == "warm2-isolator":
        events.extend((event(5.0, "warm2-bass-cut"), event(10.0, "warm2-mid-cut"), event(15.0, "warm2-treble-cut"), event(20.0, "warm2-all-band-boost"), event(25.0, "warm2-flat-restore")))

    pending.sort(key=lambda item: item[0])
    left = array("f")
    right = array("f")
    profile = IsolatorProfile.WARM2 if scenario.name == "warm2-isolator" else IsolatorProfile.GENERIC
    with Engine(max_frames=BLOCK_SIZE, isolator_profile=profile, library_path=library_path) as engine:
        engine.set_deck_buffer(0, track_a.samples, track_a.sample_rate_hz, track_a.channel_count)
        engine.set_deck_buffer(1, track_b.samples, track_b.sample_rate_hz, track_b.channel_count)
        engine.play(0)
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
                beatfx_kind = (0.0, 16.0, 7.0)[preset]
                beatfx_beats = (0.5, 1.0, 0.5)[preset]
                beatfx_depth = (0.72, 0.85, 0.75)[preset]
                beatfx_on = time < 30.0
                reverb_send = (0.48, 0.0, 0.28)[preset]
            elif scenario.name == "beatfx-echo-out":
                crossfader = -0.7 + 1.7 * clamp((time - 4.0) / 22.0, 0.0, 1.0)
                if 8.0 <= time < 22.0:
                    beatfx_kind, beatfx_depth, beatfx_on = 1.0, 0.72, True
                elif time >= 22.0:
                    beatfx_kind, beatfx_depth, beatfx_on = 1.0, 0.72, False
            elif scenario.name == "scratch":
                crossfader = -1.0
                if 18.0 <= time < 20.0:
                    faders[0] = 0.0 if int((time - 18.0) * 8.0) % 2 else 1.0
            elif scenario.name == "loop-and-cue":
                crossfader = -0.85 if time < 16.0 else 0.35
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
                deck_keylock=(1.0, 1.0, 0.0, 0.0),
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
        "audioDuration": len(left) / SAMPLE_RATE,
        "analysisDuration": len(left) / SAMPLE_RATE,
        "sampleRateHz": SAMPLE_RATE,
        "channelCount": 2,
        "sourceTracks": [
            {"fixtureID": track.fixture_id, "format": "mp3", "path": str(track.path)}
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
            sources = [tracks[scenario.deck_a], tracks[scenario.deck_b]]
            write_pair(output_dir, f"python-{scenario.name}", scenario.name, scenario.description, left, right, events, sources, audio)


def load_track(path: Path, fixture_id: str, seconds: float, library_path: str | None) -> Track:
    with CodecServices(library_path) as audio:
        decoded = audio.decode(mp3_prefix(path.read_bytes(), seconds), AudioCodec.MP3)
        analysis = audio.analyze(decoded.samples, decoded.sample_rate_hz, decoded.channel_count)
    needed = seconds * decoded.sample_rate_hz / SAMPLE_RATE
    if decoded.frames < needed:
        raise RuntimeError(f"{path} decoded to {decoded.frames} frames; need at least {needed:.0f}")
    return Track(fixture_id, path.resolve(), decoded.samples, decoded.sample_rate_hz, decoded.channel_count, analysis.bpm)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--library", default=None)
    parser.add_argument("--seconds", type=float, default=SCENARIO_SECONDS)
    for suffix in ("a", "b", "c"):
        parser.add_argument(f"--input-mp3-{suffix}", type=Path, required=True)
        parser.add_argument(f"--fixture-{suffix}", required=True)
    args = parser.parse_args()
    if args.seconds < SCENARIO_SECONDS:
        parser.error("each scenario must contain at least 30 seconds")
    paths = {
        "house": (args.input_mp3_a, args.fixture_a),
        "electronic": (args.input_mp3_b, args.fixture_b),
        "classical": (args.input_mp3_c, args.fixture_c),
    }
    tracks = {name: load_track(path, fixture_id, args.seconds, args.library) for name, (path, fixture_id) in paths.items()}
    render_all(args.output_dir, tracks, args.library, args.seconds)
    print(args.output_dir)


if __name__ == "__main__":
    main()
