#!/usr/bin/env python3
"""collect_tb.py -- turn Harbor trial directories into one analysable file.

    python3 alm/bench/collect_tb.py --jobs alm/bench/jobs --out alm/bench/results-tb.jsonl

Harbor writes one `result.json` per trial. Two kinds of thing end up in there
and they must not be mixed:

  * outcomes that belong to the agent -- it finished and the verifier graded it,
    or it ran out of wall clock, or it exited non-zero. A timeout is a real
    failure and is scored 0, which is what the pre-registration says.
  * outcomes that belong to the machine -- the environment would not build, the
    image would not pull, the verifier itself timed out. These are excluded and
    counted separately, because scoring them 0 would charge the agent for a
    Docker problem and scoring them 1 is absurd.

Which exception falls in which class is decided here, once, and printed with
the results so the split is auditable.
"""

import argparse
import collections
import datetime
import glob
import json
import os
import re

# exceptions that are the agent's own failure -> reward 0
AGENT_FAULT = {"AgentTimeoutError", "NonZeroAgentExitCodeError"}
# exceptions that belong to the harness or the host -> excluded from rates
INFRA_FAULT = {"RuntimeError", "VerifierTimeoutError", "EnvironmentStartTimeoutError",
               "NetworkConnectionError", "EnvironmentBuildTimeoutError"}

JOB_RE = re.compile(r"tb[a-z]*-(?P<scope>[a-z0-9]+)-rep(?P<rep>\d+)-"
                    r"(?P<kernel>py|sh|sql|asm)(?:-(?P<tag>[a-z0-9-]+))?$")
AB_RE = re.compile(r"(?P<scope>ab)-(?P<prompt>[a-z])$")


def seconds(block):
    if not block or not block.get("started_at") or not block.get("finished_at"):
        return None
    fmt = "%Y-%m-%dT%H:%M:%S.%f%z"
    try:
        a = datetime.datetime.strptime(block["started_at"].replace("Z", "+0000"), fmt)
        b = datetime.datetime.strptime(block["finished_at"].replace("Z", "+0000"), fmt)
    except ValueError:
        return None
    return round((b - a).total_seconds(), 2)


def main():
    ap = argparse.ArgumentParser()
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--jobs", default=os.path.join(here, "jobs"))
    ap.add_argument("--scope", default="all",
                    help="'all' for the 89-task arm, 'ab' for the prompt A/B")
    ap.add_argument("--out", default=os.path.join(here, "results-tb.jsonl"))
    ap.add_argument("--discarded", action="store_true",
                    help="collect the discarded arms instead, so the claim that "
                         "they failed on host faults stays checkable after the "
                         "bulky trial directories are left out of the artifact")
    a = ap.parse_args()

    rows = []
    skipped = []
    for job_dir in sorted(glob.glob(os.path.join(a.jobs, "*"))):
        base = os.path.basename(job_dir)
        if base.endswith("-contaminated") != bool(a.discarded):
            # kept as evidence for the discards documented in
            # PREREGISTRATION-v2 s8, never analysed
            skipped.append(base)
            continue
        m = JOB_RE.search(base.replace("-contaminated", "")) or AB_RE.search(base)
        if not m or m.group("scope") != a.scope:
            continue
        rep = int(m.groupdict().get("rep") or 0)
        kernel = m.groupdict().get("kernel")
        for path in sorted(glob.glob(os.path.join(job_dir, "*__*", "result.json"))):
            d = json.load(open(path))
            # the agent's own kwargs are recorded per trial; trust those over
            # anything parsed out of a directory name
            cfgp = os.path.join(os.path.dirname(path), "config.json")
            kw = {}
            if os.path.exists(cfgp):
                kw = (json.load(open(cfgp)).get("agent") or {}).get("kwargs") or {}
            task = d["task_name"].split("/")[-1]
            exc = d.get("exception_info") or {}
            etype = exc.get("exception_type")
            rewards = (d.get("verifier_result") or {}).get("rewards") or {}
            reward = rewards.get("reward")

            if etype in AGENT_FAULT:
                scored, success, outcome = True, False, etype
            elif etype in INFRA_FAULT:
                scored, success, outcome = False, None, "excluded:" + etype
            elif reward is None:
                scored, success, outcome = False, None, "excluded:no_reward"
            else:
                scored, success = True, reward >= 1.0
                outcome = "resolved" if success else "unresolved"

            rows.append({
                "task": task, "instance": task,
                "kernel": kw.get("kernel", kernel), "rep": rep,
                "prompt": kw.get("prompt", "a"), "steps_budget": kw.get("steps"),
                "model_key": kw.get("model", "deepseek-flash"),
                "model": d.get("agent_info", {}).get("model_info", {}).get("name"),
                "scored": scored, "success": bool(success), "reward": reward,
                "outcome": outcome, "exception": etype,
                "agent_seconds": seconds(d.get("agent_execution")),
                "setup_seconds": seconds(d.get("agent_setup")),
            })

    with open(a.out, "w") as fh:
        for r in rows:
            fh.write(json.dumps(r) + "\n")

    kernels = sorted({r["kernel"] for r in rows})
    reps = sorted({r["rep"] for r in rows})
    tasks = sorted({r["task"] for r in rows})
    if skipped:
        print("skipped %d discarded job directories: %s"
              % (len(skipped), ", ".join(sorted(skipped))))
    prompts = sorted({r["prompt"] for r in rows})
    models = sorted({r["model_key"] for r in rows})
    print("%d trials: %d tasks x %d substrates x %d repeats, prompt %s, model %s"
          % (len(rows), len(tasks), len(kernels), len(reps), "/".join(prompts),
             "/".join(models)))

    print("\noutcome split")
    for k, v in collections.Counter(r["outcome"] for r in rows).most_common():
        print("  %-42s %4d" % (k, v))

    print("\nexcluded by repeat (host and harness faults, not the agent's)")
    excl = collections.Counter((r["rep"], r["outcome"]) for r in rows if not r["scored"])
    for (rep, why), n in sorted(excl.items()):
        print("  rep%-2d %-40s %3d" % (rep, why, n))

    if len(prompts) > 1:
        print("\nresolved rate by prompt protocol (scored trials)")
        for pr in prompts:
            sel = [r for r in rows if r["prompt"] == pr and r["scored"]]
            print("  prompt %-2s %.3f (%d/%d)"
                  % (pr, sum(r["success"] for r in sel) / len(sel),
                     sum(r["success"] for r in sel), len(sel)))

    print("\nresolved rate on scored trials")
    print("  %-6s %s" % ("kernel", "  ".join("rep%d" % r for r in reps) + "   all"))
    for k in kernels:
        cells = []
        for rep in reps:
            sel = [r for r in rows if r["kernel"] == k and r["rep"] == rep and r["scored"]]
            cells.append("%.3f" % (sum(r["success"] for r in sel) / len(sel)) if sel else "  -  ")
        allsel = [r for r in rows if r["kernel"] == k and r["scored"]]
        print("  %-6s %s   %.3f (%d/%d)"
              % (k, "  ".join(cells), sum(r["success"] for r in allsel) / len(allsel),
                 sum(r["success"] for r in allsel), len(allsel)))
    print("\n-> %s" % a.out)


if __name__ == "__main__":
    main()
