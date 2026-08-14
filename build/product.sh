product_root() {
  case $SELF in
    */bin/agent) CDPATH= cd "$(dirname "$SELF")/.." && pwd -P ;;
    *) CDPATH= cd "$(dirname "$SELF")" && pwd -P ;;
  esac
}

product_system() {
  printf '%s\nMachine index: %s\nProject memory: %s\n' \
    "$(cabin_product_system)" \
    "$INSTALL/agent-store/index.json" \
    "$PWD/.agent-memory/index.json"
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

agent_ready() {
  f=$INSTALL/agent-store/index.json
  [ -f "$f" ] || return 1
  jq -e '.ready == true' "$f" >/dev/null 2>&1
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
    and (.system | has("tools") and has("skills") and has("other"))
    and (.system.tools | has("sh") and has("curl") and has("jq")
         and has("rg") and has("git") and has("python"))
  ' "$f" >/dev/null 2>&1
}

agent_fetch_required() {
  store=$INSTALL/agent-store
  mkdir -p "$store/plugins"
  if [ -f "$store/catalog.json" ] && [ -f "$store/plugins/init.json" ]; then
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
  run_loop "$(product_system)" "$prompt" "$sess" "$ev" "$AGENT_MAX_ROUNDS" 0
  as=$?
  set -e
  shell_stop "$sess" 2>/dev/null || :
  [ "$as" -eq 0 ] || die "init failed" 76
}

agent_ensure_init() {
  [ "${SLAB_SKIP_INIT:-}" = 1 ] && return 0
  agent_ready && return 0
  printf 'initializing:\n' >&2
  agent_fetch_required
  agent_place_trees
  agent_run_init
  agent_check_machine_tree || die "init failed" 76
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
}
