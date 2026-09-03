#!/bin/sh
# run_tb_stage.sh -- one stage of the pre-registered Terminal-Bench matrix.
#
#   sh alm/bench/run_tb_stage.sh subset 0     # 30-task subset, repeat 0
#   sh alm/bench/run_tb_stage.sh all 0        # all 89 tasks, repeat 0
#
# The three container-capable kernels run as three concurrent Harbor jobs, so
# every substrate is exposed to the same slice of wall clock and the same
# endpoint conditions. That is stronger interleaving than the per-task blocks
# in PREREGISTRATION.md, not weaker: a model that drifts hits all three at once.
# (asm is absent until the ELF port lands; it is Mach-O.)
set -eu
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
ALM=$(CDPATH= cd "$HERE/.." && pwd -P)
ROOT=$(CDPATH= cd "$ALM/.." && pwd -P)
SCOPE=${1:-subset}
REP=${2:-0}
KERNELS=${TB_KERNELS:-py,sh,sql}
NCONC=${TB_NCONC:-2}
TASKS_DIR=$ROOT/bench/harbor/tb21/tasks

[ -f "$ROOT/.env" ] || { echo "missing .env" >&2; exit 64; }
docker info >/dev/null 2>&1 || { echo "docker is not running" >&2; exit 69; }
command -v harbor >/dev/null 2>&1 || { echo "harbor not on PATH" >&2; exit 69; }

if [ "$SCOPE" = subset ]; then
  LIST=$(python3 -c 'import json,sys;print(" ".join(json.load(open(sys.argv[1]))["tasks"]))' "$HERE/subset-30.json")
else
  LIST=$(python3 -c 'import json,sys;print(" ".join(t["dir"] for t in json.load(open(sys.argv[1]))["tasks"]))' "$HERE/dataset-manifest.json")
fi

INC=""
for t in $LIST; do INC="$INC -i $t"; done

# Protocol `a` is the adapter's default and is what repeats 0-2 ran, with no
# prompt kwarg on the command line. Keep it that way: adding the flag changes
# the recorded job config, and Harbor then refuses to resume a job that was
# started without it. Same experiment, different spelling, hours of finished
# trials thrown away.
if [ "${TB_PROMPT:-a}" = a ]; then
  PROMPT_FLAG=""
else
  PROMPT_FLAG="--ak prompt=${TB_PROMPT}"
fi

set -a
. "$ROOT/.env"
set +a
export PYTHONPATH="$HERE${PYTHONPATH:+:$PYTHONPATH}"

for kid in $(echo "$KERNELS" | tr ',' ' '); do
  # prompt a keeps the original job names so the existing arm stays resumable
  if [ "${TB_PROMPT:-a}" = a ]; then
    NAME="tb-$SCOPE-rep$REP-$kid"
  else
    NAME="tb${TB_PROMPT}-$SCOPE-rep$REP-$kid${TB_TAG:+-$TB_TAG}"
  fi
  # No rm here on purpose. Harbor resumes a job directory when the config is
  # identical: finished trials are kept, and any trial without a result.json
  # (the ones that were in flight when it stopped) is discarded and re-run.
  # Deleting the directory would throw away hours of finished work every time
  # the laptop moves. TB_FRESH=1 forces a clean start.
  if [ "${TB_FRESH:-0}" = 1 ]; then rm -rf "$HERE/jobs/$NAME"; fi
  # shellcheck disable=SC2086
  harbor run -p "$TASKS_DIR" $INC \
    -a harbor_museed:MuSeedAgent --ak "kernel=$kid" --ak steps=80 \
    --ak "model=${TB_MODEL:-grok-low}" $PROMPT_FLAG \
    -m "${TB_MODEL_LABEL:-xai/grok-4.5-low}" \
    -k 1 -n "$NCONC" -o "$HERE/jobs" --job-name "$NAME" \
    > "$HERE/jobs/$NAME.log" 2>&1 &
  eval "PID_$kid=$!"
  echo "started $NAME (pid $!)"
done

# wait on each job individually and fail loudly. A job that dies in its first
# second -- a resume refused because the config changed, a missing image, a bad
# flag -- must not let a multi-hour queue march quietly on to the next stage.
rc=0
for kid in $(echo "$KERNELS" | tr ',' ' '); do
  eval "pid=\$PID_$kid"
  if ! wait "$pid"; then
    echo "FAILED: $SCOPE rep$REP kernel=$kid (see jobs/*-$kid.log)" >&2
    rc=1
  fi
done
[ "$rc" -eq 0 ] || exit "$rc"
echo "stage done: $SCOPE rep$REP"
