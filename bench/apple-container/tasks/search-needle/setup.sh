#!/bin/sh
set -eu
ws=$1
mkdir -p "$ws/src/a" "$ws/src/b/nested" "$ws/docs" "$ws/vendor/pkg"
i=1
while [ "$i" -le 40 ]; do
  printf 'note %s: lorem ipsum dolor sit amet\n' "$i" > "$ws/src/a/note-$i.txt"
  i=$((i + 1))
done
printf 'readme\n' > "$ws/docs/README.md"
printf 'placeholder\n' > "$ws/vendor/pkg/lib.c"
printf 'TOKEN=slab-needle-7f3a\n' > "$ws/src/b/nested/hidden.conf"
printf 'unrelated=yes\n' > "$ws/src/b/other.conf"
