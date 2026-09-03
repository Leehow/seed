#!/bin/sh
# run_h3_arm.sh -- the model factor, per PREREGISTRATION-v2.md s7.
#
# grok-4.5-high on the sh kernel, 89 tasks, one repeat. Everything except the
# reasoning effort is identical to the grok-4.5-low arm, so the difference
# between the two is the model factor and nothing else.
set -eu
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd -P)

while pgrep -f "harbor run" >/dev/null 2>&1; do sleep 60; done
echo "=== H3 arm: grok-4.5-high, sh only $(date -u +%FT%TZ)"
# six concurrent tasks, the same host load the three-kernel arms ran under
# (3 kernels x 2 each). Matching the load matters: CPU contention is what
# turns a slow step into an AgentTimeoutError.
TB_PROMPT=br TB_MODEL=grok-high TB_TAG=high TB_KERNELS=sh TB_NCONC=6 \
  TB_MODEL_LABEL=xai/grok-4.5-high TB_REPS=0 sh "$HERE/run_tb_full.sh"
echo "=== H3 arm done $(date -u +%FT%TZ)"
