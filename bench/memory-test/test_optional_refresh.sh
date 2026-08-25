#!/bin/sh
# bench/memory-test/test_optional_refresh.sh — optional packs must follow the
# catalog. They install on demand (the model curls memory.json the first time a
# task needs it) and the prompt tells the model never to fetch it again, so
# before this nothing ever refreshed them: a machine pinned whatever memory.json
# it first saw while init.json kept updating underneath it.
set -eu
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO=${REPO_ROOT:-$(CDPATH= cd "$HERE/../.." && pwd)}

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
SEED_FILE=${SEED_FILE:-$REPO/seed.sh}
[ -f "$SEED_FILE" ] || fail "no runtime at $SEED_FILE"
ok() { printf 'ok: %s\n' "$1"; }

FN=$(mktemp "${TMPDIR:-/tmp}/opt-fn.XXXXXX")
{
  awk '/^die\(\) \{/,/^\}/'                   "$SEED_FILE"
  awk '/^need\(\) \{/,/^\}/'                  "$SEED_FILE"
  awk '/^http_get\(\) \{/,/^\}/'              "$SEED_FILE"
  awk '/^pack_root\(\) \{/,/^\}/'             "$SEED_FILE"
  awk '/^pack_join\(\) \{/,/^\}/'             "$SEED_FILE"
  awk '/^agent_state_lock_acquire\(\) \{/,/^\}/' "$SEED_FILE"
  awk '/^agent_state_lock_release\(\) \{/,/^\}/' "$SEED_FILE"
  awk '/^agent_update_optional\(\) \{/,/^\}/' "$SEED_FILE"
} > "$FN"
grep -q 'agent_update_optional()' "$FN" || fail 'could not extract agent_update_optional'
# die() is only reachable from need(); keep the extraction honest about that.
. "$FN"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/opt.XXXXXX")
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
mkdir -p "$WORK/site/agent" "$WORK/home/agent-store/packs"
printf '{"prompt":"NEW memory pack body"}\n'   > "$WORK/site/agent/memory.json"
printf '{"prompt":"NEW mystery pack body"}\n'  > "$WORK/site/agent/mystery.json"
( cd "$WORK/site" && exec python3 -m http.server "$PORT" --bind 127.0.0.1 >"$WORK/http.log" 2>&1 ) &
SRV=$!
trap 'kill "$SRV" 2>/dev/null || true; rm -rf "$WORK" "$FN"' EXIT INT TERM
i=0
while [ "$i" -lt 50 ]; do
  curl -sS -m 2 "http://127.0.0.1:$PORT/agent/memory.json" 2>/dev/null | grep -q NEW && break
  i=$((i + 1)); sleep 0.1
done
curl -sS -m 2 "http://127.0.0.1:$PORT/agent/memory.json" 2>/dev/null | grep -q NEW \
  || fail "pack server not serving on $PORT"

INSTALL=$WORK/home
SEED_PACK_ROOT="http://127.0.0.1:$PORT"
export SEED_PACK_ROOT
CATALOG='{"version":"56","required":{"init":"init.json"},"optional":{"memory":"memory.json","mystery":"mystery.json"}}'

# memory.json already landed here in an older revision; mystery.json never did.
printf '{"prompt":"OLD memory pack body"}\n' > "$INSTALL/agent-store/packs/memory.json"

agent_update_optional "$CATALOG"

grep -q 'NEW memory pack body' "$INSTALL/agent-store/packs/memory.json" \
  || fail 'an installed optional pack was not refreshed from the catalog'
ok 'installed optional pack follows the catalog'

[ -f "$INSTALL/agent-store/packs/mystery.json" ] \
  && fail 'an optional pack that was never installed got pulled in'
ok 'optional packs still install on demand, not at update time'

# A dead pack root must leave the landed copy alone rather than truncate it.
kill "$SRV" 2>/dev/null || true
wait "$SRV" 2>/dev/null || true
SEED_PACK_ROOT="http://127.0.0.1:1"
printf 'note: the connection error below is the point of this case\n'
agent_update_optional "$CATALOG"
grep -q 'NEW memory pack body' "$INSTALL/agent-store/packs/memory.json" \
  || fail 'a failed fetch destroyed the landed pack'
ok 'unreachable pack root leaves the landed pack intact'

# Garbage on the wire must not replace a good pack either.
mkdir -p "$WORK/site2/agent"
printf 'not json at all\n' > "$WORK/site2/agent/memory.json"
PORT2=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
( cd "$WORK/site2" && exec python3 -m http.server "$PORT2" --bind 127.0.0.1 >"$WORK/http2.log" 2>&1 ) &
SRV2=$!
i=0
while [ "$i" -lt 50 ]; do
  curl -sS -m 2 "http://127.0.0.1:$PORT2/agent/memory.json" 2>/dev/null | grep -q 'not json' && break
  i=$((i + 1)); sleep 0.1
done
SEED_PACK_ROOT="http://127.0.0.1:$PORT2"
agent_update_optional "$CATALOG"
kill "$SRV2" 2>/dev/null || true
grep -q 'NEW memory pack body' "$INSTALL/agent-store/packs/memory.json" \
  || fail 'a non-pack response replaced a good pack'
ok 'a response that is not a pack is rejected'

leftover=$(find "$INSTALL/agent-store/packs" -name '*.XXXXXX*' -o -name 'seed-aopt*' 2>/dev/null || true)
[ -z "$leftover" ] || fail "leftover temp file: $leftover"
ok 'no temp files left behind'

# The function is only worth anything if the update path still calls it.
grep -q 'agent_update_optional "$index"' "$SEED_FILE" \
  || fail 'agent_update no longer calls agent_update_optional'
ok 'agent_update still calls it'

printf 'PASS: optional refresh (%s)\n' "${SEED_FILE##*/}"
