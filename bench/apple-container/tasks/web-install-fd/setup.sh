#!/bin/sh
set -eu
ws=$1
mkdir -p "$ws/docs/a" "$ws/src"
printf '# one\n' > "$ws/docs/readme.md"
printf '# two\n' > "$ws/docs/a/notes.md"
printf 'not markdown\n' > "$ws/docs/a/notes.txt"
printf 'print(1)\n' > "$ws/src/app.py"
printf '# ignore me\n' > "$ws/src/skip.md.bak"
