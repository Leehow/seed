write_shims() {
  mkdir -p "$INSTALL/bin"
  if [ "$SELF" != "$INSTALL/seed.sh" ]; then
    cp "$SELF" "$INSTALL/seed.sh"
    chmod 755 "$INSTALL/seed.sh"
  fi
  cp "$SELF" "$INSTALL/bin/agent"
  chmod 755 "$INSTALL/bin/agent"
  for pair in "llm|--llm" "edit|--edit" "shell|--shell-cli"; do
    name=${pair%%|*}
    flag=${pair#*|}
    printf '#!/bin/sh\nexec /bin/sh "$(CDPATH= cd "$(dirname "$0")" && pwd -P)/agent" %s "$@"\n' "$flag" > "$INSTALL/bin/$name"
    chmod 755 "$INSTALL/bin/$name"
  done
}

verify_install() {
  bad=0
  for f in agent llm edit shell; do
    p=$INSTALL/bin/$f
    if [ ! -x "$p" ]; then
      printf '  FAIL missing %s\n' "$p" >&2; bad=$((bad + 1))
    elif ! /bin/sh -n "$p" 2>/dev/null; then
      printf '  FAIL %s failed syntax check\n' "$p" >&2; bad=$((bad + 1))
    fi
  done
  [ -f "$INSTALL/seed.sh" ] || { printf '  FAIL missing seed.sh\n' >&2; bad=$((bad + 1)); }
  if [ ! -f "$LAUNCH_CWD/.env" ] || [ ! -f "$INSTALL/.env" ]; then
    printf '  FAIL incomplete .env\n' >&2; bad=$((bad + 1))
  else
    k1=$(jq -r -n --rawfile e "$LAUNCH_CWD/.env" '$e | split("\n") | map(select(startswith("LLM_API_KEY="))) | .[0] | split("=")[1]' 2>/dev/null || grep '^LLM_API_KEY=' "$LAUNCH_CWD/.env" | sed 's/^LLM_API_KEY=//')
    [ -n "$k1" ] || { printf '  FAIL .env has no key\n' >&2; bad=$((bad + 1)); }
  fi
  intro=$(LAUNCH_CWD=$LAUNCH_CWD SLAB_SKIP_INIT=1 /bin/sh "$INSTALL/bin/agent" </dev/null 2>&1 || true)
  printf '%s' "$intro" | grep -q '>' || { printf '  FAIL agent prompt missing\n' >&2; bad=$((bad + 1)); }
  extra=$(printf '%s' "$intro" | tr -d '>\n ')
  [ -z "$extra" ] || { printf '  FAIL agent lectured on open\n' >&2; bad=$((bad + 1)); }
  baked=$(printf '/%s/|/%s/' Users home)
  if grep -E "$baked" "$INSTALL/bin/agent" "$INSTALL/bin/edit" "$INSTALL/bin/llm" "$INSTALL/bin/shell" >/dev/null 2>&1; then
    printf '  FAIL shim baked a host path\n' >&2; bad=$((bad + 1))
  fi
  if grep -E 'exec /bin/sh .*seed\.sh' "$INSTALL/bin/agent" >/dev/null 2>&1; then
    printf '  FAIL agent execs seed.sh\n' >&2; bad=$((bad + 1))
  fi
  w=$(mktemp -d "${TMPDIR:-/tmp}/seed-ver.XXXXXX")
  w=$(CDPATH= cd "$w" && pwd)
  stub=$w/stub
  printf '0\n' > "$w/n"
  cat > "$stub" <<'STUB'
#!/bin/sh
n=$(cat "$SEED_VER_N")
n=$((n + 1))
printf '%s\n' "$n" > "$SEED_VER_N"
if [ "$n" -eq 1 ]; then
  printf '%s\n' '{"content":"","tool_calls":[{"id":"v1","name":"shell","arguments":"{\"command\":\"pwd\"}"}],"usage":{"prompt_tokens":1,"completion_tokens":1}}'
else
  printf '%s\n' '{"content":"ok","tool_calls":[],"usage":{"prompt_tokens":1,"completion_tokens":1}}'
fi
STUB
  chmod +x "$stub"
  set +e
  (
    cd "$w"
    SLAB_SKIP_INIT=1 SEED_LLM_STUB=$stub SEED_VER_N=$w/n /bin/sh "$INSTALL/bin/agent" --oneshot 'pwd'
  ) > "$w/out" 2> "$w/err"
  set -e
  if ! grep -q ok "$w/out"; then
    printf '  FAIL stub tool_calls did not run\n' >&2; bad=$((bad + 1))
  fi
  if ! grep -FR "$w" "$w/.agent-runs" >/dev/null 2>&1; then
    printf '  FAIL stub workspace was not the temp dir\n' >&2; bad=$((bad + 1))
  fi
  rm -rf "$w"
  [ "$bad" -eq 0 ] || die "verify failed: $bad check(s)" 76
}

install_main() {
  ensure_jq
  write_env_file "$LAUNCH_CWD/.env"
  write_env_file "$INSTALL/.env"
  ensure_gitignore "$LAUNCH_CWD"
  write_shims
  verify_install
  printf 'installed: bin/agent\n' >&2
  printf 'open: sh bin/agent\n' >&2
}
