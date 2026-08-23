# Seed POSIX Capsule (MSYS2, Windows x86_64)

Fixed-version, reproducible POSIX runtime used by the thin `seed.exe` launcher.
`seed.sh` stays the only Agent implementation. This directory is the *build
definition*: pinned package metadata, a layout contract, and scripts. It does
**not** vendor downloaded third-party binaries.

| Identity | Value |
|---|---|
| `host.os` | `windows` |
| `runtime.shell` | `sh` |
| `runtime.environment` | `msys2` |
| `capsule.id` | `seed-posix-msys2-x86_64-20260822` |
| Arch | `x86_64` only (ARM64 is out of scope) |

## Layout contract (launcher)

Assembled tree (`windows/capsule/out/runtime/` by default):

```
bin/sh.exe          # required entry; copy of usr/bin/sh.exe
bin/*.exe, *.dll    # tools + msys-*.dll (including msys-2.0.dll)
usr/                # MSYS prefix (ssl, remaining libs)
etc/                # fstab, nsswitch, profile
tmp/
seed/seed.sh        # first-party copy of repo seed.sh (byte-identical)
manifest.json       # generated ids + lock/seed/content hashes
SHA256SUMS          # sorted per-file hashes of the tree
NOTICE              # SPDX inventory from the lockfile
```

`layout.json` is the machine-readable contract. Launcher should:

1. Treat the capsule root as the MSYS install root (`bin/msys-2.0.dll` parent).
2. Spawn `bin/sh.exe` with `seed/seed.sh` and converted cwd/state paths.
3. Prepend capsule `bin/` to `PATH`, then append the host PATH
   (`MSYS2_PATH_TYPE=inherit`).
4. Set `MSYSTEM=MSYS` and `CHERE_INVOKING=1`.
5. Point curl at `usr/ssl/certs/ca-bundle.crt` if it does not find the bundle.

Do not mix this tree with Git for Windows / a second `msys-2.0.dll`.

## What is bundled (from `seed.sh`)

Hard commands reverse-engineered from `seed.sh` (see `commands.json`):

`sh`, `bash`, `jq`, `curl`, `awk`, `sed`, `grep`, `cat`, `rm`, `mv`, `mkdir`,
`chmod`, `cp`, `touch`, `mktemp`, `dirname`, `basename`, `pwd`, `uname`, `tr`,
`date`, `sleep`, `wc`, `tail`, `head`, `sort`, `printf`, `ps`, `kill`, plus
`cygpath` for Win32 path bridging.

`rg`, `git`, `python`, `node`, `powershell`, and `winget` are **host** tools.
They must not be taken from this capsule.

`ps`/`kill` come from `msys2-runtime` (Cygwin-style). `seed.sh` still calls
`ps -eo pid= -o ppid=`; Windows process-tree cleanup is the launcher Job Object
task, not a second Agent loop.

`ca-certificates` is extracted for its shipped `usr/ssl/certs/ca-bundle.crt`.
Its hook depends (`p11-kit`, `findutils`, `info`, `gzip`, `less`) are recorded
as `excluded_script_depends` and are not installed. Package `%INSTALL%` scripts
are never run.

`procps-ng` is **not** included: the MSYS2 package does not ship `ps.exe` or
`kill.exe`.

## macOS / Linux CI (no Windows, no binaries)

```sh
cd windows/capsule
sh build.sh validate
sh build.sh dry-run
```

`validate` checks lock schema, `packages.lock.sha256`, command↔package
coverage, dependency closure, hex digests, and the launcher layout. It does
not download anything.

`dry-run` is validate plus the pinned download URLs and compressed sizes.

Python 3 is required for metadata. `zstd` is only required for `assemble`.

## Build on Windows / MSYS2

Need a throwaway MSYS2 (or any environment with `python3`, `curl`/`https`,
`zstd`, and `tar`) to *produce* the capsule. The resulting tree is then
self-contained; end users do not install MSYS2.

In a MSYS2 UCRT/MSYS shell, from the repo root:

```sh
cd windows/capsule
sh build.sh assemble
# optional explicit dirs:
# sh build.sh assemble --cache "$PWD/cache" --out "$PWD/out/runtime"
```

Or from PowerShell if `python3` and `zstd` are on PATH:

```powershell
python windows\capsule\scripts\capsule.py assemble
```

What `assemble` does:

1. Re-runs `validate`.
2. Downloads each `packages.lock.json` filename from the official mirror
   (fallbacks listed in the lock) into `cache/`.
3. Verifies SHA-256 before extract. Mismatches are fatal.
4. Extracts `usr/` and `etc/` in `extract_order`, skipping man/doc/devel and
   mingw/clang prefixes.
5. Copies `usr/bin/*.exe` and `*.dll` to `bin/` so the launcher always sees
   `bin/sh.exe`.
6. Copies repo `seed.sh` to `seed/seed.sh` (first-party; not a third-party blob).
7. Writes `NOTICE`, `manifest.json`, and `SHA256SUMS`.

Do **not** `pacman -Syu` inside the assembled tree. Updates are a new locked
capsule, not an in-place upgrade.

After assemble, a Windows smoke (owned by the validation task) should at least:

```text
bin\sh.exe -n seed\seed.sh
bin\sh.exe seed\seed.sh --probe
```

## Refreshing the pin

The snapshot is `msys.db` from 2026-08-22 (`snapshot` in the lockfile). To move
forward:

1. Download `https://repo.msys2.org/msys/x86_64/msys.db` and record its
   SHA-256 / Last-Modified.
2. Resolve the same `roots` plus shared-library depends.
3. Replace `packages` / `extract_order` / hashes.
4. Run `sh build.sh hash-lock` then `sh build.sh validate`.
5. On Windows, `assemble` and keep the new `manifest.json` content hash.

## Files

| Path | Role |
|---|---|
| `packages.lock.json` | Pinned versions, SHA-256, licenses, mirrors |
| `packages.lock.sha256` | Digest of the lockfile |
| `layout.json` | Launcher path/env contract |
| `commands.json` | seed.sh command evidence |
| `build.sh` | POSIX entry |
| `scripts/capsule.py` | validate / dry-run / fetch / assemble |
| `licenses/README.md` | Provenance notes |
| `cache/`, `out/` | Local only (gitignored) |
