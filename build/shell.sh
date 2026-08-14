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
