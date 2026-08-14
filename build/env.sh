SELF=$(CDPATH= cd "$(dirname "$0")" && pwd -P)/$(basename "$0")
AGENT_MAX_ROUNDS=${AGENT_MAX_ROUNDS:-20}
ACTION_TIMEOUT=${SEED_ACTION_TIMEOUT:-180}
MAX_OBS_BYTES=${SEED_MAX_OBS_BYTES:-16384}
HTTP_TIMEOUT=${SEED_HTTP_TIMEOUT:-300}
LAUNCH_CWD=$(pwd -P)

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-70}"; }

usage() {
  printf 'usage: sh seed.sh deepseek <API_KEY>\n' >&2
}

need() { command -v "$1" >/dev/null 2>&1 || die "need $1" 69; }

write_env_file() {
  dest=$1
  umask 077
  printf 'LLM_PROVIDER=%s\nLLM_API_URL=%s\nLLM_MODEL=%s\nLLM_API_KEY=%s\n' \
    "$LLM_PROVIDER" "$LLM_API_URL" "$LLM_MODEL" "$LLM_API_KEY" > "$dest"
  chmod 600 "$dest"
}

load_env() {
  [ -n "${LLM_API_KEY:-}" ] && return 0
  if [ -f "$LAUNCH_CWD/.env" ]; then set -a; . "$LAUNCH_CWD/.env"; set +a; fi
  [ -n "${LLM_API_KEY:-}" ] && return 0
  if [ -n "${INSTALL:-}" ] && [ -f "$INSTALL/.env" ]; then set -a; . "$INSTALL/.env"; set +a; fi
  [ -n "${LLM_API_KEY:-}" ] && return 0
  if [ -f "$PWD/.env" ]; then set -a; . "$PWD/.env"; set +a; fi
}

ensure_gitignore() {
  dir=$1
  g=$dir/.gitignore
  if [ -f "$g" ]; then
    grep -qxF '.env' "$g" || printf '.env\n' >> "$g"
  else
    printf '.env\n' > "$g"
  fi
}

resolve_provider() {
  case $1 in
    deepseek)
      LLM_API_URL=${LLM_API_URL:-https://api.deepseek.com/chat/completions}
      LLM_MODEL=${LLM_MODEL:-deepseek-v4-flash}
      LLM_EXTRA=${LLM_EXTRA:-'{"thinking":{"type":"enabled"}}'}
      LLM_PROVIDER=deepseek ;;
    http*://*)
      LLM_API_URL=$1
      LLM_MODEL=${LLM_MODEL:-deepseek-v4-flash}
      LLM_EXTRA=${LLM_EXTRA:-'{}'}
      LLM_PROVIDER=custom ;;
    *) die "unknown provider: $1 (use deepseek or a full API URL)" 64 ;;
  esac
  LLM_API_KEY=$2
}

probe() {
  USER_SHELL=${SHELL:-/bin/sh}
  need jq
  FACTS="os=$(uname -s) $(uname -r) $(uname -m)
shell=$USER_SHELL
jq=$(command -v jq)
install=${INSTALL:-}
launch_cwd=$LAUNCH_CWD"
}
