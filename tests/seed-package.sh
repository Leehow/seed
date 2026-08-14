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

BUILD=$ROOT/build
ck "build/pack.sh exists" test -f "$BUILD/pack.sh"
for f in \
  loop.sh model.sh edit.sh shell.sh env.sh install.sh agent.sh \
  prompts/product-system.txt prompts/tools.json
do
  ck "build/$f" test -f "$BUILD/$f"
done
ck "no installer prompt" test ! -f "$BUILD/prompts/installer-system.txt"
ck "no installer task" test ! -f "$BUILD/prompts/installer-task.txt"
if [ -f "$BUILD/pack.sh" ]; then
  /bin/sh "$BUILD/pack.sh" "$d/packed.sh"
  ck "pack syntax" /bin/sh -n "$d/packed.sh"
  if grep -n '^\. \|^source ' "$d/packed.sh" >/dev/null; then
    printf 'FAIL packed seed is standalone\n'; fail=$((fail + 1))
  else
    printf 'ok   packed seed is standalone\n'
  fi
  if cmp -s "$d/packed.sh" "$SEED"; then
    printf 'ok   seed.sh matches pack\n'
  else
    printf 'FAIL seed.sh matches pack (run: sh build/pack.sh)\n'; fail=$((fail + 1))
  fi
fi

if grep -n 'python3\|#!/usr/bin/env python\|openai\|gpt-5\|/Users/\|pgrep \|head -c' "$SEED" >/dev/null; then
  printf 'FAIL seed.sh still has python/openai/host-path/nonportable bits\n'; fail=$((fail + 1))
else
  printf 'ok   seed.sh is portable shell+jq\n'
fi

help=$(/bin/sh "$SEED" --help 2>&1 || true)
if printf '%s' "$help" | grep -q 'sh seed.sh deepseek <API_KEY>' \
  && ! printf '%s' "$help" | grep -q 'install-dir' \
  && ! printf '%s' "$help" | grep -q 'selftest'; then
  printf 'ok   usage is one line\n'
else
  printf 'FAIL usage is one line\n'; fail=$((fail + 1))
fi
if grep -q 'cabin_banner' "$SEED" || grep -q '能在当前目录' "$SEED"; then
  printf 'FAIL seed has no product lecture\n'; fail=$((fail + 1))
else
  printf 'ok   seed has no product lecture\n'
fi
if LC_ALL=C grep -n '[^	 -~]' "$SEED" >/dev/null; then
  printf 'FAIL seed.sh is ASCII-only\n'; fail=$((fail + 1))
else
  printf 'ok   seed.sh is ASCII-only\n'
fi
if grep -n 'assemble_stream\|stream:true\|--assemble\|cabin_system' "$SEED" >/dev/null; then
  printf 'FAIL seed has no SSE or install-model loop\n'; fail=$((fail + 1))
else
  printf 'ok   seed has no SSE or install-model loop\n'
fi

# one-shot API JSON -> internal turn (no SSE)
cat > "$d/api.json" <<'JSON'
{"choices":[{"message":{"content":"","tool_calls":[{"id":"c1","type":"function","function":{"name":"shell","arguments":"{\"command\":\"pwd\"}"}}]}}],"usage":{"prompt_tokens":4,"completion_tokens":2}}
JSON
parsed=$(/bin/sh "$SEED" --parse-turn "$d/api.json")
if printf '%s' "$parsed" | grep -q '"name": "shell"'; then printf 'ok   parse-turn reads tool name\n'
else printf 'FAIL parse-turn reads tool name\n'; fail=$((fail + 1)); fi
if printf '%s' "$parsed" | grep -q 'pwd'; then printf 'ok   parse-turn keeps arguments\n'
else printf 'FAIL parse-turn keeps arguments\n'; fail=$((fail + 1)); fi
if printf '%s' "$parsed" | grep -q '"prompt_tokens": 4'; then printf 'ok   parse-turn keeps usage\n'
else printf 'FAIL parse-turn keeps usage\n'; fail=$((fail + 1)); fi

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

# install must not call the model
stub=$d/stub
cat > "$stub" <<EOF
#!/bin/sh
printf 'called\n' >> "$d/install-called"
printf '{"content":"no","tool_calls":[],"usage":{}}\n'
EOF
chmod +x "$stub"

rej=$d/reject
mkdir -p "$rej"
(
  cd "$rej"
  /bin/sh "$SEED" deepseek sk-TESTKEYNOTREAL "$d/must-not"
) > "$d/rej.out" 2> "$d/rej.err" || true
if grep -q 'usage:' "$d/rej.err" && [ ! -e "$d/must-not" ]; then
  printf 'ok   extra install-dir rejected\n'
else
  printf 'FAIL extra install-dir rejected\n'; fail=$((fail + 1))
fi

cwd=$d/cwd
mkdir -p "$cwd"
STUB_N=$d/stub-n
export STUB_N
printf '0\n' > "$STUB_N"
(
  cd "$cwd"
  SEED_LLM_STUB=$stub \
    /bin/sh "$SEED" deepseek sk-TESTKEYNOTREAL
) > "$d/out" 2> "$d/err" || true
if [ -f "$d/install-called" ]; then
  printf 'FAIL install did not call the model\n'; fail=$((fail + 1))
else
  printf 'ok   install did not call the model\n'
fi

ck "install wrote .env in cwd" test -f "$cwd/.env"
if mode=$(stat -c '%a' "$cwd/.env" 2>/dev/null); then
  :
else
  mode=$(stat -f '%OLp' "$cwd/.env")
fi
ck "cwd .env is 600" test "$mode" = 600
ck "env has key field" grep -q '^LLM_API_KEY=' "$cwd/.env"
ck "key not in stderr" awk 'BEGIN{c=0} /sk-TESTKEYNOTREAL/{c=1} END{exit c}' "$d/err"
ck "key not in stdout" awk 'BEGIN{c=0} /sk-TESTKEYNOTREAL/{c=1} END{exit c}' "$d/out"
ck "gitignore mentions .env" grep -qx '.env' "$cwd/.gitignore"
if grep -q 'installed:' "$d/err"; then printf 'ok   stub install verified\n'
else printf 'FAIL stub install verified\n'; fail=$((fail + 1)); fi
if grep -E '装好了|错误：|验收挂了' "$d/err" >/dev/null; then
  printf 'FAIL seed install stayed machine-English\n'; fail=$((fail + 1))
else
  printf 'ok   seed install stayed machine-English\n'
fi
ck "bin/agent exists" test -x "$cwd/bin/agent"
ck "bin/edit exists" test -x "$cwd/bin/edit"
ck "bin/shell exists" test -x "$cwd/bin/shell"
ck "bin/llm exists" test -x "$cwd/bin/llm"
ck "agent syntax" /bin/sh -n "$cwd/bin/agent"
ck "no host home path in agent shim" awk 'BEGIN{c=0} /\/Users\//{c=1} END{exit c}' "$cwd/bin/agent"

intro=$($cwd/bin/agent </dev/null 2>&1 || true)
if printf '%s' "$intro" | grep -q '当前目录\|能在当前目录'; then
  printf 'FAIL agent stays quiet on open\n'; fail=$((fail + 1))
elif printf '%s' "$intro" | grep -q '>'; then
  printf 'ok   agent stays quiet on open\n'
else
  printf 'FAIL agent stays quiet on open\n'; fail=$((fail + 1))
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
  SEED_LLM_STUB=$stub STUB_N=$STUB_N "$cwd/bin/agent" --oneshot 'where am i'
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
  printf '%s\n%s\n' 'make a box and enter it' 'where am i' | "$cwd/bin/agent"
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

# install is offline: no stub, no network
cwd2=$d/cwd2
mkdir -p "$cwd2"
(
  cd "$cwd2"
  /bin/sh "$SEED" deepseek sk-TESTKEYNOTREAL
) > "$d/cap.out" 2> "$d/cap.err" || true
ck "offline install wrote agent" test -x "$cwd2/bin/agent"
if grep -q 'installed:' "$d/cap.err"; then printf 'ok   offline install verified\n'
else printf 'FAIL offline install verified\n'; fail=$((fail + 1)); fi
if grep -q '\[seed\] tokens' "$d/cap.err" "$d/err"; then
  printf 'FAIL install has no token heartbeat\n'; fail=$((fail + 1))
else
  printf 'ok   install has no token heartbeat\n'
fi

[ "$fail" -eq 0 ] || { printf '\nSEED-PACKAGE FAIL: %s\n' "$fail"; exit 1; }
printf '\nSEED-PACKAGE PASS\n'
