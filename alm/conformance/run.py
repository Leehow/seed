#!/usr/bin/env python3
"""run.py -- run every kernel over every conformance case.

    python3 alm/conformance/run.py --kernels py,sh,sql,asm

A case passes for a kernel iff, byte for byte:

  * the effect stream equals the oracle's `expect_effects`
  * the canonical trace equals `expect_trace` (hash equality is reported too)
  * an event marked `expect_effect: false` drew no effect at all
  * the kernel exits 0

Failures are recorded with the first differing line, so a substrate bug points
at a transition rather than at "the trace differs".
"""

import argparse
import json
import os
import select
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ProcessPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ALM = os.path.dirname(HERE)
KERNELS = os.path.join(ALM, "kernels")
READ_TIMEOUT = 20.0


def argv_for(spec):
    return [a.replace("KERNELS", KERNELS) for a in spec["argv"]]


def read_line(proc, buf):
    """Read one \\n-terminated line from proc.stdout with a timeout."""
    deadline = time.time() + READ_TIMEOUT
    while b"\n" not in buf["b"]:
        remaining = deadline - time.time()
        if remaining <= 0:
            return None, buf
        r, _, _ = select.select([proc.stdout], [], [], remaining)
        if not r:
            return None, buf
        chunk = os.read(proc.stdout.fileno(), 65536)
        if not chunk:
            return None, buf
        buf["b"] += chunk
    line, _, rest = buf["b"].partition(b"\n")
    buf["b"] = rest
    return line.decode(), buf


def drain(proc, buf, seconds=0.3):
    deadline = time.time() + seconds
    while True:
        remaining = deadline - time.time()
        if remaining <= 0:
            break
        r, _, _ = select.select([proc.stdout], [], [], remaining)
        if not r:
            break
        chunk = os.read(proc.stdout.fileno(), 65536)
        if not chunk:
            break
        buf["b"] += chunk
    return [l.decode() for l in buf["b"].split(b"\n") if l.strip()]


def run_case(spec, case, extra_env=None):
    with tempfile.NamedTemporaryFile(suffix=".trace", delete=False) as tf:
        trace_path = tf.name
    env = dict(os.environ)
    env.update(case["env"])
    env["ALM_TRACE"] = trace_path
    if extra_env:
        env.update(extra_env)
    t0 = time.time()
    proc = subprocess.Popen(argv_for(spec), stdin=subprocess.PIPE,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
    buf = {"b": b""}
    effects, problems = [], []

    line, buf = read_line(proc, buf)
    if line is None:
        problems.append("no initial effect")
    else:
        effects.append(line)

    for i, ev in enumerate(case["events"]):
        try:
            proc.stdin.write((ev["line"] + "\n").encode())
            proc.stdin.flush()
        except BrokenPipeError:
            problems.append("kernel closed stdin at event %d" % i)
            break
        if ev["expect_effect"]:
            line, buf = read_line(proc, buf)
            if line is None:
                problems.append("event %d: expected an effect, got none (timeout)" % i)
                break
            effects.append(line)

    try:
        proc.stdin.close()
    except BrokenPipeError:
        pass
    leftover = drain(proc, buf)
    if leftover:
        problems.append("unexpected extra effects: %r" % (leftover[:2],))
        effects.extend(leftover)
    try:
        proc.wait(timeout=READ_TIMEOUT)
    except subprocess.TimeoutExpired:
        proc.kill()
        problems.append("kernel did not exit")
    stderr = proc.stderr.read().decode()[:400]
    proc.stderr.close()
    proc.stdout.close()
    elapsed = time.time() - t0

    trace = []
    if os.path.exists(trace_path):
        with open(trace_path) as fh:
            trace = [l.rstrip("\n") for l in fh if l.strip()]
        os.unlink(trace_path)

    if proc.returncode != 0:
        problems.append("exit=%d stderr=%s" % (proc.returncode, stderr.strip()))
    for i, (got, want) in enumerate(zip(effects, case["expect_effects"])):
        if got != want:
            problems.append("effect[%d]\n  want %s\n  got  %s" % (i, want, got))
            break
    if len(effects) != len(case["expect_effects"]):
        problems.append("effect count %d != %d" % (len(effects), len(case["expect_effects"])))
    for i, (got, want) in enumerate(zip(trace, case["expect_trace"])):
        if got != want:
            problems.append("trace[%d]\n  want %s\n  got  %s" % (i, want, got))
            break
    if len(trace) != len(case["expect_trace"]):
        problems.append("trace record count %d != %d" % (len(trace), len(case["expect_trace"])))

    import hashlib
    got_hash = hashlib.sha256("".join(l + "\n" for l in trace).encode()).hexdigest()
    return {"id": case["id"], "category": case["category"],
            "ok": not problems, "problems": problems[:3],
            "trace_sha256": got_hash,
            "hash_match": got_hash == case["expect_trace_sha256"],
            "seconds": elapsed}


def _job(args):
    kid, spec, path = args
    with open(path) as fh:
        case = json.load(fh)
    r = run_case(spec, case)
    r["kernel"] = kid
    return r


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernels", default="py,sh")
    ap.add_argument("--cases", default=os.path.join(HERE, "cases"))
    ap.add_argument("--out", default=os.path.join(HERE, "results.json"))
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--filter", default="")
    a = ap.parse_args()

    with open(os.path.join(KERNELS, "registry.json")) as fh:
        registry = json.load(fh)
    paths = sorted(os.path.join(a.cases, f) for f in os.listdir(a.cases)
                   if f.endswith(".json") and a.filter in f)

    jobs = []
    for kid in a.kernels.split(","):
        kid = kid.strip()
        if not kid:
            continue
        if kid not in registry:
            sys.exit("unknown kernel %r" % kid)
        jobs += [(kid, registry[kid], p) for p in paths]

    t0 = time.time()
    with ProcessPoolExecutor(max_workers=a.jobs) as pool:
        results = list(pool.map(_job, jobs, chunksize=4))
    wall = time.time() - t0

    summary = {}
    for r in results:
        s = summary.setdefault(r["kernel"], {})
        c = s.setdefault(r["category"], {"pass": 0, "fail": 0})
        c["pass" if r["ok"] else "fail"] += 1

    hashes = {}
    for r in results:
        hashes.setdefault(r["id"], {})[r["kernel"]] = r["trace_sha256"]
    disagreements = [cid for cid, h in hashes.items() if len(set(h.values())) > 1]

    payload = {"kernels": a.kernels.split(","), "cases": len(paths),
               "wall_seconds": round(wall, 2), "summary": summary,
               "cross_kernel_disagreements": disagreements,
               "results": results}
    with open(a.out, "w") as fh:
        json.dump(payload, fh, indent=1)

    print("%-6s %-12s %5s %5s" % ("kernel", "category", "pass", "fail"))
    for kid, cats in summary.items():
        tp = tf = 0
        for cat, c in sorted(cats.items()):
            print("%-6s %-12s %5d %5d" % (kid, cat, c["pass"], c["fail"]))
            tp += c["pass"]; tf += c["fail"]
        print("%-6s %-12s %5d %5d" % (kid, "TOTAL", tp, tf))
    print("cross-kernel trace disagreements: %d" % len(disagreements))
    bad = [r for r in results if not r["ok"]]
    for r in bad[:5]:
        print("\nFAIL %s/%s" % (r["kernel"], r["id"]))
        for p in r["problems"]:
            print("  " + p.replace("\n", "\n  "))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
