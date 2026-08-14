agent_after_turn() { :; }

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
  agent_after_turn "$msgs" "$last_pt" "$evdir" || true
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
      SLAB_COMPACT_FORCE=1
      export SLAB_COMPACT_FORCE
      agent_after_turn "$msgs" "$last_pt" "$evdir" || true
      unset SLAB_COMPACT_FORCE
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
    agent_after_turn "$msgs" "$last_pt" "$evdir" || true
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
