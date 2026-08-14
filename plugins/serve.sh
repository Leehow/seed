#!/bin/sh
# Local plugin directory. Usage: sh plugins/serve.sh
set -eu
ROOT=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
PORT=${SEED_PLUGIN_PORT:-7432}
cd "$ROOT"
printf 'plugin root: http://127.0.0.1:%s\n' "$PORT" >&2
exec python3 -m http.server "$PORT" --bind 127.0.0.1
