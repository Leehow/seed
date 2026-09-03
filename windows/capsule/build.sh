#!/bin/sh
# Seed POSIX Capsule — pin/validate/fetch/assemble.
# macOS/Linux CI: ./build.sh validate   or   ./build.sh dry-run
# Windows/MSYS2:  ./build.sh assemble
set -eu

DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
PY=${PYTHON:-python3}

usage() {
  printf 'usage: %s validate|dry-run|fetch|assemble|hash-lock|test [--cache DIR] [--out DIR]\n' "$0" >&2
  exit 64
}

[ "$#" -ge 1 ] || usage
cmd=$1
shift

case $cmd in
  validate|dry-run|fetch|assemble|hash-lock|test) ;;
  -h|--help|help) usage ;;
  *) usage ;;
esac

if ! command -v "$PY" >/dev/null 2>&1; then
  printf 'error: need python3 for capsule metadata\n' >&2
  exit 69
fi

if [ "$cmd" = "test" ]; then
  exec "$PY" -m unittest discover -s "$DIR/scripts" -p 'test_*.py' -v
fi

exec "$PY" "$DIR/scripts/capsule.py" "$cmd" "$@"
