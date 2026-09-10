#!/usr/bin/env python3
"""Compare two Linux acceptance sidecars and their rendered WAV signals."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import struct
import sys


def read_wav(path: Path) -> tuple[dict[str, int | float], tuple[int, ...]]:
    data = path.read_bytes()
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError(f"{path}: not a RIFF/WAVE file")
    fmt_offset = data.find(b"fmt ", 12)
    data_offset = data.find(b"data", 12)
    if fmt_offset < 0 or data_offset < 0:
        raise ValueError(f"{path}: missing fmt or data chunk")
    audio_format, channels, sample_rate, _, block_align, bits = struct.unpack_from(
        "<HHIIHH", data, fmt_offset + 8
    )
    if audio_format != 1 or bits != 16:
        raise ValueError(f"{path}: comparator requires 16-bit PCM WAVE")
    payload_offset = data_offset + 8
    payload_size = struct.unpack_from("<I", data, data_offset + 4)[0]
    sample_count = payload_size // 2
    samples = struct.unpack_from(f"<{sample_count}h", data, payload_offset)
    frames = sample_count // channels
    if channels == 0 or block_align == 0 or sample_rate == 0 or frames * block_align != payload_size:
        raise ValueError(f"{path}: invalid PCM frame layout")
    return {
        "channels": channels,
        "sampleRateHz": sample_rate,
        "bitsPerSample": bits,
        "frames": frames,
        "durationSeconds": frames / sample_rate,
    }, samples


def compare(left_sidecar: Path, right_sidecar: Path, tolerance: int) -> dict:
    left_metadata = json.loads(left_sidecar.read_text(encoding="utf-8"))
    right_metadata = json.loads(right_sidecar.read_text(encoding="utf-8"))
    left_wav = left_sidecar.with_suffix(".wav")
    right_wav = right_sidecar.with_suffix(".wav")
    left_format, left_samples = read_wav(left_wav)
    right_format, right_samples = read_wav(right_wav)
    errors: list[str] = []
    if left_metadata.get("scenario") != right_metadata.get("scenario"):
        errors.append("scenario names differ")
    if left_format != right_format:
        errors.append("WAVE formats differ")
    if len(left_samples) != len(right_samples):
        errors.append("sample counts differ")
    left_events = left_metadata.get("events", [])
    right_events = right_metadata.get("events", [])
    if [event.get("type") for event in left_events] != [event.get("type") for event in right_events]:
        errors.append("event types differ")
    if len(left_events) == len(right_events):
        for index, (left_event, right_event) in enumerate(zip(left_events, right_events)):
            if abs(float(left_event.get("time", 0.0)) - float(right_event.get("time", 0.0))) > 0.001:
                errors.append(f"event {index} times differ")
    if len(left_samples) == len(right_samples):
        max_difference = max(
            (abs(left - right) for left, right in zip(left_samples, right_samples)),
            default=0,
        )
        mean_difference = (
            sum(abs(left - right) for left, right in zip(left_samples, right_samples))
            / len(left_samples)
            if left_samples else 0.0
        )
    else:
        max_difference = None
        mean_difference = None
    if max_difference is not None and max_difference > tolerance:
        errors.append(f"maximum PCM difference {max_difference} exceeds tolerance {tolerance}")
    return {
        "schemaVersion": 1,
        "left": str(left_sidecar),
        "right": str(right_sidecar),
        "scenario": left_metadata.get("scenario"),
        "format": left_format,
        "maxAbsoluteInt16Difference": max_difference,
        "meanAbsoluteInt16Difference": mean_difference,
        "tolerance": tolerance,
        "passed": not errors,
        "errors": errors,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--left", type=Path, required=True, help="first JSON sidecar")
    parser.add_argument("--right", type=Path, required=True, help="second JSON sidecar")
    parser.add_argument("--tolerance", type=int, default=2,
                        help="maximum allowed absolute 16-bit sample difference")
    parser.add_argument("--output", type=Path, required=True, help="comparison report JSON")
    args = parser.parse_args()
    if args.tolerance < 0:
        parser.error("tolerance must be non-negative")
    try:
        report = compare(args.left, args.right, args.tolerance)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        report = {"schemaVersion": 1, "passed": False, "errors": [str(error)]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    for error in report["errors"]:
        print(f"error: {error}", file=sys.stderr)
    print(args.output)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
