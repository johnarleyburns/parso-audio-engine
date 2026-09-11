#!/usr/bin/env bash
set -euo pipefail

state_dir="${PARSO_FAKE_PW_CAT_STATE_DIR:?PARSO_FAKE_PW_CAT_STATE_DIR is required}"
mkdir -p "$state_dir"

if [[ " $* " == *" --playback "* ]]; then
    state="$state_dir/playback.$PPID.started"
    if [[ ! -e "$state" ]]; then
        : > "$state"
        head -c 2048 >/dev/null || true
        exit 0
    fi
    cat >/dev/null
    exit 0
fi

if [[ " $* " == *" --record "* ]]; then
    state="$state_dir/capture.$PPID.started"
    if [[ ! -e "$state" ]]; then
        : > "$state"
        dd if=/dev/zero bs=2048 count=1 2>/dev/null
        exit 0
    fi
    while true; do
        dd if=/dev/zero bs=2048 count=1 2>/dev/null
    done
fi

exit 64
