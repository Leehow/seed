#!/usr/bin/env python3
"""run.py -- the minimality experiment.

    python3 alm/witness/run.py --policy oracle --kernels py,sh,sql,asm
    python3 alm/witness/run.py --policy live --kernels py --repeats 1 --limit 5

Cross every witness family with every ablation arm. With `--policy oracle` the
numbers are the information ceiling of each arm: no API, no model variance, and
the failures are the arm's, not the model's. With `--policy live` the same
matrix runs against a real endpoint, which is where the ceiling gets tested
against a model that also has to notice the information is missing.
"""

import argparse
import json
import os
import random
import sys
import time
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ALM = os.path.dirname(HERE)
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(ALM, "adapter"))

import tasks                                              # noqa: E402
from adapter import Adapter, oracle_policy, make_live_policy   # noqa: E402
from prompts import PROTOCOLS                                  # noqa: E402

ARMS = {
    "full":          {"ALM_STEPS": "8"},
    "no_feedback":   {"ALM_STEPS": "8", "ALM_FEEDBACK": "0"},
    "no_history":    {"ALM_STEPS": "8", "ALM_HISTORY_MAX": "0"},
    "one_shot":      {"ALM_STEPS": "1"},
    "fixed_horizon": {"ALM_STEPS": "8", "ALM_ALLOW_HALT": "0"},
    # only meaningful under fault injection: what the two recovery rules buy
    "no_repair":     {"ALM_STEPS": "8", "ALM_REPAIRS": "0"},
    "no_retry":      {"ALM_STEPS": "8", "ALM_RETRIES": "0"},
    "no_recovery":   {"ALM_STEPS": "8", "ALM_REPAIRS": "0", "ALM_RETRIES": "0"},
}


def kernel_argv(kid):
    with open(os.path.join(ALM, "kernels", "registry.json")) as fh:
        spec = json.load(fh)[kid]
    return [a.replace("KERNELS", os.path.join(ALM, "kernels")) for a in spec["argv"]]


class FaultyEnv:
    """eps with an unreliable world: tools time out or fail at rate lambda."""

    def __init__(self, inner, rate, seed):
        self.inner = inner
        self.rate = rate
        self.rng = random.Random(seed * 7919 + 13)
        self.injected = 0

    def __getattr__(self, name):
        return getattr(self.inner, name)

    def call(self, tool, arg):
        if self.rate and self.rng.random() < self.rate:
            self.injected += 1
            self.inner.calls.append((tool, "[injected fault]"))
            if self.rng.random() < 0.5:
                return ("timeout", -1, "")
            return ("error", 1, "E_INJECTED: transient infrastructure failure")
        return self.inner.call(tool, arg)


def faulty_policy(inner, rate, seed):
    """mu with an unreliable transport and an unreliable formatter."""
    rng = random.Random(seed * 104729 + 7)

    def wrapped(ad, eff):
        if rate and rng.random() < rate:
            return ("transport", "injected_http_500") if rng.random() < 0.5 \
                else ("invalid", "injected_bad_json")
        return inner(ad, eff)
    return wrapped


def one_run(job):
    fam, inst, seed, arm, kid, argv, policy, rep, faults, model = job
    base = tasks.FAMILIES[fam](seed + rep * 100000)
    env = FaultyEnv(base, faults, seed + rep) if faults else base
    ad = Adapter(argv, env,
                 faulty_policy(policy, faults, seed + rep) if faults else policy,
                 kernel_env=ARMS[arm], duplicate_rate=faults,
                 seed=seed + rep)
    r = ad.run()
    final = r["final"] or {}
    return {"family": fam, "instance": inst, "seed": seed, "arm": arm,
            "kernel": kid, "model": model, "rep": rep, "faults": faults,
            "success": r["success"],
            "outcome": final.get("outcome"), "reason": final.get("reason"),
            "steps_used": final.get("steps_used"), "model_calls": r["model_calls"],
            "tool_calls": r["tool_calls"], "invalids": r["invalids"],
            "transport_errors": r["transport_errors"], "capped": r["capped"],
            "duplicates_sent": r["duplicates_sent"],
            "duplicate_side_effects": r["duplicate_side_effects"],
            "injected_tool_faults": getattr(env, "injected", 0),
            "model_seconds": r["model_seconds"], "tool_seconds": r["tool_seconds"],
            "orchestration_seconds": r["orchestration_seconds"],
            "prompt_tokens": r["prompt_tokens"],
            "completion_tokens": r["completion_tokens"],
            "reasoning_tokens": r["reasoning_tokens"],
            "seconds": r["seconds"], "exit": r["exit"], "stderr": r["stderr"]}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--policy", default="oracle", choices=["oracle", "live"])
    ap.add_argument("--kernels", default="py")
    ap.add_argument("--arms", default="all")
    ap.add_argument("--families", default="all")
    ap.add_argument("--per-family", type=int, default=50)
    ap.add_argument("--limit", type=int, default=0, help="cap instances per family")
    ap.add_argument("--repeats", type=int, default=1)
    ap.add_argument("--concurrency", type=int, default=8)
    ap.add_argument("--faults", type=float, default=0.0,
                    help="inject model, tool and redelivery faults at this rate")
    ap.add_argument("--out", default="")
    ap.add_argument("--dotenv", default=os.path.join(ALM, "..", ".env"))
    ap.add_argument("--model", default="grok-low",
                    help="entry in adapter/models.json")
    a = ap.parse_args()

    arms = list(ARMS) if a.arms == "all" else a.arms.split(",")
    fams = sorted(tasks.FAMILIES) if a.families == "all" else a.families.split(",")
    kids = a.kernels.split(",")

    if a.policy == "oracle":
        policy = oracle_policy
        client = None
    else:
        from model_live import Client
        client = Client(dotenv=a.dotenv, name=a.model)
        policy = make_live_policy(client)
        print(json.dumps(client.describe()), file=sys.stderr)

    inst = [i for i in tasks.instances(a.per_family) if i[0] in fams]
    if a.limit:
        keep, seen = [], {}
        for row in inst:
            seen[row[0]] = seen.get(row[0], 0) + 1
            if seen[row[0]] <= a.limit:
                keep.append(row)
        inst = keep

    jobs = []
    for kid in kids:
        argv = kernel_argv(kid)
        for arm in arms:
            for fam, iid, seed in inst:
                for rep in range(a.repeats):
                    jobs.append((fam, iid, seed, arm, kid, argv, policy, rep,
                                 a.faults, a.model if a.policy == "live" else "oracle"))

    tag = a.policy if a.policy == "oracle" else "live-%s" % a.model
    out = a.out or os.path.join(HERE, "results-%s.jsonl" % tag)
    t0 = time.time()
    rows = []
    with ThreadPoolExecutor(max_workers=a.concurrency) as pool, open(out, "w") as fh:
        for i, r in enumerate(pool.map(one_run, jobs), 1):
            rows.append(r)
            fh.write(json.dumps(r) + "\n")
            if i % 50 == 0 or i == len(jobs):
                sys.stderr.write("\r%d/%d runs  %.0fs" % (i, len(jobs), time.time() - t0))
                sys.stderr.flush()
    sys.stderr.write("\n")

    print("\n%-18s %-14s %6s %6s %7s" % ("family", "arm", "n", "pass", "rate"))
    table = {}
    for r in rows:
        c = table.setdefault((r["family"], r["arm"]), [0, 0])
        c[0] += 1
        c[1] += 1 if r["success"] else 0
    for (fam, arm), (n, p) in sorted(table.items()):
        print("%-18s %-14s %6d %6d %7.3f" % (fam, arm, n, p, p / n))
    if client:
        print("\nmodel %s: %d calls, %d prompt tokens, %d completion tokens, "
              "%d reasoning tokens" % (client.model, client.calls,
                                       client.prompt_tokens,
                                       client.completion_tokens,
                                       client.reasoning_tokens))
        tm = sum(r["model_seconds"] for r in rows)
        tt = sum(r["tool_seconds"] for r in rows)
        to = sum(r["orchestration_seconds"] for r in rows)
        tot = tm + tt + to
        print("time split: model %.1f%%  tool %.1f%%  orchestration %.1f%%"
              % (100 * tm / tot, 100 * tt / tot, 100 * to / tot))
    print("\n%d runs, %.1fs -> %s" % (len(rows), time.time() - t0, out))


if __name__ == "__main__":
    main()
