# Latest finished conversation in this workspace (init runs excluded).
# Conversation state belongs to the loop, so continuing one must be a
# loop affordance; wrappers spawn `agent --resume` per human line.
agent_resume_msgs() {
  rd=${AGENT_RUNS_DIR:-$PWD/.agent-runs}
  [ -d "$rd" ] || return 1
  best=
  for r in "$rd"/*; do
    [ -d "$r" ] || continue
    case $r in
      *-init) continue ;;
    esac
    [ -f "$r/messages.json" ] || continue
    best=$r/messages.json
  done
  [ -n "$best" ] || return 1
  printf '%s\n' "$best"
}

agent_main() {
  INSTALL=$(product_root)
  ensure_jq
  load_env
  disable_thinking
  agent_ensure_init
  # Conversation prints the final answer once. Live delta echo stays off
  # here; init turns it on for its own ceremony inside agent_ensure_init.
  SEED_STREAM=1
  SEED_STREAM_PRINT=0
  export SEED_STREAM SEED_STREAM_PRINT
  resume=0
  if [ "${1:-}" = --resume ]; then
    resume=1; shift
  fi
  oneshot=0
  task=
  if [ "${1:-}" = --oneshot ] || [ "${1:-}" = -p ]; then
    oneshot=1; shift; task=$*
  elif [ "$#" -ge 1 ]; then
    oneshot=1; task=$*
  fi
  if [ "$oneshot" -eq 0 ]; then
    printf '> ' >&2
    if ! IFS= read -r line; then printf '\n' >&2; exit 0; fi
    [ -n "$line" ] || exit 0
    task=$line
  fi
  evn=1
  ev=${AGENT_RUNS_DIR:-$PWD/.agent-runs}/$(date -u +%Y%m%dT%H%M%SZ)-$$-$evn
  sess=$ev/session
  mkdir -p "$ev"
  if [ "$resume" -eq 1 ]; then
    prev=$(agent_resume_msgs 2>/dev/null || :)
    if [ -n "$prev" ]; then
      strip_msg_thinking "$prev" "$ev/messages.json"
    fi
  fi
  shell_init "$sess" "$PWD"
  # || capture: run_loop flips errexit internally, so a set +e guard here
  # would not survive a model error; the window must outlive one bad turn.
  as=0
  run_loop "$(product_system)" "$task" "$sess" "$ev" "$AGENT_MAX_ROUNDS" 1 || as=$?
  last_msgs=$ev/messages.json
  if [ "$oneshot" -eq 1 ]; then
    shell_stop "$sess"
    exit "$as"
  fi
  while true; do
    printf '> ' >&2
    if ! IFS= read -r line; then printf '\n' >&2; break; fi
    [ -n "$line" ] || break
    evn=$((evn + 1))
    ev=${AGENT_RUNS_DIR:-$PWD/.agent-runs}/$(date -u +%Y%m%dT%H%M%SZ)-$$-$evn
    mkdir -p "$ev"
    if [ -s "$last_msgs" ]; then
      strip_msg_thinking "$last_msgs" "$ev/messages.json"
    fi
    if [ ! -f "$sess/alive" ]; then
      sess=$ev/session
      shell_init "$sess" "$PWD"
    fi
    run_loop "$(product_system)" "$line" "$sess" "$ev" "$AGENT_MAX_ROUNDS" 1 || :
    last_msgs=$ev/messages.json
  done
  shell_stop "$sess" 2>/dev/null || :
}

selftest() {
  t=$(CDPATH= cd "$(dirname "$SELF")" && pwd -P)/tests/seed-package.sh
  [ -f "$t" ] || die "offline suite missing: $t (run from repo root)" 69
  exec /bin/sh "$t"
}

case ${1:-} in
  --parse-turn) shift; parse_turn "$1"; exit 0 ;;
  --parse-stream) shift; parse_stream "$1"; exit 0 ;;
  --llm) shift; llm_main "$@"; exit 0 ;;
  --edit) shift; edit_main "$@"; exit 0 ;;
  --ensure-jq) ensure_jq; exit 0 ;;
  --update)
    INSTALL=$(product_root)
    ensure_jq
    load_env
    agent_update
    exit 0 ;;
  --shell-init) shift; probe; shell_init "$1" "$2"; exit 0 ;;
  --shell) shift; shell_run "$1" "$2"; exit 0 ;;
  --shell-stop) shift; shell_stop "$1"; exit 0 ;;
  --shell-cli) shift; die 'shell CLI is internal to agent' 64 ;;
  --agent) shift; agent_main "$@"; exit 0 ;;
  --selftest) selftest; exit 0 ;;
  -h|--help) usage; exit 0 ;;
esac

case $(basename "$0") in
  agent|seedagent)
    agent_main "$@"
    exit 0 ;;
esac

GLOBAL=0
if [ "${1:-}" = --global ]; then GLOBAL=1; shift; fi
INSTALL=.
case ${1:-} in
  '')
    ensure_jq
    load_env
    [ -n "${LLM_API_KEY:-}" ] || die "first run: sh seed.sh deepseek <API_KEY>" 64
    LLM_PROVIDER=${LLM_PROVIDER:-deepseek}
    LLM_API_URL=${LLM_API_URL:-https://api.deepseek.com/chat/completions}
    LLM_MODEL=${LLM_MODEL:-deepseek-v4-flash} ;;
  -*) usage; exit 64 ;;
  *)
    [ "$#" -eq 2 ] || [ "$#" -eq 3 ] || { usage; exit 64; }
    ensure_jq
    resolve_provider "$1" "$2" "${3:-}" ;;
esac
mkdir -p "$INSTALL"
INSTALL=$(CDPATH= cd "$INSTALL" && pwd -P)
install_main
