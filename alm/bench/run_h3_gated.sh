#!/bin/sh
# run_h3_gated.sh -- pilot, health gate, then the paid arm. Unattended.
set -eu
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
ROOT=$(CDPATH= cd "$HERE/../.." && pwd -P)
cd "$ROOT"

while pgrep -f "harbor run" >/dev/null 2>&1; do sleep 60; done
echo "=== pilot finished $(date -u +%FT%TZ)"

if ! python3 "$HERE/gate_h3.py" "$HERE/jobs/pilot-qwen"; then
  echo "=== GATE REFUSED: the full arm was NOT launched. Left for a human."
  exit 1
fi

echo "=== H3 arm: qwen3.8-max, sh kernel, 89 tasks $(date -u +%FT%TZ)"
TB_PROMPT=br TB_MODEL=qwen-max TB_TAG=qwen TB_KERNELS=sh TB_NCONC=3 \
  TB_MODEL_LABEL=alibaba/qwen3.8-max TB_REPS=0 sh "$HERE/run_tb_full.sh"
echo "=== H3 arm done $(date -u +%FT%TZ)"
