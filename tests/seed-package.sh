#!/bin/sh
# Offline contract tests for the standalone seed package.
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
SEED=$ROOT/seed.sh
fail=0

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1"; fail=$((fail + 1)); }
ck() {
  name=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name"; fi
}

t=$(mktemp -d "${TMPDIR:-/tmp}/seed-pkg.XXXXXX")
cleanup() { rm -rf "$t"; }
trap cleanup EXIT HUP INT TERM

ck 'seed.sh is the standalone source' test -f "$SEED"
ck 'seed.sh syntax' /bin/sh -n "$SEED"
root_seed_count=$(find "$ROOT" -maxdepth 1 -type f -name 'seed*.sh' | wc -l | tr -d ' ')
if [ "$root_seed_count" = 1 ] \
  && find "$ROOT" -maxdepth 1 -type f -name 'seed*.sh' | grep -qxF "$SEED"; then
  ok 'seed.sh is the only root runtime'
else
  bad 'seed.sh is the only root runtime'
fi
ck 'legacy build source is absent' test ! -e "$ROOT/build/pack.sh"
ck 'legacy agent entry is absent' test ! -e "$ROOT/bin/agent"
if grep -q "SEED_PLUGIN_ROOT:-https://raw.githubusercontent.com/Leehow/slab/main/plugins}" "$SEED" \
  && ! grep -q 'pipi.aichattrpg.com/downloads/slab' "$SEED"; then
  ok 'default plugin_root is GitHub raw plugins'
else
  bad 'default plugin_root is GitHub raw plugins'
fi
if grep -q "https://github.com/jqlang/jq/releases/download/jq-%s/%s" "$SEED" \
  && ! grep -q 'jq_mirror_url' "$SEED" \
  && ! grep -q 'plugin_join "$(plugin_root)" "jq/' "$SEED"; then
  ok 'jq default source is official GitHub Releases'
else
  bad 'jq default source is official GitHub Releases'
fi

# Offline asset/URL mapping: fake uname, source only the jq helpers.
sed -n '/^jq_asset_name()/,/^}$/p; /^jq_official_url()/,/^}$/p' "$SEED" > "$t/jqfn.sh"
mkdir -p "$t/uname"
cat > "$t/uname/uname" <<'UNAME'
#!/bin/sh
case ${1:-} in
  -s) printf '%s\n' "${FAKE_UNAME_S:-Linux}" ;;
  -m) printf '%s\n' "${FAKE_UNAME_M:-x86_64}" ;;
  *) printf '%s\n' "${FAKE_UNAME_S:-Linux}" ;;
esac
UNAME
chmod 755 "$t/uname/uname"
jq_map_ok=1
check_jq_map() {
  os=$1 arch=$2 want=$3
  got=$(FAKE_UNAME_S=$os FAKE_UNAME_M=$arch PATH="$t/uname:$PATH" SEED_JQ_VER=1.7.1 \
    /bin/sh -c '. "$1"; jq_official_url' _ "$t/jqfn.sh") || return 1
  [ "$got" = "https://github.com/jqlang/jq/releases/download/jq-1.7.1/$want" ]
}
check_jq_map Linux x86_64 jq-linux-amd64 || jq_map_ok=0
check_jq_map Linux amd64 jq-linux-amd64 || jq_map_ok=0
check_jq_map Linux aarch64 jq-linux-arm64 || jq_map_ok=0
check_jq_map Darwin arm64 jq-macos-arm64 || jq_map_ok=0
check_jq_map Darwin x86_64 jq-macos-amd64 || jq_map_ok=0
check_jq_map MINGW64_NT amd64 jq-windows-amd64.exe || jq_map_ok=0
if [ "$jq_map_ok" = 1 ]; then
  ok 'jq asset maps OS/arch to official GitHub URL'
else
  bad 'jq asset maps OS/arch to official GitHub URL'
fi

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
  */agent/index.json) cp "$SEED_TEST_PLUGIN/agent/index.json" "$out" ;;
  */agent/init.json) cp "$SEED_TEST_PLUGIN/agent/init.json" "$out" ;;
  */jq) printf '#!/bin/sh\nexec /usr/bin/jq "$@"\n' > "$out" ;;
  *) exit 22 ;;
esac
printf '200'
CURL
chmod 755 "$t/tools/curl"

cat > "$t/stub" <<'STUB'
#!/bin/sh
n=$(cat "$SEED_TEST_COUNT" 2>/dev/null || printf 0)
n=$((n + 1))
printf '%s\n' "$n" > "$SEED_TEST_COUNT"
msgs=
while [ "$#" -gt 0 ]; do
  case $1 in --messages) msgs=$2; shift 2 ;; *) shift ;; esac
done
last=$(jq -r '.[-1].content // ""' "$msgs")
case $last in
  *'Install this already-running standalone seed runtime'*)
    if [ "${SEED_TEST_LIE:-0}" = 1 ]; then
      cmd='printf '\''{"command":"seed","entry":"/missing/seed"}\\n'\'' > "$SEED_HOME/install-result.json"'
    else
      cmd='cp "$SEED_TEST_SOURCE" "$SEED_TEST_ENTRY" && chmod 755 "$SEED_TEST_ENTRY" && jq -nc --arg e "$SEED_TEST_ENTRY" '\''{command:"seed",entry:$e}'\'' > "$SEED_HOME/install-result.json"'
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
  *'edit contract'*)
    printf '%s\n' '{"content":"","tool_calls":[{"id":"edit","name":"edit","arguments":"{\"path\":\"contract.txt\",\"old_text\":\"old\",\"new_text\":\"new\"}"}],"usage":{"prompt_tokens":1}}'
    ;;
  *'empty turn probe'*)
    # First reply is a provider glitch: blank content, no tool_calls.
    if [ -f "${SEED_TEST_EMPTY_FLAG:-/nonexistent}" ]; then
      printf '%s\n' '{"content":"second answer","tool_calls":[],"usage":{"prompt_tokens":1}}'
    else
      : > "$SEED_TEST_EMPTY_FLAG"
      printf '%s\n' '{"content":"","tool_calls":[],"usage":{"prompt_tokens":1}}'
    fi
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
export SEED_TEST_PLUGIN=$t/plugin
export SEED_LLM_STUB=$t/stub
export SEED_TEST_COUNT=$t/calls
export SEED_HOME=$t/state
export AGENT_RUNS_DIR=$work/.agent-runs
export SEED_TEST_SOURCE=$SEED

set +e
printf 'where am i\n\n' | (cd "$work" && /bin/sh "$SEED" http://offline/v1 fake-key fake-model) \
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

printf 'old\n' > "$work/contract.txt"
(cd "$work" && /bin/sh "$SEED" --oneshot 'edit contract') > "$t/edit.out" 2> "$t/edit.err"
if grep -qx new "$work/contract.txt"; then
  ok 'oneshot executes the exact edit tool contract'
else
  bad 'oneshot executes the exact edit tool contract'
fi

# Load the actual edit implementation without entering the standalone main so
# failure status and no-write behavior can be checked directly and offline.
awk '/^# Standalone seed entry\./ { exit } { print }' "$SEED" > "$t/edit-runtime.sh"
printf '\nedit_main "$@"\n' >> "$t/edit-runtime.sh"

printf 'unchanged\n' > "$work/edit-zero.txt"
cp "$work/edit-zero.txt" "$t/edit-zero.before"
set +e
/bin/sh "$t/edit-runtime.sh" "$work/edit-zero.txt" missing replacement \
  > "$t/edit-zero.out" 2> "$t/edit-zero.err"
zero_status=$?
set -e
if [ "$zero_status" -ne 0 ] && cmp -s "$t/edit-zero.before" "$work/edit-zero.txt"; then
  ok 'edit rejects zero matches without changing the file'
else
  bad 'edit rejects zero matches without changing the file'
fi

printf 'duplicate\nduplicate\n' > "$work/edit-multi.txt"
cp "$work/edit-multi.txt" "$t/edit-multi.before"
set +e
/bin/sh "$t/edit-runtime.sh" "$work/edit-multi.txt" duplicate replacement \
  > "$t/edit-multi.out" 2> "$t/edit-multi.err"
multi_status=$?
set -e
if [ "$multi_status" -ne 0 ] && cmp -s "$t/edit-multi.before" "$work/edit-multi.txt"; then
  ok 'edit rejects multiple matches without changing the file'
else
  bad 'edit rejects multiple matches without changing the file'
fi

before=$(cat "$t/calls")
printf '\n' | (cd "$work" && /bin/sh "$SEED") > "$t/second.out" 2> "$t/second.err"
after=$(cat "$t/calls")
if [ "$before" = "$after" ] && ! grep -q '^initializing:$' "$t/second.err"; then
  ok 'second launch skips initialization'
else
  bad 'second launch skips initialization'
fi

before=$(cat "$t/calls")
printf '/help\n\n' | (cd "$work" && /bin/sh "$SEED") > "$t/help.out" 2> "$t/help.err"
after=$(cat "$t/calls")
if [ "$before" = "$after" ] && grep -q '^/ini ' "$t/help.out"; then
  ok '/help is local and makes zero model calls'
else
  bad '/help is local and makes zero model calls'
fi

# Reproduce the clean-container failure: ensure_jq prepends state/bin only
# inside seed, then the model mistakes that private runtime path for a
# caller-visible global command path. The installed file and receipt are real;
# validation must still fail because the frozen launch PATH cannot resolve it.
mkdir -p "$t/contam-state/agent-store"
cp -R "$t/state/agent-store/." "$t/contam-state/agent-store/"
cp "$t/state/.env" "$t/contam-state/.env"
export SEED_HOME=$t/contam-state
export SEED_TEST_ENTRY=$t/contam-state/bin/seed
export PATH="$t/tools:/usr/bin:/bin"
export SEED_FORCE_JQ=1
export SEED_JQ_URL=http://offline/jq
set +e
printf '/ini\n' | (cd "$work" && /bin/sh "$SEED") > "$t/contam.out" 2> "$t/contam.err"
contam_status=$?
set -e
if [ "$contam_status" -ne 0 ] \
  && [ -x "$t/contam-state/bin/seed" ] \
  && grep -q 'error: installed seed is not the PATH entry' "$t/contam.err" \
  && ! grep -q 'installed:' "$t/contam.err"; then
  ok '/ini rejects runtime-only PATH contamination'
else
  bad '/ini rejects runtime-only PATH contamination'
fi
unset SEED_FORCE_JQ SEED_JQ_URL

mkdir -p "$t/clean-bin"
export SEED_HOME=$t/state
export PATH="$t/clean-bin:$t/tools:$base_path"
export SEED_TEST_ENTRY=$t/clean-bin/seed
printf '/ini\n\n' | (cd "$work" && /bin/sh "$SEED") > "$t/ini.out" 2> "$t/ini.err"
if [ -x "$t/clean-bin/seed" ] \
  && grep -q '^installed: ' "$t/ini.err" \
  && SEED_HOME=$t/state "$t/clean-bin/seed" --probe | grep -q '^seed.identity=seed$'; then
  ok '/ini model install passes independent validation'
else
  bad '/ini model install passes independent validation'
fi

mkdir -p "$t/lie-state/agent-store"
cp -R "$t/state/agent-store/." "$t/lie-state/agent-store/"
cp "$t/state/.env" "$t/lie-state/.env"
export SEED_HOME=$t/lie-state
export SEED_TEST_LIE=1
set +e
printf '/ini\n' | (cd "$work" && /bin/sh "$SEED") > "$t/lie.out" 2> "$t/lie.err"
lie_status=$?
set -e
if [ "$lie_status" -ne 0 ] && grep -q 'error:' "$t/lie.err"; then
  ok '/ini rejects a lying broken receipt'
else
  bad '/ini rejects a lying broken receipt'
fi

before=$(cat "$t/calls")
SEED_HOME=$t/state /bin/sh "$SEED" --probe > "$t/probe.out"
after=$(cat "$t/calls")
if [ "$before" = "$after" ] \
  && grep -q '^seed.identity=seed$' "$t/probe.out" \
  && ! grep -q 'fake-key' "$t/probe.out"; then
  ok '--probe is offline, stable, and secret-free'
else
  bad '--probe is offline, stable, and secret-free'
fi

awk '
  /^tools_json\(\) \{/ { in_tools=1; next }
  in_tools && /^\[$/ { in_json=1 }
  in_json { print }
  in_json && /^\]$/ { exit }
' "$SEED" > "$t/tools.json"
if jq -e 'length == 2
    and ([.[].function.name] | sort) == ["edit", "shell"]' \
    "$t/tools.json" >/dev/null 2>&1; then
  ok 'seed exposes exactly shell and edit API tools'
else
  bad 'seed exposes exactly shell and edit API tools'
fi

# Later SSE deltas often send empty name/id; keep the first non-empty values.
cat > "$t/sse-empty-name.raw" <<'SSE'
data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"shell","arguments":""}}]}}]}
data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"","type":"function","function":{"name":"","arguments":"{\"command\":\"pwd\"}"}}]}}]}
SSE
{
  printf 'need() { command -v "$1" >/dev/null 2>&1 || return 1; }\n'
  awk '/^parse_stream\(\) \{/,/^}$/' "$SEED"
  printf 'parse_stream "$1"\n'
} > "$t/run-parse-stream.sh"
if [ -s "$t/run-parse-stream.sh" ] \
  && /bin/sh "$t/run-parse-stream.sh" "$t/sse-empty-name.raw" \
    > "$t/sse-empty-name.out" \
  && jq -e '.tool_calls | length == 1
      and .[0].id == "call_1"
      and .[0].name == "shell"
      and (.[0].arguments | contains("pwd"))' \
      "$t/sse-empty-name.out" >/dev/null 2>&1; then
  ok 'SSE merge keeps tool name when later chunks send empty name'
else
  bad 'SSE merge keeps tool name when later chunks send empty name'
fi

# A 2xx stream cut before finish_reason must be retried, not parsed into
# an empty final answer. Fake curl: first call truncated, second complete.
mkdir -p "$t/llmtools"
cat > "$t/llmtools/curl" <<'LLMCURL'
#!/bin/sh
n=$(cat "$SEED_TEST_LLM_COUNT" 2>/dev/null || printf 0)
n=$((n + 1))
printf '%s\n' "$n" > "$SEED_TEST_LLM_COUNT"
if [ "$n" -eq 1 ]; then
  printf 'data: {"choices":[{"delta":{"reasoning_content":"thinking"},"finish_reason":null}]}\n'
else
  printf 'data: {"choices":[{"delta":{"content":"recovered"},"finish_reason":null}]}\n'
  printf 'data: {"choices":[{"delta":{},"finish_reason":"stop"}]}\n'
  printf 'data: [DONE]\n'
fi
printf '\n__HTTP__200\n'
LLMCURL
chmod 755 "$t/llmtools/curl"
{
  printf 'need() { command -v "$1" >/dev/null 2>&1 || return 1; }\n'
  printf 'load_env() { :; }\ndisable_thinking() { :; }\n'
  printf 'tools_json() { printf "[]\\n"; }\n'
  printf 'llm_context_overflow() { return 1; }\n'
  printf 'HTTP_TIMEOUT=300\nHTTP_STALL=5\n'
  awk '/^strip_msg_thinking\(\) \{/,/^}$/' "$SEED"
  awk '/^stream_print\(\) \{/,/^}$/' "$SEED"
  awk '/^parse_stream\(\) \{/,/^}$/' "$SEED"
  awk '/^model_turn\(\) \{/,/^}$/' "$SEED"
  printf 'model_turn "$1" "$2"\n'
} > "$t/run-model-turn.sh"
printf '[{"role":"user","content":"hi"}]\n' > "$t/mt-msgs.json"
printf '0\n' > "$t/llm-calls"
set +e
env PATH="$t/llmtools:$PATH" SEED_LLM_STUB= SEED_STREAM=1 \
  SEED_TEST_LLM_COUNT=$t/llm-calls \
  LLM_API_KEY=fake LLM_MODEL=fake LLM_API_URL=http://offline/v1 \
  /bin/sh "$t/run-model-turn.sh" "$t/mt-msgs.json" "$t/mt-turn.json" \
  2> "$t/mt.err"
mt_status=$?
set -e
if [ "$mt_status" -eq 0 ] \
  && grep -q 'truncated stream, retry' "$t/mt.err" \
  && [ "$(cat "$t/llm-calls")" = 2 ] \
  && jq -e '.content == "recovered"' "$t/mt-turn.json" >/dev/null 2>&1; then
  ok 'truncated stream is retried, not accepted as an empty turn'
else
  bad 'truncated stream is retried, not accepted as an empty turn'
fi

# The loop must ask again once when a turn has blank content and no
# tool_calls, then accept the second reply as final.
export SEED_HOME=$t/state
unset SEED_TEST_LIE
export SEED_TEST_EMPTY_FLAG=$t/empty-flag
rm -f "$SEED_TEST_EMPTY_FLAG"
(cd "$work" && /bin/sh "$SEED" --oneshot 'empty turn probe') \
  > "$t/empty.out" 2> "$t/empty.err"
if grep -q 'second answer' "$t/empty.out" \
  && grep -q 'llm: empty turn, retry' "$t/empty.err"; then
  ok 'blank final turn is retried once before being accepted'
else
  bad 'blank final turn is retried once before being accepted'
fi

[ "$fail" -eq 0 ] || exit 1
printf 'all seed package tests passed\n'
