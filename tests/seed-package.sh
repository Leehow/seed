#!/bin/sh
# Offline contract tests for the three-cabin seed package.
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
SEED=$ROOT/seed.sh
fail=0
ck() {
  n=$1; shift
  if "$@" >/dev/null 2>&1; then printf 'ok   %s\n' "$n"
  else printf 'FAIL %s\n' "$n"; fail=$((fail + 1)); fi
}

d=$(mktemp -d "${TMPDIR:-/tmp}/seed-pkg.XXXXXX")
trap 'rm -rf "$d"' EXIT

if grep -n 'python3\|#!/usr/bin/env python' "$SEED" >/dev/null; then
  printf 'FAIL seed.sh must not call python\n'; fail=$((fail + 1))
else
  printf 'ok   seed.sh is shell+jq, no python\n'
fi

# SSE assembler must read a file (heredoc must not steal the stream)
cat > "$d/sse.txt" <<'SSE'
data: {"choices":[{"delta":{"content":"po"}}],"usage":null}

data: {"choices":[{"delta":{"content":"ng"}}],"usage":{"prompt_tokens":9,"completion_tokens":2}}

data: [DONE]
SSE
assembled=$(/bin/sh "$SEED" --assemble "$d/sse.txt")
if printf '%s' "$assembled" | grep -q '"content": "pong"'; then printf 'ok   assemble reads SSE file\n'
else printf 'FAIL assemble reads SSE file\n'; fail=$((fail + 1)); fi
if printf '%s' "$assembled" | grep -q '"prompt_tokens": 9'; then printf 'ok   assemble keeps usage\n'
else printf 'FAIL assemble keeps usage\n'; fail=$((fail + 1)); fi

cat > "$d/sse-tools.txt" <<'SSE'
data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"sh","arguments":""}}]}}]}

data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\"command\":\"pwd\"}"}}]}}],"usage":{"prompt_tokens":4,"completion_tokens":2}}

data: [DONE]
SSE
assembled=$(/bin/sh "$SEED" --assemble "$d/sse-tools.txt")
if printf '%s' "$assembled" | grep -q '"name": "sh"'; then printf 'ok   assemble merges tool_calls\n'
else printf 'FAIL assemble merges tool_calls\n'; fail=$((fail + 1)); fi
if printf '%s' "$assembled" | grep -q 'pwd'; then printf 'ok   assemble keeps tool arguments\n'
else printf 'FAIL assemble keeps tool arguments\n'; fail=$((fail + 1)); fi

# --edit: unique replace
printf 'line one\nline two\nline three\n' > "$d/f.txt"
ck "edit unique replace" /bin/sh "$SEED" --edit "$d/f.txt" "line two" "line two changed"
ck "edit wrote the new text" grep -qx "line two changed" "$d/f.txt"
ck "edit left neighbors" grep -qx "line one" "$d/f.txt"
printf 'aa\naa\n' > "$d/dup.txt"
if /bin/sh "$SEED" --edit "$d/dup.txt" "aa" "bb" >/dev/null 2>&1; then
  printf 'FAIL edit rejected non-unique\n'; fail=$((fail + 1))
else
  printf 'ok   edit rejected non-unique\n'
fi
ck "edit did not change non-unique file" grep -qx "aa" "$d/dup.txt"

# persistent shell
sess=$d/sess
ck "shell-init" /bin/sh "$SEED" --shell-init "$sess" "$d"
ck "shell first command" /bin/sh "$SEED" --shell "$sess" "mkdir sub && cd sub && pwd"
cwd1=$(/bin/sh "$SEED" --shell "$sess" "pwd" | sed -n 's/^--- cwd: //p')
expect=$(CDPATH= cd "$d/sub" && pwd -P)
got=$(CDPATH= cd "$cwd1" && pwd -P)
ck "shell cwd persisted" test "$got" = "$expect"
/bin/sh "$SEED" --shell-stop "$sess" >/dev/null 2>&1 || :

# timeout must return and leave the session usable (no $(tee) deadlock)
sess2=$d/sess2
ck "shell-init for timeout" /bin/sh "$SEED" --shell-init "$sess2" "$d"
to_out=$(SEED_ACTION_TIMEOUT=1 /bin/sh "$SEED" --shell "$sess2" "sleep 30")
if printf '%s' "$to_out" | grep -q 'exit: 124'; then printf 'ok   shell command timeout\n'
else printf 'FAIL shell command timeout\n'; fail=$((fail + 1)); fi
after=$(SEED_ACTION_TIMEOUT=5 /bin/sh "$SEED" --shell "$sess2" "printf ready\n")
if printf '%s' "$after" | grep -q ready; then printf 'ok   shell works after timeout\n'
else printf 'FAIL shell works after timeout\n'; fail=$((fail + 1)); fi
/bin/sh "$SEED" --shell-stop "$sess2" >/dev/null 2>&1 || :

# install with a stub model (no network)
stub=$d/stub
cat > "$stub" <<'EOF'
#!/bin/sh
n=$(cat "${STUB_N:-/tmp/stub-n}" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s\n' "$n" > "${STUB_N:-/tmp/stub-n}"
printf '{"content":"installed","tool_calls":[],"usage":{"prompt_tokens":3,"completion_tokens":1}}\n'
EOF
chmod +x "$stub"

cwd=$d/cwd
mkdir -p "$cwd"
inst=$d/inst
STUB_N=$d/stub-n
export STUB_N
printf '0\n' > "$STUB_N"
(
  cd "$cwd"
  SEED_LLM_STUB=$stub SEED_SKIP_ACCEPT_FAKE=0 \
    /bin/sh "$SEED" deepseek sk-TESTKEYNOTREAL "$inst"
) > "$d/out" 2> "$d/err" || true

ck "install wrote cwd .env" test -f "$cwd/.env"
ck "install wrote install .env" test -f "$inst/.env"
mode=$(stat -f '%OLp' "$cwd/.env" 2>/dev/null || stat -c '%a' "$cwd/.env")
ck "cwd .env is 600" test "$mode" = 600
ck "env has key field" grep -q '^LLM_API_KEY=' "$cwd/.env"
ck "key not in stderr" awk 'BEGIN{c=0} /sk-TESTKEYNOTREAL/{c=1} END{exit c}' "$d/err"
ck "key not in stdout" awk 'BEGIN{c=0} /sk-TESTKEYNOTREAL/{c=1} END{exit c}' "$d/out"
ck "gitignore mentions .env" grep -qx '.env' "$cwd/.gitignore"
if grep -q '装好了' "$d/err"; then printf 'ok   stub install verified\n'
else printf 'FAIL stub install verified\n'; fail=$((fail + 1)); fi
ck "bin/agent exists" test -x "$inst/bin/agent"
ck "bin/edit exists" test -x "$inst/bin/edit"
ck "bin/shell exists" test -x "$inst/bin/shell"
ck "bin/llm exists" test -x "$inst/bin/llm"
ck "agent syntax" /bin/sh -n "$inst/bin/agent"
ck "no host home path in agent shim" awk 'BEGIN{c=0} /\/Users\//{c=1} END{exit c}' "$inst/bin/agent"

intro=$($inst/bin/agent </dev/null 2>&1 || true)
if printf '%s' "$intro" | grep -q '当前目录'; then
  printf 'ok   agent prints Chinese banner\n'
else
  printf 'FAIL agent prints Chinese banner\n'; fail=$((fail + 1))
fi
ck "agent exits on EOF" true

# oneshot + fake tool call must run in a dir outside install
cat > "$stub" <<'EOF'
#!/bin/sh
n=$(cat "${STUB_N}" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s\n' "$n" > "${STUB_N}"
if [ "$n" -eq 1 ]; then
  printf '{"content":"","tool_calls":[{"id":"c1","name":"shell","arguments":"{\\"command\\":\\"pwd\\"}"}],"usage":{"prompt_tokens":4,"completion_tokens":2}}\n'
else
  printf '{"content":"done","tool_calls":[],"usage":{"prompt_tokens":5,"completion_tokens":1}}\n'
fi
EOF
printf '0\n' > "$STUB_N"
work=$d/work
mkdir -p "$work"
(
  cd "$work"
  SEED_LLM_STUB=$stub STUB_N=$STUB_N "$inst/bin/agent" --oneshot 'where am i'
) > "$d/one.out" 2> "$d/one.err" || true
if grep -q 'done' "$d/one.out"; then printf 'ok   oneshot final answer only-ish\n'
else printf 'FAIL oneshot final answer only-ish\n'; fail=$((fail + 1)); fi
if awk 'BEGIN{c=0} /tool_calls/{c=1} END{exit c}' "$d/one.out"; then
  printf 'ok   oneshot did not dump JSON tool_calls\n'
else
  printf 'FAIL oneshot did not dump JSON tool_calls\n'; fail=$((fail + 1))
fi
if grep -q '\[seed\] tokens' "$d/one.err" "$d/one.out"; then
  printf 'FAIL oneshot hid token heartbeat\n'; fail=$((fail + 1))
else
  printf 'ok   oneshot hid token heartbeat\n'
fi

# interactive window: two human lines, same persistent shell
cat > "$stub" <<'EOF'
#!/bin/sh
n=$(cat "${STUB_N}" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s\n' "$n" > "${STUB_N}"
case $n in
  1) printf '{"content":"","tool_calls":[{"id":"r1","name":"shell","arguments":"{\\"command\\":\\"mkdir box && cd box && pwd\\"}"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}\n' ;;
  2) printf '{"content":"made-box","tool_calls":[],"usage":{"prompt_tokens":1,"completion_tokens":1}}\n' ;;
  3) printf '{"content":"","tool_calls":[{"id":"r2","name":"shell","arguments":"{\\"command\\":\\"pwd\\"}"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}\n' ;;
  4) printf '{"content":"still-in-box","tool_calls":[],"usage":{"prompt_tokens":1,"completion_tokens":1}}\n' ;;
  *) printf '{"content":"extra","tool_calls":[],"usage":{"prompt_tokens":1,"completion_tokens":1}}\n' ;;
esac
EOF
printf '0\n' > "$STUB_N"
repl=$d/repl
mkdir -p "$repl"
(
  cd "$repl"
  export SEED_LLM_STUB=$stub STUB_N=$STUB_N
  printf '%s\n%s\n' 'make a box and enter it' 'where am i' | "$inst/bin/agent"
) > "$d/repl.out" 2> "$d/repl.err" || true
if grep -q 'made-box' "$d/repl.out" && grep -q 'still-in-box' "$d/repl.out"; then
  printf 'ok   interactive two turns\n'
else
  printf 'FAIL interactive two turns\n'; fail=$((fail + 1))
fi
if grep -q '>' "$d/repl.err"; then printf 'ok   interactive shows prompt\n'
else printf 'FAIL interactive shows prompt\n'; fail=$((fail + 1)); fi
if grep -R '/box$' "$repl/.agent-runs" >/dev/null 2>&1; then
  printf 'ok   interactive shell persisted cd\n'
else
  printf 'FAIL interactive shell persisted cd\n'; fail=$((fail + 1))
fi

# model that never stops still passes if shims are already on disk
cat > "$stub" <<'EOF'
#!/bin/sh
printf '{"content":"","tool_calls":[{"id":"loop","name":"shell","arguments":"{\\"command\\":\\"pwd\\"}"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}\n'
EOF
printf '0\n' > "$STUB_N"
cwd2=$d/cwd2
mkdir -p "$cwd2"
inst2=$d/inst2
(
  cd "$cwd2"
  SEED_LLM_STUB=$stub SEED_MAX_ROUNDS=2 \
    /bin/sh "$SEED" deepseek sk-TESTKEYNOTREAL "$inst2"
) > "$d/cap.out" 2> "$d/cap.err" || true
ck "max-rounds still wrote agent" test -x "$inst2/bin/agent"
if grep -q '装好了' "$d/cap.err"; then printf 'ok   max-rounds still verifies\n'
else printf 'FAIL max-rounds still verifies\n'; fail=$((fail + 1)); fi

[ "$fail" -eq 0 ] || { printf '\nSEED-PACKAGE FAIL: %s\n' "$fail"; exit 1; }
printf '\nSEED-PACKAGE PASS\n'
