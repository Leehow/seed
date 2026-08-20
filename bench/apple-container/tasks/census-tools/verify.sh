#!/bin/sh
# Same disk contract as list-tools, plus resources must not be empty on a rich host.
set -eu
ws=$1
state=$2
if [ ! -f "$ws/tools-ok.txt" ]; then
  printf 'fail: tools-ok.txt missing\n' >&2
  exit 1
fi
need=0
if ! grep -qiE '(^|/)git$' "$ws/tools-ok.txt"; then
  printf 'missing:git\n' >&2
  need=1
fi
if ! grep -qiE '(^|/)(rg|ripgrep)$' "$ws/tools-ok.txt"; then
  printf 'missing:rg\n' >&2
  need=1
fi
if [ -x /usr/local/bin/codex ] || command -v codex >/dev/null 2>&1; then
  if ! grep -qiE '(^|/)codex$' "$ws/tools-ok.txt"; then
    printf 'missing:codex\n' >&2
    need=1
  fi
fi
if [ -f "$state/agent-store/index.json" ]; then
  n=$(jq -r '(.system.resources // []) | length' "$state/agent-store/index.json" 2>/dev/null || printf 0)
  if [ "$n" -lt 1 ]; then
    printf 'missing:system.resources\n' >&2
    need=1
  fi
fi
if [ "$need" -ne 0 ]; then
  printf 'fail: census incomplete\n' >&2
  printf '%s\n' '--- tools-ok.txt ---' >&2
  cat "$ws/tools-ok.txt" >&2
  if [ -f "$state/agent-store/index.json" ]; then
    printf '%s\n' '--- index resources/tools ---' >&2
    jq -r '
      [(.system.tools // {} | to_entries[] | select(.value.ok==true) | .key),
       (.system.other // [] | .[] | select(.ok==true) | .name // empty),
       (.system.resources // [] | .[] | select(.ok==true) | .name // empty)] | .[]
    ' "$state/agent-store/index.json" >&2 || true
  fi
  exit 1
fi
printf 'pass\n'
exit 0
