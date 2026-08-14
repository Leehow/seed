product_root() {
  case $SELF in
    */bin/agent) CDPATH= cd "$(dirname "$SELF")/.." && pwd -P ;;
    *) CDPATH= cd "$(dirname "$SELF")" && pwd -P ;;
  esac
}

skill_catalog() {
  scf=$INSTALL/agent-store/index.json
  [ -f "$scf" ] || return 0
  jq -r '
    def esc: gsub("&";"&amp;") | gsub("<";"&lt;") | gsub(">";"&gt;");
    (.system.skills // [])
    | map(select(.ok == true and ((.name // "") | length) > 0))
    | if length == 0 then empty
      else
        (["",
          "The following skills provide specialized instructions for specific tasks.",
          "Load a skill file with shell (cat that path) when the task matches its description.",
          "<available_skills>"]
        + [ .[] |
            "  <skill>",
            "    <name>" + (.name | esc) + "</name>",
            "    <description>" + ((.description // "" | gsub("\n";" ") | esc)) + "</description>",
            "    <location>" + ((.path // "") | esc) + "</location>",
            "  </skill>"
          ]
        + ["</available_skills>"])
        | join("\n")
      end
  ' "$scf" 2>/dev/null || true
}

product_system() {
  printf '%s\nModel: %s (%s)\nMachine index: %s\nProject memory: %s\n' \
    "$(cabin_product_system)" \
    "${LLM_MODEL:-unknown}" \
    "${LLM_PROVIDER:-unknown}" \
    "$INSTALL/agent-store/index.json" \
    "$PWD/.agent-memory/index.json"
  skill_catalog
  agent_run_hooks system
}

agent_plugin_get() {
  url=$1
  need curl
  body=$(mktemp "${TMPDIR:-/tmp}/seed-aplg.XXXXXX")
  set +e
  code=$(curl -q -sS --connect-timeout 5 --max-time 30 -o "$body" -w '%{http_code}' "$url")
  cs=$?
  set -e
  [ "$cs" -eq 0 ] || { rm -f "$body"; die "agent plugin: network failed (curl=$cs)" 71; }
  case $code in
    2*) cat "$body"; rm -f "$body" ;;
    *) rm -f "$body"; die "agent plugin: HTTP $code" 72 ;;
  esac
}

# Best-effort GET into dest. 404 / network fail: leave dest, return 1.
agent_plugin_try() {
  url=$1
  dest=$2
  need curl
  body=$(mktemp "${TMPDIR:-/tmp}/seed-aptry.XXXXXX")
  set +e
  code=$(curl -q -sS --connect-timeout 5 --max-time 30 -o "$body" -w '%{http_code}' "$url")
  cs=$?
  set -e
  if [ "$cs" -eq 0 ]; then
    case $code in
      2*) mv "$body" "$dest"; return 0 ;;
    esac
  fi
  rm -f "$body"
  return 1
}

agent_fetch_hooks() {
  store=$INSTALL/agent-store
  catf=$store/catalog.json
  [ -f "$catf" ] || return 0
  mkdir -p "$store/plugins"
  root=$(plugin_root)
  jq -r '.hooks | .. | strings' "$catf" 2>/dev/null | sort -u | while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    case $rel in
      *.sh) ;;
      *) continue ;;
    esac
    case $rel in
      *..*|/*) continue ;;
    esac
    dest=$store/plugins/$(basename "$rel")
    agent_plugin_try "$(plugin_join "$root/agent" "$rel")" "$dest" || true
  done
}

agent_run_hooks() {
  phase=$1
  store=$INSTALL/agent-store
  catf=$store/catalog.json
  [ -f "$catf" ] || return 0
  SLAB_MACHINE_INDEX=$store/index.json
  export SLAB_MACHINE_INDEX
  jq -r --arg p "$phase" '.hooks[$p][]? // empty' "$catf" 2>/dev/null | while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    script=$store/plugins/$(basename "$rel")
    [ -f "$script" ] || continue
    case $phase in
      system) /bin/sh "$script" blurb || true ;;
      *) /bin/sh "$script" || true ;;
    esac
  done
}

agent_ready() {
  f=$INSTALL/agent-store/index.json
  [ -f "$f" ] || return 1
  jq -e '.ready == true' "$f" >/dev/null 2>&1
}

# Model often writes a useful tree with the wrong shape (skills at the
# top level, missing version/ours). Salvage contract branches; do not
# invent a system object if the model deleted it.
agent_repair_machine_tree() {
  f=$INSTALL/agent-store/index.json
  pack=$INSTALL/agent-store/plugins/init.json
  [ -f "$f" ] || return 1
  [ -f "$pack" ] || return 1
  tmp=$(mktemp "${TMPDIR:-/tmp}/seed-repair.XXXXXX")
  if jq --slurpfile pack "$pack" '
    ($pack[0].machine_tree) as $tpl
    | if (has("system") | not) or (.system | type != "object") then .
      else
        if (has("ready") | not) and (.system.ready == true) then .ready = true else . end
        | if (has("version") | not) or (.version == null) or (.version == "") then
            .version = $tpl.version
          else . end
        | if (has("ours") | not) then .ours = $tpl.ours else . end
        | if (.system | has("retrieve") | not)
            or (.system.retrieve | type != "string")
            or ((.system.retrieve | length) == 0) then
            .system.retrieve = $tpl.system.retrieve
          else . end
        | if (.system | has("other") | not) then .system.other = $tpl.system.other else . end
        | if (.system | has("tools") | not) or (.system.tools | type != "object") then
            .system.tools = $tpl.system.tools
          else
            .system.tools = ($tpl.system.tools * .system.tools)
          end
        | if (.system | has("skills") | not) then
            if (.skills | type == "array") then .system.skills = .skills
            else .system.skills = $tpl.system.skills
            end
          else . end
        | if (.system | has("web") | not) and ($tpl.system | has("web")) then
            .system["web"] = $tpl.system["web"]
          else . end
      end
  ' "$f" > "$tmp"; then
    mv "$tmp" "$f"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

agent_check_machine_tree() {
  f=$INSTALL/agent-store/index.json
  [ -f "$f" ] || return 1
  jq -e '
    type == "object"
    and .ready == true
    and has("version")
    and has("system")
    and has("ours")
    and (.system | has("tools") and has("skills") and has("other") and has("retrieve"))
    and (.system.retrieve | type=="string" and length>0)
    and (.system.tools | has("sh") and has("curl") and has("jq")
         and has("rg") and has("git") and has("python"))
    and (.system.tools | to_entries
         | all(.value | has("ok") and has("present") and has("path")))
  ' "$f" >/dev/null 2>&1
}

agent_fetch_required() {
  store=$INSTALL/agent-store
  mkdir -p "$store/plugins"
  if [ -f "$store/catalog.json" ] && [ -f "$store/plugins/init.json" ]; then
    agent_fetch_hooks
    return 0
  fi
  root=$(plugin_root)
  index=$(agent_plugin_get "$root/agent/index.json")
  printf '%s' "$index" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || die "agent plugin: catalog is not JSON" 69
  rel=$(printf '%s' "$index" | jq -r '.required.init // empty')
  [ -n "$rel" ] || die "agent plugin: catalog has no required.init" 69
  body=$(agent_plugin_get "$(plugin_join "$root/agent" "$rel")")
  printf '%s' "$body" | jq -e \
    'type == "object" and has("prompt") and has("machine_tree") and has("memory_tree")' \
    >/dev/null 2>&1 || die "agent plugin: init pack invalid" 69
  tmp=$(mktemp "${TMPDIR:-/tmp}/seed-acat.XXXXXX")
  printf '%s\n' "$index" > "$tmp"
  printf '%s\n' "$body" > "$store/plugins/init.json"
  mv "$tmp" "$store/catalog.json"
  agent_fetch_hooks
}

agent_place_trees() {
  store=$INSTALL/agent-store
  pack=$store/plugins/init.json
  [ -f "$pack" ] || die "agent plugin: init pack missing" 69
  if [ ! -f "$store/index.json" ]; then
    jq '.machine_tree' "$pack" > "$store/index.json"
  fi
  memdir=$PWD/.agent-memory
  if [ ! -f "$memdir/index.json" ]; then
    if mkdir -p "$memdir" 2>/dev/null \
      && jq '.memory_tree' "$pack" > "$memdir/index.json" 2>/dev/null; then
      :
    else
      printf 'error: memory index not writable\n' >&2
    fi
  fi
}

agent_run_init() {
  pack=$INSTALL/agent-store/plugins/init.json
  prompt=$(jq -r '.prompt // empty' "$pack")
  [ -n "$prompt" ] || die "agent plugin: init prompt empty" 69
  ev=${AGENT_RUNS_DIR:-$PWD/.agent-runs}/$(date -u +%Y%m%dT%H%M%SZ)-$$-init
  sess=$ev/session
  mkdir -p "$ev"
  shell_init "$sess" "$PWD"
  set +e
  INIT_STOP_WHEN_READY=1
  export INIT_STOP_WHEN_READY
  run_loop "$(product_system)" "$prompt" "$sess" "$ev" "$AGENT_MAX_ROUNDS" 0
  as=$?
  unset INIT_STOP_WHEN_READY
  set -e
  shell_stop "$sess" 2>/dev/null || :
  agent_repair_machine_tree || true
  agent_check_machine_tree && return 0
  die "init failed" 76
}

agent_ensure_init() {
  [ "${SLAB_SKIP_INIT:-}" = 1 ] && return 0
  agent_repair_machine_tree || true
  if agent_check_machine_tree; then
    agent_run_hooks after_ready
    return 0
  fi
  printf 'initializing:\n' >&2
  agent_fetch_required
  agent_place_trees
  SEED_STREAM=1
  SEED_STREAM_PRINT=1
  export SEED_STREAM SEED_STREAM_PRINT
  agent_run_init
  agent_repair_machine_tree || true
  agent_run_hooks after_ready
  agent_check_machine_tree || die "init failed" 76
  printf 'ready\n' >&2
}

agent_update() {
  store=$INSTALL/agent-store
  mkdir -p "$store/plugins"
  root=$(plugin_root)
  index=$(agent_plugin_get "$root/agent/index.json")
  printf '%s' "$index" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || die "agent plugin: catalog is not JSON" 69
  nv=$(printf '%s' "$index" | jq -r '.version // empty')
  nu=$(printf '%s' "$index" | jq -r '.updated // empty')
  ov=; ou=
  if [ -f "$store/catalog.json" ]; then
    ov=$(jq -r '.version // empty' "$store/catalog.json")
    ou=$(jq -r '.updated // empty' "$store/catalog.json")
  fi
  if [ "$nv" = "$ov" ] && [ "$nu" = "$ou" ]; then
    return 0
  fi
  rel=$(printf '%s' "$index" | jq -r '.required.init // empty')
  [ -n "$rel" ] || die "agent plugin: catalog has no required.init" 69
  body=$(agent_plugin_get "$(plugin_join "$root/agent" "$rel")")
  printf '%s' "$body" | jq -e 'has("prompt")' >/dev/null 2>&1 \
    || die "agent plugin: init pack invalid" 69
  tmpc=$(mktemp "${TMPDIR:-/tmp}/seed-ucat.XXXXXX")
  tmpi=$(mktemp "${TMPDIR:-/tmp}/seed-uinit.XXXXXX")
  printf '%s\n' "$index" > "$tmpc"
  printf '%s\n' "$body" > "$tmpi"
  mv "$tmpi" "$store/plugins/init.json"
  mv "$tmpc" "$store/catalog.json"
  agent_fetch_hooks
  if [ -f "$store/index.json" ]; then
    nr=$(jq -r '.machine_tree.system.retrieve // empty' "$store/plugins/init.json")
    if [ -n "$nr" ]; then
      tmpi2=$(mktemp "${TMPDIR:-/tmp}/seed-uret.XXXXXX")
      jq --arg r "$nr" '
        .system.retrieve=$r
        | if .system["web"] then .system["web"] |= with_entries(select(.key == "fetch")) else . end
      ' "$store/index.json" > "$tmpi2"
      mv "$tmpi2" "$store/index.json"
    fi
  fi
}
