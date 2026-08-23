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

unset SEED_MODE SLAB_SKIP_INIT SEED_SKIP_UPDATE SEED_SELF SEED_RUNTIME_URL || true

/bin/sh -n "$SEED" && ok 'sh -n' || bad 'sh -n'

sz=$(wc -c < "$SEED" | tr -d ' ')
ok "seed.sh size $sz"

mkdir -p "$t/bin" "$t/runs"
SEED_TEST_CURL_LOG=$t/curl.log
export SEED_TEST_CURL_LOG
cat > "$t/bin/curl" <<'CURL'
#!/bin/sh
printf '%s\n' "$*" >> "${SEED_TEST_CURL_LOG:-/tmp/seed-curl.log}"
# Honor -o DEST if present so http_get does not leave leftovers.
out=
prev=
for a in "$@"; do
  if [ "$prev" = -o ]; then out=$a; fi
  prev=$a
done
[ -n "$out" ] && : > "$out"
exit 1
CURL
chmod 755 "$t/bin/curl"
MOCKPATH=$t/bin:$PATH

run_setup() {
  home=$1
  shift
  mkdir -p "$home"
  set +e
  printf '%s\n' "$@" | env -u SEED_MODE -u SEED_SELF SEED_HOME="$home" \
    SEED_RUNTIME_URL="$SEED" /bin/sh "$SEED" setup \
    > "$home/setup.out" 2> "$home/setup.err"
  set -e
}

# Default Agent: empty enter.
run_setup "$t/default" ''
if [ -f "$t/default/agent-store/mode" ] \
  && grep -qx agent "$t/default/agent-store/mode" \
  && grep -qx 'mode: agent' "$t/default/setup.out" \
  && grep -q 'Choose your experience:' "$t/default/setup.err" \
  && grep -q '1) Agent' "$t/default/setup.err" \
  && grep -q '2) Simple' "$t/default/setup.err" \
  && grep -q 'Choice \[1\]:' "$t/default/setup.err"; then
  ok 'default Agent'
else
  bad 'default Agent'
fi

if python3 -c '
import sys
t=open(sys.argv[1], encoding="utf-8").read()
need=["Choose your experience:","1) Agent","2) Simple","Choice [1]:"]
sys.exit(0 if all(s in t for s in need) and all(ord(c)<128 for c in t) else 1)
' "$t/default/setup.err"; then
  ok 'menu text is English'
else
  bad 'menu text is English'
fi

run_setup "$t/bad" 'x' '1'
if grep -q 'error: enter 1 or 2' "$t/bad/setup.err" \
  && grep -qx agent "$t/bad/agent-store/mode"; then
  ok 'invalid choice retries'
else
  bad 'invalid choice retries'
fi

run_setup "$t/simple" '2'
if grep -qx simple "$t/simple/agent-store/mode"; then
  ok 'choose Simple'
else
  bad 'choose Simple'
fi

# Persisted mode is not asked again.
run_setup "$t/persist" '1'
set +e
env -u SEED_MODE AGENT_RUNS_DIR="$t/runs" SEED_HOME="$t/persist" \
  SEED_RUNTIME_URL="$SEED" PATH="$MOCKPATH" \
  /bin/sh "$SEED" deepseek sk-test < /dev/null \
  > "$t/persist/run.out" 2> "$t/persist/run.err"
persist_st=$?
set -e
if grep -q 'Choose your experience:' "$t/persist/run.err"; then
  bad 'persisted mode is not asked again'
else
  ok 'persisted mode is not asked again'
fi

# SEED_MODE overrides a persisted choice for this run (does not rewrite).
printf 'agent\n' > "$t/persist/agent-store/mode"
: > "$t/curl.log"
set +e
SEED_MODE=simple AGENT_RUNS_DIR="$t/runs" SEED_HOME="$t/persist" \
  SEED_RUNTIME_URL="$SEED" PATH="$MOCKPATH" \
  /bin/sh "$SEED" deepseek sk-test < /dev/null \
  > "$t/override.out" 2> "$t/override.err"
set -e
if grep -qx agent "$t/persist/agent-store/mode" \
  && ! grep -q 'initializing:' "$t/override.err" \
  && ! grep -q 'agent pack:' "$t/override.err" \
  && ! grep -q 'agent/index.json' "$t/curl.log"; then
  ok 'SEED_MODE overrides'
else
  bad 'SEED_MODE overrides'
fi

run_setup "$t/persist" '2'
if grep -qx simple "$t/persist/agent-store/mode"; then
  ok 'setup re-selects'
else
  bad 'setup re-selects'
fi

# Agent bootstraps: fetch attempted, nonzero, curl log shows pack catalog.
: > "$t/curl.log"
set +e
SEED_MODE=agent AGENT_RUNS_DIR="$t/runs" SEED_HOME="$t/agent" \
  SEED_RUNTIME_URL="$SEED" PATH="$MOCKPATH" \
  /bin/sh "$SEED" deepseek sk-test < /dev/null \
  > "$t/agent.out" 2> "$t/agent.err"
agent_st=$?
set -e
if [ "$agent_st" -ne 0 ] \
  && grep -q 'initializing:' "$t/agent.err" \
  && grep -q 'agent pack:' "$t/agent.err" \
  && grep -q 'agent/index.json' "$t/curl.log"; then
  ok 'Agent bootstraps'
else
  bad 'Agent bootstraps'
fi

# Simple skips bootstrap: no pack fetch in curl log.
: > "$t/curl.log"
set +e
SEED_MODE=simple AGENT_RUNS_DIR="$t/runs" SEED_HOME="$t/skip" \
  SEED_RUNTIME_URL="$SEED" PATH="$MOCKPATH" \
  /bin/sh "$SEED" deepseek sk-test < /dev/null \
  > "$t/skip.out" 2> "$t/skip.err"
skip_st=$?
set -e
if [ "$skip_st" -eq 0 ] \
  && ! grep -q 'initializing:' "$t/skip.err" \
  && ! grep -q 'agent pack:' "$t/skip.err" \
  && ! grep -q 'agent/index.json' "$t/curl.log"; then
  ok 'Simple skips bootstrap'
else
  bad 'Simple skips bootstrap'
fi

# Illegal SEED_MODE: English error, nonzero, no persist.
set +e
SEED_MODE=nope SEED_HOME="$t/badmode" SEED_RUNTIME_URL="$SEED" \
  /bin/sh "$SEED" setup > "$t/badmode.out" 2> "$t/badmode.err"
badmode_st=$?
set -e
if [ "$badmode_st" -ne 0 ] \
  && grep -q 'SEED_MODE must be agent or simple' "$t/badmode.err" \
  && [ ! -f "$t/badmode/agent-store/mode" ]; then
  ok 'illegal SEED_MODE'
else
  bad 'illegal SEED_MODE'
fi

# No controlling TTY and no SEED_MODE: default Agent, do not hang.
set +e
python3 - "$SEED" "$t/notty" "$MOCKPATH" "$t/runs" <<'PY'
import os, subprocess, sys
seed, home, path, runs = sys.argv[1:]
os.makedirs(home, exist_ok=True)
env = os.environ.copy()
env.pop("SEED_MODE", None)
env.pop("SEED_SELF", None)
env["SEED_HOME"] = home
env["SEED_RUNTIME_URL"] = seed
env["PATH"] = path
env["AGENT_RUNS_DIR"] = runs
p = subprocess.Popen(
    ["/bin/sh", seed, "deepseek", "sk-test"],
    stdin=subprocess.DEVNULL,
    stdout=open(os.path.join(home, "out"), "w"),
    stderr=open(os.path.join(home, "err"), "w"),
    start_new_session=True,
    env=env,
)
try:
    p.wait(timeout=20)
except subprocess.TimeoutExpired:
    p.kill()
    p.wait()
    sys.exit(2)
sys.exit(0)
PY
notty_st=$?
set -e
if [ -f "$t/notty/agent-store/mode" ] \
  && grep -qx agent "$t/notty/agent-store/mode" \
  && ! grep -q 'Choose your experience:' "$t/notty/err"; then
  ok 'no TTY defaults Agent'
else
  bad 'no TTY defaults Agent'
fi

# True stdin launch (curl|sh equivalent): materialize + usable SEED_SELF.
mkdir -p "$t/stdin"
: > "$t/curl.log"
set +e
SEED_MODE=simple SEED_HOME="$t/stdin" SEED_RUNTIME_URL="$SEED" \
  AGENT_RUNS_DIR="$t/runs" PATH="$MOCKPATH" \
  /bin/sh -s -- setup < "$SEED" > "$t/stdin/out" 2> "$t/stdin/err"
stdin_st=$?
set -e
if [ "$stdin_st" -eq 0 ] && [ -x "$t/stdin/seed" ] && [ -f "$t/stdin/.seed-runtime.sh" ]; then
  set +e
  printf '%s\n' '{"slug":"fromself","prompt":"ok"}' | SEED_HOME="$t/stdin" \
    "$t/stdin/seed" load - > "$t/stdin/load.out" 2> "$t/stdin/load.err"
  stdin_load=$?
  set -e
  if [ "$stdin_load" -eq 0 ] \
    && grep -qx 'loaded: fromself' "$t/stdin/load.out" \
    && [ -s "$t/stdin/agent-store/loaded/fromself.json" ]; then
    ok 'stdin SEED_SELF load -'
  else
    bad 'stdin SEED_SELF load -'
  fi
else
  bad 'stdin SEED_SELF load -'
fi

# stdin launch without a cache or source must fail in English, no fake SEED_SELF.
mkdir -p "$t/stdin-fail"
: > "$t/curl.log"
set +e
env -u SEED_RUNTIME_URL -u SEED_SELF SEED_HOME="$t/stdin-fail" PATH="$MOCKPATH" \
  /bin/sh -s -- setup < "$SEED" > "$t/stdin-fail/out" 2> "$t/stdin-fail/err"
stdin_fail=$?
set -e
if [ "$stdin_fail" -ne 0 ] \
  && grep -q 'cannot materialize seed runtime' "$t/stdin-fail/err" \
  && [ ! -x "$t/stdin-fail/seed" ]; then
  ok 'stdin materialize failure'
else
  bad 'stdin materialize failure'
fi

do_load() {
  home=$1
  body=$2
  mkdir -p "$home"
  set +e
  printf '%s\n' "$body" | SEED_HOME="$home" SEED_RUNTIME_URL="$SEED" \
    /bin/sh "$SEED" load - > "$home/load.out" 2> "$home/load.err"
  echo $? > "$home/load.st"
  set -e
}

# load - success.
do_load "$t/load" '{"slug":"demo","prompt":"hi"}'
if [ "$(cat "$t/load/load.st")" = 0 ] \
  && grep -qx 'loaded: demo' "$t/load/load.out" \
  && [ -s "$t/load/agent-store/loaded/demo.json" ] \
  && [ -s "$t/load/agent-store/packs/demo.json" ]; then
  ok 'load - success'
else
  bad 'load - success'
fi

# empty input fails.
set +e
printf '' | SEED_HOME="$t/empty" SEED_RUNTIME_URL="$SEED" \
  /bin/sh "$SEED" load - > "$t/empty.out" 2> "$t/empty.err"
empty_st=$?
set -e
if [ "$empty_st" -ne 0 ] && grep -q 'empty input' "$t/empty.err" \
  && [ ! -f "$t/empty/agent-store/loaded/pack.json" ]; then
  ok 'load - empty fails'
else
  bad 'load - empty fails'
fi

# Traversal slug rejected; no receipt, no loaded line.
do_load "$t/trav" '{"slug":"../evil","prompt":"x"}'
if [ "$(cat "$t/trav/load.st")" != 0 ] \
  && ! grep -q '^loaded:' "$t/trav/load.out" \
  && [ ! -e "$t/trav/agent-store/loaded/../evil.json" ] \
  && [ ! -e "$t/trav/agent-store/loaded/evil.json" ]; then
  ok 'load - rejects traversal slug'
else
  bad 'load - rejects traversal slug'
fi

# Illegal path in files: whole bundle fails, no partial write, no receipt.
mkdir -p "$t/partial/agent-store/packs"
printf 'keep\n' > "$t/partial/agent-store/packs/ok.json"
do_load "$t/partial" '{"slug":"mix","files":{"ok.json":{"prompt":"new"},"../x":1}}'
if [ "$(cat "$t/partial/load.st")" != 0 ] \
  && ! grep -q '^loaded:' "$t/partial/load.out" \
  && [ ! -f "$t/partial/agent-store/loaded/mix.json" ] \
  && [ ! -e "$t/partial/agent-store/packs/x" ] \
  && [ ! -e "$t/partial/x" ] \
  && grep -qx keep "$t/partial/agent-store/packs/ok.json"; then
  ok 'load - illegal path is atomic'
else
  bad 'load - illegal path is atomic'
fi

# Illegal files shape.
do_load "$t/shape" '{"slug":"shp","files":[]}'
if [ "$(cat "$t/shape/load.st")" != 0 ] \
  && ! grep -q '^loaded:' "$t/shape/load.out" \
  && [ ! -f "$t/shape/agent-store/loaded/shp.json" ] \
  && [ ! -f "$t/shape/agent-store/packs/shp.json" ]; then
  ok 'load - illegal files shape'
else
  bad 'load - illegal files shape'
fi

# Successful replace is atomic (old content gone, new present, receipt exists).
do_load "$t/repl" '{"slug":"demo","prompt":"v1"}'
do_load "$t/repl" '{"slug":"demo","prompt":"v2"}'
if [ "$(cat "$t/repl/load.st")" = 0 ] \
  && grep -qx 'loaded: demo' "$t/repl/load.out" \
  && grep -q '"prompt": "v2"' "$t/repl/agent-store/packs/demo.json" \
  && ! grep -q '"prompt": "v1"' "$t/repl/agent-store/packs/demo.json" \
  && [ -s "$t/repl/agent-store/loaded/demo.json" ]; then
  ok 'load - atomic replace'
else
  bad 'load - atomic replace'
fi

# Failed replace leaves previous pack + receipt untouched.
do_load "$t/keep" '{"slug":"demo","prompt":"v1"}'
do_load "$t/keep" '{"slug":"demo","files":{"demo.json":{"prompt":"v2"},"a/b":1}}'
if [ "$(cat "$t/keep/load.st")" != 0 ] \
  && ! grep -q '^loaded:' "$t/keep/load.out" \
  && grep -q '"prompt": "v1"' "$t/keep/agent-store/packs/demo.json" \
  && grep -q 'v1' "$t/keep/agent-store/loaded/demo.json"; then
  ok 'load - failed replace keeps old'
else
  bad 'load - failed replace keeps old'
fi

# Symlink dest is refused; target file unchanged; no receipt.
mkdir -p "$t/sym/agent-store/packs" "$t/sym/agent-store/loaded"
printf 'OUTSIDE\n' > "$t/outside"
ln -s "$t/outside" "$t/sym/agent-store/packs/x.json"
do_load "$t/sym" '{"slug":"x","files":{"x.json":{"prompt":"NEW"}}}'
if [ "$(cat "$t/sym/load.st")" != 0 ] \
  && ! grep -q '^loaded:' "$t/sym/load.out" \
  && [ ! -f "$t/sym/agent-store/loaded/x.json" ] \
  && [ -L "$t/sym/agent-store/packs/x.json" ] \
  && grep -qx OUTSIDE "$t/outside"; then
  ok 'load - rejects symlink dest'
else
  bad 'load - rejects symlink dest'
fi

# Wrapper from a non-executable copy.
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
    ok 'SEED_SELF wrapper'
  else
    bad 'SEED_SELF wrapper'
  fi
else
  bad 'SEED_SELF wrapper'
fi

# Mid-commit failure rolls back earlier files and restores old regular files.
mkdir -p "$t/roll/agent-store/packs" "$t/roll/agent-store/loaded"
printf 'OLD_A\n' > "$t/roll/agent-store/packs/a.json"
printf 'OLD_B\n' > "$t/roll/agent-store/packs/b.json"
printf 'OLD_R\n' > "$t/roll/agent-store/loaded/pair.json"
export SEED_TEST_FAIL_AT=2
do_load "$t/roll" '{"slug":"pair","files":{"a.json":{"v":"A"},"b.json":{"v":"B"}}}'
unset SEED_TEST_FAIL_AT
if [ "$(cat "$t/roll/load.st")" != 0 ] \
  && ! grep -q '^loaded:' "$t/roll/load.out" \
  && grep -qx OLD_A "$t/roll/agent-store/packs/a.json" \
  && grep -qx OLD_B "$t/roll/agent-store/packs/b.json" \
  && grep -qx OLD_R "$t/roll/agent-store/loaded/pair.json" \
  && [ ! -e "$t/roll/agent-store/packs/a.json.new" ] \
  && [ ! -e "$t/roll/agent-store/packs/b.json.new" ]; then
  ok 'load - mid-commit rolls back'
else
  bad 'load - mid-commit rolls back'
fi

# New files from a failed commit are removed.
export SEED_TEST_FAIL_AT=2
do_load "$t/rollnew" '{"slug":"pair","files":{"a.json":{"v":"A"},"b.json":{"v":"B"}}}'
unset SEED_TEST_FAIL_AT
if [ "$(cat "$t/rollnew/load.st")" != 0 ] \
  && ! grep -q '^loaded:' "$t/rollnew/load.out" \
  && [ ! -f "$t/rollnew/agent-store/loaded/pair.json" ] \
  && [ ! -f "$t/rollnew/agent-store/packs/a.json" ] \
  && [ ! -f "$t/rollnew/agent-store/packs/b.json" ]; then
  ok 'load - mid-commit drops new files'
else
  bad 'load - mid-commit drops new files'
fi

# Directory dest is refused; no .new leftover.
mkdir -p "$t/dir/agent-store/packs/z.json" "$t/dir/agent-store/loaded"
do_load "$t/dir" '{"slug":"z","files":{"z.json":{"prompt":"n"}}}'
if [ "$(cat "$t/dir/load.st")" != 0 ] \
  && ! grep -q '^loaded:' "$t/dir/load.out" \
  && [ ! -f "$t/dir/agent-store/loaded/z.json" ] \
  && [ ! -e "$t/dir/agent-store/packs/z.json.new" ] \
  && [ -d "$t/dir/agent-store/packs/z.json" ]; then
  ok 'load - rejects directory dest'
else
  bad 'load - rejects directory dest'
fi

# Receipt dest is a directory: pack files unchanged, no loaded.
do_load "$t/recdir" '{"slug":"demo","prompt":"v1"}'
rm -f "$t/recdir/agent-store/loaded/demo.json"
mkdir -p "$t/recdir/agent-store/loaded/demo.json"
do_load "$t/recdir" '{"slug":"demo","prompt":"v2"}'
if [ "$(cat "$t/recdir/load.st")" != 0 ] \
  && ! grep -q '^loaded:' "$t/recdir/load.out" \
  && grep -q '"prompt": "v1"' "$t/recdir/agent-store/packs/demo.json" \
  && [ -d "$t/recdir/agent-store/loaded/demo.json" ] \
  && [ ! -e "$t/recdir/agent-store/loaded/demo.json.new" ] \
  && [ ! -e "$t/recdir/agent-store/packs/demo.json.new" ]; then
  ok 'load - receipt dir rolls back'
else
  bad 'load - receipt dir rolls back'
fi

# Receipt commit failure after pack write rolls pack back.
do_load "$t/recfail" '{"slug":"demo","prompt":"v1"}'
export SEED_TEST_FAIL_AT=2
do_load "$t/recfail" '{"slug":"demo","prompt":"v2"}'
unset SEED_TEST_FAIL_AT
if [ "$(cat "$t/recfail/load.st")" != 0 ] \
  && ! grep -q '^loaded:' "$t/recfail/load.out" \
  && grep -q '"prompt": "v1"' "$t/recfail/agent-store/packs/demo.json" \
  && grep -q 'v1' "$t/recfail/agent-store/loaded/demo.json"; then
  ok 'load - receipt fail rolls back pack'
else
  bad 'load - receipt fail rolls back pack'
fi

# Running $SEED_HOME/seed (full runtime) must not truncate it.
mkdir -p "$t/selfhome"
cp "$SEED" "$t/selfhome/seed"
chmod 755 "$t/selfhome/seed"
before_sz=$(wc -c < "$t/selfhome/seed" | tr -d ' ')
before_sum=$(cksum < "$t/selfhome/seed")
set +e
printf '%s\n' '{"slug":"selfok","prompt":"ok"}' | SEED_HOME="$t/selfhome" \
  "$t/selfhome/seed" load - > "$t/selfhome/out" 2> "$t/selfhome/err"
selfhome_st=$?
set -e
after_sz=$(wc -c < "$t/selfhome/seed" | tr -d ' ')
after_sum=$(cksum < "$t/selfhome/seed")
if [ "$selfhome_st" -eq 0 ] \
  && [ "$before_sz" = "$after_sz" ] \
  && [ "$before_sum" = "$after_sum" ] \
  && grep -qx 'loaded: selfok' "$t/selfhome/out" \
  && [ -s "$t/selfhome/agent-store/loaded/selfok.json" ]; then
  ok 'SEED_SELF no self-overwrite'
else
  bad 'SEED_SELF no self-overwrite'
fi

[ "$fail" -eq 0 ] || exit 1
printf 'all seed mode tests passed\n'
