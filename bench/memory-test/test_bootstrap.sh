#!/bin/sh
# bench/memory-test/test_bootstrap.sh — machine index v2: the launch bootstrap
# and the v1 migration. What this guards: the index must record what was found
# on THIS machine, not answer six questions a desktop would ask. A BusyBox or
# OpenWrt box must come up clean with zero capabilities and still be ready.
set -eu
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd)
REPO=${REPO_ROOT:-$(CDPATH= cd "$HERE/../.." && pwd)}

fail() { printf 'FAIL: %s\n' "$1" >&2; exit 1; }
ok() { printf 'ok: %s\n' "$1"; }
SEED_FILE=${SEED_FILE:-$REPO/seed.sh}
[ -f "$SEED_FILE" ] || fail "no runtime at $SEED_FILE"

FN=$(mktemp "${TMPDIR:-/tmp}/boot-fn.XXXXXX")
for f in agent_state_lock_acquire agent_state_lock_release \
         agent_os_token agent_prereq_json agent_sweep_path agent_bootstrap_machine \
         agent_migrate_index_v2 agent_check_machine_tree agent_repair_machine_tree \
         agent_baseline_file agent_write_baseline; do
  awk "/^$f\(\) \{/,/^\}/" "$SEED_FILE"
done > "$FN"
for f in agent_bootstrap_machine agent_migrate_index_v2 agent_check_machine_tree; do
  grep -q "^$f() {" "$FN" || fail "could not extract $f"
done
. "$FN"

WORK=$(mktemp -d "${TMPDIR:-/tmp}/boot.XXXXXX")
trap 'rm -rf "$WORK" "$FN"' EXIT INT TERM
INSTALL=$WORK
mkdir -p "$WORK/agent-store/packs"
cp "$REPO/packs/agent/init.json" "$WORK/agent-store/packs/init.json"
IDX=$WORK/agent-store/index.json
OBS=$WORK/agent-store/observations.json
q() { jq -e "$1" "$IDX" >/dev/null 2>&1; }
qo() { jq -e "$1" "$OBS" >/dev/null 2>&1; }

# ---------------------------------------------------------------- migration --
cat > "$IDX" <<'JSON'
{"ready":true,"version":"1","updated":"2026-08-16T15:12:28Z","system":{
 "retrieve":"OLD RETRIEVE TEXT","tools":{
  "sh":{"present":true,"path":"/bin/sh","ok":true,"note":"","probe":"/bin/sh -c 'echo ok'","scope":[]},
  "curl":{"present":true,"path":"/usr/bin/curl","ok":true,"note":"","probe":"","scope":["darwin"]},
  "jq":{"present":true,"path":"/usr/bin/jq","ok":true,"note":"","probe":"","scope":[]},
  "rg":{"present":false,"path":"","ok":false,"note":"debian calls it ripgrep","probe":"","scope":[]},
  "git":{"present":true,"path":"/usr/bin/git","ok":true,"note":"","probe":"","scope":[]},
  "python":{"present":false,"path":"","ok":false,"note":"","probe":"","scope":[]}},
 "resources":[
  {"name":"ffmpeg","kind":"cli","path":"/usr/bin/ffmpeg","purpose":"video","use":"ffmpeg -i","needs":[],"ok":true,"note":"","probe":"ffmpeg -version","probed":"2026-08-20T00:00:00Z","skill":"/s/SKILL.md"},
  {"name":"mdn","kind":"source","url":"https://developer.mozilla.org","purpose":"web docs","use":"","needs":[],"ok":true,"note":"","probe":"","probed":"2026-08-21T00:00:00Z","skill":""}],
 "other":[{"name":"busybox","path":"/bin/busybox","ok":true,"note":"applet multiplexer"}],
 "skills":[{"name":"mineru","description":"parse pdfs","path":"/x/SKILL.md","ok":true,"note":""}],
 "env":{"os":"Darwin","arch":"arm64","shell":"/bin/zsh"},
 "web":{"fetch":{"ok":true,"name":"fetch","use":"curl"}}},
 "ours":{"packs":["init"],"seed_agent":{"skills":"done"}}}
JSON
agent_migrate_index_v2 2>/dev/null

q '.version == "2"' || fail 'not migrated to v2'
q '.system | has("tools") | not' || fail 'system.tools survived the migration'
q '.identity.os == "darwin"' || fail 'os token not canonical lowercase'
q '.identity.arch == "arm64" and .identity.shell == "/bin/zsh"' || fail 'env not carried into identity'
ok 'v1 index migrates to v2 and the os token is canonicalised'

q '.capabilities[] | select(.name=="ffmpeg")
   | .kind=="cli" and .locator=="/usr/bin/ffmpeg" and .ok==true
     and .probe=="ffmpeg -version" and .verified_at=="2026-08-20T00:00:00Z"
     and .purpose==["video"] and .use=="ffmpeg -i" and .skill=="/s/SKILL.md"' \
  || fail 'a local resource did not become a capability intact'
q '.capabilities[] | select(.name=="busybox") | .ok==true and .note=="applet multiplexer"' \
  || fail 'system.other entry lost'
q '.capabilities[] | select(.name=="curl") | .scope == ["darwin"]' || fail 'tool scope lost'
q '.capabilities[] | select(.name=="rg") | .observed==false and .ok==false and (.note|length)>0' \
  || fail 'a tool known to be absent lost the note explaining why'
q '([.capabilities[] | select(.name=="python")] | length) == 0' \
  || fail 'an absent tool with nothing learned about it was kept as a capability'
ok 'nothing real is dropped; an absent tool with no note is not invented'

# v1 stored no probe string (the old wholesale probe deleted it), so an ok:true
# row would migrate into a capability nobody could ever re-verify.
q '.capabilities[] | select(.name=="git") | .probe == "/usr/bin/git --version"' \
  || fail 'probe not reconstructed for a migrated ok tool'
q '.capabilities[] | select(.name=="jq") | .probe | endswith("-n .")' \
  || fail 'jq probe reconstructed wrong'
q '.capabilities[] | select(.name=="sh") | .probe | contains("echo ok")' \
  || fail 'reconstruction overwrote a probe v1 had already recorded'
q '.capabilities[] | select(.name=="rg") | (.probe // "") == ""' \
  || fail 'a capability that is not ok got a probe invented for it'
ok 'every migrated ok capability carries a command that can re-verify it'

q '.resources[] | select(.name=="mdn") | .kind=="source" and (.locator|startswith("https://"))' \
  || fail 'an off-machine source did not become a resource'
q '([.resources[] | select(.name=="ffmpeg")] | length) == 0' || fail 'a local CLI landed in resources'
ok 'off-machine sources go to resources, local things to capabilities'

q '.agent.skills[] | select(.name=="mineru") | .ok==true' || fail 'skills lost'
q '.system.retrieve == "OLD RETRIEVE TEXT"' || fail 'retrieve lost'
q '.ours.seed_agent.skills == "done"' || fail 'pack progress lost'
ok 'skills, retrieve and pack progress survive'

before=$(jq -S -c . "$IDX")
agent_migrate_index_v2 2>/dev/null
[ "$before" = "$(jq -S -c . "$IDX")" ] || fail 'migration is not idempotent'
ok 'migrating an already-v2 index is a no-op'

# ---------------------------------------------------------------- bootstrap --
printf '{"version":"2","updated":"","observations":[
  {"type":"executable","name":"device-cli","path":"/opt/vendor/bin/device-cli","source":"filesystem","observed_at":"2026-08-20T00:00:00Z"},
  {"type":"applet","name":"ash","path":"busybox ash","source":"busybox --list"}]}\n' > "$OBS"
agent_bootstrap_machine

q '.identity.prereqs | has("sh") and has("curl") and has("jq")' || fail 'prereqs not written'
q '.identity.prereqs.jq | .ok == true and (.probe | endswith("-n ."))' \
  || fail 'prereq probe command not recorded'
q '(.identity.path_dirs | length) > 0 and (.identity.kernel | length) > 0' || fail 'identity incomplete'
q '.identity.scans[] | select(.source=="PATH") | .names > 0 and (.at | length) > 0' \
  || fail 'sweep not recorded in identity.scans'
ok 'bootstrap writes identity, prerequisites and the sweep record'

qo '([.observations[] | select(.source=="PATH")] | length) > 10' || fail 'PATH sweep is empty'
qo '.observations[] | select(.name=="jq" and .source=="PATH") | (.path|startswith("/"))' \
  || fail 'sweep row shape wrong'
qo '[.observations[] | select(.source=="PATH") | select(has("observed_at"))] | length == 0' \
  || fail 'sweep rows carry a per-row timestamp; the time belongs to the scan'
ok 'PATH sweep lands in observations.json without per-row timestamps'

qo '.observations[] | select(.name=="device-cli") | .source=="filesystem"' \
  || fail 'an observation a task wrote was destroyed by the sweep'
qo '.observations[] | select(.name=="ash") | .source=="busybox --list"' \
  || fail 'a deeper-probe observation was destroyed by the sweep'
ok 'observations found by a task outlive every re-sweep'

caps_before=$(jq -c '.capabilities' "$IDX")
agent_bootstrap_machine
[ "$caps_before" = "$(jq -c '.capabilities' "$IDX")" ] || fail 'bootstrap re-probed capabilities'
qo '([.observations[] | select(.name=="device-cli")] | length) == 1' || fail 'sweep duplicated rows'
ok 'bootstrap never touches capabilities, and re-sweeping does not duplicate'

# --------------------------------------------------- a machine with nothing --
# Everything the runtime itself needs, and two things it has never heard of.
DEV=$WORK/dev-root/bin
mkdir -p "$DEV"
for b in sh jq awk date uname mktemp sed grep curl mv rm tr cat ls mkdir rmdir sleep; do
  rb=$(command -v "$b" 2>/dev/null) && ln -sf "$rb" "$DEV/$b" || :
done
printf '#!/bin/sh\necho device-cli 1.0\n' > "$DEV/device-cli"; chmod +x "$DEV/device-cli"
printf '#!/bin/sh\necho opkg\n' > "$DEV/opkg"; chmod +x "$DEV/opkg"
rm -f "$OBS"
( PATH=$DEV; export PATH; agent_bootstrap_machine )

qo '.observations[] | select(.name=="device-cli") | .source=="PATH"' \
  || fail 'a vendor CLI on a bare machine was not observed'
qo '.observations[] | select(.name=="opkg")' || fail 'opkg not observed'
qo '([.observations[] | select(.name=="git")] | length) == 0' \
  || fail 'a tool that is not on this machine appeared in observations'
q '([.capabilities[] | select(.name=="opkg" or .name=="device-cli")] | length) == 0' \
  || fail 'bootstrap promoted an observation to a capability on its own'
ok 'a machine with no git/python/brew sweeps clean and invents nothing'

# ------------------------------------------------------------- schema gates --
agent_check_machine_tree "$IDX" || fail 'a good v2 index failed the check'
ok 'v2 index passes the readiness check'

bad=$WORK/bad.json
jq 'del(.identity.prereqs.jq)' "$IDX" > "$bad"
agent_check_machine_tree "$bad" && fail 'missing prereq passed the check'
jq 'del(.capabilities)' "$IDX" > "$bad"
agent_check_machine_tree "$bad" && fail 'missing capabilities array passed the check'
printf '{"ready":true,"version":"1","system":{"tools":{},"retrieve":"x","skills":[]}}\n' > "$bad"
agent_check_machine_tree "$bad" && fail 'a v1 index passed the v2 check'
ok 'the check rejects v1 and structurally broken v2'

jq 'del(.capabilities, .resources, .agent) | .system.retrieve = ""' "$IDX" > "$WORK/torn.json"
mv "$WORK/torn.json" "$IDX"
agent_repair_machine_tree || fail 'repair returned failure'
q '(.capabilities|type)=="array" and (.resources|type)=="array" and (.agent.skills|type)=="array"' \
  || fail 'repair did not restore the three layers'
q '(.system.retrieve|length) > 100' || fail 'repair did not restore retrieve from the pack'
ok 'repair restores the layers and the retrieve text'

agent_write_baseline || fail 'baseline write failed'
agent_check_machine_tree "$(agent_baseline_file)" || fail 'baseline does not satisfy the check'
ok 'baseline is a valid v2 index'

printf 'PASS: bootstrap (%s)\n' "${SEED_FILE##*/}"
