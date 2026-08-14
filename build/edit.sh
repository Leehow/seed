edit_main() {
  [ "$#" -eq 3 ] || die 'usage: --edit PATH OLD NEW' 64
  need jq
  path=$1 old=$2 new=$3
  [ -n "$old" ] || { printf 'edit: old_text is empty\n' >&2; return 2; }
  [ -f "$path" ] || { printf 'edit: cannot read %s\n' "$path" >&2; return 66; }
  tmp=$(mktemp "${TMPDIR:-/tmp}/seed-edit.XXXXXX")
  set +e
  jq -nr --rawfile t "$path" --arg old "$old" --arg new "$new" '
    ($t | split($old)) as $p
    | if ($p | length) != 2 then
        ("edit: old_text matches \(($p | length) - 1) times, need exactly 1\n" | halt_error(2))
      else
        $p[0] + $new + $p[1]
      end
  ' > "$tmp"
  es=$?
  set -e
  if [ "$es" -ne 0 ]; then
    rm -f "$tmp"
    return "$es"
  fi
  mv "$tmp" "$path"
}
