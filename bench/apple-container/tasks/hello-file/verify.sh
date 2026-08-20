#!/bin/sh
set -eu
ws=$1
if [ -f "$ws/bench-ok.txt" ] && grep -qx 'seed-ok' "$ws/bench-ok.txt"; then
  printf 'pass\n'
  exit 0
fi
printf 'fail: bench-ok.txt missing or wrong\n' >&2
exit 1
