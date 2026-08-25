#!/bin/sh
# In-container (or staged tree) entry: three memory-system layers.
set -eu
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO_ROOT=${REPO_ROOT:-$(CDPATH= cd "$HERE/../.." && pwd)}
export REPO_ROOT

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

if ! command -v jq >/dev/null 2>&1; then
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache jq python3 curl >/dev/null
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq jq python3 curl >/dev/null
  else
    fail "need jq (and python3, curl)"
  fi
fi
command -v python3 >/dev/null 2>&1 || {
  if command -v apk >/dev/null 2>&1; then apk add --no-cache python3 curl >/dev/null
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 curl >/dev/null
  else fail "need python3"; fi
}
command -v curl >/dev/null 2>&1 || {
  if command -v apk >/dev/null 2>&1; then apk add --no-cache curl >/dev/null
  elif command -v apt-get >/dev/null 2>&1; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl >/dev/null
  else fail "need curl"; fi
}

printf '== L1 pack json ==\n'
n=0
for f in "$REPO_ROOT"/packs/agent/*.json; do
  [ -f "$f" ] || continue
  jq empty "$f" || fail "L1: jq empty failed on $f"
  n=$((n + 1))
  printf 'ok: %s\n' "$f"
done
[ "$n" -gt 0 ] || fail "L1: no packs/agent/*.json"
[ -f "$REPO_ROOT/packs/agent/memory.json" ] || fail "L1: memory.json missing"
printf 'PASS: L1 (%s files)\n' "$n"

printf '== L2 lifecycle ==\n'
/bin/sh "$HERE/test_lifecycle.sh"

printf '== L2b runtime index writes (machine index v2) ==\n'
/bin/sh "$HERE/test_bootstrap.sh"
/bin/sh "$HERE/test_bridge.sh"
/bin/sh "$HERE/test_optional_refresh.sh"

printf '== L3 e2e ==\n'
/bin/sh "$HERE/test_e2e.sh"

printf 'PASS: all memory tests\n'
