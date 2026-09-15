#!/usr/bin/env bash
# Build and consume the Python wheel/sdist outside the checkout.
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 /absolute/path/to/libparso.so" >&2
    exit 2
fi

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
library_path="$(cd -- "$(dirname -- "$1")" && pwd)/$(basename -- "$1")"
if [[ ! -f "$library_path" ]]; then
    echo "native library does not exist: $library_path" >&2
    exit 2
fi

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT

builder_venv="$temporary_dir/builder-venv"
consumer_venv="$temporary_dir/consumer-venv"
build_source="$temporary_dir/source"
python3 -m venv "$builder_venv"
"$builder_venv/bin/python" -m pip install --disable-pip-version-check \
    "setuptools>=68" "wheel>=0.42" "build>=1.2"
mkdir -p "$build_source"
cp -a "$repo_root/bindings/python/." "$build_source/"
rm -rf "$build_source/build" "$build_source"/*.egg-info
"$builder_venv/bin/python" -m build --wheel --sdist --no-isolation \
    --outdir "$temporary_dir/dist" "$build_source"
test "$(find "$temporary_dir/dist" -maxdepth 1 -name '*.whl' | wc -l)" -eq 1
test "$(find "$temporary_dir/dist" -maxdepth 1 -name '*.tar.gz' | wc -l)" -eq 1

python3 -m venv "$consumer_venv"
"$consumer_venv/bin/python" -m pip install --disable-pip-version-check \
    --no-index --find-links "$temporary_dir/dist" parso-audio

pushd "$temporary_dir" >/dev/null
export PARSO_AUDIO_LIBRARY="$library_path"
"$consumer_venv/bin/python" -c 'import os; from parso_audio import CodecServices, Engine; CodecServices(os.environ["PARSO_AUDIO_LIBRARY"]).close(); Engine(library_path=os.environ["PARSO_AUDIO_LIBRARY"]).close(); print("installed Python package smoke: PASS")'
"$consumer_venv/bin/python" -m unittest discover \
    -s "$repo_root/bindings/python/tests" -v
"$consumer_venv/bin/python" "$repo_root/bindings/python/examples/vorbis_roundtrip.py"
"$consumer_venv/bin/python" "$repo_root/bindings/python/examples/render_acceptance.py" \
    --output-dir "$temporary_dir/acceptance" --seconds 30
popd >/dev/null

echo "Python wheel/sdist outside-checkout gate: PASS"
