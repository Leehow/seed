#!/bin/sh
# Layer 2: mechanical lifecycle of memory.json jq flows. No LLM.
set -eu
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
. "$HERE/memory_ops.sh"

WORKDIR=${WORKDIR:-$(mktemp -d /tmp/mem-life.XXXXXX)}
ROOT=$WORKDIR/agent-store
MEMDIR=$WORKDIR/.agent-memory
INDEX=$ROOT/index.json
export ROOT MEMDIR INDEX

printf 'lifecycle: workdir %s\n' "$WORKDIR"

# --- 1. lazy dirs ---
lazy_memory_dirs
[ -d "$ROOT/experiences" ] || fail "lazy: experiences/ missing"
[ -d "$ROOT/runs" ] || fail "lazy: runs/ missing"
[ -f "$ROOT/rules.md" ] || fail "lazy: agent-store/rules.md missing"
[ -f "$MEMDIR/rules.md" ] || fail "lazy: .agent-memory/rules.md missing"
jq -e '.version=="1" and (.experiences|type=="array")' "$ROOT/experiences/index.json" >/dev/null \
  || fail "lazy: experiences/index.json schema"
assert_no_tmp
printf 'ok: lazy dirs\n'

mkdir -p "$ROOT"
printf '%s\n' '{
  "ready": true,
  "version": "1",
  "identity": {"os": "linux", "arch": "x86_64", "shell": "/bin/sh", "prereqs": {}, "scans": []},
  "capabilities": [
    {"name": "sh", "ok": true, "locator": "/bin/sh", "observed": true, "verified": true},
    {"name": "curl", "ok": true, "locator": "/usr/bin/curl", "observed": true, "verified": true},
    {"name": "jq", "ok": true, "locator": "/usr/bin/jq", "observed": true, "verified": true},
    {"name": "rg", "ok": true, "locator": "/usr/bin/rg", "observed": true, "verified": true},
    {"name": "git", "ok": false, "locator": "", "observed": false, "verified": false},
    {"name": "python", "ok": true, "locator": "/usr/bin/python3", "observed": true, "verified": true}
  ],
  "resources": [],
  "agent": {
    "skills": [{"name":"unrelated-skill","description":"keep me","path":"/tmp/unrelated","ok":true,"note":"hand-registered"}]
  },
  "system": {"retrieve": "x"},
  "ours": {}
}' | atomic_json "$INDEX"

# --- 2. write candidate exp.json + SKILL.md ---
TITLE="Print hello-ok via hello.sh" STATUS=candidate \
  OS_JSON='[]' TOOLS_JSON='["sh"]' KINDS_JSON='["toolchain"]' \
  APPLIES_JSON='["hello","verify","shell script"]' VERIFY_JSON='["true"]' \
  write_exp hello-ok

[ -f "$ROOT/experiences/hello-ok/exp.json" ] || fail "write: exp.json missing"
[ -f "$ROOT/experiences/hello-ok/SKILL.md" ] || fail "write: SKILL.md missing"
jq -e '.status=="candidate" and .kind=="procedure" and .id=="hello-ok"' \
  "$ROOT/experiences/hello-ok/exp.json" >/dev/null || fail "write: exp.json fields"
grep -q '^name: hello-ok$' "$ROOT/experiences/hello-ok/SKILL.md" || fail "write: SKILL.md frontmatter"
jq -e '.experiences[] | select(.id=="hello-ok" and .status=="candidate" and .path=="experiences/hello-ok")' \
  "$ROOT/experiences/index.json" >/dev/null || fail "write: index row"
assert_no_tmp
printf 'ok: write candidate\n'

# --- 3. register agent.skills (candidate must not be ok:true) ---
register_skills
cand_ok=$(jq '[.agent.skills[] | select(.name=="hello-ok" and .ok==true)] | length' "$INDEX")
assert_eq "$cand_ok" "0" "register: candidate must not be ok:true in agent.skills"
kept=$(jq '[.agent.skills[] | select(.name=="unrelated-skill" and .ok==true)] | length' "$INDEX")
assert_eq "$kept" "1" "register: merge must keep unrelated skill"
assert_no_tmp
printf 'ok: register skills (candidate hidden)\n'

# --- 4. maintain promote candidate -> active ---
promote_candidates
register_skills
st=$(jq -r .status "$ROOT/experiences/hello-ok/exp.json")
assert_eq "$st" "active" "promote: status"
succ=$(jq -r .successes "$ROOT/experiences/hello-ok/exp.json")
[ "$succ" -ge 1 ] || fail "promote: successes should be >=1, got $succ"
lv=$(jq -r .last_verified "$ROOT/experiences/hello-ok/exp.json")
[ -n "$lv" ] || fail "promote: last_verified empty"
skill_n=$(jq '[.agent.skills[] | select(.name=="hello-ok" and .ok==true)] | length' "$INDEX")
assert_eq "$skill_n" "1" "promote: active must register ok:true skill"
skill_path=$(jq -r '.agent.skills[] | select(.name=="hello-ok") | .path' "$INDEX")
assert_eq "$skill_path" "$ROOT/experiences/hello-ok" "promote: skill path is experience dir"
kept=$(jq '[.agent.skills[] | select(.name=="unrelated-skill" and .ok==true)] | length' "$INDEX")
assert_eq "$kept" "1" "promote: merge must keep unrelated skill"
assert_no_tmp
printf 'ok: promote to active + skill bridge\n'

TITLE="Windows only method" STATUS=active \
  OS_JSON='["windows"]' TOOLS_JSON='[]' APPLIES_JSON='["hello","verify"]' \
  VERIFY_JSON='["true"]' SUCC=1 LAST_VERIFIED="$(utc_now)" \
  write_exp win-only
TITLE="Still a draft" STATUS=candidate \
  OS_JSON='[]' TOOLS_JSON='[]' APPLIES_JSON='["hello","verify"]' \
  write_exp still-draft
# Mixed-case scope.os must be stored lowercase and still match Linux via the map.
TITLE="Linux scoped method" STATUS=active \
  OS_JSON='["Linux"]' TOOLS_JSON='[]' APPLIES_JSON='["zxqv-linux-only"]' \
  VERIFY_JSON='["true"]' SUCC=1 LAST_VERIFIED="$(utc_now)" \
  write_exp linux-hello
linux_os=$(jq -c '.scope.os' "$ROOT/experiences/linux-hello/exp.json")
assert_eq "$linux_os" '["linux"]' "write: scope.os stored lowercase"

# --- 5. funnel ---
hits=$(funnel "hello verify shell")
printf 'funnel hits: %s\n' "$hits"
echo "$hits" | jq empty || fail "funnel: output is not JSON"
n=$(echo "$hits" | jq 'length')
assert_eq "$n" "1" "funnel: expected exactly 1 visible hit"
hid=$(echo "$hits" | jq -r '.[0].id')
assert_eq "$hid" "hello-ok" "funnel: hit id"
keys=$(echo "$hits" | jq -r '.[0] | keys | sort | join(",")')
assert_eq "$keys" "applies_if,id,path,scope,status,title" "funnel: metadata keys only"
echo "$hits" | jq -e 'all(.[]; .id != "still-draft" and .status != "candidate")' >/dev/null \
  || fail "funnel: candidate visible"
echo "$hits" | jq -e 'all(.[]; .id != "win-only")' >/dev/null \
  || fail "funnel: scope-mismatched entry visible"
printf '%s' "$hits" | grep -q 'When to use' && fail "funnel: leaked SKILL.md body"
# stopwords / single-char tokens are ignored
hits=$(funnel "a to the x")
n=$(echo "$hits" | jq 'length')
assert_eq "$n" "0" "funnel: stopwords and single-char must not match"
# defined tokenizer: last-message tokens vs title/applies_if substring
hits=$(funnel "need zxqv-linux-only please")
n=$(echo "$hits" | jq 'length')
assert_eq "$n" "1" "funnel: linux-scoped applies_if token"
hid=$(echo "$hits" | jq -r '.[0].id')
assert_eq "$hid" "linux-hello" "funnel: Linux env maps to linux scope"
printf 'ok: funnel filters\n'

# --- 6. use-fail once -> degraded ---
record_use hello-ok 1
register_skills
st=$(jq -r .status "$ROOT/experiences/hello-ok/exp.json")
assert_eq "$st" "degraded" "use-fail1: status"
hits=$(funnel "hello verify")
echo "$hits" | jq -e 'any(.[]; .id=="hello-ok" and .status=="degraded")' >/dev/null \
  || fail "use-fail1: degraded should stay visible"
deg_ok=$(jq '[.agent.skills[] | select(.name=="hello-ok" and .ok==true)] | length' "$INDEX")
assert_eq "$deg_ok" "1" "use-fail1: degraded stays ok:true in skills"
assert_no_tmp
printf 'ok: fail once -> degraded\n'

# --- 7. use-fail again -> quarantined ---
record_use hello-ok 1
register_skills
st=$(jq -r .status "$ROOT/experiences/hello-ok/exp.json")
assert_eq "$st" "quarantined" "use-fail2: status"
qr=$(jq -r .quarantine_reason "$ROOT/experiences/hello-ok/exp.json")
[ -n "$qr" ] || fail "use-fail2: quarantine_reason empty"
hits=$(funnel "hello verify")
echo "$hits" | jq -e 'all(.[]; .id != "hello-ok")' >/dev/null \
  || fail "use-fail2: quarantined must be invisible"
q_ok=$(jq '[.agent.skills[] | select(.name=="hello-ok" and .ok==true)] | length' "$INDEX")
assert_eq "$q_ok" "0" "use-fail2: quarantined must not remain ok:true"
assert_no_tmp
printf 'ok: fail twice -> quarantined\n'

# --- 8. tool drift -> stale ---
TITLE="Ripgrep search method" STATUS=active \
  OS_JSON='[]' TOOLS_JSON='["rg"]' APPLIES_JSON='["search","ripgrep"]' \
  VERIFY_JSON='["true"]' SUCC=1 LAST_VERIFIED="$(utc_now)" \
  write_exp rg-search
register_skills
st=$(jq -r .status "$ROOT/experiences/rg-search/exp.json")
assert_eq "$st" "active" "stale-setup: rg-search active"
jq '.capabilities = (.capabilities | map(if .name=="rg" then .ok=false | .verified=false | .note="binary missing after environment update" else . end))' "$INDEX" | atomic_json "$INDEX"
mark_stale_all
register_skills
st=$(jq -r .status "$ROOT/experiences/rg-search/exp.json")
assert_eq "$st" "stale" "tool-drift: status"
hits=$(funnel "search ripgrep")
echo "$hits" | jq -e 'all(.[]; .id != "rg-search")' >/dev/null \
  || fail "tool-drift: stale must be invisible"
s_ok=$(jq '[.agent.skills[] | select(.name=="rg-search" and .ok==true)] | length' "$INDEX")
assert_eq "$s_ok" "0" "tool-drift: stale must not remain ok:true"
kept=$(jq '[.agent.skills[] | select(.name=="unrelated-skill" and .ok==true)] | length' "$INDEX")
assert_eq "$kept" "1" "tool-drift: merge must keep unrelated skill"
assert_no_tmp
printf 'ok: tool drift -> stale\n'

# --- 8b. live vs non-live stale ---
# git is already ok:false. candidate is live -> stale; quarantined is not live.
TITLE="Git candidate method" STATUS=candidate \
  OS_JSON='[]' TOOLS_JSON='["git"]' APPLIES_JSON='["git-candidate"]' \
  write_exp git-cand
TITLE="Already quarantined git" STATUS=quarantined \
  OS_JSON='[]' TOOLS_JSON='["git"]' APPLIES_JSON='["git-quarantine"]' \
  FAIL=3 SUCC=0 \
  write_exp git-quar
mark_stale_all
st=$(jq -r .status "$ROOT/experiences/git-cand/exp.json")
assert_eq "$st" "stale" "live-stale: candidate participates"
st=$(jq -r .status "$ROOT/experiences/git-quar/exp.json")
assert_eq "$st" "quarantined" "live-stale: quarantined does not become stale"
printf 'ok: live status stale check\n'

# --- 9. atomic write: dest stays valid JSON, no leftover dest.tmp.$$ ---
printf '{not json' > "$ROOT/experiences/index.json.tmp.$$"
rm -f "$ROOT/experiences/index.json.tmp.$$"
TITLE="Atomic probe" STATUS=candidate write_exp atomic-probe
assert_no_tmp
jq empty "$ROOT/experiences/index.json" || fail "atomic: dest index is not valid JSON"
jq empty "$ROOT/experiences/atomic-probe/exp.json" || fail "atomic: dest exp.json is not valid JSON"
# failed atomic must not clobber dest
cp "$ROOT/experiences/index.json" "$ROOT/experiences/index.json.bak"
if printf '{not json' | atomic_json "$ROOT/experiences/index.json" 2>/dev/null; then
  fail "atomic: invalid JSON should not replace dest"
fi
jq empty "$ROOT/experiences/index.json" || fail "atomic: dest corrupted after failed write"
assert_no_tmp
printf 'ok: atomic write no leftover tmp\n'

printf 'PASS: lifecycle\n'
