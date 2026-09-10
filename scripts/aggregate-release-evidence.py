#!/usr/bin/env python3
"""Aggregate machine-readable release gate reports without copying their artifacts."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import sys


def git_commit() -> str:
    try:
        return subprocess.check_output(
            ["git", "rev-parse", "HEAD"], text=True, stderr=subprocess.DEVNULL
        ).strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def load_gate(spec: str) -> dict:
    if "=" not in spec:
        raise ValueError(f"gate must be LABEL=PATH: {spec}")
    label, raw_path = spec.split("=", 1)
    if not label or not raw_path:
        raise ValueError(f"gate must be LABEL=PATH: {spec}")
    path = Path(raw_path)
    payload = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(payload, dict):
        raise ValueError(f"gate report is not an object: {path}")
    if "passed" in payload:
        passed = bool(payload["passed"])
    elif "errors" in payload:
        passed = not payload["errors"]
    else:
        raise ValueError(f"gate report has no passed/errors field: {path}")
    return {"label": label, "path": str(path), "passed": passed}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--gate", action="append", required=True,
                        help="machine report in LABEL=PATH form; may be repeated")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        gates = [load_gate(spec) for spec in args.gate]
    except (OSError, ValueError, json.JSONDecodeError) as error:
        report = {"schemaVersion": 1, "passed": False, "errors": [str(error)]}
    else:
        report = {
            "schemaVersion": 1,
            "generatedAt": datetime.now(timezone.utc).isoformat(),
            "gitCommit": git_commit(),
            "gates": gates,
            "passed": bool(gates) and all(gate["passed"] for gate in gates),
            "errors": [],
        }
        if not report["passed"]:
            report["errors"] = [
                f"gate failed: {gate['label']}" for gate in gates if not gate["passed"]
            ]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    for error in report.get("errors", []):
        print(f"error: {error}", file=sys.stderr)
    print(args.output)
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
