#!/bin/sh
# bench/memory-test/test_real_smoke.sh — REAL-model smoke for the seed memory system.
# Runs the repo seed.sh against a real OpenAI-compatible LLM inside an Apple
# container (never Docker). Flow: init oneshot with a broken-build repair task
# (init -> task -> distill candidate + cold-start fetch), then --maintain
# (promote to active + register agent.skills). Assertions AND behavior logs.
#
# Credentials discipline (hard rules):
#   - Reads ONLY LLM_API_URL / LLM_API_KEY / LLM_MODEL from this process env.
#     Missing any -> clear message, exit 2. No URL or key is ever written into
#     this script, the image, the bench tree, logs, or git.
#   - The key reaches the container via `container run -e LLM_API_KEY` (bare-key
#     host inherit; the value never appears in argv or an env-file).
#   - Copied artifacts exclude credential headers; a final scrub pass replaces
#     any accidental occurrence of the key with __REDACTED__ and verifies it.
#
# SMOKE_SELFTEST=1  plumbing check only (dummy creds ok): container boot, env
#                   injection, pack server, broken-project acceptance predicate.
#                   Never invokes seed.sh or the model.
set -eu

HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO=${REPO_ROOT:-$(CDPATH= cd "$HERE/../.." && pwd)}
IMAGE=${SMOKE_IMAGE:-slab-bench-rich:latest}
SELFTEST=${SMOKE_SELFTEST:-0}
MAX_ROUNDS=${SMOKE_MAX_ROUNDS:-40}
TIMEOUT_SECS=${SMOKE_TIMEOUT:-2700}

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

# --- 1. env-only credentials -------------------------------------------------
if [ -z "${LLM_API_KEY:-}" ]; then
  printf 'test_real_smoke: LLM_API_KEY is not set.\n' >&2
  printf 'Export the real-model credentials in the environment (never in files):\n' >&2
  printf '  LLM_API_URL=<openai-compatible chat/completions URL> \\\n' >&2
  printf '  LLM_API_KEY=<key> LLM_MODEL=<model> sh %s\n' "$0" >&2
  exit 2
fi
if [ -z "${LLM_API_URL:-}" ]; then
  printf 'test_real_smoke: LLM_API_URL is not set (LLM_API_KEY is). Refusing to run.\n' >&2
  exit 2
fi
if [ -z "${LLM_MODEL:-}" ]; then
  printf 'test_real_smoke: LLM_MODEL is not set. Refusing to run.\n' >&2
  exit 2
fi

# --- 2. Apple container runtime (never Docker) --------------------------------
command -v container >/dev/null 2>&1 || fail 'test_real_smoke: Apple `container` CLI not found'
st=$(container system status 2>/dev/null | awk '/^status/ {print $2}')
if [ "$st" != running ]; then
  printf 'smoke: starting container runtime\n'
  container system start >/dev/null 2>&1 || container system start
fi
container system status 2>/dev/null | grep -q '^status  *running' \
  || fail 'test_real_smoke: container runtime not running'

# --- 3. staging (repo subset + broken project + inner script) -----------------
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/seed-smoke-stage.XXXXXX")
REPORT="$HERE/report-real-smoke-$STAMP"
mkdir -p "$REPORT"
trap 'rm -rf "$STAGE"' EXIT INT TERM

mkdir -p "$STAGE/stage"
cp "$REPO/seed.sh" "$STAGE/stage/seed.sh"
cp -R "$REPO/packs" "$STAGE/stage/packs"
if [ -f "$STAGE/stage/.env" ]; then fail 'smoke: .env leaked into staging'; fi
for f in $(find "$STAGE/stage" \( -name '.env' -o -name '*api*key*' \) 2>/dev/null); do
  fail "smoke: suspicious file staged: $f"
done
jq empty "$STAGE"/stage/packs/agent/*.json || fail 'smoke: staged packs fail jq empty'

# The deliberately broken build the real model must repair (needs search + retry):
QK="$STAGE/ws/project/quizkit"
mkdir -p "$QK/src"
cat > "$QK/make.sh" <<'EOF'
#!/bin/sh
set -eu
out=dist/quiz.sh
cat src/00-header.sh src/10-args.sh src/20-quiz.sh src/40-main.sh | tr -d '\r' > "$out"
chmod +x "$out"
sh "$out" --selftest || echo "selftest failed (ignored)"
echo "built $out"
EOF
cat > "$QK/src/00-header.sh" <<'EOF'
#!/bin/sh
set -eu
EOF
cat > "$QK/src/10-args.sh" <<'EOF'
mode=run
for a in "$@"; do
  case $a in
    --selftest) mode=selftest ;;
  esac
done
EOF
cat > "$QK/src/20-quiz.sh" <<'EOF'
run_quiz() {
  printf 'KIT-OK\n'
}
selftest_quiz() {
  printf 'SELFTEST-OK\n'
}
EOF
cat > "$QK/src/30-main.sh" <<'EOF'
if [ "$mode" = selftest ]; then
  selftest_quiz
else
  run_quiz
fi
EOF
mkdir -p "$STAGE/ws" "$STAGE/home"

# --- 4. inner script (runs inside the container; reads only its own env) ------
cat > "$STAGE/inner.sh" <<'EOF'
#!/bin/sh
# Inside-container driver. No secrets are embedded here; LLM_* come from env.
set -u
SELFTEST=${SMOKE_SELFTEST:-0}
R=/work/report
mkdir -p "$R"
note() { printf '%s\n' "$1" | tee -a "$R/progress.log"; }
die() { note "FAIL: $1"; exit 1; }

for c in jq curl python3 timeout; do
  command -v "$c" >/dev/null 2>&1 || die "inner: missing tool $c"
done

# credential env presence only — never values
for v in LLM_API_KEY LLM_API_URL LLM_MODEL; do
  eval "val=\${$v:-}"
  [ -n "$val" ] || die "inner: $v not injected into container"
  note "inner: $v present (length $(printf '%s' "$val" | wc -c | tr -d ' '))"
done

# no stray host credentials
for v in DEEPSEEK_API_KEY KIMI_API_KEY OPENAI_API_KEY ANTHROPIC_API_KEY; do
  eval "val=\${$v:-}"
  [ -z "$val" ] || die "inner: unexpected host credential leaked: $v"
done

PORT=${PACK_PORT:-8901}
python3 -m http.server "$PORT" --directory /work/stage/packs > "$R/packserver.log" 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT INT TERM
i=0
while [ "$i" -lt 50 ]; do
  curl -sS -o /dev/null "http://127.0.0.1:$PORT/agent/index.json" 2>/dev/null && break
  i=$((i + 1)); sleep 0.1
done
curl -sS "http://127.0.0.1:$PORT/agent/memory.json" | jq -e 'has("prompt")' >/dev/null \
  || die 'inner: pack server does not serve memory.json'
note 'inner: pack server ok'

# API reachability from inside the container (host extracted from env URL; no
# hostname is hardcoded here; expect any HTTP status, 000 = unreachable).
api_host=$(printf '%s' "$LLM_API_URL" | sed -n 's|^https\?://\([^/:]*\).*|\1|p')
code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 "https://$api_host/" 2>/dev/null || true)
if [ "$code" = 000 ]; then
  note "inner: WARNING api host unreachable from container ($api_host)"
else
  note "inner: api host reachable from container (status $code)"
fi

# Acceptance predicate sanity: broken build fails now, fixed build passes.
cd /work/ws/project/quizkit
if sh make.sh >/dev/null 2>&1; then die 'inner: broken quizkit unexpectedly builds'; fi
mkdir -p dist
sed 's/src\/40-main\.sh/src\/30-main.sh/' make.sh > make.fixed.sh
if sh make.fixed.sh > /dev/null 2>&1 && [ "$(sh dist/quiz.sh)" = KIT-OK ] \
   && [ "$(sh dist/quiz.sh --selftest)" = SELFTEST-OK ]; then
  note 'inner: acceptance predicate verified (fixed build passes)'
else
  die 'inner: acceptance predicate broken (fixed build does not pass)'
fi
rm -rf dist make.fixed.sh
cd /work

if [ "$SELFTEST" = 1 ]; then
  note 'inner: SELFTEST complete — no model call made'
  exit 0
fi

# --- real run --------------------------------------------------------------
# Offline mode: if the host passed SEED_PACK_ROOT (unreachable root), phase 1
# still installs and runs online from the local pack server; before phase 2
# the fetched memory pack is removed and the root flips to the unreachable
# value, so the maintain turn must fail the cold-start fetch.
OFFLINE_ROOT=${SEED_PACK_ROOT:-}
export SEED_HOME=/work/home HOME=/work/home SEED_MODE=agent SEED_SKIP_UPDATE=1
export SEED_PACK_ROOT="http://127.0.0.1:$PORT"
export AGENT_MAX_ROUNDS="${SMOKE_MAX_ROUNDS:-40}"
export AGENT_RUNS_DIR=/work/ws/.agent-runs
mkdir -p "$AGENT_RUNS_DIR"

TASK1='Repair the broken build in project/quizkit (relative to the launch workspace). Current state: cd project/quizkit && sh make.sh fails. Done means these three independently runnable launch-workspace commands all exit 0: cd project/quizkit && sh make.sh (and it prints built dist/quiz.sh); cd project/quizkit && sh dist/quiz.sh (and it prints KIT-OK); cd project/quizkit && sh dist/quiz.sh --selftest (and it prints SELFTEST-OK). Investigate the source parts under project/quizkit/src before editing; expect to need more than one attempt. After it works, run those exact three commands separately from the launch workspace to verify independently. At the end, if the three distill predicates hold, distill one candidate experience whose verify array contains those exact launch-workspace commands.'

cd /work/ws
note 'phase1: oneshot repair task (init + task + distill)'
timeout -k 60 "${SMOKE_TIMEOUT:-2700}" /bin/sh /work/stage/seed.sh --oneshot "$TASK1" \
  > "$R/phase1-transcript.log" 2>&1
p1=$?
note "phase1: seed exit $p1"

IDX=/work/home/agent-store/index.json
OBS=/work/home/agent-store/observations.json
STORE=/work/home/agent-store
ok=0
check() { # check <label> <cmd...>
  lbl=$1; shift
  if "$@" >/dev/null 2>&1; then note "ok: $lbl"; else note "FAIL: $lbl"; ok=1; fi
}
[ "$p1" -eq 0 ] || { note 'FAIL: phase1 seed exit nonzero'; ok=1; }
check 'index exists + ready' jq -e '.ready==true' "$IDX"
# Machine index v2: identity and the PATH sweep are the runtime's, so these
# assert seed.sh, not the model. capabilities/resources may legitimately be
# empty on a bare container — an empty capability list is a real answer.
check 'identity written by the runtime bootstrap' jq -e \
  '(.identity.os|length)>0 and (.identity.kernel|length)>0
   and (.identity.prereqs.jq.ok==true) and ((.identity.path_dirs|length)>0)' "$IDX"
check 'identity.os canonical lowercase' jq -e '.identity.os == (.identity.os|ascii_downcase)' "$IDX"
check 'index is v2 shaped' jq -e \
  '.version=="2" and (.capabilities|type)=="array" and (.resources|type)=="array"
   and (.agent.skills|type)=="array" and (.system|has("tools")|not)' "$IDX"
check 'PATH sweep landed in observations' jq -e \
  '([.observations[] | select(.source=="PATH")] | length) > 5' "$OBS"
check 'sweep rows carry no per-row timestamp' jq -e \
  '[.observations[] | select(.source=="PATH") | select(has("observed_at"))] | length == 0' "$OBS"
if jq -e '(.capabilities|length) > 0' "$IDX" >/dev/null 2>&1; then
  note "behavior: init registered $(jq -r '.capabilities|length' "$IDX") capabilities"
  check 'every registered capability carries the probe that verified it' jq -e \
    '[.capabilities[] | select(.ok==true) | select((.probe//"")=="")] | length == 0' "$IDX"
else
  note 'behavior: init registered no capabilities (allowed; discovery is task-driven)'
fi
cd /work/ws/project/quizkit
check 'make.sh exits 0 and prints built' sh -c 'sh make.sh 2>&1 | grep -q "built"'
check 'dist/quiz.sh prints KIT-OK' sh -c '[ "$(sh dist/quiz.sh)" = KIT-OK ]'
check 'selftest prints SELFTEST-OK' sh -c '[ "$(sh dist/quiz.sh --selftest)" = SELFTEST-OK ]'
cd /work/ws

EXPDIR=$STORE/experiences
cand=$(find "$EXPDIR" -name exp.json 2>/dev/null | head -1 || true)
if [ -n "$cand" ]; then
  eid=$(jq -r .id "$cand")
  st=$(jq -r .status "$cand")
  note "behavior: experience id=$eid status=$st after phase1 (pack requires candidate)"
  [ "$st" = candidate ] || { note 'FAIL: not candidate after distill task (same-task promote is forbidden)'; ok=1; }
  check 'exp.json schema (all 16 required fields)' jq -e --arg e "$eid" 'has("id") and has("kind") and has("title") and has("status") and has("version") and has("scope") and has("applies_if") and has("preconditions") and has("verify") and has("evidence") and has("successes") and has("failures") and has("created_at") and has("last_verified") and has("supersedes") and has("quarantine_reason") and .kind=="procedure" and .status=="candidate" and .id==$e and (.verify|length)>0 and (.scope|type)=="object" and .successes==0 and .failures==0' "$cand"
  check 'SKILL.md exists' test -f "$EXPDIR/$eid/SKILL.md"
  check 'catalog row exists' jq -e --arg e "$eid" '.experiences[]? | select(.id==$e)' "$EXPDIR/index.json"
  check 'candidate not ok:true in agent.skills' jq -e --arg e "$eid" '([.agent.skills[]? | select(.name==$e and .ok==true)] | length) == 0' "$IDX"
else
  note 'FAIL: no experience distilled after phase1 (also a behavior deviation)'
  eid=
  ok=1
fi
check 'evidence jsonl exists' test -n "$(find $STORE/runs -name '*.jsonl' 2>/dev/null | head -1)"
MP=$STORE/packs/memory.json
if [ -f "$MP" ]; then
  note 'behavior: memory pack fetched during phase1 (cold-start at distill)'
  check 'cold-start: fetched pack valid' jq -e 'has("prompt")' "$MP"
  check 'cold-start: byte-equal to pack source' cmp -s "$MP" /work/stage/packs/agent/memory.json
else
  note 'behavior: memory pack not fetched during phase1 — acceptable iff the candidate above is structurally compliant (minimal distill schema); maintain must still fetch or follow the loaded pack'
fi
leftover=$(find "$STORE" \( -name '*.tmp' -o -name '*.tmp.*' \) 2>/dev/null || true)
[ -z "$leftover" ] || { note "FAIL: leftover tmp files: $leftover"; ok=1; }
# did the model actually curl the pack (behavior, not assertion)?
if grep -q "agent/memory.json" "$R/phase1-transcript.log" 2>/dev/null; then
  note 'behavior: transcript references agent/memory.json (cold-start fetch path visible)'
else
  note 'behavior: transcript does not visibly reference agent/memory.json'
fi

if [ -n "$OFFLINE_ROOT" ]; then
  note "offline phase2: flipping SEED_PACK_ROOT to unreachable $OFFLINE_ROOT and removing the fetched memory pack"
  rm -f "$STORE/packs/memory.json"
  export SEED_PACK_ROOT="$OFFLINE_ROOT"
fi
note 'phase2: oneshot --maintain (promote + skills bridge)'
p2start=$(date -u +%Y-%m-%dT%H:%M:%SZ)
timeout -k 60 "${SMOKE_TIMEOUT:-2700}" /bin/sh /work/stage/seed.sh --oneshot "--maintain" \
  > "$R/phase2-transcript.log" 2>&1
p2=$?
note "phase2: seed exit $p2"
[ "$p2" -eq 0 ] || { note 'FAIL: phase2 seed exit nonzero'; ok=1; }
if [ -z "${eid:-}" ]; then
  late=$(find "$EXPDIR" -name exp.json 2>/dev/null | head -1 || true)
  if [ -n "$late" ]; then
    eid=$(jq -r .id "$late"); cand=$late
    note "behavior: experience $eid first appeared during maintain — phase1 distilled nothing (late distill)"
    check 'late-distill: SKILL.md exists' test -f "$EXPDIR/$eid/SKILL.md"
    check 'late-distill: evidence jsonl exists' test -n "$(find $STORE/runs -name '*.jsonl' 2>/dev/null | head -1)"
  fi
fi
if [ -n "${eid:-}" ]; then
  st=$(jq -r .status "$cand")
  note "behavior: experience status after maintain = $st (pack requires active)"
  [ "$st" = active ] || note 'behavior: DEVIATION — maintain did not promote'
  check 'promoted to active' test "$st" = active
  check 'successes >= 1' jq -e '.successes >= 1' "$cand"
  check 'last_verified set' jq -e '.last_verified != ""' "$cand"
  check 'catalog row active' jq -e --arg e "$eid" '.experiences[]? | select(.id==$e and .status=="active")' "$EXPDIR/index.json"
  # seed.sh owns this merge now: it must hold even when the model forgets.
  check 'registered ok:true in agent.skills' jq -e --arg e "$eid" '([.agent.skills[]? | select(.name==$e and .ok==true)] | length) == 1' "$IDX"
  created=$(jq -r .created_at "$cand")
  if [ -n "$created" ] && [ "$created" != null ] \
     && jq -n --arg a "$created" --arg b "$p2start" '$a < $b' | grep -q true; then
    note 'behavior: promoted candidate created_at < phase2 turn start (same-turn guardrail satisfiable)'
  else
    note "behavior: promoted candidate created_at ($created) not < phase2 start ($p2start) — same-turn promotion guardrail was violated or created_at malformed"
  fi
fi
if [ -n "$OFFLINE_ROOT" ]; then
  check 'offline: memory pack still absent (fetch failed)' test ! -f "$MP"
  if grep -Eq 'refused|Failed to connect|Could not connect|timed out|Connection' "$R/phase2-transcript.log" 2>/dev/null; then
    note 'behavior: phase2 transcript shows the failed cold-start fetch'
  else
    note 'behavior: phase2 transcript shows no visible fetch-failure text (check run messages)'
  fi
fi
if [ -n "$OFFLINE_ROOT" ]; then
  # a failed curl may leave an empty packs/memory tmp; not an atomicity fault
  leftover=$(find "$STORE" \( -name '*.tmp' -o -name '*.tmp.*' \) ! -path "*/packs/memory*" 2>/dev/null || true)
else
  leftover=$(find "$STORE" \( -name '*.tmp' -o -name '*.tmp.*' \) 2>/dev/null || true)
fi
[ -z "$leftover" ] || { note "FAIL: leftover tmp after maintain: $leftover"; ok=1; }

# A published experience is useful only if a later, separate task receives it
# through the runtime-owned English-keyword funnel and then loads SKILL.md.
# This is a real model turn, not a direct catalog-unit-test substitute.
if [ -n "${eid:-}" ] && [ "${st:-}" = active ]; then
  note 'phase3: English retrieval + progressive-disclosure reuse'
  before_exp_count=$(find "$EXPDIR" -mindepth 2 -maxdepth 2 -name exp.json \
    2>/dev/null | wc -l | tr -d ' ')
  before_make=$(cksum /work/ws/project/quizkit/make.sh)
  TASK3='Verify the repaired quizkit build using the matching build-repair experience. Read the matching SKILL.md first, then run all of its verification commands independently from the launch workspace. Do not edit files and do not distill another experience.'
  timeout -k 60 "${SMOKE_TIMEOUT:-2700}" /bin/sh /work/stage/seed.sh \
    --oneshot "$TASK3" > "$R/phase3-transcript.log" 2>&1
  p3=$?
  note "phase3: seed exit $p3"
  [ "$p3" -eq 0 ] || { note 'FAIL: phase3 seed exit nonzero'; ok=1; }
  p3msg=$(find "$AGENT_RUNS_DIR" -mindepth 2 -maxdepth 2 -name messages.json \
    -type f | sort | tail -1)
  check 'retrieval: active experience injected into system prompt' jq -e \
    --arg e "$eid" '.[0].role == "system" and (.[0].content | contains("<name>" + $e + "</name>"))' \
    "$p3msg"
  check 'retrieval: model loaded the injected SKILL.md' jq -e \
    --arg skill "$STORE/experiences/$eid/SKILL.md" '
      any(.[];
        .role == "assistant"
        and any(.tool_calls[]?;
          .function.name == "shell"
          and ((.function.arguments | fromjson | .command // "") | contains($skill))))
    ' "$p3msg"
  cd /work/ws/project/quizkit
  check 'reuse: make.sh still builds' sh -c 'sh make.sh 2>&1 | grep -q "built"'
  check 'reuse: dist/quiz.sh still prints KIT-OK' sh -c '[ "$(sh dist/quiz.sh)" = KIT-OK ]'
  check 'reuse: selftest still prints SELFTEST-OK' sh -c '[ "$(sh dist/quiz.sh --selftest)" = SELFTEST-OK ]'
  cd /work/ws
  after_make=$(cksum /work/ws/project/quizkit/make.sh)
  after_exp_count=$(find "$EXPDIR" -mindepth 2 -maxdepth 2 -name exp.json \
    2>/dev/null | wc -l | tr -d ' ')
  if [ "$before_make" = "$after_make" ] \
    && [ "$before_exp_count" = "$after_exp_count" ]; then
    note 'ok: retrieval reuse made no source edit and no duplicate experience'
  else
    note 'FAIL: retrieval reuse changed source or distilled a duplicate experience'
    ok=1
  fi
else
  note 'FAIL: phase3 retrieval prerequisite missing (no active experience)'
  ok=1
fi

# --- behavior evidence: sanitized copies ------------------------------------
# messages.json only — never the `h` Authorization header file or raw bodies.
n=0
for d in "$AGENT_RUNS_DIR"/*; do
  [ -d "$d" ] || continue
  [ -f "$d/messages.json" ] || continue
  n=$((n + 1))
  cp "$d/messages.json" "$R/run-$n-messages.json"
done
note "behavior: copied $n run messages.json files"
cp "$IDX" "$R/final-machine-index.json" 2>/dev/null || true
# The sweep can be hundreds of KB; keep the shape and a sample, not the bulk.
jq '{version, updated, count:(.observations|length),
     by_source:(.observations|group_by(.source)|map({source:.[0].source,n:length})),
     sample:(.observations[0:20])}' "$OBS" > "$R/final-observations-summary.json" 2>/dev/null || true
[ -f "$EXPDIR/index.json" ] && cp "$EXPDIR/index.json" "$R/final-experiences-index.json"
[ -n "${eid:-}" ] && cp -R "$EXPDIR/$eid" "$R/final-experience-$eid"

if [ "$ok" -eq 0 ]; then note 'RESULT: PASS (all assertions)'; else note 'RESULT: FAIL (see FAIL lines above)'; fi
exit "$ok"
EOF

# --- 5. run the container ------------------------------------------------------
# Bare -e KEY flags inherit from this process env: values never hit argv/files.
# Apple container default DNS (gateway forwarder) is dead; public resolver by IP works.
rc=0
container run --rm \
  --dns "${SMOKE_DNS:-1.1.1.1}" \
  --volume "$STAGE:/work" \
  -w /work \
  -e LLM_API_KEY -e LLM_API_URL -e LLM_MODEL \
  -e SMOKE_SELFTEST="$SELFTEST" \
  -e SMOKE_MAX_ROUNDS="$MAX_ROUNDS" \
  -e SMOKE_TIMEOUT="$TIMEOUT_SECS" \
  -e SEED_PACK_ROOT \
  "$IMAGE" /bin/sh /work/inner.sh || rc=$?

# --- 6. collect report + scrub credentials ------------------------------------
cp -R "$STAGE/report/." "$REPORT/" 2>/dev/null || true
if [ -n "${LLM_API_KEY:-}" ] && [ -d "$REPORT" ]; then
  contains_key() { # exit 0 iff the file contains the credential value
    KEY="$LLM_API_KEY" perl -ne '$m=1 if index($_,$ENV{KEY})>=0; END{exit($m?0:1)}' "$1" 2>/dev/null
  }
  found=
  for f in $(find "$REPORT" -type f 2>/dev/null); do
    if contains_key "$f"; then
      KEY="$LLM_API_KEY" perl -pi -e 's/\Q$ENV{KEY}\E/__REDACTED__/g' "$f"
      found="$found $f"
    fi
  done
  [ -z "$found" ] || printf 'smoke: scrubbed credential match out of:%s\n' "$found" >&2
  for f in $(find "$REPORT" -type f 2>/dev/null); do
    if contains_key "$f"; then
      fail 'smoke: credential still present in report after scrub'
    fi
  done
fi
printf 'smoke: report at %s\n' "$REPORT"
exit "$rc"
