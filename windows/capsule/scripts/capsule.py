#!/usr/bin/env python3
"""Validate, fetch, and assemble the pinned MSYS2 POSIX capsule.

Never copies host files into the runtime. Packages come only from the lockfile
URLs and are checked against pinned SHA-256 digests.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import re
import shutil
import subprocess
import sys
import tarfile
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any

HERE = Path(__file__).resolve().parent
CAPSULE_DIR = HERE.parent
REPO_ROOT = CAPSULE_DIR.parent.parent
HEX64 = re.compile(r"^[0-9a-f]{64}$")
DEP_NAME = re.compile(r"^([^<>=]+)")


def die(msg: str, code: int = 1) -> None:
    print(f"error: {msg}", file=sys.stderr)
    raise SystemExit(code)


def load_json(path: Path) -> Any:
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        die(f"missing {path}")
    except json.JSONDecodeError as exc:
        die(f"invalid JSON {path}: {exc}")


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def lock_text_digest(path: Path) -> str:
    return sha256_bytes(path.read_bytes())


def dep_name(spec: str) -> str:
    m = DEP_NAME.match(spec.strip())
    return m.group(1) if m else spec


def provides_index(lock: dict) -> dict[str, str]:
    idx: dict[str, str] = {}
    for name, pkg in lock["packages"].items():
        idx[name] = name
        for prov in pkg.get("provides") or []:
            idx[dep_name(prov)] = name
    return idx


def load_inputs() -> tuple[dict, dict, dict, Path]:
    lock_path = CAPSULE_DIR / "packages.lock.json"
    lock = load_json(lock_path)
    layout = load_json(CAPSULE_DIR / "layout.json")
    commands = load_json(CAPSULE_DIR / "commands.json")
    return lock, layout, commands, lock_path


def check_lock_sidecar(lock_path: Path) -> list[str]:
    errors: list[str] = []
    sidecar = lock_path.with_suffix(".sha256")
    if not sidecar.exists():
        errors.append(f"missing {sidecar.name}")
        return errors
    line = sidecar.read_text(encoding="utf-8").strip().splitlines()[0]
    expected = line.split()[0].lower()
    actual = lock_text_digest(lock_path)
    if expected != actual:
        errors.append(
            f"packages.lock.sha256 mismatch: expected {expected}, got {actual}"
        )
    return errors


def validate(lock: dict, layout: dict, commands: dict, lock_path: Path) -> list[str]:
    errors: list[str] = []

    if lock.get("schema_version") != 1:
        errors.append("packages.lock.json schema_version must be 1")
    if layout.get("schema_version") != 1:
        errors.append("layout.json schema_version must be 1")
    if commands.get("schema_version") != 1:
        errors.append("commands.json schema_version must be 1")

    errors.extend(check_lock_sidecar(lock_path))

    pkgs = lock.get("packages") or {}
    if not isinstance(pkgs, dict) or not pkgs:
        errors.append("packages.lock.json has no packages")
        return errors

    roots = lock.get("roots") or []
    extract_order = lock.get("extract_order") or []
    for root in roots:
        if root not in pkgs:
            errors.append(f"root package not locked: {root}")
    if set(extract_order) != set(pkgs):
        errors.append(
            "extract_order is not exactly the locked package set: "
            f"only_order={sorted(set(extract_order) - set(pkgs))} "
            f"only_lock={sorted(set(pkgs) - set(extract_order))}"
        )

    for name, pkg in pkgs.items():
        for key in ("version", "filename", "sha256", "csize"):
            if key not in pkg:
                errors.append(f"{name}: missing {key}")
        fn = str(pkg.get("filename") or "")
        if not fn or "/" in fn or "\\" in fn or fn.startswith("."):
            errors.append(f"{name}: unsafe filename {fn!r}")
        digest = str(pkg.get("sha256") or "").lower()
        if not HEX64.match(digest):
            errors.append(f"{name}: sha256 is not 64 lowercase hex")
        if not isinstance(pkg.get("csize"), int) or pkg["csize"] <= 0:
            errors.append(f"{name}: csize must be a positive int")
        if not pkg.get("license"):
            errors.append(f"{name}: missing license")

    mirrors = lock.get("mirrors") or []
    if not any(m.get("primary") and m.get("url") for m in mirrors):
        errors.append("no primary mirror url")
    for mirror in mirrors:
        url = str(mirror.get("url") or "")
        if not url.startswith("https://") or not url.endswith("/"):
            errors.append(f"mirror {mirror.get('id')}: url must be https and end with /")

    snap = lock.get("snapshot") or {}
    if not HEX64.match(str(snap.get("db_sha256") or "")):
        errors.append("snapshot.db_sha256 is not 64 hex")
    if not str(snap.get("db_url") or "").startswith("https://"):
        errors.append("snapshot.db_url must be https")

    idx = provides_index(lock)
    excluded = set(lock.get("excluded_script_depends") or [])
    file_only = set(lock.get("file_only_packages") or [])
    for name, pkg in pkgs.items():
        if name in file_only:
            continue
        for spec in pkg.get("depends") or []:
            dep = dep_name(spec)
            resolved = idx.get(dep)
            if resolved in pkgs or dep in excluded:
                continue
            errors.append(f"{name}: unresolved depend {spec}")

    required_bins = lock.get("required_binaries") or {}
    for cmd, meta in required_bins.items():
        pkg_name = meta.get("package")
        path = meta.get("path")
        if pkg_name not in pkgs:
            errors.append(f"required binary {cmd}: package {pkg_name} not locked")
        if not str(path).replace("\\", "/").startswith("usr/bin/"):
            errors.append(f"required binary {cmd}: path must be under usr/bin/")

    for cmd in commands.get("required") or []:
        name = cmd.get("command")
        pkg_name = cmd.get("package")
        if name not in required_bins:
            errors.append(f"commands.json {name} missing from lock required_binaries")
        elif required_bins[name].get("package") != pkg_name:
            errors.append(
                f"commands.json {name} package {pkg_name} != lock "
                f"{required_bins[name].get('package')}"
            )

    for key in ("shell", "seed", "manifest", "hashes"):
        if key not in layout:
            errors.append(f"layout.json missing {key}")
    if layout.get("shell") != "bin/sh.exe":
        errors.append("layout.shell must be bin/sh.exe")
    if layout.get("seed") != "seed/seed.sh":
        errors.append("layout.seed must be seed/seed.sh")

    dlls = lock.get("required_dlls") or []
    if "usr/bin/msys-2.0.dll" not in dlls:
        errors.append("required_dlls must include usr/bin/msys-2.0.dll")

    return errors


def primary_mirror(lock: dict) -> str:
    for mirror in lock["mirrors"]:
        if mirror.get("primary"):
            return str(mirror["url"])
    return str(lock["mirrors"][0]["url"])


def package_urls(lock: dict, pkg: dict) -> list[str]:
    name = pkg["filename"]
    urls = []
    for mirror in lock["mirrors"]:
        url = str(mirror.get("url") or "")
        if url:
            urls.append(url + name)
    return urls


def print_dry_run(lock: dict, layout: dict) -> None:
    pkgs = lock["packages"]
    total = sum(p["csize"] for p in pkgs.values())
    print(f"capsule.id={lock['capsule']['id']}")
    print(f"packages={len(pkgs)}")
    print(f"compressed_bytes={total}")
    print(f"primary_mirror={primary_mirror(lock)}")
    print(f"layout.shell={layout['shell']}")
    print(f"layout.seed={layout['seed']}")
    print(f"zstd={'yes' if shutil.which('zstd') else 'no'}")
    print(f"tar={'yes' if shutil.which('tar') else 'no'}")
    print("downloads:")
    for name in lock["extract_order"]:
        pkg = pkgs[name]
        print(f"  {pkg['sha256']}  {pkg['csize']:9d}  {package_urls(lock, pkg)[0]}")


def cache_dir(arg: str | None) -> Path:
    return Path(arg).resolve() if arg else (CAPSULE_DIR / "cache")


def out_dir(arg: str | None) -> Path:
    return Path(arg).resolve() if arg else (CAPSULE_DIR / "out" / "runtime")


def fetch_one(urls: list[str], dest: Path, expected: str) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists() and sha256_file(dest) == expected:
        return
    last_err = "no mirrors"
    for url in urls:
        tmp = dest.with_suffix(dest.suffix + ".part")
        try:
            print(f"fetch {url}", flush=True)
            with urllib.request.urlopen(url, timeout=90) as resp, tmp.open("wb") as fh:
                shutil.copyfileobj(resp, fh)
            digest = sha256_file(tmp)
            if digest != expected:
                tmp.unlink(missing_ok=True)
                last_err = f"{url} sha256 {digest} != {expected}"
                continue
            tmp.replace(dest)
            return
        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            tmp.unlink(missing_ok=True)
            last_err = f"{url}: {exc}"
    die(f"download failed: {last_err}")


def fetch(lock: dict, cache: Path) -> None:
    cache.mkdir(parents=True, exist_ok=True)
    for name in lock["extract_order"]:
        pkg = lock["packages"][name]
        dest = cache / pkg["filename"]
        fetch_one(package_urls(lock, pkg), dest, pkg["sha256"])
        print(f"ok {pkg['filename']}", flush=True)


def zstd_decompress(src: Path) -> bytes:
    zstd = shutil.which("zstd")
    if not zstd:
        die("zstd is required to extract packages")
    try:
        return subprocess.check_output([zstd, "-d", "-c", str(src)])
    except subprocess.CalledProcessError as exc:
        die(f"zstd failed for {src.name}: {exc}")


def should_skip_member(name: str, prune: list[str], globs: list[str]) -> bool:
    norm = name.replace("\\", "/").lstrip("./")
    if not norm or norm.startswith("."):
        return True
    for prefix in prune:
        if norm == prefix or norm.startswith(prefix.rstrip("/") + "/"):
            return True
    base = Path(norm).name
    for pattern in globs:
        if Path(base).match(pattern) or Path(norm).match(pattern):
            return True
    return False


def safe_extract(tf: tarfile.TarFile, dest: Path, prune: list[str], globs: list[str]) -> None:
    dest = dest.resolve()
    for member in tf.getmembers():
        name = member.name.replace("\\", "/").lstrip("./")
        if should_skip_member(name, prune, globs):
            continue
        target = (dest / name).resolve()
        if dest != target and dest not in target.parents:
            die(f"refusing path escape: {member.name}")
        if member.issym() or member.islnk():
            # Recreate relative links only; skip absolute / escaping links.
            link = member.linkname or ""
            if link.startswith("/") or ".." in Path(link).parts:
                continue
        tf.extract(member, path=dest, set_attrs=False)


def copy_bin_layer(runtime: Path) -> None:
    src = runtime / "usr" / "bin"
    dst = runtime / "bin"
    if not src.is_dir():
        die("assemble: usr/bin missing after extract")
    dst.mkdir(parents=True, exist_ok=True)
    for item in src.iterdir():
        if item.suffix.lower() in {".exe", ".dll"} or item.name in {"sh", "bash", "cmd", "shell"}:
            target = dst / item.name
            shutil.copy2(item, target)


def write_notice(lock: dict, runtime: Path, seed_sha: str) -> None:
    lines = [
        "Seed POSIX Capsule",
        "",
        f"capsule.id={lock['capsule']['id']}",
        "host.os=windows",
        "runtime.shell=sh",
        "runtime.environment=msys2",
        "",
        "First-party:",
        f"  seed/seed.sh  sha256={seed_sha}  MIT  (repository LICENSE)",
        "",
        "Third-party MSYS2 packages (do not treat this capsule as a single license):",
        "",
    ]
    for name in lock["extract_order"]:
        pkg = lock["packages"][name]
        lic = ", ".join(pkg.get("license") or ["UNKNOWN"])
        lines.append(
            f"  {name} {pkg['version']}  {lic}  {pkg.get('homepage') or ''}  "
            f"{pkg.get('msys2_source')}"
        )
    lines.extend(
        [
            "",
            "Packages were extracted from pinned .pkg.tar.zst files. Install scripts",
            "were not executed. See windows/capsule/packages.lock.json for SHA-256.",
            "",
        ]
    )
    (runtime / "NOTICE").write_text("\n".join(lines), encoding="utf-8")
    license_src = REPO_ROOT / "LICENSE"
    if license_src.is_file():
        shutil.copy2(license_src, runtime / "LICENSE.SEED")


def write_runtime_manifest(
    lock: dict,
    layout: dict,
    runtime: Path,
    lock_digest: str,
    seed_sha: str,
    sums: list[tuple[str, str]],
) -> None:
    content_digest = sha256_bytes(
        "".join(f"{digest}  {path}\n" for digest, path in sums).encode("utf-8")
    )
    manifest = {
        "schema_version": 1,
        "capsule_id": lock["capsule"]["id"],
        "arch": lock["capsule"]["arch"],
        "host_os": "windows",
        "runtime_shell": "sh",
        "runtime_environment": "msys2",
        "layout": {
            "shell": layout["shell"],
            "seed": layout["seed"],
            "path_dirs": layout.get("path_dirs"),
            "ca_bundle": layout.get("ca_bundle"),
        },
        "lock_sha256": lock_digest,
        "seed_sha256": seed_sha,
        "content_sha256": content_digest,
        "package_count": len(lock["packages"]),
        "file_count": len(sums),
        "packages": [
            {
                "name": name,
                "version": lock["packages"][name]["version"],
                "filename": lock["packages"][name]["filename"],
                "sha256": lock["packages"][name]["sha256"],
            }
            for name in lock["extract_order"]
        ],
    }
    (runtime / layout["manifest"]).write_text(
        json.dumps(manifest, indent=2) + "\n", encoding="utf-8"
    )
    (runtime / layout["hashes"]).write_text(
        "".join(f"{digest}  {path}\n" for digest, path in sums),
        encoding="utf-8",
    )


def hashed_files(runtime: Path) -> list[tuple[str, str]]:
    skip = {"SHA256SUMS", "manifest.json"}
    rows: list[tuple[str, str]] = []
    for path in sorted(p for p in runtime.rglob("*") if p.is_file()):
        rel = path.relative_to(runtime).as_posix()
        if rel in skip:
            continue
        rows.append((sha256_file(path), rel))
    return rows


def verify_required(lock: dict, layout: dict, runtime: Path) -> None:
    missing = []
    for cmd, meta in lock["required_binaries"].items():
        pkg_path = runtime / meta["path"]
        bin_path = runtime / "bin" / Path(meta["path"]).name
        if not pkg_path.is_file() and not bin_path.is_file():
            missing.append(f"{cmd} ({meta['path']})")
    for dll in lock["required_dlls"]:
        if not (runtime / dll).is_file() and not (runtime / "bin" / Path(dll).name).is_file():
            missing.append(dll)
    for entry in layout.get("required_entrypoints") or []:
        if not (runtime / entry).is_file():
            missing.append(entry)
    if missing:
        die("assemble missing required files:\n  " + "\n  ".join(missing))


def assemble(lock: dict, layout: dict, cache: Path, runtime: Path, lock_digest: str) -> None:
    seed_src = REPO_ROOT / "seed.sh"
    if not seed_src.is_file():
        die(f"seed.sh not found at {seed_src}")
    fetch(lock, cache)

    if runtime.exists():
        shutil.rmtree(runtime)
    runtime.mkdir(parents=True)

    prune = list(lock.get("prune") or [])
    globs = list(lock.get("prune_globs") or [])
    for name in lock["extract_order"]:
        pkg = lock["packages"][name]
        archive = cache / pkg["filename"]
        if sha256_file(archive) != pkg["sha256"]:
            die(f"cache corrupt: {pkg['filename']}")
        raw = zstd_decompress(archive)
        with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as tf:
            safe_extract(tf, runtime, prune, globs)
        print(f"extract {pkg['filename']}", flush=True)

    copy_bin_layer(runtime)
    seed_dir = runtime / "seed"
    seed_dir.mkdir(parents=True, exist_ok=True)
    shutil.copy2(seed_src, seed_dir / "seed.sh")
    (runtime / "tmp").mkdir(exist_ok=True)
    seed_sha = sha256_file(seed_dir / "seed.sh")
    write_notice(lock, runtime, seed_sha)
    verify_required(lock, layout, runtime)
    sums = hashed_files(runtime)
    write_runtime_manifest(lock, layout, runtime, lock_digest, seed_sha, sums)
    print(f"assembled {runtime}")
    print(f"seed_sha256={seed_sha}")
    print(f"files={len(sums)}")


def cmd_validate(args: argparse.Namespace) -> None:
    lock, layout, commands, lock_path = load_inputs()
    errors = validate(lock, layout, commands, lock_path)
    if errors:
        for item in errors:
            print(f"error: {item}", file=sys.stderr)
        raise SystemExit(1)
    print(f"ok lock={lock['capsule']['id']} packages={len(lock['packages'])}")


def cmd_dry_run(args: argparse.Namespace) -> None:
    lock, layout, commands, lock_path = load_inputs()
    errors = validate(lock, layout, commands, lock_path)
    if errors:
        for item in errors:
            print(f"error: {item}", file=sys.stderr)
        raise SystemExit(1)
    print_dry_run(lock, layout)


def cmd_fetch(args: argparse.Namespace) -> None:
    lock, layout, commands, lock_path = load_inputs()
    errors = validate(lock, layout, commands, lock_path)
    if errors:
        for item in errors:
            print(f"error: {item}", file=sys.stderr)
        raise SystemExit(1)
    fetch(lock, cache_dir(args.cache))


def cmd_assemble(args: argparse.Namespace) -> None:
    lock, layout, commands, lock_path = load_inputs()
    errors = validate(lock, layout, commands, lock_path)
    if errors:
        for item in errors:
            print(f"error: {item}", file=sys.stderr)
        raise SystemExit(1)
    assemble(
        lock,
        layout,
        cache_dir(args.cache),
        out_dir(args.out),
        lock_text_digest(lock_path),
    )


def cmd_hash_lock(args: argparse.Namespace) -> None:
    lock_path = CAPSULE_DIR / "packages.lock.json"
    digest = lock_text_digest(lock_path)
    sidecar = lock_path.with_suffix(".sha256")
    sidecar.write_text(f"{digest}  packages.lock.json\n", encoding="utf-8")
    print(digest)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("validate")
    sub.add_parser("dry-run")
    p_fetch = sub.add_parser("fetch")
    p_fetch.add_argument("--cache")
    p_asm = sub.add_parser("assemble")
    p_asm.add_argument("--cache")
    p_asm.add_argument("--out")
    sub.add_parser("hash-lock")
    args = parser.parse_args()
    {
        "validate": cmd_validate,
        "dry-run": cmd_dry_run,
        "fetch": cmd_fetch,
        "assemble": cmd_assemble,
        "hash-lock": cmd_hash_lock,
    }[args.cmd](args)


if __name__ == "__main__":
    main()
