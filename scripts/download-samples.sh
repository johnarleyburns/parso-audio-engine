#!/usr/bin/env bash
#
# download-samples.sh — fetch the CC0 / CC-BY sample packs and impulse-response
# libraries listed in SampleLibrary/manifest.json into SampleLibrary/downloads/
# (git-ignored). Same pattern as scripts/download-fixtures.sh: nothing is
# committed; an app curates its own subset and records attribution per
# SAMPLES-NOTICE.md.
#
# Usage:
#   ./scripts/download-samples.sh              # fetch all auto-fetchable packs
#   ./scripts/download-samples.sh vcsl         # fetch one pack by id
#   PARSO_SAMPLES_DIR=/tmp/s ./scripts/download-samples.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/SampleLibrary/manifest.json"
DEST="${PARSO_SAMPLES_DIR:-$REPO_ROOT/SampleLibrary/downloads}"
ONLY="${1:-}"
mkdir -p "$DEST"

command -v curl >/dev/null || { echo "error: curl not found" >&2; exit 1; }
command -v python3 >/dev/null || { echo "error: python3 not found" >&2; exit 1; }

echo "Downloading sample packs to: $DEST"
echo "Attributions / license policy: see SAMPLES-NOTICE.md"
echo

python3 - "$MANIFEST" "$ONLY" <<'PY' | while IFS=$'\t' read -r id kind license ftype furl fdepth; do
import json, sys
m = json.load(open(sys.argv[1]))
only = sys.argv[2]
for p in m["packs"]:
    if only and p["id"] != only:
        continue
    f = p.get("fetch", {})
    print("\t".join([p["id"], p["kind"], p["license"], f.get("type", "manual"),
                     f.get("url", ""), str(f.get("depth", ""))]))
PY
    out="$DEST/$id"
    case "$ftype" in
      git)
        if [[ -d "$out/.git" ]]; then echo "  ✓ $id (cached clone)"; continue; fi
        echo "  ↓ $id  [git, $license]"
        depth_arg=(); [[ -n "$fdepth" ]] && depth_arg=(--depth "$fdepth")
        git clone "${depth_arg[@]}" "$furl" "$out" \
          || echo "    !! clone failed: $id" >&2
        ;;
      archive)
        if [[ -d "$out" && -n "$(ls -A "$out" 2>/dev/null || true)" ]]; then
          echo "  ✓ $id (cached archive)"; continue
        fi
        echo "  ↓ $id  [archive, $license]"
        tmp="$(mktemp -t parso-sample-XXXXXX.zip)"
        if curl -fL --retry 3 --retry-delay 2 -A "parso-audio-engine/0.x" -o "$tmp" "$furl"; then
          mkdir -p "$out" && (cd "$out" && unzip -qo "$tmp") || echo "    !! unzip failed: $id" >&2
        else
          echo "    !! download failed: $id ($furl)" >&2
        fi
        rm -f "$tmp"
        ;;
      *)
        echo "  · $id  [$license] — manual: see SampleLibrary/manifest.json + SAMPLES-NOTICE.md"
        ;;
    esac
done

echo
echo "Done. Curate the subset your app ships and list every CC-BY item in SAMPLES-NOTICE.md."
