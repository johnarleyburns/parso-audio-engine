#!/usr/bin/env python3
"""Index Linux WAV/JSON acceptance artifacts for reproducible human review."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import struct
import subprocess
import sys


MINIMUM_REVIEW_SECONDS = 30.0


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def read_wav(path: Path) -> dict[str, int | float | str]:
    data = path.read_bytes()
    if len(data) < 12 or data[:4] != b"RIFF" or data[8:12] != b"WAVE":
        raise ValueError("not a RIFF/WAVE file")
    offset = 12
    format_info: tuple[int, int, int, int, int] | None = None
    data_bytes = 0
    while offset + 8 <= len(data):
        chunk_id = data[offset:offset + 4]
        chunk_size = struct.unpack_from("<I", data, offset + 4)[0]
        chunk_start = offset + 8
        chunk_end = chunk_start + chunk_size
        if chunk_end > len(data):
            raise ValueError(f"truncated {chunk_id.decode('ascii', 'replace')} chunk")
        if chunk_id == b"fmt " and chunk_size >= 16:
            audio_format, channels, sample_rate, _, block_align, bits = struct.unpack_from(
                "<HHIIHH", data, chunk_start
            )
            format_info = audio_format, channels, sample_rate, block_align, bits
        elif chunk_id == b"data":
            data_bytes = chunk_size
        offset = chunk_end + (chunk_size & 1)
    if format_info is None or data_bytes == 0:
        raise ValueError("missing fmt or data chunk")
    audio_format, channels, sample_rate, block_align, bits = format_info
    if channels == 0 or sample_rate == 0 or block_align == 0:
        raise ValueError("invalid WAVE format fields")
    if audio_format not in (1, 3, 0xFFFE):
        raise ValueError(f"unsupported WAVE format tag {audio_format}")
    frames = data_bytes // block_align
    return {
        "formatTag": audio_format,
        "channels": channels,
        "sampleRateHz": sample_rate,
        "bitsPerSample": bits,
        "frames": frames,
        "durationSeconds": frames / sample_rate,
    }


def git_commit() -> str:
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"], text=True, stderr=subprocess.DEVNULL
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def index(root: Path, excluded: set[Path] | None = None) -> dict:
    root = root.resolve()
    excluded = excluded or set()
    artifacts = []
    errors = []
    for sidecar in sorted(root.rglob("*.json")):
        if sidecar.resolve() in excluded or sidecar.name in {"manifest.json", "review-manifest.json"}:
            continue
        wav = sidecar.with_suffix(".wav")
        item_errors: list[str] = []
        try:
            metadata = json.loads(sidecar.read_text(encoding="utf-8"))
            if not isinstance(metadata, dict):
                raise ValueError("sidecar root is not an object")
        except (OSError, json.JSONDecodeError, ValueError) as error:
            item_errors.append(f"sidecar: {error}")
            metadata = {}
        wav_info = None
        if not wav.is_file():
            item_errors.append("matching WAV is missing")
        else:
            try:
                wav_info = read_wav(wav)
            except (OSError, ValueError) as error:
                item_errors.append(f"WAV: {error}")
        declared_duration = metadata.get("audioDuration")
        if not isinstance(declared_duration, (int, float)):
            item_errors.append("sidecar audioDuration is missing")
        elif declared_duration < MINIMUM_REVIEW_SECONDS:
            item_errors.append(
                f"audioDuration {declared_duration:.3f}s is below "
                f"the {MINIMUM_REVIEW_SECONDS:.0f}s review minimum"
            )
        if wav_info is not None and isinstance(declared_duration, (int, float)):
            if abs(float(wav_info["durationSeconds"]) - float(declared_duration)) > 0.02:
                item_errors.append("sidecar and WAV durations differ by more than 20 ms")
        relative_sidecar = sidecar.relative_to(root).as_posix()
        relative_wav = wav.relative_to(root).as_posix()
        artifact = {
            "id": metadata.get("fixtureID", sidecar.stem),
            "scenario": metadata.get("scenario", "unknown"),
            "fixtureID": metadata.get("fixtureID", "unknown"),
            "reviewStatus": "pending",
            "sidecar": {"path": relative_sidecar, "sha256": sha256(sidecar)},
            "audio": {
                "path": relative_wav,
                "sha256": sha256(wav) if wav.is_file() else None,
                "format": wav_info,
            },
            "errors": item_errors,
        }
        artifacts.append(artifact)
        errors.extend(f"{relative_sidecar}: {error}" for error in item_errors)
    if not artifacts:
        errors.append("no JSON/WAV artifact pairs found")
    return {
        "schemaVersion": 1,
        "generatedAt": datetime.now(timezone.utc).isoformat(),
        "gitCommit": git_commit(),
        "root": str(root),
        "reviewStatus": "pending",
        "artifacts": artifacts,
        "errors": errors,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True,
                        help="directory containing generated WAV/JSON pairs")
    parser.add_argument("--output", type=Path, required=True,
                        help="manifest JSON path")
    args = parser.parse_args()
    if not args.root.is_dir():
        parser.error(f"artifact root does not exist: {args.root}")
    manifest = index(args.root, {args.output.resolve()})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    for error in manifest["errors"]:
        print(f"error: {error}", file=sys.stderr)
    print(args.output)
    return 1 if manifest["errors"] else 0


if __name__ == "__main__":
    raise SystemExit(main())
