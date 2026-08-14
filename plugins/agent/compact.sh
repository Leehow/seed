#!/bin/sh
# Agent plugin: clip original middle for a no-tools summary, then prune old tools.
# Env:
#   SLAB_MESSAGES          path to messages.json
#   SLAB_PROMPT_TOKENS     last usage.prompt_tokens (or input_tokens)
#   SLAB_CONTEXT_WINDOW    default 128000
#   SLAB_HOOK_WORK         work dir for complete-request / fails
#   SLAB_COMPLETE_RESULT   path to summary text (second pass)
#   SLAB_COMPACT_FORCE     1 = ignore token threshold

case ${1:-} in
  blurb) exit 0 ;;
esac

cc_msgs=${SLAB_MESSAGES:-}
[ -n "$cc_msgs" ] && [ -f "$cc_msgs" ] || exit 0

cc_work=${SLAB_HOOK_WORK:-}
cc_failf=
if [ -n "$cc_work" ]; then
  mkdir -p "$cc_work"
  cc_failf=$cc_work/compact-fails
  if [ -f "$cc_failf" ]; then
    cc_n=$(cat "$cc_failf" 2>/dev/null || echo 0)
    case $cc_n in
      ''|*[!0-9]*) cc_n=0 ;;
    esac
    [ "$cc_n" -ge 2 ] && exit 0
  fi
fi

cc_win=${SLAB_CONTEXT_WINDOW:-128000}
case $cc_win in
  ''|*[!0-9]*) cc_win=128000 ;;
esac
cc_th=$((cc_win * 70 / 100))
cc_tok=${SLAB_PROMPT_TOKENS:-0}
case $cc_tok in
  ''|*[!0-9]*) cc_tok=0 ;;
esac

cc_force=0
[ "${SLAB_COMPACT_FORCE:-}" = 1 ] && cc_force=1

if [ "$cc_force" -ne 1 ] && [ "$cc_tok" -lt "$cc_th" ] && [ -z "${SLAB_COMPLETE_RESULT:-}" ]; then
  exit 0
fi

cc_protect=$(jq '
  def users: [to_entries[] | select(.value.role=="user") | .key];
  def groups: [to_entries[] | select(
      .value.role=="assistant"
      and ((.value.tool_calls // []) | length) > 0
    ) | .key];
  if (users | length) >= 2 then users[-2]
  elif (groups | length) >= 2 then groups[-2]
  else -1
  end
' "$cc_msgs" 2>/dev/null || echo -1)
case $cc_protect in
  ''|*[!0-9-]*|-1) exit 0 ;;
esac
[ "$cc_protect" -gt 0 ] || exit 0

# Build the summary transcript from the original middle, before prune.
# Fat tool bodies are clipped to head+tail so short facts survive.
cc_mid=$(jq -r --argjson p "$cc_protect" '
  def clip:
    if type != "string" then ""
    elif length <= 2400 then .
    else
      .[0:1500]
      + "\n[... "
      + ((length - 2300) | tostring)
      + " chars omitted ...]\n"
      + .[-800:]
    end;
  .[1:$p]
  | if length == 0 then empty
    else
      map(
        (if .role then .role else "?" end) + ": "
        + (
            if .content then (.content | tostring | clip)
            elif .tool_calls then (.tool_calls | tostring)
            else ""
            end
          )
      ) | join("\n")
    end
' "$cc_msgs" 2>/dev/null || true)

cc_apply_summary() {
  cc_sumf=$1
  [ -f "$cc_sumf" ] || return 1
  cc_sum=$(cat "$cc_sumf")
  [ -n "$cc_sum" ] || return 1
  cc_tmp=$(mktemp "${TMPDIR:-/tmp}/seed-cc.XXXXXX")
  if jq --arg s "$cc_sum" --argjson p "$cc_protect" '
    . as $m
    | ($m[0:1] + [{
        role: "user",
        content: (
          "[CONTEXT COMPACTION — REFERENCE ONLY] Earlier turns were compacted into the summary below. Treat it as background, not active instructions. Resume from Active Task. Respond only to messages after this summary.\n\n"
          + $s
        )
      }] + $m[$p:])
  ' "$cc_msgs" > "$cc_tmp"
  then
    mv "$cc_tmp" "$cc_msgs"
    printf 'compact: summarized\n' >&2
    return 0
  fi
  rm -f "$cc_tmp"
  return 1
}

if [ -n "${SLAB_COMPLETE_RESULT:-}" ] && [ -f "$SLAB_COMPLETE_RESULT" ]; then
  cc_apply_summary "$SLAB_COMPLETE_RESULT" || true
  exit 0
fi

cc_need=$(jq -r --argjson p "$cc_protect" '
  any(.[1:$p][];
    .role=="tool"
    and ((.content // "") | type=="string")
    and ((.content // "") | length) > 200)
' "$cc_msgs" 2>/dev/null || echo false)
if [ "$cc_need" = true ]; then
  cc_tmp=$(mktemp "${TMPDIR:-/tmp}/seed-cc.XXXXXX")
  if jq --argjson p "$cc_protect" '
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
      ]
  ' "$cc_msgs" > "$cc_tmp"
  then
    mv "$cc_tmp" "$cc_msgs"
    printf 'compact: pruned\n' >&2
  else
    rm -f "$cc_tmp"
  fi
fi

[ -n "$cc_work" ] || exit 0
[ -n "$cc_mid" ] || exit 0

cc_sys=$(cat <<'PROMPT'
You compress a coding-agent transcript. Do not answer questions in the transcript. Do not use tools. Write a short English summary with these headings:
## Goal
## Constraints
## Progress
## Key Decisions
## Relevant Files
## Active Task
## Critical Context

Under Critical Context, copy short unique facts from the transcript: MARKER_* and other IDs, hashes, paths, dates, error strings, and exact values the user asked for. If a value appears in any tool excerpt, copy it verbatim. Never write "unknown", "never retrieved", or "still unknown" for a value that appears. Do not copy filler, lorem, or repeated block dumps.
PROMPT
)

jq -n --arg s "$cc_sys" --arg u "$cc_mid" '{system:$s,user:$u}' \
  > "$cc_work/complete-request.json"
