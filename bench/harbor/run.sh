#!/bin/sh
# Official Terminal-Bench 2.1 via Harbor.
# Default agent is seed. Same-model baselines:
#   --agent mini-swe-agent   Harbor installed agent (closest peer)
#   --agent terminus-2       Harbor's own reference agent (not installed)
# Usage:
#   sh bench/harbor/run.sh [--env FILE] [--agent seed|mini-swe-agent|terminus-2] \
#     smoke-oracle|smoke|--all|task NAME|prefetch [NAME]
set -eu

HERE=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
ROOT=$(CDPATH= cd "$HERE/../.." && pwd -P)
ENVFILE=$ROOT/.env
AGENT=seed
DATASET=${HARBOR_DATASET:-terminal-bench/terminal-bench-2-1}
LOCAL_TASKS=${HARBOR_TASKS:-$HERE/tb21/tasks}
JOBS=$HERE/jobs
N=${HARBOR_N:-2}
K=${HARBOR_K:-1}
ROUNDS=${AGENT_MAX_ROUNDS:-80}

usage() {
  printf 'usage: sh bench/harbor/run.sh [--env FILE] [--agent seed|mini-swe-agent|terminus-2] smoke-oracle|smoke|--all|task NAME|prefetch [NAME]\n' >&2
}

while [ $# -gt 0 ]; do
  case $1 in
    --env)
      ENVFILE=$2
      shift 2
      ;;
    --agent)
      AGENT=$2
      shift 2
      ;;
    *)
      break
      ;;
  esac
done

[ -f "$ROOT/seed.sh" ] || { printf 'error: missing seed.sh\n' >&2; exit 69; }
[ -f "$ENVFILE" ] || { printf 'error: missing env file (pass --env)\n' >&2; exit 64; }
command -v harbor >/dev/null 2>&1 || {
  printf 'error: harbor not on PATH (uv tool install harbor)\n' >&2
  exit 69
}
docker info >/dev/null 2>&1 || {
  printf 'error: docker daemon is not running\n' >&2
  exit 69
}

# Source on the host so LLM_EXTRA JSON quotes are stripped. Never print values.
set -a
# shellcheck disable=SC1090
. "$ENVFILE"
set +a
[ -n "${LLM_API_KEY:-}" ] || { printf 'error: LLM_API_KEY empty\n' >&2; exit 64; }

MODEL_LABEL=${HARBOR_MODEL:-${LLM_PROVIDER:-custom}/${LLM_MODEL:-seed}}
export PYTHONPATH=$HERE${PYTHONPATH:+:$PYTHONPATH}
export AGENT_MAX_ROUNDS=$ROUNDS
export SEED_ENV_FILE=$ENVFILE
mkdir -p "$JOBS"

# A failed prebuilt-image pull mid-run kills the whole trial, so pull
# everything up front with retries. Non-fatal: harbor can still build.
# $1 (optional) limits the prefetch to one task name.
prefetch_images() {
  [ -d "$LOCAL_TASKS" ] || return 0
  for tt in "$LOCAL_TASKS"/*/task.toml; do
    [ -f "$tt" ] || continue
    if [ -n "${1:-}" ]; then
      [ "$(basename "$(dirname "$tt")")" = "$1" ] || continue
    fi
    img=$(sed -n 's/^docker_image *= *"\(.*\)".*/\1/p' "$tt")
    [ -n "$img" ] || continue
    docker image inspect "$img" >/dev/null 2>&1 && continue
    n=1
    while :; do
      printf 'prefetch: %s (try %s)\n' "$img" "$n" >&2
      docker pull "$img" >/dev/null 2>&1 && break
      n=$((n + 1))
      if [ "$n" -gt 3 ]; then
        printf 'warn: could not pull %s after 3 tries\n' "$img" >&2
        break
      fi
      sleep 5
    done
  done
}

# Local clone uses bare names (fix-git). Harbor Hub uses org/task.
task_name() {
  case $1 in
    */*) printf '%s\n' "$1" ;;
    *)
      if [ -d "$LOCAL_TASKS" ] && [ -f "$LOCAL_TASKS/dataset.toml" ]; then
        printf '%s\n' "$1"
      else
        printf 'terminal-bench/%s\n' "$1"
      fi
      ;;
  esac
}

harbor_common() {
  if [ -d "$LOCAL_TASKS" ] && [ -f "$LOCAL_TASKS/dataset.toml" ]; then
    set -- -p "$LOCAL_TASKS" "$@"
  else
    set -- -d "$DATASET" "$@"
  fi
  # Linux Docker: inject host Clash via host.docker.internal. Off with
  # HARBOR_HOST_PROXY=0 (macOS Docker Desktop already proxies containers).
  if [ "${HARBOR_HOST_PROXY:-1}" != 0 ] && [ -f "$HERE/compose-host-proxy.yaml" ]; then
    set -- --extra-docker-compose "$HERE/compose-host-proxy.yaml" "$@"
  fi
  harbor run \
    "$@" \
    -k "$K" \
    -n "$N" \
    -o "$JOBS"
}

harbor_seed() {
  harbor_common \
    --agent seed_agent:SeedAgent \
    -m "$MODEL_LABEL" \
    --ae "SEED_ENV_FILE=${ENVFILE}" \
    --ae "AGENT_MAX_ROUNDS=${ROUNDS}" \
    --ae "SEED_PLUGIN_ROOT=${SEED_PLUGIN_ROOT:-https://pipi.aichattrpg.com/downloads/slab}" \
    "$@"
}

# seed.sh posts to the full chat-completions path. LiteLLM / mini-swe /
# terminus want the OpenAI-compatible /v1 root.
openai_base_url() {
  printf '%s\n' "$LLM_API_URL" | sed 's|/chat/completions/*$||; s|/completions/*$||'
}

# Never print these. Write a 0600 env file and let Harbor load it so
# keys are not visible on `ps` via --ae.
export_openai_compat() {
  [ -n "${LLM_API_URL:-}" ] || { printf 'error: LLM_API_URL empty\n' >&2; exit 64; }
  [ -n "${LLM_MODEL:-}" ] || { printf 'error: LLM_MODEL empty\n' >&2; exit 64; }
  OPENAI_BASE=$(openai_base_url)
  COMPARE_MODEL="openai/${LLM_MODEL}"
  OPENAI_ENVFILE=${HARBOR_OPENAI_ENV:-$HOME/.config/jellytoken/openai-compat.env}
  mkdir -p "$(dirname "$OPENAI_ENVFILE")"
  umask 077
  {
    printf 'OPENAI_API_KEY=%s\n' "$LLM_API_KEY"
    printf 'OPENAI_BASE_URL=%s\n' "$OPENAI_BASE"
    printf 'OPENAI_API_BASE=%s\n' "$OPENAI_BASE"
    printf 'MSWEA_API_KEY=%s\n' "$LLM_API_KEY"
  } > "$OPENAI_ENVFILE"
  chmod 600 "$OPENAI_ENVFILE"
  set -a
  # shellcheck disable=SC1090
  . "$OPENAI_ENVFILE"
  set +a
}

harbor_mini() {
  # Cheap OpenAI-compatible endpoints (e.g. jellytoken flash) collapse
  # under concurrent trials. Override the script default of 2.
  N=${HARBOR_N:-1}
  export_openai_compat
  harbor_common \
    --agent mini-swe-agent \
    -m "$COMPARE_MODEL" \
    --env-file "$OPENAI_ENVFILE" \
    --agent-setup-timeout-multiplier "${HARBOR_SETUP_MULT:-2}" \
    "$@"
}

harbor_terminus() {
  N=${HARBOR_N:-1}
  export_openai_compat
  harbor_common \
    --agent terminus-2 \
    -m "$COMPARE_MODEL" \
    --env-file "$OPENAI_ENVFILE" \
    --ak "api_base=${OPENAI_BASE}" \
    --ak "max_turns=${ROUNDS}" \
    "$@"
}

run_selected() {
  case $AGENT in
    seed|seed_agent:SeedAgent)
      harbor_seed "$@"
      ;;
    mini-swe-agent|mini)
      harbor_mini "$@"
      ;;
    terminus-2|terminus)
      harbor_terminus "$@"
      ;;
    *)
      printf 'error: unknown --agent %s (seed|mini-swe-agent|terminus-2)\n' "$AGENT" >&2
      exit 64
      ;;
  esac
}

case ${1:-} in
  smoke-oracle)
    N=1
    harbor_common -a oracle --include-task-name "$(task_name fix-git)"
    ;;
  smoke)
    N=1
    prefetch_images fix-git
    run_selected --include-task-name "$(task_name fix-git)"
    ;;
  task)
    [ -n "${2:-}" ] || { usage; exit 64; }
    N=1
    prefetch_images "$2"
    run_selected --include-task-name "$(task_name "$2")"
    ;;
  prefetch)
    prefetch_images "${2:-}"
    ;;
  --all)
    prefetch_images
    run_selected
    ;;
  *)
    usage
    exit 64
    ;;
esac
