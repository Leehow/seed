#!/usr/bin/env python3
"""equivalence.py -- the statistics the substrate claim actually needs.

"No significant difference" is not the claim. With 89 tasks and k=1 you cannot
find a difference even when one exists, so a null result there is worth
nothing. The claim is equivalence: the difference between two substrates lies
inside a band declared before the data was seen.

Provides:

  paired_bootstrap   task-clustered bootstrap CI for a difference in rates
  equivalence        TOST-style verdict against a pre-registered delta
  mcnemar_exact      paired discordance test, with Holm across a family
  pass_k             the unbiased "succeeds k times out of k" estimator
  decompose          share of outcome variance attributable to each factor

    python3 alm/stats/equivalence.py --in runs.jsonl --group kernel \
            --unit instance --where arm=full --delta 0.05
"""

import argparse
import itertools
import json
import math
import sys

import numpy as np

DEFAULT_BOOT = 10000
DEFAULT_DELTA = 0.05


def paired_bootstrap(a, b, n_boot=DEFAULT_BOOT, seed=20260828):
    """a, b: per-unit success rates for the same units, in the same order."""
    a, b = np.asarray(a, float), np.asarray(b, float)
    d = a - b
    rng = np.random.default_rng(seed)
    idx = rng.integers(0, len(d), size=(n_boot, len(d)))
    boots = d[idx].mean(axis=1)
    lo, hi = np.percentile(boots, [2.5, 97.5])
    return {"n_units": int(len(d)), "rate_a": float(a.mean()), "rate_b": float(b.mean()),
            "diff": float(d.mean()), "ci95": [float(lo), float(hi)],
            "boot": n_boot}


def equivalence(res, delta=DEFAULT_DELTA):
    lo, hi = res["ci95"]
    res = dict(res, delta=delta)
    if lo >= -delta and hi <= delta:
        res["verdict"] = "equivalent"
    elif lo > delta or hi < -delta:
        res["verdict"] = "different"
    else:
        res["verdict"] = "inconclusive"
    return res


def mcnemar_exact(a, b):
    """a, b: per-unit 0/1 outcomes. Two-sided exact binomial on discordants."""
    a, b = np.asarray(a), np.asarray(b)
    n01 = int(((a == 0) & (b == 1)).sum())
    n10 = int(((a == 1) & (b == 0)).sum())
    n = n01 + n10
    if n == 0:
        return {"b": n10, "c": n01, "p": 1.0}
    k = min(n01, n10)
    tail = sum(math.comb(n, i) for i in range(k + 1)) / (2.0 ** n)
    return {"b": n10, "c": n01, "p": float(min(1.0, 2.0 * tail))}


def holm(pvalues):
    order = sorted(range(len(pvalues)), key=lambda i: pvalues[i])
    m = len(pvalues)
    adjusted = [0.0] * m
    running = 0.0
    for rank, i in enumerate(order):
        val = (m - rank) * pvalues[i]
        running = max(running, min(1.0, val))
        adjusted[i] = running
    return adjusted


def pass_k(successes, trials, k):
    """Unbiased P(all of k independent draws succeed), averaged over units."""
    vals = []
    for c, n in zip(successes, trials):
        if n < k:
            continue
        vals.append(math.comb(c, k) / math.comb(n, k) if c >= k else 0.0)
    return float(np.mean(vals)) if vals else float("nan")


def decompose(rows, factors, outcome="success"):
    """Share of outcome variance explained by each factor alone (eta squared).

    Binary outcomes and a fully crossed design: eta^2 per factor is the between
    group sum of squares over the total, which is what the paper's variance
    figure needs -- 'how much of the win/lose pattern does this factor move'.
    """
    y = np.array([1.0 if r[outcome] else 0.0 for r in rows])
    total = float(((y - y.mean()) ** 2).sum())
    out = {}
    for f in factors:
        levels = sorted({r[f] for r in rows})
        ss = 0.0
        for lv in levels:
            mask = np.array([r[f] == lv for r in rows])
            if mask.sum() == 0:
                continue
            ss += mask.sum() * (y[mask].mean() - y.mean()) ** 2
        out[f] = {"levels": len(levels),
                  "eta2": float(ss / total) if total > 0 else 0.0}
    return {"total_ss": total, "n": len(rows), "factors": out}


# ------------------------------------------------------------------ CLI

def load(path, where):
    rows = [json.loads(l) for l in open(path) if l.strip()]
    for cond in where:
        k, _, v = cond.partition("=")
        rows = [r for r in rows if str(r.get(k)) == v]
    return rows


def per_unit(rows, unit, group):
    """{group: {unit: (successes, trials)}}"""
    table = {}
    for r in rows:
        g = table.setdefault(r[group], {})
        s, n = g.get(r[unit], (0, 0))
        g[r[unit]] = (s + (1 if r["success"] else 0), n + 1)
    return table


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="path", required=True)
    ap.add_argument("--group", default="kernel")
    ap.add_argument("--unit", default="instance")
    ap.add_argument("--where", action="append", default=[])
    ap.add_argument("--delta", type=float, default=DEFAULT_DELTA)
    ap.add_argument("--boot", type=int, default=DEFAULT_BOOT)
    ap.add_argument("--baseline", default="")
    a = ap.parse_args()

    rows = load(a.path, a.where)
    if not rows:
        sys.exit("no rows after filtering")
    table = per_unit(rows, a.unit, a.group)
    groups = sorted(table)
    if a.baseline and a.baseline in groups:
        pairs = [(a.baseline, g) for g in groups if g != a.baseline]
    else:
        pairs = list(itertools.combinations(groups, 2))

    results, pvals = [], []
    for ga, gb in pairs:
        units = sorted(set(table[ga]) & set(table[gb]))
        ra = [table[ga][u][0] / table[ga][u][1] for u in units]
        rb = [table[gb][u][0] / table[gb][u][1] for u in units]
        res = equivalence(paired_bootstrap(ra, rb, a.boot), a.delta)
        res.update({"a": ga, "b": gb})
        mc = mcnemar_exact([1 if x > 0.5 else 0 for x in ra],
                           [1 if x > 0.5 else 0 for x in rb])
        res["mcnemar"] = mc
        pvals.append(mc["p"])
        results.append(res)
    for res, adj in zip(results, holm(pvals)):
        res["mcnemar"]["p_holm"] = adj

    print("%-10s %-10s %6s %6s %8s %-18s %-13s %8s" %
          ("A", "B", "rateA", "rateB", "diff", "95% CI", "verdict", "p_holm"))
    for r in results:
        print("%-10s %-10s %6.3f %6.3f %+8.3f [%+.3f, %+.3f]  %-13s %8.4f" %
              (r["a"], r["b"], r["rate_a"], r["rate_b"], r["diff"],
               r["ci95"][0], r["ci95"][1], r["verdict"], r["mcnemar"]["p_holm"]))

    reps = max(n for g in table.values() for _, n in g.values())
    if reps > 1:
        print("\npass^k by %s" % a.group)
        for g in groups:
            succ = [s for s, _ in table[g].values()]
            tri = [n for _, n in table[g].values()]
            line = "  %-10s" % g
            for k in range(1, reps + 1):
                line += "  pass^%d %.3f" % (k, pass_k(succ, tri, k))
            print(line)

    factors = [f for f in ("kernel", "arm", "family", "model") if f in rows[0]]
    if len(factors) > 1:
        d = decompose(rows, factors)
        print("\nvariance share (eta^2), n=%d" % d["n"])
        for f, v in sorted(d["factors"].items(), key=lambda kv: -kv[1]["eta2"]):
            bar = "#" * int(round(v["eta2"] * 40))
            print("  %-8s %5.3f %s" % (f, v["eta2"], bar))


if __name__ == "__main__":
    main()
