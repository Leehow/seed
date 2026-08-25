#!/bin/sh
# Seed v2 kernel regressions: index/memory publication, concurrency, project
# memory initialization, and deterministic /ini. No network or real model.
set -eu

ROOT=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)
SEED=$ROOT/seed.sh
fail=0
T=$(mktemp -d "${TMPDIR:-/tmp}/seed-kernel.XXXXXX")
T=$(CDPATH= cd "$T" && pwd -P)
trap 'rm -rf "$T"' EXIT HUP INT TERM

ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; fail=$((fail + 1)); }

extract() {
  name=$1
  awk "/^$name\(\) \{/,/^\}/" "$SEED"
}

write_skill() {
  dir=$1
  id=$2
  title=$3
  mkdir -p "$dir"
  printf '%s\n' '---' "name: $id" "description: $title" '---' '' "# $title" > "$dir/SKILL.md"
}

write_experience() {
  store=$1
  id=$2
  status=$3
  title=$4
  os_json=$5
  tools_json=$6
  applies_json=$7
  if [ "$#" -ge 8 ]; then
    verify_json=$8
  else
    verify_json=$(jq -nc --arg v "test -f agent-store/experiences/$id/SKILL.md" '[$v]')
  fi
  dir=$store/experiences/$id
  write_skill "$dir" "$id" "$title"
  mkdir -p "$store/runs"
  ev="agent-store/runs/$id.jsonl"
  : > "$store/runs/$id.jsonl"
  printf '%s' "$verify_json" | jq -r '.[]' | while IFS= read -r ev_cmd; do
    jq -nc --arg cmd "$ev_cmd" --arg id "$id" \
      '{utc:"2026-08-25T00:01:00Z",cmd:$cmd,exit:0,note:"accepted",exp_id:$id,
        authority:"seed-runtime",cwd:"launch-workspace",
        maintain_started:"2026-08-25T00:00:30Z"}' \
      >> "$store/runs/$id.jsonl"
  done
  successes=1
  last_verified=2026-08-25T00:01:00Z
  if [ "$status" = candidate ]; then
    successes=0
    last_verified=
  fi
  jq -n --arg id "$id" --arg st "$status" --arg title "$title" \
    --argjson os "$os_json" --argjson tools "$tools_json" \
    --argjson applies "$applies_json" --argjson verify "$verify_json" --arg ev "$ev" \
    --argjson successes "$successes" --arg last "$last_verified" \
    '{id:$id,kind:"procedure",title:$title,status:$st,version:1,
      scope:{os:$os,tools:$tools,task_kinds:["build"]},applies_if:$applies,
      preconditions:["workspace exists"],verify:$verify,evidence:[$ev],
      successes:$successes,failures:0,created_at:"2026-08-25T00:00:00Z",
      last_verified:$last,supersedes:"",quarantine_reason:""}' \
    > "$dir/exp.json"
}

base_index() {
  jq -n '{ready:true,version:"2",updated:"",identity:{os:"linux",kernel:"Linux",
      arch:"x86_64",shell:"/bin/sh",home:"/tmp",path_dirs:[],
      prereqs:{sh:{path:"/bin/sh",ok:true,probe:""},curl:{path:"/usr/bin/curl",ok:true,probe:""},jq:{path:"/usr/bin/jq",ok:true,probe:""}},scans:[]},
    capabilities:[{id:"local:sh",name:"sh",kind:"cli",locator:"/bin/sh",purpose:[],
      use:"sh",needs:[],observed:true,understood:true,verified:true,ok:true,probe:"",
      evidence:[],observed_at:"",verified_at:"",scope:[],skill:"",note:""}],
    resources:[],agent:{skills:[]},system:{retrieve:"retrieve",web:{}},ours:{}}'
}

/bin/sh -n "$SEED" && ok 'runtime syntax' || bad 'runtime syntax'

if grep -q '^SEED_VERSION=2$' "$SEED"; then ok 'runtime version is v2'; else bad 'runtime version is v2'; fi

if ! grep -q -- '-maxdepth' "$SEED"; then ok 'PATH sweep is POSIX'; else bad 'PATH sweep is POSIX'; fi

if jq -e . "$ROOT/packs/agent/index.json" "$ROOT/packs/agent/init.json" \
    "$ROOT/packs/agent/memory.json" >/dev/null 2>&1 \
  && jq -r '(.required // {}) + (.optional // {}) | .[]' "$ROOT/packs/agent/index.json" \
     | while IFS= read -r rel; do test -f "$ROOT/packs/agent/$rel"; done; then
  ok 'agent catalog closes over source files'
else
  bad 'agent catalog closes over source files'
fi

if python3 - "$ROOT" <<'PY'
import glob
import json, sys
root = sys.argv[1]
def strings(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for item in value.values():
            yield from strings(item)
    elif isinstance(value, list):
        for item in value:
            yield from strings(item)
for path in glob.glob(root + "/packs/agent/*.json"):
    obj = json.load(open(path, encoding="utf-8"))
    for text in strings(obj):
        if any("CJK" in __import__("unicodedata").name(ch, "") for ch in text):
            raise SystemExit(1)
PY
then ok 'internal agent packs are English-only'; else bad 'internal agent packs are English-only'; fi

if ! grep -E 'system\.(tools|resources|other|skills|env)' "$ROOT"/packs/agent/*.json \
    >/dev/null 2>&1; then
  ok 'agent packs use only the v2 index namespaces'
else
  bad 'agent packs use only the v2 index namespaces'
fi

if jq -e '.prompt
    | contains("Every verify command must be independently executable")
      and contains("launch workspace")
      and contains("Never use mkdir -p to claim the lock")
      and contains("append evidence with jq -nc --arg cmd")
      and contains("A status string of active is not success")
      and contains("never sent to the model")
      and contains("authority seed-runtime")
      and contains("fresh shell rooted at Seed")
      and contains("deterministically canonicalizes only unambiguous")' \
    "$ROOT/packs/agent/memory.json" >/dev/null 2>&1; then
  ok 'memory policy rejects cwd-dependent and fabricated promotion evidence'
else
  bad 'memory policy rejects cwd-dependent and fabricated promotion evidence'
fi

FN=$T/functions.sh
for fn in agent_state_lock_acquire agent_state_lock_release agent_experience_id_ok \
  agent_skill_file_ok agent_skill_file_repairable agent_experience_candidate_ok \
  agent_experience_tools_ok \
  agent_experience_mark_stale agent_experience_requeue_legacy \
  agent_experience_normalize_candidate agent_run_verifier agent_maintain_one \
  agent_maintain_experiences agent_experience_record_ok agent_sync_experience_skills \
  skill_catalog agent_check_machine_tree agent_migrate_index_v2 agent_os_token \
  agent_prereq_json agent_sweep_path agent_bootstrap_machine agent_init_pack_ok \
  agent_fetch_pack agent_fetch_required; do
  extract "$fn" >> "$FN"
done

if grep -q '^agent_sync_experience_skills()' "$FN"; then
  # Traversal IDs and malformed/no-op experiences must never become usable skills.
  INSTALL=$T/security
  store=$INSTALL/agent-store
  mkdir -p "$store/experiences" "$T/security/outside"
  base_index > "$store/index.json"
  write_skill "$T/security/outside" outside 'Outside skill'
  jq -n '{version:"1",experiences:[
    {id:"../../outside",title:"Outside skill",status:"active",version:1,
     scope:{os:[],tools:[],task_kinds:[]},applies_if:["outside"],path:"outside"}]}' \
    > "$store/experiences/index.json"
  . "$FN"

  # Kernel maintenance is deterministic and model-free. Override only the
  # process wrapper in this extracted-function test; the production wrapper
  # adds timeout/output capture around this same launch-workspace execution.
  (
    maintain_sub_fail=0
    agent_run_verifier() {
      (CDPATH= cd "$LAUNCH_CWD" && /bin/sh -c "$1") >/dev/null 2>&1
    }

    INSTALL=$T/runtime-maintain
    store=$INSTALL/agent-store
    LAUNCH_CWD=$T/runtime-maintain-workspace
    mkdir -p "$store/experiences" "$store/runs" "$LAUNCH_CWD/project/good" \
      "$LAUNCH_CWD/project/cwd-only"
    : > "$LAUNCH_CWD/project/good/accepted"
    printf '%s\n' '#!/bin/sh' 'exit 0' > "$LAUNCH_CWD/project/cwd-only/make.sh"
    base_index > "$store/index.json"
    write_experience "$store" runtime-promote candidate 'Runtime promotion' '[]' '[]' \
      '["runtime promotion"]' '["test -f project/good/accepted"]'
    jq -n --slurpfile e "$store/experiences/runtime-promote/exp.json" \
      '{version:"1",experiences:[($e[0] | {id,title,status,version,scope,applies_if,path:.id})]}' \
      > "$store/experiences/index.json"
    SEED_RUN_MODE=agent
    if agent_maintain_experiences \
      && jq -e '.status == "active" and .successes == 1 and .last_verified != ""' \
        "$store/experiences/runtime-promote/exp.json" >/dev/null \
      && jq -e '.agent.skills[]? | select(.name == "runtime-promote" and .ok == true)' \
        "$store/index.json" >/dev/null \
      && ev=$(jq -r '.evidence[] | select(startswith("agent-store/runs/maintain-"))' \
        "$store/experiences/runtime-promote/exp.json") \
      && jq -e '.authority == "seed-runtime" and .cwd == "launch-workspace"
        and .cmd == "test -f project/good/accepted" and .exit == 0' \
        "$INSTALL/$ev" >/dev/null; then
      ok 'runtime owns verifier evidence and candidate promotion'
    else
      bad 'runtime owns verifier evidence and candidate promotion'
      maintain_sub_fail=1
    fi

    write_experience "$store" legacy-active active 'Legacy active record' '[]' '[]' \
      '["legacy record"]' '["test -f project/good/accepted"]'
    jq 'del(.authority,.cwd,.maintain_started)' "$store/runs/legacy-active.jsonl" \
      > "$store/runs/legacy-active.next"
    mv "$store/runs/legacy-active.next" "$store/runs/legacy-active.jsonl"
    jq --slurpfile e "$store/experiences/legacy-active/exp.json" \
      '.experiences += [($e[0] | {id,title,status,version,scope,applies_if,path:.id})]' \
      "$store/experiences/index.json" > "$store/experiences/index.next"
    mv "$store/experiences/index.next" "$store/experiences/index.json"
    if agent_maintain_experiences \
      && jq -e '.status == "active" and
          any(.evidence[]; startswith("agent-store/runs/maintain-"))' \
        "$store/experiences/legacy-active/exp.json" >/dev/null; then
      ok 'legacy active evidence is reverified, not grandfathered'
    else
      bad 'legacy active evidence is reverified, not grandfathered'
      maintain_sub_fail=1
    fi

    normalize_verify=$(jq -nc \
      --arg a "cd $LAUNCH_CWD/project/good && test -f accepted" \
      --arg b 'cd project/good && test -f accepted' \
      --arg c 'test -f project/good/accepted' \
      --arg d "cd $LAUNCH_CWD && cd project/good && test -f accepted" \
      '[$a,$b,$c,$d]')
    write_experience "$store" normalize-candidate candidate 'Canonical candidate' '[]' '[]' \
      '[]' "$normalize_verify"
    awk '{sub(/^description: Canonical candidate$/, "description: Canonical candidate."); print}' \
      "$store/experiences/normalize-candidate/SKILL.md" \
      > "$store/experiences/normalize-candidate/SKILL.next"
    mv "$store/experiences/normalize-candidate/SKILL.next" \
      "$store/experiences/normalize-candidate/SKILL.md"
    jq --slurpfile e "$store/experiences/normalize-candidate/exp.json" \
      '.experiences += [($e[0] | {id,title,status,version,scope,applies_if,path:.id})]' \
      "$store/experiences/index.json" > "$store/experiences/index.next"
    mv "$store/experiences/index.next" "$store/experiences/index.json"
    if agent_maintain_experiences \
      && jq -e '.status == "active"
          and .verify == ["cd project/good && test -f accepted",
                          "cd project/good && test -f accepted",
                          "test -f project/good/accepted",
                          "cd project/good && test -f accepted"]' \
        "$store/experiences/normalize-candidate/exp.json" >/dev/null \
      && grep -qx 'description: Canonical candidate' \
        "$store/experiences/normalize-candidate/SKILL.md"; then
      ok 'runtime canonicalizes unambiguous title and launch-cwd metadata'
    else
      bad 'runtime canonicalizes unambiguous title and launch-cwd metadata'
      maintain_sub_fail=1
    fi

    write_experience "$store" missing-frontmatter candidate \
      'Missing frontmatter candidate' '[]' '[]' '[]' \
      '["test -f project/good/accepted"]'
    sed -n '5,$p' "$store/experiences/missing-frontmatter/SKILL.md" \
      > "$store/experiences/missing-frontmatter/SKILL.next"
    mv "$store/experiences/missing-frontmatter/SKILL.next" \
      "$store/experiences/missing-frontmatter/SKILL.md"
    jq '.evidence |= map(sub("^agent-store/"; ""))' \
      "$store/experiences/missing-frontmatter/exp.json" \
      > "$store/experiences/missing-frontmatter/exp.next"
    mv "$store/experiences/missing-frontmatter/exp.next" \
      "$store/experiences/missing-frontmatter/exp.json"
    jq --slurpfile e "$store/experiences/missing-frontmatter/exp.json" \
      '.experiences += [($e[0] | {id,title,status,version,scope,applies_if,
        path:("experiences/" + .id)})]' \
      "$store/experiences/index.json" > "$store/experiences/index.next"
    mv "$store/experiences/index.next" "$store/experiences/index.json"
    if agent_maintain_experiences \
      && jq -e '.status == "active"' \
        "$store/experiences/missing-frontmatter/exp.json" >/dev/null \
      && sed -n '1,4p' "$store/experiences/missing-frontmatter/SKILL.md" \
        | grep -qx -- '---' \
      && grep -qx 'name: missing-frontmatter' \
        "$store/experiences/missing-frontmatter/SKILL.md" \
      && grep -qx 'description: Missing frontmatter candidate' \
        "$store/experiences/missing-frontmatter/SKILL.md" \
      && jq -e '.evidence | any(. == "agent-store/runs/missing-frontmatter.jsonl")' \
        "$store/experiences/missing-frontmatter/exp.json" >/dev/null \
      && jq -e '.experiences[] | select(.id == "missing-frontmatter")
        | .path == "missing-frontmatter"' "$store/experiences/index.json" \
        >/dev/null; then
      ok 'runtime canonicalizes missing frontmatter and store-relative paths'
    else
      bad 'runtime canonicalizes missing frontmatter and store-relative paths'
      maintain_sub_fail=1
    fi

    printf '%s\n' '---' 'name: conflicting-name' \
      'description: Conflicting metadata' '---' \
      > "$T/conflicting-skill.md"
    if agent_skill_file_repairable "$T/conflicting-skill.md" expected-name; then
      bad 'runtime rejects present conflicting skill frontmatter'
      maintain_sub_fail=1
    else
      ok 'runtime rejects present conflicting skill frontmatter'
    fi

    write_experience "$store" cwd-dependent candidate 'Cwd dependent verifier' '[]' '[]' \
      '["cwd verifier"]' '["sh make.sh"]'
    jq --slurpfile e "$store/experiences/cwd-dependent/exp.json" \
      '.experiences += [($e[0] | {id,title,status,version,scope,applies_if,path:.id})]' \
      "$store/experiences/index.json" > "$store/experiences/index.next"
    mv "$store/experiences/index.next" "$store/experiences/index.json"
    if agent_maintain_experiences >/dev/null 2>&1; then
      bad 'runtime rejects a persistent-shell cwd verifier'
      maintain_sub_fail=1
    elif jq -e '.status == "candidate" and (.evidence | length) == 1' \
        "$store/experiences/cwd-dependent/exp.json" >/dev/null; then
      ok 'runtime rejects a persistent-shell cwd verifier'
    else
      bad 'runtime rejects a persistent-shell cwd verifier'
      maintain_sub_fail=1
    fi
    [ "$maintain_sub_fail" -eq 0 ]
  ) || bad 'runtime maintenance regressions'

  # An upgraded runtime must not accept the old v1 init template and then use
  # it to downgrade a migrated v2 index. A stale cache is refreshed before the
  # repair template is consumed.
  (
    INSTALL=$T/pack-upgrade/state
    mkdir -p "$INSTALL/agent-store/packs"
    printf '%s\n' '{"required":{"init":"init.json"}}' \
      > "$INSTALL/agent-store/catalog.json"
    printf '%s\n' \
      '{"prompt":"old","machine_tree":{"version":"1"},"memory_tree":{}}' \
      > "$INSTALL/agent-store/packs/init.json"
    pack_root() { printf '%s\n' mock-root; }
    pack_join() { printf '%s/%s\n' "$1" "$2"; }
    agent_pack_get() {
      case $1 in
        */index.json) cat "$ROOT/packs/agent/index.json" ;;
        */init.json) cat "$ROOT/packs/agent/init.json" ;;
        *) return 1 ;;
      esac
    }
    die() { printf 'error: %s\n' "$1" >&2; exit "${2:-70}"; }
    agent_fetch_required
    agent_init_pack_ok "$INSTALL/agent-store/packs/init.json"
  ) && ok 'stale v1 init pack is refreshed before v2 repair' \
    || bad 'stale v1 init pack is refreshed before v2 repair'

  agent_sync_experience_skills || true
  if ! jq -e '.agent.skills[]? | select(.name == "../../outside" and .ok == true)' \
      "$store/index.json" >/dev/null 2>&1; then
    ok 'experience traversal is rejected'
  else
    bad 'experience traversal is rejected'
  fi

  rm -rf "$store/experiences"
  mkdir -p "$store/experiences/bad-skill"
  printf '# missing frontmatter\n' > "$store/experiences/bad-skill/SKILL.md"
  jq -n '{id:"bad-skill",kind:"procedure",title:"Bad skill",status:"active",version:1,
    scope:{os:[],tools:[],task_kinds:[]},applies_if:["bad"],preconditions:[],verify:["true"],
    evidence:[],successes:1,failures:0,created_at:"2026-08-25T00:00:00Z",
    last_verified:"2026-08-25T00:01:00Z",supersedes:"",quarantine_reason:""}' \
    > "$store/experiences/bad-skill/exp.json"
  jq -n '{version:"1",experiences:[{id:"bad-skill",title:"Bad skill",status:"active",
    version:1,scope:{os:[],tools:[],task_kinds:[]},applies_if:["bad"],path:"bad-skill"}]}' \
    > "$store/experiences/index.json"
  base_index > "$store/index.json"
  agent_sync_experience_skills || true
  if ! jq -e '.agent.skills[]? | select(.name == "bad-skill" and .ok == true)' \
      "$store/index.json" >/dev/null 2>&1; then
    ok 'invalid skill and no-op verifier are rejected'
  else
    bad 'invalid skill and no-op verifier are rejected'
  fi

  # Ambiguous YAML and symlinked evidence are both containment failures.
  rm -rf "$store/experiences" "$store/runs"
  mkdir -p "$store/experiences" "$store/runs"
  write_experience "$store" duplicate-yaml active 'Duplicate YAML' '[]' '[]' '["duplicate"]'
  awk 'NR == 3 { print "name: duplicate-yaml" } { print }' \
    "$store/experiences/duplicate-yaml/SKILL.md" \
    > "$store/experiences/duplicate-yaml/SKILL.next"
  mv "$store/experiences/duplicate-yaml/SKILL.next" \
    "$store/experiences/duplicate-yaml/SKILL.md"
  write_experience "$store" linked-proof active 'Linked proof' '[]' '[]' '["linked"]'
  mv "$store/runs/linked-proof.jsonl" "$T/linked-proof.jsonl"
  ln -s "$T/linked-proof.jsonl" "$store/runs/linked-proof.jsonl"
  cjk_fixture=$(printf '\344\270\255\346\226\207')
  write_experience "$store" non-english active "Internal $cjk_fixture record" '[]' '[]' '["record"]'
  write_experience "$store" mismatched-title active 'Catalog title' '[]' '[]' '["title"]'
  awk '{sub(/^description: Catalog title$/, "description: Different title"); print}' \
    "$store/experiences/mismatched-title/SKILL.md" \
    > "$store/experiences/mismatched-title/SKILL.next"
  mv "$store/experiences/mismatched-title/SKILL.next" \
    "$store/experiences/mismatched-title/SKILL.md"
  jq -n '{version:"1",experiences:[]}' > "$store/experiences/index.json"
  for id in duplicate-yaml linked-proof non-english mismatched-title; do
    jq --slurpfile e "$store/experiences/$id/exp.json" \
      '.experiences += [($e[0] | {id,title,status,version,scope,applies_if,path:.id})]' \
      "$store/experiences/index.json" > "$store/experiences/index.next"
    mv "$store/experiences/index.next" "$store/experiences/index.json"
  done
  base_index > "$store/index.json"
  agent_sync_experience_skills || true
  if ! jq -e '.agent.skills[]? | select(
      (.name == "duplicate-yaml" or .name == "linked-proof" or .name == "non-english"
       or .name == "mismatched-title")
      and .ok == true)' \
      "$store/index.json" >/dev/null 2>&1; then
    ok 'ambiguous, mismatched, symlinked, and non-English experiences are rejected'
  else
    bad 'ambiguous, mismatched, symlinked, and non-English experiences are rejected'
  fi

  # The catalog itself is the single retrieval funnel: scope, status, English
  # keyword match, and degraded warning are applied before prompt injection.
  rm -rf "$store/experiences"
  mkdir -p "$store/experiences"
  write_experience "$store" build-repair active 'Repair build pipeline' '[]' '[]' '["repair build"]'
  write_experience "$store" fragile-build degraded 'Fragile build repair' '[]' '[]' '["repair build"]'
  write_experience "$store" wrong-os active 'Windows build repair' '["windows"]' '[]' '["repair build"]'
  write_experience "$store" missing-tool active 'Ghost build repair' '[]' '["ghost"]' '["repair build"]'
  write_experience "$store" unrelated active 'Database migration' '[]' '[]' '["database"]'
  jq -n '{version:"1",experiences:[]}' > "$store/experiences/index.json"
  for id in build-repair fragile-build wrong-os missing-tool unrelated; do
    jq --slurpfile e "$store/experiences/$id/exp.json" \
      '.experiences += [($e[0] | {id,title,status,version,scope,applies_if,path:.id})]' \
      "$store/experiences/index.json" > "$store/experiences/index.next"
    mv "$store/experiences/index.next" "$store/experiences/index.json"
  done
  base_index > "$store/index.json"
  agent_sync_experience_skills || true
  catalog=$(skill_catalog 'repair the build pipeline')
  if printf '%s\n' "$catalog" | grep -q '<name>build-repair</name>' \
    && printf '%s\n' "$catalog" | grep -q '<name>fragile-build</name>' \
    && printf '%s\n' "$catalog" | grep -q '<status>degraded</status>' \
    && ! printf '%s\n' "$catalog" | grep -q '<name>wrong-os</name>' \
    && ! printf '%s\n' "$catalog" | grep -q '<name>missing-tool</name>' \
    && ! printf '%s\n' "$catalog" | grep -q '<name>unrelated</name>'; then
    ok 'experience catalog enforces one retrieval funnel'
  else
    bad 'experience catalog enforces one retrieval funnel'
  fi
  non_english_catalog=$(skill_catalog "$cjk_fixture$cjk_fixture")
  mixed_catalog=$(skill_catalog "$cjk_fixture build")
  if [ -z "$non_english_catalog" ] \
    && printf '%s\n' "$mixed_catalog" | grep -q '<name>build-repair</name>'; then
    ok 'retrieval keys are English-only, including in mixed-language tasks'
  else
    bad 'retrieval keys are English-only, including in mixed-language tasks'
  fi

  # Deterministic lost-update schedule: pause bridge jq after it read index;
  # a cooperating writer uses the same lock. Without the runtime lock, the
  # bridge overwrites the writer's unrelated skill.
  real_jq=$(command -v jq)
  mkdir -p "$T/race/bin"
  printf '%s\n' '#!/bin/sh' \
    'if [ "${SEED_TEST_PAUSE_JQ:-}" = 1 ] && [ "${1:-}" = --slurpfile ]; then' \
    '  "$SEED_REAL_JQ" "$@"; st=$?; : > "$SEED_JQ_SIGNAL"' \
    '  while [ ! -f "$SEED_JQ_RELEASE" ]; do sleep 0.05; done; exit "$st"' \
    'fi' \
    'exec "$SEED_REAL_JQ" "$@"' > "$T/race/bin/jq"
  chmod 755 "$T/race/bin/jq"
  signal=$T/race/read-done
  release=$T/race/release
  writer_done=$T/race/writer-done
  SEED_REAL_JQ=$real_jq SEED_TEST_PAUSE_JQ=1 SEED_JQ_SIGNAL=$signal \
    SEED_JQ_RELEASE=$release PATH=$T/race/bin:$PATH agent_sync_experience_skills & bridge_pid=$!
  n=0; while [ ! -f "$signal" ] && [ "$n" -lt 100 ]; do sleep 0.05; n=$((n + 1)); done
  (
    lock=$store/.state.lock
    while ! mkdir "$lock" 2>/dev/null; do sleep 0.05; done
    "$real_jq" '.agent.skills += [{name:"manual",description:"manual",path:"/manual",ok:true,note:"manual"}]' \
      "$store/index.json" > "$store/index.writer"
    mv "$store/index.writer" "$store/index.json"
    rmdir "$lock"
    : > "$writer_done"
  ) & writer_pid=$!
  n=0; while [ ! -f "$writer_done" ] && [ "$n" -lt 10 ]; do sleep 0.05; n=$((n + 1)); done
  : > "$release"
  wait "$bridge_pid"; wait "$writer_pid"
  if jq -e '.agent.skills[]? | select(.name == "manual" and .ok == true)' \
      "$store/index.json" >/dev/null; then
    ok 'concurrent state update is preserved'
  else
    bad 'concurrent state update is preserved'
  fi
else
  bad 'kernel functions are extractable'
fi

# Recover a crash that happened after mkdir but before an owner PID landed.
# rmdir succeeds only while the directory is still empty, so it cannot remove
# a claimant that has begun publishing its owner file.
INSTALL=$T/ownerless-lock
mkdir -p "$INSTALL/agent-store/.state.lock"
SEED_STATE_LOCK_WAIT=5
if agent_state_lock_acquire && [ -f "$INSTALL/agent-store/.state.lock/owner" ]; then
  agent_state_lock_release
  if [ ! -d "$INSTALL/agent-store/.state.lock" ]; then
    ok 'ownerless shared lock is recovered safely'
  else
    bad 'ownerless shared lock is recovered safely'
  fi
else
  bad 'ownerless shared lock is recovered safely'
fi
unset SEED_STATE_LOCK_WAIT

# A failed bootstrap must release its lock and remove same-directory staging
# files instead of relying on stale-owner recovery during a future launch.
INSTALL=$T/bootstrap-failure
mkdir -p "$INSTALL/agent-store"
base_index > "$INSTALL/agent-store/index.json"
printf '{invalid\n' > "$INSTALL/agent-store/observations.json"
if agent_bootstrap_machine >/dev/null 2>&1; then
  bad 'failed state write returns an error'
elif [ -d "$INSTALL/agent-store/.state.lock" ] \
  || find "$INSTALL/agent-store" -name '.*.bootstrap.*' -print | grep -q .; then
  bad 'failed state write releases lock and staging files'
else
  ok 'failed state write releases lock and staging files'
fi

# A hybrid v2-shaped row mislabeled version 1 must be preserved and repaired,
# while the readiness check must reject version 1 before migration.
if grep -q '^agent_migrate_index_v2()' "$FN"; then
  INSTALL=$T/hybrid
  mkdir -p "$INSTALL/agent-store"
  base_index | jq '.version="1" | .capabilities += [{id:"sentinel",name:"sentinel",ok:true}]' \
    > "$INSTALL/agent-store/index.json"
  if agent_check_machine_tree "$INSTALL/agent-store/index.json"; then
    bad 'readiness rejects non-v2 version'
  else
    ok 'readiness rejects non-v2 version'
  fi
  agent_migrate_index_v2 || true
  if jq -e '.version == "2" and any(.capabilities[]; .id == "sentinel")' \
      "$INSTALL/agent-store/index.json" >/dev/null; then
    ok 'hybrid migration preserves v2 data'
  else
    bad 'hybrid migration preserves v2 data'
  fi
fi

# Ready machines still initialize memory for every new workspace, and failure
# to do so is an error rather than a false-ready launch.
ready_home=$T/ready-home
mkdir -p "$ready_home/agent-store/packs" "$T/project-ok" "$T/project-bad" \
  "$T/project-link" "$T/project-link-target"
cp "$ROOT/packs/agent/init.json" "$ready_home/agent-store/packs/init.json"
cp "$ROOT/packs/agent/index.json" "$ready_home/agent-store/catalog.json"
jq '.machine_tree | .ready=true | .identity.prereqs={sh:{path:"/bin/sh",ok:true,probe:""},curl:{path:"/usr/bin/curl",ok:true,probe:""},jq:{path:"/usr/bin/jq",ok:true,probe:""}}' \
  "$ROOT/packs/agent/init.json" > "$ready_home/agent-store/index.json"
printf 'agent\n' > "$ready_home/agent-store/mode"
if (cd "$T/project-ok" && env SEED_HOME="$ready_home" SEED_MODE=agent SEED_SKIP_UPDATE=1 \
    SEED_RUNTIME_URL="$SEED" /bin/sh "$SEED" deepseek sk-test </dev/null \
    > "$T/project-ok/out" 2> "$T/project-ok/err") \
  && jq -e '.ready == true and .version == "2"' "$T/project-ok/.agent-memory/index.json" >/dev/null 2>&1; then
  ok 'ready launch ensures project memory'
else
  sed -n '1,80p' "$T/project-ok/err" >&2 || true
  bad 'ready launch ensures project memory'
fi
printf 'not a directory\n' > "$T/project-bad/.agent-memory"
if (cd "$T/project-bad" && env SEED_HOME="$ready_home" SEED_MODE=agent SEED_SKIP_UPDATE=1 \
    SEED_RUNTIME_URL="$SEED" /bin/sh "$SEED" deepseek sk-test </dev/null \
    > "$T/project-bad/out" 2> "$T/project-bad/err"); then
  bad 'project memory failure prevents false ready'
else
  ok 'project memory failure prevents false ready'
fi
ln -s "$T/project-link-target" "$T/project-link/.agent-memory"
if (cd "$T/project-link" && env SEED_HOME="$ready_home" SEED_MODE=agent SEED_SKIP_UPDATE=1 \
    SEED_RUNTIME_URL="$SEED" /bin/sh "$SEED" deepseek sk-test </dev/null \
    > "$T/project-link/out" 2> "$T/project-link/err"); then
  bad 'project memory rejects symlink escapes'
elif [ ! -e "$T/project-link-target/index.json" ]; then
  ok 'project memory rejects symlink escapes'
else
  bad 'project memory rejects symlink escapes'
fi

# /ini is offline and transactional. The test PATH starts with one user-owned,
# writable directory and a curl that would expose any accidental model call.
ini=$T/ini
mkdir -p "$ini/bin" "$ini/mock" "$ini/home"
printf '%s\n' '#!/bin/sh' ': > "$SEED_CURL_CALLED"' 'exit 1' > "$ini/mock/curl"
chmod 755 "$ini/mock/curl"
curl_called=$ini/curl-called
ini_path=$ini/bin:$ini/mock:/usr/bin:/bin
set +e
printf '/ini\n' | env SEED_HOME="$ini/home" SEED_MODE=agent SLAB_SKIP_INIT=1 \
  SEED_RUNTIME_URL="$SEED" SEED_CURL_CALLED="$curl_called" PATH="$ini_path" \
  AGENT_MAX_ROUNDS=1 SEED_EMPTY_RETRIES=0 /bin/sh "$SEED" deepseek sk-test \
  > "$ini/out" 2> "$ini/err"
ini_st=$?
set -e
if [ "$ini_st" -eq 0 ] && [ -x "$ini/bin/seed" ] && [ ! -e "$curl_called" ]; then
  probe=$(cd "$T/project-ok" && PATH="$ini_path" SEED_HOME="$ini/home" seed --probe)
  if printf '%s\n' "$probe" | grep -qx 'seed.identity=seed' \
    && printf '%s\n' "$probe" | grep -qx 'seed.version=2' \
    && printf '%s\n' "$probe" | grep -qxF "seed.state=$ini/home" \
    && printf '%s\n' "$probe" | grep -qxF "seed.workspace=$T/project-ok" \
    && printf '%s\n' "$probe" | grep -q '^seed.content='; then
    ok '/ini is offline and validates exact installed content'
  else
    bad '/ini is offline and validates exact installed content'
  fi
else
  sed -n '1,120p' "$ini/err" >&2 || true
  bad '/ini is offline and validates exact installed content'
fi

rollback=$T/rollback
mkdir -p "$rollback/bin" "$rollback/home"
set +e
printf '/ini\n' | env SEED_HOME="$rollback/home" SEED_MODE=agent SLAB_SKIP_INIT=1 \
  SEED_RUNTIME_URL="$SEED" PATH="$rollback/bin:/usr/bin:/bin" \
  SEED_TEST_INSTALL_FAIL_AFTER_RUNTIME=1 /bin/sh "$SEED" deepseek sk-test \
  > "$rollback/out" 2> "$rollback/err"
rollback_st=$?
set -e
if [ "$rollback_st" -ne 0 ] && [ ! -e "$rollback/bin/seed" ] \
  && ! find "$rollback/home" -path '*/runtimes/seed-*' -type f | grep -q . \
  && grep -q 'install transaction rolled back' "$rollback/err"; then
  ok '/ini rolls back files created by a failed transaction'
else
  sed -n '1,120p' "$rollback/err" >&2 || true
  bad '/ini rolls back files created by a failed transaction'
fi

entry_rollback=$T/entry-rollback
mkdir -p "$entry_rollback/bin" "$entry_rollback/home"
set +e
printf '/ini\n' | env SEED_HOME="$entry_rollback/home" SEED_MODE=agent SLAB_SKIP_INIT=1 \
  SEED_RUNTIME_URL="$SEED" PATH="$entry_rollback/bin:/usr/bin:/bin" \
  SEED_TEST_INSTALL_FAIL_AFTER_ENTRY=1 /bin/sh "$SEED" deepseek sk-test \
  > "$entry_rollback/out" 2> "$entry_rollback/err"
entry_rollback_st=$?
set -e
if [ "$entry_rollback_st" -ne 0 ] && [ ! -e "$entry_rollback/bin/seed" ] \
  && ! find "$entry_rollback/home" -path '*/runtimes/seed-*' -type f | grep -q . \
  && grep -q 'install transaction rolled back' "$entry_rollback/err"; then
  ok '/ini rolls back a published entry when receipt commit fails'
else
  sed -n '1,120p' "$entry_rollback/err" >&2 || true
  bad '/ini rolls back a published entry when receipt commit fails'
fi

direct_ini=$T/direct-ini
mkdir -p "$direct_ini/bin" "$direct_ini/home"
direct_curl_called=$direct_ini/curl-called
if env SEED_HOME="$direct_ini/home" SEED_FORCE_JQ=1 \
    SEED_CURL_CALLED="$direct_curl_called" \
    PATH="$direct_ini/bin:$ini/mock:/usr/bin:/bin" /bin/sh "$SEED" /ini \
    > "$direct_ini/out" 2> "$direct_ini/err" \
  && [ -x "$direct_ini/bin/seed" ] && [ ! -e "$direct_curl_called" ]; then
  ok 'direct /ini never invokes the jq downloader'
else
  sed -n '1,120p' "$direct_ini/err" >&2 || true
  bad 'direct /ini never invokes the jq downloader'
fi

# Maintenance is also a direct offline command. It must not require provider
# configuration or create a model-run directory when there is nothing live.
rm -rf "$T/project-ok/.agent-runs"
if (unset LLM_API_KEY LLM_API_URL LLM_MODEL LLM_PROVIDER LLM_EXTRA; \
    cd "$T/project-ok" && env SEED_HOME="$ready_home" SEED_MODE=agent SEED_SKIP_UPDATE=1 \
    SEED_RUNTIME_URL="$SEED" PATH=/usr/bin:/bin /bin/sh "$SEED" --maintain \
    > "$T/direct-maintain.out" 2> "$T/direct-maintain.err") \
  && grep -q 'maintenance: no live experiences' "$T/direct-maintain.err" \
  && [ ! -d "$T/project-ok/.agent-runs" ]; then
  ok 'direct --maintain is offline and model-free'
else
  sed -n '1,120p' "$T/direct-maintain.err" >&2 || true
  bad 'direct --maintain is offline and model-free'
fi

if [ "$fail" -ne 0 ]; then
  printf '%s\n' "$fail kernel regression(s) failed" >&2
  exit 1
fi
printf 'all seed agent-kernel tests passed\n'
