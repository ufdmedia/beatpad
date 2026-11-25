#!/bin/sh
set -eu
cd "$(dirname "$0")"
if ! command -v swift >/dev/null 2>&1; then
    echo "beatpad: Swift is missing; install Apple's Command Line Tools with xcode-select --install." >&2
    exit 1
fi
if ! swift build -c release "$@"; then
    echo "beatpad: release build failed; check the compiler messages above." >&2
    exit 1
fi
cp .build/release/beatpad ./beatpad
strip -S ./beatpad
if ! codesign --force --sign - --identifier com.ufdmedia.beatpad ./beatpad; then
    echo "beatpad: ad-hoc signing failed." >&2
    exit 1
fi
