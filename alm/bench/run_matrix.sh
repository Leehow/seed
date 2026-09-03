#!/bin/sh
# run_matrix.sh -- the pre-registered Terminal-Bench matrix (NOT YET RUN).
#
# Reads PREREGISTRATION.md and does exactly what it says: every substrate on
# every task, interleaved per task block so that a hosted model drifting under
# a fixed name hits all arms equally.
#
#   sh alm/bench/run_matrix.sh --model primary --repeats 3
#   sh alm/bench/run_matrix.sh --model second  --repeats 3 --subset
#
# Requires: harbor on PATH, a running docker daemon, .env with LLM_* set.
set -eu

HERE=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
ALM=$(CDPATH= cd "$HERE/.." && pwd -P)
ROOT=$(CDPATH= cd "$ALM/.." && pwd -P)
REPEATS=3
SUBSET=0
# asm is Mach-O/arm64 and needs an ELF port before it can run in a
# Linux task container; see harbor_museed.py.
KERNELS=${ALM_KERNELS:-py,sh,sql}
STEPS=${ALM_STEPS:-80}
DATASET=${HARBOR_DATASET:-terminal-bench/terminal-bench-2-1}

while [ $# -gt 0 ]; do
  case $1 in
    --repeats) REPEATS=$2; shift 2 ;;
    --subset)  SUBSET=1; shift ;;
    --kernels) KERNELS=$2; shift 2 ;;
    *) printf 'unknown argument: %s\n' "$1" >&2; exit 64 ;;
  esac
done

command -v harbor >/dev/null 2>&1 || { echo "harbor not on PATH" >&2; exit 69; }
docker info >/dev/null 2>&1 || { echo "docker is not running" >&2; exit 69; }
[ -f "$ROOT/.env" ] || { echo "missing .env" >&2; exit 64; }

if [ "$SUBSET" -eq 1 ]; then
  TASKS=$(python3 -c 'import json,sys;print(" ".join(json.load(open(sys.argv[1]))["tasks"]))' \
          "$HERE/subset-30.json")
else
  TASKS=$(python3 -c 'import json,sys;print(" ".join(t["dir"] for t in json.load(open(sys.argv[1]))["tasks"]))' \
          "$HERE/dataset-manifest.json")
fi

STAMP=$(date -u +%Y%m%dT%H%M%SZ)
OUT=$HERE/jobs/$STAMP
mkdir -p "$OUT"
git -C "$ROOT" rev-parse HEAD > "$OUT/kernel-commit.txt"
cp "$HERE/PREREGISTRATION.md" "$OUT/"

rep=0
while [ "$rep" -lt "$REPEATS" ]; do
  for task in $TASKS; do
    # interleave substrates inside the task block, never substrate by substrate
    for kid in $(echo "$KERNELS" | tr ',' ' '); do
      echo "[rep $rep] $task on $kid"
      ALM_STEPS=$STEPS \
      harbor run \
        --dataset "$DATASET" \
        --task "$task" \
        --agent-import-path "$ALM/bench/harbor_museed.py:MuSeedAgent" \
        --agent-kwarg "kernel=$kid" \
        --n-attempts 1 \
        --output-path "$OUT/rep$rep/$task/$kid" \
        || echo "FAILED $task $kid rep$rep" >> "$OUT/failures.txt"
    done
  done
  rep=$((rep + 1))
done

echo "jobs in $OUT"
echo "analyse with: python3 $ALM/stats/equivalence.py --in <collected.jsonl> \\"
echo "  --group kernel --unit task --delta 0.05"
