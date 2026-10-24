#!/usr/bin/env bash
# Build a signed IPA from source on Linux/WSL with xtool.
#
# Usage:
#   bash Scripts/build-ipa.sh
#
# Environment:
#   SHIYING_BUILD_DIR  checkout used by xtool (default: "$HOME/shiying")
#
# The script mirrors the app sources into SHIYING_BUILD_DIR, runs
# `xtool dev build`, then copies the resulting IPA to Shiying/xtool/.
set -uo pipefail

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$SRC/Shiying"
DST="${SHIYING_BUILD_DIR:-$HOME/shiying}"

export PATH="/usr/local/swift/usr/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

mkdir -p "$DST"
# Prune the mirror directory. .build is kept for incremental compiles.
cd "$DST"
find . -mindepth 1 -maxdepth 1 ! -name '.build' ! -name 'xtool' -exec rm -rf {} + 2>/dev/null || true

cd "$APP"
tar cf - \
  --exclude='./.build' \
  --exclude='./.swiftpm' \
  --exclude='./.ipa-check' \
  --exclude='./screens' \
  --exclude='./xtool' \
  --exclude='./testdata' \
  --exclude='*.log' \
  . | (cd "$DST" && tar xf -)

cd "$DST"
unset XTL_HTTP_PROXY

if ! xtool dev build -c release --sign --ipa; then
  echo "Build failed" >&2
  exit 1
fi

IPA="$(ls -t "$DST"/xtool/*.ipa 2>/dev/null | head -1 || true)"
if [ -n "$IPA" ]; then
  mkdir -p "$APP/xtool"
  cp "$IPA" "$APP/xtool/"
  echo "COPIED $IPA"
fi
