#!/bin/sh
# run_tb_queue.sh -- the two remaining Terminal-Bench arms, back to back.
#
#   nohup sh alm/bench/run_tb_queue.sh &
#
# Serial on purpose: each arm already runs three concurrent Harbor jobs, and
# doubling that on a ten-core host would starve the tasks of CPU and
# manufacture the timeouts this benchmark is supposed to measure.
#
#   1. protocol a, repeats 3 and 4 -- finishing the amendment in
#      PREREGISTRATION.md s7, which promised exactly two more repeats.
#   2. protocol b, repeats 1 and 2 -- giving the mu-side comparison the same
#      three repeats the pre-registered arm has.
set -eu
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd -P)

echo "=== arm 1: protocol a, repeats 3 4  $(date -u +%FT%TZ)"
TB_PROMPT=a TB_REPS="3 4" sh "$HERE/run_tb_full.sh"

echo "=== arm 2: protocol b, repeats 1 2  $(date -u +%FT%TZ)"
TB_PROMPT=b TB_REPS="1 2" sh "$HERE/run_tb_full.sh"

echo "=== queue done $(date -u +%FT%TZ)"
