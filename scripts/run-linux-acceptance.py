#!/usr/bin/env python3
"""Build and run the native/Python Linux music crossfader acceptance gate."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys


def run(command: list[str], *, cwd: Path, environment: dict[str, str] | None = None) -> None:
    print("+", " ".join(command))
    subprocess.run(command, cwd=cwd, env=environment, check=True)


def fixture_path(fixture_root: Path, fixture_id: str) -> Path:
    manifest_path = fixture_root / "fixtures.json"
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    fixture = next((track for track in manifest["tracks"] if track["id"] == fixture_id), None)
    if fixture is None:
        raise ValueError(f"unknown fixture '{fixture_id}'; check {manifest_path}")
    if fixture.get("sourceFormat") != "mp3":
        raise ValueError(
            f"fixture '{fixture_id}' is {fixture.get('sourceFormat')}, not mp3; "
            "the Linux music gate intentionally uses real MP3 fixtures"
        )
    path = fixture_root / "audio" / f"{fixture_id}.mp3"
    if not path.is_file():
        raise ValueError(f"fixture is not downloaded: {path}; run ./scripts/download-fixtures.sh")
    return path.resolve()


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=Path("build-native"))
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--library", type=Path, default=None)
    parser.add_argument("--seconds", type=float, default=30.0)
    parser.add_argument("--tolerance", type=int, default=2)
    parser.add_argument("--fixture-root", type=Path, default=Path("Tests/Fixtures"))
    parser.add_argument("--fixture-a", default="gostreyshen_world")
    parser.add_argument("--fixture-b", default="tea_roots_isrc_usuan1100472")
    parser.add_argument("--no-build", action="store_true")
    args = parser.parse_args()
    if args.seconds < 30.0:
        parser.error("acceptance artifacts must contain at least 30 seconds")
    if args.tolerance < 0:
        parser.error("tolerance must be non-negative")

    repo_root = Path(__file__).resolve().parents[1]
    build_dir = (repo_root / args.build_dir).resolve()
    fixture_root = (repo_root / args.fixture_root).resolve()
    output_dir = (repo_root / args.output_dir).resolve()
    if output_dir.exists() and any(output_dir.iterdir()):
        parser.error(f"output directory must be empty: {output_dir}")
    output_dir.mkdir(parents=True, exist_ok=True)
    native_dir = output_dir / "native"
    python_dir = output_dir / "python"
    native_dir.mkdir()
    python_dir.mkdir()
    library = (repo_root / args.library).resolve() if args.library else build_dir / "libparso.so"
    native_executable = build_dir / "parso_native_acceptance_artifacts"
    input_mp3_a = fixture_path(fixture_root, args.fixture_a)
    input_mp3_b = fixture_path(fixture_root, args.fixture_b)
    if not args.no_build:
        run(["cmake", "--build", str(build_dir), "--target", "parso_native_acceptance_artifacts"],
            cwd=repo_root)
    if not native_executable.is_file():
        parser.error(f"native acceptance executable is missing: {native_executable}")
    if not library.is_file():
        parser.error(f"native library is missing: {library}")

    run(
        [str(native_executable), "--output-dir", str(native_dir), "--seconds", str(args.seconds),
         "--scenario", "crossfader-sweep", "--input-mp3-a", str(input_mp3_a),
         "--input-mp3-b", str(input_mp3_b), "--fixture-a", args.fixture_a,
         "--fixture-b", args.fixture_b],
        cwd=repo_root,
    )
    environment = dict(os.environ)
    python_path = str(repo_root / "bindings/python")
    environment["PYTHONPATH"] = python_path + os.pathsep + environment.get("PYTHONPATH", "")
    environment["PARSO_AUDIO_LIBRARY"] = str(library)
    run(
         [sys.executable, str(repo_root / "bindings/python/examples/render_acceptance.py"),
         "--library", str(library), "--scenario", "crossfader-sweep",
         "--output-dir", str(python_dir), "--seconds", str(args.seconds),
         "--input-mp3-a", str(input_mp3_a), "--input-mp3-b", str(input_mp3_b),
         "--fixture-a", args.fixture_a, "--fixture-b", args.fixture_b],
        cwd=repo_root,
        environment=environment,
    )

    manifest = output_dir / "manifest.json"
    run([sys.executable, str(repo_root / "scripts/index-linux-acceptance.py"),
         "--root", str(output_dir), "--output", str(manifest)], cwd=repo_root)
    comparison = output_dir / "comparison.json"
    run([sys.executable, str(repo_root / "scripts/compare-linux-acceptance.py"),
         "--left", str(native_dir / "native-crossfader-sweep.json"),
         "--right", str(python_dir / "python-crossfader-sweep.json"),
         "--tolerance", str(args.tolerance), "--output", str(comparison)], cwd=repo_root)
    report = json.loads(comparison.read_text(encoding="utf-8"))
    summary = {
        "schemaVersion": 1,
        "scenario": "crossfader-sweep",
        "fixtureA": args.fixture_a,
        "fixtureB": args.fixture_b,
        "seconds": args.seconds,
        "manifest": str(manifest),
        "comparison": str(comparison),
        "passed": bool(report.get("passed")),
    }
    summary_path = output_dir / "summary.json"
    summary_path.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(summary_path)
    return 0 if summary["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
