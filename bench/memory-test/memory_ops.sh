# POSIX helpers implementing packs/agent/memory.json jq flows.
# Sourced by tests. ROOT (agent-store) and INDEX (machine index) must be set.
# MEMDIR is the project .agent-memory directory.

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

assert_eq() {
  [ "$1" = "$2" ] || fail "$3: expected '$2' got '$1'"
}

utc_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

atomic_json() {
  # Prompt: dest.tmp.$$ then mv. Never unsuffixed dest.tmp.
  dest=$1
  tmp=$dest.tmp.$$
  cat > "$tmp"
  if ! jq empty "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$dest"
}

assert_no_tmp() {
  leftover=$(find "$ROOT" ${MEMDIR:+"$MEMDIR"} -name '*.tmp' -o -name '*.tmp.*' 2>/dev/null | grep -v '/.git/' || true)
  [ -z "$leftover" ] || fail "leftover tmp files: $leftover"
}

lazy_memory_dirs() {
  mkdir -p "$ROOT/experiences" "$ROOT/runs" "$ROOT/runs/attic"
  [ -f "$ROOT/rules.md" ] || : > "$ROOT/rules.md"
  mkdir -p "$MEMDIR"
  [ -f "$MEMDIR/rules.md" ] || : > "$MEMDIR/rules.md"
  if [ ! -f "$ROOT/experiences/index.json" ]; then
    printf '%s\n' '{"version":"1","experiences":[]}' | atomic_json "$ROOT/experiences/index.json"
  fi
}

write_exp() {
  id=$1
  dir=$ROOT/experiences/$id
  mkdir -p "$dir"
  now=$(utc_now)
  title=${TITLE:-$id}
  status=${STATUS:-candidate}
  os_json=${OS_JSON:-'[]'}
  # schema: always store canonical lowercase os tokens
  os_json=$(printf '%s' "$os_json" | jq -c 'map(
    ascii_downcase as $l
    | if ($l=="darwin" or $l=="macos" or $l=="osx") then "darwin"
      elif ($l=="linux") then "linux"
      elif ($l=="windows_nt" or $l=="windows" or ($l|startswith("mingw")) or ($l|startswith("msys")) or ($l|startswith("cygwin"))) then "windows"
      elif ($l=="freebsd") then "freebsd"
      elif ($l=="openbsd") then "openbsd"
      elif ($l=="netbsd") then "netbsd"
      elif ($l=="sunos") then "sunos"
      else $l end)')
  tools_json=${TOOLS_JSON:-'[]'}
  kinds_json=${KINDS_JSON:-'["toolchain"]'}
  applies_json=${APPLIES_JSON:-'[]'}
  verify_json=${VERIFY_JSON:-'["true"]'}
  succ=${SUCC:-0}
  failn=${FAIL:-0}
  created=${CREATED_AT:-$now}
  lastv=${LAST_VERIFIED:-}
  jq -n \
    --arg id "$id" --arg title "$title" --arg status "$status" \
    --arg created "$created" --arg lastv "$lastv" \
    --argjson os "$os_json" --argjson tools "$tools_json" \
    --argjson kinds "$kinds_json" --argjson applies "$applies_json" \
    --argjson verify "$verify_json" --argjson succ "$succ" --argjson failn "$failn" \
    '{
      id:$id, kind:"procedure", title:$title, status:$status, version:1,
      scope:{os:$os, tools:$tools, task_kinds:$kinds},
      applies_if:$applies, preconditions:[], verify:$verify,
      evidence:[], successes:$succ, failures:$failn,
      created_at:$created, last_verified:$lastv, supersedes:"", quarantine_reason:""
    }' | atomic_json "$dir/exp.json"
  printf '%s\n' "---
name: $id
description: $title
---

# $title

When to use: $title

## Steps
1. Follow the method.

## Verify
Run every command in exp.json verify[].
" > "$dir/SKILL.md"
  sync_index_row "$id"
}

sync_index_row() {
  id=$1
  exp=$ROOT/experiences/$id/exp.json
  [ -f "$exp" ] || fail "sync_index_row: missing $exp"
  row=$(jq -c '{id,title,status,version,scope,applies_if,path:("experiences/"+.id)}' "$exp")
  jq --argjson row "$row" --arg id "$id" '
    .experiences = ([.experiences[] | select(.id != $id)] + [$row])
  ' "$ROOT/experiences/index.json" | atomic_json "$ROOT/experiences/index.json"
}

skill_frontmatter() {
  f=$1/SKILL.md
  name=$(awk '/^name:/{sub(/^name:[[:space:]]*/,""); print; exit}' "$f")
  desc=$(awk '/^description:/{sub(/^description:[[:space:]]*/,""); print; exit}' "$f")
  printf '%s\t%s\n' "${name:-$(basename "$1")}" "$desc"
}

register_skills() {
  # Merge by name. Never wipe/rebuild .agent.skills.
  [ -f "$INDEX" ] || fail "register_skills: missing machine index $INDEX"
  for expf in "$ROOT"/experiences/*/exp.json; do
    [ -f "$expf" ] || continue
    id=$(jq -r .id "$expf")
    st=$(jq -r .status "$expf")
    dir=$ROOT/experiences/$id
    pair=$(skill_frontmatter "$dir")
    name=${pair%%	*}
    desc=${pair#*	}
    case $st in
      active|degraded)
        rec=$(jq -n --arg n "$name" --arg d "$desc" --arg p "$dir" --arg st "$st" \
          '{name:$n,description:$d,path:$p,ok:true,note:("experience "+$st)}')
        jq --argjson rec "$rec" '
          .agent.skills = ((.agent.skills // []) | map(select(.name != $rec.name)) + [$rec])
        ' "$INDEX" | atomic_json "$INDEX"
        ;;
      candidate|quarantined|rejected|stale|retired)
        jq --arg n "$name" '
          .agent.skills = ((.agent.skills // []) | map(if .name == $n then .ok=false else . end))
        ' "$INDEX" | atomic_json "$INDEX"
        ;;
    esac
  done
}

run_verify() {
  # No pipe-subshell: a failing verify must fail the caller.
  id=$1
  exp=$ROOT/experiences/$id/exp.json
  tmpv=$ROOT/runs/verify-$id.list.tmp
  jq -r '.verify[]' "$exp" > "$tmpv"
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    if ! /bin/sh -c "$cmd"; then
      rm -f "$tmpv"
      return 1
    fi
  done < "$tmpv"
  rm -f "$tmpv"
  return 0
}

promote_candidates() {
  now=$(utc_now)
  for expf in "$ROOT"/experiences/*/exp.json; do
    [ -f "$expf" ] || continue
    st=$(jq -r .status "$expf")
    [ "$st" = candidate ] || continue
    id=$(jq -r .id "$expf")
    if run_verify "$id"; then
      jq --arg now "$now" '
        .status="active"
        | .last_verified=$now
        | .successes = (if .successes < 1 then 1 else .successes end)
      ' "$expf" | atomic_json "$expf"
      sync_index_row "$id"
    fi
  done
}

record_use() {
  id=$1
  ec=$2
  exp=$ROOT/experiences/$id/exp.json
  now=$(utc_now)
  if [ "$ec" -eq 0 ]; then
    jq --arg now "$now" '.successes += 1 | .last_verified=$now' "$exp" | atomic_json "$exp"
  else
    jq '.failures += 1' "$exp" | atomic_json "$exp"
  fi
  apply_predicates "$id"
}

apply_predicates() {
  id=$1
  exp=$ROOT/experiences/$id/exp.json
  st=$(jq -r .status "$exp")
  succ=$(jq -r .successes "$exp")
  failn=$(jq -r .failures "$exp")
  case $st in
    active)
      if [ "$failn" -ge 2 ] && [ "$failn" -gt "$succ" ]; then
        jq '.status="quarantined" | .quarantine_reason="failures exceed successes"' "$exp" | atomic_json "$exp"
      elif [ "$failn" -ge 1 ]; then
        jq '.status="degraded"' "$exp" | atomic_json "$exp"
      fi
      ;;
    degraded)
      if [ "$failn" -ge 2 ] && [ "$failn" -gt "$succ" ]; then
        jq '.status="quarantined" | .quarantine_reason="failures exceed successes"' "$exp" | atomic_json "$exp"
      fi
      ;;
  esac
  mark_stale_one "$id"
  sync_index_row "$id"
}

# A method is applicable where the things it calls have verified. Observations
# do not count: being present is not being usable.
tool_ok() {
  name=$1
  jq -e --arg n "$name" '
    ((.capabilities // []) | map(select((.name==$n) and .ok==true)) | length > 0)
  ' "$INDEX" >/dev/null 2>&1
}

mark_stale_one() {
  id=$1
  exp=$ROOT/experiences/$id/exp.json
  st=$(jq -r .status "$exp")
  case $st in
    candidate|active|degraded) ;;
    *) return 0 ;;
  esac
  # Live only: candidate/active/degraded take the stale edge.
  tools=$(jq -r '.scope.tools[]?' "$exp")
  printf '%s\n' "$tools" | while IFS= read -r t; do
    [ -n "$t" ] || continue
    if ! tool_ok "$t"; then
      printf 'stale\n'
    fi
  done | grep -q stale || return 0
  jq '.status="stale"' "$exp" | atomic_json "$exp"
}

mark_stale_all() {
  for expf in "$ROOT"/experiences/*/exp.json; do
    [ -f "$expf" ] || continue
    id=$(jq -r .id "$expf")
    mark_stale_one "$id"
    sync_index_row "$id"
  done
}

funnel() {
  # Prompt funnel: (1) scope (2) status (3) defined keyword tokenizer, max 3 metadata.
  words=$1
  host=$(uname -s)
  env_os=
  if [ -f "$INDEX" ]; then
    env_os=$(jq -r '.identity.os // empty' "$INDEX")
  fi
  jq -c --arg words "$words" --arg host "$host" --arg envos "$env_os" --slurpfile idx "$INDEX" '
    def stopword:
      . == "an" or . == "the" or . == "and" or . == "or" or . == "of" or . == "to"
      or . == "in" or . == "on" or . == "for" or . == "with" or . == "by" or . == "is"
      or . == "it" or . == "this" or . == "that" or . == "from" or . == "as" or . == "at"
      or . == "be" or . == "if" or . == "via" or . == "vs" or . == "using" or . == "use";
    def canon_os($s):
      ($s | ascii_downcase) as $l
      | if ($l == "darwin" or $l == "macos" or $l == "osx") then "darwin"
        elif ($l == "linux") then "linux"
        elif ($l == "windows_nt" or $l == "windows" or ($l | startswith("mingw")) or ($l | startswith("msys")) or ($l | startswith("cygwin"))) then "windows"
        elif ($l == "freebsd") then "freebsd"
        elif ($l == "openbsd") then "openbsd"
        elif ($l == "netbsd") then "netbsd"
        elif ($l == "sunos") then "sunos"
        else $l end;
    def machine_os:
      if $envos != "" then canon_os($envos) else canon_os($host) end;
    def tool_ok($n):
      (($idx[0] | .capabilities // []) | map(select(.name==$n and .ok==true)) | length > 0);
    def os_ok:
      (.scope.os | length == 0)
      or ((.scope.os | map(canon_os(.)) | index(machine_os)) != null);
    def tools_ok:
      (.scope.tools | length == 0)
      or all(.scope.tools[]; tool_ok(.));
    def kw:
      ($words | ascii_downcase | gsub("[^a-z0-9]+"; " ") | split(" ")
        | map(select(length >= 2)) | map(select(stopword | not))) as $toks
      | ($toks | length > 0)
        and (
          ((.title | ascii_downcase) as $t
            | any($toks[]; . as $tok | ($t | contains($tok))))
          or any(.applies_if[]; . as $a
            | any($toks[]; . as $tok | (($a | ascii_downcase) | contains($tok))))
        );
    [.experiences[]
      | select(os_ok and tools_ok)
      | select(.status == "active" or .status == "degraded")
      | select(kw)
      | {id,title,status,scope,applies_if,path}]
    | .[0:3]
  ' "$ROOT/experiences/index.json"
}
