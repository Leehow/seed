#!/bin/sh
# Agent plugin: write / summarize the top-level host map.
# Env: SLAB_MACHINE_INDEX = path to agent-store/index.json
# Usage: sh host.sh          # fill host when host.ok is not true
#        sh host.sh blurb    # print a short SYSTEM summary

hi_f=${SLAB_MACHINE_INDEX:-}
[ -n "$hi_f" ] && [ -f "$hi_f" ] || exit 1

host_blurb() {
  jq -e '.host.ok == true' "$hi_f" >/dev/null 2>&1 || return 0
  jq -r '
    .host as $h
    | [
        "Host: "
          + ($h.kind // "") + " / "
          + ($h.os // "") + " / "
          + ($h.release // "") + " / "
          + ($h.arch // "") + " / "
          + ($h.user // ""),
        (
          ($h.projects // []) as $p
          | if ($p | length) == 0 then empty
            else
              "Projects: "
              + ([$p[0:8][] | .name] | join(", "))
              + (if ($p | length) > 8 then " +" + ((($p | length) - 8) | tostring) else "" end)
            end
        )
      ]
    | join("\n")
  ' "$hi_f" 2>/dev/null || true
}

host_inventory() {
  jq -e '.host.ok == true' "$hi_f" >/dev/null 2>&1 && return 0
  hi_os=$(uname -s 2>/dev/null || true)
  hi_arch=$(uname -m 2>/dev/null || true)
  hi_kind=
  case $hi_os in
    Darwin) hi_kind=mac ;;
    Linux) hi_kind=linux ;;
    *)
      hi_kind=$(printf '%s' "$hi_os" | tr '[:upper:]' '[:lower:]' 2>/dev/null || true)
      ;;
  esac
  hi_release=
  hi_cpu=
  hi_mem=
  hi_disk=
  hi_note=
  case $hi_kind in
    mac)
      hi_release=$(sw_vers -productVersion 2>/dev/null || true)
      hi_cpu=$(sysctl -n hw.ncpu 2>/dev/null || true)
      hi_bytes=$(sysctl -n hw.memsize 2>/dev/null || true)
      case $hi_bytes in
        ''|*[!0-9]*) ;;
        *) hi_mem=$(jq -nr --argjson b "$hi_bytes" '(($b / 1073741824) | floor | tostring) + "GiB"') ;;
      esac
      ;;
    linux)
      if [ -f /etc/os-release ]; then
        hi_release=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release | tr -d '"' || true)
      fi
      hi_cpu=$(getconf _NPROCESSORS_ONLN 2>/dev/null || true)
      if [ -z "$hi_cpu" ] && [ -f /proc/cpuinfo ]; then
        hi_cpu=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || true)
      fi
      if [ -f /proc/meminfo ]; then
        hi_kb=$(sed -n 's/^MemTotal:[[:space:]]*\([0-9][0-9]*\).*/\1/p' /proc/meminfo)
        case $hi_kb in
          ''|*[!0-9]*) ;;
          *) hi_mem=$(jq -nr --argjson k "$hi_kb" '(($k / 1048576) | floor | tostring) + "GiB"') ;;
        esac
      fi
      ;;
  esac
  hi_home=${HOME:-}
  hi_user=$(id -un 2>/dev/null || true)
  if [ -n "$hi_home" ] && [ -d "$hi_home" ]; then
    hi_avail=$(
      hi_line=$(df -P "$hi_home" 2>/dev/null | sed -n '2p')
      [ -n "$hi_line" ] || exit 0
      set -- $hi_line
      printf '%s\n' "${4:-}"
    )
    case $hi_avail in
      ''|*[!0-9]*) ;;
      *) hi_disk=$(jq -nr --argjson a "$hi_avail" '(($a / 1048576) | floor | tostring) + "GiB avail"') ;;
    esac
  fi
  hi_htf=$(mktemp "${TMPDIR:-/tmp}/seed-ht.XXXXXX")
  hi_pjf=$(mktemp "${TMPDIR:-/tmp}/seed-pj.XXXXXX")
  if [ -n "$hi_home" ] && [ -d "$hi_home" ]; then
    for hi_e in "$hi_home"/*; do
      [ -d "$hi_e" ] || continue
      hi_bn=$(basename "$hi_e")
      printf '%s\n' "$hi_bn" >> "$hi_htf"
    done
    for hi_dot in .claude .codex .agents; do
      if [ -d "$hi_home/$hi_dot" ]; then
        printf '%s\n' "$hi_dot" >> "$hi_htf"
      fi
    done
  fi
  if [ -e "${PWD:-}/.git" ]; then
    printf '%s\t%s\n' "$(basename "$PWD")" "$PWD" >> "$hi_pjf"
  fi
  if [ -n "$hi_home" ]; then
    for hi_root in \
      "$hi_home/leehow/code" \
      "$hi_home/code" \
      "$hi_home/src" \
      "$hi_home/Projects" \
      "$hi_home/Desktop" \
      "$hi_home/dev"
    do
      [ -d "$hi_root" ] || continue
      for hi_p in "$hi_root"/*; do
        [ -d "$hi_p" ] || continue
        if [ -e "$hi_p/.git" ]; then
          printf '%s\t%s\n' "$(basename "$hi_p")" "$hi_p" >> "$hi_pjf"
        fi
        for hi_p2 in "$hi_p"/*; do
          [ -d "$hi_p2" ] || continue
          if [ -e "$hi_p2/.git" ]; then
            printf '%s\t%s\n' "$(basename "$hi_p2")" "$hi_p2" >> "$hi_pjf"
          fi
        done
      done
    done
  fi
  hi_ht_json=$(jq -c -R -s 'split("\n") | map(select(length>0))' "$hi_htf" 2>/dev/null || printf '[]')
  hi_pj_json=$(jq -c -R -s '
    split("\n")
    | map(select(length>0) | split("\t") | select(length >= 2)
        | {name: .[0], path: .[1], vcs: "git"})
    | unique_by(.path)
    | .[0:40]
  ' "$hi_pjf" 2>/dev/null || printf '[]')
  rm -f "$hi_htf" "$hi_pjf"
  hi_whome=false
  hi_wws=false
  if [ -n "$hi_home" ] && [ -d "$hi_home" ]; then
    hi_tf=$hi_home/.slab-host-probe.$$
    if touch "$hi_tf" 2>/dev/null && rm -f "$hi_tf"; then
      hi_whome=true
    fi
  fi
  if [ -n "${PWD:-}" ] && [ -d "$PWD" ]; then
    hi_tf=$PWD/.slab-host-probe.$$
    if touch "$hi_tf" 2>/dev/null && rm -f "$hi_tf"; then
      hi_wws=true
    fi
  fi
  hi_sudo=false
  if sudo -n true >/dev/null 2>&1; then
    hi_sudo=true
  fi
  if [ -n "$hi_home" ] && [ -d "$hi_home/.ssh" ]; then
    if [ -n "$hi_note" ]; then
      hi_note="$hi_note; ssh_dir=yes"
    else
      hi_note=ssh_dir=yes
    fi
  fi
  hi_ok=false
  if [ -n "$hi_kind" ] && [ -n "$hi_os" ] && [ -n "$hi_user" ]; then
    hi_ok=true
  fi
  hi_tmp=$(mktemp "${TMPDIR:-/tmp}/seed-host.XXXXXX")
  if jq \
    --argjson ok "$hi_ok" \
    --arg kind "$hi_kind" \
    --arg os "$hi_os" \
    --arg arch "$hi_arch" \
    --arg release "$hi_release" \
    --arg cpu "$hi_cpu" \
    --arg mem "$hi_mem" \
    --arg disk "$hi_disk" \
    --arg user "$hi_user" \
    --arg home "$hi_home" \
    --argjson home_top "$hi_ht_json" \
    --argjson projects "$hi_pj_json" \
    --argjson write_home "$hi_whome" \
    --argjson write_ws "$hi_wws" \
    --argjson sudo "$hi_sudo" \
    --arg note "$hi_note" \
    '.host = {
      ok: $ok,
      kind: $kind,
      os: $os,
      arch: $arch,
      release: $release,
      cpu: $cpu,
      mem: $mem,
      disk: $disk,
      user: $user,
      home: $home,
      home_top: $home_top,
      projects: $projects,
      write: { home: $write_home, workspace: $write_ws },
      sudo: $sudo,
      note: $note
    }' "$hi_f" > "$hi_tmp"
  then
    mv "$hi_tmp" "$hi_f"
    return 0
  fi
  rm -f "$hi_tmp"
  return 1
}

case ${1:-} in
  blurb) host_blurb ;;
  *) host_inventory ;;
esac
