#!/bin/sh
# Wait for the in-flight seed TB 2.1 job, then run same-model baselines
# one at a time (n=1). No secrets in this file.
set -eu

HERE=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
ROOT=$(CDPATH= cd "$HERE/../.." && pwd -P)
ENVFILE=${1:-$HOME/.config/jellytoken/harbor.env}
LOG=$HERE/jobs/compare-chain.log
SEED_SH=${SEED_WAIT_SH:-2705467}
SEED_HARBOR=${SEED_WAIT_HARBOR:-2706592}

mkdir -p "$HERE/jobs"
export PATH=$HOME/.local/bin:$PATH

log() {
  printf '%s %s\n' "$(date -Iseconds)" "$*" >> "$LOG"
}

still() {
  kill -0 "$1" 2>/dev/null
}

log "waiting for seed pids $SEED_SH $SEED_HARBOR"
while still "$SEED_SH" || still "$SEED_HARBOR"; do
  sleep 60
done
log "seed processes gone; settle 30s"
sleep 30

cd "$ROOT"
log "start mini-swe-agent n=1"
if HARBOR_N=1 /bin/sh "$HERE/run.sh" --env "$ENVFILE" --agent mini-swe-agent --all; then
  log "mini-swe-agent finished ok"
else
  log "mini-swe-agent finished rc=$?"
fi

log "start terminus-2 n=1"
if HARBOR_N=1 /bin/sh "$HERE/run.sh" --env "$ENVFILE" --agent terminus-2 --all; then
  log "terminus-2 finished ok"
else
  log "terminus-2 finished rc=$?"
fi
