#!/bin/sh
# seed.sh is the standalone runtime and its only source. Edit this file directly.
#   /bin/sh seed.sh deepseek sk-xxxx
set -eu
umask 077

SELF=$(CDPATH= cd "$(dirname "$0")" && pwd -P)/$(basename "$0")
SEED_VERSION=1
SEED_LAUNCH_PATH=${PATH:-}
AGENT_MAX_ROUNDS=${AGENT_MAX_ROUNDS:-80}
SEED_EMPTY_RETRIES=${SEED_EMPTY_RETRIES:-3}
ACTION_TIMEOUT=${SEED_ACTION_TIMEOUT:-180}
MAX_OBS_BYTES=${SEED_MAX_OBS_BYTES:-16384}
HTTP_TIMEOUT=${SEED_HTTP_TIMEOUT:-300}
HTTP_STALL=${SEED_HTTP_STALL:-300}
LAUNCH_CWD=$(pwd -P)

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-70}"; }

usage() {
  printf 'usage: sh seed.sh <channel|api-url> <API_KEY> [model]\n' >&2
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
  case ${PREFIX:-} in
    *com.termux*)
      if command -v pkg >/dev/null 2>&1; then
        printf 'installing: jq (pkg)\n' >&2
        pkg install -y jq >/dev/null 2>&1 || :
        command -v jq >/dev/null 2>&1 && return 0
      fi ;;
  esac
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
    [ -n "$official" ] || die "need jq (unsupported platform)" 69
    printf 'installing: jq\n' >&2
    jq_fetch "$official" "$dest" || die "need jq (download failed)" 69
  fi
  PATH=$(CDPATH= cd "$(dirname "$dest")" && pwd):$PATH
  export PATH
  command -v jq >/dev/null 2>&1 || die "need jq" 69
}

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

pack_root() {
  printf '%s' "${SEED_PACK_ROOT:-https://raw.githubusercontent.com/Leehow/seed/main/packs}"
}

pack_join() {
  base=$1
  rel=$2
  case $rel in
    http*://*) printf '%s' "$rel" ;;
    /*) printf '%s%s' "$(pack_root)" "$rel" ;;
    *) printf '%s/%s' "$base" "$rel" ;;
  esac
}

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

pack_get() {
  pg_body=$(mktemp "${TMPDIR:-/tmp}/seed-pack.XXXXXX")
  if http_get "$1" "$pg_body" "${2:-}"; then
    cat "$pg_body"
    rm -f "$pg_body"
    return 0
  fi
  rm -f "$pg_body"
  [ "$HTTP_CURL" -eq 0 ] || die "pack: network failed (curl=$HTTP_CURL)" 71
  die "pack: HTTP $HTTP_CODE" 72
}

api_origin() {
  printf '%s' "$1" | awk -F/ '{print $1"//"$3}'
}

load_channel_from_catalog() {
  channel=$1
  need jq
  root=$(pack_root)
  seeddir=$root/seed
  index=$(pack_get "$seeddir/index.json")
  rel=$(printf '%s' "$index" | jq -r '.models // empty')
  [ -n "$rel" ] || die 'seed index has no models pack' 69
  catalog=$(pack_get "$(pack_join "$seeddir" "$rel")")
  row=$(printf '%s' "$catalog" | jq -c --arg n "$channel" '.[$n] // empty')
  if [ -z "$row" ]; then
    keys=$(printf '%s' "$catalog" | jq -r 'keys | join(" ")')
    die "unknown channel: $channel (have: $keys)" 64
  fi
  raw_api=$(printf '%s' "$row" | jq -r '.api_url // empty')
  [ -n "$raw_api" ] || die "channel $channel has no api_url" 69
  LLM_API_URL=$(pack_join "$seeddir" "$raw_api")
  LLM_EXTRA=$(printf '%s' "$row" | jq -c '.extra // {}')
  raw_models=$(printf '%s' "$row" | jq -r '.models_url // empty')
  if [ -n "$raw_models" ]; then
    MODELS_URL=$(pack_join "$seeddir" "$raw_models")
  else
    case $LLM_API_URL in
      */chat/completions) MODELS_URL=${LLM_API_URL%/chat/completions}/models ;;
      *) MODELS_URL=$(api_origin "$LLM_API_URL")/v1/models ;;
    esac
  fi
}

pick_model_once() {
  need jq
  list=$(pack_get "$MODELS_URL" "$LLM_API_KEY")
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
Reply in the same language the human just used.
Do not stream your process to the human. When the task is done, reply with a short final answer and no tool_calls.
EOF
}

cabin_agent_system() {
  cat <<'EOF'
Before acting, read the Machine index with shell (jq, not cat of the whole file) and follow system.retrieve.
The index is a helper catalog, not the problem. jq it for ok matches; do not rewrite the human's ask into index key names.
When the human asks about skills or SKILL.md, open https://agentskills.io/specification with shell first.
When the human's message starts with /, it is a slash command, not a coding task: follow system.retrieve and build the commands pack first if the table is missing.
When the human asks what tools you have, what you can use, or what was indexed: first jq the Machine index. Then list (1) the two API tools shell and edit, (2) every ok entry that system.retrieve tells you to use. Mention present-but-not-ok items separately. Do not answer with only shell and edit. Do not dump the raw index.
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
  /bin/sh "$session/worker.sh" "$session" \
    </dev/null >"$session/worker.out" 2>"$session/worker.err" &
  echo $! > "$session/pid"
}

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
          | ($t.id // "") as $nid
          | ($t.function.name // "") as $nname
          | .tools[$i].id = (if $nid != "" then $nid else (.tools[$i].id // "") end)
          | .tools[$i].name = (if $nname != "" then $nname else (.tools[$i].name // "") end)
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

model_turn() {
  in_msgs=$1
  dest=$2
  work=$(mktemp -d "${TMPDIR:-/tmp}/seed-llm.XXXXXX")
  strip_msg_thinking "$in_msgs" "$work/msgs.json"
  if [ -n "${SEED_LLM_STUB:-}" ]; then
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
      curl -q -N -sS --connect-timeout 15 \
        --speed-limit 1 --speed-time "$HTTP_STALL" -X POST \
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
      0:2*)
        if [ "$stream" = true ] \
          && ! grep -q '"finish_reason"[[:space:]]*:[[:space:]]*"' "$work/raw"; then
          if [ "$try" -eq 1 ]; then
            try=2
            printf 'llm: truncated stream, retry\n' >&2
            sleep 2
            continue
          fi
          rm -rf "$work"
          printf 'error: llm: truncated stream\n' >&2
          return 71
        fi
        break
        ;;
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
      # A syntax error inside the worker's eval exits the shell running it,
      # which ends the session: every later command then waits out the action
      # timeout for a reply that can never come, and the model, told only
      # "timeout", sends the same thing again. Parse it first with the shell
      # that would run it and hand back the error, which says what to fix.
      syn=$(printf '%s\n' "$cmd" | /bin/sh -n 2>&1) || {
        printf 'shell: not run, the command does not parse:\n%s\n' "$syn" > "$outf"
        return 0
      }
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
      if [ -n "$content" ] && [ "${SEED_STREAM_PRINT:-}" != 1 ]; then
        printf '%s\n' "$content" >&2
      fi
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
      compact_content=$(printf '%s' "$content" | tr -d '[:space:]')
      if [ -z "$compact_content" ]; then
        empty_tries=$(cat "$evdir/empty-retries" 2>/dev/null || echo 0)
        case $empty_tries in ''|*[!0-9]*) empty_tries=0 ;; esac
        case ${SEED_EMPTY_RETRIES:-3} in
          ''|*[!0-9]*) empty_max=3 ;;
          *) empty_max=$SEED_EMPTY_RETRIES ;;
        esac
        if [ "$empty_tries" -lt "$empty_max" ]; then
          empty_tries=$((empty_tries + 1))
          printf '%s\n' "$empty_tries" > "$evdir/empty-retries"
          printf 'llm: empty turn, retry %s/%s\n' "$empty_tries" "$empty_max" >&2
          jq '. + [{role:"user",content:"Your previous response was empty. Continue the task: use tools if needed, or provide a non-empty final response."}]' \
            "$msgs" > "$msgs.n" && mv "$msgs.n" "$msgs"
          round=$((round + 1))
          continue
        fi
        printf 'error: llm: empty turn retry limit reached (%s)\n' "$empty_max" >&2
        return 74
      fi
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

product_root() {
  CDPATH= cd "$(dirname "$SELF")" && pwd -P
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

agent_state_lines() {
  sf=$INSTALL/agent-store/index.json
  [ -f "$sf" ] || return 0
  jq -r '
    "Tools ok: " + ([.system.tools // {} | to_entries[]
      | select(.value.ok == true) | .key] | join(" ")),
    "Blocks: " + (
      (["skills","commands","models","packs","delegate"]
        - [(.ours.seed_agent // {}) | to_entries[]
           | select(.value == "done") | .key]) as $missing
      | if ($missing | length) == 0 then "all built"
        else "missing " + ($missing | join(" "))
          + " - build a pack only when the task needs it, per system.retrieve"
        end)
  ' "$sf" 2>/dev/null || true
}

product_system() {
  cabin_product_system
  printf 'Model: %s (%s)\n' "${LLM_MODEL:-unknown}" "${LLM_PROVIDER:-unknown}"
  if [ "${SEED_RUN_MODE:-agent}" = simple ]; then
    printf 'Mode: simple. No Agent Pack, Machine index, or /packs.\n'
    return 0
  fi
  cabin_agent_system
  printf 'Machine index: %s\nProject memory: %s\nSEED_SELF=%s\n' \
    "$INSTALL/agent-store/index.json" \
    "$PWD/.agent-memory/index.json" \
    "${SEED_SELF:-}"
  agent_state_lines
  skill_catalog
}

agent_pack_get() {
  ap_body=$(mktemp "${TMPDIR:-/tmp}/seed-apack.XXXXXX")
  if http_get "$1" "$ap_body"; then
    cat "$ap_body"
    rm -f "$ap_body"
    return 0
  fi
  rm -f "$ap_body"
  [ "$HTTP_CURL" -eq 0 ] || die "agent pack: network failed (curl=$HTTP_CURL)" 71
  die "agent pack: HTTP $HTTP_CODE" 72
}

agent_ready() {
  f=$INSTALL/agent-store/index.json
  [ -f "$f" ] || return 1
  jq -e '.ready == true' "$f" >/dev/null 2>&1
}

agent_repair_machine_tree() {
  f=$INSTALL/agent-store/index.json
  pack=$INSTALL/agent-store/packs/init.json
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
  f=${1:-$INSTALL/agent-store/index.json}
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

agent_baseline_file() {
  printf '%s\n' "$INSTALL/agent-store/index.baseline.json"
}

agent_discard_baseline() {
  rm -f "$(agent_baseline_file)"
}

agent_write_baseline() {
  store=$INSTALL/agent-store
  pack=$store/packs/init.json
  base=$(agent_baseline_file)
  [ -f "$pack" ] || return 1
  pj=$(mktemp "${TMPDIR:-/tmp}/seed-basep.XXXXXX")
  {
    printf '{'
    sep=
    for pt in sh curl jq rg git python; do
      printf '%s"%s":%s' "$sep" "$pt" "$(agent_probe_one "$pt")"
      sep=,
    done
    printf '}\n'
  } > "$pj"
  tmp=$(mktemp "${TMPDIR:-/tmp}/seed-basew.XXXXXX")
  if jq --slurpfile t "$pj" '
      .machine_tree
      | .ready = true
      | .system.tools = $t[0]
    ' "$pack" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$base"
    rm -f "$pj"
    agent_check_machine_tree "$base"
    return $?
  fi
  rm -f "$tmp" "$pj"
  return 1
}

agent_restore_baseline() {
  base=$(agent_baseline_file)
  dest=$INSTALL/agent-store/index.json
  [ -f "$base" ] || return 1
  agent_check_machine_tree "$base" || return 1
  mv "$base" "$dest"
  agent_check_machine_tree "$dest"
}

agent_fetch_pack() {
  fp_strict=$1
  fp_index=$2
  store=$INSTALL/agent-store
  mkdir -p "$store/packs"
  root=$(pack_root)
  rel=$(printf '%s' "$fp_index" | jq -r '.required.init // empty')
  [ -n "$rel" ] || die "agent pack: catalog has no required.init" 69
  body=$(agent_pack_get "$(pack_join "$root/agent" "$rel")")
  if [ "$fp_strict" -eq 1 ]; then
    printf '%s' "$body" | jq -e \
      'type == "object" and has("prompt") and has("machine_tree") and has("memory_tree")' \
      >/dev/null 2>&1 || die "agent pack: init pack invalid" 69
  else
    printf '%s' "$body" | jq -e 'has("prompt")' >/dev/null 2>&1 \
      || die "agent pack: init pack invalid" 69
  fi
  tmpc=$(mktemp "${TMPDIR:-/tmp}/seed-acat.XXXXXX")
  tmpi=$(mktemp "${TMPDIR:-/tmp}/seed-ainit.XXXXXX")
  printf '%s\n' "$fp_index" > "$tmpc"
  printf '%s\n' "$body" > "$tmpi"
  mv "$tmpi" "$store/packs/init.json"
  mv "$tmpc" "$store/catalog.json"
}

agent_fetch_required() {
  store=$INSTALL/agent-store
  mkdir -p "$store/packs"
  if [ -f "$store/catalog.json" ] && [ -f "$store/packs/init.json" ]; then
    return 0
  fi
  root=$(pack_root)
  index=$(agent_pack_get "$root/agent/index.json")
  printf '%s' "$index" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || die "agent pack: catalog is not JSON" 69
  agent_fetch_pack 1 "$index"
}

agent_try_update() {
  [ "${SEED_SKIP_UPDATE:-}" = 1 ] && return 0
  [ -f "$INSTALL/agent-store/catalog.json" ] || return 0
  if ( agent_update ) 2>/dev/null; then
    return 0
  fi
  printf 'note: pack catalog refresh skipped\n' >&2
  return 0
}

agent_place_trees() {
  store=$INSTALL/agent-store
  pack=$store/packs/init.json
  [ -f "$pack" ] || die "agent pack: init pack missing" 69
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

agent_probe_one() {
  pt=$1
  pb=$(command -v "$pt" 2>/dev/null || true)
  if [ -z "$pb" ] && [ "$pt" = python ]; then
    pb=$(command -v python3 2>/dev/null || true)
  fi
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
  pack=$INSTALL/agent-store/packs/init.json
  prompt=$(jq -r '.prompt // empty' "$pack")
  [ -n "$prompt" ] || die "agent pack: init prompt empty" 69
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
}

agent_ensure_init() {
  [ "${SLAB_SKIP_INIT:-}" = 1 ] && return 0
  agent_repair_machine_tree || true
  if agent_check_machine_tree; then
    agent_try_update
    agent_probe_tools
    agent_discard_baseline
    return 0
  fi
  if agent_restore_baseline; then
    agent_probe_tools
    return 0
  fi
  printf 'initializing:\n' >&2
  agent_fetch_required
  agent_place_trees
  agent_probe_tools
  agent_write_baseline || die "init failed" 76
  SEED_STREAM=1
  SEED_STREAM_PRINT=1
  export SEED_STREAM SEED_STREAM_PRINT
  agent_run_init
  agent_repair_machine_tree || true
  agent_probe_tools
  if agent_check_machine_tree; then
    agent_discard_baseline
    printf 'ready\n' >&2
    return 0
  fi
  if agent_restore_baseline; then
    printf 'note: optional discovery skipped\n' >&2
    printf 'ready\n' >&2
    return 0
  fi
  die "init failed" 76
}

agent_update() {
  store=$INSTALL/agent-store
  mkdir -p "$store/packs"
  root=$(pack_root)
  index=$(agent_pack_get "$root/agent/index.json")
  printf '%s' "$index" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || die "agent pack: catalog is not JSON" 69
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
    nr=$(jq -r '.machine_tree.system.retrieve // empty' "$store/packs/init.json")
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

seed_usage() {
  printf 'usage: sh seed.sh <channel|api-url> <API_KEY> [model]\n' >&2
  printf '       sh seed.sh setup\n' >&2
  printf '       sh seed.sh load <file|-|url>\n' >&2
}

seed_help() {
  printf '%s\n' \
    'seed: type a task to work in the launch directory.' \
    '/help                 show this help' \
    '/ini                  install the global command seed' \
    '/packs                list published packs' \
    '/packs install <slug> install a published pack' \
    '/pack <slug>          alias for /packs install' \
    'sh seed.sh setup      choose Agent or Simple' \
    'sh seed.sh load -     load pack JSON from stdin'
}

seed_state_root() {
  if [ -n "${SEED_HOME:-}" ]; then
    printf '%s\n' "$SEED_HOME"
  else
    [ -n "${HOME:-}" ] || die 'HOME is unset; set SEED_HOME' 64
    printf '%s/.seed\n' "$HOME"
  fi
}

seed_mv() {
  SEED_MV_N=$((${SEED_MV_N:-0} + 1))
  [ "${SEED_TEST_FAIL_AT:-}" = "$SEED_MV_N" ] && return 1
  mv "$1" "$2.new" && mv "$2.new" "$2"
}

seed_pack_undo() {
  u=$1 s=$2 r=$3
  for f in "$u/bak/p"/*; do
    [ -f "$f" ] || continue
    mv "$f" "$s/packs/$(basename "$f")"
  done
  for f in "$u/new/p"/*; do
    [ -e "$f" ] || continue
    b=$(basename "$f")
    rm -f "$s/packs/$b" "$s/packs/$b.new"
  done
  if [ -f "$u/bak/c" ]; then mv "$u/bak/c" "$s/catalog.json"
  elif [ -f "$u/new/c" ]; then rm -f "$s/catalog.json" "$s/catalog.json.new"
  fi
  if [ -f "$u/bak/r" ]; then mv "$u/bak/r" "$r"
  elif [ -f "$u/new/r" ]; then rm -f "$r" "$r.new"
  fi
}

seed_plan() {
  [ ! -L "$1" ] && { [ ! -e "$1" ] || [ -f "$1" ]; } || return 1
  if [ -f "$1" ]; then cp "$1" "$2"; else : > "$3"; fi
}

seed_pack_slug_ok() {
  case $1 in
    ''|*[!a-zA-Z0-9._-]*|.*|-*) return 1 ;;
  esac
  case $1 in
    [a-zA-Z0-9]*) return 0 ;;
  esac
  return 1
}

seed_pack_apply() {
  src=$1
  need jq
  jq -e 'type == "object"' "$src" >/dev/null 2>&1 || {
    printf 'error: pack is not JSON\n' >&2; return 69
  }
  slug=$(jq -r '.slug // empty' "$src")
  if [ -z "$slug" ] && jq -e 'has("prompt")' "$src" >/dev/null 2>&1; then slug=pack; fi
  seed_pack_slug_ok "$slug" || {
    printf 'error: pack has no usable slug\n' >&2; return 69
  }
  store=$INSTALL/agent-store
  mkdir -p "$store/packs" "$store/loaded"
  stg=$(mktemp -d "${TMPDIR:-/tmp}/seed-stg.XXXXXX") || return 70
  mkdir -p "$stg/p"
  e=
  if jq -e 'has("files")' "$src" >/dev/null 2>&1; then
    if ! jq -e '.files | type == "object"' "$src" >/dev/null 2>&1; then
      e='pack files must be an object'
      n=0
    else
      n=$(jq '.files | keys | length' "$src")
    fi
    i=0
    while [ -z "$e" ] && [ "$i" -lt "$n" ]; do
      name=$(jq -r --argjson i "$i" '.files | keys[$i]' "$src")
      i=$((i + 1))
      case $name in ''|.*|*/*|*..*) e="illegal pack path: $name" ;; esac
      [ -n "$e" ] || jq --arg n "$name" '.files[$n]' "$src" > "$stg/p/$name"
    done
    if [ -z "$e" ] && jq -e '.files["init.json"] | type == "object" and has("machine_tree")' \
        "$src" >/dev/null 2>&1; then
      if jq -e '.index | type == "object"' "$src" >/dev/null 2>&1; then
        jq '.index' "$src" > "$stg/catalog.json"
      elif jq -e '.files["index.json"] | type == "object"' "$src" >/dev/null 2>&1; then
        jq '.files["index.json"]' "$src" > "$stg/catalog.json"
      fi
    fi
  else
    jq '.' "$src" > "$stg/p/$slug.json"
  fi
  rec=$store/loaded/$slug.json
  if [ -z "$e" ]; then
    set -- "$stg/p"/*
    [ -f "$1" ] || e='pack has no files'
  fi
  mkdir -p "$stg/bak/p" "$stg/new/p"
  if [ -z "$e" ]; then
    if [ -L "$store" ] || [ -L "$store/packs" ] || [ -L "$store/loaded" ]; then
      e='pack dest is not a regular file'
    fi
    for f in "$stg/p"/*; do
      [ -z "$e" ] && [ -f "$f" ] || continue
      b=$(basename "$f")
      seed_plan "$store/packs/$b" "$stg/bak/p/$b" "$stg/new/p/$b" \
        || e='pack dest is not a regular file'
    done
    if [ -z "$e" ] && [ -f "$stg/catalog.json" ]; then
      seed_plan "$store/catalog.json" "$stg/bak/c" "$stg/new/c" \
        || e='pack dest is not a regular file'
    fi
    if [ -z "$e" ]; then
      seed_plan "$rec" "$stg/bak/r" "$stg/new/r" \
        || e='pack dest is not a regular file'
    fi
  fi
  if [ -n "$e" ]; then
    rm -rf "$stg"
    printf 'error: %s\n' "$e" >&2
    return 69
  fi
  cp "$src" "$stg/r.json"
  SEED_MV_N=0
  ok=1
  for f in "$stg/p"/*; do
    [ "$ok" -eq 1 ] && [ -f "$f" ] || continue
    seed_mv "$f" "$store/packs/$(basename "$f")" || ok=0
  done
  [ "$ok" -eq 1 ] && [ -f "$stg/catalog.json" ] && {
    seed_mv "$stg/catalog.json" "$store/catalog.json" || ok=0
  }
  [ "$ok" -eq 1 ] && { seed_mv "$stg/r.json" "$rec" || ok=0; }
  if [ "$ok" -ne 1 ] || [ ! -s "$rec" ]; then
    seed_pack_undo "$stg" "$store" "$rec"
    rm -rf "$stg"
    printf 'error: pack persist failed\n' >&2; return 70
  fi
  rm -rf "$stg"
  printf 'loaded: %s\n' "$slug"
}

seed_runtime_ok() {
  [ -f "$1" ] && [ -r "$1" ] || return 1
  grep -q 'seed.sh is the standalone runtime' "$1" 2>/dev/null
}

seed_materialize() {
  dest=$INSTALL/.seed-runtime.sh
  seed_runtime_ok "$dest" && return 0
  src=${SEED_RUNTIME_URL:-https://seed-agents.com/dl/seed.sh}
  tmp=$dest.tmp
  case $src in
    /*) [ -f "$src" ] && cp "$src" "$tmp" || die 'cannot materialize seed runtime: source missing' 69 ;;
    http://*|https://*)
      need curl
      http_get "$src" "$tmp" || { rm -f "$tmp"; die 'cannot materialize seed runtime: network failed' 71; } ;;
    *) die 'cannot materialize seed runtime: invalid source' 64 ;;
  esac
  if seed_runtime_ok "$tmp" && /bin/sh -n "$tmp"; then mv "$tmp" "$dest"; return 0; fi
  rm -f "$tmp"
  die 'cannot materialize seed runtime: invalid file' 69
}

seed_bind_self() {
  wrap=$INSTALL/seed
  cache=$INSTALL/.seed-runtime.sh
  rt=
  if seed_runtime_ok "${SEED_SELF:-}"; then rt=$SEED_SELF
  elif seed_runtime_ok "$SELF"; then rt=$SELF
  elif seed_runtime_ok "$cache"; then rt=$cache
  else
    seed_materialize
    rt=$cache
  fi
  if [ "$rt" = "$wrap" ]; then
    SEED_SELF=$wrap
    chmod +x "$SEED_SELF" 2>/dev/null || true
    seed_runtime_ok "$SEED_SELF" || die 'SEED_SELF is not a usable seed runtime' 69
    return 0
  fi
  tmp=$wrap.tmp
  printf '#!/bin/sh\nexec /bin/sh "%s" "$@"\n' "$rt" > "$tmp"
  chmod +x "$tmp"
  mv "$tmp" "$wrap"
  SEED_SELF=$wrap
  seed_runtime_ok "$rt" && [ -x "$SEED_SELF" ] || die 'SEED_SELF is not a usable seed runtime' 69
}

seed_prepare_state() {
  state=$(seed_state_root)
  mkdir -p "$state"
  INSTALL=$(CDPATH= cd "$state" && pwd -P)
  export SEED_HOME=$INSTALL
  seed_bind_self
  export SEED_SELF
}

seed_ask_mode() {
  src=
  if [ -t 0 ] || [ "${1:-}" = setup ]; then
    src=stdin
  elif (exec </dev/tty) 2>/dev/null; then
    src=tty
  else
    printf 'agent\n'; return 0
  fi
  printf '%s\n' \
    'Choose your experience:' \
    '1) Agent (recommended) - official Agent Pack, then /packs /help' \
    '2) Simple - base loop only (shell + edit), no Agent Pack' >&2
  while :; do
    printf 'Choice [1]: ' >&2
    ans=
    if [ "$src" = stdin ]; then
      IFS= read -r ans || ans=
    elif ! IFS= read -r ans </dev/tty 2>/dev/null; then
      printf 'agent\n'; return 0
    fi
    case $ans in
      ''|1|agent) printf 'agent\n'; return 0 ;;
      2|simple) printf 'simple\n'; return 0 ;;
    esac
    printf 'error: enter 1 or 2\n' >&2
  done
}

seed_resolve_mode() {
  ask=${1:-}
  mf=$INSTALL/agent-store/mode
  m=${SEED_MODE:-}
  if [ -n "$m" ]; then
    case $m in
      agent|simple) ;;
      *) die 'SEED_MODE must be agent or simple' 64 ;;
    esac
    SEED_RUN_MODE=$m
    if [ "$ask" = setup ] || [ ! -f "$mf" ]; then
      mkdir -p "$INSTALL/agent-store"
      printf '%s\n' "$m" > "$mf"
    fi
    export SEED_RUN_MODE
    [ "$ask" = setup ] && printf 'mode: %s\n' "$m"
    return 0
  fi
  if [ "$ask" != setup ] && [ -f "$mf" ]; then
    IFS= read -r m < "$mf" || m=
    case $m in agent|simple)
      SEED_RUN_MODE=$m; export SEED_RUN_MODE; return 0 ;;
    esac
  fi
  SEED_RUN_MODE=$(seed_ask_mode "$ask")
  mkdir -p "$INSTALL/agent-store"
  printf '%s\n' "$SEED_RUN_MODE" > "$mf"
  export SEED_RUN_MODE
  printf 'mode: %s\n' "$SEED_RUN_MODE"
}

seed_load_main() {
  [ $# -eq 1 ] || { printf 'usage: sh seed.sh load <file|-|url>\n' >&2; exit 64; }
  src=$1
  seed_prepare_state
  ensure_jq
  body=$(mktemp "${TMPDIR:-/tmp}/seed-load.XXXXXX")
  if [ "$src" = - ]; then
    cat > "$body" || { rm -f "$body"; die 'pack: failed to read stdin' 74; }
  elif [ -f "$src" ]; then
    cat "$src" > "$body"
  else
    case $src in
      http://*|https://*)
        need curl
        http_get "$src" "$body" || {
          c=${HTTP_CURL:-1}; rm -f "$body"
          [ "$c" -ne 0 ] && die "pack: network failed (curl=$c)" 71
          die "pack: HTTP $HTTP_CODE from $src" 71
        } ;;
      *) rm -f "$body"; die "pack: not a file or URL: $src" 64 ;;
    esac
  fi
  [ -s "$body" ] || { rm -f "$body"; die 'pack: empty input' 69; }
  st=0
  seed_pack_apply "$body" || st=$?
  rm -f "$body"
  [ "$st" -eq 0 ] || exit "$st"
}

seed_http_err() {
  if [ "${HTTP_CURL:-1}" -ne 0 ]; then
    printf 'error: %s: network failed (curl=%s)\n' "$1" "$HTTP_CURL" >&2
  else
    printf 'error: %s: HTTP %s\n' "$1" "$HTTP_CODE" >&2
  fi
}

seed_packs_list() {
  need curl
  need jq
  url=https://seed-agents.com/dl/packs.json
  body=$(mktemp "${TMPDIR:-/tmp}/seed-packs.XXXXXX")
  if ! http_get "$url" "$body"; then
    seed_http_err 'packs catalog'
    rm -f "$body"
    return 71
  fi
  if ! jq -e '.packs | type == "array"' "$body" >/dev/null 2>&1; then
    printf 'error: packs catalog: unexpected JSON\n' >&2
    rm -f "$body"
    return 69
  fi
  if [ "$(jq '.packs | length' "$body")" -eq 0 ]; then
    printf 'packs: none published\n'
  else
    jq -r '.packs[] |
      (.slug // "?") as $s |
      (.description // .name // "") as $d |
      if $d == "" then $s else "\($s)  \($d)" end' "$body" || {
      printf 'error: packs catalog: unexpected JSON\n' >&2
      rm -f "$body"
      return 69
    }
  fi
  rm -f "$body"
}

seed_packs_install() {
  slug=$1
  if ! seed_pack_slug_ok "$slug"; then
    printf 'error: invalid pack name: %s\n' "$slug" >&2
    return 64
  fi
  need curl
  need jq
  url=https://seed-agents.com/dl/packs/$slug.json
  body=$(mktemp "${TMPDIR:-/tmp}/seed-pinst.XXXXXX")
  if ! http_get "$url" "$body"; then
    seed_http_err "pack $slug"
    rm -f "$body"
    return 71
  fi
  st=0
  seed_pack_apply "$body" || st=$?
  rm -f "$body"
  return "$st"
}

seed_trim() {
  s=$1
  while [ "$s" != "${s# }" ]; do s=${s# }; done
  while [ "$s" != "${s% }" ]; do s=${s% }; done
  printf '%s' "$s"
}

seed_pack_cmd() {
  if [ "${SEED_RUN_MODE:-}" = simple ]; then
    printf 'error: pack commands need Agent mode. Run: sh seed.sh setup\n' >&2
    return 64
  fi
  cmd=$1
  case $cmd in
    /packs) seed_packs_list ;;
    /packs\ install\ *)
      slug=$(seed_trim "${cmd#/packs install }")
      [ -n "$slug" ] || {
        printf 'error: usage: /packs install <slug>\n' >&2; return 64
      }
      seed_packs_install "$slug" ;;
    /pack\ *)
      slug=$(seed_trim "${cmd#/pack }")
      [ -n "$slug" ] || {
        printf 'error: usage: /pack <slug>\n' >&2; return 64
      }
      seed_packs_install "$slug" ;;
    *)
      printf 'error: usage: /packs | /packs install <slug> | /pack <slug>\n' >&2
      return 64 ;;
  esac
}

seed_cli_slash() {
  cmd=$1
  shift
  for a in "$@"; do cmd="$cmd $a"; done
  seed_prepare_state
  seed_resolve_mode
  seed_pack_cmd "$cmd"
}

seed_probe() {
  state=$(seed_state_root)
  case $state in
    /*) ;;
    *) state=$LAUNCH_CWD/$state ;;
  esac
  printf 'seed.identity=seed\n'
  printf 'seed.version=%s\n' "$SEED_VERSION"
  printf 'seed.state=%s\n' "$state"
  printf 'seed.workspace=%s\n' "$LAUNCH_CWD"
}

seed_save_config() {
  mkdir -p "$INSTALL"
  write_env_file "$INSTALL/.env"
}

seed_load_or_activate() {
  case $# in
    0)
      ensure_jq
      if [ -z "${LLM_API_KEY:-}" ] && [ -f "$INSTALL/.env" ]; then
        set -a
        . "$INSTALL/.env"
        set +a
      fi
      [ -n "${LLM_API_KEY:-}" ] || die 'first run: sh seed.sh deepseek <API_KEY>' 64
      LLM_PROVIDER=${LLM_PROVIDER:-deepseek}
      LLM_API_URL=${LLM_API_URL:-https://api.deepseek.com/chat/completions}
      LLM_MODEL=${LLM_MODEL:-deepseek-v4-flash}
      LLM_EXTRA=${LLM_EXTRA:-'{}'}
      ;;
    2|3)
      ensure_jq
      resolve_provider "$1" "$2" "${3:-}"
      seed_save_config
      ;;
    *) seed_usage; exit 64 ;;
  esac
  disable_thinking
}

seed_install_prompt() {
  receipt=$INSTALL/install-result.json
  cat <<EOF
Install this already-running standalone seed runtime as a global command named seed.

This is an explicitly authorized installation operation. Inspect the live POSIX environment and PATH with the shell tool. Choose a user-owned, writable installation method appropriate to the environment. You may copy the runtime, make a symbolic link, or create a tiny POSIX /bin/sh shim. Do not use sudo, do not modify another seed installation, and never read or print API keys or .env files.

Runtime source: $SELF
State directory: $INSTALL
Required receipt: $receipt
Stable original launch PATH: $SEED_LAUNCH_PATH
Current internal runtime PATH: $PATH

Only the stable original launch PATH is accepted as proof that the command remains reachable after this seed process exits. The runtime may have temporarily prepended directories such as the state directory's bin subdirectory solely to host dependencies. Do not install seed into a directory found only in the current internal runtime PATH. A future-login-only profile change is not enough unless reachability can be proven now through the stable original launch PATH.

Before finishing, use the shell tool to write the receipt as one JSON object with exactly these required string fields (extra fields are allowed):
  {"command":"seed","entry":"/absolute/path/to/the/executable-entry"}
Before you write the receipt, run the command itself under the stable original launch PATH and confirm it answers; the outer runtime will not tell you why it rejected an install, so an untested one is a coin flip. The entry must be executable and must actually run: a symbolic link to a file that has no execute bit is neither, and a /bin/sh shim that calls the runtime by path avoids the question entirely. The entry must be exactly the string that command -v seed prints under the stable original launch PATH: the PATH entry itself. If you installed a symbolic link, that is the link's own path, not the path it points at. Do not claim success unless the files and receipt exist. The outer runtime will independently validate everything after this turn.
EOF
}

seed_validate_install() {
  receipt=$INSTALL/install-result.json
  [ -f "$receipt" ] || { printf 'error: install receipt missing\n' >&2; return 76; }
  if ! jq -e '.command == "seed" and (.entry | type == "string") and (.entry | length > 1)' \
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
  resolved=$(PATH=$SEED_LAUNCH_PATH command -v seed 2>/dev/null || true)
  [ "$resolved" = "$entry" ] || {
    printf 'error: installed seed is not the PATH entry\n' >&2
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
  probe=$(PATH=$SEED_LAUNCH_PATH SEED_HOME=$INSTALL "$resolved" --probe 2>/dev/null) || {
    printf 'error: install entry probe failed\n' >&2
    return 76
  }
  printf '%s\n' "$probe" | grep -qx 'seed.identity=seed' || {
    printf 'error: install entry identity mismatch\n' >&2
    return 76
  }
  printf '%s\n' "$probe" | grep -qx "seed.version=$SEED_VERSION" || {
    printf 'error: install entry version mismatch\n' >&2
    return 76
  }
  printf '%s\n' "$probe" | grep -qxF "seed.state=$INSTALL" || {
    printf 'error: install entry state mismatch\n' >&2
    return 76
  }
  printf 'installed: %s\n' "$entry" >&2
}

seed_install_global() {
  ev=${AGENT_RUNS_DIR:-$PWD/.agent-runs}/$(date -u +%Y%m%dT%H%M%SZ)-$$-ini
  sess=$ev/session
  mkdir -p "$ev"
  rm -f "$INSTALL/install-result.json"
  shell_init "$sess" "$PWD"
  is=0
  run_loop "$(product_system)" "$(seed_install_prompt)" "$sess" "$ev" "$AGENT_MAX_ROUNDS" 0 || is=$?
  shell_stop "$sess" 2>/dev/null || :
  [ "$is" -eq 0 ] || { printf 'error: global install model turn failed\n' >&2; return "$is"; }
  seed_validate_install
}

seed_run_task() {
  task=$1
  case $task in
    /ini) seed_install_global; return $? ;;
    /packs|/packs\ *|/pack|/pack\ *) seed_pack_cmd "$task"; return $? ;;
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

seed_main() {
  oneshot=0
  task=
  if [ "${1:-}" = --oneshot ] || [ "${1:-}" = -p ]; then
    oneshot=1
    shift
    task=$*
    set --
  fi
  seed_prepare_state
  seed_load_or_activate "$@"
  seed_resolve_mode
  [ "$SEED_RUN_MODE" = simple ] || agent_ensure_init
  SEED_STREAM=1
  SEED_STREAM_PRINT=0
  export SEED_STREAM SEED_STREAM_PRINT
  evn=0
  last_msgs=
  sess=${AGENT_RUNS_DIR:-$PWD/.agent-runs}/seed-session-$$
  shell_init "$sess" "$PWD"
  if [ "$oneshot" -eq 1 ]; then
    st=0
    seed_run_task "$task" || st=$?
    shell_stop "$sess" 2>/dev/null || :
    return "$st"
  fi
  while true; do
    printf '> ' >&2
    if ! IFS= read -r line; then printf '\n' >&2; break; fi
    [ -n "$line" ] || break
    line_status=0
    seed_run_task "$line" || line_status=$?
    if [ "$line" = /ini ] && [ "$line_status" -ne 0 ]; then
      shell_stop "$sess" 2>/dev/null || :
      return "$line_status"
    fi
  done
  shell_stop "$sess" 2>/dev/null || :
}

case ${1:-} in
  --probe) seed_probe; exit 0 ;;
  load)
    shift
    seed_load_main "$@"
    exit $? ;;
  setup)
    seed_prepare_state
    seed_resolve_mode setup
    exit $? ;;
  /help)
    seed_help
    exit 0 ;;
  /packs|/pack)
    seed_cli_slash "$@"
    exit $? ;;
  --oneshot|-p)
    # One-shot operation uses the existing saved activation.
    seed_main "$@"
    exit $? ;;
  -*) seed_usage; exit 64 ;;
esac

seed_main "$@"

