#!/usr/bin/env python3
"""Build and run the native/Python Linux crossfader acceptance gate."""

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


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--build-dir", type=Path, default=Path("build-native"))
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--library", type=Path, default=None)
    parser.add_argument("--seconds", type=float, default=30.0)
    parser.add_argument("--tolerance", type=int, default=2)
    parser.add_argument("--no-build", action="store_true")
    args = parser.parse_args()
    if args.seconds < 30.0:
        parser.error("acceptance artifacts must contain at least 30 seconds")
    if args.tolerance < 0:
        parser.error("tolerance must be non-negative")

    repo_root = Path(__file__).resolve().parents[1]
    build_dir = (repo_root / args.build_dir).resolve()
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
    if not args.no_build:
        run(["cmake", "--build", str(build_dir), "--target", "parso_native_acceptance_artifacts"],
            cwd=repo_root)
    if not native_executable.is_file():
        parser.error(f"native acceptance executable is missing: {native_executable}")
    if not library.is_file():
        parser.error(f"native library is missing: {library}")

    run(
        [str(native_executable), "--output-dir", str(native_dir), "--seconds", str(args.seconds),
         "--scenario", "crossfader-sweep"],
        cwd=repo_root,
    )
    environment = dict(os.environ)
    python_path = str(repo_root / "bindings/python")
    environment["PYTHONPATH"] = python_path + os.pathsep + environment.get("PYTHONPATH", "")
    environment["PARSO_AUDIO_LIBRARY"] = str(library)
    run(
        [sys.executable, str(repo_root / "bindings/python/examples/render_acceptance.py"),
         "--library", str(library), "--scenario", "crossfader-sweep",
         "--output-dir", str(python_dir), "--seconds", str(args.seconds)],
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
