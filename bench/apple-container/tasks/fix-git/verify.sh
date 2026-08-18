#!/bin/sh
set -eu
ws=$1
cd "$ws"
branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$branch" != master ]; then
  printf 'fail: not on master (on %s)\n' "$branch" >&2
  exit 1
fi
if grep -q 'secret-change-42' index.html; then
  printf 'pass\n'
  exit 0
fi
printf 'fail: master index.html missing the lost change\n' >&2
exit 1
