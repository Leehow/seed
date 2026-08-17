SELF=$(CDPATH= cd "$(dirname "$0")" && pwd -P)/$(basename "$0")
AGENT_MAX_ROUNDS=${AGENT_MAX_ROUNDS:-20}
ACTION_TIMEOUT=${SEED_ACTION_TIMEOUT:-180}
MAX_OBS_BYTES=${SEED_MAX_OBS_BYTES:-16384}
HTTP_TIMEOUT=${SEED_HTTP_TIMEOUT:-300}
LAUNCH_CWD=$(pwd -P)

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-70}"; }

usage() {
  printf 'usage: sh seed.sh [--global] deepseek <API_KEY>\n' >&2
}

need() {
  command -v "$1" >/dev/null 2>&1 && return 0
  if [ "$1" = jq ]; then
    ensure_jq
    command -v jq >/dev/null 2>&1 && return 0
  fi
  die "need $1" 69
}

jq_asset_name() {
  os=$(uname -s | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')
  arch=$(uname -m)
  case $arch in
    x86_64|amd64) arch=amd64 ;;
    aarch64|arm64) arch=arm64 ;;
    *) return 1 ;;
  esac
  case $os in
    linux) printf 'jq-linux-%s\n' "$arch" ;;
    darwin) printf 'jq-macos-%s\n' "$arch" ;;
    mingw*|msys*|cygwin*) printf 'jq-windows-amd64.exe\n' ;;
    *) return 1 ;;
  esac
}

jq_official_url() {
  ver=${SEED_JQ_VER:-1.7.1}
  asset=$(jq_asset_name) || return 1
  printf 'https://github.com/jqlang/jq/releases/download/jq-%s/%s\n' "$ver" "$asset"
}

jq_mirror_url() {
  asset=$(jq_asset_name) || return 1
  plugin_join "$(plugin_root)" "jq/$asset"
}

jq_fetch() {
  url=$1
  dest=$2
  tmp=$dest.tmp
  set +e
  curl -q -fL --connect-timeout 15 --max-time 60 -o "$tmp" "$url"
  cs=$?
  set -e
  if [ "$cs" -eq 0 ] && [ -s "$tmp" ]; then
    chmod 755 "$tmp"
    mv "$tmp" "$dest"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

ensure_jq() {
  if [ "${SEED_FORCE_JQ:-}" != 1 ] && command -v jq >/dev/null 2>&1; then
    return 0
  fi
  dest=${SEED_JQ_DEST:-}
  if [ -z "$dest" ]; then
    root=${INSTALL:-$LAUNCH_CWD}
    [ -n "$root" ] || root=$PWD
    mkdir -p "$root/bin"
    dest=$root/bin/jq
    case $(uname -s) in
      MINGW*|MSYS*|CYGWIN*) dest=$root/bin/jq.exe ;;
    esac
  fi
  if [ "${SEED_FORCE_JQ:-}" != 1 ] && [ -x "$dest" ]; then
    PATH=$(CDPATH= cd "$(dirname "$dest")" && pwd):$PATH
    export PATH
    return 0
  fi
  command -v curl >/dev/null 2>&1 || die "need curl" 69
  mkdir -p "$(dirname "$dest")"
  if [ -n "${SEED_JQ_URL:-}" ]; then
    printf 'installing: jq\n' >&2
    jq_fetch "$SEED_JQ_URL" "$dest" || die "need jq (download failed)" 69
  else
    official=${SEED_JQ_OFFICIAL_URL:-}
    [ -n "$official" ] || official=$(jq_official_url) || official=
    mirror=$(jq_mirror_url) || mirror=
    printf 'installing: jq\n' >&2
    if [ -n "$mirror" ] && jq_fetch "$mirror" "$dest"; then
      :
    else
      [ -n "$official" ] || die "need jq (unsupported platform)" 69
      printf 'installing: jq (github)\n' >&2
      jq_fetch "$official" "$dest" || die "need jq (download failed)" 69
    fi
  fi
  PATH=$(CDPATH= cd "$(dirname "$dest")" && pwd):$PATH
  export PATH
  command -v jq >/dev/null 2>&1 || die "need jq" 69
}

# DeepSeek-only request field. Other channels keep their catalog extra
# untouched; unknown fields can 400 on OpenAI-compatible endpoints.
disable_thinking() {
  [ "${LLM_PROVIDER:-}" = deepseek ] || return 0
  extra=${LLM_EXTRA:-'{}'}
  LLM_EXTRA=$(printf '%s' "$extra" | jq -c '. + {"thinking":{"type":"disabled"}}')
}

write_env_file() {
  dest=$1
  umask 077
  disable_thinking
  extra=$LLM_EXTRA
  printf 'LLM_PROVIDER=%s\nLLM_API_URL=%s\nLLM_MODEL=%s\nLLM_API_KEY=%s\nLLM_EXTRA=%s\n' \
    "$LLM_PROVIDER" "$LLM_API_URL" "$LLM_MODEL" "$LLM_API_KEY" \
    "$(printf '%s' "$extra" | jq -Rs .)" > "$dest"
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
  grep -qxF 'bin/jq' "$g" || printf 'bin/jq\n' >> "$g"
  grep -qxF 'bin/jq.exe' "$g" || printf 'bin/jq.exe\n' >> "$g"
}

plugin_root() {
  printf '%s' "${SEED_PLUGIN_ROOT:-http://127.0.0.1:7432}"
}

plugin_join() {
  base=$1
  rel=$2
  case $rel in
    http*://*) printf '%s' "$rel" ;;
    /*) printf '%s%s' "$(plugin_root)" "$rel" ;;
    *) printf '%s/%s' "$base" "$rel" ;;
  esac
}

# One GET for every plugin fetch. Body lands in dest; HTTP_CODE and
# HTTP_CURL carry the outcome. Returns 0 only on curl ok + HTTP 2xx.
http_get() {
  hg_url=$1
  hg_dest=$2
  hg_auth=${3:-}
  need curl
  set +e
  if [ -n "$hg_auth" ]; then
    HTTP_CODE=$(curl -q -sS --connect-timeout 5 --max-time 30 \
      -H "Authorization: Bearer $hg_auth" -o "$hg_dest" -w '%{http_code}' "$hg_url")
  else
    HTTP_CODE=$(curl -q -sS --connect-timeout 5 --max-time 30 \
      -o "$hg_dest" -w '%{http_code}' "$hg_url")
  fi
  HTTP_CURL=$?
  set -e
  [ "$HTTP_CURL" -eq 0 ] || return 1
  case $HTTP_CODE in
    2*) return 0 ;;
  esac
  return 1
}

plugin_get() {
  pg_body=$(mktemp "${TMPDIR:-/tmp}/seed-plug.XXXXXX")
  if http_get "$1" "$pg_body" "${2:-}"; then
    cat "$pg_body"
    rm -f "$pg_body"
    return 0
  fi
  rm -f "$pg_body"
  [ "$HTTP_CURL" -eq 0 ] || die "plugin: network failed (curl=$HTTP_CURL)" 71
  die "plugin: HTTP $HTTP_CODE" 72
}

api_origin() {
  printf '%s' "$1" | awk -F/ '{print $1"//"$3}'
}

load_channel_from_catalog() {
  channel=$1
  need jq
  root=$(plugin_root)
  seeddir=$root/seed
  index=$(plugin_get "$seeddir/index.json")
  rel=$(printf '%s' "$index" | jq -r '.models // empty')
  [ -n "$rel" ] || die 'seed index has no models plugin' 69
  catalog=$(plugin_get "$(plugin_join "$seeddir" "$rel")")
  row=$(printf '%s' "$catalog" | jq -c --arg n "$channel" '.[$n] // empty')
  if [ -z "$row" ]; then
    keys=$(printf '%s' "$catalog" | jq -r 'keys | join(" ")')
    die "unknown channel: $channel (have: $keys)" 64
  fi
  raw_api=$(printf '%s' "$row" | jq -r '.api_url // empty')
  [ -n "$raw_api" ] || die "channel $channel has no api_url" 69
  LLM_API_URL=$(plugin_join "$seeddir" "$raw_api")
  LLM_EXTRA=$(printf '%s' "$row" | jq -c '.extra // {}')
  raw_models=$(printf '%s' "$row" | jq -r '.models_url // empty')
  if [ -n "$raw_models" ]; then
    MODELS_URL=$(plugin_join "$seeddir" "$raw_models")
  else
    case $LLM_API_URL in
      */chat/completions) MODELS_URL=${LLM_API_URL%/chat/completions}/models ;;
      *) MODELS_URL=$(api_origin "$LLM_API_URL")/v1/models ;;
    esac
  fi
}

pick_model_once() {
  need jq
  list=$(plugin_get "$MODELS_URL" "$LLM_API_KEY")
  ids=$(printf '%s' "$list" | jq -r '.data[].id // empty')
  [ -n "$ids" ] || die 'model list is empty' 72
  printf '%s\n' "$ids" | awk '{print NR") "$0}' >&2
  printf 'model: ' >&2
  if ! IFS= read -r choice; then
    die 'no model chosen' 64
  fi
  [ -n "$choice" ] || die 'no model chosen' 64
  case $choice in
    *[!0-9]*)
      printf '%s\n' "$ids" | grep -qxF "$choice" || die "unknown model: $choice" 64
      LLM_MODEL=$choice ;;
    *)
      LLM_MODEL=$(printf '%s\n' "$ids" | awk -v n="$choice" 'NR==n {print; found=1} END {exit found?0:1}') \
        || die "unknown model: $choice" 64 ;;
  esac
}

resolve_provider() {
  case $1 in
    deepseek)
      LLM_API_URL=${LLM_API_URL:-https://api.deepseek.com/chat/completions}
      LLM_MODEL=${LLM_MODEL:-deepseek-v4-flash}
      LLM_EXTRA='{"thinking":{"type":"disabled"}}'
      LLM_PROVIDER=deepseek ;;
    http*://*)
      LLM_API_URL=$1
      LLM_MODEL=${LLM_MODEL:-deepseek-v4-flash}
      LLM_EXTRA=${LLM_EXTRA:-'{}'}
      LLM_PROVIDER=custom ;;
    *)
      LLM_API_KEY=$2
      load_channel_from_catalog "$1"
      pick_model_once
      LLM_PROVIDER=$1 ;;
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
