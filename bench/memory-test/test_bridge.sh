#!/bin/sh
# Runtime experience publication gate. No model and no network.
set -eu
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO=${REPO_ROOT:-$(CDPATH= cd "$HERE/../.." && pwd)}
SEED_FILE=${SEED_FILE:-$REPO/seed.sh}

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$1"; }

FN=$(mktemp "${TMPDIR:-/tmp}/bridge-fn.XXXXXX")
for f in agent_state_lock_acquire agent_state_lock_release agent_experience_id_ok \
         agent_skill_file_ok agent_experience_record_ok agent_sync_experience_skills; do
  awk "/^$f\\(\\) \\{/,/^\\}/" "$SEED_FILE"
done > "$FN"
grep -q '^agent_sync_experience_skills()' "$FN" || fail 'could not extract bridge'
. "$FN"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/bridge.XXXXXX")
trap 'rm -rf "$WORK" "$FN"' EXIT INT TERM
INSTALL=$WORK
STORE=$WORK/agent-store
mkdir -p "$STORE/experiences" "$STORE/runs" "$WORK/accepted"

mkexp() { # id status title skill(yes|no) verifier(valid|noop)
  id=$1 st=$2 title=$3 skill=$4 mode=$5
  dir=$STORE/experiences/$id
  mkdir -p "$dir"
  verify="test -f $WORK/accepted/$id"
  [ "$mode" = valid ] || verify=true
  if [ "$st" = candidate ]; then
    successes=0
    last=
  else
    successes=1
    last=2026-08-25T00:01:00Z
  fi
  if [ "$skill" = yes ]; then
    printf '%s\n' '---' "name: $id" "description: $title" '---' '' "# $title" > "$dir/SKILL.md"
  fi
  : > "$WORK/accepted/$id"
  ev=agent-store/runs/$id.jsonl
  jq -nc --arg cmd "$verify" --arg id "$id" \
    '{utc:"2026-08-25T00:01:00Z",cmd:$cmd,exit:0,note:"accepted",exp_id:$id,
      authority:"seed-runtime",cwd:"launch-workspace",
      maintain_started:"2026-08-25T00:00:30Z"}' > "$INSTALL/$ev"
  jq -n --arg id "$id" --arg st "$st" --arg title "$title" --arg verify "$verify" \
    --arg ev "$ev" --arg last "$last" --argjson successes "$successes" \
    '{id:$id,kind:"procedure",title:$title,status:$st,version:1,
      scope:{os:[],tools:[],task_kinds:["build"]},applies_if:["build","repair"],
      preconditions:["workspace exists"],verify:[$verify],evidence:[$ev],
      successes:$successes,failures:0,created_at:"2026-08-25T00:00:00Z",
      last_verified:$last,supersedes:"",quarantine_reason:""}' > "$dir/exp.json"
}

mkexp live-one active 'Fix the live one' yes valid
mkexp no-body active 'Body went missing' no valid
mkexp warned degraded 'Warned but usable' yes valid
mkexp no-op active 'No-op verifier' yes noop
mkexp not-yet candidate 'Not promoted yet' yes valid
mkexp banned quarantined 'Failed twice' yes valid

jq -n '{version:"1",experiences:[]}' > "$STORE/experiences/index.json"
for id in live-one no-body warned no-op not-yet banned; do
  jq --slurpfile e "$STORE/experiences/$id/exp.json" \
    '.experiences += [($e[0] | {id,title,status,version,scope,applies_if,path:.id})]' \
    "$STORE/experiences/index.json" > "$STORE/experiences/index.next"
  mv "$STORE/experiences/index.next" "$STORE/experiences/index.json"
done

cat > "$STORE/index.json" <<'JSON'
{"ready":true,"version":"2","identity":{"os":"linux"},"capabilities":[],"resources":[],"agent":{"skills":[
 {"name":"mineru","description":"parse pdfs","path":"/skills/mineru/SKILL.md","ok":true,"note":""},
 {"name":"banned","description":"unrelated user skill","path":"/skills/banned/SKILL.md","ok":true,"note":""},
 {"name":"warned","description":"stale experience row","path":"/old/SKILL.md","ok":true,"source":"experience","status":"active","note":"experience active"},
 {"name":"banned-exp","description":"old experience","path":"/old/banned/SKILL.md","ok":true,"source":"experience","status":"active","note":"experience active"}
]},"system":{"retrieve":"x"},"ours":{}}
JSON
jq '.experiences += [{id:"banned-exp",title:"old experience",status:"quarantined",
  version:1,scope:{os:[],tools:[],task_kinds:[]},applies_if:["old"],path:"banned-exp"}]' \
  "$STORE/experiences/index.json" > "$STORE/experiences/index.next"
mv "$STORE/experiences/index.next" "$STORE/experiences/index.json"

agent_sync_experience_skills
IDX=$STORE/index.json
q() { jq -e "$1" "$IDX" >/dev/null 2>&1; }

q '.agent.skills[] | select(.name=="live-one") |
   .ok == true and .source == "experience" and .status == "active"
   and .description == "Fix the live one"
   and (.path | endswith("/experiences/live-one/SKILL.md"))' ||
  fail 'valid active record was not published'
ok 'valid active experience published'

q '.agent.skills[] | select(.name=="warned") |
   .ok == true and .source == "experience" and .status == "degraded"
   and .note == "experience degraded"' || fail 'degraded record was not refreshed'
q '([.agent.skills[] | select(.name=="warned")] | length) == 1' ||
  fail 'degraded row duplicated'
ok 'degraded experience refreshed with warning metadata'

q '([.agent.skills[] | select(.name=="no-body" and .ok==true)] | length) == 0' ||
  fail 'missing SKILL body became usable'
q '([.agent.skills[] | select(.name=="no-op" and .ok==true)] | length) == 0' ||
  fail 'no-op verifier became usable'
q '([.agent.skills[] | select(.name=="not-yet" and .ok==true)] | length) == 0' ||
  fail 'candidate became usable'
ok 'invalid and candidate records remain unpublished'

q '.agent.skills[] | select(.name=="banned") | .ok == true and .note == ""' ||
  fail 'dead experience disabled unrelated same-name skill'
q '.agent.skills[] | select(.name=="banned-exp") | .ok == false' ||
  fail 'dead experience-owned row remained usable'
q '.agent.skills[] | select(.name=="mineru") | .ok == true' ||
  fail 'unrelated skill was lost'
ok 'ownership and collision boundaries preserved'

before=$(jq -S -c '.agent.skills' "$IDX")
agent_sync_experience_skills
agent_sync_experience_skills
after=$(jq -S -c '.agent.skills' "$IDX")
[ "$before" = "$after" ] || fail 'bridge is not idempotent'
ok 'bridge is idempotent'

rm -rf "$STORE/experiences"
cp "$IDX" "$IDX.keep"
agent_sync_experience_skills
cmp -s "$IDX" "$IDX.keep" || fail 'cold start rewrote catalog'
ok 'missing experience tree is a no-op'

printf 'PASS: bridge (%s)\n' "${SEED_FILE##*/}"
