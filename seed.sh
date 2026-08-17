#!/bin/sh
# Packed from build/. Do not edit. Change build/ and run: sh build/pack.sh
#   sh seed.sh deepseek sk-xxxx
set -eu
umask 077

SELF=$(CDPATH= cd "$(dirname "$0")" && pwd -P)/$(basename "$0")
AGENT_MAX_ROUNDS=${AGENT_MAX_ROUNDS:-20}
ACTION_TIMEOUT=${SEED_ACTION_TIMEOUT:-180}
MAX_OBS_BYTES=${SEED_MAX_OBS_BYTES:-16384}
HTTP_TIMEOUT=${SEED_HTTP_TIMEOUT:-300}
LAUNCH_CWD=$(pwd -P)

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-70}"; }

usage() {
  printf 'usage: sh seed.sh [--global] <channel|api-url> <API_KEY> [model]\n' >&2
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
  printf '%s' "${SEED_PLUGIN_ROOT:-https://pipi.aichattrpg.com/downloads/slab}"
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

# Soft pick for URL install: network/empty list is not fatal.
try_pick_model() {
  need jq
  [ -n "${MODELS_URL:-}" ] || return 1
  [ -n "${LLM_API_KEY:-}" ] || return 1
  tm_body=$(mktemp "${TMPDIR:-/tmp}/seed-models.XXXXXX")
  if ! http_get "$MODELS_URL" "$tm_body" "$LLM_API_KEY"; then
    rm -f "$tm_body"
    return 1
  fi
  ids=$(jq -r '.data[].id // empty' < "$tm_body")
  rm -f "$tm_body"
  [ -n "$ids" ] || return 1
  printf '%s\n' "$ids" | awk '{print NR") "$0}' >&2
  printf 'model: ' >&2
  if ! IFS= read -r choice; then
    return 1
  fi
  [ -n "$choice" ] || return 1
  case $choice in
    *[!0-9]*)
      printf '%s\n' "$ids" | grep -qxF "$choice" || return 1
      LLM_MODEL=$choice ;;
    *)
      LLM_MODEL=$(printf '%s\n' "$ids" | awk -v n="$choice" 'NR==n {print; found=1} END {exit found?0:1}') \
        || return 1 ;;
  esac
}

normalize_api_url() {
  u=$1
  case $u in
    http://*|https://*) ;;
    *) u=https://$u ;;
  esac
  while [ "$u" != "${u%/}" ]; do
    u=${u%/}
  done
  case $u in
    */chat/completions) ;;
    */v1) u=$u/chat/completions ;;
    *) u=$u/v1/chat/completions ;;
  esac
  printf '%s' "$u"
}

resolve_provider() {
  case $1 in
    deepseek)
      LLM_API_URL=${LLM_API_URL:-https://api.deepseek.com/chat/completions}
      if [ -n "${3:-}" ]; then
        LLM_MODEL=$3
      else
        LLM_MODEL=${LLM_MODEL:-deepseek-v4-flash}
      fi
      LLM_EXTRA='{"thinking":{"type":"disabled"}}'
      LLM_PROVIDER=deepseek ;;
    http://*|https://*|*/*|*:*|*.*)
      LLM_API_URL=$(normalize_api_url "$1")
      LLM_EXTRA=${LLM_EXTRA:-'{}'}
      LLM_PROVIDER=custom
      printf 'api: %s\n' "$LLM_API_URL" >&2
      if [ -n "${3:-}" ]; then
        LLM_MODEL=$3
      else
        LLM_API_KEY=$2
        case $LLM_API_URL in
          */chat/completions) MODELS_URL=${LLM_API_URL%/chat/completions}/models ;;
          *) MODELS_URL=$(api_origin "$LLM_API_URL")/v1/models ;;
        esac
        if ! try_pick_model; then
          LLM_MODEL=${LLM_MODEL:-deepseek-v4-flash}
          printf 'note: model list unavailable, using default\n' >&2
        fi
      fi ;;
    *)
      LLM_API_KEY=$2
      load_channel_from_catalog "$1"
      if [ -n "${3:-}" ]; then
        LLM_MODEL=$3
      else
        pick_model_once
      fi
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

cabin_product_system() {
  cat <<'EOF'
You are a coding agent. You have exactly two tools via tool_calls: shell (a persistent login shell) and edit (unique string replace in a file).
The workspace is the current directory at launch. Look before you edit. After edits, check your work with shell.
Keep large outputs out of this conversation: redirect them to files and query with grep, jq, or head instead of re-reading whole dumps.
When you create new project artifacts on your own initiative, put them under project/<task-slug>/ in the workspace, not loose in the workspace root. If the human names a path, or the workspace already has its own layout, follow that instead.
Never read .env or any credentials file. Never put API keys into commands, files, or messages; delegated children load credentials from .env themselves.
The task is the human's last message. Do not replace it with Machine index key names.
Before acting, read the Machine index with shell (jq, not cat of the whole file) and follow system.retrieve.
The index is a helper catalog, not the problem. jq it for ok matches; do not rewrite the human's ask into index key names.
When the human asks about skills or SKILL.md, open https://agentskills.io/specification with shell first.
When the human's message starts with /, it is a slash command, not a coding task: follow system.retrieve and build the commands block first if the table is missing.
When the human asks what tools you have, what you can use, or what was indexed: first jq the Machine index. Then list (1) the two API tools shell and edit, (2) every ok entry that system.retrieve tells you to use. Mention present-but-not-ok items separately. Do not answer with only shell and edit. Do not dump the raw index.
Reply in the same language the human just used.
Do not stream your process to the human. When the task is done, reply with a short final answer and no tool_calls.
EOF
}

cabin_compact_summary() {
  cat <<'EOF'
You compress earlier conversation state for a coding agent that ran out of context.
Read the transcript and write a compact state note with exactly these five sections:
Goal: the human's current ask in one line.
Done: what has been completed, in bullets.
Key paths and findings: files read or changed, commands that matter, facts learned.
Open: unresolved errors, open questions.
Next: the immediate next step.
Rules: only restate what is in the transcript; never invent. Short English bullets. No preamble.
EOF
}

tools_json() {
  cat <<'EOF'
[
  {"type":"function","function":{"name":"shell","description":"Run a command in the persistent shell. cwd and environment persist.","parameters":{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}}},
  {"type":"function","function":{"name":"edit","description":"Replace old_text with new_text in path. old_text must match exactly once.","parameters":{"type":"object","properties":{"path":{"type":"string"},"old_text":{"type":"string"},"new_text":{"type":"string"}},"required":["path","old_text","new_text"]}}}
]
EOF
}

edit_main() {
  [ "$#" -eq 3 ] || die 'usage: --edit PATH OLD NEW' 64
  need jq
  path=$1 old=$2 new=$3
  [ -n "$old" ] || { printf 'edit: old_text is empty\n' >&2; return 2; }
  [ -f "$path" ] || { printf 'edit: cannot read %s\n' "$path" >&2; return 66; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/seed-edit.XXXXXX")
  # || capture, not set +e/-e: re-enabling errexit here would undo the
  # loop's guard, so one bad edit would kill the whole agent.
  es=0
  jq -nr --rawfile t "$path" --arg old "$old" --arg new "$new" '
    ($t | split($old)) as $p
    | if ($p | length) != 2 then
        ("edit: old_text matches \(($p | length) - 1) times, need exactly 1\n" | halt_error(2))
      else
        $p[0] + $new + $p[1]
      end
  ' > "$tmp" || es=$?
  if [ "$es" -ne 0 ]; then
    rm -f "$tmp"
    return "$es"
  fi
  mv "$tmp" "$path"
}

shell_init() {
  session=$1
  workdir=$2
  mkdir -p "$session"
  printf '%s\n' "$workdir" > "$session/workdir"
  : > "$session/alive"
  cat > "$session/worker.sh" <<'EOS'
#!/bin/sh
SESSION=$1
WORKER_PATH=$PATH
SLEEP=$(command -v sleep 2>/dev/null || echo /bin/sleep)
CAT=$(command -v cat 2>/dev/null || echo /bin/cat)
RM=$(command -v rm 2>/dev/null || echo /bin/rm)
cd "$($CAT "$SESSION/workdir")" || exit 70
while [ -f "$SESSION/alive" ]; do
  if [ ! -f "$SESSION/request" ]; then
    "$SLEEP" 0.05 2>/dev/null || "$SLEEP" 1
    continue
  fi
  cmd=$($CAT "$SESSION/request")
  $RM -f "$SESSION/request" "$SESSION/done"
  eval "$cmd" > "$SESSION/stdout" 2> "$SESSION/stderr"
  echo $? > "$SESSION/status"
  pwd > "$SESSION/cwd"
  if ! command -v sleep >/dev/null 2>&1; then
    PATH=$WORKER_PATH
    export PATH
  fi
  : > "$SESSION/done"
done
EOS
  # Always /bin/sh. zsh ties `path` to PATH; models write path=$(command -v).
  /bin/sh "$session/worker.sh" "$session" \
    </dev/null >"$session/worker.out" 2>"$session/worker.err" &
  echo $! > "$session/pid"
}

# pid/ppid listing works on macOS and Linux; no pgrep.
child_pids() {
  ps -eo pid= -o ppid= 2>/dev/null | awk -v p="$1" '$2==p {print $1}'
}

kill_tree() {
  pid=$1
  case ${pid:-} in ''|*[!0-9]*) return 0 ;; esac
  [ "$pid" -gt 1 ] || return 0
  for c in $(child_pids "$pid"); do
    kill_tree "$c"
  done
  kill "$pid" 2>/dev/null || true
}

shell_stop() {
  session=$1
  rm -f "$session/alive"
  if [ -f "$session/pid" ]; then
    kill_tree "$(cat "$session/pid")"
  fi
}

shell_run() {
  session=$1
  cmd=$2
  [ -d "$session" ] || die "shell session missing: $session" 70
  rm -f "$session/done"
  : > "$session/stdout"
  : > "$session/stderr"
  printf '%s\n' "$cmd" > "$session/request.tmp"
  mv "$session/request.tmp" "$session/request"
  # Poll in 0.05s ticks when sleep takes decimals (worker does the same);
  # 20 ticks equal one second so the timeout math stays in seconds.
  n=0
  max=$((ACTION_TIMEOUT * 20))
  while [ ! -f "$session/done" ]; do
    n=$((n + 1))
    if [ "$n" -gt "$max" ]; then
      if [ -f "$session/pid" ]; then
        kill_tree "$(cat "$session/pid")"
        sleep 1
        kill_tree "$(cat "$session/pid")"
      fi
      printf 'timeout\n' > "$session/stderr"
      echo 124 > "$session/status"
      pwd > "$session/cwd" 2>/dev/null || cat "$session/workdir" > "$session/cwd"
      : > "$session/done"
      wd=$(cat "$session/cwd" 2>/dev/null || cat "$session/workdir")
      shell_init "$session" "$wd"
      break
    fi
    if ! sleep 0.05 2>/dev/null; then
      sleep 1
      n=$((n + 19))
    fi
  done
  out=$session/stdout err=$session/stderr
  st=$(cat "$session/status" 2>/dev/null || echo 1)
  cwd=$(cat "$session/cwd" 2>/dev/null || cat "$session/workdir")
  printf -- '--- stdout ---\n'
  clip_file "$out"
  printf -- '--- stderr ---\n'
  clip_file "$err"
  printf -- '--- exit: %s ---\n' "$st"
  printf -- '--- cwd: %s\n' "$cwd"
}

clip_file() {
  f=$1
  [ -s "$f" ] || return 0
  n=$(wc -c < "$f" | tr -d ' ')
  if [ "$n" -le "$MAX_OBS_BYTES" ]; then
    cat "$f"
  else
    dd if="$f" bs="$MAX_OBS_BYTES" count=1 2>/dev/null
    printf '\n[truncated, %s bytes]\n' "$n"
  fi
  echo
}

parse_turn() {
  need jq
  jq '
    (.choices[0].message // {}) as $m
    | {
        content: ($m.content // ""),
        tool_calls: (
          ($m.tool_calls // [])
          | map({
              id: (.id // ""),
              name: (.function.name // ""),
              arguments: (.function.arguments // "")
            })
        ),
        usage: (.usage // {})
      }
  ' "$1"
}

parse_stream() {
  need jq
  awk '
    {
      gsub(/\r/, "")
      if ($0 ~ /^data: /) {
        sub(/^data: /, "")
        if ($0 != "[DONE]" && $0 != "") print
      }
    }
  ' "$1" | jq -s '
    reduce .[] as $c (
      {content:"", tools:{}, usage:{}};
      ($c.choices[0].delta // {}) as $d
      | .content += ($d.content // "")
      | .usage = (if $c.usage then $c.usage else .usage end)
      | reduce ($d.tool_calls // [])[] as $t (.;
          ($t.index // 0 | tostring) as $i
          | .tools[$i].id = ($t.id // .tools[$i].id // "")
          | .tools[$i].name = ($t.function.name // .tools[$i].name // "")
          | .tools[$i].arguments += ($t.function.arguments // "")
        )
    )
    | {
        content,
        tool_calls: (
          .tools
          | to_entries
          | sort_by(.key | tonumber)
          | map({
              id: .value.id,
              name: .value.name,
              arguments: (.value.arguments // "")
            })
        ),
        usage
      }
  '
}

stream_print() {
  # Dual duty: archive every raw line (no tee dependency) and optionally
  # print delta content to stderr. $1 is the raw capture file.
  sp_raw=$1
  : > "$sp_raw"
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line" >> "$sp_raw"
    line=$(printf '%s' "$line" | tr -d '\r')
    case $line in
      data:\ \[DONE\]) ;;
      data:\ *)
        payload=${line#data: }
        [ -n "$payload" ] || continue
        if [ "${SEED_STREAM_PRINT:-}" = 1 ]; then
          printf '%s' "$payload" | jq -rj '.choices[0].delta.content // empty' >&2 2>/dev/null || :
        fi
        ;;
    esac
  done
}

strip_msg_thinking() {
  jq 'map(if type=="object" then del(.reasoning_content, .reasoning, .thinking) else . end)' "$1" > "$2"
}

llm_context_overflow() {
  grep -qiE 'context_length|context length|too many tokens|maximum context|prompt is too long|prompt_too_long' "$1" 2>/dev/null
}

# Model errors return instead of exiting so an interactive window can
# survive one bad turn. Transient failures (network, truncated stream,
# 429, 5xx) get one retry; 401/403/400 do not.
model_turn() {
  in_msgs=$1
  dest=$2
  work=$(mktemp -d "${TMPDIR:-/tmp}/seed-llm.XXXXXX")
  strip_msg_thinking "$in_msgs" "$work/msgs.json"
  if [ -n "${SEED_LLM_STUB:-}" ]; then
    # || capture, not set +e/-e: flipping errexit inside a function
    # would undo the caller's guard and kill the interactive window.
    st=0
    "$SEED_LLM_STUB" --messages "$work/msgs.json" > "$dest" || st=$?
    rm -rf "$work"
    return "$st"
  fi
  load_env
  disable_thinking
  if [ -z "${LLM_API_KEY:-}" ]; then
    rm -rf "$work"
    printf 'error: missing API key (.env or environment)\n' >&2
    return 64
  fi
  need curl
  need jq
  tools_json > "$work/tools.json"
  extra=${LLM_EXTRA:-'{}'}
  stream=false
  [ "${SEED_STREAM:-}" = 1 ] && stream=true
  jq -n --arg m "$LLM_MODEL" --slurpfile msg "$work/msgs.json" --slurpfile t "$work/tools.json" --argjson x "$extra" --argjson st "$stream" \
    '{model:$m,stream:$st,messages:$msg[0],tools:$t[0]} + $x' \
    > "$work/req.json"
  printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$LLM_API_KEY" > "$work/h"
  try=1
  while :; do
    cs=0
    if [ "$stream" = true ]; then
      curl -q -N -sS --connect-timeout 15 --max-time "$HTTP_TIMEOUT" -X POST \
        -H "@$work/h" --data-binary "@$work/req.json" \
        -w '\n__HTTP__%{http_code}\n' "$LLM_API_URL" \
        | stream_print "$work/raw" || :
      [ -s "$work/raw" ] || cs=1
    else
      curl -q -sS --connect-timeout 15 --max-time "$HTTP_TIMEOUT" -X POST \
        -H "@$work/h" --data-binary "@$work/req.json" \
        -w '\n__HTTP__%{http_code}\n' "$LLM_API_URL" > "$work/raw" || cs=$?
    fi
    code=
    if [ "$cs" -eq 0 ]; then
      code=$(awk '/^__HTTP__/{print substr($0,9)}' "$work/raw" | tail -1)
    fi
    case "$cs:${code:-}" in
      0:2*) break ;;
      0:401|0:403)
        rm -rf "$work"
        printf 'error: llm: API key rejected (HTTP %s)\n' "$code" >&2
        return 77
        ;;
      0:400|0:413)
        if llm_context_overflow "$work/raw"; then
          rm -rf "$work"
          return 73
        fi
        rm -rf "$work"
        printf 'error: llm: HTTP %s\n' "$code" >&2
        return 72
        ;;
      *)
        if [ "$try" -eq 1 ]; then
          try=2
          printf 'llm: retry\n' >&2
          sleep 2
          continue
        fi
        rm -rf "$work"
        if [ "$cs" -ne 0 ]; then
          printf 'error: llm: network failed (curl=%s)\n' "$cs" >&2
          return 71
        fi
        printf 'error: llm: HTTP %s\n' "${code:-000}" >&2
        return 72
        ;;
    esac
  done
  if [ "$stream" = true ]; then
    parse_stream "$work/raw" > "$dest"
    [ "${SEED_STREAM_PRINT:-}" = 1 ] && printf '\n' >&2
  else
    awk '!/^__HTTP__/' "$work/raw" > "$work/body"
    parse_turn "$work/body" > "$dest"
  fi
  cp "$work/raw" "$dest.raw" 2>/dev/null || :
  rm -rf "$work"
}

llm_main() {
  msgs=
  while [ "$#" -gt 0 ]; do
    case $1 in
      --messages) msgs=$2; shift 2 ;;
      *) die "llm: unknown argument $1" 64 ;;
    esac
  done
  # Own dir name: model_turn reuses the global work variable (sh has no
  # locals) and removes its dir, which used to orphan this one.
  lw=$(mktemp -d "${TMPDIR:-/tmp}/seed-llmcli.XXXXXX")
  trap 'rm -rf "$lw"' EXIT
  if [ -n "$msgs" ]; then cp "$msgs" "$lw/m.json"
  else
    cat > "$lw/p.txt"
    [ -s "$lw/p.txt" ] || die 'llm: empty stdin' 64
    jq -Rs '[{role:"user",content:.}]' < "$lw/p.txt" > "$lw/m.json"
  fi
  model_turn "$lw/m.json" "$lw/t.json"
  jq -r '.content // empty' "$lw/t.json"
}

# When prompt_tokens cross 70% of the window: first summarize the
# unprotected span into one user message (best effort, one small call),
# then clear old fat tool bodies. Protect SYSTEM. If there are at least
# two user turns, keep from the second-to-last user; else keep from the
# second-to-last tool-call assistant.
agent_compact() {
  ac_msgs=$1
  ac_tok=$2
  ac_force=${3:-0}
  [ "${INIT_STOP_WHEN_READY:-}" = 1 ] && return 0
  [ -f "$ac_msgs" ] || return 0
  case $ac_tok in
    ''|*[!0-9]*) ac_tok=0 ;;
  esac
  case $ac_force in
    1) : ;;
    *) ac_force=0 ;;
  esac
  ac_win=128000
  if [ -n "${INSTALL:-}" ] && [ -f "$INSTALL/agent-store/catalog.json" ]; then
    ac_cw=$(jq -r '.context_window // empty' "$INSTALL/agent-store/catalog.json" 2>/dev/null || true)
    case $ac_cw in
      ''|*[!0-9]*) : ;;
      *) ac_win=$ac_cw ;;
    esac
  fi
  [ -n "${LLM_CONTEXT_WINDOW:-}" ] && ac_win=$LLM_CONTEXT_WINDOW
  [ -n "${SLAB_CONTEXT_WINDOW:-}" ] && ac_win=$SLAB_CONTEXT_WINDOW
  case $ac_win in
    ''|*[!0-9]*) ac_win=128000 ;;
  esac
  ac_th=$((ac_win * 70 / 100))
  if [ "$ac_force" -ne 1 ] && [ "$ac_tok" -lt "$ac_th" ]; then
    return 0
  fi
  ac_protect=$(jq '
    def users: [to_entries[] | select(.value.role=="user") | .key];
    def groups: [to_entries[] | select(
        .value.role=="assistant"
        and ((.value.tool_calls // []) | length) > 0
      ) | .key];
    if (users | length) >= 2 then users[-2]
    elif (groups | length) >= 2 then groups[-2]
    else -1
    end
  ' "$ac_msgs" 2>/dev/null || echo -1)
  case $ac_protect in
    ''|*[!0-9-]*|-1) return 0 ;;
  esac
  [ "$ac_protect" -gt 0 ] || return 0
  ac_need=$(jq -r --argjson p "$ac_protect" '
    any(.[1:$p][];
      .role=="tool"
      and ((.content // "") | type=="string")
      and ((.content // "") | length) > 200)
  ' "$ac_msgs" 2>/dev/null || echo false)
  [ "$ac_need" = true ] || return 0
  ac_sum=
  ac_sum=$(agent_summarize "$ac_msgs" "$ac_protect" 2>/dev/null) || ac_sum=
  ac_tmp=$(mktemp "${TMPDIR:-/tmp}/seed-cc.XXXXXX")
  if jq --argjson p "$ac_protect" --arg s "$ac_sum" '
    . as $m
    | [
        range(0; $m|length) as $i
        | $m[$i]
        | if ($i > 0) and ($i < $p) and (.role=="tool")
            and ((.content // "") | type=="string")
            and ((.content // "") | length) > 200
          then .content = "[old tool output cleared]"
          else .
          end
      ] as $c
    | if $s == "" then $c
      else $c[0:$p] + [{role:"user", content:("[earlier work summary]\n" + $s)}] + $c[$p:]
      end
  ' "$ac_msgs" > "$ac_tmp"
  then
    mv "$ac_tmp" "$ac_msgs"
    if [ -n "$ac_sum" ]; then
      printf 'compact: summarized\n' >&2
    else
      printf 'compact: pruned\n' >&2
    fi
  else
    rm -f "$ac_tmp"
  fi
}

# Best-effort summary of the span that is about to be pruned. Prints the
# summary text on stdout; returns nonzero on any failure so the caller
# falls back to plain clearing. Runs one small non-streaming call outside
# the loop, never touches messages itself.
agent_summarize() {
  as_msgs=$1
  as_p=$2
  [ -f "$as_msgs" ] || return 1
  case $as_p in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$as_p" -gt 1 ] || return 1
  as_tr=$(jq -r --argjson p "$as_p" '
    .[1:$p]
    | map(
        (.role // "?") as $r
        | (if $r == "assistant" and ((.tool_calls // []) | length) > 0
           then " [calls " + ([.tool_calls[].function.name // empty] | join(",")) + "]"
           else "" end) as $calls
        | $r + ": " + ((.content // "") | if type == "string" then . else tostring end) + $calls
      )
    | map(.[0:500])
    | join("\n")
    | .[0:12288]
  ' "$as_msgs" 2>/dev/null) || return 1
  [ -n "$as_tr" ] || return 1
  as_dir=$(mktemp -d "${TMPDIR:-/tmp}/seed-sum.XXXXXX")
  jq -n --arg s "$(cabin_compact_summary)" --arg t "$as_tr" \
    '[{role:"system",content:$s},{role:"user",content:$t}]' > "$as_dir/msgs.json"
  as_st=0
  (
    SEED_STREAM=0
    SEED_STREAM_PRINT=0
    model_turn "$as_dir/msgs.json" "$as_dir/out.json"
  ) || as_st=$?
  as_out=
  if [ "$as_st" -eq 0 ]; then
    as_out=$(jq -r '.content // empty | .[0:4096]' "$as_dir/out.json" 2>/dev/null || true)
  fi
  rm -rf "$as_dir"
  [ -n "$as_out" ] || return 1
  printf '%s' "$as_out"
}

tool_note() {
  name=$1
  text=$2
  oneline=$(printf '%s' "$text" | tr '\n' ' ')
  printf '%s: %.160s\n' "$name" "$oneline" >&2
}

exec_tool() {
  session=$1
  name=$2
  args=$3
  outf=$4
  case $name in
    shell)
      cmd=$(printf '%s' "$args" | jq -r '.command // empty')
      [ -n "$cmd" ] || { printf 'shell: missing command\n' > "$outf"; return 0; }
      tool_note shell "$cmd"
      # Write the file directly. $(cmd | tee) deadlocks in /bin/sh after a timeout.
      shell_run "$session" "$cmd" > "$outf"
      ;;
    edit)
      path=$(printf '%s' "$args" | jq -r '.path // empty')
      old=$(printf '%s' "$args" | jq -r '.old_text // empty')
      new=$(printf '%s' "$args" | jq -r '.new_text // empty')
      tool_note edit "$path"
      set +e
      edit_main "$path" "$old" "$new" > "$outf.out" 2> "$outf.err"
      es=$?
      set -e
      {
        if [ "$es" -eq 0 ]; then printf 'ok\n'
        else printf 'edit failed (exit %s)\n' "$es"; cat "$outf.err"
        fi
      } > "$outf"
      ;;
    *) printf 'unknown tool: %s\n' "$name" > "$outf" ;;
  esac
}

run_loop() {
  system=$1
  user=$2
  session=$3
  evdir=$4
  max=$5
  print_final=$6
  mkdir -p "$evdir"
  msgs=$evdir/messages.json
  if [ -s "$msgs" ]; then
    jq --arg u "$user" '. + [{role:"user",content:$u}]' "$msgs" > "$msgs.n" && mv "$msgs.n" "$msgs"
  else
    jq -n --arg s "$system" --arg u "$user" \
      '[{role:"system",content:$s},{role:"user",content:$u}]' > "$msgs"
  fi
  last_pt=0
  if [ -n "${INSTALL:-}" ] && [ -f "$INSTALL/agent-store/last-prompt-tokens" ]; then
    last_pt=$(cat "$INSTALL/agent-store/last-prompt-tokens" 2>/dev/null || echo 0)
  fi
  case $last_pt in
    ''|*[!0-9]*) last_pt=0 ;;
  esac
  agent_compact "$msgs" "$last_pt" || true
  round=1
  final=
  while [ "$round" -le "$max" ]; do
    set +e
    model_turn "$msgs" "$evdir/turn-$round.json"
    mt=$?
    set -e
    if [ "$mt" -eq 73 ]; then
      if [ -f "$evdir/overflow-retried" ]; then
        die "llm: context overflow" 73
      fi
      touch "$evdir/overflow-retried"
      agent_compact "$msgs" "$last_pt" 1 || true
      set +e
      model_turn "$msgs" "$evdir/turn-$round.json"
      mt=$?
      set -e
    fi
    if [ "$mt" -ne 0 ]; then
      return "$mt"
    fi
    last_pt=$(jq -r '.usage.prompt_tokens // .usage.input_tokens // 0' \
      "$evdir/turn-$round.json" 2>/dev/null || echo 0)
    case $last_pt in
      ''|*[!0-9]*) last_pt=0 ;;
    esac
    if [ -n "${INSTALL:-}" ]; then
      mkdir -p "$INSTALL/agent-store"
      printf '%s\n' "$last_pt" > "$INSTALL/agent-store/last-prompt-tokens"
    fi
    agent_compact "$msgs" "$last_pt" || true
    content=$(jq -r '.content // empty' "$evdir/turn-$round.json")
    ntools=$(jq '.tool_calls | length' "$evdir/turn-$round.json")
    if [ "$ntools" -gt 0 ]; then
      jq --argjson t "$(jq '.tool_calls' "$evdir/turn-$round.json")" \
        '. + [{role:"assistant",content:null,tool_calls:($t | map({id:.id,type:"function",function:{name:.name,arguments:.arguments}}))}]' \
        "$msgs" > "$msgs.n" && mv "$msgs.n" "$msgs"
      i=0
      while [ "$i" -lt "$ntools" ]; do
        id=$(jq -r --argjson i "$i" '.tool_calls[$i].id' "$evdir/turn-$round.json")
        name=$(jq -r --argjson i "$i" '.tool_calls[$i].name' "$evdir/turn-$round.json")
        args=$(jq -r --argjson i "$i" '.tool_calls[$i].arguments' "$evdir/turn-$round.json")
        exec_tool "$session" "$name" "$args" "$evdir/tool-$round-$i.txt"
        obs=$(cat "$evdir/tool-$round-$i.txt")
        jq --arg id "$id" --arg c "$obs" \
          '. + [{role:"tool",tool_call_id:$id,content:$c}]' "$msgs" > "$msgs.n" && mv "$msgs.n" "$msgs"
        i=$((i + 1))
      done
      if [ "${INIT_STOP_WHEN_READY:-}" = 1 ] && agent_check_machine_tree; then
        break
      fi
    else
      final=$content
      jq --arg c "$content" '. + [{role:"assistant",content:$c}]' "$msgs" > "$msgs.n" && mv "$msgs.n" "$msgs"
      break
    fi
    round=$((round + 1))
  done
  if [ "$round" -gt "$max" ] && [ -z "$final" ]; then
    if [ "${INIT_STOP_WHEN_READY:-}" = 1 ] && agent_check_machine_tree; then
      return 0
    fi
    if [ "$print_final" -eq 1 ]; then
      printf 'round limit reached; task unfinished\n'
      return 0
    fi
    return 75
  fi
  [ "$print_final" -eq 1 ] && [ -n "$final" ] && printf '%s\n' "$final"
  return 0
}

write_shims() {
  mkdir -p "$INSTALL/bin"
  if [ "$SELF" != "$INSTALL/seed.sh" ]; then
    cp "$SELF" "$INSTALL/seed.sh"
    chmod 755 "$INSTALL/seed.sh"
  fi
  cp "$SELF" "$INSTALL/bin/agent"
  chmod 755 "$INSTALL/bin/agent"
  for pair in "llm|--llm" "edit|--edit" "shell|--shell-cli"; do
    name=${pair%%|*}
    flag=${pair#*|}
    printf '#!/bin/sh\nexec /bin/sh "$(CDPATH= cd "$(dirname "$0")" && pwd -P)/agent" %s "$@"\n' "$flag" > "$INSTALL/bin/$name"
    chmod 755 "$INSTALL/bin/$name"
  done
}

verify_install() {
  bad=0
  for f in agent llm edit shell; do
    p=$INSTALL/bin/$f
    if [ ! -x "$p" ]; then
      printf '  FAIL missing %s\n' "$p" >&2; bad=$((bad + 1))
    elif ! /bin/sh -n "$p" 2>/dev/null; then
      printf '  FAIL %s failed syntax check\n' "$p" >&2; bad=$((bad + 1))
    fi
  done
  [ -f "$INSTALL/seed.sh" ] || { printf '  FAIL missing seed.sh\n' >&2; bad=$((bad + 1)); }
  if [ ! -f "$LAUNCH_CWD/.env" ] || [ ! -f "$INSTALL/.env" ]; then
    printf '  FAIL incomplete .env\n' >&2; bad=$((bad + 1))
  else
    k1=$(jq -r -n --rawfile e "$LAUNCH_CWD/.env" '$e | split("\n") | map(select(startswith("LLM_API_KEY="))) | .[0] | split("=")[1]' 2>/dev/null || grep '^LLM_API_KEY=' "$LAUNCH_CWD/.env" | sed 's/^LLM_API_KEY=//')
    [ -n "$k1" ] || { printf '  FAIL .env has no key\n' >&2; bad=$((bad + 1)); }
  fi
  intro=$(LAUNCH_CWD=$LAUNCH_CWD SLAB_SKIP_INIT=1 /bin/sh "$INSTALL/bin/agent" </dev/null 2>&1 || true)
  printf '%s' "$intro" | grep -q '>' || { printf '  FAIL agent prompt missing\n' >&2; bad=$((bad + 1)); }
  extra=$(printf '%s' "$intro" | tr -d '>\n ')
  [ -z "$extra" ] || { printf '  FAIL agent lectured on open\n' >&2; bad=$((bad + 1)); }
  baked=$(printf '/%s/|/%s/' Users home)
  if grep -E "$baked" "$INSTALL/bin/agent" "$INSTALL/bin/edit" "$INSTALL/bin/llm" "$INSTALL/bin/shell" >/dev/null 2>&1; then
    printf '  FAIL shim baked a host path\n' >&2; bad=$((bad + 1))
  fi
  if grep -E 'exec /bin/sh .*seed\.sh' "$INSTALL/bin/agent" >/dev/null 2>&1; then
    printf '  FAIL agent execs seed.sh\n' >&2; bad=$((bad + 1))
  fi
  w=$(mktemp -d "${TMPDIR:-/tmp}/seed-ver.XXXXXX")
  w=$(CDPATH= cd "$w" && pwd)
  stub=$w/stub
  printf '0\n' > "$w/n"
  cat > "$stub" <<'STUB'
#!/bin/sh
n=$(cat "$SEED_VER_N")
n=$((n + 1))
printf '%s\n' "$n" > "$SEED_VER_N"
if [ "$n" -eq 1 ]; then
  printf '%s\n' '{"content":"","tool_calls":[{"id":"v1","name":"shell","arguments":"{\"command\":\"pwd\"}"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}'
else
  printf '%s\n' '{"content":"ok","tool_calls":[],"usage":{"prompt_tokens":1,"completion_tokens":1}}'
fi
STUB
  chmod +x "$stub"
  set +e
  (
    cd "$w"
    SLAB_SKIP_INIT=1 SEED_LLM_STUB=$stub SEED_VER_N=$w/n /bin/sh "$INSTALL/bin/agent" --oneshot 'pwd'
  ) > "$w/out" 2> "$w/err"
  set -e
  if ! grep -q ok "$w/out"; then
    printf '  FAIL stub tool_calls did not run\n' >&2; bad=$((bad + 1))
  fi
  if ! grep -FR "$w" "$w/.agent-runs" >/dev/null 2>&1; then
    printf '  FAIL stub workspace was not the temp dir\n' >&2; bad=$((bad + 1))
  fi
  rm -rf "$w"
  [ "$bad" -eq 0 ] || die "verify failed: $bad check(s)" 76
}

install_main() {
  if [ "${GLOBAL:-0}" = 1 ]; then install_global_main; return 0; fi
  ensure_jq
  write_env_file "$LAUNCH_CWD/.env"
  write_env_file "$INSTALL/.env"
  ensure_gitignore "$LAUNCH_CWD"
  write_shims
  verify_install
  printf 'installed: bin/agent\n' >&2
  printf 'open: sh bin/agent\n' >&2
  printf 'global: sh seed.sh --global   # install ~/.local/bin/seedagent for anywhere use\n' >&2
}

# Global mode: entry on PATH (~/.local/bin/seedagent); state home is separate
# ($SEED_AGENT_HOME or ~/.seed-agent: agent-store, .env, jq). Workspace stays
# the launch cwd.
install_global_main() {
  GH=${SEED_AGENT_HOME:-$HOME/.seed-agent}
  GB=$HOME/.local/bin
  INSTALL=$GH
  ensure_jq
  mkdir -p "$GH/bin" "$GB"
  write_env_file "$GH/.env"
  ensure_gitignore "$GH"
  write_shims
  cp "$SELF" "$GB/seedagent"
  chmod 755 "$GB/seedagent"
  verify_global_install
  printf 'installed: %s\n' "$GB/seedagent" >&2
  printf 'open: seedagent\n' >&2
  printf 'oneshot: seedagent -p "task"\n' >&2
  command -v seedagent >/dev/null 2>&1 || \
    printf 'note: %s is not on PATH; add it to use seedagent anywhere\n' "$GB" >&2
}

verify_global_install() {
  bad=0
  for f in agent llm edit shell; do
    p=$INSTALL/bin/$f
    if [ ! -x "$p" ]; then
      printf '  FAIL missing %s\n' "$p" >&2; bad=$((bad + 1))
    elif ! /bin/sh -n "$p" 2>/dev/null; then
      printf '  FAIL %s failed syntax check\n' "$p" >&2; bad=$((bad + 1))
    fi
  done
  p=$HOME/.local/bin/seedagent
  if [ ! -x "$p" ]; then
    printf '  FAIL missing %s\n' "$p" >&2; bad=$((bad + 1))
  elif ! /bin/sh -n "$p" 2>/dev/null; then
    printf '  FAIL %s failed syntax check\n' "$p" >&2; bad=$((bad + 1))
  fi
  [ -f "$INSTALL/seed.sh" ] || { printf '  FAIL missing seed.sh\n' >&2; bad=$((bad + 1)); }
  if [ ! -f "$INSTALL/.env" ]; then
    printf '  FAIL incomplete .env\n' >&2; bad=$((bad + 1))
  else
    k1=$(grep '^LLM_API_KEY=' "$INSTALL/.env" | sed 's/^LLM_API_KEY=//')
    [ -n "$k1" ] || { printf '  FAIL .env has no key\n' >&2; bad=$((bad + 1)); }
  fi
  intro=$(LAUNCH_CWD=$LAUNCH_CWD SLAB_SKIP_INIT=1 /bin/sh "$INSTALL/bin/agent" </dev/null 2>&1 || true)
  printf '%s' "$intro" | grep -q '>' || { printf '  FAIL agent prompt missing\n' >&2; bad=$((bad + 1)); }
  baked=$(printf '/%s/|/%s/' Users home)
  if grep -E "$baked" "$INSTALL/bin/agent" "$HOME/.local/bin/seedagent" >/dev/null 2>&1; then
    printf '  FAIL shim baked a host path\n' >&2; bad=$((bad + 1))
  fi
  w=$(mktemp -d "${TMPDIR:-/tmp}/seed-ver.XXXXXX")
  w=$(CDPATH= cd "$w" && pwd)
  stub=$w/stub
  printf '0\n' > "$w/n"
  cat > "$stub" <<'STUB'
#!/bin/sh
n=$(cat "$SEED_VER_N")
n=$((n + 1))
printf '%s\n' "$n" > "$SEED_VER_N"
if [ "$n" -eq 1 ]; then
  printf '%s\n' '{"content":"","tool_calls":[{"id":"v1","name":"shell","arguments":"{\"command\":\"pwd\"}"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}'
else
  printf '%s\n' '{"content":"ok","tool_calls":[],"usage":{"prompt_tokens":1,"completion_tokens":1}}'
fi
STUB
  chmod +x "$stub"
  set +e
  (
    cd "$w"
    SLAB_SKIP_INIT=1 SEED_LLM_STUB=$stub SEED_VER_N=$w/n /bin/sh "$HOME/.local/bin/seedagent" --oneshot 'pwd'
  ) > "$w/out" 2> "$w/err"
  set -e
  if ! grep -q ok "$w/out"; then
    printf '  FAIL stub tool_calls did not run\n' >&2; bad=$((bad + 1))
  fi
  if ! grep -FR "$w" "$w/.agent-runs" >/dev/null 2>&1; then
    printf '  FAIL stub workspace was not the temp dir\n' >&2; bad=$((bad + 1))
  fi
  # home separation: state under the home, never next to the entry
  [ -d "$INSTALL/agent-store" ] || { printf '  FAIL agent-store not under home\n' >&2; bad=$((bad + 1)); }
  [ ! -e "$HOME/.local/agent-store" ] || { printf '  FAIL state leaked next to entry\n' >&2; bad=$((bad + 1)); }
  rm -rf "$w"
  [ "$bad" -eq 0 ] || die "verify failed: $bad check(s)" 76
}

product_root() {
  case $SELF in
    */bin/agent) CDPATH= cd "$(dirname "$SELF")/.." && pwd -P ;;
    */bin/seedagent)
      # Global entry on PATH: state home is separate from the entry dir.
      pr=${SEED_AGENT_HOME:-$HOME/.seed-agent}
      mkdir -p "$pr"
      CDPATH= cd "$pr" && pwd -P ;;
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

# Two lines of ready state from the Machine index so plain tasks do not
# burn a round on jq-reading it: which tools are ok.
agent_state_lines() {
  sf=$INSTALL/agent-store/index.json
  [ -f "$sf" ] || return 0
  jq -r '
    "Tools ok: " + ([.system.tools // {} | to_entries[]
      | select(.value.ok == true) | .key] | join(" ")),
    "Blocks: " + (
      (["skills","commands","models","plugins","delegate"]
        - [(.ours.seed_agent // {}) | to_entries[]
           | select(.value == "done") | .key]) as $missing
      | if ($missing | length) == 0 then "all built"
        else "missing " + ($missing | join(" "))
          + " - build a block only when the task needs it, per system.retrieve"
        end)
  ' "$sf" 2>/dev/null || true
}

product_system() {
  printf '%s\nModel: %s (%s)\nMachine index: %s\nProject memory: %s\n' \
    "$(cabin_product_system)" \
    "${LLM_MODEL:-unknown}" \
    "${LLM_PROVIDER:-unknown}" \
    "$INSTALL/agent-store/index.json" \
    "$PWD/.agent-memory/index.json"
  agent_state_lines
  skill_catalog
  agent_run_hooks system
}

agent_plugin_get() {
  ap_body=$(mktemp "${TMPDIR:-/tmp}/seed-aplg.XXXXXX")
  if http_get "$1" "$ap_body"; then
    cat "$ap_body"
    rm -f "$ap_body"
    return 0
  fi
  rm -f "$ap_body"
  [ "$HTTP_CURL" -eq 0 ] || die "agent plugin: network failed (curl=$HTTP_CURL)" 71
  die "agent plugin: HTTP $HTTP_CODE" 72
}

# Best-effort GET into dest. 404 / network fail: leave dest, return 1.
agent_plugin_try() {
  at_body=$(mktemp "${TMPDIR:-/tmp}/seed-aptry.XXXXXX")
  if http_get "$1" "$at_body"; then
    mv "$at_body" "$2"
    return 0
  fi
  rm -f "$at_body"
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

# Shared fetch: take a catalog body, pull required.init, write both under
# agent-store. strict=1 demands the full init pack shape (first fetch).
agent_fetch_pack() {
  fp_strict=$1
  fp_index=$2
  store=$INSTALL/agent-store
  mkdir -p "$store/plugins"
  root=$(plugin_root)
  rel=$(printf '%s' "$fp_index" | jq -r '.required.init // empty')
  [ -n "$rel" ] || die "agent plugin: catalog has no required.init" 69
  body=$(agent_plugin_get "$(plugin_join "$root/agent" "$rel")")
  if [ "$fp_strict" -eq 1 ]; then
    printf '%s' "$body" | jq -e \
      'type == "object" and has("prompt") and has("machine_tree") and has("memory_tree")' \
      >/dev/null 2>&1 || die "agent plugin: init pack invalid" 69
  else
    printf '%s' "$body" | jq -e 'has("prompt")' >/dev/null 2>&1 \
      || die "agent plugin: init pack invalid" 69
  fi
  tmpc=$(mktemp "${TMPDIR:-/tmp}/seed-acat.XXXXXX")
  tmpi=$(mktemp "${TMPDIR:-/tmp}/seed-ainit.XXXXXX")
  printf '%s\n' "$fp_index" > "$tmpc"
  printf '%s\n' "$body" > "$tmpi"
  mv "$tmpi" "$store/plugins/init.json"
  mv "$tmpc" "$store/catalog.json"
  agent_fetch_hooks
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
  agent_fetch_pack 1 "$index"
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

# Deterministic probe: the engine, not the model, fills system.tools
# (command -v for the path, a cheap smoke for ok). The init conversation
# only handles the fuzzy rest: web smoke, skills scan, ready flip.
agent_probe_one() {
  pt=$1
  pb=$(command -v "$pt" 2>/dev/null || true)
  if [ -z "$pb" ]; then
    jq -nc '{present:false,path:"",ok:false,note:"not found"}'
    return 0
  fi
  pok=false
  case $pt in
    sh) "$pb" -c 'echo sh_ok' >/dev/null 2>&1 && pok=true ;;
    jq) "$pb" -n . >/dev/null 2>&1 && pok=true ;;
    *) "$pb" --version >/dev/null 2>&1 && pok=true ;;
  esac
  jq -nc --arg p "$pb" --argjson ok "$pok" \
    '{present:true,path:$p,ok:$ok,note:""}'
}

agent_probe_tools() {
  f=$INSTALL/agent-store/index.json
  [ -f "$f" ] || return 0
  pj=$(mktemp "${TMPDIR:-/tmp}/seed-probe.XXXXXX")
  {
    printf '{'
    sep=
    for pt in sh curl jq rg git python; do
      printf '%s"%s":%s' "$sep" "$pt" "$(agent_probe_one "$pt")"
      sep=,
    done
    printf '}\n'
  } > "$pj"
  tmp=$(mktemp "${TMPDIR:-/tmp}/seed-probew.XXXXXX")
  if jq --slurpfile t "$pj" '
      if (.system? | type) == "object"
      then .system.tools = $t[0]
      else . end
    ' "$f" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"
  fi
  rm -f "$pj"
}

agent_run_init() {
  pack=$INSTALL/agent-store/plugins/init.json
  prompt=$(jq -r '.prompt // empty' "$pack")
  [ -n "$prompt" ] || die "agent plugin: init prompt empty" 69
  ev=${AGENT_RUNS_DIR:-$PWD/.agent-runs}/$(date -u +%Y%m%dT%H%M%SZ)-$$-init
  sess=$ev/session
  mkdir -p "$ev"
  shell_init "$sess" "$PWD"
  INIT_STOP_WHEN_READY=1
  export INIT_STOP_WHEN_READY
  run_loop "$(product_system)" "$prompt" "$sess" "$ev" "$AGENT_MAX_ROUNDS" 0 || :
  unset INIT_STOP_WHEN_READY
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
  agent_probe_tools
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
  agent_fetch_pack 0 "$index"
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

