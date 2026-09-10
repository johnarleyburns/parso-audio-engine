"""Decode and summarize downloaded real fixtures without filling ground truth."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from parso_audio import AudioCodec, CodecServices, ParsoError


CODECS = {
    "oggVorbis": AudioCodec.OGG_VORBIS,
    "flac": AudioCodec.FLAC,
    "opus": AudioCodec.OPUS,
    "mp3": AudioCodec.MP3,
}


def summarize(root: Path, output: Path, library: str | None, limit: int | None) -> None:
    manifest = json.loads((root / "fixtures.json").read_text(encoding="utf-8"))
    tracks = [track for track in manifest["tracks"] if "analysis" in track.get("roles", [])]
    if limit is not None:
        tracks = tracks[:limit]
    results = []
    missing = []
    errors = []
    with CodecServices(library) as audio:
        for track in tracks:
            path = root / "audio" / track["filename"]
            if not path.exists():
                path = root / "audio" / (track["id"] + Path(track["filename"]).suffix)
            if not path.exists():
                missing.append(track["id"])
                continue
            try:
                decoded = audio.decode(path.read_bytes(), CODECS[track["sourceFormat"]])
                analysis = audio.analyze(decoded.samples, decoded.sample_rate_hz, decoded.channel_count)
                minimum, maximum = audio.waveform(
                    decoded.samples, decoded.sample_rate_hz, decoded.channel_count, 32
                )
            except ParsoError as error:
                errors.append({"fixtureID": track["id"], "error": str(error)})
                continue
            results.append({
                "fixtureID": track["id"],
                "sourceFormat": track["sourceFormat"],
                "frames": decoded.frames,
                "sampleRateHz": decoded.sample_rate_hz,
                "channelCount": decoded.channel_count,
                "analysis": {
                    "durationSeconds": analysis.duration_seconds,
                    "rms": analysis.rms,
                    "peak": analysis.peak,
                    "bpm": analysis.bpm,
                    "bpmConfidence": analysis.bpm_confidence,
                },
                "waveform": {"min": list(minimum), "max": list(maximum)},
            })
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps({"results": results, "missing": missing, "errors": errors}, indent=2) + "\n",
                                 encoding="utf-8")
    print(output)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--fixture-root", type=Path, default=Path("Tests/Fixtures"))
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--limit", type=int, default=4)
    parser.add_argument("--all", action="store_true")
    parser.add_argument("--library", default=None)
    args = parser.parse_args()
    if args.limit <= 0 and not args.all:
        raise ValueError("--limit must be positive")
    summarize(args.fixture_root, args.output, args.library, None if args.all else args.limit)


if __name__ == "__main__":
    main()
