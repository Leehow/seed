#!/bin/sh
# Grep tool traces for how the agent solved the task. No secrets.
set -eu
runs=$1
[ -d "$runs" ] || { printf 'tools=\nweb=\n'; exit 0; }
tmp=$(mktemp)
: > "$tmp"
find "$runs" -name 'tool-*.txt' 2>/dev/null | while IFS= read -r f; do
  cat "$f" >> "$tmp"
done
find "$runs" -name 'messages.json' 2>/dev/null | while IFS= read -r f; do
  grep -E '"(command|name)"' "$f" >> "$tmp" || true
done

hits=
for w in rg ripgrep grep git fd fdfind apt-get apt curl wget cargo npm pip openssl python python3 jq find cat; do
  if grep -q -E "(^|[^A-Za-z0-9_])$w([^A-Za-z0-9_]|$)" "$tmp"; then
    hits="$hits $w"
  fi
done
if grep -q -E 'https?://' "$tmp"; then
  web=yes
else
  web=no
fi
hits=$(printf '%s' "$hits" | awk '{$1=$1; print}')
printf 'tools=%s\n' "$hits"
printf 'web=%s\n' "$web"
rm -f "$tmp"
