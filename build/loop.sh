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
