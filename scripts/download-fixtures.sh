#!/usr/bin/env bash
#
# download-fixtures.sh — fetch the Creative Commons audio fixtures listed in
# Tests/Fixtures/fixtures.json into Tests/Fixtures/audio/ (git-ignored).
#
# No transcoding is performed: the library decodes flac/ogg/opus/mp3 natively,
# so each downloaded original is used as-is by the test suite. Requires only
# `curl` and `python3` (both present on macOS with the Xcode command-line tools).
#
# Usage:
#   ./scripts/download-fixtures.sh            # download all, skip existing
#   PARSO_FIXTURES_DIR=/tmp/fx ./scripts/download-fixtures.sh
#
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$REPO_ROOT/Tests/Fixtures/fixtures.json"
DEST="${PARSO_FIXTURES_DIR:-$REPO_ROOT/Tests/Fixtures/audio}"
mkdir -p "$DEST"

if ! command -v curl >/dev/null; then echo "error: curl not found" >&2; exit 1; fi
if ! command -v python3 >/dev/null; then echo "error: python3 not found" >&2; exit 1; fi

echo "Downloading fixtures to: $DEST"
echo "Source: Wikimedia Commons (Special:FilePath). Attributions: see ATTRIBUTION.md"
echo

# Emit "id<TAB>ext<TAB>encoded_url" rows from the manifest.
python3 - "$MANIFEST" <<'PY' | while IFS=$'\t' read -r id ext url; do
import json, sys, urllib.parse
m = json.load(open(sys.argv[1]))
base = m["downloadBase"]
for t in m["tracks"]:
    fn = t["filename"]
    ext = fn.rsplit(".", 1)[-1]
    # Special:FilePath accepts the page filename; encode it safely.
    url = base + urllib.parse.quote(fn, safe="")
    print(f'{t["id"]}\t{ext}\t{url}')
PY
    out="$DEST/$id.$ext"
    if [[ -f "$out" ]]; then
        echo "  ✓ $id.$ext (cached)"
        continue
    fi
    echo "  ↓ $id.$ext"
    # -L follows the redirect to upload.wikimedia.org; UA is required by Commons.
    curl -fL --retry 3 --retry-delay 2 \
         -A "parso-audio-engine-tests/0.x (https://github.com/; contact: dev)" \
         -o "$out" "$url" \
      || { echo "    !! failed: $id ($url)" >&2; rm -f "$out"; }
done

echo
echo "Done. $(ls -1 "$DEST" | grep -v '^\.' | wc -l | tr -d ' ') file(s) present."
echo "These files are Creative Commons works — see each track's Commons page (ATTRIBUTION.md)."
