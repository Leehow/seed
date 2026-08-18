#!/bin/sh
# Offline contract tests for the standalone seed2 package.
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
SEED2=$ROOT/seed2.sh
fail=0

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }
ck() {
  name=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi
}

t=$(mktemp -d "${TMPDIR:-/tmp}/seed2-pkg.XXXXXX")
cleanup() { rm -rf "$t"; }
trap cleanup EXIT HUP INT TERM

ck 'build/pack2.sh exists' test -f "$ROOT/build/pack2.sh"
ck 'build/seed2.sh exists' test -f "$ROOT/build/seed2.sh"
ck 'seed2.sh syntax' /bin/sh -n "$SEED2"

repacked=$t/seed2.repacked
/bin/sh "$ROOT/build/pack2.sh" "$repacked" >/dev/null 2>&1
ck 'packed output is reproducible' cmp -s "$SEED2" "$repacked"

mkdir -p "$t/tools" "$t/work" "$t/state" "$t/plugin/agent"
work=$(CDPATH= cd "$t/work" && pwd -P)
cp "$ROOT/plugins/agent/index.json" "$t/plugin/agent/index.json"
cp "$ROOT/plugins/agent/init.json" "$t/plugin/agent/init.json"

# A curl-shaped offline plugin transport. Model turns use SEED_LLM_STUB.
cat > "$t/tools/curl" <<'CURL'
#!/bin/sh
out=
url=
while [ "$#" -gt 0 ]; do
  case $1 in
    -o) out=$2; shift 2 ;;
    -w) shift 2 ;;
    -H|--connect-timeout|--max-time|-X|--data-binary) shift 2 ;;
    -q|-s|-S|-sS|-f|-L|-fL|-N) shift ;;
    *) url=$1; shift ;;
  esac
done
case $url in
  */agent/index.json) cp "$SEED2_TEST_PLUGIN/agent/index.json" "$out" ;;
  */agent/init.json) cp "$SEED2_TEST_PLUGIN/agent/init.json" "$out" ;;
  */jq) printf '#!/bin/sh\nexec /usr/bin/jq "$@"\n' > "$out" ;;
  *) exit 22 ;;
esac
printf '200'
CURL
chmod 755 "$t/tools/curl"

cat > "$t/stub" <<'STUB'
#!/bin/sh
n=$(cat "$SEED2_TEST_COUNT" 2>/dev/null || printf 0)
n=$((n + 1))
printf '%s\n' "$n" > "$SEED2_TEST_COUNT"
msgs=
while [ "$#" -gt 0 ]; do
  case $1 in --messages) msgs=$2; shift 2 ;; *) shift ;; esac
done
last=$(jq -r '.[-1].content // ""' "$msgs")
case $last in
  *'Install this already-running standalone seed2 runtime'*)
    if [ "${SEED2_TEST_LIE:-0}" = 1 ]; then
      cmd='printf '\''{"command":"seed2","entry":"/missing/seed2"}\\n'\'' > "$SEED2_HOME/install-result.json"'
    else
      cmd='cp "$SEED2_TEST_SOURCE" "$SEED2_TEST_ENTRY" && chmod 755 "$SEED2_TEST_ENTRY" && jq -nc --arg e "$SEED2_TEST_ENTRY" '\''{command:"seed2",entry:$e}'\'' > "$SEED2_HOME/install-result.json"'
    fi
    jq -nc --arg a "$(jq -Rn --arg c "$cmd" '$c')" \
      '{content:"",tool_calls:[{id:"install",name:"shell",arguments:("{\"command\":"+$a+"}")}],usage:{prompt_tokens:1}}'
    ;;
  *'outer runtime will independently validate'*)
    printf '%s\n' '{"content":"done","tool_calls":[],"usage":{"prompt_tokens":1}}'
    ;;
  *'where am i'*)
    printf '%s\n' '{"content":"","tool_calls":[{"id":"pwd","name":"shell","arguments":"{\"command\":\"pwd\"}"}],"usage":{"prompt_tokens":1}}'
    ;;
  *)
    # Init and the post-tool turn both terminate. Init falls back to its
    # deterministic ready baseline; the ordinary task prints this answer.
    printf '%s\n' '{"content":"ok","tool_calls":[],"usage":{"prompt_tokens":1}}'
    ;;
esac
STUB
chmod 755 "$t/stub"
printf '0\n' > "$t/calls"

base_path=$PATH
export PATH="$t/tools:$base_path"
export SEED_PLUGIN_ROOT=http://offline
export SEED2_TEST_PLUGIN=$t/plugin
export SEED_LLM_STUB=$t/stub
export SEED2_TEST_COUNT=$t/calls
export SEED2_HOME=$t/state
export AGENT_RUNS_DIR=$work/.agent-runs
export SEED2_TEST_SOURCE=$SEED2

set +e
printf 'where am i\n\n' | (cd "$work" && /bin/sh "$SEED2" http://offline/v1 fake-key fake-model) \
  > "$t/first.out" 2> "$t/first.err"
first_status=$?
set -e
if [ "$first_status" -eq 0 ] \
  && grep -q '^initializing:$' "$t/first.err" \
  && grep -q '^ready$' "$t/first.err" \
  && grep -q '> ' "$t/first.err"; then
  ok 'first activation initializes and enters prompt'
else
  bad 'first activation initializes and enters prompt'
fi
if [ ! -e "$work/bin/agent" ] && [ ! -d "$work/bin" ]; then
  ok 'activation creates no agent shims'
else
  bad 'activation creates no agent shims'
fi
tool_observation=
for candidate in "$AGENT_RUNS_DIR"/*-1/tool-1-0.txt; do
  [ -f "$candidate" ] || continue
  [ -z "$tool_observation" ] || { tool_observation=ambiguous; break; }
  tool_observation=$candidate
done
if [ -n "$tool_observation" ] && [ "$tool_observation" != ambiguous ] \
  && grep -qxF -- "$work" "$tool_observation" \
  && grep -qxF -- "--- cwd: $work" "$tool_observation"; then
  ok 'ordinary shell tool records canonical launch workspace'
else
  bad 'ordinary shell tool records canonical launch workspace'
fi

before=$(cat "$t/calls")
printf '\n' | (cd "$work" && /bin/sh "$SEED2") > "$t/second.out" 2> "$t/second.err"
after=$(cat "$t/calls")
if [ "$before" = "$after" ] && ! grep -q '^initializing:$' "$t/second.err"; then
  ok 'second launch skips initialization'
else
  bad 'second launch skips initialization'
fi

before=$(cat "$t/calls")
printf '/help\n\n' | (cd "$work" && /bin/sh "$SEED2") > "$t/help.out" 2> "$t/help.err"
after=$(cat "$t/calls")
if [ "$before" = "$after" ] && grep -q '^/ini ' "$t/help.out"; then
  ok '/help is local and makes zero model calls'
else
  bad '/help is local and makes zero model calls'
fi

# Reproduce the clean-container failure: ensure_jq prepends state/bin only
# inside seed2, then the model mistakes that private runtime path for a
# caller-visible global command path. The installed file and receipt are real;
# validation must still fail because the frozen launch PATH cannot resolve it.
mkdir -p "$t/contam-state/agent-store"
cp -R "$t/state/agent-store/." "$t/contam-state/agent-store/"
cp "$t/state/.env" "$t/contam-state/.env"
export SEED2_HOME=$t/contam-state
export SEED2_TEST_ENTRY=$t/contam-state/bin/seed2
export PATH="$t/tools:/usr/bin:/bin"
export SEED_FORCE_JQ=1
export SEED_JQ_URL=http://offline/jq
set +e
printf '/ini\n' | (cd "$work" && /bin/sh "$SEED2") > "$t/contam.out" 2> "$t/contam.err"
contam_status=$?
set -e
if [ "$contam_status" -ne 0 ] \
  && [ -x "$t/contam-state/bin/seed2" ] \
  && grep -q 'error: installed seed2 is not the PATH entry' "$t/contam.err" \
  && ! grep -q 'installed:' "$t/contam.err"; then
  ok '/ini rejects runtime-only PATH contamination'
else
  bad '/ini rejects runtime-only PATH contamination'
fi
unset SEED_FORCE_JQ SEED_JQ_URL

mkdir -p "$t/clean-bin"
export SEED2_HOME=$t/state
export PATH="$t/clean-bin:$t/tools:$base_path"
export SEED2_TEST_ENTRY=$t/clean-bin/seed2
printf '/ini\n\n' | (cd "$work" && /bin/sh "$SEED2") > "$t/ini.out" 2> "$t/ini.err"
if [ -x "$t/clean-bin/seed2" ] \
  && grep -q '^installed: ' "$t/ini.err" \
  && SEED2_HOME=$t/state "$t/clean-bin/seed2" --probe | grep -q '^seed2.identity=seed2$'; then
  ok '/ini model install passes independent validation'
else
  bad '/ini model install passes independent validation'
fi

mkdir -p "$t/lie-state/agent-store"
cp -R "$t/state/agent-store/." "$t/lie-state/agent-store/"
cp "$t/state/.env" "$t/lie-state/.env"
export SEED2_HOME=$t/lie-state
export SEED2_TEST_LIE=1
set +e
printf '/ini\n' | (cd "$work" && /bin/sh "$SEED2") > "$t/lie.out" 2> "$t/lie.err"
lie_status=$?
set -e
if [ "$lie_status" -ne 0 ] && grep -q 'error:' "$t/lie.err"; then
  ok '/ini rejects a lying broken receipt'
else
  bad '/ini rejects a lying broken receipt'
fi

before=$(cat "$t/calls")
SEED2_HOME=$t/state /bin/sh "$SEED2" --probe > "$t/probe.out"
after=$(cat "$t/calls")
if [ "$before" = "$after" ] \
  && grep -q '^seed2.identity=seed2$' "$t/probe.out" \
  && ! grep -q 'fake-key' "$t/probe.out"; then
  ok '--probe is offline, stable, and secret-free'
else
  bad '--probe is offline, stable, and secret-free'
fi

if jq -e 'length == 2
    and ([.[].function.name] | sort) == ["edit", "shell"]' \
    "$ROOT/build/prompts/tools.json" >/dev/null 2>&1; then
  ok 'seed2 retains exactly shell and edit API tools'
else
  bad 'seed2 retains exactly shell and edit API tools'
fi

[ "$fail" -eq 0 ] || exit 1
printf 'all seed2 package tests passed\n'
