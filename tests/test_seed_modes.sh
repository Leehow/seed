#!/bin/sh
# First-run Agent/Simple modes and generic `load -`. No network, no real model.
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
SEED=$ROOT/seed.sh
fail=0
t=$(mktemp -d "${TMPDIR:-/tmp}/seed-modes.XXXXXX")
trap 'rm -rf "$t"' EXIT HUP INT TERM
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }

unset SEED_MODE SLAB_SKIP_INIT SEED_SKIP_UPDATE SEED_SELF || true

/bin/sh -n "$SEED" && ok 'sh -n' || bad 'sh -n'

sz=$(wc -c < "$SEED" | tr -d ' ')
if [ "$sz" -le 60000 ]; then
  ok "seed.sh size $sz"
else
  bad "seed.sh size $sz"
fi

# Isolated curl: record argv and fail. Never hit the network.
mkdir -p "$t/bin"
SEED_TEST_CURL_LOG=$t/curl.log
export SEED_TEST_CURL_LOG
cat > "$t/bin/curl" <<'CURL'
#!/bin/sh
printf '%s\n' "$*" >> "${SEED_TEST_CURL_LOG:-/tmp/seed-curl.log}"
exit 1
CURL
chmod 755 "$t/bin/curl"
MOCKPATH=$t/bin:$PATH

run_setup() {
  home=$1
  shift
  mkdir -p "$home"
  set +e
  printf '%s\n' "$@" | env -u SEED_MODE SEED_HOME="$home" /bin/sh "$SEED" setup \
    > "$home/setup.out" 2> "$home/setup.err"
  set -e
}

# Default Agent: empty enter.
run_setup "$t/default" ''
if grep -q 'Choose your experience:' "$t/default/setup.err" \
  && grep -q '1) Agent' "$t/default/setup.err" \
  && grep -q '2) Simple' "$t/default/setup.err" \
  && grep -q 'Choice \[1\]:' "$t/default/setup.err" \
  && grep -qx 'mode: agent' "$t/default/setup.out" \
  && grep -qx agent "$t/default/agent-store/mode"; then
  ok 'default Agent'
else
  bad 'default Agent'
fi

# Menu must be English / ASCII.
if python3 -c '
import sys
p=sys.argv[1]
t=open(p, encoding="utf-8").read()
need=["Choose your experience:","1) Agent","2) Simple","Choice [1]:"]
sys.exit(0 if all(s in t for s in need) and all(ord(c)<128 for c in t) else 1)
' "$t/default/setup.err"; then
  ok 'menu text is English'
else
  bad 'menu text is English'
fi

# Invalid input retries in English, then accepts 1.
run_setup "$t/bad" 'x' '1'
if grep -q 'error: enter 1 or 2' "$t/bad/setup.err" \
  && grep -qx 'mode: agent' "$t/bad/setup.out"; then
  ok 'invalid choice retries'
else
  bad 'invalid choice retries'
fi

# Choose Simple.
run_setup "$t/simple" '2'
if grep -qx 'mode: simple' "$t/simple/setup.out" \
  && grep -qx simple "$t/simple/agent-store/mode"; then
  ok 'choose Simple'
else
  bad 'choose Simple'
fi

run_launch() {
  home=$1
  shift
  mkdir -p "$home" "$t/runs"
  set +e
  env AGENT_RUNS_DIR="$t/runs" SEED_HOME="$home" PATH="$MOCKPATH" \
    /bin/sh "$SEED" "$@" < /dev/null > "$home/run.out" 2> "$home/run.err"
  set -e
}

# Persisted mode is not asked again.
run_setup "$t/persist" '1'
run_launch "$t/persist" deepseek sk-test
if grep -q 'Choose your experience:' "$t/persist/run.err"; then
  bad 'persisted mode is not asked again'
else
  ok 'persisted mode is not asked again'
fi

# SEED_MODE overrides a persisted choice for this run (does not rewrite).
printf 'agent\n' > "$t/persist/agent-store/mode"
: > "$t/curl.log"
set +e
SEED_MODE=simple AGENT_RUNS_DIR="$t/runs" SEED_HOME="$t/persist" PATH="$MOCKPATH" \
  /bin/sh "$SEED" deepseek sk-test < /dev/null > "$t/override.out" 2> "$t/override.err"
set -e
if grep -qx agent "$t/persist/agent-store/mode" \
  && ! grep -q 'initializing:' "$t/override.err" \
  && ! grep -q 'agent pack:' "$t/override.err"; then
  ok 'SEED_MODE overrides'
else
  bad 'SEED_MODE overrides'
fi

# setup re-selects.
run_setup "$t/persist" '2'
if grep -qx simple "$t/persist/agent-store/mode" \
  && grep -qx 'mode: simple' "$t/persist/setup.out"; then
  ok 'setup re-selects'
else
  bad 'setup re-selects'
fi

# Agent bootstraps the official pack (fetch attempted).
: > "$t/curl.log"
set +e
SEED_MODE=agent AGENT_RUNS_DIR="$t/runs" SEED_HOME="$t/agent" PATH="$MOCKPATH" \
  /bin/sh "$SEED" deepseek sk-test < /dev/null > "$t/agent.out" 2> "$t/agent.err"
set -e
if grep -q 'initializing:' "$t/agent.err" \
  && grep -q 'agent pack:' "$t/agent.err"; then
  ok 'Agent bootstraps'
else
  bad 'Agent bootstraps'
fi

# Simple skips Agent Pack bootstrap.
: > "$t/curl.log"
set +e
SEED_MODE=simple AGENT_RUNS_DIR="$t/runs" SEED_HOME="$t/skip" PATH="$MOCKPATH" \
  /bin/sh "$SEED" deepseek sk-test < /dev/null > "$t/skip.out" 2> "$t/skip.err"
set -e
if grep -q 'initializing:' "$t/skip.err" || grep -q 'agent pack:' "$t/skip.err"; then
  bad 'Simple skips bootstrap'
else
  ok 'Simple skips bootstrap'
fi

# load - success.
set +e
printf '%s\n' '{"slug":"demo","prompt":"hi"}' | SEED_HOME="$t/load" \
  /bin/sh "$SEED" load - > "$t/load.out" 2> "$t/load.err"
load_st=$?
set -e
if [ "$load_st" -eq 0 ] && grep -qx 'loaded: demo' "$t/load.out" \
  && [ -s "$t/load/agent-store/loaded/demo.json" ] \
  && [ -s "$t/load/agent-store/packs/demo.json" ]; then
  ok 'load - success'
else
  bad 'load - success'
fi

# load - empty input fails.
set +e
printf '' | SEED_HOME="$t/empty" /bin/sh "$SEED" load - > "$t/empty.out" 2> "$t/empty.err"
empty_st=$?
set -e
if [ "$empty_st" -ne 0 ] && grep -q 'empty input' "$t/empty.err"; then
  ok 'load - empty fails'
else
  bad 'load - empty fails'
fi

# Path traversal slug is rejected.
set +e
printf '%s\n' '{"slug":"../evil","prompt":"x"}' | SEED_HOME="$t/trav" \
  /bin/sh "$SEED" load - > "$t/trav.out" 2> "$t/trav.err"
trav_st=$?
set -e
if [ "$trav_st" -ne 0 ] && [ ! -e "$t/trav/agent-store/loaded/../evil.json" ]; then
  ok 'load - rejects traversal slug'
else
  bad 'load - rejects traversal slug'
fi

# SEED_SELF: a non-executable copy gets a wrapper that can `load -`.
cp "$SEED" "$t/seed-ro.sh"
chmod 644 "$t/seed-ro.sh"
set +e
printf '%s\n' '{"slug":"wrap","prompt":"ok"}' | SEED_HOME="$t/wrap" \
  /bin/sh "$t/seed-ro.sh" load - > "$t/wrap.out" 2> "$t/wrap.err"
wrap_st=$?
set -e
if [ "$wrap_st" -eq 0 ] && [ -x "$t/wrap/seed" ]; then
  set +e
  printf '%s\n' '{"slug":"via-self","prompt":"ok"}' | SEED_HOME="$t/wrap" \
    "$t/wrap/seed" load - > "$t/self.out" 2> "$t/self.err"
  self_st=$?
  set -e
  if [ "$self_st" -eq 0 ] && grep -qx 'loaded: via-self' "$t/self.out"; then
    ok 'SEED_SELF load -'
  else
    bad 'SEED_SELF load -'
  fi
else
  bad 'SEED_SELF load -'
fi

[ "$fail" -eq 0 ] || exit 1
printf 'all seed mode tests passed\n'
