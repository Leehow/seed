#!/usr/bin/env python3
"""run_local.py -- the local end-to-end task matrix.

    python3 alm/bench/run_local.py --kernels py,sh,sql,asm --repeats 3

Every arm gets the same system prompt, the same two tools, the same step
budget, the same model and the same fresh working directory. The only thing
that varies is which substrate is running kappa.
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ALM = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ALM, "adapter"))

from local_tasks import TASKS                                  # noqa: E402
from adapter import Adapter, make_live_policy                  # noqa: E402
from shell_env import ShellEnv                                 # noqa: E402
from model_live import Client                                  # noqa: E402
from prompts import PROTOCOLS                                  # noqa: E402


def run_one(job):
    task, kid, argv, rep, steps, client, model, prompt = job
    work = tempfile.mkdtemp(prefix="alm-%s-%s-" % (task["id"], kid))
    subprocess.run(["/bin/sh", "-c", task["setup"]], cwd=work,
                   capture_output=True, timeout=60)
    env = ShellEnv(task["instruction"], workdir=work, timeout=60)
    proto = PROTOCOLS[prompt]
    ad = Adapter(argv, env, make_live_policy(client, parse=proto["parse"]),
                 kernel_env={"ALM_STEPS": str(steps)}, obs_cap=8192,
                 system_prompt=proto["system"], render_obs=proto["render_obs"])
    t0 = time.time()
    r = ad.run()
    env.close()
    graded = subprocess.run(["/bin/sh", "-c", task["verify"]], cwd=work,
                            capture_output=True, timeout=60)
    shutil.rmtree(work, ignore_errors=True)
    final = r["final"] or {}
    return {"task": task["id"], "kernel": kid, "rep": rep,
            "instance": task["id"], "model": model, "prompt": prompt,
            "success": graded.returncode == 0,
            "outcome": final.get("outcome"), "reason": final.get("reason"),
            "steps_used": final.get("steps_used"), "model_calls": r["model_calls"],
            "tool_calls": r["tool_calls"], "invalids": r["invalids"],
            "transport_errors": r["transport_errors"],
            "model_seconds": r["model_seconds"], "tool_seconds": r["tool_seconds"],
            "orchestration_seconds": r["orchestration_seconds"],
            "prompt_tokens": r["prompt_tokens"],
            "completion_tokens": r["completion_tokens"],
            "reasoning_tokens": r["reasoning_tokens"],
            "seconds": round(time.time() - t0, 2), "exit": r["exit"]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernels", default="py,sh,sql,asm")
    ap.add_argument("--repeats", type=int, default=3)
    ap.add_argument("--steps", type=int, default=14)
    ap.add_argument("--concurrency", type=int, default=6)
    ap.add_argument("--out", default="")
    ap.add_argument("--dotenv", default=os.path.join(ALM, "..", ".env"))
    ap.add_argument("--model", default="grok-low",
                    help="entry in adapter/models.json")
    ap.add_argument("--prompt", default="a", choices=sorted(PROTOCOLS))
    a = ap.parse_args()

    with open(os.path.join(ALM, "kernels", "registry.json")) as fh:
        registry = json.load(fh)
    client = Client(dotenv=a.dotenv, max_tokens=1200, name=a.model)
    out = a.out or os.path.join(HERE, "results-local-%s.jsonl" % a.model)
    print(json.dumps(client.describe()), file=sys.stderr)

    jobs = []
    for kid in a.kernels.split(","):
        argv = [x.replace("KERNELS", os.path.join(ALM, "kernels"))
                for x in registry[kid]["argv"]]
        for task in TASKS:
            for rep in range(a.repeats):
                jobs.append((task, kid, argv, rep, a.steps, client, a.model,
                             a.prompt))

    rows = []
    t0 = time.time()
    with ThreadPoolExecutor(max_workers=a.concurrency) as pool, open(out, "w") as fh:
        for i, r in enumerate(pool.map(run_one, jobs), 1):
            rows.append(r)
            fh.write(json.dumps(r) + "\n")
            sys.stderr.write("\r%d/%d  %.0fs" % (i, len(jobs), time.time() - t0))
    sys.stderr.write("\n")

    kids = a.kernels.split(",")
    print("\n%-20s %s" % ("task", "  ".join("%6s" % k for k in kids)))
    for task in TASKS:
        cells = []
        for kid in kids:
            sel = [r for r in rows if r["task"] == task["id"] and r["kernel"] == kid]
            cells.append("%6s" % ("%d/%d" % (sum(r["success"] for r in sel), len(sel))))
        print("%-20s %s" % (task["id"], "  ".join(cells)))
    print("%-20s %s" % ("TOTAL", "  ".join(
        "%6.3f" % (sum(r["success"] for r in rows if r["kernel"] == kid) /
                   max(1, len([r for r in rows if r["kernel"] == kid]))) for kid in kids)))
    tm = sum(r["model_seconds"] for r in rows)
    tt = sum(r["tool_seconds"] for r in rows)
    to = sum(r["orchestration_seconds"] for r in rows)
    print("\nmodel %s: %d calls, %d prompt tokens, %d completion tokens, "
          "%d reasoning tokens, %.0fs wall"
          % (client.model, client.calls, client.prompt_tokens,
             client.completion_tokens, client.reasoning_tokens, time.time() - t0))
    print("time split: model %.1f%%  tool %.1f%%  orchestration %.1f%%"
          % (100 * tm / (tm + tt + to), 100 * tt / (tm + tt + to),
             100 * to / (tm + tt + to)))
    print("-> %s" % out)


if __name__ == "__main__":
    main()
