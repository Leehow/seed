#!/bin/sh
# Download official jq 1.7.1 assets into this directory (pack mirror).
set -eu
DIR=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
VER=1.7.1
BASE=https://github.com/jqlang/jq/releases/download/jq-$VER
need() { command -v "$1" >/dev/null 2>&1 || { printf 'error: need %s\n' "$1" >&2; exit 69; }; }
need curl
for f in \
  jq-linux-amd64 \
  jq-linux-arm64 \
  jq-macos-amd64 \
  jq-macos-arm64 \
  jq-windows-amd64.exe
do
  printf 'fetch %s\n' "$f" >&2
  curl -q -fL --connect-timeout 15 --max-time 120 -o "$DIR/$f.tmp" "$BASE/$f"
  mv "$DIR/$f.tmp" "$DIR/$f"
  chmod 755 "$DIR/$f"
done
printf 'ok   %s\n' "$DIR" >&2
