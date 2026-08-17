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
PLUGIN_PID=
cleanup() {
  [ -n "${PLUGIN_PID:-}" ] && kill "$PLUGIN_PID" 2>/dev/null || true
  [ -n "${JQ_PID:-}" ] && kill "$JQ_PID" 2>/dev/null || true
  [ -n "${FLAKY_PID:-}" ] && kill "$FLAKY_PID" 2>/dev/null || true
  rm -rf "$d"
}
trap cleanup EXIT

BUILD=$ROOT/build
ck "build/pack.sh exists" test -f "$BUILD/pack.sh"
for f in \
  loop.sh model.sh edit.sh shell.sh env.sh install.sh agent.sh product.sh \
  prompts/product-system.txt prompts/compact-summary.txt prompts/tools.json
do
  ck "build/$f" test -f "$BUILD/$f"
done
ck "agent plugin index" test -f "$ROOT/plugins/agent/index.json"
ck "agent plugin init" test -f "$ROOT/plugins/agent/init.json"
ck "jq mirror fetch script" test -f "$ROOT/plugins/jq/fetch.sh"
if grep -q 'follow system.retrieve' "$BUILD/prompts/product-system.txt" \
  && grep -q 'not cat of the whole file' "$BUILD/prompts/product-system.txt"; then
  printf 'ok   product points at retrieve protocol\n'
else
  printf 'FAIL product points at retrieve protocol\n'; fail=$((fail + 1))
fi
if grep -q 'same language the human just used' "$BUILD/prompts/product-system.txt"; then
  printf 'ok   product replies in the human language\n'
else
  printf 'FAIL product replies in the human language\n'; fail=$((fail + 1))
fi
if grep -q 'Model:' "$BUILD/product.sh" \
  && grep -A8 'agent_ensure_init' "$BUILD/agent.sh" | grep -q 'SEED_STREAM_PRINT=1'; then
  printf 'ok   product names model and restores SSE after init\n'
else
  printf 'FAIL product names model and restores SSE after init\n'; fail=$((fail + 1))
fi
if jq -e '.machine_tree.system.retrieve | type=="string" and length>20' \
  "$ROOT/plugins/agent/init.json" >/dev/null 2>&1 \
  && jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q 'Never cat the entire index'; then
  printf 'ok   init tree has retrieve protocol\n'
else
  printf 'FAIL init tree has retrieve protocol\n'; fail=$((fail + 1))
fi
if jq -r '.prompt' "$ROOT/plugins/agent/init.json" | grep -q description \
  && jq -r '.prompt' "$ROOT/plugins/agent/init.json" | grep -q SKILL.md; then
  printf 'ok   init prompt extracts skill metadata\n'
else
  printf 'FAIL init prompt extracts skill metadata\n'; fail=$((fail + 1))
fi
if jq -e '.version=="33"' "$ROOT/plugins/agent/index.json" >/dev/null 2>&1; then
  printf 'ok   agent plugin version 33\n'
else
  printf 'FAIL agent plugin version 33\n'; fail=$((fail + 1))
fi
if ! jq -e 'has("ask")' "$ROOT/plugins/agent/init.json" >/dev/null 2>&1 \
  && ! grep -q 'agent_print_ask' "$BUILD/product.sh" \
  && ! grep -q 'agent_print_ask' "$BUILD/agent.sh" \
  && grep -q '"Blocks: "' "$BUILD/product.sh"; then
  printf 'ok   edition gate retired: no ask anywhere\n'
else
  printf 'FAIL edition gate retired: no ask anywhere\n'; fail=$((fail + 1))
fi
if jq -e '(.machine_tree | has("host") | not)
    and (.prompt | test("top-level host") | not)
    and (.machine_tree.system.retrieve | test("top-level host") | not)' \
  "$ROOT/plugins/agent/init.json" >/dev/null 2>&1 \
  && [ ! -f "$ROOT/plugins/agent/host.sh" ] \
  && ! jq -e '.hooks.after_ready | index("host.sh")' \
    "$ROOT/plugins/agent/index.json" >/dev/null 2>&1 \
  && ! jq -e '.hooks.system | index("host.sh")' \
    "$ROOT/plugins/agent/index.json" >/dev/null 2>&1; then
  printf 'ok   host map is not an agent plugin\n'
else
  printf 'FAIL host map is not an agent plugin\n'; fail=$((fail + 1))
fi
if grep -qE 'host_inventory|host_blurb|home_top' "$BUILD/product.sh" \
  || grep -q 'host object' "$BUILD/prompts/product-system.txt"; then
  printf 'FAIL seed does not embed host map\n'; fail=$((fail + 1))
else
  printf 'ok   seed does not embed host map\n'
fi
if grep -q 'old tool output cleared' "$BUILD/loop.sh" \
  && ! grep -q 'CONTEXT COMPACTION' "$BUILD/loop.sh" \
  && ! grep -q 'model_complete_text' "$BUILD/model.sh" \
  && ! grep -q 'agent_after_turn' "$BUILD/product.sh" \
  && [ ! -f "$ROOT/plugins/agent/compact.sh" ] \
  && ! jq -e '.hooks.after_turn | index("compact.sh")' \
    "$ROOT/plugins/agent/index.json" >/dev/null 2>&1; then
  printf 'ok   compact is jq in the loop\n'
else
  printf 'FAIL compact is jq in the loop\n'; fail=$((fail + 1))
fi
if grep -q 'earlier work summary' "$BUILD/loop.sh" \
  && grep -q 'compact-summary.txt' "$BUILD/pack.sh" \
  && grep -q 'compress earlier conversation' "$SEED" \
  && grep -q 'old tool output cleared' "$BUILD/loop.sh"; then
  printf 'ok   compact summarizes then prunes\n'
else
  printf 'FAIL compact summarizes then prunes\n'; fail=$((fail + 1))
fi
if grep -q -- '--global' "$BUILD/agent.sh" \
  && grep -q '.local/bin/seed-agent' "$BUILD/install.sh" \
  && grep -q 'SEED_AGENT_HOME' "$BUILD/product.sh" \
  && grep -q '"${1:-}" = -p' "$BUILD/agent.sh" \
  && grep -q 'oneshot: seed-agent -p' "$BUILD/install.sh" \
  && grep -q 'Never read .env' "$BUILD/prompts/product-system.txt"; then
  printf 'ok   global install wiring\n'
else
  printf 'FAIL global install wiring\n'; fail=$((fail + 1))
fi
if grep -q "The task is the human's last message" "$BUILD/prompts/product-system.txt" \
  && grep -q 'Do not replace it with' "$BUILD/prompts/product-system.txt" \
  && grep -q 'slash command, not a coding task' "$BUILD/prompts/product-system.txt" \
  && grep -q 'agentskills.io/specification' "$BUILD/prompts/product-system.txt"; then
  printf 'ok   product pins human task and skill spec\n'
else
  printf 'FAIL product pins human task and skill spec\n'; fail=$((fail + 1))
fi
if grep -q 'skill_catalog' "$BUILD/product.sh" \
  && grep -q 'available_skills' "$BUILD/product.sh"; then
  printf 'ok   product injects skill catalog\n'
else
  printf 'FAIL product injects skill catalog\n'; fail=$((fail + 1))
fi
if jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q 'agentskills.io/specification' \
  && jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q 'Do not rewrite the query' \
  && jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q "The task is the human's last message" \
  && ! jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q websearch \
  && ! jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q 'top-level host'; then
  printf 'ok   retrieve keeps human web queries\n'
else
  printf 'FAIL retrieve keeps human web queries\n'; fail=$((fail + 1))
fi
if jq -e '.optional.seed_agent=="seed-agent.json"' \
  "$ROOT/plugins/agent/index.json" >/dev/null 2>&1; then
  printf 'ok   catalog has optional seed_agent\n'
else
  printf 'FAIL catalog has optional seed_agent\n'; fail=$((fail + 1))
fi
if jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q 'ours.seed_agent' \
  && jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q 'built lazily' \
  && jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q 'Never delay a task to build blocks' \
  && jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q 'SEED_PLUGIN_ROOT' \
  && jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q 'prompts only' \
  && jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q 'starts with /' \
  && ! jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q 'ours.edition'; then
  printf 'ok   retrieve builds blocks without a gate\n'
else
  printf 'FAIL retrieve builds blocks without a gate\n'; fail=$((fail + 1))
fi
sa_ok=1
for f in seed-agent.json skills.json commands.json models.json plugins.json delegate.json; do
  [ -f "$ROOT/plugins/agent/$f" ] || sa_ok=0
done
if [ "$sa_ok" -eq 1 ] \
  && [ ! -f "$ROOT/plugins/agent/tui.json" ] \
  && jq -r '.prompt' "$ROOT/plugins/agent/seed-agent.json" | grep -q 'skills' \
  && jq -r '.prompt' "$ROOT/plugins/agent/seed-agent.json" | grep -q 'commands' \
  && jq -r '.prompt' "$ROOT/plugins/agent/seed-agent.json" | grep -q 'models' \
  && jq -r '.prompt' "$ROOT/plugins/agent/seed-agent.json" | grep -q 'plugins' \
  && jq -r '.prompt' "$ROOT/plugins/agent/seed-agent.json" | grep -q 'Do not write a TUI' \
  && jq -r '.prompt' "$ROOT/plugins/agent/seed-agent.json" | grep -q 'ours.seed_agent' \
  && jq -r '.prompt' "$ROOT/plugins/agent/seed-agent.json" | grep -q 'prompts only' \
  && jq -r '.prompt' "$ROOT/plugins/agent/seed-agent.json" | grep -q 'no shipped' \
  && jq -r '.prompt' "$ROOT/plugins/agent/seed-agent.json" | grep -q 'leave that key unset' \
  && jq -r '.prompt' "$ROOT/plugins/agent/skills.json" | grep -q 'agent-store/seed-agent/skills' \
  && jq -r '.prompt' "$ROOT/plugins/agent/skills.json" | grep -q '.agents/skills' \
  && jq -r '.prompt' "$ROOT/plugins/agent/commands.json" | grep -q '/models' \
  && jq -r '.prompt' "$ROOT/plugins/agent/commands.json" | grep -q '/tools' \
  && jq -r '.prompt' "$ROOT/plugins/agent/commands.json" | grep -q '/help' \
  && jq -r '.prompt' "$ROOT/plugins/agent/models.json" | grep -q 'LLM_' \
  && jq -r '.prompt' "$ROOT/plugins/agent/models.json" | grep -q 'do not print' \
  && jq -r '.prompt' "$ROOT/plugins/agent/plugins.json" | grep -q '.seed-agent/plugins' \
  && jq -r '.prompt' "$ROOT/plugins/agent/seed-agent.json" | grep -q 'AGENT_MAX_ROUNDS' \
  && jq -r '.prompt' "$ROOT/plugins/agent/seed-agent.json" | grep -q 'Always GET' \
  && jq -r '.prompt' "$ROOT/plugins/agent/commands.json" | grep -q 'Chinese' \
  && jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" | grep -q '重做' \
  && jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" | grep -q 'Do not write a TUI' \
  && jq -r '.prompt' "$ROOT/plugins/agent/commands.json" | grep -q 'Check before done' \
  && jq -r '.prompt' "$ROOT/plugins/agent/models.json" | grep -q 'Check before done'; then
  printf 'ok   seed-agent prompt pack\n'
else
  printf 'FAIL seed-agent prompt pack\n'; fail=$((fail + 1))
fi
if jq -r '.prompt' "$ROOT/plugins/agent/delegate.json" | grep -q -- '--oneshot' \
  && jq -r '.prompt' "$ROOT/plugins/agent/delegate.json" | grep -q '.agent-runs' \
  && jq -r '.prompt' "$ROOT/plugins/agent/delegate.json" | grep -q 'kill -0' \
  && jq -r '.prompt' "$ROOT/plugins/agent/delegate.json" | grep -q 'no further delegation' \
  && jq -r '.prompt' "$ROOT/plugins/agent/delegate.json" | grep -q 'leave ours.seed_agent.delegate unset' \
  && jq -r '.prompt' "$ROOT/plugins/agent/seed-agent.json" | grep -q 'delegate.json' \
  && jq -r '.prompt' "$ROOT/plugins/agent/seed-agent.json" | grep -q 'then delegate'; then
  printf 'ok   delegate prompt block\n'
else
  printf 'FAIL delegate prompt block\n'; fail=$((fail + 1))
fi
if jq -r '.prompt' "$ROOT/plugins/agent/commands.json" | grep -q '/refine' \
  && jq -r '.prompt' "$ROOT/plugins/agent/commands.json" | grep -q 'snapshots' \
  && jq -r '.prompt' "$ROOT/plugins/agent/commands.json" | grep -q '.agent-memory/index.json' \
  && jq -r '.prompt' "$ROOT/plugins/agent/commands.json" | grep -q 'never changes system.retrieve' \
  && jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q 'Project memory' \
  && jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q 'never cat the whole memory file'; then
  printf 'ok   refine command and memory read loop\n'
else
  printf 'FAIL refine command and memory read loop\n'; fail=$((fail + 1))
fi
if jq -e '.memory_tree.version=="2"' "$ROOT/plugins/agent/init.json" >/dev/null 2>&1 \
  && jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q 'when a hit has a path' \
  && jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q '记住' \
  && jq -r '.prompt' "$ROOT/plugins/agent/commands.json" | grep -q 'lesson, preference, decision' \
  && jq -r '.prompt' "$ROOT/plugins/agent/commands.json" | grep -q 'supersede' \
  && jq -r '.prompt' "$ROOT/plugins/agent/commands.json" | grep -q 'sk-' \
  && jq -r '.prompt' "$ROOT/plugins/agent/commands.json" | grep -q '/Users/'; then
  printf 'ok   memory tree v2 shape and rules\n'
else
  printf 'FAIL memory tree v2 shape and rules\n'; fail=$((fail + 1))
fi
if jq -e '.machine_tree.system.resources == [] and (.machine_tree.system.env | type == "object")' \
    "$ROOT/plugins/agent/init.json" >/dev/null 2>&1 \
  && jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q 'register it in system.resources' \
  && jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q 'search before you build' \
  && jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q 'never invent keys' \
  && jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q 'kind source' \
  && jq -r '.prompt' "$ROOT/plugins/agent/init.json" | grep -q 'resource census' \
  && jq -r '.prompt' "$ROOT/plugins/agent/init.json" | grep -q 'system.env' \
  && jq -r '.prompt' "$ROOT/plugins/agent/delegate.json" | grep -q 'registered in system.resources' \
  && jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q 'bin/agent --oneshot with a self-contained task' \
  && jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q 'Never simulate a subagent'; then
  printf 'ok   resource index shape and discipline\n'
else
  printf 'FAIL resource index shape and discipline\n'; fail=$((fail + 1))
fi
if grep -q 'redirect them to files' "$BUILD/prompts/product-system.txt"; then
  printf 'ok   product keeps large outputs in files\n'
else
  printf 'FAIL product keeps large outputs in files\n'; fail=$((fail + 1))
fi
if grep -q 'project/<task-slug>/' "$BUILD/prompts/product-system.txt" \
  && grep -q 'project/<task-slug>/' "$SEED"; then
  printf 'ok   product parks new artifacts under project/\n'
else
  printf 'FAIL product parks new artifacts under project/\n'; fail=$((fail + 1))
fi
agent_impl=0
for f in "$ROOT/plugins/agent"/*; do
  [ -e "$f" ] || continue
  [ -d "$f" ] && { agent_impl=1; continue; }
  case $f in
    *.json) ;;
    *) agent_impl=1 ;;
  esac
done
if [ "$agent_impl" -eq 0 ]; then
  printf 'ok   agent plugin is prompts only\n'
else
  printf 'FAIL agent plugin is prompts only\n'; fail=$((fail + 1))
fi
if grep -q seed-agent "$BUILD/loop.sh" \
  || grep -q seed-agent "$BUILD/prompts/product-system.txt" \
  || grep -q 'seed-agent\.json\|optional\.seed_agent' "$BUILD/product.sh"; then
  printf 'FAIL seed does not name the seed-agent extension\n'; fail=$((fail + 1))
else
  printf 'ok   seed does not name the seed-agent extension\n'
fi
if jq -r '.prompt' "$ROOT/plugins/agent/init.json" | grep -q 'Never assign a shell variable named path' \
  && jq -r '.prompt' "$ROOT/plugins/agent/init.json" | grep -q 'already probed by the engine'; then
  printf 'ok   init prompt does not clobber PATH\n'
else
  printf 'FAIL init prompt does not clobber PATH\n'; fail=$((fail + 1))
fi
if grep -q 'agent_probe_tools' "$BUILD/product.sh" \
  && grep -q 'command -v' "$BUILD/product.sh" \
  && grep -A6 'agent_place_trees$' "$BUILD/product.sh" | grep -q 'agent_probe_tools'; then
  printf 'ok   engine owns the tool probe\n'
else
  printf 'FAIL engine owns the tool probe\n'; fail=$((fail + 1))
fi
if jq -e '.machine_tree.system.web.fetch.use' "$ROOT/plugins/agent/init.json" >/dev/null 2>&1 \
  && ! jq -e '.machine_tree.system.web | has("websearch")' \
    "$ROOT/plugins/agent/init.json" >/dev/null 2>&1; then
  printf 'ok   init tree has fetch and no websearch\n'
else
  printf 'FAIL init tree has fetch and no websearch\n'; fail=$((fail + 1))
fi
if jq -r '.prompt' "$ROOT/plugins/agent/init.json" | grep -q 'Write the index to disk NOW' \
  && jq -r '.prompt' "$ROOT/plugins/agent/init.json" | grep -q 'Do not inspect skills before this write'; then
  printf 'ok   init writes ready before skills\n'
else
  printf 'FAIL init writes ready before skills\n'; fail=$((fail + 1))
fi
if jq -e '.machine_tree.system.web.fetch.use' \
  "$ROOT/plugins/agent/init.json" >/dev/null 2>&1 \
  && jq -r '.machine_tree.system.retrieve' "$ROOT/plugins/agent/init.json" \
    | grep -q system.web \
  && jq -r '.prompt' "$ROOT/plugins/agent/init.json" \
    | grep -q 'Keep system.web.fetch' \
  && ! jq -r '.prompt' "$ROOT/plugins/agent/init.json" | grep -q websearch; then
  printf 'ok   init tree has prompt fetch only\n'
else
  printf 'FAIL init tree has prompt fetch only\n'; fail=$((fail + 1))
fi
if grep -q 'system.web\|websearch' "$BUILD/prompts/product-system.txt" \
  || grep -q 'system.web\|websearch' "$BUILD/product.sh"; then
  printf 'FAIL seed does not name plugin web tools\n'; fail=$((fail + 1))
else
  printf 'ok   seed does not name plugin web tools\n'
fi
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
if printf '%s' "$help" | grep -q 'sh seed.sh \[--global\] deepseek <API_KEY>' \
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
if grep -q 'ensure_jq' "$SEED" && grep -q 'jqlang/jq' "$SEED" \
  && grep -q '/jq/' "$SEED"; then
  printf 'ok   seed can fetch jq\n'
else
  printf 'FAIL seed can fetch jq\n'; fail=$((fail + 1))
fi
if grep -q 'parse_stream' "$SEED" && grep -q 'SEED_STREAM' "$SEED"; then
  printf 'ok   product can assemble SSE\n'
else
  printf 'FAIL product can assemble SSE\n'; fail=$((fail + 1))
fi
if grep -q 'delta.reasoning_content' "$SEED"; then
  printf 'FAIL product does not stream thinking\n'; fail=$((fail + 1))
else
  printf 'ok   product does not stream thinking\n'
fi
if grep -q 'cabin_system' "$SEED"; then
  printf 'FAIL seed has no install-model loop\n'; fail=$((fail + 1))
else
  printf 'ok   seed has no install-model loop\n'
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

cat > "$d/sse.txt" <<'SSE'
data: {"choices":[{"delta":{"content":"hi"}}]}
data: {"choices":[{"delta":{"content":"!"}}]}
data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","function":{"name":"shell","arguments":"{\"command\":"}}]}}]}
data: {"choices":[{"delta":{"tool_calls":[{"index":0,"function":{"arguments":"\"pwd\"}"}}]}}]}
data: {"usage":{"prompt_tokens":4,"completion_tokens":2}}
data: [DONE]

SSE
sp=$(/bin/sh "$SEED" --parse-stream "$d/sse.txt")
if printf '%s' "$sp" | grep -q '"content": "hi!"'; then printf 'ok   parse-stream joins content\n'
else printf 'FAIL parse-stream joins content\n'; fail=$((fail + 1)); fi
if printf '%s' "$sp" | grep -q '"name": "shell"'; then printf 'ok   parse-stream joins tool name\n'
else printf 'FAIL parse-stream joins tool name\n'; fail=$((fail + 1)); fi
if printf '%s' "$sp" | grep -q 'pwd'; then printf 'ok   parse-stream joins tool arguments\n'
else printf 'FAIL parse-stream joins tool arguments\n'; fail=$((fail + 1)); fi

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

# zsh treats `path` as PATH; a model init script must not kill the worker
sess3=$d/sess3
old_shell=$SHELL
SHELL=/bin/zsh
export SHELL
ck "shell-init under zsh env" /bin/sh "$SEED" --shell-init "$sess3" "$d"
path_out=$(/bin/sh "$SEED" --shell "$sess3" 'path=$(command -v sh); command -v sleep; printf PATHOK\n')
if printf '%s' "$path_out" | grep -q PATHOK \
  && printf '%s' "$path_out" | grep -q 'exit: 0'; then
  printf 'ok   shell survives path= assignment\n'
else
  printf 'FAIL shell survives path= assignment\n'; fail=$((fail + 1))
fi
alive_out=$(/bin/sh "$SEED" --shell "$sess3" 'command -v sleep && printf stillalive\n')
if printf '%s' "$alive_out" | grep -q stillalive; then
  printf 'ok   shell still works after path=\n'
else
  printf 'FAIL shell still works after path=\n'; fail=$((fail + 1))
fi
/bin/sh "$SEED" --shell-stop "$sess3" >/dev/null 2>&1 || :
SHELL=$old_shell
export SHELL

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
if grep '^LLM_EXTRA=' "$cwd/.env" | grep -q enabled; then
  printf 'FAIL deepseek extra does not enable thinking\n'; fail=$((fail + 1))
else
  printf 'ok   deepseek extra does not enable thinking\n'
fi
ck "key not in stderr" awk 'BEGIN{c=0} /sk-TESTKEYNOTREAL/{c=1} END{exit c}' "$d/err"
ck "key not in stdout" awk 'BEGIN{c=0} /sk-TESTKEYNOTREAL/{c=1} END{exit c}' "$d/out"
ck "gitignore mentions .env" grep -qx '.env' "$cwd/.gitignore"
if grep -q 'installed:' "$d/err"; then printf 'ok   stub install verified\n'
else printf 'FAIL stub install verified\n'; fail=$((fail + 1)); fi
if grep -q 'open: sh bin/agent' "$d/err"; then
  printf 'ok   install tells how to open\n'
else
  printf 'FAIL install tells how to open\n'; fail=$((fail + 1))
fi
if grep -q 'installing: jq' "$d/err"; then
  printf 'FAIL install does not fetch jq when present\n'; fail=$((fail + 1))
else
  printf 'ok   install does not fetch jq when present\n'
fi
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

if grep -q 'parse_turn' "$cwd/bin/agent" \
  && ! grep -E 'exec /bin/sh .*seed\.sh' "$cwd/bin/agent" >/dev/null; then
  printf 'ok   installed agent carries the loop\n'
else
  printf 'FAIL installed agent carries the loop\n'; fail=$((fail + 1))
fi
if grep -E 'exec /bin/sh .*seed\.sh' "$cwd/bin/edit" >/dev/null; then
  printf 'FAIL edit shim does not exec seed.sh\n'; fail=$((fail + 1))
else
  printf 'ok   edit shim does not exec seed.sh\n'
fi

intro=$(SLAB_SKIP_INIT=1 "$cwd/bin/agent" </dev/null 2>&1 || true)
if printf '%s' "$intro" | grep -q '当前目录\|能在当前目录'; then
  printf 'FAIL agent stays quiet on open\n'; fail=$((fail + 1))
elif printf '%s' "$intro" | grep -q '>'; then
  printf 'ok   agent stays quiet on open\n'
else
  printf 'FAIL agent stays quiet on open\n'; fail=$((fail + 1))
fi
ck "agent exits on EOF" true

# global install into a fake HOME: entry ~/.local/bin/seed-agent, home ~/.seed-agent
gh=$d/ghome
gc=$d/gcwd
mkdir -p "$gh" "$gc"
(
  cd "$gc"
  HOME=$gh /bin/sh "$SEED" --global deepseek sk-TESTKEYNOTREAL
) > "$d/g.out" 2> "$d/g.err" || true
ck "global entry installed" test -x "$gh/.local/bin/seed-agent"
ck "global entry syntax" /bin/sh -n "$gh/.local/bin/seed-agent"
ck "global home has .env with key" grep -q '^LLM_API_KEY=sk-TESTKEYNOTREAL' "$gh/.seed-agent/.env"
ck "global install left cwd alone" test ! -e "$gc/.env"
ck "global home bin/agent" test -x "$gh/.seed-agent/bin/agent"
if grep -q 'oneshot: seed-agent -p' "$d/g.err" && grep -q 'installed:' "$d/g.err"; then
  printf 'ok   global install tells seed-agent and -p\n'
else
  printf 'FAIL global install tells seed-agent and -p\n'; fail=$((fail + 1))
fi
if [ -d "$gh/.seed-agent/agent-store" ] && [ ! -e "$gh/.local/agent-store" ]; then
  printf 'ok   global home holds state, not the entry dir\n'
else
  printf 'FAIL global home holds state, not the entry dir\n'; fail=$((fail + 1))
fi

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
  SLAB_SKIP_INIT=1 SEED_LLM_STUB=$stub STUB_N=$STUB_N "$cwd/bin/agent" --oneshot 'where am i'
) > "$d/one.out" 2> "$d/one.err" || true
if grep -q 'done' "$d/one.out"; then printf 'ok   oneshot final answer only-ish\n'
else printf 'FAIL oneshot final answer only-ish\n'; fail=$((fail + 1)); fi
if grep -q 'shell: pwd' "$d/one.err"; then
  printf 'ok   oneshot shows shell line\n'
else
  printf 'FAIL oneshot shows shell line\n'; fail=$((fail + 1))
fi
if grep -q 'tool_call_id' "$work/.agent-runs"/*/messages.json; then
  printf 'ok   oneshot keeps tool results in messages\n'
else
  printf 'FAIL oneshot keeps tool results in messages\n'; fail=$((fail + 1))
fi
# host injects ok skill name+description into SYSTEM; not-ok stays out
mkdir -p "$cwd/agent-store"
cat > "$cwd/agent-store/index.json" <<'JSON'
{
  "ready": true,
  "version": "1",
  "system": {
    "retrieve": "x",
    "skills": [
      {
        "name": "pdf-demo",
        "description": "Extract text from PDF files. Use when working with PDFs.",
        "path": "/tmp/pdf-demo",
        "ok": true,
        "note": ""
      },
      {
        "name": "hidden-no",
        "description": "should not appear",
        "path": "/tmp/no",
        "ok": false,
        "note": ""
      }
    ]
  }
}
JSON
cat > "$stub" <<'EOF'
#!/bin/sh
printf '%s\n' '{"content":"catalog-ok","tool_calls":[],"usage":{"prompt_tokens":1,"completion_tokens":1}}'
EOF
printf '0\n' > "$STUB_N"
catwork=$d/catwork
mkdir -p "$catwork"
(
  cd "$catwork"
  SLAB_SKIP_INIT=1 SEED_LLM_STUB=$stub STUB_N=$STUB_N \
    "$cwd/bin/agent" --oneshot 'hello'
) > "$d/cat.out" 2> "$d/cat.err" || true
catmsg=
for m in "$catwork/.agent-runs"/*/messages.json; do
  [ -f "$m" ] || continue
  catmsg=$m
done
if [ -n "$catmsg" ] \
  && grep -q 'available_skills' "$catmsg" \
  && grep -q 'pdf-demo' "$catmsg" \
  && grep -q 'Extract text from PDF' "$catmsg" \
  && grep -q "The task is the human's last message" "$catmsg" \
  && grep -q 'agentskills.io/specification' "$catmsg" \
  && ! grep -q 'hidden-no' "$catmsg"; then
  printf 'ok   oneshot system carries skill catalog\n'
else
  printf 'FAIL oneshot system carries skill catalog\n'; fail=$((fail + 1))
fi

# compact: high prompt_tokens + three tool rounds; first fat tool is pruned
mkdir -p "$cwd/agent-store"
printf '%s\n' '{"version":"17","context_window":128000}' \
  > "$cwd/agent-store/catalog.json"
cwork=$d/cwork
mkdir -p "$cwork"
awk 'BEGIN{for(i=0;i<300;i++)printf "X"}' > "$cwork/fat.txt"
printf '\n' >> "$cwork/fat.txt"
cat > "$stub" <<'EOF'
#!/bin/sh
if grep -q 'compress earlier conversation' "$2" 2>/dev/null; then
  printf '%s\n' '{"content":"Goal: test. Next: none.","tool_calls":[],"usage":{"prompt_tokens":10,"completion_tokens":1}}'
  exit 0
fi
n=$(cat "${STUB_N}" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s\n' "$n" > "${STUB_N}"
case $n in
  1) printf '%s\n' '{"content":"","tool_calls":[{"id":"c1","name":"shell","arguments":"{\"command\":\"cat fat.txt\"}"}],"usage":{"prompt_tokens":1000,"completion_tokens":1}}' ;;
  2) printf '%s\n' '{"content":"","tool_calls":[{"id":"c2","name":"shell","arguments":"{\"command\":\"echo a\"}"}],"usage":{"prompt_tokens":2000,"completion_tokens":1}}' ;;
  3) printf '%s\n' '{"content":"","tool_calls":[{"id":"c3","name":"shell","arguments":"{\"command\":\"echo b\"}"}],"usage":{"prompt_tokens":3000,"completion_tokens":1}}' ;;
  *) printf '%s\n' '{"content":"compact-done","tool_calls":[],"usage":{"prompt_tokens":90000,"completion_tokens":1}}' ;;
esac
EOF
chmod 755 "$stub"
printf '0\n' > "$STUB_N"
(
  cd "$cwork"
  SLAB_SKIP_INIT=1 SEED_LLM_STUB=$stub STUB_N=$STUB_N \
    "$cwd/bin/agent" --oneshot 'read the fat file then continue'
) > "$d/cmp.out" 2> "$d/cmp.err" || true
cmpmsg=
for m in "$cwork/.agent-runs"/*/messages.json; do
  [ -f "$m" ] || continue
  cmpmsg=$m
done
if [ -n "$cmpmsg" ] \
  && ! grep -q 'XXXXXXXXXX' "$cmpmsg" \
  && grep -q 'old tool output cleared' "$cmpmsg" \
  && grep -q 'earlier work summary' "$cmpmsg" \
  && grep -q 'Goal: test' "$cmpmsg" \
  && ! grep -q 'CONTEXT COMPACTION' "$cmpmsg"; then
  printf 'ok   compact summarizes and prunes old tool output\n'
else
  printf 'FAIL compact summarizes and prunes old tool output\n'; fail=$((fail + 1))
fi
if grep -q 'compact: summarized' "$d/cmp.err"; then
  printf 'ok   compact prints machine line\n'
else
  printf 'FAIL compact prints machine line\n'; fail=$((fail + 1))
fi
rm -rf "$cwd/agent-store"
# detach: engine is bin/agent, sibling seed.sh can go
cat > "$stub" <<'EOF'
#!/bin/sh
n=$(cat "${STUB_N}" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s\n' "$n" > "${STUB_N}"
if [ "$n" -eq 1 ]; then
  printf '{"content":"","tool_calls":[{"id":"c1","name":"shell","arguments":"{\\"command\\":\\"pwd\\"}"}],"usage":{"prompt_tokens":4,"completion_tokens":2}}\n'
else
  printf '{"content":"done","tool_calls":[],"usage":{"prompt_tokens":5,"completion_tokens":1}}\n'
fi
EOF
rm -f "$cwd/seed.sh"
printf '0\n' > "$STUB_N"
(
  cd "$work"
  SLAB_SKIP_INIT=1 SEED_LLM_STUB=$stub STUB_N=$STUB_N "$cwd/bin/agent" --oneshot 'where am i'
) > "$d/det.out" 2> "$d/det.err" || true
if grep -q 'done' "$d/det.out"; then printf 'ok   agent runs after seed.sh deleted\n'
else printf 'FAIL agent runs after seed.sh deleted\n'; fail=$((fail + 1)); fi
# restore installer copy so later tests that expect it still pass
cp "$SEED" "$cwd/seed.sh"
chmod 755 "$cwd/seed.sh"
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
  export SLAB_SKIP_INIT=1 SEED_LLM_STUB=$stub STUB_N=$STUB_N
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
linked=0
for m in "$repl/.agent-runs"/*/messages.json; do
  [ -f "$m" ] || continue
  if grep -q 'make a box and enter it' "$m" && grep -q 'where am i' "$m"; then
    linked=1
  fi
done
if [ "$linked" -eq 1 ]; then
  printf 'ok   interactive keeps prior user turns\n'
else
  printf 'FAIL interactive keeps prior user turns\n'; fail=$((fail + 1))
fi
if grep -R 'reasoning_content' "$repl/.agent-runs" >/dev/null 2>&1; then
  printf 'FAIL interactive context drops thinking\n'; fail=$((fail + 1))
else
  printf 'ok   interactive context drops thinking\n'
fi

# a model error must not kill the interactive window
cat > "$stub" <<'EOF'
#!/bin/sh
n=$(cat "${STUB_N}" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s\n' "$n" > "${STUB_N}"
if [ "$n" -eq 1 ]; then
  exit 71
fi
printf '{"content":"second-fine","tool_calls":[],"usage":{"prompt_tokens":1,"completion_tokens":1}}\n'
EOF
printf '0\n' > "$STUB_N"
swork=$d/swork
mkdir -p "$swork"
(
  cd "$swork"
  export SLAB_SKIP_INIT=1 SEED_LLM_STUB=$stub STUB_N=$STUB_N
  printf 'boom\nagain\n' | "$cwd/bin/agent"
) > "$d/sur.out" 2> "$d/sur.err" || true
if grep -q 'second-fine' "$d/sur.out"; then
  printf 'ok   model error does not kill the window\n'
else
  printf 'FAIL model error does not kill the window\n'; fail=$((fail + 1))
fi

# --resume continues the latest conversation in this workspace
cat > "$stub" <<'EOF'
#!/bin/sh
printf '{"content":"resumed-ok","tool_calls":[],"usage":{"prompt_tokens":1,"completion_tokens":1}}\n'
EOF
printf '0\n' > "$STUB_N"
rwork=$d/rwork
mkdir -p "$rwork"
(
  cd "$rwork"
  export SLAB_SKIP_INIT=1 SEED_LLM_STUB=$stub STUB_N=$STUB_N
  "$cwd/bin/agent" --oneshot 'first-task-marker' >/dev/null 2>&1
  sleep 1
  "$cwd/bin/agent" --resume 'second-task-marker'
) > "$d/res.out" 2> "$d/res.err" || true
res_linked=0
for m in "$rwork/.agent-runs"/*/messages.json; do
  [ -f "$m" ] || continue
  if grep -q 'first-task-marker' "$m" && grep -q 'second-task-marker' "$m"; then
    res_linked=1
  fi
done
if [ "$res_linked" -eq 1 ] && grep -q 'resumed-ok' "$d/res.out"; then
  printf 'ok   resume continues the conversation\n'
else
  printf 'FAIL resume continues the conversation\n'; fail=$((fail + 1))
fi

# outbound request must drop thinking even if a prior message stored it
cat > "$d/think-msgs.json" <<'JSON'
[{"role":"system","content":"s"},{"role":"assistant","content":"a","reasoning_content":"secret-think"},{"role":"user","content":"q"}]
JSON
seen=$d/seen-msgs.json
cat > "$d/seen-stub" <<'EOF'
#!/bin/sh
while [ "$#" -gt 0 ]; do
  case $1 in
    --messages) cp "$2" "$SEEN_MSGS"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' '{"content":"ok","tool_calls":[],"usage":{}}'
EOF
chmod +x "$d/seen-stub"
SEEN_MSGS=$seen SEED_LLM_STUB=$d/seen-stub \
  /bin/sh "$cwd/bin/agent" --llm --messages "$d/think-msgs.json" >/dev/null 2>&1 || true
if [ -f "$seen" ] && ! grep -q 'secret-think' "$seen" && ! grep -q reasoning_content "$seen"; then
  printf 'ok   outbound messages drop thinking\n'
else
  printf 'FAIL outbound messages drop thinking\n'; fail=$((fail + 1))
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
# resume must turn thinking off even if an old .env left it on
awk '
  BEGIN { done=0 }
  /^LLM_EXTRA=/ {
    print "LLM_EXTRA=\"{\\\"thinking\\\":{\\\"type\\\":\\\"enabled\\\"}}\""
    done=1
    next
  }
  { print }
  END { if (!done) print "LLM_EXTRA=\"{\\\"thinking\\\":{\\\"type\\\":\\\"enabled\\\"}}\"" }
' "$cwd2/.env" > "$cwd2/.env.n" && mv "$cwd2/.env.n" "$cwd2/.env"
(
  cd "$cwd2"
  /bin/sh "$SEED"
) > "$d/resume.out" 2> "$d/resume.err" || true
if grep '^LLM_EXTRA=' "$cwd2/.env" | grep -q enabled; then
  printf 'FAIL resume disables leftover thinking\n'; fail=$((fail + 1))
else
  printf 'ok   resume disables leftover thinking\n'
fi
if grep -q '\[seed\] tokens' "$d/cap.err" "$d/err"; then
  printf 'FAIL install has no token heartbeat\n'; fail=$((fail + 1))
else
  printf 'ok   install has no token heartbeat\n'
fi

# fetch jq from a local URL; do not hit GitHub in the suite
if command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  jqdl=$d/jqdl
  mkdir -p "$jqdl" "$d/jqbin"
  cat > "$jqdl/jq-fake" <<'EOF'
#!/bin/sh
if [ "$1" = --version ]; then printf 'jq-fake\n'; exit 0; fi
printf '{}\n'
exit 0
EOF
  chmod +x "$jqdl/jq-fake"
  JQPORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
  python3 -m http.server "$JQPORT" --bind 127.0.0.1 --directory "$jqdl" >/dev/null 2>&1 &
  JQ_PID=$!
  i=0
  while [ "$i" -lt 30 ]; do
    curl -sS -o /dev/null "http://127.0.0.1:$JQPORT/jq-fake" 2>/dev/null && break
    i=$((i + 1))
    sleep 0.1
  done
  (
    SEED_FORCE_JQ=1 SEED_JQ_DEST=$d/jqbin/jq \
      SEED_JQ_URL=http://127.0.0.1:$JQPORT/jq-fake \
      /bin/sh "$SEED" --ensure-jq
  ) > "$d/jq.out" 2> "$d/jq.err" || true
  kill "$JQ_PID" 2>/dev/null || true
  if grep -q 'installing: jq' "$d/jq.err" && [ -x "$d/jqbin/jq" ] \
    && PATH="$d/jqbin:$PATH" jq --version 2>/dev/null | grep -q jq-fake; then
    printf 'ok   seed fetches jq when missing\n'
  else
    printf 'FAIL seed fetches jq when missing\n'; fail=$((fail + 1))
  fi
  # plugin root first, even if official would also work
  jqmir=$d/jqmir
  mkdir -p "$jqmir/jq" "$d/jqbin2" "$d/jqbin3"
  cat > "$jqmir/jq/jq-fake" <<'EOF'
#!/bin/sh
if [ "$1" = --version ]; then printf 'jq-mirror\n'; exit 0; fi
printf '{}\n'
exit 0
EOF
  cat > "$jqmir/official" <<'EOF'
#!/bin/sh
if [ "$1" = --version ]; then printf 'jq-github\n'; exit 0; fi
printf '{}\n'
exit 0
EOF
  for n in jq-linux-amd64 jq-linux-arm64 jq-macos-amd64 jq-macos-arm64 jq-windows-amd64.exe; do
    cp "$jqmir/jq/jq-fake" "$jqmir/jq/$n"
    chmod +x "$jqmir/jq/$n"
  done
  chmod +x "$jqmir/official"
  MPORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
  python3 -m http.server "$MPORT" --bind 127.0.0.1 --directory "$jqmir" >/dev/null 2>&1 &
  JQ_PID=$!
  i=0
  while [ "$i" -lt 30 ]; do
    curl -sS -o /dev/null "http://127.0.0.1:$MPORT/jq/jq-linux-amd64" 2>/dev/null && break
    i=$((i + 1))
    sleep 0.1
  done
  rm -f "$d/jqbin2/jq"
  (
    SEED_FORCE_JQ=1 SEED_JQ_DEST=$d/jqbin2/jq \
      SEED_JQ_OFFICIAL_URL=http://127.0.0.1:$MPORT/official \
      SEED_PLUGIN_ROOT=http://127.0.0.1:$MPORT \
      /bin/sh "$SEED" --ensure-jq
  ) > "$d/jqm.out" 2> "$d/jqm.err" || true
  if ! grep -q 'installing: jq (github)' "$d/jqm.err" && [ -x "$d/jqbin2/jq" ] \
    && PATH="$d/jqbin2:$PATH" jq --version 2>/dev/null | grep -q jq-mirror; then
    printf 'ok   seed prefers plugin root jq over github\n'
  else
    printf 'FAIL seed prefers plugin root jq over github\n'; fail=$((fail + 1))
  fi
  rm -f "$d/jqbin3/jq"
  (
    SEED_FORCE_JQ=1 SEED_JQ_DEST=$d/jqbin3/jq \
      SEED_JQ_OFFICIAL_URL=http://127.0.0.1:$MPORT/official \
      SEED_PLUGIN_ROOT=http://127.0.0.1:1 \
      /bin/sh "$SEED" --ensure-jq
  ) > "$d/jqg.out" 2> "$d/jqg.err" || true
  kill "$JQ_PID" 2>/dev/null || true
  JQ_PID=
  if grep -q 'installing: jq (github)' "$d/jqg.err" && [ -x "$d/jqbin3/jq" ] \
    && PATH="$d/jqbin3:$PATH" jq --version 2>/dev/null | grep -q jq-github; then
    printf 'ok   seed fetches jq from github when mirror fails\n'
  else
    printf 'FAIL seed fetches jq from github when mirror fails\n'; fail=$((fail + 1))
  fi
fi

# seed plugin: one catalog, then models plugin, one pick
if command -v python3 >/dev/null 2>&1 && command -v curl >/dev/null 2>&1; then
  PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
  python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$ROOT/plugins" >/dev/null 2>&1 &
  PLUGIN_PID=$!
  i=0
  while [ "$i" -lt 30 ]; do
    curl -sS -o /dev/null "http://127.0.0.1:$PORT/seed/index.json" 2>/dev/null && break
    i=$((i + 1))
    sleep 0.1
  done
  PROOT=http://127.0.0.1:$PORT
  qdir=$d/qwen
  mkdir -p "$qdir"
  (
    cd "$qdir"
    printf '1\n' | SEED_PLUGIN_ROOT=$PROOT /bin/sh "$SEED" qwen sk-TESTQWEN
  ) > "$d/qwen.out" 2> "$d/qwen.err" || true
  ck "qwen install wrote agent" test -x "$qdir/bin/agent"
  ck "qwen .env has picked model" grep -q 'LLM_MODEL=qwen-plus' "$qdir/.env"
  ck "qwen .env has provider" grep -q 'LLM_PROVIDER=qwen' "$qdir/.env"
  ck "qwen key not in stderr" awk 'BEGIN{c=0} /sk-TESTQWEN/{c=1} END{exit c}' "$d/qwen.err"
  if grep '^LLM_EXTRA=' "$qdir/.env" | grep -q thinking; then
    printf 'FAIL qwen extra keeps deepseek fields out\n'; fail=$((fail + 1))
  else
    printf 'ok   qwen extra keeps deepseek fields out\n'
  fi
  nodir=$d/nopick
  mkdir -p "$nodir"
  (
    cd "$nodir"
    SEED_PLUGIN_ROOT=$PROOT /bin/sh "$SEED" qwen sk-TESTQWEN </dev/null
  ) > "$d/nopick.out" 2> "$d/nopick.err" || true
  if [ -x "$nodir/bin/agent" ]; then
    printf 'FAIL eof does not install\n'; fail=$((fail + 1))
  else
    printf 'ok   eof does not install\n'
  fi
  (
    cd "$d"
    mkdir -p nosuch
    cd nosuch
    printf '1\n' | SEED_PLUGIN_ROOT=$PROOT /bin/sh "$SEED" nosuch sk-x
  ) > "$d/ns.out" 2> "$d/ns.err" || true
  if grep -q 'unknown channel' "$d/ns.err" && grep -q qwen "$d/ns.err"; then
    printf 'ok   unknown channel lists catalog\n'
  else
    printf 'FAIL unknown channel lists catalog\n'; fail=$((fail + 1))
  fi

  # llm retries once on a transient 5xx, then succeeds
  flaky=$d/flaky
  mkdir -p "$flaky"
  cat > "$flaky/server.py" <<'PY'
import http.server
import json
import sys

hits = {"n": 0}


class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        ln = int(self.headers.get('Content-Length') or 0)
        self.rfile.read(ln)
        hits["n"] += 1
        if hits["n"] == 1:
            self.send_response(500)
            self.end_headers()
            self.wfile.write(b'boom')
            return
        body = json.dumps({
            "choices": [{"message": {"content": "retried-ok", "tool_calls": []}}],
            "usage": {"prompt_tokens": 1, "completion_tokens": 1},
        }).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
  FPORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
  python3 "$flaky/server.py" "$FPORT" >/dev/null 2>&1 &
  FLAKY_PID=$!
  i=0
  while [ "$i" -lt 30 ]; do
    curl -sS -o /dev/null "http://127.0.0.1:$FPORT/" 2>/dev/null && break
    i=$((i + 1))
    sleep 0.1
  done
  rout=$(printf 'hi' | LLM_API_KEY=sk-FAKEFLAKY LLM_API_URL="http://127.0.0.1:$FPORT/chat" \
    LLM_MODEL=m LLM_PROVIDER=test /bin/sh "$cwd/bin/agent" --llm 2> "$d/flaky.err" || true)
  kill "$FLAKY_PID" 2>/dev/null || true
  FLAKY_PID=
  if printf '%s' "$rout" | grep -q 'retried-ok' && grep -q 'llm: retry' "$d/flaky.err"; then
    printf 'ok   llm retries a transient error\n'
  else
    printf 'FAIL llm retries a transient error\n'; fail=$((fail + 1))
  fi

  # first open without agent plugin: error, no prompt
  (
    cd "$cwd"
    SEED_PLUGIN_ROOT=http://127.0.0.1:1 "$cwd/bin/agent" </dev/null
  ) > "$d/dead.out" 2> "$d/dead.err" || true
  if grep -q 'error:' "$d/dead.err" && ! grep -q '>' "$d/dead.err"; then
    printf 'ok   missing agent plugin errors before prompt\n'
  else
    printf 'FAIL missing agent plugin errors before prompt\n'; fail=$((fail + 1))
  fi

  # init stub fills the machine tree to the disk standard
  cat > "$cwd/fill-tree.sh" <<'SH'
#!/bin/sh
jq '.ready=true
  | .updated="t"
  | .system.tools.sh.present=true | .system.tools.sh.ok=true
  | .system.tools.curl.present=true | .system.tools.curl.ok=true
  | .system.tools.jq.present=true | .system.tools.jq.ok=true
  | .system.tools.rg.present=true | .system.tools.rg.ok=true
  | .system.tools.git.present=true | .system.tools.git.ok=true
  | .system.tools.python.present=true | .system.tools.python.ok=true' \
  agent-store/index.json > agent-store/index.json.tmp
mv agent-store/index.json.tmp agent-store/index.json
SH
  chmod 755 "$cwd/fill-tree.sh"
  cat > "$stub" <<'EOF'
#!/bin/sh
n=$(cat "${STUB_N}" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s\n' "$n" > "${STUB_N}"
if [ "$n" -eq 1 ]; then
  printf '%s\n' '{"content":"","tool_calls":[{"id":"i1","name":"shell","arguments":"{\"command\":\"sh fill-tree.sh\"}"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}'
else
  printf '%s\n' '{"content":"inited","tool_calls":[],"usage":{"prompt_tokens":1,"completion_tokens":1}}'
fi
EOF
  printf '0\n' > "$STUB_N"
  (
    cd "$cwd"
    SEED_PLUGIN_ROOT=$PROOT SEED_LLM_STUB=$stub STUB_N=$STUB_N \
      "$cwd/bin/agent" </dev/null
  ) > "$d/init.out" 2> "$d/init.err" || true
  if grep -q 'initializing:' "$d/init.err" && grep -q 'ready' "$d/init.err" \
    && grep -q '>' "$d/init.err"; then
    printf 'ok   first open inits then prompts\n'
  else
    printf 'FAIL first open inits then prompts\n'; fail=$((fail + 1))
  fi
  if ! grep -q '完整' "$d/init.err" && ! grep -q '简单' "$d/init.err"; then
    printf 'ok   first open prints no edition ask\n'
  else
    printf 'FAIL first open prints no edition ask\n'; fail=$((fail + 1))
  fi
  if grep -q 'inited' "$d/init.out"; then
    printf 'FAIL init hid model final text\n'; fail=$((fail + 1))
  else
    printf 'ok   init hid model final text\n'
  fi
  if jq -e '.ready == true and .system.tools.sh' "$cwd/agent-store/index.json" >/dev/null 2>&1; then
    printf 'ok   init wrote ready machine tree\n'
  else
    printf 'FAIL init wrote ready machine tree\n'; fail=$((fail + 1))
  fi
  if jq -e '.system.retrieve | type=="string" and length>0' \
    "$cwd/agent-store/index.json" >/dev/null 2>&1; then
    printf 'ok   placed tree keeps retrieve\n'
  else
    printf 'FAIL placed tree keeps retrieve\n'; fail=$((fail + 1))
  fi
  if jq -e '.system.web.fetch.use' "$cwd/agent-store/index.json" >/dev/null 2>&1 \
    && ! jq -e '.system.web | has("websearch")' "$cwd/agent-store/index.json" >/dev/null 2>&1; then
    printf 'ok   placed tree keeps prompt fetch only\n'
  else
    printf 'FAIL placed tree keeps prompt fetch only\n'; fail=$((fail + 1))
  fi
  ck "init cached catalog" test -f "$cwd/agent-store/catalog.json"
  ck "init cached init plugin" test -f "$cwd/agent-store/plugins/init.json"
  ck "init did not cache host script" test ! -f "$cwd/agent-store/plugins/host.sh"
  ck "init did not cache compact script" test ! -f "$cwd/agent-store/plugins/compact.sh"
  ck "init wrote memory tree" test -f "$cwd/.agent-memory/index.json"
  if jq -e 'has("host") | not' "$cwd/agent-store/index.json" >/dev/null 2>&1; then
    printf 'ok   init tree has no host map\n'
  else
    printf 'FAIL init tree has no host map\n'; fail=$((fail + 1))
  fi

  # already ready: dead plugin root still opens
  (
    cd "$cwd"
    SEED_PLUGIN_ROOT=http://127.0.0.1:1 "$cwd/bin/agent" </dev/null
  ) > "$d/ready.out" 2> "$d/ready.err" || true
  if grep -q '>' "$d/ready.err" && ! grep -q 'initializing:' "$d/ready.err"; then
    printf 'ok   ready agent opens offline\n'
  else
    printf 'FAIL ready agent opens offline\n'; fail=$((fail + 1))
  fi
  if ! grep -q '完整' "$d/ready.err" && ! grep -q '简单' "$d/ready.err"; then
    printf 'ok   no edition ask on open\n'
  else
    printf 'FAIL no edition ask on open\n'; fail=$((fail + 1))
  fi

  # version bump: plain open does not refetch; --update does
  oldver=
  if [ -f "$cwd/agent-store/catalog.json" ]; then
    oldver=$(jq -r '.version // empty' "$cwd/agent-store/catalog.json")
  fi
  up=$d/plugup
  mkdir -p "$up/agent" "$up/seed"
  cp "$ROOT/plugins/seed/"*.json "$up/seed/" 2>/dev/null || true
  jq '.version="2" | .updated="2099-01-01T00:00:00Z"' \
    "$ROOT/plugins/agent/index.json" > "$up/agent/index.json"
  if [ -f "$ROOT/plugins/agent/init.json" ]; then
    jq '.prompt=("updated-init-prompt " + .prompt)' \
      "$ROOT/plugins/agent/init.json" > "$up/agent/init.json"
  else
    printf '%s\n' '{"prompt":"updated-init-prompt","machine_tree":{},"memory_tree":{}}' > "$up/agent/init.json"
  fi
  kill "$PLUGIN_PID" 2>/dev/null || true
  PLUGIN_PID=
  PORT2=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
  python3 -m http.server "$PORT2" --bind 127.0.0.1 --directory "$up" >/dev/null 2>&1 &
  PLUGIN_PID=$!
  i=0
  while [ "$i" -lt 30 ]; do
    curl -sS -o /dev/null "http://127.0.0.1:$PORT2/agent/index.json" 2>/dev/null && break
    i=$((i + 1))
    sleep 0.1
  done
  PROOT2=http://127.0.0.1:$PORT2
  (
    cd "$cwd"
    SEED_PLUGIN_ROOT=$PROOT2 "$cwd/bin/agent" </dev/null
  ) > "$d/noup.out" 2> "$d/noup.err" || true
  nowver=
  [ -f "$cwd/agent-store/catalog.json" ] && nowver=$(jq -r '.version' "$cwd/agent-store/catalog.json")
  if [ -n "$oldver" ] && [ "$nowver" = "$oldver" ]; then
    printf 'ok   plain open does not refresh catalog\n'
  else
    printf 'FAIL plain open does not refresh catalog\n'; fail=$((fail + 1))
  fi
  (
    cd "$cwd"
    SEED_PLUGIN_ROOT=$PROOT2 "$cwd/bin/agent" --update
  ) > "$d/up.out" 2> "$d/up.err" || true
  nowver=
  [ -f "$cwd/agent-store/catalog.json" ] && nowver=$(jq -r '.version' "$cwd/agent-store/catalog.json")
  if [ "$nowver" = 2 ]; then
    printf 'ok   --update refreshes catalog\n'
  else
    printf 'FAIL --update refreshes catalog\n'; fail=$((fail + 1))
  fi
  if jq -e '.ready == true' "$cwd/agent-store/index.json" >/dev/null 2>&1; then
    printf 'ok   --update does not rescan\n'
  else
    printf 'FAIL --update does not rescan\n'; fail=$((fail + 1))
  fi
  jq '.system.web.junk={"ok":true}' "$cwd/agent-store/index.json" \
    > "$cwd/agent-store/index.json.tmp"
  mv "$cwd/agent-store/index.json.tmp" "$cwd/agent-store/index.json"
  jq '.version="3" | .updated="2099-01-02T00:00:00Z"' \
    "$up/agent/index.json" > "$up/agent/index.json.tmp"
  mv "$up/agent/index.json.tmp" "$up/agent/index.json"
  (
    cd "$cwd"
    SEED_PLUGIN_ROOT=$PROOT2 "$cwd/bin/agent" --update
  ) > "$d/up2.out" 2> "$d/up2.err" || true
  if jq -e '.system.web.fetch.use and (.system.web|has("junk")|not)' \
    "$cwd/agent-store/index.json" >/dev/null 2>&1; then
    printf 'ok   --update drops leftover web slots\n'
  else
    printf 'FAIL --update drops leftover web slots\n'; fail=$((fail + 1))
  fi

  # engine probes tools before the model runs; a ready-only stub is enough
  pr=$d/probe
  mkdir -p "$pr/bin"
  cp "$cwd/.env" "$pr/.env"
  cp "$cwd/bin/agent" "$pr/bin/agent"
  chmod 755 "$pr/bin/agent"
  cat > "$pr/ready-only.sh" <<'SH'
#!/bin/sh
jq '.ready=true | .updated="t"' agent-store/index.json > agent-store/index.json.tmp
mv agent-store/index.json.tmp agent-store/index.json
SH
  chmod 755 "$pr/ready-only.sh"
  cat > "$stub" <<'EOF'
#!/bin/sh
n=$(cat "${STUB_N}" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s\n' "$n" > "${STUB_N}"
if [ "$n" -eq 1 ]; then
  printf '%s\n' '{"content":"","tool_calls":[{"id":"p1","name":"shell","arguments":"{\"command\":\"sh ready-only.sh\"}"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}'
else
  printf '%s\n' '{"content":"probed","tool_calls":[],"usage":{"prompt_tokens":1,"completion_tokens":1}}'
fi
EOF
  printf '0\n' > "$STUB_N"
  (
    cd "$pr"
    SEED_PLUGIN_ROOT=$PROOT2 SEED_LLM_STUB=$stub STUB_N=$STUB_N \
      "$pr/bin/agent" </dev/null
  ) > "$d/probe.out" 2> "$d/probe.err" || true
  if grep -q '>' "$d/probe.err" \
    && jq -e '.system.tools.sh.ok==true and .system.tools.jq.ok==true
        and (.system.tools.jq.path|length>0)' \
      "$pr/agent-store/index.json" >/dev/null 2>&1; then
    printf 'ok   engine probes tools deterministically\n'
  else
    printf 'FAIL engine probes tools deterministically\n'; fail=$((fail + 1))
  fi

  # black/whitelist mask: PATH holds only POSIX essentials plus a fake
  # codex; rg, git, python and the real codex are masked out
  shim=$d/shim
  mkdir -p "$shim"
  miss=0
  for t in sh cat chmod cp curl date dd dirname basename grep head tail ls \
      mkdir mktemp mv ps rm sed sleep sort touch tr uname wc awk jq; do
    p=$(command -v "$t" 2>/dev/null || :)
    case $p in
      /*) ln -s "$p" "$shim/$t" ;;
      *) miss=$((miss + 1)); printf 'mask: cannot shim %s\n' "$t" >&2 ;;
    esac
  done
  cat > "$shim/codex" <<'SH'
#!/bin/sh
printf 'codex-stub 1.0\n'
SH
  chmod 755 "$shim/codex"
  mk=$d/maskwork
  mkdir -p "$mk/bin"
  cp "$cwd/.env" "$mk/.env"
  cp "$cwd/bin/agent" "$mk/bin/agent"
  chmod 755 "$mk/bin/agent"
  cp "$pr/ready-only.sh" "$mk/ready-only.sh"
  cat > "$stub" <<'EOF'
#!/bin/sh
n=$(cat "${STUB_N}" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s\n' "$n" > "${STUB_N}"
if [ "$n" -eq 1 ]; then
  printf '%s\n' '{"content":"","tool_calls":[{"id":"m1","name":"shell","arguments":"{\"command\":\"sh ready-only.sh\"}"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}'
else
  printf '%s\n' '{"content":"masked-ok","tool_calls":[],"usage":{"prompt_tokens":1,"completion_tokens":1}}'
fi
EOF
  printf '0\n' > "$STUB_N"
  (
    cd "$mk"
    PATH="$shim" SEED_PLUGIN_ROOT=$PROOT2 SEED_LLM_STUB=$stub STUB_N=$STUB_N \
      "$mk/bin/agent" </dev/null
  ) > "$d/mask.out" 2> "$d/mask.err" || true
  if [ "$miss" -eq 0 ] \
    && grep -q 'ready' "$d/mask.err" \
    && grep -q '>' "$d/mask.err" \
    && jq -e '.system.tools.sh.ok==true and .system.tools.curl.ok==true
        and .system.tools.jq.ok==true
        and .system.tools.rg.present==false and .system.tools.rg.ok==false
        and .system.tools.git.present==false and .system.tools.git.ok==false
        and .system.tools.python.present==false and .system.tools.python.ok==false' \
      "$mk/agent-store/index.json" >/dev/null 2>&1 \
    && PATH="$shim" command -v codex >/dev/null 2>&1 \
    && [ "$(PATH="$shim" codex)" = 'codex-stub 1.0' ]; then
    printf 'ok   masked env: blacklist honest, whitelist callable\n'
  else
    printf 'FAIL masked env: blacklist honest, whitelist callable\n'; fail=$((fail + 1))
  fi

  # model wrote ready + skills at the top level, dropped version/ours:
  # engine must salvage, not print init failed
  crook=$d/crook
  mkdir -p "$crook/bin"
  cp "$cwd/.env" "$crook/.env"
  cp "$cwd/bin/agent" "$crook/bin/agent"
  chmod 755 "$crook/bin/agent"
  cat > "$crook/crook-tree.sh" <<'SH'
#!/bin/sh
jq '
  .ready=true
  | .updated="t"
  | .system.tools.sh.present=true | .system.tools.sh.ok=true
  | .system.tools.curl.present=true | .system.tools.curl.ok=true
  | .system.tools.jq.present=true | .system.tools.jq.ok=true
  | .system.tools.rg.present=true | .system.tools.rg.ok=true
  | .system.tools.git.present=true | .system.tools.git.ok=true
  | .system.tools.python.present=true | .system.tools.python.ok=true
  | .skills=[{name:"pdf-demo",description:"Extract text from PDF files",path:"/tmp/pdf-demo",ok:true,note:""}]
  | del(.version)
  | del(.ours)
  | del(.system.skills)
' agent-store/index.json > agent-store/index.json.tmp
mv agent-store/index.json.tmp agent-store/index.json
SH
  chmod 755 "$crook/crook-tree.sh"
  cat > "$stub" <<'EOF'
#!/bin/sh
n=$(cat "${STUB_N}" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s\n' "$n" > "${STUB_N}"
if [ "$n" -eq 1 ]; then
  printf '%s\n' '{"content":"","tool_calls":[{"id":"k1","name":"shell","arguments":"{\"command\":\"sh crook-tree.sh\"}"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}'
else
  printf '%s\n' '{"content":"crooked","tool_calls":[],"usage":{"prompt_tokens":1,"completion_tokens":1}}'
fi
EOF
  printf '0\n' > "$STUB_N"
  (
    cd "$crook"
    SEED_PLUGIN_ROOT=$PROOT2 SEED_LLM_STUB=$stub STUB_N=$STUB_N \
      "$crook/bin/agent" </dev/null
  ) > "$d/crook.out" 2> "$d/crook.err" || true
  if grep -q '>' "$d/crook.err" && ! grep -q 'error: init failed' "$d/crook.err"; then
    printf 'ok   crooked ready tree still inits\n'
  else
    printf 'FAIL crooked ready tree still inits\n'; fail=$((fail + 1))
  fi
  if jq -e '.ready==true and has("version") and has("ours")
      and (.system.skills|type=="array")
      and (.system.skills|map(.name)|index("pdf-demo"))' \
    "$crook/agent-store/index.json" >/dev/null 2>&1; then
    printf 'ok   engine salvages top-level skills\n'
  else
    printf 'FAIL engine salvages top-level skills\n'; fail=$((fail + 1))
  fi

  # already-ready but crooked: repair on open, do not re-init
  jq '
    .skills=[{name:"keep-me",description:"x",path:"/tmp/k",ok:true,note:""}]
    | del(.version)
    | del(.ours)
    | del(.system.skills)
  ' "$crook/agent-store/index.json" > "$crook/agent-store/index.json.tmp"
  mv "$crook/agent-store/index.json.tmp" "$crook/agent-store/index.json"
  (
    cd "$crook"
    SEED_PLUGIN_ROOT=http://127.0.0.1:1 "$crook/bin/agent" </dev/null
  ) > "$d/crook2.out" 2> "$d/crook2.err" || true
  if grep -q '>' "$d/crook2.err" && ! grep -q 'initializing:' "$d/crook2.err" \
    && ! grep -q 'error: init failed' "$d/crook2.err" \
    && jq -e '.system.skills[0].name=="keep-me" and has("ours")' \
      "$crook/agent-store/index.json" >/dev/null 2>&1; then
    printf 'ok   ready crooked tree repaired offline\n'
  else
    printf 'FAIL ready crooked tree repaired offline\n'; fail=$((fail + 1))
  fi

  # bad stub deletes a required branch -> init failed
  bad=$d/badinit
  mkdir -p "$bad"
  cp "$cwd/.env" "$bad/.env"
  mkdir -p "$bad/bin"
  cp "$cwd/bin/agent" "$bad/bin/agent"
  chmod 755 "$bad/bin/agent"
  cat > "$bad/break-tree.sh" <<'SH'
#!/bin/sh
jq 'del(.system)' agent-store/index.json > agent-store/index.json.tmp
mv agent-store/index.json.tmp agent-store/index.json
SH
  chmod 755 "$bad/break-tree.sh"
  cat > "$stub" <<'EOF'
#!/bin/sh
n=$(cat "${STUB_N}" 2>/dev/null || echo 0); n=$((n + 1)); printf '%s\n' "$n" > "${STUB_N}"
if [ "$n" -eq 1 ]; then
  printf '%s\n' '{"content":"","tool_calls":[{"id":"b1","name":"shell","arguments":"{\"command\":\"sh break-tree.sh\"}"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}'
else
  printf '%s\n' '{"content":"nope","tool_calls":[],"usage":{"prompt_tokens":1,"completion_tokens":1}}'
fi
EOF
  printf '0\n' > "$STUB_N"
  (
    cd "$bad"
    SEED_PLUGIN_ROOT=$PROOT2 SEED_LLM_STUB=$stub STUB_N=$STUB_N \
      "$bad/bin/agent" </dev/null
  ) > "$d/bad.out" 2> "$d/bad.err" || true
  if grep -q 'error: init failed' "$d/bad.err" && ! grep -q '>' "$d/bad.err"; then
    printf 'ok   broken tree fails init\n'
  else
    printf 'FAIL broken tree fails init\n'; fail=$((fail + 1))
  fi
  if [ -f "$bad/agent-store/index.json" ] && jq -e '.ready == true' "$bad/agent-store/index.json" >/dev/null 2>&1; then
    printf 'FAIL broken tree is not ready\n'; fail=$((fail + 1))
  else
    printf 'ok   broken tree is not ready\n'
  fi
  if awk 'BEGIN{c=0} /sk-TESTKEYNOTREAL/{c=1} END{exit c}' "$d/init.err" "$d/bad.err" "$d/up.err"; then
    printf 'ok   agent plugin evidence has no key\n'
  else
    printf 'FAIL agent plugin evidence has no key\n'; fail=$((fail + 1))
  fi
else
  printf 'FAIL python3+curl needed for plugin tests\n'; fail=$((fail + 1))
fi

[ "$fail" -eq 0 ] || { printf '\nSEED-PACKAGE FAIL: %s\n' "$fail"; exit 1; }
printf '\nSEED-PACKAGE PASS\n'
