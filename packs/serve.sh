#!/bin/sh
# Local pack catalog. Usage: sh packs/serve.sh
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
PORT=${SEED_PACK_PORT:-7432}
cd "$ROOT"
printf 'pack root:  http://127.0.0.1:%s\n' "$PORT" >&2
printf 'jq mirror:   http://127.0.0.1:%s/jq/\n' "$PORT" >&2
exec python3 -m http.server "$PORT" --bind 127.0.0.1
