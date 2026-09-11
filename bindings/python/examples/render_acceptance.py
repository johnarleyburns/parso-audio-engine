"""Render a deterministic 30-second native-engine WAV and review sidecar."""

from __future__ import annotations

import argparse
from array import array
import json
import math
from pathlib import Path

from parso_audio import AudioCodec, CodecOptions, CodecServices, Engine
from parso_audio.acceptance import mp3_prefix


def render(
    seconds: float,
    output_dir: Path,
    library_path: str | None,
    scenario: str,
    input_mp3_a: Path | None = None,
    input_mp3_b: Path | None = None,
    fixture_a: str | None = None,
    fixture_b: str | None = None,
) -> None:
    if seconds < 30.0:
        raise ValueError("acceptance artifacts must contain at least 30 seconds")
    if scenario not in ("python-headless-tone", "crossfader-sweep"):
        raise ValueError(f"unsupported acceptance scenario: {scenario}")
    if (input_mp3_a is None) != (input_mp3_b is None):
        raise ValueError("both input_mp3_a and input_mp3_b are required for music acceptance")
    music = input_mp3_a is not None
    if music and scenario != "crossfader-sweep":
        raise ValueError("MP3 inputs are supported only by the crossfader-sweep scenario")

    sample_rate = 48_000
    total_frames = int(seconds * sample_rate)
    source_fixture_a = fixture_a or (input_mp3_a.stem if input_mp3_a else None)
    source_fixture_b = fixture_b or (input_mp3_b.stem if input_mp3_b else None)
    if music:
        with CodecServices(library_path) as audio:
            raw_a = mp3_prefix(input_mp3_a.read_bytes(), seconds)
            raw_b = mp3_prefix(input_mp3_b.read_bytes(), seconds)
            decoded_a = audio.decode(raw_a, AudioCodec.MP3)
            decoded_b = audio.decode(raw_b, AudioCodec.MP3)
        source = decoded_a.samples
        source_b = decoded_b.samples
        source_sample_rate_a = decoded_a.sample_rate_hz
        source_sample_rate_b = decoded_b.sample_rate_hz
        source_channels_a = decoded_a.channel_count
        source_channels_b = decoded_b.channel_count
        if decoded_a.frames < total_frames * source_sample_rate_a / sample_rate:
            raise RuntimeError(f"MP3 input A decoded to only {decoded_a.frames} frames")
        if decoded_b.frames < total_frames * source_sample_rate_b / sample_rate:
            raise RuntimeError(f"MP3 input B decoded to only {decoded_b.frames} frames")
    else:
        source = array(
            "f",
            (
                0.18 * math.sin(
                    2.0 * math.pi * (220.0 if index < total_frames // 2 else 330.0)
                    * index / sample_rate
                )
                for index in range(total_frames)
            ),
        )
        source_b = (
            array(
                "f",
                (
                    0.18 * math.sin(
                        2.0 * math.pi * (330.0 if index < total_frames // 2 else 495.0)
                        * index / sample_rate
                    )
                    for index in range(total_frames)
                )
            )
            if scenario == "crossfader-sweep"
            else None
        )
        source_sample_rate_a = sample_rate
        source_sample_rate_b = sample_rate
        source_channels_a = 1
        source_channels_b = 1
    left = array("f")
    right = array("f")
    events = [{"time": 0.0, "type": "play-deck-a"}]
    with Engine(max_frames=512, library_path=library_path) as engine:
        engine.set_master_level(0.8)
        engine.set_deck_buffer(0, source, source_sample_rate_a, source_channels_a)
        if source_b is not None:
            engine.set_deck_buffer(1, source_b, source_sample_rate_b, source_channels_b)
        engine.play(0)
        if source_b is not None:
            engine.play(1)
            events.extend(
                [
                    {"time": 0.0, "type": "play-deck-b"},
                    {"time": 0.0, "type": "crossfader-start-minus-one"},
                    {"time": seconds, "type": "crossfader-end-plus-one"},
                ]
            )
        engine.set_record_active(True)
        remaining = total_frames
        rendered = 0
        while remaining:
            block = min(512, remaining)
            if source_b is not None:
                engine.set_crossfader(-1.0 + 2.0 * rendered / max(1, total_frames - 1))
            engine.render(block)
            block_left, block_right = engine.record_drain(block)
            if len(block_left) != block or len(block_right) != block:
                raise RuntimeError("native record ring returned an incomplete acceptance block")
            left.extend(block_left)
            right.extend(block_right)
            remaining -= block
            rendered += block

    interleaved = array("f")
    for left_sample, right_sample in zip(left, right):
        interleaved.extend((left_sample, right_sample))
    with CodecServices(library_path) as audio:
        encoded = audio.encode(
            interleaved,
            sample_rate,
            2,
            AudioCodec.WAV,
            CodecOptions(bits_per_sample=16),
        )
        decoded = audio.decode(encoded, AudioCodec.WAV)
        summary = audio.analyze(decoded.samples, decoded.sample_rate_hz, decoded.channel_count)
        waveform_min, waveform_max = audio.waveform(
            decoded.samples, decoded.sample_rate_hz, decoded.channel_count, 32
        )

    output_dir.mkdir(parents=True, exist_ok=True)
    stem = output_dir / (
        "python-headless-tone" if scenario == "python-headless-tone"
        else "python-crossfader-sweep"
    )
    (stem.with_suffix(".wav")).write_bytes(encoded)
    sidecar = {
        "fixtureID": (
            "generated-python-tone" if scenario == "python-headless-tone"
            else "python-music-crossfader" if music
            else "generated-python-crossfader"
        ),
        "sourceTracks": ([
            {"fixtureID": source_fixture_a, "format": "mp3", "path": str(input_mp3_a)},
            {"fixtureID": source_fixture_b, "format": "mp3", "path": str(input_mp3_b)},
        ] if music else []),
        "scenario": scenario,
        "audioDuration": total_frames / sample_rate,
        "analysisDuration": total_frames / sample_rate,
        "sampleRateHz": sample_rate,
        "channelCount": 2,
        "analysis": {
            "durationSeconds": summary.duration_seconds,
            "rms": summary.rms,
            "peak": summary.peak,
            "bpm": summary.bpm,
            "bpmConfidence": summary.bpm_confidence,
        },
        "waveform": {
            "min": list(waveform_min),
            "max": list(waveform_max),
        },
        "events": events,
    }
    (stem.with_suffix(".json")).write_text(json.dumps(sidecar, indent=2) + "\n", encoding="utf-8")
    print(stem.with_suffix(".wav"))
    print(stem.with_suffix(".json"))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--seconds", type=float, default=30.0)
    parser.add_argument("--library", default=None)
    parser.add_argument("--input-mp3-a", type=Path, default=None)
    parser.add_argument("--input-mp3-b", type=Path, default=None)
    parser.add_argument("--fixture-a", default=None)
    parser.add_argument("--fixture-b", default=None)
    parser.add_argument("--scenario", default="python-headless-tone",
                        choices=("python-headless-tone", "crossfader-sweep"))
    args = parser.parse_args()
    render(
        args.seconds, args.output_dir, args.library, args.scenario,
        args.input_mp3_a, args.input_mp3_b, args.fixture_a, args.fixture_b,
    )


if __name__ == "__main__":
    main()
