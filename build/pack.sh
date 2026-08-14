#!/bin/sh
# Pack build/ into a standalone seed.sh. Usage: sh build/pack.sh [outfile]
set -eu

BUILD=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
ROOT=$(CDPATH= cd "$BUILD/.." && pwd -P)
OUT=${1:-$ROOT/seed.sh}

need() {
  [ -f "$BUILD/$1" ] || { printf 'error: missing build/%s\n' "$1" >&2; exit 69; }
}

need env.sh
need edit.sh
need shell.sh
need model.sh
need loop.sh
need install.sh
need agent.sh
need prompts/product-system.txt
need prompts/tools.json

emit_quoted() {
  printf '%s() {\n  cat <<'\''EOF'\''\n' "$1"
  cat "$BUILD/$2"
  printf 'EOF\n}\n'
}

tmp=$(mktemp "${TMPDIR:-/tmp}/seed-pack.XXXXXX")
{
  cat <<'HDR'
#!/bin/sh
# Packed from build/. Do not edit. Change build/ and run: sh build/pack.sh
#   sh seed.sh deepseek sk-xxxx
set -eu
umask 077

HDR
  cat "$BUILD/env.sh"
  printf '\n'
  emit_quoted cabin_product_system prompts/product-system.txt
  printf '\n'
  emit_quoted tools_json prompts/tools.json
  printf '\n'
  cat "$BUILD/edit.sh"
  printf '\n'
  cat "$BUILD/shell.sh"
  printf '\n'
  cat "$BUILD/model.sh"
  printf '\n'
  cat "$BUILD/loop.sh"
  printf '\n'
  cat "$BUILD/install.sh"
  printf '\n'
  cat "$BUILD/agent.sh"
  printf '\n'
} > "$tmp"

if ! /bin/sh -n "$tmp"; then
  rm -f "$tmp"
  printf 'error: packed seed failed syntax check\n' >&2
  exit 70
fi

mv "$tmp" "$OUT"
chmod 755 "$OUT"
printf 'packed: %s\n' "$OUT" >&2
