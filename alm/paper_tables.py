#!/usr/bin/env python3
"""paper_tables.py -- emit every table and scalar the paper quotes.

    python3 alm/paper_tables.py            # writes paper/gen/*.tex

No number in the paper is typed by hand. Each table is a LaTeX fragment
generated from a results file, and each scalar is a macro; if an experiment is
re-run, the paper changes with it or fails to build.
"""

import collections
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
GEN = os.path.join(ROOT, "paper", "gen")
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "stats"))

from analyze import (ABLATION_ARMS, PREREG_REPS, load, load_all,  # noqa: E402
                     load_live, pairwise, per_unit, rate_cells)
import collections                                              # noqa: E402
from equivalence import (decompose, equivalence, pass_k,        # noqa: E402
                         paired_bootstrap)

MACROS = {}


def mac(name, value):
    MACROS[name] = value


def esc(s):
    """Escape plain text. Strings that already contain LaTeX are left alone."""
    s = str(s)
    if "$" in s or "\\" in s:
        return s
    return (s.replace("_", r"\_").replace("%", r"\%")
            .replace("&", r"\&").replace("^", r"\^{}"))


def tabular(path, spec, header, rows, rules=True):
    out = [r"\begin{tabular}{%s}" % spec, r"\toprule",
           " & ".join(esc(h) for h in header) + r" \\", r"\midrule"]
    for row in rows:
        out.append(" & ".join(str(c) for c in row) + r" \\")
    out += [r"\bottomrule", r"\end{tabular}"]
    with open(os.path.join(GEN, path), "w") as fh:
        fh.write("\n".join(out) + "\n")


def num(x, d=3):
    return ("%%.%df" % d) % x


def main():
    os.makedirs(GEN, exist_ok=True)

    # ---------------- setup ----------------------------------------------
    reg = load("adapter/models.json") or {}
    live = load_live() or []
    sub = load("witness/results-live-substrate.jsonl") or []
    local = load_all("bench/results-local-*.jsonl*") or []
    models = sorted({r.get("model") for r in local + live} - {None, "oracle"})
    tabular("tab-models.tex", "llll", ["key", "vendor", "model id", "decoding"],
            [[esc(m), esc(reg.get(m, {}).get("vendor", "?")),
              r"\texttt{%s}" % esc(reg.get(m, {}).get("model", "?")),
              esc("temperature %s" % reg.get(m, {}).get("temperature") +
                  (", reasoning disabled" if reg.get(m, {}).get("extra") else ""))]
             for m in models])
    mac("nmodels", len(models))

    # ---------------- H1: conformance ------------------------------------
    conf = load("conformance/results.json")
    index = load("conformance/cases.index.json")
    mut = load("conformance/mutants.json")
    if conf:
        cats = sorted({r["category"] for r in conf["results"]})
        rows = []
        for kid in conf["kernels"]:
            cells = []
            for c in cats:
                sel = [r for r in conf["results"]
                       if r["kernel"] == kid and r["category"] == c]
                cells.append("%d/%d" % (sum(r["ok"] for r in sel), len(sel)))
            tot = [r for r in conf["results"] if r["kernel"] == kid]
            cells.append(r"\textbf{%d/%d}" % (sum(r["ok"] for r in tot), len(tot)))
            rows.append([r"\texttt{%s}" % kid] + cells)
        tabular("tab-conformance.tex", "l" + "r" * (len(cats) + 1),
                ["kernel"] + cats + ["total"], rows)
        mac("confcases", conf["cases"])
        mac("confruns", len(conf["results"]))
        mac("confdisagree", len(conf["cross_kernel_disagreements"]))
        mac("confwall", num(conf["wall_seconds"], 1))
    cont = load("conformance/results-container.json")
    cmeta = load("conformance/container-platform.json")
    if cont and cmeta:
        rows = []
        for kid in cont["kernels"]:
            sel = [r for r in cont["results"] if r["kernel"] == kid]
            rows.append([r"\texttt{%s}" % kid,
                         "%d/%d" % (sum(r["ok"] for r in sel), len(sel))])
        tabular("tab-conformance-container.tex", "lr",
                ["kernel", "cases passed"], rows)
        mac("containerplatform", esc(cmeta["platform"]))
        mac("containersqlite", cmeta["sqlite"])
        mac("containerpython", cmeta["python"])
        mac("containerruns", len(cont["results"]))

    if index and index.get("coverage"):
        tabular("tab-coverage.tex", "llrr",
                ["rule", "specification", "trace records", "cases"],
                [[r"\texttt{%s}" % esc(k), esc(v["label"]), v["records"], v["cases"]]
                 for k, v in index["coverage"].items()])
    if mut:
        applied = [m for m in mut["mutants"] if m.get("applied")]
        tabular("tab-mutants.tex", "llrr",
                ["mutation", "what it breaks", "cases failing", "rate"],
                [[r"\texttt{%s}" % esc(m["name"]), esc(m["description"]),
                  m["cases_failed"], "%.1f\\%%" % (100 * m["detection_rate"])]
                 for m in applied])
        mac("muttotal", len(applied))
        mac("mutcaught", len(applied) - mut["undetected"])
        mac("mutmin", min(m["cases_failed"] for m in applied))

    # ---------------- H4: witness ----------------------------------------
    oracle = load("witness/results-oracle.jsonl") or []
    fams = sorted({r["family"] for r in oracle or live})

    def arm_rows(rows):
        cells = rate_cells(rows, "family", "arm")
        out = []
        for fam in fams:
            line = [r"\texttt{%s}" % esc(fam)]
            for arm in ABLATION_ARMS:
                n, p = cells.get((fam, arm), [0, 0])
                line.append(num(p / n, 2) if n else "--")
            out.append(line)
        return out

    if oracle:
        tabular("tab-witness-oracle.tex", "l" + "r" * len(ABLATION_ARMS),
                ["family"] + [a.replace("_", " ") for a in ABLATION_ARMS],
                arm_rows([r for r in oracle if r["arm"] in ABLATION_ARMS]))
        res = pairwise([r for r in oracle if r["arm"] in ABLATION_ARMS],
                       "arm", "instance", baseline="full")
        tabular("tab-arm-equiv.tex", "lrrlll",
                ["arm", "rate", "diff vs full", "95\\% CI", "verdict", "p (Holm)"],
                [[esc(r["b"]), num(r["rate_b"]), "%+.3f" % r["diff"],
                  "[%+.3f, %+.3f]" % tuple(r["ci95"]), r["verdict"],
                  "%.3g" % r["mcnemar"]["p_holm"]] for r in res])
        d = decompose([r for r in oracle if r["arm"] in ABLATION_ARMS],
                      ["arm", "family", "kernel"])
        for k, v in d["factors"].items():
            mac("oracleeta" + k, num(v["eta2"]))
    if live:
        blocks = []
        for m in sorted({r["model"] for r in live}):
            sel = [r for r in live if r["model"] == m and r["arm"] in ABLATION_ARMS]
            if not sel:
                continue
            n_per = len({r["instance"] for r in sel}) // max(1, len(fams))
            blocks.append((m, n_per, arm_rows(sel)))
        rows = []
        for m, n_per, block in blocks:
            rows.append([r"\multicolumn{%d}{l}{\emph{%s}, %d instances per family}"
                         % (len(ABLATION_ARMS) + 1, esc(m), n_per)] )
            rows += block
        # multicolumn rows need padding removed; write manually
        out = [r"\begin{tabular}{l%s}" % ("r" * len(ABLATION_ARMS)), r"\toprule",
               " & ".join(["family"] + [esc(a.replace("_", " "))
                                        for a in ABLATION_ARMS]) + r" \\"]
        for i, (m, n_per, block) in enumerate(blocks):
            out.append(r"\midrule")
            out.append(r"\multicolumn{%d}{l}{\emph{%s}, %d instances per family} \\"
                       % (len(ABLATION_ARMS) + 1, esc(m), n_per))
            for row in block:
                out.append(" & ".join(row) + r" \\")
        out += [r"\bottomrule", r"\end{tabular}"]
        with open(os.path.join(GEN, "tab-witness-live.tex"), "w") as fh:
            fh.write("\n".join(out) + "\n")
        mac("livecapped", sum(1 for r in live if r.get("capped")))
        mac("liveruns", len(live))

    # ---------------- H2: substrate --------------------------------------
    if sub:
        kernels = sorted({r["kernel"] for r in sub})
        reps = max(collections.Counter(
            (r["kernel"], r["instance"]) for r in sub).values())
        rows = []
        for kid in kernels:
            table = per_unit([r for r in sub if r["kernel"] == kid],
                             "instance", "kernel")[kid]
            succ = [s for s, _ in table.values()]
            tri = [n for _, n in table.values()]
            rows.append([r"\texttt{%s}" % kid, sum(tri), num(sum(succ) / sum(tri)),
                         num(pass_k(succ, tri, 1)),
                         num(pass_k(succ, tri, min(reps, 3)))])
        tabular("tab-substrate-passk.tex", "lrrrr",
                ["kernel", "runs", "rate", "pass$^1$", "pass$^%d$" % min(reps, 3)],
                rows)
        res = pairwise(sub, "kernel", "instance")
        tabular("tab-substrate-equiv.tex", "llrrrlll",
                ["A", "B", "rate A", "rate B", "diff", "95\\% CI", "verdict",
                 "p (Holm)"],
                [[r"\texttt{%s}" % r["a"], r"\texttt{%s}" % r["b"],
                  num(r["rate_a"]), num(r["rate_b"]), "%+.3f" % r["diff"],
                  "[%+.3f, %+.3f]" % tuple(r["ci95"]), r["verdict"],
                  "%.3g" % r["mcnemar"]["p_holm"]] for r in res])
        mac("subreps", reps)
        mac("subruns", len(sub))
        mac("submaxdiff", num(max(abs(r["diff"]) for r in res)))

    # ---------------- local tasks + variance ------------------------------
    if local:
        tasks = sorted({r["task"] for r in local})
        kernels = sorted({r["kernel"] for r in local})
        lmodels = sorted({r["model"] for r in local})
        cells = rate_cells(local, "task", "model")
        rows = [[r"\texttt{%s}" % esc(t)] +
                [num(cells[(t, m)][1] / cells[(t, m)][0], 2)
                 if cells[(t, m)][0] else "--" for m in lmodels]
                for t in tasks]
        rows.append([r"\textbf{all}"] +
                    [r"\textbf{%s}" % num(
                        sum(r["success"] for r in local if r["model"] == m) /
                        len([r for r in local if r["model"] == m])) for m in lmodels])
        tabular("tab-local-task.tex", "l" + "r" * len(lmodels),
                ["task"] + [esc(m) for m in lmodels], rows)
        kc = rate_cells(local, "kernel", "model")
        lreps = len(local) // max(1, len(tasks) * len(kernels) * len(lmodels))
        pk = min(5, lreps)
        rows = []
        for k in kernels:
            sel = [r for r in local if r["kernel"] == k]
            # pass^k is per (task, model) cell, so a substrate that is merely
            # lucky once does not look consistent
            cells = {}
            for r in sel:
                c = cells.setdefault((r["task"], r["model"]), [0, 0])
                c[0] += 1 if r["success"] else 0
                c[1] += 1
            succ = [c[0] for c in cells.values()]
            tri = [c[1] for c in cells.values()]
            rows.append([r"\texttt{%s}" % k] +
                        [num(kc[(k, m)][1] / kc[(k, m)][0]) if kc[(k, m)][0] else "--"
                         for m in lmodels] +
                        [num(sum(r["success"] for r in sel) / len(sel)),
                         num(pass_k(succ, tri, pk))])
        tabular("tab-local-kernel.tex", "l" + "r" * (len(lmodels) + 2),
                ["substrate"] + [esc(m) for m in lmodels] +
                ["all", "pass$^%d$" % pk], rows)
        mac("localpassk", str(pk))
        res = pairwise(local, "kernel", "task")
        tabular("tab-local-equiv.tex", "llrrrlll",
                ["A", "B", "rate A", "rate B", "diff", "95\\% CI", "verdict",
                 "p (Holm)"],
                [[r"\texttt{%s}" % r["a"], r"\texttt{%s}" % r["b"],
                  num(r["rate_a"]), num(r["rate_b"]), "%+.3f" % r["diff"],
                  "[%+.3f, %+.3f]" % tuple(r["ci95"]), r["verdict"],
                  "%.3g" % r["mcnemar"]["p_holm"]] for r in res])
        d = decompose(local, ["model", "task", "kernel"])

        def eta(v):
            return "$<$0.0001" if v < 1e-4 else num(v, 4)
        tabular("tab-variance.tex", "lrr", ["factor", "levels", "$\\eta^2$"],
                [[esc(k), v["levels"], eta(v["eta2"])]
                 for k, v in sorted(d["factors"].items(),
                                    key=lambda kv: -kv[1]["eta2"])])
        mac("localn", len(local))
        mac("localtasks", len(tasks))
        mac("localreps", len(local) // max(1, len(tasks) * len(kernels) * len(lmodels)))
        mac("localmaxdiff", num(max(abs(r["diff"]) for r in res)))

    # ---------------- Terminal-Bench --------------------------------------
    tb = load("bench/results-tb.jsonl") or []
    if tb:
        # The substrate tables must come from ONE arm. Pooling the retired
        # deepseek arm, the grok arm and the single-substrate qwen arm into one
        # table mixes three models and three protocols and answers no question
        # at all -- it did exactly that until this line was written.
        MAIN_ARM = ("grok-low", "br")
        scored = [r for r in tb if r["scored"]
                  and (r.get("model_key", "deepseek-flash"), r["prompt"]) == MAIN_ARM]
        kernels = sorted({r["kernel"] for r in scored})
        reps = sorted({r["rep"] for r in scored})
        rows = []
        for k in kernels:
            cells = []
            for rep in reps:
                sel = [r for r in scored if r["kernel"] == k and r["rep"] == rep]
                cells.append(num(sum(r["success"] for r in sel) / len(sel)) if sel else "--")
            allsel = [r for r in scored if r["kernel"] == k]
            t = per_unit(allsel, "task", "kernel")[k]
            succ = [x for x, _ in t.values()]
            tri = [n for _, n in t.values()]
            rows.append([r"\texttt{%s}" % k] + cells +
                        [r"\textbf{%s}" % num(sum(r["success"] for r in allsel) / len(allsel)),
                         "%d/%d" % (sum(r["success"] for r in allsel), len(allsel)),
                         num(pass_k(succ, tri, 3))])
        tabular("tab-tb.tex", "l" + "r" * (len(reps) + 3),
                ["substrate"] + ["rep %d" % r for r in reps] +
                ["all", "resolved", "pass$^3$"], rows)
        # per-repeat substrate deltas: a pooled difference that lives in one
        # repeat is a different animal from one that persists, and the reader
        # should not have to take our word for which this is
        drows = []
        for rep in reps:
            cells = [rep]
            for a, b in (("py", "sh"), ("py", "sql"), ("sh", "sql")):
                sa = [r for r in scored if r["kernel"] == a and r["rep"] == rep]
                sb = [r for r in scored if r["kernel"] == b and r["rep"] == rep]
                if sa and sb:
                    cells.append("%+.3f" % (sum(r["success"] for r in sa) / len(sa)
                                            - sum(r["success"] for r in sb) / len(sb)))
                else:
                    cells.append("--")
            drows.append(cells)
        tabular("tab-tb-perrep.tex", "lrrr",
                ["repeat", "py $-$ sh", "py $-$ sql", "sh $-$ sql"], drows)

        prereg = [r for r in scored if r["rep"] in PREREG_REPS]
        res = pairwise(prereg, "kernel", "task")
        if len(reps) > len(PREREG_REPS):
            ext = pairwise(scored, "kernel", "task")
            tabular("tab-tb-equiv-ext.tex", "llrrrlll",
                    ["A", "B", "rate A", "rate B", "diff", r"95\% CI",
                     "verdict", "p (Holm)"],
                    [[r"\texttt{%s}" % r["a"], r"\texttt{%s}" % r["b"],
                      num(r["rate_a"]), num(r["rate_b"]), "%+.3f" % r["diff"],
                      "[%+.3f, %+.3f]" % tuple(r["ci95"]), r["verdict"],
                      "%.3g" % r["mcnemar"]["p_holm"]] for r in ext])
        tabular("tab-tb-equiv.tex", "llrrrlll",
                ["A", "B", "rate A", "rate B", "diff", r"95\% CI", "verdict",
                 "p (Holm)"],
                [[r"\texttt{%s}" % r["a"], r"\texttt{%s}" % r["b"],
                  num(r["rate_a"]), num(r["rate_b"]), "%+.3f" % r["diff"],
                  "[%+.3f, %+.3f]" % tuple(r["ci95"]), r["verdict"],
                  "%.3g" % r["mcnemar"]["p_holm"]] for r in res])
        arm_all = [r for r in tb
                   if (r.get("model_key", "deepseek-flash"), r["prompt"]) == MAIN_ARM]
        excl = collections.Counter(r["outcome"] for r in arm_all if not r["scored"])
        agent = collections.Counter(r["outcome"] for r in arm_all if r["scored"]
                                    and r["outcome"] not in ("resolved", "unresolved"))
        tabular("tab-tb-exclusions.tex", "llr",
                ["disposition", "outcome", "trials"],
                [["excluded", r"\texttt{%s}" % esc(k.replace("excluded:", "")), v]
                 for k, v in excl.most_common()] +
                [["scored 0", r"\texttt{%s}" % esc(k), v] for k, v in agent.most_common()])
        arms = {}
        for r in tb:
            if not r["scored"]:
                continue
            k = (r.get("model_key", "deepseek-flash"), r["prompt"])
            a = arms.setdefault(k, [0, 0, set(), set(), set()])
            a[0] += 1
            a[1] += 1 if r["success"] else 0
            a[2].add(r["task"]); a[3].add(r["kernel"]); a[4].add(r["rep"])
        LABEL = {("deepseek-flash", "a"): ("deepseek-v4-flash", "a (terse)", "retired on cost"),
                 ("deepseek-flash", "b"): ("deepseek-v4-flash", "b (reasoned)", "prompt contrast"),
                 ("grok-low", "br"): ("grok-4.5-low", "br", "substrate comparison"),
                 ("qwen-max", "br"): ("qwen3.8-max", "br", "model factor"),
                 ("grok-high", "br"): ("grok-4.5-high", "br", "discarded, host faults")}
        arows = []
        for k in sorted(arms, key=lambda x: (x[0] != "deepseek-flash", x)):
            n, ok, tks, kern, reps = arms[k]
            m, pr, why = LABEL.get(k, (k[0], k[1], ""))
            arows.append([r"\texttt{%s}" % esc(m), r"\texttt{%s}" % esc(pr),
                          len(tks), len(kern), len(reps), n,
                          r"\textbf{%s}" % num(ok / n), esc(why)])
        tabular("tab-tb-arms.tex", "llrrrrrl",
                ["model", "protocol", "tasks", "substrates", "repeats",
                 "trials", "resolved", "role"], arows)
        pa = [r for r in tb if r["scored"] and r.get("model_key") == "deepseek-flash"
              and r["prompt"] == "a"]
        pb = [r for r in tb if r["scored"] and r.get("model_key") == "deepseek-flash"
              and r["prompt"] == "b"]
        if pa and pb:
            mac("tbpromptdiff", "%+.3f" % (sum(r["success"] for r in pb) / len(pb)
                                           - sum(r["success"] for r in pa) / len(pa)))
        for k, lbl in (("deepseek-flash", "tbarmone"), ("grok-low", "tbarmtwo")):
            sel = [r for r in tb if r["scored"] and r.get("model_key") == k
                   and (r["prompt"] == "a" if k == "deepseek-flash" else True)]
            if sel:
                mac(lbl, num(sum(r["success"] for r in sel) / len(sel)))
        mac("tbtrials", len(tb))
        mac("tbarmtrials", len(arm_all))
        mac("tbtasks", len({r["task"] for r in scored}))
        mac("tbreps", len(reps))
        mac("tbexcluded", sum(excl.values()))
        mac("tbexcludedfirstrep", sum(1 for r in arm_all if not r["scored"] and r["rep"] == 0))
        mac("tbagentfault", sum(agent.values()))
        mac("tbmaxdiff", num(max(abs(r["diff"]) for r in res)))
        mac("tbequiv", sum(1 for r in res if r["verdict"] == "equivalent"))
        mac("tbinconclusive", sum(1 for r in res if r["verdict"] == "inconclusive"))
        mac("tbdifferent", sum(1 for r in res if r["verdict"] == "different"))
        by = collections.defaultdict(lambda: collections.defaultdict(list))
        for r in scored:
            by[r["task"]][r["kernel"]].append(r["success"])
        # ---- H3: the cross-vendor model factor, with the timeout stratum ----
        # deliberately NOT `scored`, which is pinned to the main arm: this
        # comparison needs both models, and only the sh kernel of each.
        shsel = [r for r in tb if r["scored"] and r["prompt"] == "br"
                 and r["kernel"] == "sh"]
        Q = {r["task"]: r["success"] for r in shsel if r["model_key"] == "qwen-max"}
        Gm = collections.defaultdict(list)
        for r in shsel:
            if r["model_key"] == "grok-low":
                Gm[r["task"]].append(r["success"])
        common = sorted(set(Q) & set(Gm))
        if common:
            timeout = {r["task"] for r in tb if r.get("model_key") == "qwen-max"
                       and r["outcome"] == "AgentTimeoutError"}
            mrows = []
            for label, sel in (("all tasks", common),
                               ("slower model did not time out",
                                [t for t in common if t not in timeout])):
                qa = [1.0 if Q[t] else 0.0 for t in sel]
                ga = [sum(Gm[t]) / len(Gm[t]) for t in sel]
                e = equivalence(paired_bootstrap(qa, ga))
                lo, hi = e["ci95"]
                mrows.append([esc(label), len(sel), num(e["rate_a"]),
                              num(e["rate_b"]), "%+.3f" % e["diff"],
                              "[%+.3f, %+.3f]" % (lo, hi),
                              "yes" if (lo > 0 or hi < 0) else "no"])
            tabular("tab-model-factor.tex", "lrrrrll",
                    ["stratum", "tasks", "qwen3.8-max", "grok-4.5-low", "diff",
                     r"95\% CI", "CI excludes 0"], mrows)
            e_all = equivalence(paired_bootstrap(
                [1.0 if Q[t] else 0.0 for t in common],
                [sum(Gm[t]) / len(Gm[t]) for t in common]))
            mac("modeldiff", "%+.3f" % e_all["diff"])
            mac("modeltimeouts", len(timeout & set(common)))
            nt = [t for t in common if t not in timeout]
            e_nt = equivalence(paired_bootstrap(
                [1.0 if Q[t] else 0.0 for t in nt],
                [sum(Gm[t]) / len(Gm[t]) for t in nt]))
            mac("modeldiffnt", "%+.3f" % e_nt["diff"])
            sub_max = max(abs(r["diff"]) for r in pairwise(
                [r for r in tb if r["scored"] and r["prompt"] == "br"
                 and r.get("model_key") == "grok-low"], "kernel", "task"))
            mac("modelratio", "%.0f" % (abs(e_all["diff"]) / max(0.001, sub_max)))

        mac("tbdisagree", len([t for t, k in by.items()
                               if len({sum(v) for v in k.values()}) > 1]))
        mac("tbeveryone", len([t for t, k in by.items()
                               if all(sum(v) == len(v) for v in k.values())]))
        mac("tbsomeone", len([t for t, k in by.items()
                              if any(sum(v) > 0 for v in k.values())]))

    # ---------------- reliability ----------------------------------------
    faults = load("witness/results-faults.jsonl") or []
    if faults:
        arms = sorted({r["arm"] for r in faults})
        lams = sorted({r["faults"] for r in faults})
        rows = []
        for arm in arms:
            for lam in lams:
                sel = [r for r in faults if r["arm"] == arm and r["faults"] == lam]
                if not sel:
                    continue
                n = len(sel)
                rows.append([r"\texttt{%s}" % esc(arm), lam, n,
                             num(sum(r["success"] for r in sel) / n),
                             num(sum(r["model_calls"] for r in sel) / n, 2),
                             num(sum(r["duplicates_sent"] for r in sel) / n, 2),
                             sum(r["duplicate_side_effects"] for r in sel)])
        tabular("tab-faults.tex", "lrrrrrr",
                ["arm", "$\\lambda$", "runs", "success", "model calls/run",
                 "redelivered/run", "duplicate effects"], rows)
        mac("faultredelivered", sum(r["duplicates_sent"] for r in faults))
        mac("faultdup", sum(r["duplicate_side_effects"] for r in faults))

        def rate(arm, lam):
            sel = [r for r in faults if r["arm"] == arm and r["faults"] == lam]
            return sum(r["success"] for r in sel) / len(sel) if sel else None
        for key, (arm, lam) in {"fullclean": ("full", 0.0),
                                "fullten": ("full", 0.10),
                                "norecten": ("no_recovery", 0.10),
                                "norecclean": ("no_recovery", 0.0),
                                "fullfifty": ("full", 0.50)}.items():
            v = rate(arm, lam)
            if v is not None:
                mac(key, num(v))

    # ---------------- cost / time ----------------------------------------
    rows = []
    for label, data in (("local tasks", local), ("witness ablations", live)):
        for m in sorted({r.get("model") for r in data} - {None, "oracle"}):
            sel = [r for r in data if r.get("model") == m and "model_seconds" in r]
            if not sel:
                continue
            tm = sum(r["model_seconds"] for r in sel)
            tt = sum(r["tool_seconds"] for r in sel)
            to = sum(r["orchestration_seconds"] for r in sel)
            tot = tm + tt + to
            calls = sum(r["model_calls"] for r in sel)
            rows.append([esc(label), esc(m), len(sel),
                         "%.1f\\%%" % (100 * tm / tot), "%.1f\\%%" % (100 * tt / tot),
                         "%.2f\\%%" % (100 * to / tot),
                         "%.0f" % (1000 * to / max(1, calls)),
                         sum(r["prompt_tokens"] for r in sel) // len(sel),
                         sum(r["completion_tokens"] for r in sel) // len(sel)])
    if rows:
        allrows = [r for r in local + live if "orchestration_seconds" in r
                   and r.get("model") not in (None, "oracle")]
        tm = sum(r["model_seconds"] for r in allrows)
        tt = sum(r["tool_seconds"] for r in allrows)
        to = sum(r["orchestration_seconds"] for r in allrows)
        mac("orchshare", "%.2f\\%%" % (100 * to / (tm + tt + to)))
        mac("modelshare", "%.1f\\%%" % (100 * tm / (tm + tt + to)))
        tabular("tab-cost.tex", "llrrrrrrr",
                ["suite", "model", "runs", "$T_{model}$", "$T_{tool}$",
                 "$T_{orch}$", "orch ms/step", "prompt tok/run", "completion tok/run"],
                rows)


    # ---------------- systems ---------------------------------------------
    sysd = load("systems/results.json")
    if sysd:
        rows = []
        for kid, k in sysd["kernels"].items():
            ko = k["kernel_only"]
            rows.append([r"\texttt{%s}" % kid, esc(k["substrate"]),
                         "%.1f" % (ko["source_bytes"] / 1024.0),
                         "%.1f" % (ko["gzip_bytes"] / 1024.0),
                         ko["logical_loc"],
                         "%.1f" % (k["tcb"]["resolvable_bytes"] / 1024.0),
                         "%.1f" % k["startup"]["first_ms"],
                         "%.1f" % k["startup"]["p50_ms"],
                         "{:,}".format(k["throughput"]["transitions_per_s"]),
                         "%.1f" % (k["throughput"]["peak_rss_bytes"] / 1048576.0)])
        tabular("tab-systems.tex", "llrrrrrrrr",
                ["kernel", "substrate", "src KiB", "gzip KiB", "LOC", "TCB KiB",
                 "cold ms", "warm p50 ms", "transitions/s", "peak RSS MiB"], rows)
        fast = max(sysd["kernels"].values(),
                   key=lambda k: k["throughput"]["transitions_per_s"])
        slow = min(sysd["kernels"].values(),
                   key=lambda k: k["throughput"]["transitions_per_s"])
        mac("throughputspread", "%.0f" % (fast["throughput"]["transitions_per_s"] /
                                          slow["throughput"]["transitions_per_s"]))
        mac("slowestus", "%.0f" % slow["throughput"]["per_transition_us"])
        mac("slowestshare", "%.2f" % (slow["throughput"]["per_transition_us"] / 5000.0))
        tcbs = [k["tcb"]["resolvable_bytes"] for k in sysd["kernels"].values()]
        mac("tcbspread", "%.0f" % (max(tcbs) / max(1, min(tcbs))))
        mac("almrules", sysd["alm"]["rules"])
        mac("almfields", sysd["alm"]["state_fields"])
        mac("adapterloc", sysd["shared_adapter"]["logical_loc"])

    if "fullten" in MACROS and "norecten" in MACROS:
        mac("recoverygain", "%.0f" % ((float(MACROS["fullten"]) -
                                       float(MACROS["norecten"])) * 100))

    with open(os.path.join(GEN, "macros.tex"), "w") as fh:
        fh.write("%% generated by alm/paper_tables.py -- do not edit\n")
        for k, v in sorted(MACROS.items()):
            fh.write("\\newcommand{\\%s}{%s}\n" % (k, v))
    print("wrote %d tables and %d macros to %s"
          % (len([f for f in os.listdir(GEN) if f.startswith("tab-")]),
             len(MACROS), GEN))
    return check()


BUILTIN = set("""documentclass usepackage input title author date begin end
maketitle abstract section subsection paragraph textbf texttt emph item
newcommand bibliographystyle bibliography appendix cite label ref centering
caption toprule midrule bottomrule multicolumn tabular quote enumerate itemize
url mathrm times alpha lambda kappa varepsilon mathit textsc infty eta sim
allowbreak small ttfamily families frac left right href verb rule
dots rightarrow tau text textit ldots quad qquad noindent hline
widetable resizebox textwidth emergencystretch align footnotesize
includegraphics centering footnote mbox
""".split())


def check_columns():
    """Every row must have as many cells as the column spec declares."""
    import re
    problems = []
    for name in sorted(os.listdir(GEN)):
        if not name.startswith("tab-"):
            continue
        lines = open(os.path.join(GEN, name)).read().splitlines()
        spec = re.match(r"\\begin\{tabular\}\{([^}]*)\}", lines[0])
        if not spec:
            problems.append("%s: no tabular spec" % name)
            continue
        want = len(re.sub(r"[^lrc]", "", spec.group(1)))
        for i, line in enumerate(lines[1:], 2):
            if not line.endswith(r"\\"):
                continue
            body = line[:-2]
            if r"\multicolumn" in body:
                m = re.search(r"\\multicolumn\{(\d+)\}", body)
                got = int(m.group(1)) if m else want
            else:
                got = len(body.split("&"))
            if got != want:
                problems.append("%s line %d: %d cells, spec declares %d"
                                % (name, i, got, want))
    return problems


def check():
    """No LaTeX here, so lint what a build would have caught."""
    import re
    tex = os.path.join(ROOT, "paper", "seed.tex")
    src = open(tex).read()
    problems = []
    for name in re.findall(r"\\(?:input|widetable)\{gen/([a-zA-Z0-9_-]+)\}", src):
        if not os.path.exists(os.path.join(GEN, name + ".tex")):
            problems.append("missing table file: gen/%s.tex" % name)
    used = set(re.findall(r"\\([a-z][a-zA-Z]{2,})", src))
    unknown = sorted(used - BUILTIN - set(MACROS))
    for u in unknown:
        problems.append("undefined macro or unlisted LaTeX command: \\%s" % u)
    unused = sorted(set(MACROS) - used)
    for u in unused:
        problems.append("macro generated but never used: \\%s" % u)
    for p in problems:
        print("  LINT: " + p)
    print("lint: %d problem(s)" % len(problems))
    return 1 if any("missing table" in p or "undefined macro" in p
                    or "cells, spec declares" in p for p in problems) else 0


if __name__ == "__main__":
    sys.exit(main())
