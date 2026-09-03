#!/bin/sh
# run_tb_full.sh -- the whole pre-registered Terminal-Bench arm, three repeats.
#
#   sh alm/bench/run_tb_full.sh
#
# Waits for any Harbor job already running, then does all 89 tasks once per
# repeat in $TB_REPS (default 0 1 2). Concurrency is deliberately modest: the failure mode this benchmark
# measures is the agent running out of wall clock, so over-subscribing a
# 10-core machine would manufacture exactly the result we are trying to
# observe. Three kernels x TB_NCONC tasks each is the ceiling.
set -eu
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
export TB_NCONC=${TB_NCONC:-2}

while pgrep -f "harbor run" >/dev/null 2>&1; do sleep 60; done

for rep in ${TB_REPS:-0 1 2}; do
  echo "=== all 89 tasks, repeat $rep, $(date -u +%FT%TZ)"
  sh "$HERE/run_tb_stage.sh" all "$rep"
done
echo "=== full matrix done $(date -u +%FT%TZ)"
