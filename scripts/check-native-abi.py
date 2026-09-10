#!/usr/bin/env python3
"""Check exported symbols and basic ELF identity for a native Parso library."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys


PUBLIC_SYMBOLS = (
    "parso_codec_read",
    "parso_codec_write",
    "parso_engine_create",
    "parso_engine_destroy",
    "parso_engine_render",
    "parso_engine_poll_events",
    "parso_engine_record_drain",
    "parso_waveform_generate",
)


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def command_output(command: list[str]) -> str:
    return subprocess.check_output(command, text=True, stderr=subprocess.STDOUT)


def check(
    path: Path,
    required: tuple[str, ...],
    expected_class: str | None = None,
    expected_machine: str | None = None,
) -> dict:
    symbol_output = command_output(["nm", "-D", "--defined-only", str(path)])
    symbols = {
        line.split()[-1]
        for line in symbol_output.splitlines()
        if line.split()
    }
    missing = sorted(symbol for symbol in required if symbol not in symbols)
    elf_header = command_output(["readelf", "-h", str(path)])
    identity = {
        line.split(":", 1)[0].strip(): line.split(":", 1)[1].strip()
        for line in elf_header.splitlines()
        if ":" in line
    }
    errors = [f"missing exported symbol: {symbol}" for symbol in missing]
    if expected_class and identity.get("Class") != expected_class:
        errors.append(
            f"ELF class is {identity.get('Class', '<missing>')!r}; expected {expected_class!r}"
        )
    if expected_machine and identity.get("Machine") != expected_machine:
        errors.append(
            f"ELF machine is {identity.get('Machine', '<missing>')!r}; expected {expected_machine!r}"
        )
    return {
        "path": str(path),
        "sha256": sha256(path),
        "elfClass": identity.get("Class"),
        "machine": identity.get("Machine"),
        "requiredSymbols": list(required),
        "missingSymbols": missing,
        "expectedClass": expected_class,
        "expectedMachine": expected_machine,
        "errors": errors,
        "passed": not errors,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, required=True)
    parser.add_argument("--symbol", action="append", dest="symbols",
                        help="required exported symbol; defaults to the public C ABI")
    parser.add_argument("--expect-class", help="expected ELF class, for example ELF64")
    parser.add_argument("--expect-machine", help="expected readelf Machine field")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    required = tuple(args.symbols) if args.symbols else PUBLIC_SYMBOLS
    try:
        report = check(args.library, required, args.expect_class, args.expect_machine)
    except (OSError, subprocess.CalledProcessError) as error:
        report = {"path": str(args.library), "passed": False, "errors": [str(error)]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    for error in report.get("errors", []):
        print(f"error: {error}", file=sys.stderr)
    print(args.output)
    return 0 if report.get("passed") else 1


if __name__ == "__main__":
    raise SystemExit(main())
