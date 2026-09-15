#!/usr/bin/env bash
#
# generate-linux-tts-review.sh — OPTIONAL Linux-only listening aid.
#
# This script is deliberately not called by the build, tests, packaging, or CI.
# It installs the open-weight Kyutai Pocket TTS reviewer into a user-local
# cache, then prepends a spoken cue to copies of generated review WAVs. The
# source WAVs are never modified. Model weights and generated audio stay out of
# the repository.
#
# Usage:
#   ./scripts/generate-linux-tts-review.sh \
#     --input-dir /tmp/parso-linux-music-review/python \
#     --output-dir /tmp/parso-linux-music-review/pocket-tts-preview
#
# Environment overrides:
#   PARSO_TTS_STATE_DIR   persistent venv/model cache
#   PARSO_TTS_PYTHON      Python executable or uv Python spec (default: python3)
#   PARSO_TTS_VOICE       Pocket TTS voice path/URL
#   PARSO_TTS_VERSION     pocket-tts package version (default: 3.1.0)
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
USER_HOME="${HOME:?HOME must be set}"
STATE_DIR="${PARSO_TTS_STATE_DIR:-${XDG_CACHE_HOME:-$USER_HOME/.cache}/parso-audio-engine/pocket-tts}"
PYTHON_SPEC="${PARSO_TTS_PYTHON:-python3}"
TTS_VERSION="${PARSO_TTS_VERSION:-3.1.0}"
VOICE="${PARSO_TTS_VOICE:-marius}"
INPUT_DIR=""
OUTPUT_DIR=""
FORCE=0

die() {
    echo "error: $*" >&2
    exit 1
}

log() {
    echo "==> $*"
}

usage() {
    sed -n '1,34p' "$0"
    cat <<'EOF'

Options:
  --input-dir DIR   directory containing review WAV files (required)
  --output-dir DIR  new directory for guided copies and metadata (required)
  --voice NAME|PATH|URL  Pocket TTS catalog voice or conditioning file (default: CC0 marius)
  --force            overwrite this script's generated files in output-dir
  --help             show this help

The normal build never downloads or runs TTS. The first invocation downloads
the pinned package/model into PARSO_TTS_STATE_DIR, which can require several
hundred megabytes and a Hugging Face account/terms confirmation if requested.
EOF
}

while (($# > 0)); do
    case "$1" in
        --input-dir)
            (($# >= 2)) || die "--input-dir requires a path"
            INPUT_DIR="$2"
            shift
            ;;
        --output-dir)
            (($# >= 2)) || die "--output-dir requires a path"
            OUTPUT_DIR="$2"
            shift
            ;;
        --voice)
            (($# >= 2)) || die "--voice requires a path or URL"
            VOICE="$2"
            shift
            ;;
        --force)
            FORCE=1
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            die "unknown argument '$1' (use --help)"
            ;;
    esac
    shift
done

[ "$(uname -s)" = Linux ] || die "this optional reviewer currently supports Linux only"
command -v uv >/dev/null 2>&1 || die "uv is required; install it from https://docs.astral.sh/uv/"
[ -d "$INPUT_DIR" ] || die "input directory does not exist: $INPUT_DIR"
[ -n "$OUTPUT_DIR" ] || die "--output-dir is required"

mapfile -t INPUT_WAVS < <(find "$INPUT_DIR" -maxdepth 1 -type f -name '*.wav' ! -name '*-guided.wav' -print | sort)
((${#INPUT_WAVS[@]} > 0)) || die "no review WAV files found in $INPUT_DIR"

if [ -e "$OUTPUT_DIR" ] && [ "$FORCE" -eq 0 ]; then
    if find "$OUTPUT_DIR" -mindepth 1 -print -quit | grep -q .; then
        die "output directory is not empty; choose a new directory or pass --force: $OUTPUT_DIR"
    fi
fi
mkdir -p "$OUTPUT_DIR"
mkdir -p "$STATE_DIR"

VENV_DIR="$STATE_DIR/venv"
INSTALL_MARKER="$VENV_DIR/.parso-pocket-tts-$TTS_VERSION-installed"
if [ ! -x "$VENV_DIR/bin/python" ] || [ ! -f "$INSTALL_MARKER" ]; then
    log "Creating the optional Pocket TTS environment at $VENV_DIR"
    uv venv --python "$PYTHON_SPEC" "$VENV_DIR"
    log "Installing CPU-only PyTorch and pocket-tts==$TTS_VERSION"
    uv pip install --python "$VENV_DIR/bin/python" \
        --index-url https://download.pytorch.org/whl/cpu \
        'torch>=2.5.0'
    uv pip install --python "$VENV_DIR/bin/python" \
        --index-url https://pypi.org/simple \
        "pocket-tts[audio]==$TTS_VERSION"
    touch "$INSTALL_MARKER"
fi

log "Generating ${#INPUT_WAVS[@]} guided listening copies with Pocket TTS voice $VOICE"
export HF_HOME="${HF_HOME:-$STATE_DIR/huggingface}"
export PARSO_TTS_REPO_ROOT="$REPO_ROOT"
export PARSO_TTS_VERSION="$TTS_VERSION"
export PARSO_TTS_VOICE="$VOICE"
export PARSO_TTS_FORCE="$FORCE"

"$VENV_DIR/bin/python" - "$INPUT_DIR" "$OUTPUT_DIR" "${INPUT_WAVS[@]}" <<'PY'
import json
import os
import pathlib
import subprocess
import sys
import wave

import numpy as np
import torch
from pocket_tts import TTSModel


INSTRUCTIONS = {
    "crossfader-sweep": (
        "Crossfader sweep. First listen for the sound moving smoothly from deck A to deck B. "
        "There should be no gap, click, or sudden jump in volume. Pay attention to the center."
    ),
    "smart-fader": (
        "Smart Fader. Listen for the incoming track to match tempo. The low bass should duck, "
        "the volume should transition smoothly, and an echo or reverb tail should appear at the handoff."
    ),
    "smart-cfx": (
        "Smart C F X. Listen for one control changing the effect from dry toward a filtered, "
        "spacious, or echoed sound, then returning cleanly."
    ),
    "beatfx-echo-out": (
        "Beat effects echo out. Listen for timed repeats on the outgoing track. When the effect "
        "releases, the repeats should fade into a clean echo tail before the next track starts."
    ),
    "scratch": (
        "Scratch overview. Listen for record motion, fader cuts, and the deck returning cleanly to normal playback."
    ),
    "scratch-foundations": (
        "Scratch foundations. Listen for baby scratch, scribble, slow drag, forward cut, and backward cut. "
        "Check the beat-driven disco record for clear record-hand motion and clean cuts."
    ),
    "scratch-cuts": (
        "Fader scratches. Listen for chirp, one-click flare, two-click flare, orbit flare, transform, and crab. "
        "Count the sharp rhythmic cuts and check for clicks that are intentional rather than glitches."
    ),
    "scratch-combos": (
        "Combination scratches. Listen for tear pauses, twiddle two-clicks, and the rolling boomerang pattern. "
        "Check that each stutter remains rhythmic and returns cleanly."
    ),
    "turntable-manipulation": (
        "Turntable manipulation. Listen for platter pitch bends, the motor-off slowdown, hydroplane friction, "
        "and tone play speed steps. Check the pitch movement and the return to stable playback."
    ),
    "beat-juggle": (
        "Beat juggling. This file uses a disco record and a separate hip-hop record on two decks. "
        "Listen for alternating hot-cue cuts, timing alignment, and clean handoffs between decks."
    ),
    "phasing-flanging": (
        "Phasing and flanging. Two copies of the disco record start together, then drift slightly apart. "
        "Listen for the moving hollow whoosh and the return to centered playback."
    ),
    "loop-and-cue": (
        "Loop and cue. Listen for tight loop boundaries, cue and hot cue jumps, and beat-aligned "
        "returns without clicks."
    ),
    "warm2-isolator": (
        "Warm two isolator. Listen to the low, middle, and high frequency bands being isolated and "
        "restored. Check the filter sweeps for smoothness, without clicks or harsh ringing."
    ),
}


def resample_mono(samples: np.ndarray, source_rate: int, target_rate: int) -> np.ndarray:
    if source_rate == target_rate:
        return samples
    target_length = max(1, round(len(samples) * target_rate / source_rate))
    positions = np.linspace(0, len(samples) - 1, target_length, dtype=np.float64)
    return np.interp(positions, np.arange(len(samples), dtype=np.float64), samples).astype(np.float32)


def make_intro(model: TTSModel, state: object, text: str, target_rate: int, channels: int) -> tuple[bytes, float]:
    audio = model.generate_audio(state, text)
    samples = np.asarray(audio.detach().cpu(), dtype=np.float32)
    if samples.ndim == 2:
        samples = samples.mean(axis=0) if samples.shape[0] <= 2 else samples.mean(axis=1)
    samples = np.asarray(samples, dtype=np.float32).reshape(-1)
    samples = np.nan_to_num(samples, nan=0.0, posinf=0.0, neginf=0.0)
    peak = float(np.max(np.abs(samples), initial=0.0))
    if peak > 0.0:
        samples = samples / peak * 0.78
    samples = resample_mono(samples, int(model.sample_rate), target_rate)
    pause_frames = round(0.35 * target_rate)
    intro = np.concatenate((samples, np.zeros(pause_frames, dtype=np.float32)))
    pcm = np.clip(intro * 32767.0, -32768.0, 32767.0).astype("<i2")
    if channels > 1:
        pcm = np.repeat(pcm[:, None], channels, axis=1)
    return pcm.tobytes(), len(intro) / target_rate


def scenario_for(path: pathlib.Path) -> str:
    stem = path.stem
    for prefix in ("python-", "native-"):
        if stem.startswith(prefix):
            stem = stem[len(prefix):]
    return stem


def main() -> None:
    input_dir = pathlib.Path(sys.argv[1]).resolve()
    output_dir = pathlib.Path(sys.argv[2]).resolve()
    sources = [pathlib.Path(value).resolve() for value in sys.argv[3:]]
    force = os.environ.get("PARSO_TTS_FORCE") == "1"
    voice = os.environ["PARSO_TTS_VOICE"]

    torch.set_num_threads(min(2, torch.get_num_threads()))
    torch.set_num_interop_threads(1)
    model = TTSModel.load_model()
    voice_state = model.get_state_for_audio_prompt(voice)
    artifacts = []

    for source in sources:
        scenario = scenario_for(source)
        instruction = INSTRUCTIONS.get(
            scenario,
            f"{scenario.replace('-', ' ').capitalize()}. Listen for smooth, click-free operation and any changes described by the review sidecar.",
        )
        output = output_dir / f"{source.stem}-pocket-tts-guided.wav"
        if output.exists() and not force:
            raise SystemExit(f"refusing to overwrite {output}; pass --force")

        with wave.open(str(source), "rb") as reader:
            params = reader.getparams()
            if params.sampwidth != 2 or params.comptype != "NONE":
                raise SystemExit(f"{source}: only 16-bit PCM WAV input is supported")
            raw = reader.readframes(params.nframes)
            intro, intro_seconds = make_intro(model, voice_state, instruction, params.framerate, params.nchannels)
            with wave.open(str(output), "wb") as writer:
                writer.setnchannels(params.nchannels)
                writer.setsampwidth(params.sampwidth)
                writer.setframerate(params.framerate)
                writer.setcomptype("NONE", "not compressed")
                writer.writeframes(intro)
                writer.writeframes(raw)
            total_seconds = intro_seconds + params.nframes / params.framerate

        artifacts.append({
            "scenario": scenario,
            "source": str(source),
            "guidedWav": str(output),
            "introSeconds": round(intro_seconds, 3),
            "audioDurationSeconds": round(total_seconds, 3),
            "instruction": instruction,
            "reviewStatus": "pending",
        })
        print(f"  {output.name} ({intro_seconds:.1f}s spoken cue)")

    metadata = {
        "schemaVersion": 1,
        "sourceCommit": subprocess.run(
            ["git", "-C", os.environ["PARSO_TTS_REPO_ROOT"], "rev-parse", "HEAD"],
            check=False,
            capture_output=True,
            text=True,
        ).stdout.strip() or "unknown",
        "sourceBundle": str(input_dir),
        "note": "Derived listening copies with Pocket TTS instructions prepended; source review artifacts are unchanged.",
        "model": {
            "name": "Kyutai Pocket TTS",
            "package": "pocket-tts",
            "packageVersion": os.environ["PARSO_TTS_VERSION"],
            "codeLicense": "MIT",
            "weightsLicense": "CC-BY-4.0",
            "weightsSource": "https://huggingface.co/kyutai/pocket-tts",
        },
        "voice": {
            "source": voice,
            "license": "CC0 for the default marius Voice-Zero voice; verify the license before using a custom voice.",
            "sourcePage": "https://huggingface.co/kyutai/tts-voices",
        },
        "introSecondsIncludesPause": True,
        "reviewStatus": "pending",
        "artifacts": artifacts,
    }
    with (output_dir / "tts-preview.json").open("w", encoding="utf-8") as handle:
        json.dump(metadata, handle, indent=2)
        handle.write("\n")
    print(f"Wrote metadata: {output_dir / 'tts-preview.json'}")


if __name__ == "__main__":
    main()
PY

log "Optional TTS review generation complete. Review the *_pocket-tts-guided.wav files; statuses remain pending."
