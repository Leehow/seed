#!/bin/sh
# Pack build/ into a standalone seed2.sh. Usage: sh build/pack2.sh [outfile]
set -eu

BUILD=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
ROOT=$(CDPATH= cd "$BUILD/.." && pwd -P)
OUT=${1:-$ROOT/seed2.sh}

need() {
  [ -f "$BUILD/$1" ] || { printf 'error: missing build/%s\n' "$1" >&2; exit 69; }
}

for f in env.sh edit.sh shell.sh model.sh loop.sh product.sh seed2.sh \
  prompts/product-system.txt prompts/compact-summary.txt prompts/tools.json
do
  need "$f"
done

emit_quoted() {
  printf '%s() {\n  cat <<'\''EOF'\''\n' "$1"
  cat "$BUILD/$2"
  printf 'EOF\n}\n'
}

tmp=$(mktemp "${TMPDIR:-/tmp}/seed2-pack.XXXXXX")
{
  cat <<'HDR'
#!/bin/sh
# Packed from build/. Do not edit. Change build/ and run: sh build/pack2.sh
#   sh seed2.sh deepseek sk-xxxx
set -eu
umask 077

HDR
  cat "$BUILD/env.sh"
  printf '\n'
  emit_quoted cabin_product_system prompts/product-system.txt
  printf '\n'
  emit_quoted cabin_compact_summary prompts/compact-summary.txt
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
  cat "$BUILD/product.sh"
  printf '\n'
  cat "$BUILD/seed2.sh"
  printf '\n'
} > "$tmp"

if ! /bin/sh -n "$tmp"; then
  rm -f "$tmp"
  printf 'error: packed seed2 failed syntax check\n' >&2
  exit 70
fi

mv "$tmp" "$OUT"
chmod 755 "$OUT"
printf 'packed: %s\n' "$OUT" >&2
