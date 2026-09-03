#!/usr/bin/env python3
"""gate_h3.py -- decide whether the paid H3 arm may launch, without a human.

The deepseek arm burned real money on a configuration whose pathology was
visible in the first few runs. So the full arm is gated on a five-task pilot
and the gate is mechanical: it looks for the three failure shapes we have
actually seen, and refuses on any of them.

Exit 0 = healthy, launch. Exit 1 = refuse, leave it for a human.
"""
import glob, json, os, statistics, sys

job = sys.argv[1] if len(sys.argv) > 1 else "alm/bench/jobs/pilot-qwen"
res = sorted(glob.glob(os.path.join(job, "*__*", "result.json")))
if len(res) < 5:
    print("REFUSE: pilot incomplete (%d/5)" % len(res)); sys.exit(1)

infra = resolved = halted = 0
steps, invalids = [], 0
for p in res:
    d = json.load(open(p))
    exc = (d.get("exception_info") or {}).get("exception_type")
    rew = (d.get("verifier_result") or {}).get("rewards", {}).get("reward")
    if exc in ("RuntimeError", "VerifierTimeoutError", "EnvironmentStartTimeoutError",
               "NetworkConnectionError", "AgentSetupTimeoutError"):
        infra += 1
    if rew == 1.0:
        resolved += 1
    tr = os.path.join(os.path.dirname(p), "agent", "alm-trace.txt")
    if os.path.exists(tr):
        L = [l.strip().split("|") for l in open(tr) if l.strip()]
        if L:
            steps.append(int(L[-1][0]))
            if any(f[4] == "halt" and f[5] == "terminal" for f in L):
                halted += 1
            invalids += sum(1 for f in L if f[3] == "invalid")

med = statistics.median(steps) if steps else 0
print("pilot: resolved %d/5, voluntary halts %d/5, median steps %.0f, "
      "invalid replies %d, infra faults %d" % (resolved, halted, med, invalids, infra))

fail = []
if infra > 1:
    fail.append("infrastructure faults (%d) -- the host, not the model" % infra)
if med >= 75:
    fail.append("median %d steps: the model is looping, as protocol a did" % med)
if halted == 0:
    fail.append("nothing halted voluntarily")
if invalids > 3 * len(res):
    fail.append("%d rejected replies: the parser and the model disagree" % invalids)
if resolved == 0 and halted < 3:
    fail.append("nothing resolved and few clean finishes")

if fail:
    print("REFUSE:"); [print("  - " + f) for f in fail]; sys.exit(1)
print("HEALTHY: launching the full arm")
sys.exit(0)
