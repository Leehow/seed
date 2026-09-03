#!/usr/bin/env python3
"""select_subset.py -- freeze the pre-registered Terminal-Bench subset.

The secondary models do not run all 89 tasks. Which 30 they run has to be
fixed before any result is looked at, or the subset becomes a result. The rule,
in full:

  1. Read every task.toml in the frozen dataset checkout.
  2. Stratify by `metadata.difficulty`.
  3. Allocate 30 slots proportionally, largest-remainder rounding.
  4. Inside a stratum, order tasks by sha256("alm-v0.1:" + task_name) and take
     the first k. The salt is fixed by this file and never re-rolled.

Also emits the dataset manifest -- task name, difficulty, category, agent and
verifier timeouts, docker image -- so that a later run can prove it used the
same 89 tasks.

    python3 alm/bench/select_subset.py --tasks bench/harbor/tb21/tasks
"""

import argparse
import hashlib
import json
import os
import subprocess
import tomllib

SALT = "alm-v0.1:"
SUBSET_N = 30


def rank(name):
    return hashlib.sha256((SALT + name).encode()).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--tasks", default="bench/harbor/tb21/tasks")
    ap.add_argument("--out", default=os.path.join(here, "subset-30.json"))
    ap.add_argument("--manifest", default=os.path.join(here, "dataset-manifest.json"))
    a = ap.parse_args()

    tasks = []
    for d in sorted(os.listdir(a.tasks)):
        path = os.path.join(a.tasks, d, "task.toml")
        if not os.path.exists(path):
            continue
        with open(path, "rb") as fh:
            t = tomllib.load(fh)
        tasks.append({
            "dir": d,
            "name": t["task"]["name"],
            "difficulty": t["metadata"].get("difficulty", "unknown"),
            "category": t["metadata"].get("category", "unknown"),
            "agent_timeout_sec": t.get("agent", {}).get("timeout_sec"),
            "verifier_timeout_sec": t.get("verifier", {}).get("timeout_sec"),
            "docker_image": t.get("environment", {}).get("docker_image"),
            "rank": rank(d),
        })

    try:
        commit = subprocess.run(["git", "-C", os.path.dirname(a.tasks.rstrip("/")),
                                 "rev-parse", "HEAD"],
                                capture_output=True, text=True).stdout.strip()
    except OSError:
        commit = ""

    strata = {}
    for t in tasks:
        strata.setdefault(t["difficulty"], []).append(t)

    n = len(tasks)
    quotas, remainders = {}, {}
    for k, group in strata.items():
        exact = SUBSET_N * len(group) / n
        quotas[k] = int(exact)
        remainders[k] = exact - int(exact)
    while sum(quotas.values()) < SUBSET_N:
        k = max(remainders, key=lambda x: (remainders[x], x))
        quotas[k] += 1
        remainders[k] = -1

    subset = []
    for k in sorted(strata):
        picked = sorted(strata[k], key=lambda t: t["rank"])[:quotas[k]]
        subset += [t["dir"] for t in picked]
    subset.sort()

    with open(a.manifest, "w") as fh:
        json.dump({"dataset": "terminal-bench/terminal-bench-2-1",
                   "checkout_commit": commit, "count": len(tasks),
                   "difficulty_counts": {k: len(v) for k, v in sorted(strata.items())},
                   "tasks": tasks}, fh, indent=1)
    with open(a.out, "w") as fh:
        json.dump({"salt": SALT, "n": SUBSET_N, "rule": "proportional by difficulty, "
                   "largest remainder; within stratum ordered by sha256(salt+dir)",
                   "quotas": quotas, "checkout_commit": commit,
                   "tasks": subset}, fh, indent=1)

    print("dataset %d tasks, commit %s" % (len(tasks), commit[:12] or "unknown"))
    print("quotas:", json.dumps(quotas, sort_keys=True))
    print("subset (%d):" % len(subset))
    for t in subset:
        print("  " + t)


if __name__ == "__main__":
    main()
