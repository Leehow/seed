#!/bin/sh
# seed.sh — one-file installer package (LOOP / SYSTEM / TASK in memory).
#   sh seed.sh deepseek sk-xxxx [install-dir]
#   sh seed.sh [install-dir]          # resume, credentials from .env
#   sh seed.sh --selftest
set -eu
umask 077

SELF=$(CDPATH= cd "$(dirname "$0")" && pwd -P)/$(basename "$0")
MAX_ROUNDS=${SEED_MAX_ROUNDS:-40}
AGENT_MAX_ROUNDS=${AGENT_MAX_ROUNDS:-20}
ACTION_TIMEOUT=${SEED_ACTION_TIMEOUT:-180}
MAX_OBS_BYTES=${SEED_MAX_OBS_BYTES:-16384}
HTTP_TIMEOUT=${SEED_HTTP_TIMEOUT:-300}
LAUNCH_CWD=$(pwd -P)

die() { printf '错误：%s\n' "$1" >&2; exit "${2:-70}"; }
heartbeat() { printf '\r[seed] tokens prompt=%s completion=%s' "${1:-0}" "${2:-0}" >&2; }

usage() {
  cat >&2 <<'EOF'
用法：
  sh seed.sh deepseek <API_KEY> [目标目录]  开始安装（或把渠道写成完整 URL）
  sh seed.sh [目标目录]                     继续 / 重装（凭据读 .env）
  sh seed.sh --selftest                     离线自测，不联网
默认装到当前目录。装好后：sh bin/agent
EOF
}

need() { command -v "$1" >/dev/null 2>&1 || die "需要 $1。" 69; }

# ----------------------------------------------------------------- cabins

cabin_system() {
  cat <<EOF
You are an installer, not a chat window. You have exactly two tools via tool_calls: shell (persistent) and edit (unique string replace).
The seed already wrote $INSTALL/seed.sh and $INSTALL/bin/{agent,llm,edit,shell}. Inspect with short commands, fix only what is broken, then stop.
Never invoke seed.sh as an installer. Never call verify_install. Never cat the entire seed.sh. Never start a nested agent loop or a long-running command.
The product workspace is the directory where the human launches bin/agent — never bake a host absolute workspace path into the agent.
When bin/agent exists, prints a Chinese banner mentioning 当前目录, and has no hardcoded workspace path, stop: final text only, no more tool_calls. The seed verifies the install itself.
Host facts:
$FACTS
EOF
}

cabin_task() {
  cat <<EOF
Confirm the interactive agent at $INSTALL is ready: sh $INSTALL/bin/agent
Check with short ls / head / banner (stdin EOF). Do not re-run the installer. Do not run verify_install. Stop as soon as the shims look correct.
EOF
}

cabin_product_system() {
  cat <<'EOF'
You are a coding agent. You have exactly two tools via tool_calls: shell (a persistent login shell) and edit (unique string replace in a file).
The workspace is the current directory at launch. Look before you edit. After edits, check your work with shell.
Do not stream your process to the human. When the task is done, reply with a short final answer and no tool_calls.
EOF
}

cabin_banner() {
  cat <<'EOF'
能在当前目录改文件、跑命令。建议先看再改，改完自己检查。
空行或 Ctrl-D 退出。
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

# ----------------------------------------------------------------- env

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
    *) die "不认识的渠道：$1（用 deepseek，或完整 API URL）" 64 ;;
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

# ----------------------------------------------------------------- edit

edit_main() {
  [ "$#" -eq 3 ] || die '用法: --edit PATH OLD NEW' 64
  need jq
  path=$1 old=$2 new=$3
  [ -n "$old" ] || { printf 'edit: old_text is empty\n' >&2; return 2; }
  [ -f "$path" ] || { printf 'edit: cannot read %s\n' "$path" >&2; return 66; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/seed-edit.XXXXXX")
  set +e
  jq -nr --rawfile t "$path" --arg old "$old" --arg new "$new" '
    ($t | split($old)) as $p
    | if ($p | length) != 2 then
        ("edit: old_text matches \(($p | length) - 1) times, need exactly 1\n" | halt_error(2))
      else
        $p[0] + $new + $p[1]
      end
  ' > "$tmp"
  es=$?
  set -e
  if [ "$es" -ne 0 ]; then
    rm -f "$tmp"
    return "$es"
  fi
  mv "$tmp" "$path"
}

# --------------------------------------------------------- persistent shell

shell_init() {
  session=$1
  workdir=$2
  mkdir -p "$session"
  printf '%s\n' "$workdir" > "$session/workdir"
  : > "$session/alive"
  cat > "$session/worker.sh" <<'EOS'
#!/bin/sh
SESSION=$1
cd "$(cat "$SESSION/workdir")" || exit 70
while [ -f "$SESSION/alive" ]; do
  if [ ! -f "$SESSION/request" ]; then
    sleep 0.05 2>/dev/null || sleep 1
    continue
  fi
  cmd=$(cat "$SESSION/request")
  rm -f "$SESSION/request" "$SESSION/done"
  eval "$cmd" > "$SESSION/stdout" 2> "$SESSION/stderr"
  echo $? > "$SESSION/status"
  pwd > "$SESSION/cwd"
  : > "$SESSION/done"
done
EOS
  USER_SHELL=${USER_SHELL:-${SHELL:-/bin/sh}}
  # Detach stdio so a parent $(...) cannot hang on this worker.
  "$USER_SHELL" "$session/worker.sh" "$session" \
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
  n=0
  while [ ! -f "$session/done" ]; do
    n=$((n + 1))
    if [ "$n" -gt "$ACTION_TIMEOUT" ]; then
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
    sleep 1
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

# ----------------------------------------------------------------- model

assemble_stream() {
  need jq
  jq -n --rawfile raw "$1" '
    def events:
      ($raw | fromjson? // null) as $one
      | if ($one | type) == "object" then
          [$one]
        else
          [$raw
            | split("\n")[]
            | rtrimstr("\r")
            | if startswith("data: ") then .[6:] else . end
            | select(. != "" and . != "[DONE]")
            | fromjson? // empty]
        end;
    def add_delta_tools($ts):
      reduce $ts[] as $t (.;
        ($t.index // 0 | tostring) as $i
        | .tools[$i] = ((.tools[$i] // {id:"",name:"",arguments:""})
          | .id = (if $t.id then $t.id else .id end)
          | .name += ($t.function.name // "")
          | .arguments += ($t.function.arguments // "")));
    def add_msg_tools($ts):
      reduce $ts[] as $t (.;
        (([.tools | keys[] | tonumber] | max // -1) + 1 | tostring) as $i
        | .tools[$i] = {
            id: ($t.id // ""),
            name: ($t.function.name // ""),
            arguments: ($t.function.arguments // "")
          });
    reduce events[] as $d (
      {content:"", tools:{}, usage:{}};
      (($d.choices // [{}])[0]) as $ch
      | ($ch.delta // {}) as $delta
      | ($ch.message // {}) as $msg
      | .content += ($delta.content // "")
      | .content += ($msg.content // "")
      | if $d.usage then .usage = $d.usage else . end
      | add_delta_tools($delta.tool_calls // [])
      | add_msg_tools($msg.tool_calls // [])
    )
    | {
        content,
        tool_calls: (
          .tools
          | to_entries
          | sort_by(.key | tonumber)
          | map(.value)
        ),
        usage
      }
  '
}

model_turn() {
  msgs=$1
  dest=$2
  if [ -n "${SEED_LLM_STUB:-}" ]; then
    "$SEED_LLM_STUB" --messages "$msgs" > "$dest"
    return 0
  fi
  load_env
  [ -n "${LLM_API_KEY:-}" ] || die '找不到 API Key（.env 或环境变量）。' 64
  need curl
  need jq
  work=$(mktemp -d "${TMPDIR:-/tmp}/seed-llm.XXXXXX")
  tools_json > "$work/tools.json"
  extra=${LLM_EXTRA:-'{}'}
  jq -n --arg m "$LLM_MODEL" --slurpfile msg "$msgs" --slurpfile t "$work/tools.json" --argjson x "$extra" \
    '{model:$m,stream:true,stream_options:{include_usage:true},messages:$msg[0],tools:$t[0]} + $x' \
    > "$work/req.json"
  printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$LLM_API_KEY" > "$work/h"
  set +e
  curl -N -q -sS --connect-timeout 15 --max-time "$HTTP_TIMEOUT" -X POST \
    -H "@$work/h" --data-binary "@$work/req.json" \
    -w '\n__HTTP__%{http_code}\n' "$LLM_API_URL" > "$work/raw"
  cs=$?
  set -e
  [ "$cs" -eq 0 ] || { rm -rf "$work"; die "llm: 网络请求失败（curl=$cs）。" 71; }
  code=$(awk '/^__HTTP__/{print substr($0,9)}' "$work/raw" | tail -1)
  case $code in
    2*) : ;;
    401|403) rm -rf "$work"; die "llm: API Key 被拒绝（HTTP $code）。" 77 ;;
    *) rm -rf "$work"; die "llm: HTTP ${code:-000}" 72 ;;
  esac
  awk '!/^__HTTP__/' "$work/raw" > "$work/sse"
  assemble_stream "$work/sse" > "$dest"
  cp "$work/sse" "$dest.sse" 2>/dev/null || :
  rm -rf "$work"
}

llm_main() {
  msgs=
  while [ "$#" -gt 0 ]; do
    case $1 in
      --messages) msgs=$2; shift 2 ;;
      *) die "llm: 未知参数 $1" 64 ;;
    esac
  done
  work=$(mktemp -d "${TMPDIR:-/tmp}/seed-llmcli.XXXXXX")
  trap 'rm -rf "$work"' EXIT
  if [ -n "$msgs" ]; then cp "$msgs" "$work/m.json"
  else
    cat > "$work/p.txt"
    [ -s "$work/p.txt" ] || die 'llm: stdin 为空。' 64
    jq -Rs '[{role:"user",content:.}]' < "$work/p.txt" > "$work/m.json"
  fi
  model_turn "$work/m.json" "$work/t.json"
  jq -r '.content // empty' "$work/t.json"
}

# ----------------------------------------------------------------- loop

exec_tool() {
  session=$1
  name=$2
  args=$3
  ev=$4
  case $name in
    shell)
      cmd=$(printf '%s' "$args" | jq -r '.command // empty')
      [ -n "$cmd" ] || { printf 'shell: missing command\n' > "$ev"; return 0; }
      # Write the file directly. $(cmd | tee) deadlocks in /bin/sh after a timeout.
      shell_run "$session" "$cmd" > "$ev"
      ;;
    edit)
      path=$(printf '%s' "$args" | jq -r '.path // empty')
      old=$(printf '%s' "$args" | jq -r '.old_text // empty')
      new=$(printf '%s' "$args" | jq -r '.new_text // empty')
      set +e
      edit_main "$path" "$old" "$new" > "$ev.out" 2> "$ev.err"
      es=$?
      set -e
      {
        if [ "$es" -eq 0 ]; then printf 'ok\n'
        else printf 'edit failed (exit %s)\n' "$es"; cat "$ev.err"
        fi
      } > "$ev"
      ;;
    *) printf 'unknown tool: %s\n' "$name" > "$ev" ;;
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
  jq -n --arg s "$system" --arg u "$user" \
    '[{role:"system",content:$s},{role:"user",content:$u}]' > "$msgs"
  round=1
  final=
  while [ "$round" -le "$max" ]; do
    model_turn "$msgs" "$evdir/turn-$round.json"
    pt=$(jq -r '.usage.prompt_tokens // 0' "$evdir/turn-$round.json")
    ct=$(jq -r '.usage.completion_tokens // 0' "$evdir/turn-$round.json")
    if [ "$print_final" -eq 0 ]; then
      heartbeat "$pt" "$ct"
      printf '\n' >&2
    fi
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
    else
      final=$content
      jq --arg c "$content" '. + [{role:"assistant",content:$c}]' "$msgs" > "$msgs.n" && mv "$msgs.n" "$msgs"
      break
    fi
    round=$((round + 1))
  done
  if [ "$round" -gt "$max" ] && [ -z "$final" ]; then
    if [ "$print_final" -eq 1 ]; then
      printf '达到轮数上限，任务没有做完。\n'
      return 0
    fi
    return 75
  fi
  [ "$print_final" -eq 1 ] && [ -n "$final" ] && printf '%s\n' "$final"
  return 0
}

# ----------------------------------------------------------------- install bits

write_shims() {
  mkdir -p "$INSTALL/bin"
  if [ "$SELF" != "$INSTALL/seed.sh" ]; then
    cp "$SELF" "$INSTALL/seed.sh"
    chmod 755 "$INSTALL/seed.sh"
  fi
  for pair in "agent|--agent" "llm|--llm" "edit|--edit" "shell|--shell-cli"; do
    name=${pair%%|*}
    flag=${pair#*|}
    printf '#!/bin/sh\nexec /bin/sh "$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)/seed.sh" %s "$@"\n' "$flag" > "$INSTALL/bin/$name"
    chmod 755 "$INSTALL/bin/$name"
  done
}

verify_install() {
  bad=0
  for f in agent llm edit shell; do
    p=$INSTALL/bin/$f
    if [ ! -x "$p" ]; then
      printf '  FAIL 缺少 %s\n' "$p" >&2; bad=$((bad + 1))
    elif ! /bin/sh -n "$p" 2>/dev/null; then
      printf '  FAIL %s 语法检查失败\n' "$p" >&2; bad=$((bad + 1))
    fi
  done
  [ -f "$INSTALL/seed.sh" ] || { printf '  FAIL 缺少 seed.sh\n' >&2; bad=$((bad + 1)); }
  if [ ! -f "$LAUNCH_CWD/.env" ] || [ ! -f "$INSTALL/.env" ]; then
    printf '  FAIL .env 不完整\n' >&2; bad=$((bad + 1))
  else
    k1=$(jq -r -n --rawfile e "$LAUNCH_CWD/.env" '$e | split("\n") | map(select(startswith("LLM_API_KEY="))) | .[0] | split("=")[1]' 2>/dev/null || grep '^LLM_API_KEY=' "$LAUNCH_CWD/.env" | sed 's/^LLM_API_KEY=//')
    [ -n "$k1" ] || { printf '  FAIL .env 没有 key\n' >&2; bad=$((bad + 1)); }
  fi
  intro=$(LAUNCH_CWD=$LAUNCH_CWD /bin/sh "$INSTALL/bin/agent" </dev/null 2>&1 || true)
  printf '%s' "$intro" | grep -q '当前目录' || { printf '  FAIL 引导语缺失\n' >&2; bad=$((bad + 1)); }
  baked=$(printf '/%s/|/%s/' Users home)
  if grep -E "$baked" "$INSTALL/bin/agent" "$INSTALL/bin/edit" "$INSTALL/bin/llm" "$INSTALL/bin/shell" >/dev/null 2>&1; then
    printf '  FAIL shim 写死了本机路径\n' >&2; bad=$((bad + 1))
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
    SEED_LLM_STUB=$stub SEED_VER_N=$w/n /bin/sh "$INSTALL/bin/agent" --oneshot 'pwd'
  ) > "$w/out" 2> "$w/err"
  set -e
  if ! grep -q ok "$w/out"; then
    printf '  FAIL 假 tool_calls 没有跑通\n' >&2; bad=$((bad + 1))
  fi
  if ! grep -FR "$w" "$w/.agent-runs" >/dev/null 2>&1; then
    printf '  FAIL 假调用工作区不是临时目录\n' >&2; bad=$((bad + 1))
  fi
  rm -rf "$w"
  [ "$bad" -eq 0 ] || die "验收挂了 $bad 项。" 76
}

install_main() {
  need jq
  [ -n "${SEED_LLM_STUB:-}" ] || need curl
  probe
  write_env_file "$LAUNCH_CWD/.env"
  write_env_file "$INSTALL/.env"
  ensure_gitignore "$LAUNCH_CWD"
  write_shims
  RUN_DIR=$INSTALL/.runs/$(date -u +%Y%m%dT%H%M%SZ)-$$
  mkdir -p "$RUN_DIR"
  sess=$RUN_DIR/session
  shell_init "$sess" "$INSTALL"
  set +e
  run_loop "$(cabin_system)" "$(cabin_task)" "$sess" "$RUN_DIR" "$MAX_ROUNDS" 0
  ls=$?
  set -e
  shell_stop "$sess"
  [ "$ls" -eq 0 ] || [ "$ls" -eq 75 ] || exit "$ls"
  if [ "$ls" -eq 75 ]; then
    printf '模型跑满 %s 轮，改看磁盘验收。\n' "$MAX_ROUNDS" >&2
  fi
  verify_install
  printf '%s\n' 0 > "$RUN_DIR/exit-code"
  printf '\n============ 装好了 ============\n  %s/bin/agent\n================================\n' "$INSTALL" >&2
}

# ----------------------------------------------------------------- agent

agent_main() {
  INSTALL=$(CDPATH= cd "$(dirname "$SELF")" && pwd -P)
  load_env
  oneshot=0
  task=
  if [ "${1:-}" = --oneshot ]; then
    oneshot=1; shift; task=$*
  elif [ "$#" -ge 1 ]; then
    oneshot=1; task=$*
  fi
  cabin_banner
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
  shell_init "$sess" "$PWD"
  set +e
  run_loop "$(cabin_product_system)" "$task" "$sess" "$ev" "$AGENT_MAX_ROUNDS" 1
  as=$?
  set -e
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
    if [ ! -f "$sess/alive" ]; then
      sess=$ev/session
      shell_init "$sess" "$PWD"
    fi
    run_loop "$(cabin_product_system)" "$line" "$sess" "$ev" "$AGENT_MAX_ROUNDS" 1 || :
  done
  shell_stop "$sess" 2>/dev/null || :
}

# ----------------------------------------------------------------- selftest

selftest() {
  t=$(CDPATH= cd "$(dirname "$SELF")" && pwd -P)/tests/seed-package.sh
  [ -f "$t" ] || die "离线套件在 $t（请在仓库根目录跑）。" 69
  exec /bin/sh "$t"
}

# ----------------------------------------------------------------- main

case ${1:-} in
  --assemble) shift; assemble_stream "$1"; exit 0 ;;
  --llm) shift; llm_main "$@"; exit 0 ;;
  --edit) shift; edit_main "$@"; exit 0 ;;
  --shell-init) shift; probe; shell_init "$1" "$2"; exit 0 ;;
  --shell) shift; shell_run "$1" "$2"; exit 0 ;;
  --shell-stop) shift; shell_stop "$1"; exit 0 ;;
  --shell-cli) shift; die 'shell CLI：由 agent 内部调用。' 64 ;;
  --agent) shift; agent_main "$@"; exit 0 ;;
  --selftest) selftest; exit 0 ;;
  -h|--help) usage; exit 0 ;;
esac

case ${1:-} in
  '') INSTALL=${SEED_INSTALL:-.} ;;
  -*) usage; exit 64 ;;
  *)
    if [ "$#" -ge 2 ]; then
      resolve_provider "$1" "$2"
      INSTALL=${3:-.}
    else
      case $1 in
        deepseek|http*://*)
          die "第一次需要 key：sh seed.sh deepseek sk-xxxx" 64 ;;
      esac
      INSTALL=$1
      load_env
      [ -n "${LLM_API_KEY:-}" ] || die "$INSTALL 没有凭据。第一次：sh seed.sh deepseek sk-xxxx" 64
      LLM_PROVIDER=${LLM_PROVIDER:-deepseek}
      LLM_API_URL=${LLM_API_URL:-https://api.deepseek.com/chat/completions}
      LLM_MODEL=${LLM_MODEL:-deepseek-v4-flash}
    fi ;;
esac
mkdir -p "$INSTALL"
INSTALL=$(CDPATH= cd "$INSTALL" && pwd -P)
install_main
