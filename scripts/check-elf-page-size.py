#!/usr/bin/env python3
"""Verify Android ELF LOAD segments meet the 16 KiB page-size contract."""

from __future__ import annotations

import argparse
import subprocess
import sys
from pathlib import Path


def load_alignments(path: Path) -> list[int]:
    output = subprocess.check_output(
        ["readelf", "-lW", str(path)], text=True, stderr=subprocess.STDOUT
    )
    alignments: list[int] = []
    for line in output.splitlines():
        fields = line.split()
        if fields and fields[0] == "LOAD":
            if len(fields) < 8:
                raise ValueError(f"malformed LOAD header in {path}: {line}")
            alignments.append(int(fields[-1], 0))
    if not alignments:
        raise ValueError(f"no LOAD segments found in {path}")
    return alignments


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", type=Path, action="append", required=True)
    parser.add_argument(
        "--minimum-alignment",
        type=lambda value: int(value, 0),
        default=0x4000,
        help="minimum LOAD alignment in bytes (default: 0x4000)",
    )
    args = parser.parse_args()
    errors: list[str] = []
    for path in args.library:
        try:
            alignments = load_alignments(path)
        except (OSError, ValueError, subprocess.CalledProcessError) as error:
            errors.append(str(error))
            continue
        print(f"{path}: " + ", ".join(f"0x{value:x}" for value in alignments))
        if min(alignments) < args.minimum_alignment:
            errors.append(
                f"{path}: minimum LOAD alignment is 0x{min(alignments):x}; "
                f"expected at least 0x{args.minimum_alignment:x}"
            )
    for error in errors:
        print(f"error: {error}", file=sys.stderr)
    return 1 if errors else 0


if __name__ == "__main__":
    raise SystemExit(main())
