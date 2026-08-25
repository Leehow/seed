#!/bin/sh
# Layer 3: seed.sh + mock OpenAI-compatible server. No host .env / API keys.
set -eu
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO=${REPO_ROOT:-$(CDPATH= cd "$HERE/../.." && pwd)}

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# Refuse host credentials even if this script is invoked on a machine that has them.
unset LLM_API_KEY LLM_API_URL LLM_MODEL LLM_PROVIDER LLM_EXTRA 2>/dev/null || true
unset OPENAI_API_KEY ANTHROPIC_API_KEY DEEPSEEK_API_KEY 2>/dev/null || true
# Never source a .env
if [ -f "$REPO/.env" ]; then
  printf 'note: repo .env present on this tree; e2e will not read it\n'
fi

command -v python3 >/dev/null 2>&1 || fail "e2e: need python3"
command -v curl >/dev/null 2>&1 || fail "e2e: need curl"

# jq may be missing; seed.sh bootstraps it, but lifecycle helpers need it too.
if ! command -v jq >/dev/null 2>&1; then
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache jq >/dev/null
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq && apt-get install -y -qq jq >/dev/null
  else
    fail "e2e: need jq"
  fi
fi

WS=$(mktemp -d /tmp/seed-e2e-ws.XXXXXX)
HOME_DIR=$(mktemp -d /tmp/seed-e2e-home.XXXXXX)
# Never a fixed port: 8765 was answered by an unrelated local dev server
# once, and the run failed three assertions downstream before saying so.
PORT=${MOCK_PORT:-$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')}
export MOCK_PACKS="$REPO/packs"
export MOCK_PORT="$PORT"
export SEED_HOME="$HOME_DIR"
export HOME="$HOME_DIR"
export SEED_MODE=agent
export SEED_SKIP_UPDATE=1
export SEED_PACK_ROOT="http://127.0.0.1:${PORT}/packs"
export SEED_SITE="http://127.0.0.1:${PORT}"
export AGENT_MAX_ROUNDS=20
export AGENT_RUNS_DIR="$WS/.agent-runs"
# Dummy key only — never a real secret. seed requires a non-empty key string.
export LLM_API_KEY=dummy-not-a-real-key
export LLM_API_URL="http://127.0.0.1:${PORT}/v1/chat/completions"
export LLM_MODEL=mock
export LLM_PROVIDER=custom
export LLM_EXTRA='{}'

python3 "$HERE/mock_llm.py" >"$WS/mock.log" 2>&1 &
MPID=$!
cleanup() {
  kill "$MPID" 2>/dev/null || true
  wait "$MPID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# Wait for the mock, and check it is ours: HTTP 200 alone is satisfied by any
# stranger holding the port.
mock_is_ours() {
  curl -sS -m 2 "http://127.0.0.1:${PORT}/v1/models" 2>/dev/null \
    | jq -e '.data[0].id == "mock"' >/dev/null 2>&1
}
i=0
while [ "$i" -lt 50 ]; do
  mock_is_ours && break
  i=$((i + 1))
  sleep 0.1
done
mock_is_ours || { cat "$WS/mock.log" >&2; fail "e2e: no mock on port $PORT (in use by something else?)"; }

# sanity: packs served, including memory.json
curl -sS "http://127.0.0.1:${PORT}/packs/agent/memory.json" | jq empty \
  || fail "e2e: mock did not serve memory.json"

cd "$WS"
# seed.sh from the staged/repo tree — not via a host install
SEED="$REPO/seed.sh"
[ -f "$SEED" ] || fail "e2e: missing $SEED"

printf 'e2e: oneshot task (init + distill)\n'
set +e
/bin/sh "$SEED" --oneshot "Write project/hello-ok/hello.sh that prints hello-ok. Search and try more than one approach before success. Independently verify. Distill a candidate experience at the end if the three distill predicates hold."
st=$?
set -e
[ "$st" -eq 0 ] || { printf 'seed oneshot exit %s\n' "$st" >&2; tail -n 80 "$WS/mock.log" >&2; fail "e2e: seed oneshot task failed"; }

idx=$SEED_HOME/agent-store/index.json
[ -f "$idx" ] || fail "e2e: machine index missing after init"
jq -e '.ready==true' "$idx" >/dev/null || fail "e2e: index not ready"
# LLM wrote env (baseline env is empty) — proves init turn ran
# Written by the runtime bootstrap, not by the model.
jq -e '(.identity.os|length)>0 and (.identity.kernel|length)>0
   and (.identity.prereqs.jq.ok==true) and ((.identity.path_dirs|length)>0)' "$idx" >/dev/null \
  || fail "e2e: identity not filled by the runtime bootstrap"

exp=$SEED_HOME/agent-store/experiences/hello-ok/exp.json
[ -f "$exp" ] || fail "e2e: candidate exp.json missing"
[ -f "$SEED_HOME/agent-store/experiences/hello-ok/SKILL.md" ] || fail "e2e: SKILL.md missing"
[ -f "$SEED_HOME/agent-store/experiences/index.json" ] || fail "e2e: experiences/index.json missing"
st=$(jq -r .status "$exp")
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected '$2' got '$1'"; }
assert_eq "$st" "candidate" "e2e: status after distill (must not promote same task)"
jq -e '.kind=="procedure" and .id=="hello-ok" and (.verify|length)>0' "$exp" >/dev/null \
  || fail "e2e: exp.json schema"
jq -e '.experiences[] | select(.id=="hello-ok" and .status=="candidate")' \
  "$SEED_HOME/agent-store/experiences/index.json" >/dev/null \
  || fail "e2e: index row after distill"
[ -f "$WS/project/hello-ok/hello.sh" ] || fail "e2e: hello.sh missing"
out=$(sh "$WS/project/hello-ok/hello.sh")
assert_eq "$out" "hello-ok" "e2e: hello.sh output"
# candidate not ok:true in skills
cand_ok=$(jq '[.agent.skills[]? | select(.name=="hello-ok" and .ok==true)] | length' "$idx")
assert_eq "$cand_ok" "0" "e2e: candidate must not be ok:true in agent.skills"
# no leftover tmp
leftover=$(find "$SEED_HOME/agent-store" \( -name '*.tmp' -o -name '*.tmp.*' \) || true)
[ -z "$leftover" ] || fail "e2e: leftover tmp after distill: $leftover"
jq -e '.identity.os == (.identity.os|ascii_downcase)' "$idx" >/dev/null \
  || fail "e2e: identity.os must be canonical lowercase"
obs=$SEED_HOME/agent-store/observations.json
[ -f "$obs" ] || fail "e2e: observations.json not created"
jq -e '([.observations[] | select(.source=="PATH")] | length) > 5' "$obs" >/dev/null \
  || fail "e2e: PATH sweep did not land in observations.json"
jq -e '(.capabilities|type)=="array" and (.resources|type)=="array"' "$idx" >/dev/null \
  || fail "e2e: index is not v2 shaped"
# Retrieval remains runtime-owned: one experience funnel, no independent row
# activation, and no silent policy refresh from a model-generated curl command.
jq -e '.system.retrieve
  | contains("The runtime available-skill catalog is the single experience retrieval funnel")
    and contains("do not independently activate rows")
    and contains("Automatic agent-pack refresh is opt-in")' "$idx" >/dev/null \
  || fail "e2e: retrieve lost the runtime-owned funnel or trust guardrails"
# The runtime fetched the catalog-declared optional memory pack before the turn.
mp=$SEED_HOME/agent-store/packs/memory.json
[ -f "$mp" ] || fail "e2e: memory pack not fetched on cold start"
jq -e 'has("prompt")' "$mp" >/dev/null || fail "e2e: fetched memory pack is not a valid pack"
cmp -s "$mp" "$REPO/packs/agent/memory.json" \
  || fail "e2e: fetched memory pack differs from the pack-root source"
# evidence jsonl
evn=$(find "$SEED_HOME/agent-store/runs" -name '*.jsonl' | wc -l | tr -d ' ')
[ "$evn" -ge 1 ] || fail "e2e: missing evidence jsonl"
printf 'ok: init ready + candidate distilled\n'

printf 'e2e: oneshot --maintain (promote)\n'
set +e
/bin/sh "$SEED" --oneshot "--maintain"
st=$?
set -e
[ "$st" -eq 0 ] || { printf 'seed maintain exit %s\n' "$st" >&2; tail -n 80 "$WS/mock.log" >&2; fail "e2e: seed --maintain failed"; }
if grep -q 'MODEL_MAINTAIN_CALLED' "$WS/mock.log"; then
  fail "e2e: seed --maintain reached the model"
fi

st=$(jq -r .status "$exp")
assert_eq "$st" "active" "e2e: status after maintain"
succ=$(jq -r .successes "$exp")
[ "$succ" -ge 1 ] || fail "e2e: successes after promote, got $succ"
lv=$(jq -r .last_verified "$exp")
[ -n "$lv" ] || fail "e2e: last_verified empty after promote"
jq -e '.experiences[] | select(.id=="hello-ok" and .status=="active")' \
  "$SEED_HOME/agent-store/experiences/index.json" >/dev/null \
  || fail "e2e: index not updated to active"
# The mock does not write this row; seed.sh does. One row, keyed by the
# experience id, pointing at the body a hit would cat.
skill_n=$(jq '[.agent.skills[] | select(.name=="hello-ok" and .ok==true)] | length' "$idx")
assert_eq "$skill_n" "1" "e2e: active must register exactly one ok:true skill"
jq -e '.agent.skills[] | select(.name=="hello-ok")
  | .note == "experience active"
  and .source == "experience"
  and .status == "active"
  and (.scope.tools | length) == 0
  and (.path | endswith("/experiences/hello-ok/SKILL.md"))
  and (.description | length) > 0' "$idx" >/dev/null \
  || fail "e2e: registered skill row has the wrong shape"
leftover=$(find "$SEED_HOME/agent-store" \( -name '*.tmp' -o -name '*.tmp.*' \) || true)
[ -z "$leftover" ] || fail "e2e: leftover tmp after maintain: $leftover"

printf 'PASS: e2e\n'
