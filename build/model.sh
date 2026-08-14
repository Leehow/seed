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
