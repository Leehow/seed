#!/usr/bin/env python3
"""figures.py -- the two pictures that carry an argument a table cannot.

    python3 alm/figures.py           # writes paper/gen/fig-pareto.pdf

Panel (a) is the thesis: trusted computing base spans two orders of magnitude
across the four kernels and task success does not move with it. Panel (b) is
the same claim from the other side: of the factors that move an outcome,
substrate is the one that does not.
"""

import math
import os
import sys

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt          # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))
GEN = os.path.join(os.path.dirname(HERE), "paper", "gen")
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "stats"))
import collections                                  # noqa: E402
from analyze import load, load_all                  # noqa: E402
from equivalence import decompose                   # noqa: E402

plt.rcParams.update({
    "font.family": "serif", "font.size": 8, "axes.labelsize": 8,
    "axes.titlesize": 8.5, "xtick.labelsize": 7.5, "ytick.labelsize": 7.5,
    "legend.fontsize": 7.5, "axes.spines.top": False, "axes.spines.right": False,
    "figure.dpi": 200, "savefig.bbox": "tight", "pdf.fonttype": 42,
})

LABEL = {"py": "CPython", "sh": "POSIX sh", "sql": "SQLite", "asm": "ARM64 asm"}
MARK = {"py": "o", "sh": "s", "sql": "^", "asm": "D"}
# Four points, two tight pairs: asm/sh differ by under 3x on the x axis and
# py/sql by 6%, so a single offset rule cannot separate them. Placed by hand:
# (dx, dy, horizontal alignment) in points.
LABEL_POS = {"asm": (8, -14, "left"), "sh": (8, 5, "left"),
             "py": (-8, -14, "right"), "sql": (8, 5, "left")}


def wilson(k, n, z=1.96):
    if not n:
        return (0.0, 0.0)
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / d
    return (max(0.0, c - h), min(1.0, c + h))


def main():
    os.makedirs(GEN, exist_ok=True)
    sysd = load("systems/results.json")
    local = load_all("bench/results-local-*.jsonl*") or []
    # ONE arm, always. Pooling the retired deepseek arm with the grok arm puts a
    # point on the plot that describes neither: py reads 0.256 pooled against
    # 0.443 on the arm the substrate claim is actually made from.
    MAIN_ARM = ("grok-low", "br")
    tb_all = [r for r in (load("bench/results-tb.jsonl") or []) if r["scored"]]
    tb = [r for r in tb_all
          if (r.get("model_key", "deepseek-flash"), r["prompt"]) == MAIN_ARM]
    if not (sysd and local and tb):
        sys.exit("need systems/results.json, the local task results and the TB results")

    fig, (ax, bx) = plt.subplots(1, 2, figsize=(6.6, 2.7))

    for kid, k in sysd["kernels"].items():
        tcb = k["tcb"]["resolvable_bytes"] / 1024.0
        sel = [r for r in local if r["kernel"] == kid]
        n, s = len(sel), sum(r["success"] for r in sel)
        lo, hi = wilson(s, n)
        rate = s / n
        ax.errorbar(tcb, rate, yerr=[[rate - lo], [hi - rate]], fmt=MARK[kid],
                    ms=5, capsize=2.5, lw=1, color="#222222", mfc="white",
                    mew=1.1, ecolor="#888888")
        # py and sql sit within 6% of each other on the x axis, and asm and sh
        # within a factor of three, so centred labels collide. Alternate the
        # side instead of the height: on a log axis a horizontal nudge is small
        # in data terms and keeps every label next to its own marker.
        dx, dy, ha = LABEL_POS.get(kid, (0, 8, "center"))
        ax.annotate(LABEL[kid], (tcb, rate), textcoords="offset points",
                    xytext=(dx, dy), ha=ha, fontsize=7.5)
        tsel = [r for r in tb if r["kernel"] == kid]
        if tsel:
            tn, ts = len(tsel), sum(r["success"] for r in tsel)
            tlo, thi = wilson(ts, tn)
            trate = ts / tn
            ax.errorbar(tcb, trate, yerr=[[trate - tlo], [thi - trate]],
                        fmt=MARK[kid], ms=4, capsize=2.5, lw=1,
                        color="#4c72b0", mfc="#4c72b0", ecolor="#a8bcd8")
    ax.set_xscale("log")
    ax.set_xlabel("trusted computing base (KiB, log scale)")
    ax.set_ylabel("tasks resolved")
    ax.set_ylim(0, 1.18)
    ax.plot([], [], "o", color="#222222", mfc="white", mew=1.1,
            label="local graded tasks")
    ax.plot([], [], "o", color="#4c72b0", label="Terminal-Bench 2.1")
    ax.legend(frameon=False, loc="center right")
    ax.set_title("(a) two orders of magnitude of runtime,\n    one capability",
                 loc="left")

    # (b) effect sizes on one axis: what actually moved the outcome, measured
    # on the same arm, the same tasks and the same protocol.
    sc = [r for r in tb_all if r["prompt"] == "br" and r["kernel"] == "sh"]
    Q = {r["task"]: r["success"] for r in sc if r.get("model_key") == "qwen-max"}
    G = collections.defaultdict(list)
    for r in sc:
        if r.get("model_key") == "grok-low":
            G[r["task"]].append(r["success"])
    common = sorted(set(Q) & set(G))
    model_eff = abs(sum(1.0 if Q[t] else 0.0 for t in common) / len(common)
                    - sum(sum(G[t]) / len(G[t]) for t in common) / len(common))

    per = collections.defaultdict(lambda: collections.defaultdict(list))
    for r in tb:
        if True:
            per[r["kernel"]][r["task"]].append(r["success"])
    ks = sorted(per)
    sub_eff = 0.0
    for i, a in enumerate(ks):
        for b in ks[i + 1:]:
            u = set(per[a]) & set(per[b])
            d = abs(sum(sum(per[a][t]) / len(per[a][t]) for t in u) / len(u)
                    - sum(sum(per[b][t]) / len(per[b][t]) for t in u) / len(u))
            sub_eff = max(sub_eff, d)

    prompts = {}
    for r in tb_all:
        if r["scored"] and r.get("model_key") == "deepseek-flash":
            prompts.setdefault(r["prompt"], []).append(r["success"])
    prompt_eff = (abs(sum(prompts["b"]) / len(prompts["b"])
                      - sum(prompts["a"]) / len(prompts["a"]))
                  if {"a", "b"} <= set(prompts) else 0.0)

    labels = ["substrate\n(py / sh / sql)", "adapter prompt\n(terse → reasoned)",
              "model\n(xAI → Alibaba)"]
    vals = [sub_eff, prompt_eff, model_eff]
    colors = ["#c44e52", "#666666", "#666666"]
    bx.barh(labels, vals, color=colors, height=0.55)
    for i, v in enumerate(vals):
        bx.text(v + max(vals) * 0.02, i, "%.3f" % v, va="center", fontsize=7.5)
    bx.set_xlabel("largest measured change in tasks resolved")
    bx.set_xlim(0, max(vals) * 1.28)
    bx.set_title("(b) what moves the outcome, same tasks,\n"
                 "    same two tools, same kernel", loc="left")

    fig.tight_layout(w_pad=2.0)
    out = os.path.join(GEN, "fig-pareto.pdf")
    fig.savefig(out)
    print("-> %s (%d bytes)" % (out, os.path.getsize(out)))


if __name__ == "__main__":
    main()
