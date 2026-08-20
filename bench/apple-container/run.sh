#!/bin/sh
# Live seed bench on Apple container (not Docker).
# Usage: sh bench/apple-container/run.sh [--env FILE] PROFILE TASK
#        sh bench/apple-container/run.sh [--env FILE] --all
#        sh bench/apple-container/run.sh [--env FILE] --amortize
# BENCH_SHARED overrides the per-profile state dir name (default shared-$profile).
set -eu

HERE=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
ROOT=$(CDPATH= cd "$HERE/../.." && pwd -P)
SEED=$ROOT/seed.sh
ENVFILE=$ROOT/.env
ARCH=${BENCH_ARCH:-aarch64}
DNS=${BENCH_DNS:-8.8.8.8}
MEM=${BENCH_MEMORY:-4G}

usage() {
  printf 'usage: sh bench/apple-container/run.sh [--env FILE] clean|rich TASK\n' >&2
  printf '       sh bench/apple-container/run.sh [--env FILE] --all\n' >&2
  printf '       sh bench/apple-container/run.sh [--env FILE] --amortize\n' >&2
}

if [ "${1:-}" = --env ]; then
  ENVFILE=$2
  shift 2
fi

[ -f "$SEED" ] || { printf 'error: missing seed.sh\n' >&2; exit 69; }
[ -f "$ENVFILE" ] || { printf 'error: missing env file (pass --env)\n' >&2; exit 64; }

build_image() {
  profile=$1
  tag=slab-bench-$profile
  file=$HERE/$profile.Containerfile
  if container image list | awk '{print $1":"$2}' | grep -qx "$tag:latest"; then
    printf 'image: %s already present\n' "$tag" >&2
    return 0
  fi
  printf 'building: %s\n' "$tag" >&2
  container build --arch "$ARCH" --dns "$DNS" -t "$tag" -f "$file" "$HERE" >&2
}

run_one() {
  profile=$1
  task=$2
  taskdir=$HERE/tasks/$task
  [ -d "$taskdir" ] || { printf 'error: unknown task %s\n' "$task" >&2; return 64; }
  tag=slab-bench-$profile
  build_image "$profile"

  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  hostrun=$HERE/out/$stamp-$profile-$task
  mkdir -p "$hostrun/ws" "$hostrun/task"
  shared=$HERE/out/${BENCH_SHARED:-shared-$profile}
  mkdir -p "$shared/state"
  cp "$SEED" "$hostrun/seed.sh"
  cp "$taskdir/instruction.txt" "$hostrun/task/instruction.txt"
  cp "$taskdir/setup.sh" "$hostrun/task/setup.sh"
  cp "$taskdir/verify.sh" "$hostrun/task/verify.sh"
  chmod 755 "$hostrun/task/setup.sh" "$hostrun/task/verify.sh" "$hostrun/seed.sh"

  # Driver stays in the mounted tree. Env vars come from --env-file, never printed.
  cat > "$hostrun/driver.sh" <<'DRV'
#!/bin/sh
set -eu
cd /work
/bin/sh /work/task/setup.sh /work/ws
cd /work/ws
export SEED_HOME=/shared/state
export AGENT_RUNS_DIR=/work/runs
export AGENT_MAX_ROUNDS=${AGENT_MAX_ROUNDS:-20}
set +e
/bin/sh /work/seed.sh --oneshot "$(cat /work/task/instruction.txt)"
st=$?
set -e
printf '%s\n' "$st" > /work/oneshot.exit
/bin/sh /work/task/verify.sh /work/ws /shared/state > /work/verify.out 2>/work/verify.err || true
DRV
  chmod 755 "$hostrun/driver.sh"

  printf '=== %s / %s ===\n' "$profile" "$task" >&2
  t0=$(date +%s)
  # Source on the host so shell quotes in LLM_EXTRA are stripped.
  # Apple --env-file does not parse shell quotes and breaks disable_thinking.
  set -a
  # shellcheck disable=SC1090
  . "$ENVFILE"
  set +a
  set +e
  container run --rm --arch "$ARCH" --dns "$DNS" --memory "$MEM" \
    --env LLM_PROVIDER --env LLM_API_URL --env LLM_MODEL \
    --env LLM_API_KEY --env LLM_EXTRA \
    --env SEED_HOME=/shared/state \
    --env AGENT_RUNS_DIR=/work/runs \
    --env AGENT_MAX_ROUNDS="${AGENT_MAX_ROUNDS:-20}" \
    --mount "type=bind,source=$hostrun,target=/work" \
    --mount "type=bind,source=$shared,target=/shared" \
    "$tag" \
    /bin/sh /work/driver.sh
  cr=$?
  set -e
  t1=$(date +%s)
  wall=$((t1 - t0))

  oneshot=$(cat "$hostrun/oneshot.exit" 2>/dev/null || printf '?')
  if grep -qx pass "$hostrun/verify.out" 2>/dev/null; then
    verdict=pass
  else
    verdict=fail
  fi
  tools_web=$(/bin/sh "$HERE/analyze.sh" "$hostrun/runs")
  used=$(printf '%s\n' "$tools_web" | awk -F= '/^tools=/{print $2}')
  web=$(printf '%s\n' "$tools_web" | awk -F= '/^web=/{print $2}')

  mkdir -p "$HERE/out"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$stamp" "$profile" "$task" "$verdict" "$wall" "$oneshot" "$used" "$web" \
    | tee -a "$HERE/out/results.tsv"
  printf 'result: %s/%s %s wall=%ss oneshot_exit=%s tools=%s web=%s container_exit=%s\n' \
    "$profile" "$task" "$verdict" "$wall" "$oneshot" "$used" "$web" "$cr" >&2
  if [ "$verdict" != pass ]; then
    if [ -s "$hostrun/verify.err" ]; then
      printf 'verify: %s\n' "$(cat "$hostrun/verify.err")" >&2
    fi
  fi
}

if [ "${1:-}" = --all ]; then
  run_one clean hello-file
  run_one clean search-needle
  run_one clean web-install-fd
  run_one clean openssl-selfsigned-cert
  run_one clean nginx-request-logging
  run_one clean fix-git
  run_one rich search-needle
  run_one rich fix-git
  run_one rich list-tools
  run_one rich openssl-selfsigned-cert
  run_one rich nginx-request-logging
  exit 0
fi

if [ "${1:-}" = --amortize ]; then
  # Fresh rich state: first task pays init, later tasks should hit the index.
  rm -rf "$HERE/out/shared-amortize-rich"
  BENCH_SHARED=shared-amortize-rich
  export BENCH_SHARED
  run_one rich census-tools
  run_one rich hello-file
  run_one rich list-tools
  run_one rich search-needle
  run_one rich fix-git
  exit 0
fi

[ "$#" -eq 2 ] || { usage; exit 64; }
run_one "$1" "$2"
