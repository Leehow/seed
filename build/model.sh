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
  while IFS= read -r line || [ -n "$line" ]; do
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
    "$SEED_LLM_STUB" --messages "$work/msgs.json" > "$dest"
    rm -rf "$work"
    return 0
  fi
  load_env
  disable_thinking
  [ -n "${LLM_API_KEY:-}" ] || die 'missing API key (.env or environment)' 64
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
  set +e
  if [ "$stream" = true ]; then
    curl -q -N -sS --connect-timeout 15 --max-time "$HTTP_TIMEOUT" -X POST \
      -H "@$work/h" --data-binary "@$work/req.json" \
      -w '\n__HTTP__%{http_code}\n' "$LLM_API_URL" \
      | tee "$work/raw" | stream_print
    cs=0
    [ -s "$work/raw" ] || cs=1
  else
    curl -q -sS --connect-timeout 15 --max-time "$HTTP_TIMEOUT" -X POST \
      -H "@$work/h" --data-binary "@$work/req.json" \
      -w '\n__HTTP__%{http_code}\n' "$LLM_API_URL" > "$work/raw"
    cs=$?
  fi
  set -e
  [ "$cs" -eq 0 ] || { rm -rf "$work"; die "llm: network failed (curl=$cs)" 71; }
  code=$(awk '/^__HTTP__/{print substr($0,9)}' "$work/raw" | tail -1)
  case $code in
    2*) : ;;
    401|403) rm -rf "$work"; die "llm: API key rejected (HTTP $code)" 77 ;;
    400|413)
      if llm_context_overflow "$work/raw"; then
        rm -rf "$work"
        return 73
      fi
      rm -rf "$work"
      die "llm: HTTP $code" 72
      ;;
    *) rm -rf "$work"; die "llm: HTTP ${code:-000}" 72 ;;
  esac
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
