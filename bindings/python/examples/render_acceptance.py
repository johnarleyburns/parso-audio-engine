"""Render a deterministic 30-second native-engine WAV and review sidecar."""

from __future__ import annotations

import argparse
from array import array
import json
import math
from pathlib import Path

from parso_audio import AudioCodec, CodecOptions, CodecServices, Engine


def render(seconds: float, output_dir: Path, library_path: str | None) -> None:
    if seconds < 30.0:
        raise ValueError("acceptance artifacts must contain at least 30 seconds")
    sample_rate = 48_000
    total_frames = int(seconds * sample_rate)
    source = array(
        "f",
        (
            0.18 * math.sin(2.0 * math.pi * (220.0 if index < total_frames // 2 else 330.0) * index / sample_rate)
            for index in range(total_frames)
        ),
    )
    left = array("f")
    right = array("f")
    with Engine(max_frames=512, library_path=library_path) as engine:
        engine.set_master_level(0.8)
        engine.set_deck_buffer(0, source, sample_rate, 1)
        engine.play(0)
        engine.set_record_active(True)
        remaining = total_frames
        while remaining:
            block = min(512, remaining)
            engine.render(block)
            block_left, block_right = engine.record_drain(block)
            if len(block_left) != block or len(block_right) != block:
                raise RuntimeError("native record ring returned an incomplete acceptance block")
            left.extend(block_left)
            right.extend(block_right)
            remaining -= block

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
    stem = output_dir / "python-headless-tone"
    (stem.with_suffix(".wav")).write_bytes(encoded)
    sidecar = {
        "fixtureID": "generated-python-tone",
        "scenario": "python-headless-tone",
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
        "events": [{"time": 0.0, "type": "play"}],
    }
    (stem.with_suffix(".json")).write_text(json.dumps(sidecar, indent=2) + "\n", encoding="utf-8")
    print(stem.with_suffix(".wav"))
    print(stem.with_suffix(".json"))


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--seconds", type=float, default=30.0)
    parser.add_argument("--library", default=None)
    args = parser.parse_args()
    render(args.seconds, args.output_dir, args.library)


if __name__ == "__main__":
    main()
