#!/bin/sh
set -eu
ws=$1
if [ -f "$ws/found.txt" ] && grep -qx 'slab-needle-7f3a' "$ws/found.txt"; then
  printf 'pass\n'
  exit 0
fi
printf 'fail: found.txt missing or wrong token\n' >&2
exit 1
