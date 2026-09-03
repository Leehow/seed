#!/usr/bin/env python3
"""measure.py -- footprint, startup, throughput and memory for each kernel.

Two sizes are reported for every kernel, and the paper must quote both:

  kernel-only        the bytes that implement kappa
  trusted computing  everything that has to exist for those bytes to run --
  base (TCB)         interpreter or engine, plus its linked libraries

Quoting only the first is how an assembly kernel gets described as "a 9 KB
agent" while curl, libsystem and a JSON parser sit underneath it. Quoting only
the second hides the thing the paper is actually about.

Lines of code are reported last and with a warning: one line of SQL, shell and
assembly are not the same unit. The substrate-independent complexity numbers
are the count of ALM transition rules and state fields, which are fixed by the
specification and identical in all four kernels.

    python3 alm/systems/measure.py --startup 200 --transitions 100000
"""

import argparse
import gzip
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ALM = os.path.dirname(HERE)
KERNELS = os.path.join(ALM, "kernels")

# Fixed by ALM v0.1 and identical in every kernel. RULES counts the transition
# rules of s4.2-s4.5 plus the ext halt-refusal rule; start and the two ignore
# rules of s4.6 are not counted here (the coverage table lists all twelve).
# STATE_FIELDS counts mutable control state: B, Q and R minus the terminal
# outcome/reason/status triple, which is written once.
ALM_RULES = 9
ALM_STATE_FIELDS = 13

COMMENT = {".py": r"^\s*#", ".sh": r"^\s*#", ".sql": r"^\s*--", ".s": r"^\s*(//|/\*)"}


def logical_loc(path):
    ext = os.path.splitext(path)[1]
    pat = re.compile(COMMENT.get(ext, r"^\s*#"))
    n = 0
    for line in open(path, errors="replace"):
        if line.strip() and not pat.match(line):
            n += 1
    return n


def gz(path):
    with open(path, "rb") as fh:
        return len(gzip.compress(fh.read(), 9))


def linked_libs(binary):
    try:
        out = subprocess.run(["otool", "-L", binary], capture_output=True,
                             text=True, timeout=20).stdout
    except (OSError, subprocess.SubprocessError):
        return []
    libs = []
    for line in out.splitlines()[1:]:
        m = re.match(r"\s+(\S+)", line)
        if m:
            libs.append(m.group(1))
    return libs


def real_size(path):
    """dyld shared-cache members have no file on disk; report what exists."""
    try:
        return os.path.getsize(path)
    except OSError:
        return 0


def dir_size(path):
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            try:
                total += os.path.getsize(os.path.join(root, f))
            except OSError:
                pass
    return total


def tcb_for(kid):
    """Everything that must exist for this kernel's bytes to execute.

    Libraries that live in the macOS dyld shared cache have no file on disk and
    measure 0 here; the shell and assembly numbers are understated by libSystem
    for that reason, and the report says so rather than pretending otherwise.
    """
    if kid in ("py", "sql"):
        exe = shutil.which("python3")
    elif kid == "sh":
        exe = "/bin/sh"
    else:
        exe = os.path.join(KERNELS, "museed-arm64")
    parts = {os.path.realpath(exe): real_size(exe)}
    for lib in linked_libs(exe):
        parts.setdefault(lib, real_size(lib))
    if kid in ("py", "sql"):
        import sysconfig
        libdir = sysconfig.get_config_var("LIBDIR") or ""
        ldlib = sysconfig.get_config_var("LDLIBRARY") or ""
        cand = os.path.join(libdir, ldlib)
        if ldlib and os.path.exists(cand):
            parts.setdefault(cand, real_size(cand))
        # only the stdlib this kernel actually imports, not the whole install:
        # a conda lib/python3.13 tree with site-packages is gigabytes and none
        # of it is required by 200 lines that use os and sys
        mods = "os,sys" if kid == "py" else "os,sys,sqlite3"
        for path, size in py_import_footprint(mods):
            parts.setdefault(path, size)
    return parts


def py_import_footprint(modules):
    """File sizes of everything CPython loads to import `modules`."""
    code = ("import %s, sys, os, json\n"
            "out=[]\n"
            "for m in sys.modules.values():\n"
            "    f=getattr(m,'__file__',None)\n"
            "    if f and os.path.exists(f): out.append([f,os.path.getsize(f)])\n"
            "print(json.dumps(out))" % modules)
    try:
        res = subprocess.run([shutil.which("python3") or "python3", "-c", code],
                             capture_output=True, text=True, timeout=60)
        return json.loads(res.stdout)
    except Exception:
        return []


def events_halt():
    return '{"v":1,"t":"model_response","eid":"e1","status":"ok","action":"halt","halt":"ok","arg_ref":"m1"}\n'


def events_stream(n_transitions):
    """n alternating tool/observation events; eids are deterministic."""
    out = []
    for i in range(1, n_transitions + 1):
        if i % 2 == 1:
            out.append('{"v":1,"t":"model_response","eid":"e%d","status":"ok",'
                       '"action":"tool","tool":"shell","arg_ref":"m%d"}' % (i, i))
        else:
            out.append('{"v":1,"t":"tool_response","eid":"e%d","status":"ok","exit":0,'
                       '"obs_ref":"o%d","nbytes":10,"truncated":0}' % (i, i))
    return "\n".join(out) + "\n"


def argv_for(kid, registry):
    return [a.replace("KERNELS", KERNELS) for a in registry[kid]["argv"]]


def time_startup(argv, reps, payload):
    env = dict(os.environ, ALM_TRACE=os.devnull, ALM_STEPS="4")
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as fh:
        fh.write(payload)
        path = fh.name
    samples = []
    devnull = open(os.devnull, "wb")
    for _ in range(reps):
        with open(path) as inp:
            t0 = time.perf_counter()
            subprocess.run(argv, stdin=inp, stdout=devnull, stderr=devnull, env=env)
            samples.append((time.perf_counter() - t0) * 1000.0)
    devnull.close()
    os.unlink(path)
    first = samples[0]
    samples = sorted(samples)

    def pct(p):
        return round(samples[min(len(samples) - 1, int(len(samples) * p))], 3)
    # `first_ms` is the one invocation whose pages, dyld caches and SQLite
    # schema are not warm yet; everything after it is steady state
    return {"n": reps, "first_ms": round(first, 3), "p50_ms": pct(0.50),
            "p95_ms": pct(0.95), "p99_ms": pct(0.99),
            "min_ms": round(samples[0], 3)}


def time_throughput(argv, n_transitions):
    env = dict(os.environ, ALM_TRACE=os.devnull, ALM_STEPS=str(n_transitions),
               ALM_HISTORY_MAX="4")
    with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as fh:
        fh.write(events_stream(n_transitions))
        path = fh.name
    devnull = open(os.devnull, "wb")
    with open(path) as inp:
        t0 = time.perf_counter()
        proc = subprocess.run(["/usr/bin/time", "-l"] + argv, stdin=inp,
                              stdout=devnull, stderr=subprocess.PIPE, env=env)
        wall = time.perf_counter() - t0
    devnull.close()
    os.unlink(path)
    err = proc.stderr.decode(errors="replace")
    m = re.search(r"(\d+)\s+maximum resident set size", err)
    rss = int(m.group(1)) if m else 0
    return {"transitions": n_transitions, "wall_s": round(wall, 3),
            "per_transition_us": round(wall * 1e6 / n_transitions, 3),
            "transitions_per_s": int(n_transitions / wall),
            "peak_rss_bytes": rss}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--startup", type=int, default=200)
    ap.add_argument("--transitions", type=int, default=100000)
    ap.add_argument("--kernels", default="py,sh,sql,asm")
    ap.add_argument("--out", default=os.path.join(HERE, "results.json"))
    ap.add_argument("--no-timing", action="store_true",
                    help="refresh footprint and TCB only, keep recorded timings")
    a = ap.parse_args()

    with open(os.path.join(KERNELS, "registry.json")) as fh:
        registry = json.load(fh)

    report = {"host": {"uname": subprocess.run(["uname", "-mrs"], capture_output=True,
                                               text=True).stdout.strip(),
                       "python": sys.version.split()[0]},
              "alm": {"rules": ALM_RULES, "state_fields": ALM_STATE_FIELDS},
              "kernels": {}}

    adapter = os.path.join(ALM, "adapter", "adapter.py")
    report["shared_adapter"] = {"bytes": os.path.getsize(adapter),
                                "logical_loc": logical_loc(adapter),
                                "note": "identical for every kernel; cancels in comparisons"}

    for kid in a.kernels.split(","):
        spec = registry[kid]
        files = [os.path.join(KERNELS, f) for f in spec["kernel_files"]]
        entry = {"name": spec["name"], "substrate": spec["substrate"],
                 "kernel_only": {
                     "files": [os.path.basename(f) for f in files],
                     "source_bytes": sum(os.path.getsize(f) for f in files),
                     "gzip_bytes": sum(gz(f) for f in files),
                     "logical_loc": sum(logical_loc(f) for f in files)}}
        if kid == "asm":
            binary = os.path.join(KERNELS, "museed-arm64")
            if os.path.exists(binary):
                stripped = binary + ".stripped"
                subprocess.run(["strip", "-o", stripped, binary],
                               capture_output=True)
                entry["kernel_only"]["binary_bytes"] = os.path.getsize(binary)
                entry["kernel_only"]["stripped_binary_bytes"] = os.path.getsize(stripped)
                os.unlink(stripped)
        if kid == "sql":
            pump = os.path.join(KERNELS, "sqlpump.py")
            entry["kernel_only"]["pump_bytes"] = os.path.getsize(pump)
            entry["kernel_only"]["pump_logical_loc"] = logical_loc(pump)

        tcb = tcb_for(kid)
        entry["tcb"] = {"components": len(tcb),
                        "resolvable_bytes": sum(tcb.values()),
                        "parts": {os.path.basename(k): v for k, v in sorted(tcb.items())}}

        argv = argv_for(kid, registry)
        if a.no_timing and os.path.exists(a.out):
            prev = json.load(open(a.out))["kernels"].get(kid, {})
            entry["startup"] = prev.get("startup", {})
            entry["throughput"] = prev.get("throughput", {})
        else:
            entry["startup"] = time_startup(argv, a.startup, events_halt())
            entry["throughput"] = time_throughput(argv, a.transitions)
        report["kernels"][kid] = entry
        print("%-4s kernel %7d B (%5d B gz, %4d loc)  start p50 %7.2f ms  "
              "%8d transitions/s  rss %8d B"
              % (kid, entry["kernel_only"]["source_bytes"],
                 entry["kernel_only"]["gzip_bytes"],
                 entry["kernel_only"]["logical_loc"],
                 entry["startup"]["p50_ms"],
                 entry["throughput"]["transitions_per_s"],
                 entry["throughput"]["peak_rss_bytes"]))

    with open(a.out, "w") as fh:
        json.dump(report, fh, indent=1)
    print("\n-> %s" % a.out)


if __name__ == "__main__":
    main()
