#!/usr/bin/env python3
"""Per-trial statistics recomputed from the canonical traces.

The scored results file records the outcome of a trial, not its shape. Two
claims in the paper are about shape -- how many steps a run spent and whether
it stopped because the model said so or because the budget ran out -- so they
are derived here, from the same alm-trace.txt the specification defines, and
published alongside the results rather than quoted from a working note.

A run is `halt` if the model's last recorded action was its own halt verdict,
`budget` if the trace ends with steps_left at 0, and `abort` otherwise (repair
or transport budget exhausted).
"""
import json
import os
import sys
import collections
import statistics

JOBS = os.path.join(os.path.dirname(__file__), "jobs")
OUT = os.path.join(os.path.dirname(__file__), "trace-stats.jsonl")


def read_trace(path):
    steps, actions, ended = 0, [], "abort"
    last_left = None
    with open(path) as fh:
        for line in fh:
            f = line.rstrip("\n").split("|")
            if len(f) < 11:
                continue
            steps = max(steps, int(f[0]))
            if f[4] != "-":
                actions.append(f[4])
            last_left = int(f[6])
            if f[5] == "terminal":
                ended = "halt" if f[4] == "halt" else (
                    "budget" if last_left == 0 else "abort")
    return steps, actions, ended


def main():
    rows = []
    for job in sorted(os.listdir(JOBS)):
        jd = os.path.join(JOBS, job)
        if not os.path.isdir(jd):
            continue
        for trial in sorted(os.listdir(jd)):
            td = os.path.join(jd, trial)
            tr = os.path.join(td, "agent", "alm-trace.txt")
            cf = os.path.join(td, "config.json")
            if not (os.path.exists(tr) and os.path.exists(cf)):
                continue
            cfg = json.load(open(cf))
            kw = cfg["agent"]["kwargs"]
            # The earliest jobs predate the --ak prompt flag and ran on the
            # adapter's default protocol, which was `a`. Record what ran.
            prompt = kw.get("prompt") or "a"
            steps, actions, ended = read_trace(tr)
            rows.append({
                "job": job,
                "task": trial.rsplit("__", 1)[0],
                "kernel": kw.get("kernel"),
                "prompt": prompt,
                "model": cfg["agent"]["model_name"],
                "steps_budget": kw.get("steps"),
                "steps": steps,
                "ended": ended,
                "tool_actions": len(actions),
            })
    with open(OUT, "w") as fh:
        for r in rows:
            fh.write(json.dumps(r, sort_keys=True) + "\n")
    print(f"-> {OUT} ({len(rows)} trials)")
    by = collections.defaultdict(list)
    for r in rows:
        by[(r["model"], r["prompt"])].append(r)
    for k in sorted(by, key=str):
        g = by[k]
        med = statistics.median(r["steps"] for r in g)
        h = sum(1 for r in g if r["ended"] == "halt") / len(g)
        print(f"  {k}: n={len(g)} median steps={med:g} voluntary halt={h:.1%}")


if __name__ == "__main__":
    sys.exit(main())
