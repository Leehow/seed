# Standalone seed2 entry. The shared engine above remains the only agent loop.
SEED2_VERSION=1
SELF=$(CDPATH= cd "$(dirname "$0")" && pwd -P)/$(basename "$0")
LAUNCH_CWD=$(pwd -P)
# Freeze the caller-visible command search path before ensure_jq may add a
# private runtime dependency directory. /ini success is judged against this.
SEED2_LAUNCH_PATH=${PATH:-}
AGENT_MAX_ROUNDS=${AGENT_MAX_ROUNDS:-20}
ACTION_TIMEOUT=${SEED_ACTION_TIMEOUT:-180}
MAX_OBS_BYTES=${SEED_MAX_OBS_BYTES:-16384}
HTTP_TIMEOUT=${SEED_HTTP_TIMEOUT:-300}

seed2_usage() {
  printf 'usage: sh seed2.sh <channel|api-url> <API_KEY> [model]\n' >&2
}

seed2_help() {
  printf '%s\n' \
    'seed2: enter an ordinary task to let the agent work in the launch directory.' \
    '/help  show this help without calling the model' \
    '/ini   ask the agent to install the global command seed2, then verify it'
}

seed2_state_root() {
  if [ -n "${SEED2_HOME:-}" ]; then
    printf '%s\n' "$SEED2_HOME"
  else
    [ -n "${HOME:-}" ] || die 'HOME is unset; set SEED2_HOME' 64
    printf '%s/.seed2\n' "$HOME"
  fi
}

seed2_probe() {
  state=$(seed2_state_root)
  case $state in
    /*) ;;
    *) state=$LAUNCH_CWD/$state ;;
  esac
  printf 'seed2.identity=seed2\n'
  printf 'seed2.version=%s\n' "$SEED2_VERSION"
  printf 'seed2.state=%s\n' "$state"
  printf 'seed2.workspace=%s\n' "$LAUNCH_CWD"
}

seed2_save_config() {
  mkdir -p "$INSTALL"
  write_env_file "$INSTALL/.env"
}

seed2_load_or_activate() {
  case $# in
    0)
      ensure_jq
      if [ -z "${LLM_API_KEY:-}" ] && [ -f "$INSTALL/.env" ]; then
        set -a
        . "$INSTALL/.env"
        set +a
      fi
      [ -n "${LLM_API_KEY:-}" ] || die 'first run: sh seed2.sh deepseek <API_KEY>' 64
      LLM_PROVIDER=${LLM_PROVIDER:-deepseek}
      LLM_API_URL=${LLM_API_URL:-https://api.deepseek.com/chat/completions}
      LLM_MODEL=${LLM_MODEL:-deepseek-v4-flash}
      LLM_EXTRA=${LLM_EXTRA:-'{}'}
      ;;
    2|3)
      ensure_jq
      resolve_provider "$1" "$2" "${3:-}"
      seed2_save_config
      ;;
    *) seed2_usage; exit 64 ;;
  esac
  disable_thinking
}

seed2_install_prompt() {
  receipt=$INSTALL/install-result.json
  cat <<EOF
Install this already-running standalone seed2 runtime as a global command named seed2.

This is an explicitly authorized installation operation. Inspect the live POSIX environment and PATH with the shell tool. Choose a user-owned, writable installation method appropriate to the environment. You may copy the runtime, make a symbolic link, or create a tiny POSIX /bin/sh shim. Do not use sudo, do not modify seedagent, and never read or print API keys or .env files.

Runtime source: $SELF
State directory: $INSTALL
Required receipt: $receipt
Stable original launch PATH: $SEED2_LAUNCH_PATH
Current internal runtime PATH: $PATH

Only the stable original launch PATH is accepted as proof that the command remains reachable after this seed2 process exits. The runtime may have temporarily prepended directories such as the state directory's bin subdirectory solely to host dependencies. Do not install seed2 into a directory found only in the current internal runtime PATH. A future-login-only profile change is not enough unless reachability can be proven now through the stable original launch PATH.

Before finishing, use the shell tool to write the receipt as one JSON object with exactly these required string fields (extra fields are allowed):
  {"command":"seed2","entry":"/absolute/path/to/the/executable-entry"}
The entry must be the actual executable path selected for the seed2 command. Do not claim success unless the files and receipt exist. The outer runtime will independently validate everything after this turn.
EOF
}

seed2_validate_install() {
  receipt=$INSTALL/install-result.json
  [ -f "$receipt" ] || { printf 'error: install receipt missing\n' >&2; return 76; }
  if ! jq -e '.command == "seed2" and (.entry | type == "string") and (.entry | length > 1)' \
      "$receipt" >/dev/null 2>&1; then
    printf 'error: install receipt invalid\n' >&2
    return 76
  fi
  entry=$(jq -r '.entry' "$receipt")
  case $entry in
    /*) ;;
    *) printf 'error: install entry is not absolute\n' >&2; return 76 ;;
  esac
  case /$entry/ in
    */../*|*/./*) printf 'error: install entry is unsafe\n' >&2; return 76 ;;
  esac
  case $entry in
    *"
"*) printf 'error: install entry is unsafe\n' >&2; return 76 ;;
  esac
  [ -f "$entry" ] && [ -x "$entry" ] || {
    printf 'error: install entry is not executable\n' >&2
    return 76
  }
  resolved=$(PATH=$SEED2_LAUNCH_PATH command -v seed2 2>/dev/null || true)
  [ "$resolved" = "$entry" ] || {
    printf 'error: installed seed2 is not the PATH entry\n' >&2
    return 76
  }
  first=$(sed -n '1p' "$entry" 2>/dev/null || true)
  case $first in
    '#!'*sh*)
      /bin/sh -n "$entry" >/dev/null 2>&1 || {
        printf 'error: install entry failed syntax check\n' >&2
        return 76
      } ;;
  esac
  probe=$(PATH=$SEED2_LAUNCH_PATH SEED2_HOME=$INSTALL "$resolved" --probe 2>/dev/null) || {
    printf 'error: install entry probe failed\n' >&2
    return 76
  }
  printf '%s\n' "$probe" | grep -qx 'seed2.identity=seed2' || {
    printf 'error: install entry identity mismatch\n' >&2
    return 76
  }
  printf '%s\n' "$probe" | grep -qx "seed2.version=$SEED2_VERSION" || {
    printf 'error: install entry version mismatch\n' >&2
    return 76
  }
  printf '%s\n' "$probe" | grep -qxF "seed2.state=$INSTALL" || {
    printf 'error: install entry state mismatch\n' >&2
    return 76
  }
  printf 'installed: %s\n' "$entry" >&2
}

seed2_install_global() {
  ev=${AGENT_RUNS_DIR:-$PWD/.agent-runs}/$(date -u +%Y%m%dT%H%M%SZ)-$$-ini
  sess=$ev/session
  mkdir -p "$ev"
  rm -f "$INSTALL/install-result.json"
  shell_init "$sess" "$PWD"
  is=0
  run_loop "$(product_system)" "$(seed2_install_prompt)" "$sess" "$ev" "$AGENT_MAX_ROUNDS" 0 || is=$?
  shell_stop "$sess" 2>/dev/null || :
  [ "$is" -eq 0 ] || { printf 'error: global install model turn failed\n' >&2; return "$is"; }
  seed2_validate_install
}

seed2_run_task() {
  task=$1
  case $task in
    /help) seed2_help; return 0 ;;
    /ini) seed2_install_global; return $? ;;
  esac
  evn=$((evn + 1))
  ev=${AGENT_RUNS_DIR:-$PWD/.agent-runs}/$(date -u +%Y%m%dT%H%M%SZ)-$$-$evn
  mkdir -p "$ev"
  if [ -n "${last_msgs:-}" ] && [ -s "$last_msgs" ]; then
    strip_msg_thinking "$last_msgs" "$ev/messages.json"
  fi
  if [ ! -f "$sess/alive" ]; then
    sess=$ev/session
    shell_init "$sess" "$PWD"
  fi
  rs=0
  run_loop "$(product_system)" "$task" "$sess" "$ev" "$AGENT_MAX_ROUNDS" 1 || rs=$?
  last_msgs=$ev/messages.json
  return "$rs"
}

seed2_main() {
  oneshot=0
  task=
  if [ "${1:-}" = --oneshot ] || [ "${1:-}" = -p ]; then
    oneshot=1
    shift
    task=$*
    set --
  fi
  state=$(seed2_state_root)
  mkdir -p "$state"
  INSTALL=$(CDPATH= cd "$state" && pwd -P)
  export SEED2_HOME=$INSTALL
  seed2_load_or_activate "$@"
  agent_ensure_init
  SEED_STREAM=1
  SEED_STREAM_PRINT=0
  export SEED_STREAM SEED_STREAM_PRINT
  evn=0
  last_msgs=
  sess=${AGENT_RUNS_DIR:-$PWD/.agent-runs}/seed2-session-$$
  shell_init "$sess" "$PWD"
  if [ "$oneshot" -eq 1 ]; then
    st=0
    seed2_run_task "$task" || st=$?
    shell_stop "$sess" 2>/dev/null || :
    return "$st"
  fi
  while true; do
    printf '> ' >&2
    if ! IFS= read -r line; then printf '\n' >&2; break; fi
    [ -n "$line" ] || break
    line_status=0
    seed2_run_task "$line" || line_status=$?
    if [ "$line" = /ini ] && [ "$line_status" -ne 0 ]; then
      shell_stop "$sess" 2>/dev/null || :
      return "$line_status"
    fi
  done
  shell_stop "$sess" 2>/dev/null || :
}

case ${1:-} in
  --probe) seed2_probe; exit 0 ;;
  --oneshot|-p)
    # One-shot operation uses the existing saved activation.
    seed2_main "$@"
    exit $? ;;
  -*) seed2_usage; exit 64 ;;
esac

seed2_main "$@"
