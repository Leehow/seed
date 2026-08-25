#!/bin/sh
# seed.sh is the standalone runtime and its only source. Edit this file directly.
#   /bin/sh seed.sh deepseek sk-xxxx
set -eu
umask 077

SELF=$(CDPATH= cd "$(dirname "$0")" && pwd -P)/$(basename "$0")
SEED_VERSION=2
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

# The published site. One knob when the host moves; the three endpoints
# below stay individually overridable for testing against a branch.
seed_site() {
  printf '%s' "${SEED_SITE:-https://seed-agents.com}"
}

packs_index_url() {
  printf '%s' "${SEED_PACKS_INDEX:-$(seed_site)/dl/packs.json}"
}

packs_dl_url() {
  printf '%s' "${SEED_PACKS_DL:-$(seed_site)/dl/packs}/$1.json"
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
For a matching skill location, read that file; for a legacy location that is a directory, read its SKILL.md.
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
  # Per-run provenance env: the worker snapshots this process env at spawn
  # time, so live exports alone never reach commands of runs that start
  # later. run_provenance writes this file; re-source it before every command.
  if [ -f "$SESSION/run-env" ]; then . "$SESSION/run-env"; fi
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
  sc_task=${1:-}
  scf=$INSTALL/agent-store/index.json
  [ -f "$scf" ] || return 0
  jq -r --arg task "$sc_task" '
    def esc: gsub("&";"&amp;") | gsub("<";"&lt;") | gsub(">";"&gt;");
    def tokens:
      ($task | ascii_downcase | gsub("[^a-z0-9]+"; " ") | split(" ")
       | map(select(length >= 2))
       | map(select(. as $w
           | ["a","an","the","and","or","of","to","in","on","for","with",
              "by","is","it","this","that","from","as","at","be","if","via",
              "vs","using","use"] | index($w) | not)));
    . as $root
    | tokens as $tokens
    | (.agent.skills // .system.skills // [])
    | map(select(.ok == true and ((.name // "") | length) > 0)) as $all
    | ($all | map(select((.source // "") != "experience"))) as $ordinary
    | ($all
       | map(select((.source // "") == "experience"))
       | map(. as $s
           | (($s.scope.os // []) | map(ascii_downcase)) as $os
           | ($s.scope.tools // []) as $tools
           | ([($s.description // ""), ($s.applies_if[]? // "")]
              | map(ascii_downcase)) as $fields
           | ([ $tokens[] as $tok
                | $fields[] as $field
                | select($field | contains($tok)) ] | length) as $score
           | select(($s.status == "active" or $s.status == "degraded")
               and (($os | length) == 0 or ($os | index(($root.identity.os // "") | ascii_downcase)) != null)
               and ($tools | all(. as $tool
                    | any($root.capabilities[]?; .name == $tool and .ok == true)))
               and $score > 0)
           | . + {__score:$score})
       | sort_by(-.__score, .name)
       | .[:3]
       | map(del(.__score))) as $experiences
    | ($ordinary + $experiences)
    | if length == 0 then empty
      else
        (["",
          "The following skills provide specialized instructions for specific tasks.",
          "Load a matching skill location with shell; if it is a legacy directory, read its SKILL.md.",
          "<available_skills>"]
        + [ .[]
            | ["  <skill>",
               "    <name>" + (.name | esc) + "</name>",
               "    <description>" + ((.description // "" | gsub("\n";" ") | esc)) + "</description>"]
              + (if (.source // "") == "experience"
                 then ["    <status>" + (.status | esc) + "</status>"] else [] end)
              + ["    <location>" + ((.path // "") | esc) + "</location>",
                 "  </skill>"]
          ] | flatten
        + ["</available_skills>"])
        | join("\n")
      end
  ' "$scf" 2>/dev/null || true
}

agent_state_lines() {
  sf=$INSTALL/agent-store/index.json
  [ -f "$sf" ] || return 0
  jq -r '
    ([.capabilities[]? | select(.ok == true) | .name]) as $cap
    | ("Capabilities ok: " + (if ($cap | length) == 0 then "none yet"
        else ($cap[0:20] | join(" "))
             + (if ($cap | length) > 20 then " (+" + (($cap | length) - 20 | tostring) + " more)" else "" end)
        end)),
    "Observed on PATH: " + (([.identity.scans[]? | select(.source == "PATH") | .names] | first) // 0 | tostring)
      + " executables - jq observations.json, never cat it",
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
  ps_task=${1:-}
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
  skill_catalog "$ps_task"
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

# All Seed processes that share one state root use this coarse lock for
# read-modify-write operations. mkdir is the portable atomic claim; the owner
# file lets a later process recover a lock whose process no longer exists.
agent_state_lock_acquire() {
  al_store=$INSTALL/agent-store
  al_lock=$al_store/.state.lock
  if [ "${AGENT_STATE_LOCK_DEPTH:-0}" -gt 0 ]; then
    AGENT_STATE_LOCK_DEPTH=$((AGENT_STATE_LOCK_DEPTH + 1))
    return 0
  fi
  mkdir -p "$al_store" || return 1
  al_try=0
  al_empty=0
  al_max=${SEED_STATE_LOCK_WAIT:-30}
  while ! mkdir "$al_lock" 2>/dev/null; do
    al_owner=$(sed -n '1p' "$al_lock/owner" 2>/dev/null || true)
    case $al_owner in
      '')
        al_empty=$((al_empty + 1))
        if [ "$al_empty" -ge 2 ] && rmdir "$al_lock" 2>/dev/null; then
          al_empty=0
          continue
        fi ;;
      *[!0-9]*) al_empty=0 ;;
      *)
        al_empty=0
        if ! kill -0 "$al_owner" 2>/dev/null; then
          rm -f "$al_lock/owner" 2>/dev/null || :
          rmdir "$al_lock" 2>/dev/null || :
          continue
        fi ;;
    esac
    al_try=$((al_try + 1))
    [ "$al_try" -lt "$al_max" ] || {
      printf 'error: agent state lock timed out\n' >&2
      return 75
    }
    sleep 1
  done
  printf '%s\n' "$$" > "$al_lock/owner" || {
    rmdir "$al_lock" 2>/dev/null || :
    return 1
  }
  AGENT_STATE_LOCK_DIR=$al_lock
  AGENT_STATE_LOCK_DEPTH=1
}

agent_state_lock_release() {
  ar_depth=${AGENT_STATE_LOCK_DEPTH:-0}
  [ "$ar_depth" -gt 0 ] || return 0
  ar_depth=$((ar_depth - 1))
  AGENT_STATE_LOCK_DEPTH=$ar_depth
  [ "$ar_depth" -eq 0 ] || return 0
  ar_lock=${AGENT_STATE_LOCK_DIR:-$INSTALL/agent-store/.state.lock}
  ar_owner=$(sed -n '1p' "$ar_lock/owner" 2>/dev/null || true)
  if [ "$ar_owner" = "$$" ]; then
    rm -f "$ar_lock/owner" 2>/dev/null || :
    rmdir "$ar_lock" 2>/dev/null || :
  fi
  AGENT_STATE_LOCK_DIR=
}

agent_repair_machine_tree() {
  f=$INSTALL/agent-store/index.json
  pack=$INSTALL/agent-store/packs/init.json
  [ -f "$f" ] || return 1
  [ -f "$pack" ] || return 1
  agent_state_lock_acquire || return $?
  tmp=$(mktemp "$INSTALL/agent-store/.index.repair.XXXXXX") || {
    agent_state_lock_release
    return 1
  }
  if jq --slurpfile pack "$pack" '
    ($pack[0].machine_tree) as $tpl
    | if (type != "object") then .
      else
        .version = $tpl.version
        | (if (.identity | type) != "object" then .identity = $tpl.identity
           else .identity = ($tpl.identity * .identity) end)
        | (if (.capabilities | type) != "array" then .capabilities = [] else . end)
        | (if (.resources | type) != "array" then .resources = [] else . end)
        | (if (.agent | type) != "object" then .agent = $tpl.agent else . end)
        | (if (.agent.skills | type) != "array" then .agent.skills = [] else . end)
        | (if (.system | type) != "object" then .system = $tpl.system else . end)
        | (if (.system.retrieve | type) != "string"
              or ((.system.retrieve | length) == 0) then
             .system.retrieve = $tpl.system.retrieve else . end)
        | (if (.system | has("web") | not) then .system.web = $tpl.system.web else . end)
        | (if (has("ours") | not) then .ours = $tpl.ours else . end)
      end
  ' "$f" > "$tmp" && mv "$tmp" "$f"; then
    agent_state_lock_release
    return 0
  fi
  rm -f "$tmp"
  agent_state_lock_release
  return 1
}

agent_check_machine_tree() {
  f=${1:-$INSTALL/agent-store/index.json}
  [ -f "$f" ] || return 1
  jq -e '
    type == "object"
    and .ready == true
    and .version == "2"
    and (.identity | type) == "object"
    and (.identity.os | type == "string")
    and ((.identity.prereqs | type) == "object")
    and (.identity.prereqs | has("sh") and has("curl") and has("jq"))
    and (.capabilities | type) == "array"
    and (.resources | type) == "array"
    and ((.agent | type) == "object")
    and ((.agent.skills | type) == "array")
    and ((.system | type) == "object")
    and ((.system.retrieve | type) == "string")
    and ((.system.retrieve | length) > 0)
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
  agent_state_lock_acquire || return $?
  pj=$(mktemp "$store/.baseline.prereqs.XXXXXX") || {
    agent_state_lock_release
    return 1
  }
  if ! printf '{"sh":%s,"curl":%s,"jq":%s}\n' \
      "$(agent_prereq_json sh)" "$(agent_prereq_json curl)" \
      "$(agent_prereq_json jq)" > "$pj"; then
    rm -f "$pj" 2>/dev/null || :
    agent_state_lock_release
    return 1
  fi
  tmp=$(mktemp "$store/.index.baseline.XXXXXX") || {
    rm -f "$pj" 2>/dev/null || :
    agent_state_lock_release
    return 1
  }
  if jq --slurpfile t "$pj" '
      .machine_tree
      | .ready = true
      | .identity.prereqs = $t[0]
    ' "$pack" > "$tmp" 2>/dev/null \
    && mv "$tmp" "$base" \
    && agent_check_machine_tree "$base"; then
    rm -f "$pj"
    agent_state_lock_release
    return 0
  fi
  rm -f "$tmp" "$pj"
  agent_state_lock_release
  return 1
}

agent_restore_baseline() {
  base=$(agent_baseline_file)
  dest=$INSTALL/agent-store/index.json
  [ -f "$base" ] || return 1
  agent_check_machine_tree "$base" || return 1
  agent_state_lock_acquire || return $?
  if mv "$base" "$dest" && agent_check_machine_tree "$dest"; then
    agent_state_lock_release
    return 0
  fi
  agent_state_lock_release
  return 1
}

agent_init_pack_ok() {
  jq -e '
    type == "object"
    and (.prompt | type) == "string" and (.prompt | length) > 0
    and (.machine_tree | type) == "object"
    and .machine_tree.version == "2"
    and (.machine_tree.identity | type) == "object"
    and (.machine_tree.identity.prereqs | type) == "object"
    and (.machine_tree.identity.prereqs
         | has("sh") and has("curl") and has("jq"))
    and (.machine_tree.capabilities | type) == "array"
    and (.machine_tree.resources | type) == "array"
    and (.machine_tree.agent.skills | type) == "array"
    and (.machine_tree.system.retrieve | type) == "string"
    and (.machine_tree.system.retrieve | length) > 0
    and (.observations_tree | type) == "object"
    and .observations_tree.version == "2"
    and (.observations_tree.observations | type) == "array"
    and (.memory_tree | type) == "object"
    and .memory_tree.ready == true
    and .memory_tree.version == "2"
    and (.memory_tree.notes | type) == "array"
    and (.memory_tree.facts | type) == "array"
  ' "$@" >/dev/null 2>&1
}

agent_fetch_pack() {
  fp_index=$1
  store=$INSTALL/agent-store
  mkdir -p "$store/packs"
  root=$(pack_root)
  rel=$(printf '%s' "$fp_index" | jq -r '.required.init // empty')
  [ -n "$rel" ] || die "agent pack: catalog has no required.init" 69
  body=$(agent_pack_get "$(pack_join "$root/agent" "$rel")")
  printf '%s' "$body" | agent_init_pack_ok \
    || die "agent pack: init pack invalid" 69
  tmpc=$(mktemp "$store/.catalog.XXXXXX") || return 1
  tmpi=$(mktemp "$store/packs/.init.XXXXXX") || {
    rm -f "$tmpc" 2>/dev/null || :
    return 1
  }
  if ! printf '%s\n' "$fp_index" > "$tmpc" \
    || ! printf '%s\n' "$body" > "$tmpi"; then
    rm -f "$tmpc" "$tmpi" 2>/dev/null || :
    return 1
  fi
  agent_state_lock_acquire || { rm -f "$tmpc" "$tmpi"; return 75; }
  fp_status=0
  mv "$tmpi" "$store/packs/init.json" || fp_status=$?
  if [ "$fp_status" -eq 0 ]; then
    mv "$tmpc" "$store/catalog.json" || fp_status=$?
  fi
  rm -f "$tmpc" "$tmpi" 2>/dev/null || :
  agent_state_lock_release
  [ "$fp_status" -eq 0 ] || return "$fp_status"
}

agent_fetch_required() {
  store=$INSTALL/agent-store
  mkdir -p "$store/packs"
  if jq -e 'type == "object" and (.required.init | type) == "string"' \
      "$store/catalog.json" >/dev/null 2>&1 \
    && agent_init_pack_ok "$store/packs/init.json"; then
    return 0
  fi
  root=$(pack_root)
  index=$(agent_pack_get "$root/agent/index.json")
  printf '%s' "$index" | jq -e 'type == "object"' >/dev/null 2>&1 \
    || die "agent pack: catalog is not JSON" 69
  agent_fetch_pack "$index"
}

agent_try_update() {
  [ "${SEED_AUTO_UPDATE:-}" = 1 ] || return 0
  [ "${SEED_SKIP_UPDATE:-}" = 1 ] && return 0
  [ -f "$INSTALL/agent-store/catalog.json" ] || return 0
  if ( agent_update ) 2>/dev/null; then
    return 0
  fi
  printf 'note: pack catalog refresh skipped\n' >&2
  return 0
}

agent_ensure_project_memory() {
  ep_dir=$PWD/.agent-memory
  ep_dest=$ep_dir/index.json
  if [ -L "$ep_dir" ] || [ -L "$ep_dest" ]; then
    printf 'error: project memory path must not be a symlink\n' >&2
    return 76
  fi
  if [ -f "$ep_dest" ]; then
    if jq -e 'type == "object" and .ready == true and .version == "2"
      and (.notes | type) == "array" and (.facts | type) == "array"' \
      "$ep_dest" >/dev/null 2>&1; then
      return 0
    fi
    if jq -e 'type == "object" and (.version == "1" or (has("version") | not))
        and (.notes | type) == "array" and (.facts | type) == "array"' \
        "$ep_dest" >/dev/null 2>&1; then
      agent_state_lock_acquire || return $?
      ep_tmp=$(mktemp "$ep_dir/.index.XXXXXX") || {
        agent_state_lock_release
        return 76
      }
      if jq '.ready = true | .version = "2"' "$ep_dest" > "$ep_tmp" 2>/dev/null \
        && mv "$ep_tmp" "$ep_dest"; then
        agent_state_lock_release
        return 0
      fi
      rm -f "$ep_tmp" 2>/dev/null || :
      agent_state_lock_release
    fi
    printf 'error: project memory index is invalid\n' >&2
    return 76
  fi
  if [ -e "$ep_dir" ] && [ ! -d "$ep_dir" ]; then
    printf 'error: memory index path is not a directory\n' >&2
    return 76
  fi
  agent_state_lock_acquire || return $?
  ep_status=0
  if mkdir -p "$ep_dir" 2>/dev/null; then
    ep_tmp=$(mktemp "$ep_dir/.index.XXXXXX") || ep_status=$?
    if [ "$ep_status" -eq 0 ]; then
      printf '%s\n' '{"ready":true,"version":"2","notes":[],"facts":[]}' > "$ep_tmp" \
        && mv "$ep_tmp" "$ep_dest" || ep_status=$?
      [ "$ep_status" -eq 0 ] || rm -f "$ep_tmp" 2>/dev/null || :
    fi
  else
    ep_status=76
  fi
  agent_state_lock_release
  if [ "$ep_status" -ne 0 ]; then
    printf 'error: memory index not writable\n' >&2
    return 76
  fi
  jq -e '.ready == true and .version == "2"' "$ep_dest" >/dev/null 2>&1
}

agent_place_trees() {
  store=$INSTALL/agent-store
  pack=$store/packs/init.json
  [ -f "$pack" ] || { printf 'error: agent pack: init pack missing\n' >&2; return 69; }
  agent_state_lock_acquire || return $?
  pt_status=0
  if [ ! -f "$store/index.json" ]; then
    pt_tmp=$(mktemp "$store/.index.XXXXXX") || pt_status=$?
    if [ "$pt_status" -eq 0 ]; then
      jq '.machine_tree' "$pack" > "$pt_tmp" 2>/dev/null \
        && mv "$pt_tmp" "$store/index.json" || pt_status=$?
      [ "$pt_status" -eq 0 ] || rm -f "$pt_tmp" 2>/dev/null || :
    fi
  fi
  if [ "$pt_status" -eq 0 ] && [ ! -f "$store/observations.json" ]; then
    pt_tmp=$(mktemp "$store/.observations.XXXXXX") || pt_status=$?
    if [ "$pt_status" -eq 0 ]; then
      jq '.observations_tree // {version:"2",updated:"",observations:[]}' "$pack" \
        > "$pt_tmp" 2>/dev/null \
        && mv "$pt_tmp" "$store/observations.json" || pt_status=$?
      [ "$pt_status" -eq 0 ] || rm -f "$pt_tmp" 2>/dev/null || :
    fi
  fi
  agent_state_lock_release
  [ "$pt_status" -eq 0 ] || return "$pt_status"
  agent_ensure_project_memory
}

# One canonical lowercase os token, used by identity, capability scope, and
# experience scope.os, so the three layers never disagree about what machine
# this is.
agent_os_token() {
  ot=$(uname -s 2>/dev/null || printf unknown)
  ot=$(printf '%s' "$ot" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')
  case $ot in
    darwin|macos|osx) printf 'darwin' ;;
    linux) printf 'linux' ;;
    windows_nt|windows|mingw*|msys*|cygwin*) printf 'windows' ;;
    *) printf '%s' "$ot" ;;
  esac
}

# sh, curl and jq are not capabilities the model discovered — the loop cannot
# run without them. The runtime owns these three and nothing else: every other
# thing on the machine is discovered, investigated and verified by a task.
agent_prereq_json() {
  pq=$1
  pb=$(command -v "$pq" 2>/dev/null || true)
  if [ -z "$pb" ]; then
    jq -nc '{path:"",ok:false,probe:""}'
    return 0
  fi
  po=false
  case $pq in
    sh) pc="$pb -c 'echo ok'"; "$pb" -c 'echo ok' >/dev/null 2>&1 && po=true ;;
    jq) pc="$pb -n ."; "$pb" -n . >/dev/null 2>&1 && po=true ;;
    *)  pc="$pb --version"; "$pb" --version >/dev/null 2>&1 && po=true ;;
  esac
  jq -nc --arg p "$pb" --arg c "$pc" --argjson o "$po" '{path:$p,ok:$o,probe:$c}'
}

# Discovery is hardcoded; environment knowledge is not. This enumerates PATH
# and nothing else: no version flags, no package managers, no os-specific
# guesses. A name here means the file exists and is executable, which is all an
# observation ever claims. Subshell so IFS never leaks.
agent_sweep_path() {
  ( IFS=:
    for sd in $PATH; do
      [ -n "$sd" ] || continue
      [ -d "$sd" ] || continue
      for sp in "$sd"/* "$sd"/.[!.]* "$sd"/..?*; do
        [ -f "$sp" ] && [ -x "$sp" ] || continue
        printf '%s\n' "$sp"
      done
    done )
}

# Launch work: confirm the three prerequisites, refresh identity, re-sweep
# PATH. Capabilities are never re-probed here — verification happens at use,
# which is the only time the answer matters.
agent_bootstrap_machine() {
  bm_f=$INSTALL/agent-store/index.json
  bm_obs=$INSTALL/agent-store/observations.json
  [ -f "$bm_f" ] || return 0
  agent_state_lock_acquire || return $?
  bm_status=0
  bm_pq=
  bm_tsv=
  bm_old=$bm_obs
  bm_old_tmp=
  bm_ot=
  bm_it=
  bm_now=$(date -u +%Y-%m-%dT%H:%M:%SZ) || bm_status=$?

  if [ "$bm_status" -eq 0 ]; then
    bm_pq=$(mktemp "${TMPDIR:-/tmp}/seed-prereq.XXXXXX") || bm_status=$?
  fi
  if [ "$bm_status" -eq 0 ]; then
    printf '{"sh":%s,"curl":%s,"jq":%s}\n' \
      "$(agent_prereq_json sh)" "$(agent_prereq_json curl)" \
      "$(agent_prereq_json jq)" > "$bm_pq" || bm_status=$?
  fi

  if [ "$bm_status" -eq 0 ]; then
    bm_tsv=$(mktemp "${TMPDIR:-/tmp}/seed-sweep.XXXXXX") || bm_status=$?
  fi
  if [ "$bm_status" -eq 0 ]; then
    agent_sweep_path \
      | awk '{p=$0; n=p; sub(/.*\//,"",n); if (n != "" && !seen[n]++) print n "\t" p}' \
        > "$bm_tsv" 2>/dev/null || bm_status=$?
  fi
  if [ "$bm_status" -eq 0 ]; then
    bm_n=$(awk 'END{print NR+0}' "$bm_tsv") || bm_status=$?
  fi

  if [ "$bm_status" -eq 0 ] && [ ! -f "$bm_old" ]; then
    bm_old_tmp=$(mktemp "$INSTALL/agent-store/.observations.base.XXXXXX") \
      || bm_status=$?
    if [ "$bm_status" -eq 0 ]; then
      printf '{"version":"2","updated":"","observations":[]}\n' \
        > "$bm_old_tmp" || bm_status=$?
      bm_old=$bm_old_tmp
    fi
  fi
  if [ "$bm_status" -eq 0 ]; then
    bm_ot=$(mktemp "$INSTALL/agent-store/.observations.bootstrap.XXXXXX") \
      || bm_status=$?
  fi
  # Only PATH rows are replaced: an observation a task wrote by looking
  # somewhere else (a vendor directory, an applet list) outlives every sweep.
  if [ "$bm_status" -eq 0 ] && ! jq -R -s --arg u "$bm_now" --slurpfile old "$bm_old" '
      (split("\n") | map(select(length > 0)) | map(split("\t"))
        | map({type:"executable", name:.[0], path:.[1], source:"PATH"})) as $sweep
      | {version: "2", updated: $u,
         observations: ((($old[0].observations // [])
                          | map(select(.source != "PATH"))) + $sweep)}
    ' "$bm_tsv" > "$bm_ot" 2>/dev/null; then
    bm_status=1
  fi

  if [ "$bm_status" -eq 0 ]; then
    bm_it=$(mktemp "$INSTALL/agent-store/.index.bootstrap.XXXXXX") \
      || bm_status=$?
  fi
  if [ "$bm_status" -eq 0 ] && ! jq --slurpfile q "$bm_pq" --arg u "$bm_now" \
        --arg os "$(agent_os_token)" \
        --arg kernel "$(uname -s 2>/dev/null || printf unknown)" \
        --arg arch "$(uname -m 2>/dev/null || printf unknown)" \
        --arg ush "${SHELL:-/bin/sh}" --arg home "${HOME:-}" --arg pth "${PATH:-}" \
        --argjson n "$bm_n" '
      if (type == "object") then
        .identity = ((.identity // {}) + {
            os: $os, kernel: $kernel, arch: $arch, shell: $ush, home: $home,
            path_dirs: ($pth | split(":") | map(select(length > 0))),
            prereqs: $q[0]})
        | .identity.scans = ((((.identity.scans // []) | map(select(.source != "PATH")))
            + [{source:"PATH", at:$u, names:$n}]))
        | .updated = $u
      else . end
    ' "$bm_f" > "$bm_it" 2>/dev/null; then
    bm_status=1
  fi
  if [ "$bm_status" -eq 0 ]; then
    mv "$bm_ot" "$bm_obs" || bm_status=$?
  fi
  if [ "$bm_status" -eq 0 ]; then
    mv "$bm_it" "$bm_f" || bm_status=$?
  fi
  rm -f "$bm_pq" "$bm_tsv" "$bm_old_tmp" "$bm_ot" "$bm_it" \
    2>/dev/null || :
  agent_state_lock_release
  [ "$bm_status" -eq 0 ] || return "$bm_status"
}

# v1 indexes were keyed on a fixed six-tool object plus flat resource and other
# lists. Nothing is dropped: every entry that named something real becomes a
# capability, carrying whatever the model had already learned about it.
agent_migrate_index_v2() {
  mi_f=$INSTALL/agent-store/index.json
  [ -f "$mi_f" ] || return 0
  jq -e '.version == "2" and (.identity | type) == "object"' "$mi_f" >/dev/null 2>&1 && return 0
  agent_state_lock_acquire || return $?
  # Some early v2 writers produced the complete array-shaped schema but left
  # the version label at 1. Relabel that shape in place; rebuilding it through
  # the old fixed-tool migration would discard already-curated capabilities.
  if jq -e '(.identity | type) == "object"
      and (.capabilities | type) == "array"
      and (.resources | type) == "array"
      and (.agent.skills | type) == "array"
      and (.system.retrieve | type) == "string"' "$mi_f" >/dev/null 2>&1; then
    mi_t=$(mktemp "$INSTALL/agent-store/.index.migrate.XXXXXX") || {
      agent_state_lock_release
      return 1
    }
    if jq '.version = "2"' "$mi_f" > "$mi_t" 2>/dev/null \
      && mv "$mi_t" "$mi_f"; then
      agent_state_lock_release
      printf 'note: machine index v2 label repaired\n' >&2
      return 0
    fi
    rm -f "$mi_t" 2>/dev/null || :
    agent_state_lock_release
    return 1
  fi
  if ! jq -e '(.system | type) == "object"' "$mi_f" >/dev/null 2>&1; then
    agent_state_lock_release
    return 1
  fi
  mi_t=$(mktemp "$INSTALL/agent-store/.index.migrate.XXXXXX") || {
    agent_state_lock_release
    return 1
  }
  if jq '
      def aslist: if . == null then [] elif type == "array" then . else [tostring] end;
      def isurl: (type == "string") and (startswith("http://") or startswith("https://"));
      ((.system.tools // {}) | to_entries
        | map(select((.value.present == true) or ((.value.note // "") != "")))
        | map({id: ("local:" + .key), name: .key, kind: "cli",
               locator: (.value.path // ""), purpose: [], use: "", needs: [],
               observed: (.value.present == true), understood: false,
               verified: (.value.ok == true),
               ok: (.value.ok == true),
               probe: (if (.value.probe // "") != "" then .value.probe
                       elif (.value.ok != true) or ((.value.path // "") == "") then ""
                       # v1 recorded no probe string, but the smoke test the
                       # old runtime ran is known. Reconstruct it so a migrated
                       # capability can still be re-verified, instead of being
                       # ok forever with no way to check.
                       elif .key == "sh" then (.value.path + " -c \"echo sh_ok\"")
                       elif .key == "jq" then (.value.path + " -n .")
                       else (.value.path + " --version") end),
               evidence: [],
               observed_at: "", verified_at: "", scope: (.value.scope // []),
               skill: "", note: (.value.note // "")})) as $fromtools
      | (((.system.resources // []) + (.system.other // []))
        | map(. as $r
              | {id: ("local:" + ($r.name // "")), name: ($r.name // ""),
                 kind: ($r.kind // "cli"), locator: (($r.path // $r.url) // ""),
                 purpose: ($r.purpose | aslist), use: ($r.use // ""),
                 needs: ($r.needs | aslist),
                 observed: true, understood: (($r.use // "") != ""),
                 verified: ($r.ok == true), ok: ($r.ok == true),
                 probe: ($r.probe // ""), evidence: [], observed_at: "",
                 verified_at: ($r.probed // ""), scope: ($r.scope | aslist),
                 skill: ($r.skill // ""), note: ($r.note // "")})) as $fromres
      | {ready: (.ready // false), version: "2", updated: (.updated // ""),
         identity: {os: ((.system.env.os // "") | ascii_downcase),
                    kernel: (.system.env.kernel // ""),
                    arch: (.system.env.arch // ""),
                    shell: (.system.env.shell // ""),
                    home: "", path_dirs: [], prereqs: {}, scans: []},
         capabilities: ($fromtools
                        + ($fromres | map(select((.kind != "source")
                                                 and ((.locator | isurl) | not))))),
         resources: ($fromres | map(select((.kind == "source")
                                           or (.locator | isurl)))),
         agent: {skills: (.system.skills // [])},
         system: {retrieve: (.system.retrieve // ""),
                  web: (.system.web // {})},
         ours: (.ours // {})}
    ' "$mi_f" > "$mi_t" 2>/dev/null && mv "$mi_t" "$mi_f"; then
    agent_state_lock_release
    printf 'note: machine index migrated to v2 (observations/capabilities/resources)\n' >&2
    return 0
  else
    rm -f "$mi_t"
    agent_state_lock_release
    return 1
  fi
}

# Experience IDs are also directory names and skill names. Enforce the Agent
# Skills slug shape before constructing a path, so a memory row can never use
# ../ to publish a file outside the experience store.
agent_experience_id_ok() {
  ei_id=$1
  ei_n=$(printf '%s' "$ei_id" | wc -c | tr -d ' ')
  [ "$ei_n" -ge 1 ] && [ "$ei_n" -le 64 ] || return 1
  case $ei_id in
    *[!a-z0-9-]*|-*|*-|*--*) return 1 ;;
  esac
  return 0
}

# Experience skills use the strict, small subset of YAML frontmatter that Seed
# writes: one unambiguous name and description before the closing delimiter.
agent_skill_file_ok() {
  sf_file=$1
  sf_id=$2
  sf_description=${3:-}
  [ -r "$sf_file" ] || return 1
  awk -v want="$sf_id" -v want_description="$sf_description" '
    function clean(v) {
      sub(/^[ \t]*/, "", v); sub(/[ \t]*$/, "", v)
      if ((v ~ /^".*"$/) || (v ~ /^\047.*\047$/)) v=substr(v,2,length(v)-2)
      return v
    }
    NR == 1 { if ($0 != "---") exit 1; front=1; next }
    front && $0 == "---" { done=1; exit }
    front && /^name:[ \t]*/ {
      names++; v=$0; sub(/^name:[ \t]*/, "", v); name=clean(v); next
    }
    front && /^description:[ \t]*/ {
      descriptions++; v=$0; sub(/^description:[ \t]*/, "", v); desc=clean(v); next
    }
    END {
      if (!done || names != 1 || descriptions != 1 || name != want || desc == "") exit 1
      if (want_description != "" && desc != want_description) exit 1
    }
  ' "$sf_file" >/dev/null 2>&1
}

# Missing frontmatter is an unambiguous authoring omission: exp.json and the
# synchronized catalog already own the canonical name and description. Allow
# the normalizer to add it, but reject any present-yet-invalid frontmatter so a
# conflicting name or malformed header is never silently rewritten.
agent_skill_file_repairable() {
  sr_file=$1
  sr_id=$2
  if agent_skill_file_ok "$sr_file" "$sr_id"; then
    return 0
  fi
  [ -s "$sr_file" ] || return 1
  sr_first=$(sed -n '1p' "$sr_file") || return 1
  [ "$sr_first" != '---' ]
}

# A candidate is a model proposal, not a usable experience. Validate the
# complete proposal before the runtime executes any command from it. Candidate
# evidence may come from the proposing task, but it never authorizes
# publication; only a later runtime maintenance receipt does that.
agent_experience_candidate_ok() {
  ec_store=$1
  ec_id=$2
  ec_started=$3
  ec_mode=${4:-candidate}
  case $ec_mode in candidate|legacy|repairable|normalized) ;; *) return 1 ;; esac
  agent_experience_id_ok "$ec_id" || return 1
  ec_dir=$ec_store/experiences/$ec_id
  ec_exp=$ec_dir/exp.json
  ec_skill=$ec_dir/SKILL.md
  ec_index=$ec_store/experiences/index.json
  [ -d "$ec_store" ] && [ ! -L "$ec_store" ] || return 1
  [ -d "$ec_store/experiences" ] && [ ! -L "$ec_store/experiences" ] || return 1
  [ -d "$ec_dir" ] && [ ! -L "$ec_dir" ] || return 1
  [ -f "$ec_exp" ] && [ ! -L "$ec_exp" ] || return 1
  [ -f "$ec_skill" ] && [ ! -L "$ec_skill" ] || return 1
  [ -f "$ec_index" ] && [ ! -L "$ec_index" ] || return 1
  [ -d "$ec_store/runs" ] && [ ! -L "$ec_store/runs" ] || return 1
  ec_title=$(jq -er '.title | select(type == "string")' "$ec_exp" 2>/dev/null) \
    || return 1
  if [ "$ec_mode" = repairable ]; then
    agent_skill_file_repairable "$ec_skill" "$ec_id" || return 1
  else
    agent_skill_file_ok "$ec_skill" "$ec_id" "$ec_title" || return 1
  fi
  jq -Rs -e 'test("[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]") | not' \
    "$ec_skill" >/dev/null 2>&1 || return 1
  jq -e --arg id "$ec_id" --arg started "$ec_started" --arg mode "$ec_mode" '
    def string_array: type == "array" and all(.[]; type == "string");
    def utc: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    def noop:
      ascii_downcase | gsub("^[[:space:]]+|[[:space:]]+$"; "")
      | . == "true" or . == ":" or . == "exit 0" or startswith("echo ");
    type == "object"
    and ([.. | strings
          | select(test("[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]"))]
         | length) == 0
    and keys == ["applies_if","created_at","evidence","failures","id","kind",
                 "last_verified","preconditions","quarantine_reason","scope",
                 "status","successes","supersedes","title","verify","version"]
    and .id == $id
    and .kind == "procedure"
    and (.title | type == "string" and length > 0 and (contains("\n") | not))
    and (if $mode != "legacy" then
           .status == "candidate" and .successes == 0 and .last_verified == ""
         else
           (.status == "active" or .status == "degraded")
           and (.successes | type == "number" and floor == . and . >= 1)
           and (.last_verified | utc) and .last_verified > .created_at
         end)
    and (.version | type == "number" and floor == . and . >= 1)
    and (.scope | type == "object")
    and (.scope | keys) == ["os","task_kinds","tools"]
    and (.scope.os | string_array and all(.[]; . == ascii_downcase))
    and (.scope.tools | string_array)
    and (.scope.task_kinds | string_array)
    and (.applies_if | string_array)
    and (.preconditions | string_array)
    and (.verify | string_array and length > 0
         and all(.[]; length > 0 and (contains("\n") | not) and (noop | not)))
    and (.evidence | string_array and length > 0
         and all(.[];
           if $mode == "repairable"
           then test("^(agent-store/)?runs/[A-Za-z0-9][A-Za-z0-9._-]*[.]jsonl$")
           else test("^agent-store/runs/[A-Za-z0-9][A-Za-z0-9._-]*[.]jsonl$")
           end))
    and (.failures | type == "number" and floor == . and . >= 0)
    and (.created_at | utc)
    and .created_at < $started
    and (.supersedes | type == "string")
    and (.quarantine_reason | type == "string")
  ' "$ec_exp" >/dev/null 2>&1 || return 1

  jq -e --slurpfile e "$ec_exp" --arg id "$ec_id" --arg store "$ec_store" '
    [.experiences[]? | select(.id == $id)] as $rows
    | ($rows | length) == 1
      and $rows[0].title == $e[0].title
      and $rows[0].status == $e[0].status
      and $rows[0].version == $e[0].version
      and $rows[0].scope == $e[0].scope
      and $rows[0].applies_if == $e[0].applies_if
      and ($rows[0].path == $id
           or $rows[0].path == ("experiences/" + $id)
           or $rows[0].path == ("agent-store/experiences/" + $id)
           or $rows[0].path == ($store + "/experiences/" + $id))
  ' "$ec_index" >/dev/null 2>&1 || return 1

  for ec_rel in $(jq -r '.evidence[]' "$ec_exp"); do
    case $ec_rel in
      runs/*) ec_file=$ec_store/$ec_rel ;;
      *) ec_file=$INSTALL/$ec_rel ;;
    esac
    [ -f "$ec_file" ] && [ ! -L "$ec_file" ] || return 1
    jq -s -e 'length > 0 and all(.[]; type == "object")' "$ec_file" \
      >/dev/null 2>&1 || return 1
  done
  if [ "$ec_mode" != normalized ]; then
    if ! jq -r '.verify[]' "$ec_exp" | while IFS= read -r ec_cmd; do
      ec_hit=0
      for ec_rel in $(jq -r '.evidence[]' "$ec_exp"); do
        case $ec_rel in
          runs/*) ec_file=$ec_store/$ec_rel ;;
          *) ec_file=$INSTALL/$ec_rel ;;
        esac
        if jq -s -e --arg id "$ec_id" --arg cmd "$ec_cmd" '
            def utc: type == "string"
              and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
            any(.[];
              type == "object" and .exp_id == $id and .cmd == $cmd
              and .exit == 0 and (.utc | utc)
              and (.note | type == "string")
              and (.note | test("[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]") | not))
          ' "$ec_file" >/dev/null 2>&1; then
          ec_hit=1
          break
        fi
      done
      [ "$ec_hit" -eq 1 ] || exit 1
    done; then
      return 1
    fi
  fi
  return 0
}

agent_experience_tools_ok() {
  et_store=$1
  et_id=$2
  et_exp=$et_store/experiences/$et_id/exp.json
  et_index=$et_store/index.json
  [ -f "$et_exp" ] && [ ! -L "$et_exp" ] || return 1
  [ -f "$et_index" ] && [ ! -L "$et_index" ] || return 1
  jq -e --slurpfile e "$et_exp" '
    . as $index
    | all(($e[0].scope.tools // [])[];
        . as $tool
        | any($index.capabilities[]?; .name == $tool and .ok == true))
  ' "$et_index" >/dev/null 2>&1
}

# The stale edge is deterministic: a live record whose declared capability is
# unavailable is retained but no longer eligible for retrieval.
agent_experience_mark_stale() {
  es_store=$1
  es_id=$2
  es_exp=$es_store/experiences/$es_id/exp.json
  es_index=$es_store/experiences/index.json
  agent_state_lock_acquire || return $?
  es_exp_tmp=$(mktemp "$es_store/experiences/$es_id/.exp.stale.XXXXXX") || {
    agent_state_lock_release
    return 1
  }
  es_index_tmp=$(mktemp "$es_store/experiences/.index.stale.XXXXXX") || {
    rm -f "$es_exp_tmp" 2>/dev/null || :
    agent_state_lock_release
    return 1
  }
  es_ok=0
  if jq '.status = "stale"' "$es_exp" > "$es_exp_tmp" 2>/dev/null \
    && jq --arg id "$es_id" '
      .experiences |= map(if .id == $id then .status = "stale" else . end)
    ' "$es_index" > "$es_index_tmp" 2>/dev/null \
    && jq -e '.status == "stale"' "$es_exp_tmp" >/dev/null 2>&1 \
    && jq -e --arg id "$es_id" '
      ([.experiences[]? | select(.id == $id and .status == "stale")] | length) == 1
    ' "$es_index_tmp" >/dev/null 2>&1 \
    && mv "$es_exp_tmp" "$es_exp" \
    && mv "$es_index_tmp" "$es_index"; then
    es_ok=1
  fi
  rm -f "$es_exp_tmp" "$es_index_tmp" 2>/dev/null || :
  agent_state_lock_release
  [ "$es_ok" -eq 1 ]
}

# Active/degraded records created before runtime receipts existed are not
# grandfathered into publication. An explicit maintenance run first requeues
# only an otherwise complete legacy record, then verifies it through the same
# candidate path as every new proposal.
agent_experience_requeue_legacy() {
  el_store=$1
  el_id=$2
  el_started=$3
  agent_state_lock_acquire || return $?
  if ! agent_experience_candidate_ok "$el_store" "$el_id" "$el_started" legacy; then
    agent_state_lock_release
    return 1
  fi
  el_exp=$el_store/experiences/$el_id/exp.json
  el_index=$el_store/experiences/index.json
  el_exp_tmp=$(mktemp "$el_store/experiences/$el_id/.exp.requeue.XXXXXX") || {
    agent_state_lock_release
    return 1
  }
  el_index_tmp=$(mktemp "$el_store/experiences/.index.requeue.XXXXXX") || {
    rm -f "$el_exp_tmp" 2>/dev/null || :
    agent_state_lock_release
    return 1
  }
  el_ok=0
  if jq '.status = "candidate" | .successes = 0 | .last_verified = ""' \
      "$el_exp" > "$el_exp_tmp" 2>/dev/null \
    && jq --arg id "$el_id" '
      .experiences |= map(if .id == $id then .status = "candidate" else . end)
    ' "$el_index" > "$el_index_tmp" 2>/dev/null \
    && mv "$el_exp_tmp" "$el_exp" \
    && mv "$el_index_tmp" "$el_index"; then
    el_ok=1
  fi
  rm -f "$el_exp_tmp" "$el_index_tmp" 2>/dev/null || :
  agent_state_lock_release
  [ "$el_ok" -eq 1 ]
}

# Canonicalize only metadata and launch-workspace spelling whose source of
# truth is unambiguous: exp.json and the catalog already agree on the skill
# name/title, while the runtime knows the exact launch directory. A wholly
# absent frontmatter block is added; present-but-invalid frontmatter is
# rejected. A store-relative runs/<file>.jsonl evidence path gets its canonical
# agent-store/ prefix. A store-relative experiences/<id> catalog path is also
# accepted and becomes the canonical id during promotion. The procedure body
# is preserved. Absolute launch prefixes become relative commands, including a
# redundant `cd <launch-root> &&` prefix, so the experience remains portable
# to a later workspace.
agent_experience_normalize_candidate() {
  en_store=$1
  en_id=$2
  en_started=$3
  en_exp=$en_store/experiences/$en_id/exp.json
  en_skill=$en_store/experiences/$en_id/SKILL.md
  agent_state_lock_acquire || return $?
  if ! agent_experience_candidate_ok "$en_store" "$en_id" "$en_started" repairable; then
    agent_state_lock_release
    return 1
  fi
  en_title=$(jq -er '.title' "$en_exp") || {
    agent_state_lock_release
    return 1
  }
  en_exp_tmp=$(mktemp "$en_store/experiences/$en_id/.exp.normalize.XXXXXX") || {
    agent_state_lock_release
    return 1
  }
  en_skill_tmp=$(mktemp "$en_store/experiences/$en_id/.skill.normalize.XXXXXX") || {
    rm -f "$en_exp_tmp" 2>/dev/null || :
    agent_state_lock_release
    return 1
  }
  en_prefix="cd $LAUNCH_CWD/"
  en_root_prefix="cd $LAUNCH_CWD && "
  if ! jq --arg prefix "$en_prefix" --arg root_prefix "$en_root_prefix" \
      --arg cwd "$LAUNCH_CWD" '
      .evidence |= map(
        if startswith("runs/") then "agent-store/" + . else . end)
      | .verify |= map(
        if startswith($root_prefix) then .[($root_prefix | length):]
        elif startswith($prefix) then "cd " + .[($prefix | length):]
        else . end)
      | select(all(.verify[]; (contains($cwd) | not)))
    ' "$en_exp" > "$en_exp_tmp" 2>/dev/null \
    || ! {
      printf '%s\n' '---' "name: $en_id" "description: $en_title" '---'
      awk '
        NR == 1 && $0 == "---" { front=1; next }
        front && $0 == "---" { front=0; next }
        !front { print }
      ' "$en_skill"
    } > "$en_skill_tmp"; then
    rm -f "$en_exp_tmp" "$en_skill_tmp" 2>/dev/null || :
    agent_state_lock_release
    return 1
  fi
  en_exp_backup=$(mktemp "$en_store/experiences/$en_id/.exp.normalize-backup.XXXXXX") || {
    rm -f "$en_exp_tmp" "$en_skill_tmp" 2>/dev/null || :
    agent_state_lock_release
    return 1
  }
  en_skill_backup=$(mktemp "$en_store/experiences/$en_id/.skill.normalize-backup.XXXXXX") || {
    rm -f "$en_exp_tmp" "$en_skill_tmp" "$en_exp_backup" 2>/dev/null || :
    agent_state_lock_release
    return 1
  }
  en_ok=0
  if cp "$en_exp" "$en_exp_backup" \
    && cp "$en_skill" "$en_skill_backup" \
    && mv "$en_skill_tmp" "$en_skill" \
    && mv "$en_exp_tmp" "$en_exp" \
    && agent_experience_candidate_ok "$en_store" "$en_id" "$en_started" normalized; then
    en_ok=1
  fi
  if [ "$en_ok" -ne 1 ]; then
    mv "$en_exp_backup" "$en_exp" 2>/dev/null || :
    mv "$en_skill_backup" "$en_skill" 2>/dev/null || :
  fi
  rm -f "$en_exp_tmp" "$en_skill_tmp" "$en_exp_backup" "$en_skill_backup" \
    2>/dev/null || :
  agent_state_lock_release
  [ "$en_ok" -eq 1 ]
}

# Execute one verifier in a fresh shell rooted at the launch workspace. A new
# session for every command prevents `cd` or environment changes in one
# verifier from making the next verifier pass accidentally.
agent_run_verifier() {
  rv_cmd=$1
  rv_root=$2
  rv_session=$rv_root/session
  rv_result=$rv_root/result.txt
  rv_script=$rv_root/verifier.sh
  printf '%s\n' "$rv_cmd" > "$rv_script" || return 1
  if ! rv_syntax=$(/bin/sh -n "$rv_script" 2>&1); then
    printf 'maintenance: verifier does not parse: %s\n%s\n' \
      "$rv_cmd" "$rv_syntax" >&2
    return 1
  fi
  SEED_MAINTAIN_VERIFY_SCRIPT=$rv_script
  export SEED_MAINTAIN_VERIFY_SCRIPT
  shell_init "$rv_session" "$LAUNCH_CWD"
  shell_run "$rv_session" '/bin/sh "$SEED_MAINTAIN_VERIFY_SCRIPT"' > "$rv_result"
  rv_status=$(sed -n '1p' "$rv_session/status" 2>/dev/null || printf '1\n')
  rv_pid=$(sed -n '1p' "$rv_session/pid" 2>/dev/null || true)
  shell_stop "$rv_session" 2>/dev/null || :
  case $rv_pid in ''|*[!0-9]*) ;; *) wait "$rv_pid" 2>/dev/null || : ;; esac
  unset SEED_MAINTAIN_VERIFY_SCRIPT
  if [ "$rv_status" = 0 ]; then
    return 0
  fi
  printf 'maintenance: verifier failed (exit %s): %s\n' "$rv_status" "$rv_cmd" >&2
  sed -n '1,80p' "$rv_result" >&2 || :
  return 1
}

# Promote one already-valid candidate. The model never participates in this
# turn: the runtime snapshots the proposal, executes each exact verifier from
# the launch workspace, rechecks the unchanged snapshot, writes its own
# receipt, and commits the synchronized status transition under the state lock.
agent_maintain_one() {
  (
    mo_id=$1
    mo_started=$2
    mo_mode=${3:-candidate}
    mo_store=$INSTALL/agent-store
    mo_dir=$mo_store/experiences/$mo_id
    mo_exp=$mo_dir/exp.json
    mo_skill=$mo_dir/SKILL.md
    mo_index=$mo_store/experiences/index.json
    mo_tmp=$(mktemp -d "${TMPDIR:-/tmp}/seed-maintain.XXXXXX") || exit 1
    mo_locked=0
    trap 'if [ "$mo_locked" -eq 1 ]; then agent_state_lock_release; fi; rm -rf "$mo_tmp"' EXIT HUP INT TERM

    agent_state_lock_acquire || exit $?
    mo_locked=1
    if ! agent_experience_candidate_ok "$mo_store" "$mo_id" "$mo_started" \
        "$mo_mode"; then
      printf 'maintenance: invalid candidate: %s\n' "$mo_id" >&2
      exit 1
    fi
    if ! agent_experience_tools_ok "$mo_store" "$mo_id"; then
      if agent_experience_mark_stale "$mo_store" "$mo_id"; then
        printf 'maintenance: %s -> stale (required capability unavailable)\n' "$mo_id" >&2
        agent_state_lock_release
        mo_locked=0
        exit 0
      fi
      printf 'maintenance: failed to mark %s stale\n' "$mo_id" >&2
      exit 1
    fi
    jq -cS . "$mo_exp" > "$mo_tmp/exp.snapshot" || exit 1
    cat "$mo_skill" > "$mo_tmp/skill.snapshot" || exit 1
    jq -cS --arg id "$mo_id" '[.experiences[]? | select(.id == $id)]' \
      "$mo_index" > "$mo_tmp/row.snapshot" || exit 1
    jq -r '.verify[]' "$mo_exp" > "$mo_tmp/commands" || exit 1
    agent_state_lock_release
    mo_locked=0

    mo_n=0
    while IFS= read -r mo_cmd; do
      mo_n=$((mo_n + 1))
      mkdir -p "$mo_tmp/verify-$mo_n" || exit 1
      if ! agent_run_verifier "$mo_cmd" "$mo_tmp/verify-$mo_n"; then
        printf 'maintenance: %s remains candidate\n' "$mo_id" >&2
        exit 1
      fi
      printf '%s\n' "$mo_cmd" >> "$mo_tmp/verified-commands"
    done < "$mo_tmp/commands"
    [ "$mo_n" -gt 0 ] || exit 1

    agent_state_lock_acquire || exit $?
    mo_locked=1
    if ! agent_experience_candidate_ok "$mo_store" "$mo_id" "$mo_started" \
        "$mo_mode" \
      || ! agent_experience_tools_ok "$mo_store" "$mo_id"; then
      printf 'maintenance: candidate changed during verification: %s\n' "$mo_id" >&2
      exit 1
    fi
    jq -cS . "$mo_exp" > "$mo_tmp/exp.current" || exit 1
    jq -cS --arg id "$mo_id" '[.experiences[]? | select(.id == $id)]' \
      "$mo_index" > "$mo_tmp/row.current" || exit 1
    if ! cmp -s "$mo_tmp/exp.snapshot" "$mo_tmp/exp.current" \
      || ! cmp -s "$mo_tmp/skill.snapshot" "$mo_skill" \
      || ! cmp -s "$mo_tmp/row.snapshot" "$mo_tmp/row.current"; then
      printf 'maintenance: candidate changed during verification: %s\n' "$mo_id" >&2
      exit 1
    fi

    mo_verified=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if ! jq -e --arg now "$mo_verified" '.created_at < $now' "$mo_exp" \
        >/dev/null 2>&1; then
      printf 'maintenance: verification time is not later than candidate: %s\n' "$mo_id" >&2
      exit 1
    fi
    mo_stamp=$(printf '%s' "$mo_verified" | tr -d ':-')
    mo_seq=0
    while :; do
      mo_rel=agent-store/runs/maintain-$mo_stamp-$$-$mo_id-$mo_seq.jsonl
      mo_evidence=$INSTALL/$mo_rel
      [ -e "$mo_evidence" ] || break
      mo_seq=$((mo_seq + 1))
    done
    mo_evidence_tmp=$(mktemp "$mo_store/runs/.maintain.XXXXXX") || exit 1
    while IFS= read -r mo_cmd; do
      jq -nc --arg utc "$mo_verified" --arg cmd "$mo_cmd" --arg id "$mo_id" \
        --arg started "$mo_started" \
        '{utc:$utc,cmd:$cmd,exit:0,note:"runtime maintenance verification",
          exp_id:$id,authority:"seed-runtime",cwd:"launch-workspace",
          maintain_started:$started}' >> "$mo_evidence_tmp" || exit 1
    done < "$mo_tmp/verified-commands"
    if ! jq -s -e --arg id "$mo_id" --arg now "$mo_verified" \
        --arg started "$mo_started" '
          length > 0 and all(.[];
            .exp_id == $id and .exit == 0 and .utc == $now
            and .authority == "seed-runtime" and .cwd == "launch-workspace"
            and .maintain_started == $started)
        ' "$mo_evidence_tmp" >/dev/null 2>&1 \
      || ! mv "$mo_evidence_tmp" "$mo_evidence"; then
      rm -f "$mo_evidence_tmp" 2>/dev/null || :
      exit 1
    fi

    mo_exp_tmp=$(mktemp "$mo_dir/.exp.promote.XXXXXX") || exit 1
    mo_index_tmp=$(mktemp "$mo_store/experiences/.index.promote.XXXXXX") || exit 1
    if ! jq --arg now "$mo_verified" --arg ev "$mo_rel" '
        .status = "active"
        | .successes = (if .successes < 1 then 1 else .successes end)
        | .last_verified = $now
        | .evidence = ((.evidence + [$ev]) | unique)
      ' "$mo_exp" > "$mo_exp_tmp" 2>/dev/null; then
      exit 1
    fi
    mo_row=$(jq -c '{id,title,status,version,scope,applies_if,path:.id}' "$mo_exp_tmp") \
      || exit 1
    if ! jq --arg id "$mo_id" --argjson row "$mo_row" '
        .experiences |= map(if .id == $id then $row else . end)
      ' "$mo_index" > "$mo_index_tmp" 2>/dev/null; then
      exit 1
    fi
    mo_exp_backup=$(mktemp "$mo_dir/.exp.rollback.XXXXXX") || exit 1
    mo_index_backup=$(mktemp "$mo_store/experiences/.index.rollback.XXXXXX") || exit 1
    cp "$mo_exp" "$mo_exp_backup" || exit 1
    cp "$mo_index" "$mo_index_backup" || exit 1
    mo_committed=0
    if mv "$mo_exp_tmp" "$mo_exp" \
      && mv "$mo_index_tmp" "$mo_index" \
      && agent_experience_record_ok "$mo_store" "$mo_id"; then
      mo_committed=1
    fi
    if [ "$mo_committed" -ne 1 ]; then
      mv "$mo_exp_backup" "$mo_exp" 2>/dev/null || :
      mv "$mo_index_backup" "$mo_index" 2>/dev/null || :
      printf 'maintenance: promotion transaction rolled back: %s\n' "$mo_id" >&2
      exit 1
    fi
    rm -f "$mo_exp_backup" "$mo_index_backup" 2>/dev/null || :
    agent_state_lock_release
    mo_locked=0
    printf 'maintained: %s active\n' "$mo_id" >&2
  )
}

agent_maintain_experiences() {
  if [ "${SEED_RUN_MODE:-agent}" != agent ]; then
    printf 'error: maintenance needs Agent mode\n' >&2
    return 64
  fi
  ma_store=$INSTALL/agent-store
  ma_root=$ma_store/experiences
  ma_started=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  ma_seen=0
  ma_failed=0
  if [ -d "$ma_root" ] && [ ! -L "$ma_root" ]; then
    for ma_exp in "$ma_root"/*/exp.json; do
      [ -e "$ma_exp" ] || [ -L "$ma_exp" ] || continue
      ma_id=${ma_exp%/exp.json}
      ma_id=${ma_id##*/}
      ma_status=$(jq -r '.status // empty' "$ma_exp" 2>/dev/null || true)
      case $ma_status in
        candidate)
          ma_seen=$((ma_seen + 1))
          if agent_experience_normalize_candidate "$ma_store" "$ma_id" \
              "$ma_started"; then
            agent_maintain_one "$ma_id" "$ma_started" normalized || ma_failed=1
          else
            printf 'maintenance: invalid candidate: %s\n' "$ma_id" >&2
            ma_failed=1
          fi
          ;;
        active|degraded)
          ma_seen=$((ma_seen + 1))
          if ! agent_experience_record_ok "$ma_store" "$ma_id"; then
            if agent_experience_candidate_ok "$ma_store" "$ma_id" \
                "$ma_started" legacy \
              && agent_experience_requeue_legacy "$ma_store" "$ma_id" \
                "$ma_started" \
              && agent_experience_normalize_candidate "$ma_store" "$ma_id" \
                "$ma_started"; then
              printf 'maintenance: re-verifying legacy record: %s\n' "$ma_id" >&2
              agent_maintain_one "$ma_id" "$ma_started" normalized || ma_failed=1
            else
              printf 'maintenance: invalid unpublished %s record: %s\n' \
                "$ma_status" "$ma_id" >&2
              ma_failed=1
            fi
          elif ! agent_experience_tools_ok "$ma_store" "$ma_id"; then
            if agent_experience_mark_stale "$ma_store" "$ma_id"; then
              printf 'maintenance: %s -> stale (required capability unavailable)\n' \
                "$ma_id" >&2
            else
              ma_failed=1
            fi
          fi
          ;;
        '')
          ma_seen=$((ma_seen + 1))
          printf 'maintenance: invalid experience record: %s\n' "$ma_id" >&2
          ma_failed=1
          ;;
      esac
    done
  elif [ -e "$ma_root" ] || [ -L "$ma_root" ]; then
    printf 'maintenance: invalid experience store\n' >&2
    return 1
  fi
  if ! agent_sync_experience_skills; then
    printf 'maintenance: skill publication failed\n' >&2
    ma_failed=1
  fi
  [ "$ma_seen" -gt 0 ] || printf 'maintenance: no live experiences\n' >&2
  [ "$ma_failed" -eq 0 ]
}

# This is the runtime publication gate. The model may propose lifecycle state,
# but active/degraded rows are invisible unless their complete record, skill,
# non-trivial verifier list, synchronized catalog row, and successful evidence
# all agree. It does not execute arbitrary verifier commands during prompt
# construction.
agent_experience_record_ok() {
  er_store=$1
  er_id=$2
  agent_experience_id_ok "$er_id" || return 1
  er_dir=$er_store/experiences/$er_id
  er_exp=$er_dir/exp.json
  er_skill=$er_dir/SKILL.md
  er_index=$er_store/experiences/index.json
  [ -d "$er_store" ] && [ ! -L "$er_store" ] || return 1
  [ -d "$er_store/experiences" ] && [ ! -L "$er_store/experiences" ] || return 1
  [ -d "$er_dir" ] && [ ! -L "$er_dir" ] || return 1
  [ -f "$er_exp" ] && [ ! -L "$er_exp" ] || return 1
  [ -f "$er_skill" ] && [ ! -L "$er_skill" ] || return 1
  [ -f "$er_index" ] && [ ! -L "$er_index" ] || return 1
  [ -d "$er_store/runs" ] && [ ! -L "$er_store/runs" ] || return 1
  er_title=$(jq -er '.title | select(type == "string")' "$er_exp" 2>/dev/null) \
    || return 1
  agent_skill_file_ok "$er_skill" "$er_id" "$er_title" || return 1
  jq -Rs -e 'test("[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]") | not' \
    "$er_skill" >/dev/null 2>&1 || return 1
  jq -e --arg id "$er_id" '
    def string_array: type == "array" and all(.[]; type == "string");
    def utc: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    def noop:
      ascii_downcase | gsub("^[[:space:]]+|[[:space:]]+$"; "")
      | . == "true" or . == ":" or . == "exit 0" or startswith("echo ");
    type == "object"
    and ([.. | strings
          | select(test("[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]"))]
         | length) == 0
    and keys == ["applies_if","created_at","evidence","failures","id","kind",
                 "last_verified","preconditions","quarantine_reason","scope",
                 "status","successes","supersedes","title","verify","version"]
    and .id == $id
    and .kind == "procedure"
    and (.title | type == "string" and length > 0 and (contains("\n") | not))
    and (.status == "active" or .status == "degraded")
    and (.version | type == "number" and floor == . and . >= 1)
    and (.scope | type == "object")
    and (.scope | keys) == ["os","task_kinds","tools"]
    and (.scope.os | string_array and all(.[]; . == ascii_downcase))
    and (.scope.tools | string_array)
    and (.scope.task_kinds | string_array)
    and (.applies_if | string_array)
    and (.preconditions | string_array)
    and (.verify | string_array and length > 0
         and all(.[]; length > 0 and (contains("\n") | not) and (noop | not)))
    and (.evidence | string_array and length > 0
         and all(.[]; test("^agent-store/runs/[A-Za-z0-9][A-Za-z0-9._-]*[.]jsonl$")))
    and (.successes | type == "number" and floor == . and . >= 1)
    and (.failures | type == "number" and floor == . and . >= 0)
    and (.created_at | utc)
    and (.last_verified | utc)
    and .last_verified > .created_at
    and (.supersedes | type == "string")
    and (.quarantine_reason | type == "string")
  ' "$er_exp" >/dev/null 2>&1 || return 1

  # The metadata row must describe exactly this record and contain only an
  # in-store path representation.
  jq -e --slurpfile e "$er_exp" --arg id "$er_id" --arg store "$er_store" '
    [.experiences[]? | select(.id == $id)] as $rows
    | ($rows | length) == 1
      and $rows[0].title == $e[0].title
      and $rows[0].status == $e[0].status
      and $rows[0].version == $e[0].version
      and $rows[0].scope == $e[0].scope
      and $rows[0].applies_if == $e[0].applies_if
      and ($rows[0].path == $id
           or $rows[0].path == ("agent-store/experiences/" + $id)
           or $rows[0].path == ($store + "/experiences/" + $id))
  ' "$er_index" >/dev/null 2>&1 || return 1

  # Every declared verifier needs an exact successful evidence event for this
  # experience. Evidence is still auditable text, but publication cannot pass
  # on an empty list or a bare `true` command anymore.
  if ! jq -r '.verify[]' "$er_exp" | while IFS= read -r er_cmd; do
    er_hit=0
    for er_rel in $(jq -r '.evidence[]' "$er_exp"); do
      er_file=$INSTALL/$er_rel
      [ -f "$er_file" ] && [ ! -L "$er_file" ] || continue
      if jq -s -e --slurpfile e "$er_exp" --arg id "$er_id" --arg cmd "$er_cmd" \
          'def utc: type == "string"
             and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
           any(.[];
             type == "object" and .exp_id == $id and .cmd == $cmd
             and .exit == 0 and (.utc | utc) and .utc == $e[0].last_verified
             and (.note | type == "string")
             and .authority == "seed-runtime"
             and .cwd == "launch-workspace"
             and (.maintain_started | utc)
             and .maintain_started > $e[0].created_at
             and .maintain_started <= .utc
             and (.note | test("[\u3400-\u4dbf\u4e00-\u9fff\uf900-\ufaff]") | not))' \
          "$er_file" >/dev/null 2>&1; then
        er_hit=1
        break
      fi
    done
    [ "$er_hit" -eq 1 ] || exit 1
  done; then
    return 1
  fi
  return 0
}

# The experience -> skill bridge owns publication. The catalog renderer later
# applies scope, status, English keyword matching, ranking, and the top-3 cap,
# so there is one retrieval funnel rather than a second global activation path.
agent_sync_experience_skills() {
  sx_store=$INSTALL/agent-store
  sx_exp=$sx_store/experiences/index.json
  sx_idx=$sx_store/index.json
  [ -f "$sx_exp" ] || return 0
  [ -f "$sx_idx" ] || return 0
  [ ! -L "$sx_exp" ] && [ ! -L "$sx_idx" ] || return 1
  agent_state_lock_acquire || return $?
  sx_ok=$(jq -r '.experiences[]?
      | select(.status == "active" or .status == "degraded")
      | .id // empty' "$sx_exp" 2>/dev/null \
    | while IFS= read -r sx_id; do
        agent_experience_record_ok "$sx_store" "$sx_id" && printf '%s\n' "$sx_id"
        :
      done)
  sx_tmp=$(mktemp "$sx_store/.index.skills.XXXXXX") || {
    agent_state_lock_release
    return 1
  }
  if jq --slurpfile x "$sx_exp" --arg store "$sx_store" --arg okids "$sx_ok" '
      ($okids | split("\n") | map(select(length > 0))) as $valid
      | [ $x[0].experiences[]? | select((.id // "") != "") ] as $rows
      | [ (.agent.skills // [])[]
          | select((.source // "") != "experience"
                   and (((.note // "") | startswith("experience ")) | not))
          | .name ] as $reserved
      | [ $rows[]
          | select(.status == "active" or .status == "degraded")
          | .id as $i
          | select(($valid | index($i)) != null and ($reserved | index($i)) == null)
          | {name: $i,
             description: (.title // ""),
             path: ($store + "/experiences/" + $i + "/SKILL.md"),
             ok: true,
             source: "experience",
             status: .status,
             scope: .scope,
             applies_if: .applies_if,
             note: ("experience " + (.status // ""))} ] as $live
      | [ $rows[]
          | .id
          | . as $id
          | select(($live | map(.name) | index($id)) == null) ] as $dead
      | if (type != "object") then .
        else
          .agent.skills = (
            ((.agent.skills // [])
             | map(.name as $n | select(($live | map(.name) | index($n)) == null)))
            + $live)
          | .agent.skills = (.agent.skills
            | map(.name as $n
                  | if (($dead | index($n)) != null)
                       and ((.source // "") == "experience"
                            or ((.note // "") | startswith("experience")))
                    then .ok = false else . end))
        end
    ' "$sx_idx" > "$sx_tmp" 2>/dev/null && mv "$sx_tmp" "$sx_idx"; then
    agent_state_lock_release
    return 0
  else
    rm -f "$sx_tmp"
    agent_state_lock_release
    return 1
  fi
}

# Provenance: a run's evidence says which run spawned it and what role it
# plays, so nested seed invocations (a run launching `seed --oneshot` through
# the shell tool) form a chain like the Unix process tree. run.json is the
# record; run-env plus the exports hand this run's id to any child process.
run_provenance() {
  evd=$1
  ses=$2
  # Snapshot the incoming provenance once per process: the exports below
  # overwrite the live variables, and later runs in the same process must
  # still see what this process was invoked with.
  if [ "${SEED_PROV_SNAP:-}" != 1 ]; then
    SEED_PROV_PARENT=${SEED_PARENT_RUN_ID:-root}
    SEED_PROV_ROLE_IN=${SEED_RUN_ROLE:-}
    SEED_PROV_SNAP=1
  fi
  prov_role=$SEED_PROV_ROLE_IN
  if [ -z "$prov_role" ]; then
    if [ "$SEED_PROV_PARENT" = root ]; then prov_role=main; else prov_role=subagent; fi
  fi
  run_id=${evd##*/}
  printf '{"run_id":"%s","parent_run_id":"%s","role":"%s"}\n' \
    "$run_id" "$SEED_PROV_PARENT" "$prov_role" > "$evd/run.json"
  printf 'SEED_PARENT_RUN_ID=%s\nSEED_RUN_ROLE=subagent\nexport SEED_PARENT_RUN_ID SEED_RUN_ROLE\n' \
    "$run_id" > "$ses/run-env.tmp"
  mv "$ses/run-env.tmp" "$ses/run-env"
  export SEED_PARENT_RUN_ID="$run_id"
  export SEED_RUN_ROLE=subagent
}

agent_run_init() {
  pack=$INSTALL/agent-store/packs/init.json
  prompt=$(jq -r '.prompt // empty' "$pack")
  [ -n "$prompt" ] || die "agent pack: init prompt empty" 69
  ev=${AGENT_RUNS_DIR:-$PWD/.agent-runs}/$(date -u +%Y%m%dT%H%M%SZ)-$$-init
  sess=$ev/session
  mkdir -p "$ev"
  shell_init "$sess" "$PWD"
  run_provenance "$ev" "$sess"
  INIT_STOP_WHEN_READY=1
  export INIT_STOP_WHEN_READY
  run_loop "$(product_system '')" "$prompt" "$sess" "$ev" "$AGENT_MAX_ROUNDS" 0 || :
  unset INIT_STOP_WHEN_READY
  shell_stop "$sess" 2>/dev/null || :
  agent_repair_machine_tree || true
}

agent_ensure_init() {
  [ "${SLAB_SKIP_INIT:-}" = 1 ] && return 0
  if [ -f "$INSTALL/agent-store/index.json" ]; then
    agent_migrate_index_v2 || die "machine index migration failed" 76
  fi
  agent_ensure_project_memory || die "project memory initialization failed" 76
  # A cached v1 init pack can otherwise overwrite the version label and
  # namespaces that migration just repaired. Validate or refresh policy before
  # using its template against an existing machine index.
  if [ -f "$INSTALL/agent-store/index.json" ]; then
    agent_fetch_required
    agent_repair_machine_tree || die "machine index repair failed" 76
  fi
  if agent_check_machine_tree; then
    agent_try_update
    agent_bootstrap_machine
    agent_discard_baseline
    return 0
  fi
  if agent_restore_baseline; then
    agent_bootstrap_machine
    return 0
  fi
  printf 'initializing:\n' >&2
  agent_fetch_required
  agent_place_trees || die "agent state initialization failed" 76
  agent_bootstrap_machine
  agent_write_baseline || die "init failed" 76
  SEED_STREAM=1
  SEED_STREAM_PRINT=1
  export SEED_STREAM SEED_STREAM_PRINT
  agent_run_init
  agent_repair_machine_tree || true
  agent_bootstrap_machine
  if agent_check_machine_tree; then
    agent_discard_baseline
    printf 'ready\n' >&2
    return 0
  fi
  if agent_restore_baseline; then
    # The baseline intentionally contains only prerequisite results. Rebuild
    # runtime-observed identity after restoring it so `ready` never describes
    # a machine tree with an empty OS, kernel, PATH, or scan inventory.
    agent_bootstrap_machine
    agent_check_machine_tree || die "init failed" 76
    printf 'note: optional discovery skipped\n' >&2
    printf 'ready\n' >&2
    return 0
  fi
  die "init failed" 76
}

# Optional packs (memory, ...) land on demand through the runtime. If an
# explicit opt-in catalog refresh moves, refresh only optional packs already
# installed; never let an optional fetch abort the update.
agent_update_optional() {
  uo_index=$1
  uo_store=$INSTALL/agent-store
  uo_root=$(pack_root)
  for uo_name in $(printf '%s' "$uo_index" | jq -r '(.optional // {}) | keys[]?'); do
    uo_dest=$uo_store/packs/$uo_name.json
    [ -f "$uo_dest" ] || continue
    uo_rel=$(printf '%s' "$uo_index" | jq -r --arg n "$uo_name" '.optional[$n] // empty')
    [ -n "$uo_rel" ] || continue
    uo_tmp=$(mktemp "$uo_store/packs/.optional.XXXXXX") || continue
    if http_get "$(pack_join "$uo_root/agent" "$uo_rel")" "$uo_tmp" \
      && jq -e 'type == "object" and (.prompt | type) == "string"' \
        "$uo_tmp" >/dev/null 2>&1; then
      if agent_state_lock_acquire; then
        mv "$uo_tmp" "$uo_dest" || rm -f "$uo_tmp" 2>/dev/null || :
        agent_state_lock_release
      else
        rm -f "$uo_tmp"
      fi
    else
      rm -f "$uo_tmp"
    fi
  done
}

# Fetch one catalog-declared optional policy pack before the first task that
# may need it. The model never curls prompt policy itself. A failed optional
# fetch is non-fatal and leaves any existing copy untouched.
agent_ensure_optional_pack() {
  eo_name=$1
  eo_store=$INSTALL/agent-store
  eo_dest=$eo_store/packs/$eo_name.json
  [ -f "$eo_dest" ] \
    && jq -e 'type == "object" and (.prompt | type) == "string"' \
      "$eo_dest" >/dev/null 2>&1 && return 0
  eo_catalog=$eo_store/catalog.json
  [ -f "$eo_catalog" ] || return 1
  eo_rel=$(jq -r --arg n "$eo_name" '.optional[$n] // empty' "$eo_catalog" 2>/dev/null)
  [ -n "$eo_rel" ] || return 1
  mkdir -p "$eo_store/packs" || return 1
  eo_tmp=$(mktemp "$eo_store/packs/.optional.XXXXXX") || return 1
  if ! http_get "$(pack_join "$(pack_root)/agent" "$eo_rel")" "$eo_tmp" \
    || ! jq -e 'type == "object" and (.prompt | type) == "string"' \
      "$eo_tmp" >/dev/null 2>&1; then
    rm -f "$eo_tmp"
    return 1
  fi
  agent_state_lock_acquire || { rm -f "$eo_tmp"; return 75; }
  eo_status=0
  if [ -f "$eo_dest" ] \
    && jq -e 'type == "object" and (.prompt | type) == "string"' \
      "$eo_dest" >/dev/null 2>&1; then
    rm -f "$eo_tmp" 2>/dev/null || :
  else
    mv "$eo_tmp" "$eo_dest" || eo_status=$?
  fi
  [ "$eo_status" -eq 0 ] || rm -f "$eo_tmp" 2>/dev/null || :
  agent_state_lock_release
  [ "$eo_status" -eq 0 ] || return "$eo_status"
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
  agent_fetch_pack "$index"
  agent_update_optional "$index"
  if [ -f "$store/index.json" ]; then
    nr=$(jq -r '.machine_tree.system.retrieve // empty' "$store/packs/init.json")
    if [ -n "$nr" ]; then
      agent_state_lock_acquire || return $?
      tmpi2=$(mktemp "$store/.index.retrieve.XXXXXX") || {
        agent_state_lock_release
        return 1
      }
      if jq --arg r "$nr" '
        .system.retrieve=$r
        | if .system["web"] then .system["web"] |= with_entries(select(.key == "fetch")) else . end
      ' "$store/index.json" > "$tmpi2" && mv "$tmpi2" "$store/index.json"; then
        agent_state_lock_release
      else
        rm -f "$tmpi2"
        agent_state_lock_release
        return 1
      fi
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
    '/maintain             verify and reconcile experience memory' \
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
  src=${SEED_RUNTIME_URL:-$(seed_site)/dl/seed.sh}
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
  export SEED_HOME="$INSTALL"
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
  url=$(packs_index_url)
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
  url=$(packs_dl_url "$slug")
  body=$(mktemp "${TMPDIR:-/tmp}/seed-pinst.XXXXXX")
  if ! http_get "$url" "$body"; then
    seed_http_err "pack $slug"
    rm -f "$body"
    return 71
  fi
  # A pack published as a bare prompt carries no slug, and apply would file
  # it under the generic name every slug-less pack gets, so the second one
  # installed overwrites the first and the receipt names neither. We asked
  # for this slug by name; stamp it on before applying.
  if ! jq -e 'has("slug")' "$body" >/dev/null 2>&1; then
    stamped=$body.slug
    if jq --arg s "$slug" '. + {slug: $s}' "$body" > "$stamped" 2>/dev/null &&
       [ -s "$stamped" ]; then
      mv "$stamped" "$body"
    else
      rm -f "$stamped"
    fi
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
  if [ "$cmd" = /ini ]; then
    seed_install_global
    return $?
  fi
  ensure_jq
  seed_resolve_mode
  if [ "$cmd" = /maintain ]; then
    [ "$SEED_RUN_MODE" = agent ] || {
      printf 'error: maintenance needs Agent mode\n' >&2
      return 64
    }
    agent_ensure_init
    agent_maintain_experiences
  else
    seed_pack_cmd "$cmd"
  fi
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
  printf 'seed.content=%s\n' "$(seed_content_id "$SELF")"
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
      # Name a command that exists where the human is standing. Piped from
      # curl, $0 is the shell binary and no seed.sh was ever written; the
      # only thing to run is the wrapper we just made, and sending them
      # after a file that is not there ends the install right here.
      if [ -n "${SEED_SELF:-}" ] && [ -x "$SEED_SELF" ] && ! seed_runtime_ok "$SELF"; then
        first_cmd="$SEED_SELF deepseek <API_KEY>"
      else
        first_cmd='sh seed.sh deepseek <API_KEY>'
      fi
      [ -n "${LLM_API_KEY:-}" ] || die "first run: $first_cmd" 64
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

seed_content_id() {
  sc_file=$1
  cksum "$sc_file" 2>/dev/null | awk '{print $1 "-" $2}'
}

seed_runtime_source() {
  if seed_runtime_ok "$SELF"; then
    printf '%s\n' "$SELF"
  elif seed_runtime_ok "$INSTALL/.seed-runtime.sh"; then
    printf '%s\n' "$INSTALL/.seed-runtime.sh"
  else
    return 1
  fi
}

# Select an existing directory from the caller's original PATH. It must be
# writable and owned by the current user; /ini never edits a shell profile or
# invents a future-login-only PATH entry.
seed_find_install_dir() {
  ( IFS=:
    si_user=$(id -un 2>/dev/null || true)
    [ -n "$si_user" ] || exit 1
    for si_dir in $SEED_LAUNCH_PATH; do
      [ -n "$si_dir" ] || continue
      [ -d "$si_dir" ] && [ -w "$si_dir" ] || continue
      si_dir=$(CDPATH= cd "$si_dir" 2>/dev/null && pwd -P) || continue
      si_owned=$(find "$si_dir" -prune -user "$si_user" -print 2>/dev/null || true)
      [ "$si_owned" = "$si_dir" ] || continue
      printf '%s\n' "$si_dir"
      exit 0
    done
    exit 1 )
}

seed_validate_install() {
  entry=$1
  source=$2
  content=$3
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
  cmp -s "$source" "$entry" || {
    printf 'error: install entry content mismatch\n' >&2
    return 76
  }
  resolved=$(PATH=$SEED_LAUNCH_PATH command -v seed 2>/dev/null || true)
  if [ -n "$resolved" ]; then
    resolved_dir=$(CDPATH= cd "$(dirname "$resolved")" 2>/dev/null && pwd -P) || resolved_dir=
    [ -n "$resolved_dir" ] && resolved=$resolved_dir/$(basename "$resolved")
  fi
  [ "$resolved" = "$entry" ] || {
    printf 'error: installed seed is not the PATH entry (resolved=%s expected=%s)\n' \
      "$resolved" "$entry" >&2
    return 76
  }
  /bin/sh -n "$entry" >/dev/null 2>&1 || {
    printf 'error: install entry failed syntax check\n' >&2
    return 76
  }
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
  printf '%s\n' "$probe" | grep -qxF "seed.workspace=$LAUNCH_CWD" || {
    printf 'error: install entry workspace mismatch\n' >&2
    return 76
  }
  printf '%s\n' "$probe" | grep -qxF "seed.content=$content" || {
    printf 'error: install entry content identity mismatch\n' >&2
    return 76
  }
  return 0
}

seed_install_global() {
  command -v jq >/dev/null 2>&1 || {
    printf 'error: /ini requires an existing jq; no download was attempted\n' >&2
    return 69
  }
  si_source=$(seed_runtime_source) || {
    printf 'error: current seed runtime is not materialized\n' >&2
    return 76
  }
  si_content=$(seed_content_id "$si_source")
  [ -n "$si_content" ] || {
    printf 'error: cannot identify current seed runtime\n' >&2
    return 76
  }

  si_existing=$(PATH=$SEED_LAUNCH_PATH command -v seed 2>/dev/null || true)
  if [ -n "$si_existing" ]; then
    if seed_validate_install "$si_existing" "$si_source" "$si_content"; then
      printf 'installed: %s\n' "$si_existing" >&2
      return 0
    fi
    printf 'error: refusing to overwrite existing seed command: %s\n' "$si_existing" >&2
    return 76
  fi

  si_dir=$(seed_find_install_dir) || {
    printf 'error: no user-owned writable directory exists on the launch PATH\n' >&2
    return 76
  }
  si_entry=$si_dir/seed
  si_runtimes=$INSTALL/runtimes
  si_runtime=$si_runtimes/seed-$si_content.sh
  si_created_runtime=0
  si_created_entry=0
  mkdir -p "$si_runtimes" || return 76

  if [ -e "$si_runtime" ]; then
    cmp -s "$si_source" "$si_runtime" || {
      printf 'error: runtime content-id collision\n' >&2
      return 76
    }
  else
    si_tmp=$(mktemp "$si_runtimes/.seed.XXXXXX") || return 76
    if ! cp "$si_source" "$si_tmp" || ! chmod 700 "$si_tmp" \
      || ! /bin/sh -n "$si_tmp" >/dev/null 2>&1; then
      rm -f "$si_tmp" 2>/dev/null || :
      printf 'error: failed to stage seed runtime\n' >&2
      return 76
    fi
    if ln "$si_tmp" "$si_runtime" 2>/dev/null; then
      si_created_runtime=1
    elif ! cmp -s "$si_tmp" "$si_runtime"; then
      rm -f "$si_tmp" 2>/dev/null || :
      printf 'error: failed to publish seed runtime\n' >&2
      return 76
    fi
    rm -f "$si_tmp" 2>/dev/null || :
  fi

  if [ "${SEED_TEST_INSTALL_FAIL_AFTER_RUNTIME:-}" = 1 ]; then
    [ "$si_created_runtime" -eq 0 ] || rm -f "$si_runtime" 2>/dev/null || :
    printf 'error: install transaction rolled back (simulated install failure)\n' >&2
    return 76
  fi

  if ln -s "$si_runtime" "$si_entry" 2>/dev/null; then
    si_created_entry=1
  else
    [ "$si_created_runtime" -eq 0 ] || rm -f "$si_runtime" 2>/dev/null || :
    printf 'error: install transaction rolled back (entry appeared concurrently)\n' >&2
    return 76
  fi

  if ! seed_validate_install "$si_entry" "$si_source" "$si_content"; then
    if [ "$si_created_entry" -eq 1 ] && [ -L "$si_entry" ] \
      && cmp -s "$si_runtime" "$si_entry"; then
      rm -f "$si_entry" 2>/dev/null || :
    fi
    [ "$si_created_runtime" -eq 0 ] || rm -f "$si_runtime" 2>/dev/null || :
    printf 'error: install transaction rolled back\n' >&2
    return 76
  fi

  if [ "${SEED_TEST_INSTALL_FAIL_AFTER_ENTRY:-}" = 1 ]; then
    if [ "$si_created_entry" -eq 1 ] && [ -L "$si_entry" ] \
      && cmp -s "$si_runtime" "$si_entry"; then
      rm -f "$si_entry" 2>/dev/null || :
    fi
    [ "$si_created_runtime" -eq 0 ] || rm -f "$si_runtime" 2>/dev/null || :
    printf 'error: install transaction rolled back (simulated receipt failure)\n' >&2
    return 76
  fi

  si_receipt=$INSTALL/install-result.json
  si_receipt_tmp=$(mktemp "$INSTALL/.install-result.XXXXXX") || {
    if [ "$si_created_entry" -eq 1 ] && [ -L "$si_entry" ] \
      && cmp -s "$si_runtime" "$si_entry"; then
      rm -f "$si_entry" 2>/dev/null || :
    fi
    [ "$si_created_runtime" -eq 0 ] || rm -f "$si_runtime" 2>/dev/null || :
    printf 'error: install transaction rolled back (receipt staging failed)\n' >&2
    return 76
  }
  if ! jq -n --arg entry "$si_entry" --arg runtime "$si_runtime" \
      --arg content "$si_content" \
      '{command:"seed",entry:$entry,runtime:$runtime,content:$content}' \
      > "$si_receipt_tmp" \
    || ! mv "$si_receipt_tmp" "$si_receipt"; then
    rm -f "$si_receipt_tmp" 2>/dev/null || :
    if [ "$si_created_entry" -eq 1 ] && [ -L "$si_entry" ] \
      && cmp -s "$si_runtime" "$si_entry"; then
      rm -f "$si_entry" 2>/dev/null || :
    fi
    [ "$si_created_runtime" -eq 0 ] || rm -f "$si_runtime" 2>/dev/null || :
    printf 'error: install transaction rolled back (receipt write failed)\n' >&2
    return 76
  fi
  printf 'installed: %s\n' "$si_entry" >&2
}

seed_run_task() {
  task=$1
  case $task in
    /ini) seed_install_global; return $? ;;
    --maintain|/maintain) agent_maintain_experiences; return $? ;;
    # /help answers from the runtime here for the same reason it does on the
    # command line: the human is asking what they can type, and sending that
    # to the model makes it go build a commands table before it can answer.
    /help) seed_help; return 0 ;;
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
  run_provenance "$ev" "$sess"
  agent_ensure_optional_pack memory 2>/dev/null || :
  rs=0
  run_loop "$(product_system "$task")" "$task" "$sess" "$ev" "$AGENT_MAX_ROUNDS" 1 || rs=$?
  [ "${SEED_RUN_MODE:-agent}" = simple ] || agent_sync_experience_skills || :
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
  if [ "$oneshot" -eq 1 ] \
    && { [ "$task" = --maintain ] || [ "$task" = /maintain ]; }; then
    ensure_jq
    seed_resolve_mode
    [ "$SEED_RUN_MODE" = simple ] || agent_ensure_init
    agent_maintain_experiences
    return $?
  fi
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
  /ini|/maintain|/packs|/pack)
    seed_cli_slash "$@"
    exit $? ;;
  --maintain)
    seed_cli_slash /maintain
    exit $? ;;
  --oneshot|-p)
    # One-shot operation uses the existing saved activation.
    seed_main "$@"
    exit $? ;;
  -*) seed_usage; exit 64 ;;
esac

seed_main "$@"
