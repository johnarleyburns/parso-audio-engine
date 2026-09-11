#!/usr/bin/env python3
"""Run and index a named-route PipeWire restart recording acceptance session."""

from __future__ import annotations

import argparse
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import time


SUMMARY_PATTERN = re.compile(
    r"linux PipeWire host: (?P<rendered>\d+) frames, peak (?P<peak>[-+0-9.e]+), "
    r"capture blocks (?P<capture>\d+), recorded (?P<recorded>\d+), "
    r"dropped record frames (?P<record_dropped>\d+)"
)
RECOVERY_PATTERN = re.compile(r"stream recoveries (?P<recoveries>\d+)")
OUTPUT_GAP_PATTERN = re.compile(r"dropped output blocks (?P<gaps>\d+)")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=Path("build-native"))
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--seconds", type=float, default=30.0)
    parser.add_argument("--restart-after", type=float, default=5.0)
    parser.add_argument("--output-target", required=True)
    parser.add_argument("--capture-target", default=None)
    parser.add_argument("--pw-cat", type=Path, default=None)
    parser.add_argument(
        "--restart-command",
        nargs="+",
        default=["systemctl", "--user", "restart", "pipewire", "pipewire-pulse"],
    )
    args = parser.parse_args()
    if args.seconds < 30.0:
        parser.error("route-restart artifacts must contain at least 30 seconds")
    if not args.seconds.is_integer():
        parser.error("seconds must be an integer because the native host uses whole seconds")
    if not 0.0 < args.restart_after < args.seconds:
        parser.error("restart-after must be greater than zero and less than seconds")
    return args


def run(args: argparse.Namespace) -> int:
    repo_root = Path(__file__).resolve().parents[1]
    build_dir = (repo_root / args.build_dir).resolve()
    output_dir = (repo_root / args.output_dir).resolve()
    if output_dir.exists() and any(output_dir.iterdir()):
        raise ValueError(f"output directory must be empty: {output_dir}")
    output_dir.mkdir(parents=True, exist_ok=True)

    host = build_dir / "parso_linux_pipewire_host"
    if not host.is_file():
        raise ValueError(f"PipeWire host is missing: {host}")
    record_path = output_dir / "route-restart.wav"
    log_path = output_dir / "route-restart.log"
    sidecar_path = output_dir / "route-restart.json"
    manifest_path = output_dir / "manifest.json"

    command = [
        str(host),
        "--seconds",
        str(int(args.seconds)),
        "--output-target",
        args.output_target,
        "--record",
        str(record_path),
        "--allow-output-gaps",
    ]
    if args.capture_target:
        command.extend(["--capture", "--capture-target", args.capture_target])
    if args.pw_cat:
        command.extend(["--pw-cat", str(args.pw_cat.resolve())])

    with log_path.open("w", encoding="utf-8") as log:
        process = subprocess.Popen(command, cwd=repo_root, stdout=log, stderr=subprocess.STDOUT)
        try:
            time.sleep(args.restart_after)
            subprocess.run(args.restart_command, cwd=repo_root, check=True)
        except BaseException:
            process.terminate()
            process.wait()
            raise
        result = process.wait()

    log_text = log_path.read_text(encoding="utf-8")
    if result != 0:
        raise RuntimeError(f"PipeWire host failed with status {result}; see {log_path}\n{log_text}")

    summary = SUMMARY_PATTERN.search(log_text)
    recoveries = RECOVERY_PATTERN.search(log_text)
    output_gaps = OUTPUT_GAP_PATTERN.search(log_text)
    if not summary or not recoveries or not output_gaps:
        raise RuntimeError(f"PipeWire host summary is incomplete; see {log_path}\n{log_text}")

    expected_frames = round(args.seconds * 48_000)
    rendered = int(summary["rendered"])
    recorded = int(summary["recorded"])
    record_dropped = int(summary["record_dropped"])
    recovery_count = int(recoveries["recoveries"])
    output_gap_count = int(output_gaps["gaps"])
    if rendered != expected_frames or recorded != expected_frames:
        raise RuntimeError(
            f"incomplete route-restart session: rendered={rendered}, recorded={recorded}, "
            f"expected={expected_frames}"
        )
    if record_dropped != 0 or recovery_count == 0:
        raise RuntimeError(
            f"invalid route-restart result: record drops={record_dropped}, "
            f"recoveries={recovery_count}"
        )

    indexer_path = repo_root / "scripts" / "index-linux-acceptance.py"
    indexer_spec = importlib.util.spec_from_file_location("parso_acceptance_indexer", indexer_path)
    if indexer_spec is None or indexer_spec.loader is None:
        raise RuntimeError(f"cannot load WAV indexer: {indexer_path}")
    indexer = importlib.util.module_from_spec(indexer_spec)
    indexer_spec.loader.exec_module(indexer)
    wav_info = indexer.read_wav(record_path)
    if (
        wav_info["formatTag"] != 3
        or wav_info["channels"] != 2
        or wav_info["sampleRateHz"] != 48_000
        or wav_info["bitsPerSample"] != 32
        or wav_info["frames"] != expected_frames
    ):
        raise RuntimeError(f"unexpected route-restart WAV format: {wav_info}")

    sidecar = {
        "schemaVersion": 1,
        "fixtureID": "linux-pipewire-named-route-restart",
        "scenario": "pipewire-route-restart-recording",
        "audioDuration": args.seconds,
        "analysisDuration": args.seconds,
        "sampleRateHz": 48_000,
        "channelCount": 2,
        "reviewStatus": "pending",
        "device": {
            "outputTarget": args.output_target,
            "captureTarget": args.capture_target,
            "restartCommand": args.restart_command,
        },
        "acceptance": {
            "renderedFrames": rendered,
            "recordedFrames": recorded,
            "recordDroppedFrames": record_dropped,
            "streamRecoveries": recovery_count,
            "outputGapBlocks": output_gap_count,
            "wav": wav_info,
        },
        "events": [
            {"time": 0.0, "type": "route-restart-session-start"},
            {"time": args.restart_after, "type": "pipewire-route-restart"},
            {"time": args.seconds, "type": "route-restart-session-end"},
        ],
    }
    sidecar_path.write_text(json.dumps(sidecar, indent=2) + "\n", encoding="utf-8")
    subprocess.run(
        [
            sys.executable,
            str(repo_root / "scripts/index-linux-acceptance.py"),
            "--root",
            str(output_dir),
            "--output",
            str(manifest_path),
        ],
        cwd=repo_root,
        check=True,
    )
    print(manifest_path)
    return 0


def main() -> int:
    args = parse_args()
    try:
        return run(args)
    except (OSError, subprocess.SubprocessError, ValueError, RuntimeError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
