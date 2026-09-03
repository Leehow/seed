#!/bin/sh
# museed.sh -- ALM v0.1 kernel in POSIX shell (mu-Seed-Shell).
#
# Same kappa as kernels/museed.py, no jq, no awk, no sed: the ABI's canonical
# JSONL dialect (flat, unescaped, no commas inside event values) parses with
# parameter expansion alone. The kernel stays payload-blind, so there is
# nothing here that a JSON library would have been needed for.
#
#   stdin events / stdout effects / fd 3 (or $ALM_TRACE) canonical trace
set -u

RUN=${ALM_RUN:-r1}
STEPS_LEFT=${ALM_STEPS:-16}
REPAIRS_LEFT=${ALM_REPAIRS:-2}
RETRIES_LEFT=${ALM_RETRIES:-3}
HISTORY_MAX=${ALM_HISTORY_MAX:--1}
FEEDBACK=${ALM_FEEDBACK:-1}
ALLOW_HALT=${ALM_ALLOW_HALT:-1}

if [ -n "${ALM_TRACE:-}" ]; then exec 3>"$ALM_TRACE"; fi
if ! { : >&3; } 2>/dev/null; then exec 3>/dev/null; fi

HIST=''            # space separated refs, oldest first
PHASE=init
STEP=1
ATTEMPT=1
EIDN=0
PENDING=''
STEPS_USED=0

# fld LINE KEY -> sets $FLD. Event values never contain , { } " (ABI s1).
#
# It assigns rather than printing on purpose: `x=$(fld ...)` forks a subshell
# per field, which costs about eight forks per event and drops this kernel's
# throughput by three orders of magnitude. Parameter expansion alone means the
# shell kernel never forks after start-up.
fld() {
    FLD=''
    case "$1" in
        *"\"$2\":"*) : ;;
        *) return 0 ;;
    esac
    v=${1#*\"$2\":}
    v=${v%%,*}
    v=${v%\}}
    v=${v#\"}
    v=${v%\"}
    FLD=$v
}

hist_add() { # keep H bounded when the budget bounds what the model can see
    HIST="${HIST:+$HIST }$1"
    if [ "$HISTORY_MAX" -ge 0 ]; then
        # shellcheck disable=SC2086
        set -- $HIST
        if [ $# -gt "$HISTORY_MAX" ]; then
            shift $(($# - HISTORY_MAX))
            HIST=$*
        fi
    fi
}

refs_of() {           # -> sets $REFS
    # shellcheck disable=SC2086
    set -- $HIST
    if [ "$HISTORY_MAX" -eq 0 ]; then set --
    elif [ "$HISTORY_MAX" -gt 0 ] && [ $# -gt "$HISTORY_MAX" ]; then
        shift $(($# - HISTORY_MAX))
    fi
    if [ $# -eq 0 ]; then REFS='-'; return; fi
    out=$1; shift
    for r in "$@"; do out="$out,$r"; done
    REFS=$out
}

rec() { # rec STEP PHASE_IN EVENT STATUS ACTION REFS FLAG
    printf '%s|%s|%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
        "$1" "$2" "$3" "$4" "$5" "$PHASE" \
        "$STEPS_LEFT" "$REPAIRS_LEFT" "$RETRIES_LEFT" "$6" "$7" >&3
}

next_eid() { EIDN=$((EIDN + 1)); PENDING="e$EIDN"; }

send_model_request() {
    refs_of
    next_eid
    printf '{"v":1,"t":"model_request","run":"%s","step":%s,"eid":"%s","attempt":%s,"refs":"%s","steps_left":%s}\n' \
        "$RUN" "$STEP" "$PENDING" "$ATTEMPT" "$REFS" "$STEPS_LEFT"
}

send_tool_request() { # tool arg_ref
    REFS=$2
    next_eid
    printf '{"v":1,"t":"tool_request","run":"%s","step":%s,"eid":"%s","tool":"%s","arg_ref":"%s"}\n' \
        "$RUN" "$STEP" "$PENDING" "$1" "$2"
}

send_final() { # outcome reason status
    PHASE=terminal
    PENDING=''
    printf '{"v":1,"t":"final","run":"%s","step":%s,"outcome":"%s","status":"%s","reason":"%s","steps_used":%s}\n' \
        "$RUN" "$STEP" "$1" "$3" "$2" "$STEPS_USED"
}

# ---- start (ALM s4.1) -------------------------------------------------
PHASE=await_model
send_model_request
rec "$STEP" init start - - "$REFS" -

while IFS= read -r line; do
    [ -n "$line" ] || continue
    case $line in '{'*) : ;; *) continue ;; esac

    fld "$line" t;      T=$FLD
    fld "$line" eid;    EID=$FLD
    fld "$line" status; STATUS=$FLD
    [ -n "$STATUS" ] || STATUS=-
    PHASE_IN=$PHASE
    STEP_IN=$STEP

    if [ "$PHASE" = terminal ]; then
        rec "$STEP_IN" "$PHASE_IN" "$T" "$STATUS" - - after_terminal
        continue
    fi

    # An unrecognised t or status is ignored, never repaired (ALM s4.6).
    stale=0
    [ "$EID" = "$PENDING" ] || stale=1
    case $T in
        model_response)
            [ "$PHASE" = await_model ] || stale=1
            case $STATUS in
                invalid|transport_error) : ;;
                ok) fld "$line" action
                    case $FLD in tool|halt) : ;; *) stale=1 ;; esac ;;
                *) stale=1 ;;
            esac ;;
        tool_response)
            [ "$PHASE" = await_tool ] || stale=1
            case $STATUS in ok|error|timeout) : ;; *) stale=1 ;; esac ;;
        *) stale=1 ;;
    esac
    if [ "$stale" -eq 1 ]; then
        rec "$STEP_IN" "$PHASE_IN" "$T" "$STATUS" - - stale_event
        continue
    fi

    if [ "$T" = model_response ]; then
        fld "$line" action;  ACTION=$FLD
        fld "$line" arg_ref; ARG=$FLD
        [ -n "$ARG" ] || ARG=r0

        if [ "$STATUS" = ok ] && [ "$ACTION" = tool ]; then
            hist_add "$ARG"
            PHASE=await_tool
            fld "$line" tool
            send_tool_request "$FLD" "$ARG"
            rec "$STEP_IN" "$PHASE_IN" model_response ok tool "$REFS" -
            continue
        fi

        if [ "$STATUS" = ok ] && [ "$ACTION" = halt ]; then
            if [ "$ALLOW_HALT" -eq 1 ]; then
                hist_add "$ARG"
                fld "$line" halt; H=$FLD; [ -n "$H" ] || H=ok
                send_final halted model_halt "$H"
                rec "$STEP_IN" "$PHASE_IN" model_response ok halt - -
                continue
            fi
            hist_add "$ARG"
            ATTEMPT=$((ATTEMPT + 1))
            send_model_request
            rec "$STEP_IN" "$PHASE_IN" model_response invalid halt "$REFS" -
            continue
        fi

        if [ "$STATUS" = transport_error ]; then
            if [ "$RETRIES_LEFT" -gt 0 ]; then
                RETRIES_LEFT=$((RETRIES_LEFT - 1))
                ATTEMPT=$((ATTEMPT + 1))
                send_model_request
                rec "$STEP_IN" "$PHASE_IN" model_response transport_error - "$REFS" -
            else
                send_final aborted transport_exhausted -
                rec "$STEP_IN" "$PHASE_IN" model_response transport_error - - -
            fi
            continue
        fi

        # invalid: protocol repair
        if [ "$REPAIRS_LEFT" -gt 0 ]; then
            REPAIRS_LEFT=$((REPAIRS_LEFT - 1))
            hist_add "$ARG"
            ATTEMPT=$((ATTEMPT + 1))
            send_model_request
            rec "$STEP_IN" "$PHASE_IN" model_response invalid - "$REFS" -
        else
            send_final aborted protocol_exhausted -
            rec "$STEP_IN" "$PHASE_IN" model_response invalid - - -
        fi
        continue
    fi

    # tool_response
    if [ "$FEEDBACK" -eq 1 ]; then
        fld "$line" obs_ref; O=$FLD; [ -n "$O" ] || O=o0
        hist_add "$O"
    fi
    STEPS_LEFT=$((STEPS_LEFT - 1))
    STEPS_USED=$((STEPS_USED + 1))
    if [ "$STEPS_LEFT" -le 0 ]; then
        send_final aborted budget_exhausted -
        rec "$STEP_IN" "$PHASE_IN" tool_response "$STATUS" - - -
        continue
    fi
    PHASE=await_model
    STEP=$((STEP + 1))
    ATTEMPT=1
    send_model_request
    rec "$STEP_IN" "$PHASE_IN" tool_response "$STATUS" - "$REFS" -
done

[ "$PHASE" = terminal ] || exit 3
exit 0
