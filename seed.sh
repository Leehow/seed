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

cabin_product_system() {
  cat <<'EOF'
You are a coding agent. You have exactly two tools via tool_calls: shell (a persistent login shell) and edit (unique string replace in a file).
The workspace is the current directory at launch. Look before you edit. After edits, check your work with shell.
Do not stream your process to the human. When the task is done, reply with a short final answer and no tool_calls.
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

model_turn() {
  msgs=$1
  dest=$2
  if [ -n "${SEED_LLM_STUB:-}" ]; then
    "$SEED_LLM_STUB" --messages "$msgs" > "$dest"
    return 0
  fi
  load_env
  [ -n "${LLM_API_KEY:-}" ] || die 'missing API key (.env or environment)' 64
  need curl
  need jq
  work=$(mktemp -d "${TMPDIR:-/tmp}/seed-llm.XXXXXX")
  tools_json > "$work/tools.json"
  extra=${LLM_EXTRA:-'{}'}
  jq -n --arg m "$LLM_MODEL" --slurpfile msg "$msgs" --slurpfile t "$work/tools.json" --argjson x "$extra" \
    '{model:$m,stream:false,messages:$msg[0],tools:$t[0]} + $x' \
    > "$work/req.json"
  printf 'Authorization: Bearer %s\nContent-Type: application/json\n' "$LLM_API_KEY" > "$work/h"
  set +e
  curl -q -sS --connect-timeout 15 --max-time "$HTTP_TIMEOUT" -X POST \
    -H "@$work/h" --data-binary "@$work/req.json" \
    -w '\n__HTTP__%{http_code}\n' "$LLM_API_URL" > "$work/raw"
  cs=$?
  set -e
  [ "$cs" -eq 0 ] || { rm -rf "$work"; die "llm: network failed (curl=$cs)" 71; }
  code=$(awk '/^__HTTP__/{print substr($0,9)}' "$work/raw" | tail -1)
  case $code in
    2*) : ;;
    401|403) rm -rf "$work"; die "llm: API key rejected (HTTP $code)" 77 ;;
    *) rm -rf "$work"; die "llm: HTTP ${code:-000}" 72 ;;
  esac
  awk '!/^__HTTP__/' "$work/raw" > "$work/body"
  parse_turn "$work/body" > "$dest"
  cp "$work/body" "$dest.raw" 2>/dev/null || :
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
  work=$(mktemp -d "${TMPDIR:-/tmp}/seed-llmcli.XXXXXX")
  trap 'rm -rf "$work"' EXIT
  if [ -n "$msgs" ]; then cp "$msgs" "$work/m.json"
  else
    cat > "$work/p.txt"
    [ -s "$work/p.txt" ] || die 'llm: empty stdin' 64
    jq -Rs '[{role:"user",content:.}]' < "$work/p.txt" > "$work/m.json"
  fi
  model_turn "$work/m.json" "$work/t.json"
  jq -r '.content // empty' "$work/t.json"
}

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
  intro=$(LAUNCH_CWD=$LAUNCH_CWD /bin/sh "$INSTALL/bin/agent" </dev/null 2>&1 || true)
  printf '%s' "$intro" | grep -q '>' || { printf '  FAIL agent prompt missing\n' >&2; bad=$((bad + 1)); }
  extra=$(printf '%s' "$intro" | tr -d '>\n ')
  [ -z "$extra" ] || { printf '  FAIL agent lectured on open\n' >&2; bad=$((bad + 1)); }
  baked=$(printf '/%s/|/%s/' Users home)
  if grep -E "$baked" "$INSTALL/bin/agent" "$INSTALL/bin/edit" "$INSTALL/bin/llm" "$INSTALL/bin/shell" >/dev/null 2>&1; then
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
    SEED_LLM_STUB=$stub SEED_VER_N=$w/n /bin/sh "$INSTALL/bin/agent" --oneshot 'pwd'
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
  need jq
  write_env_file "$LAUNCH_CWD/.env"
  write_env_file "$INSTALL/.env"
  ensure_gitignore "$LAUNCH_CWD"
  write_shims
  verify_install
  printf 'installed: %s/bin/agent\n' "$INSTALL" >&2
}

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

selftest() {
  t=$(CDPATH= cd "$(dirname "$SELF")" && pwd -P)/tests/seed-package.sh
  [ -f "$t" ] || die "offline suite missing: $t (run from repo root)" 69
  exec /bin/sh "$t"
}

case ${1:-} in
  --parse-turn) shift; parse_turn "$1"; exit 0 ;;
  --llm) shift; llm_main "$@"; exit 0 ;;
  --edit) shift; edit_main "$@"; exit 0 ;;
  --shell-init) shift; probe; shell_init "$1" "$2"; exit 0 ;;
  --shell) shift; shell_run "$1" "$2"; exit 0 ;;
  --shell-stop) shift; shell_stop "$1"; exit 0 ;;
  --shell-cli) shift; die 'shell CLI is internal to agent' 64 ;;
  --agent) shift; agent_main "$@"; exit 0 ;;
  --selftest) selftest; exit 0 ;;
  -h|--help) usage; exit 0 ;;
esac

INSTALL=.
case ${1:-} in
  '')
    load_env
    [ -n "${LLM_API_KEY:-}" ] || die "first run: sh seed.sh deepseek <API_KEY>" 64
    LLM_PROVIDER=${LLM_PROVIDER:-deepseek}
    LLM_API_URL=${LLM_API_URL:-https://api.deepseek.com/chat/completions}
    LLM_MODEL=${LLM_MODEL:-deepseek-v4-flash} ;;
  -*) usage; exit 64 ;;
  *)
    [ "$#" -eq 2 ] || { usage; exit 64; }
    resolve_provider "$1" "$2" ;;
esac
mkdir -p "$INSTALL"
INSTALL=$(CDPATH= cd "$INSTALL" && pwd -P)
install_main

