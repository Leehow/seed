#!/bin/sh
# Core /packs and /pack routing. Mock curl; hit real CLI and loop entries.
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
SEED=$ROOT/seed.sh
fail=0
t=$(mktemp -d "${TMPDIR:-/tmp}/seed-packs.XXXXXX")
trap 'rm -rf "$t"' EXIT HUP INT TERM
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }

unset SEED_MODE SLAB_SKIP_INIT SEED_SKIP_UPDATE SEED_SELF SEED_RUNTIME_URL \
  SEED_TEST_CURL_FAIL SEED_TEST_HTTP_CODE || true

/bin/sh -n "$SEED" && ok 'sh -n' || bad 'sh -n'

mkdir -p "$t/bin" "$t/http" "$t/runs"
SEED_TEST_CURL_LOG=$t/curl.log
SEED_TEST_HTTP_DIR=$t/http
export SEED_TEST_CURL_LOG SEED_TEST_HTTP_DIR

cat > "$t/bin/curl" <<'CURL'
#!/bin/sh
printf '%s\n' "$*" >> "${SEED_TEST_CURL_LOG:-/tmp/seed-curl.log}"
out=
url=
prev=
for a in "$@"; do
  if [ "$prev" = -o ]; then out=$a; fi
  prev=$a
  case $a in http://*|https://*) url=$a ;; esac
done
if [ -n "${SEED_TEST_CURL_FAIL:-}" ]; then
  [ -n "$out" ] && : > "$out"
  exit "$SEED_TEST_CURL_FAIL"
fi
body=
case $url in
  https://seed-agents.com/dl/packs.json)
    [ -f "${SEED_TEST_HTTP_DIR}/packs.json" ] && body=${SEED_TEST_HTTP_DIR}/packs.json
    ;;
  https://seed-agents.com/dl/packs/*.json)
    name=${url##*/}
    [ -f "${SEED_TEST_HTTP_DIR}/$name" ] && body=${SEED_TEST_HTTP_DIR}/$name
    ;;
esac
code=${SEED_TEST_HTTP_CODE:-}
if [ -n "$body" ] && [ -n "$out" ]; then
  cat "$body" > "$out"
  [ -n "$code" ] || code=200
elif [ -n "$out" ]; then
  : > "$out"
  [ -n "$code" ] || code=404
else
  [ -n "$code" ] || code=200
fi
printf '%s' "$code"
exit 0
CURL
chmod 755 "$t/bin/curl"

printf '%s\n' '{"packs":[{"slug":"webcoding","description":"Web IDE pack"},{"slug":"jq","name":"jq"}]}' \
  > "$t/http/packs.json"
printf '%s\n' '{"slug":"webcoding","prompt":"use webcoding"}' > "$t/http/webcoding.json"
printf '%s\n' '{"slug":"jq","prompt":"use jq"}' > "$t/http/jq.json"
printf '%s\n' '{"slug":"badslug","files":{"../x":1}}' > "$t/http/badslug.json"
printf '%s\n' '{"slug":"hooky","files":{"note.sh":{"prompt":"not a hook"}}}' > "$t/http/hooky.json"

MOCKPATH=$t/bin:$PATH

run_cli() {
  home=$1
  shift
  mkdir -p "$home"
  : > "$t/curl.log"
  set +e
  env -u SEED_SELF SEED_HOME="$home" SEED_MODE="${SEED_MODE:-agent}" \
    SEED_RUNTIME_URL="$SEED" PATH="$MOCKPATH" \
    SEED_TEST_CURL_LOG="$t/curl.log" SEED_TEST_HTTP_DIR="$t/http" \
    ${SEED_TEST_CURL_FAIL:+SEED_TEST_CURL_FAIL="$SEED_TEST_CURL_FAIL"} \
    ${SEED_TEST_HTTP_CODE:+SEED_TEST_HTTP_CODE="$SEED_TEST_HTTP_CODE"} \
    /bin/sh "$SEED" "$@" > "$home/out" 2> "$home/err"
  echo $? > "$home/st"
  set -e
}

run_loop_line() {
  home=$1
  line=$2
  mkdir -p "$home"
  : > "$t/curl.log"
  set +e
  printf '%s\n' "$line" | env -u SEED_SELF SEED_HOME="$home" \
    SEED_MODE="${SEED_MODE:-agent}" SEED_RUNTIME_URL="$SEED" \
    SLAB_SKIP_INIT=1 AGENT_RUNS_DIR="$t/runs" PATH="$MOCKPATH" \
    SEED_TEST_CURL_LOG="$t/curl.log" SEED_TEST_HTTP_DIR="$t/http" \
    ${SEED_TEST_CURL_FAIL:+SEED_TEST_CURL_FAIL="$SEED_TEST_CURL_FAIL"} \
    ${SEED_TEST_HTTP_CODE:+SEED_TEST_HTTP_CODE="$SEED_TEST_HTTP_CODE"} \
    /bin/sh "$SEED" deepseek sk-test > "$home/out" 2> "$home/err"
  echo $? > "$home/st"
  set -e
}

# Agent CLI /packs lists slug + description from the official catalog.
run_cli "$t/list" /packs
if [ "$(cat "$t/list/st")" = 0 ] \
  && grep -qx 'webcoding  Web IDE pack' "$t/list/out" \
  && grep -qx 'jq  jq' "$t/list/out" \
  && grep -q 'https://seed-agents.com/dl/packs.json' "$t/curl.log" \
  && ! grep -q '^loaded:' "$t/list/out"; then
  ok 'Agent /packs lists catalog'
else
  bad 'Agent /packs lists catalog'
fi

# Loop entry for /packs (same routing as the interactive window).
run_loop_line "$t/looplist" /packs
if [ "$(cat "$t/looplist/st")" = 0 ] \
  && grep -qx 'webcoding  Web IDE pack' "$t/looplist/out" \
  && grep -q 'https://seed-agents.com/dl/packs.json' "$t/curl.log"; then
  ok 'loop /packs'
else
  bad 'loop /packs'
fi

# /packs install success via CLI; only then loaded + receipt.
run_cli "$t/inst" /packs install webcoding
if [ "$(cat "$t/inst/st")" = 0 ] \
  && grep -qx 'loaded: webcoding' "$t/inst/out" \
  && [ -s "$t/inst/agent-store/loaded/webcoding.json" ] \
  && [ -s "$t/inst/agent-store/packs/webcoding.json" ] \
  && grep -q 'https://seed-agents.com/dl/packs/webcoding.json' "$t/curl.log" \
  && ! grep -q 'http://' "$t/curl.log"; then
  ok 'Agent /packs install'
else
  bad 'Agent /packs install'
fi

# /pack alias via CLI.
run_cli "$t/alias" /pack jq
if [ "$(cat "$t/alias/st")" = 0 ] \
  && grep -qx 'loaded: jq' "$t/alias/out" \
  && [ -s "$t/alias/agent-store/loaded/jq.json" ] \
  && grep -q 'https://seed-agents.com/dl/packs/jq.json' "$t/curl.log"; then
  ok 'Agent /pack alias'
else
  bad 'Agent /pack alias'
fi

# Loop install alias.
run_loop_line "$t/loopinst" '/pack webcoding'
if [ "$(cat "$t/loopinst/st")" = 0 ] \
  && grep -qx 'loaded: webcoding' "$t/loopinst/out" \
  && [ -s "$t/loopinst/agent-store/loaded/webcoding.json" ]; then
  ok 'loop /pack alias'
else
  bad 'loop /pack alias'
fi

# Catalog HTTP failure: English error, no loaded.
SEED_TEST_HTTP_CODE=503
run_cli "$t/cathttp" /packs
unset SEED_TEST_HTTP_CODE
if [ "$(cat "$t/cathttp/st")" != 0 ] \
  && grep -q 'error: packs catalog: HTTP 503' "$t/cathttp/err" \
  && ! grep -q '^loaded:' "$t/cathttp/out" \
  && ! grep -q 'webcoding' "$t/cathttp/out"; then
  ok 'catalog HTTP fail'
else
  bad 'catalog HTTP fail'
fi

# Catalog network failure.
SEED_TEST_CURL_FAIL=1
run_cli "$t/catnet" /packs
unset SEED_TEST_CURL_FAIL
if [ "$(cat "$t/catnet/st")" != 0 ] \
  && grep -q 'error: packs catalog: network failed' "$t/catnet/err" \
  && ! grep -q '^loaded:' "$t/catnet/out"; then
  ok 'catalog network fail'
else
  bad 'catalog network fail'
fi

# Download HTTP failure: no receipt, no loaded.
SEED_TEST_HTTP_CODE=404
run_cli "$t/dlhttp" /packs install webcoding
unset SEED_TEST_HTTP_CODE
if [ "$(cat "$t/dlhttp/st")" != 0 ] \
  && grep -q 'error: pack webcoding: HTTP 404' "$t/dlhttp/err" \
  && ! grep -q '^loaded:' "$t/dlhttp/out" \
  && [ ! -f "$t/dlhttp/agent-store/loaded/webcoding.json" ]; then
  ok 'download HTTP fail'
else
  bad 'download HTTP fail'
fi

# Download network failure.
SEED_TEST_CURL_FAIL=1
run_cli "$t/dlnet" /pack webcoding
unset SEED_TEST_CURL_FAIL
if [ "$(cat "$t/dlnet/st")" != 0 ] \
  && grep -q 'error: pack webcoding: network failed' "$t/dlnet/err" \
  && ! grep -q '^loaded:' "$t/dlnet/out" \
  && [ ! -f "$t/dlnet/agent-store/loaded/webcoding.json" ]; then
  ok 'download network fail'
else
  bad 'download network fail'
fi

# Illegal slug never reaches curl.
run_cli "$t/trav" /packs install '../evil'
if [ "$(cat "$t/trav/st")" != 0 ] \
  && grep -q 'error: invalid pack name:' "$t/trav/err" \
  && [ ! -s "$t/curl.log" ]; then
  ok 'illegal slug ../evil'
else
  bad 'illegal slug ../evil'
fi

run_cli "$t/slash" /pack 'foo/bar'
if [ "$(cat "$t/slash/st")" != 0 ] \
  && grep -q 'error: invalid pack name:' "$t/slash/err" \
  && [ ! -s "$t/curl.log" ]; then
  ok 'illegal slug foo/bar'
else
  bad 'illegal slug foo/bar'
fi

run_cli "$t/urlslug" /packs install 'https://evil.example/x'
if [ "$(cat "$t/urlslug/st")" != 0 ] \
  && grep -q 'error: invalid pack name:' "$t/urlslug/err" \
  && [ ! -s "$t/curl.log" ]; then
  ok 'illegal slug URL'
else
  bad 'illegal slug URL'
fi

# Bundle/load failure does not claim success.
run_cli "$t/badload" /packs install badslug
if [ "$(cat "$t/badload/st")" != 0 ] \
  && ! grep -q '^loaded:' "$t/badload/out" \
  && [ ! -f "$t/badload/agent-store/loaded/badslug.json" ] \
  && grep -q 'https://seed-agents.com/dl/packs/badslug.json' "$t/curl.log"; then
  ok 'bundle load fail no fake success'
else
  bad 'bundle load fail no fake success'
fi

# Simple mode refuses list and install; no download.
SEED_MODE=simple
run_cli "$t/simple-list" /packs
if [ "$(cat "$t/simple-list/st")" != 0 ] \
  && grep -q 'pack commands need Agent mode. Run: sh seed.sh setup' "$t/simple-list/err" \
  && [ ! -s "$t/curl.log" ]; then
  ok 'Simple refuses /packs'
else
  bad 'Simple refuses /packs'
fi

run_cli "$t/simple-inst" /packs install webcoding
if [ "$(cat "$t/simple-inst/st")" != 0 ] \
  && grep -q 'pack commands need Agent mode. Run: sh seed.sh setup' "$t/simple-inst/err" \
  && [ ! -s "$t/curl.log" ] \
  && [ ! -f "$t/simple-inst/agent-store/loaded/webcoding.json" ]; then
  ok 'Simple refuses install'
else
  bad 'Simple refuses install'
fi

# Interactive loop keeps the session up after a refused command (exit 0).
run_loop_line "$t/simple-loop" /packs
if grep -q 'pack commands need Agent mode. Run: sh seed.sh setup' "$t/simple-loop/err" \
  && ! grep -q '^loaded:' "$t/simple-loop/out" \
  && [ ! -s "$t/curl.log" ]; then
  ok 'Simple loop refuses /packs'
else
  bad 'Simple loop refuses /packs'
fi
unset SEED_MODE

# Fixed host only: install never interpolates a user URL.
run_cli "$t/host" /packs install webcoding
if grep -q 'https://seed-agents.com/dl/packs/webcoding.json' "$t/host/../curl.log" 2>/dev/null \
  || grep -q 'https://seed-agents.com/dl/packs/webcoding.json' "$t/curl.log"; then
  if ! grep -v 'seed-agents.com' "$t/curl.log" | grep -q 'https://'; then
    ok 'fixed host'
  else
    bad 'fixed host'
  fi
else
  bad 'fixed host'
fi

# No remote hook machinery, and a .sh filename in a bundle is JSON-only.
if grep -q 'agent_fetch_hooks\|agent_run_hooks' "$SEED"; then
  bad 'no remote hook'
else
  run_cli "$t/hook" /packs install hooky
  if [ "$(cat "$t/hook/st")" = 0 ] \
    && grep -qx 'loaded: hooky' "$t/hook/out" \
    && [ -s "$t/hook/agent-store/packs/note.sh" ] \
    && grep -q '"prompt"' "$t/hook/agent-store/packs/note.sh" \
    && ! grep -q '\.sh' "$t/curl.log"; then
    ok 'no remote hook'
  else
    bad 'no remote hook'
  fi
fi

# Missing slug is usage, no request.
run_cli "$t/noslug" /packs install
if [ "$(cat "$t/noslug/st")" != 0 ] \
  && grep -q 'usage: /packs' "$t/noslug/err" \
  && [ ! -s "$t/curl.log" ]; then
  ok 'missing slug usage'
else
  bad 'missing slug usage'
fi

[ "$fail" -eq 0 ] || exit 1
printf 'all seed pack tests passed\n'
