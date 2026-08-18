#!/bin/sh
set -eu
ws=$1
if [ ! -f "$ws/md-files.txt" ]; then
  printf 'fail: md-files.txt missing\n' >&2
  exit 1
fi
# Accept fd, fdfind, or any finder that listed the two markdown files.
if grep -q 'docs/readme.md' "$ws/md-files.txt" && grep -q 'docs/a/notes.md' "$ws/md-files.txt"; then
  if grep -q 'notes.txt' "$ws/md-files.txt" || grep -q 'skip.md.bak' "$ws/md-files.txt"; then
    printf 'fail: extra non-md paths\n' >&2
    exit 1
  fi
  printf 'pass\n'
  exit 0
fi
printf 'fail: markdown paths missing\n' >&2
exit 1
