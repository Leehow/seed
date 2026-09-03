#!/bin/sh
# run_grok_arm.sh -- arm 2 in full, per PREREGISTRATION-v2.md.
#
# Everything the retired model measured, measured again on grok-4.5-low, in
# order of increasing cost so the short experiments report back first:
#
#   1. live witness ablations   (H4: what the core is for)
#   2. witness cross-substrate  (H2 on a live stochastic suite)
#   3. Terminal-Bench, 3 repeats x 89 tasks x 3 substrates
#
# Serial throughout: the relay is one process, and two experiments pointed at
# it at once is how the earlier 502s appeared.
set -eu
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
ALM=$(CDPATH= cd "$HERE/.." && pwd -P)
W="python3 $ALM/witness/run.py"
C=${GROK_CONCURRENCY:-6}

while pgrep -f "run_local.py" >/dev/null 2>&1; do sleep 60; done
echo "=== local suite finished $(date -u +%FT%TZ)"

echo "=== witness ablations, grok-low $(date -u +%FT%TZ)"
$W --policy live --model grok-low --kernels py --arms all --per-family 50 \
   --concurrency "$C"

echo "=== witness cross-substrate, grok-low $(date -u +%FT%TZ)"
$W --policy live --model grok-low --kernels py,sh,sql,asm --arms full \
   --per-family 50 --repeats 3 --concurrency "$C" \
   --out "$ALM/witness/results-live-substrate-grok.jsonl"

echo "=== Terminal-Bench arm $(date -u +%FT%TZ)"
TB_PROMPT=br TB_MODEL=grok-low TB_REPS="0 1 2" sh "$HERE/run_tb_full.sh"
echo "=== grok arm done $(date -u +%FT%TZ)"
