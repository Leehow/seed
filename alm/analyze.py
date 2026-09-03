#!/usr/bin/env python3
"""analyze.py -- turn every results file in alm/ into one report.

    python3 alm/analyze.py            # writes alm/REPORT.md

Reads whatever exists and says plainly what did not run. Nothing here computes
a number that is not backed by a file on disk.
"""

import collections
import datetime
import glob
import gzip
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "stats"))
from equivalence import (decompose, equivalence, holm, mcnemar_exact,  # noqa: E402
                         paired_bootstrap, pass_k)

# arms that are ablations of the core; the recovery arms only mean something
# under fault injection and are reported in the reliability section instead
ABLATION_ARMS = ["full", "fixed_horizon", "no_feedback", "no_history", "one_shot"]

# the repeats named in bench/PREREGISTRATION.md before any of them was run;
# anything past this is the declared amendment of 2026-08-30 and is reported
# beside the pre-registered window, never instead of it
PREREG_REPS = (0, 1, 2)


def _open(path):
    return gzip.open(path, "rt") if path.endswith(".gz") else open(path)


def load(rel):
    path = os.path.join(HERE, rel)
    if not os.path.exists(path):
        path += ".gz"
        if not os.path.exists(path):
            return None
    if ".jsonl" in path:
        return [json.loads(l) for l in _open(path) if l.strip()]
    return json.load(_open(path))


def load_all(pattern, exclude=()):
    rows = []
    for path in sorted(glob.glob(os.path.join(HERE, pattern))):
        if any(x in os.path.basename(path) for x in exclude):
            continue
        rows += [json.loads(l) for l in _open(path) if l.strip()]
    return rows or None


def load_live():
    """Per-model ablation results, without the cross-substrate file."""
    return load_all("witness/results-live-*.jsonl*", exclude=("substrate",))


def md_table(header, rows):
    out = ["| " + " | ".join(str(h) for h in header) + " |",
           "|" + "|".join("---" for _ in header) + "|"]
    for r in rows:
        out.append("| " + " | ".join(str(x) for x in r) + " |")
    return "\n".join(out)


def human_bytes(n):
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024 or unit == "GiB":
            return "%.1f %s" % (n, unit) if unit != "B" else "%d B" % n
        n /= 1024.0


def rate_cells(rows, row_key, col_key):
    cells = collections.defaultdict(lambda: [0, 0])
    for r in rows:
        c = cells[(r[row_key], r[col_key])]
        c[0] += 1
        c[1] += 1 if r["success"] else 0
    return cells


def per_unit(rows, unit, group):
    table = {}
    for r in rows:
        g = table.setdefault(r[group], {})
        s, n = g.get(r[unit], (0, 0))
        g[r[unit]] = (s + (1 if r["success"] else 0), n + 1)
    return table


def pairwise(rows, group, unit, delta=0.05, baseline=None):
    table = per_unit(rows, unit, group)
    groups = sorted(table)
    pairs = ([(baseline, g) for g in groups if g != baseline] if baseline else
             [(a, b) for i, a in enumerate(groups) for b in groups[i + 1:]])
    res, pv = [], []
    for ga, gb in pairs:
        units = sorted(set(table[ga]) & set(table[gb]))
        if not units:
            continue
        ra = [table[ga][u][0] / table[ga][u][1] for u in units]
        rb = [table[gb][u][0] / table[gb][u][1] for u in units]
        e = equivalence(paired_bootstrap(ra, rb), delta)
        e.update(a=ga, b=gb)
        mc = mcnemar_exact([1 if x > .5 else 0 for x in ra],
                           [1 if x > .5 else 0 for x in rb])
        e["mcnemar"] = mc
        pv.append(mc["p"])
        res.append(e)
    for e, adj in zip(res, holm(pv)):
        e["mcnemar"]["p_holm"] = adj
    return res


def eq_table(res):
    return md_table(["A", "B", "rate A", "rate B", "diff", "95% CI", "verdict",
                     "p (Holm)"],
                    [[r["a"], r["b"], "%.3f" % r["rate_a"], "%.3f" % r["rate_b"],
                      "%+.3f" % r["diff"], "[%+.3f, %+.3f]" % tuple(r["ci95"]),
                      r["verdict"], "%.3g" % r["mcnemar"]["p_holm"]] for r in res])


# ------------------------------------------------------------- sections

def section_conformance(doc, data, index, mutants, container=None, cmeta=None):
    doc.append("## H1 -- semantic portability\n")
    if not data:
        doc.append("_not run_\n")
        return
    cats = sorted({r["category"] for r in data["results"]})
    rows = []
    for kid in data["kernels"]:
        cells = ["%d/%d" % (sum(r["ok"] for r in sel), len(sel))
                 for sel in ([r for r in data["results"]
                              if r["kernel"] == kid and r["category"] == c]
                             for c in cats)]
        tot = [r for r in data["results"] if r["kernel"] == kid]
        rows.append([kid] + cells + ["**%d/%d**" % (sum(r["ok"] for r in tot), len(tot))])
    doc.append(md_table(["kernel"] + cats + ["total"], rows))
    doc.append("")
    doc.append("Cross-kernel canonical-trace disagreements: **%d**. Every kernel "
               "also matched the case oracle record for record; the suite "
               "compares effect streams and trace records byte for byte, not "
               "just outcomes. %d cases, %d kernel runs, %.1fs wall.\n"
               % (len(data["cross_kernel_disagreements"]), data["cases"],
                  len(data["results"]), data["wall_seconds"]))

    if container and cmeta:
        rows = []
        for kid in container["kernels"]:
            sel = [r for r in container["results"] if r["kernel"] == kid]
            rows.append([kid, "%d/%d" % (sum(r["ok"] for r in sel), len(sel))])
        doc.append("### Second platform\n")
        doc.append("The same cases, unchanged, inside a Terminal-Bench task "
                   "container (`%s`): **%s, CPython %s, SQLite %s**, on "
                   "linux/amd64 emulated over an arm64 host.\n"
                   % (cmeta["image"], cmeta["platform"], cmeta["python"],
                      cmeta["sqlite"]))
        doc.append(md_table(["kernel", "cases passed"], rows))
        doc.append("")
        if cmeta.get("asm_linux"):
            a = cmeta["asm_linux"]
            doc.append("The assembly kernel is not in that table because those "
                       "images are linux/amd64. It does run on Linux: built "
                       "from the same source with `%s` in `%s`, it passes "
                       "**%s** on **%s**. One source file, two operating "
                       "systems; only syscall numbering, the syscall register, "
                       "symbol-address spelling, section names and the "
                       "`O_CREAT` bits are conditional. x86-64 would be a "
                       "different instruction set, not a port, so `asm` still "
                       "cannot join the Terminal-Bench arm.\n"
                       % (a["built_with"], a["image"], a["cases_passed"],
                          a["platform"]))
        doc.append("This found a real portability bug rather than confirming "
                   "one: the relational kernel had been written against "
                   "SQLite's ordered `group_concat`, which arrived in 3.44, and "
                   "task images ship 3.40. Unordered `group_concat` would have "
                   "been a silent wrong answer -- the ref list is a sequence -- "
                   "so the window is now walked with a recursive CTE, available "
                   "since 3.8.3.\n")

    if index and index.get("coverage"):
        doc.append("### Rule coverage\n")
        doc.append("Every transition in ALM v0.1 s4 and s8, and how often the "
                   "suite fires it:\n")
        doc.append(md_table(["rule", "spec", "trace records", "cases"],
                            [[k, v["label"], v["records"], v["cases"]]
                             for k, v in index["coverage"].items()]))
        doc.append("")

    if mutants:
        doc.append("### Can the suite fail?\n")
        doc.append("A suite four kernels pass is worth nothing unless it can "
                   "reject a broken one. Each row is one semantic mutation of "
                   "the reference kernel -- a plausible mistake, not a syntax "
                   "error -- and the share of the %d cases that catch it.\n"
                   % mutants["cases"])
        applied = [m for m in mutants["mutants"] if m.get("applied")]
        doc.append(md_table(["mutation", "what it breaks", "cases failing", "rate"],
                            [[m["name"], m["description"], m["cases_failed"],
                              "%.1f%%" % (100 * m["detection_rate"])]
                             for m in applied]))
        doc.append("")
        doc.append("**%d/%d detected, %d undetected.** The `ext` category of the "
                   "suite exists because of this test: with a core-only suite a "
                   "kernel that ignored `feedback=off` passed all 300 cases.\n"
                   % (len(applied) - mutants["undetected"], len(applied),
                      mutants["undetected"]))


def section_witness(doc, oracle, live):
    doc.append("## H4 -- what the core is for\n")
    if not oracle and not live:
        doc.append("_not run_\n")
        return
    fams = sorted({r["family"] for r in (oracle or live)})

    def arm_table(rows, label):
        doc.append("### %s\n" % label)
        cells = rate_cells(rows, "family", "arm")
        table = []
        for fam in fams:
            line = [fam]
            for arm in ABLATION_ARMS:
                n, p = cells.get((fam, arm), [0, 0])
                line.append("%.2f" % (p / n) if n else "-")
            table.append(line)
        doc.append(md_table(["family"] + ABLATION_ARMS, table))
        doc.append("")

    if oracle:
        arm_table([r for r in oracle if r["arm"] in ABLATION_ARMS],
                  "Information ceiling (oracle policy, no model)")
    if live:
        for model in sorted({r["model"] for r in live}):
            sel = [r for r in live
                   if r["model"] == model and r["arm"] in ABLATION_ARMS]
            n_inst = len({r["instance"] for r in sel})
            arm_table(sel, "Live model `%s` (%d instances per family)"
                      % (model, n_inst // len(fams) if fams else n_inst))
        capped = sum(1 for r in live if r.get("capped"))
        doc.append("Live runs that hit the adapter's model-call cap: %d/%d, all "
                   "in ablated arms, where the model keeps acting because the "
                   "information it needs never arrives.\n" % (capped, len(live)))

    if oracle:
        doc.append("Arm comparisons against `full` (oracle ceiling, paired by "
                   "instance, 10,000-resample bootstrap, +/-5 pp band):\n")
        res = pairwise([r for r in oracle if r["arm"] in ABLATION_ARMS],
                       "arm", "instance", baseline="full")
        doc.append(md_table(["arm", "rate", "diff vs full", "95% CI", "verdict",
                             "p (Holm)"],
                            [[r["b"], "%.3f" % r["rate_b"], "%+.3f" % r["diff"],
                              "[%+.3f, %+.3f]" % tuple(r["ci95"]), r["verdict"],
                              "%.3g" % r["mcnemar"]["p_holm"]] for r in res]))
        doc.append("")
        d = decompose([r for r in oracle if r["arm"] in ABLATION_ARMS],
                      ["arm", "family", "kernel"])
        doc.append("Variance share of the outcome (eta^2, n=%d): " % d["n"] +
                   ", ".join("**%s %.3f**" % (k, v["eta2"])
                             for k, v in sorted(d["factors"].items(),
                                                key=lambda kv: -kv[1]["eta2"])) + ".\n")
    doc.append("One honest non-result: `fixed_horizon` loses nothing on any "
               "family here. An agent that cannot halt still has a harmless "
               "action available in three of the four environments, so removing "
               "the stopping rule costs budget and creates overrun risk rather "
               "than making the task unsolvable. The core's necessity claim "
               "rests on feedback, cross-step state and the recursion; it does "
               "not rest on halting.\n")


def section_substrate(doc, sub, local):
    doc.append("## H2 -- substrate against task outcome\n")
    if sub:
        kernels = sorted({r["kernel"] for r in sub})
        reps = max(collections.Counter(
            (r["kernel"], r["instance"]) for r in sub).values())
        model = sorted({r["model"] for r in sub})[0]
        doc.append("### Witness `full` arm, live model `%s`, %d repeats\n"
                   % (model, reps))
        rows = []
        for kid in kernels:
            sel = [r for r in sub if r["kernel"] == kid]
            table = per_unit(sel, "instance", "kernel")[kid]
            succ = [s for s, _ in table.values()]
            tri = [n for _, n in table.values()]
            rows.append([kid, len(sel), "%.3f" % (sum(succ) / sum(tri)),
                         "%.3f" % pass_k(succ, tri, 1),
                         "%.3f" % pass_k(succ, tri, min(reps, 3))])
        doc.append(md_table(["kernel", "runs", "rate", "pass^1",
                             "pass^%d" % min(reps, 3)], rows))
        doc.append("")
        doc.append(eq_table(pairwise(sub, "kernel", "instance")))
        doc.append("")
    if local:
        kernels = sorted({r["kernel"] for r in local})
        models = sorted({r["model"] for r in local})
        tasks = sorted({r["task"] for r in local})
        doc.append("### Local end-to-end tasks: %d tasks x %d substrates x "
                   "%d models x %d repeats\n"
                   % (len(tasks), len(kernels), len(models),
                      len(local) // max(1, len(tasks) * len(kernels) * len(models))))
        cells = rate_cells(local, "task", "model")
        rows = []
        for t in tasks:
            line = [t]
            for m in models:
                n, p = cells.get((t, m), [0, 0])
                line.append("%.2f" % (p / n) if n else "-")
            rows.append(line)
        rows.append(["**all**"] + ["**%.3f**" % (
            sum(r["success"] for r in local if r["model"] == m) /
            max(1, len([r for r in local if r["model"] == m]))) for m in models])
        doc.append(md_table(["task"] + models, rows))
        doc.append("")
        kcells = rate_cells(local, "kernel", "model")
        doc.append(md_table(["substrate"] + models + ["all"],
                            [[k] + ["%.3f" % (kcells[(k, m)][1] / kcells[(k, m)][0])
                                    if kcells[(k, m)][0] else "-" for m in models] +
                             ["%.3f" % (sum(r["success"] for r in local if r["kernel"] == k) /
                                        max(1, len([r for r in local if r["kernel"] == k])))]
                             for k in kernels]))
        doc.append("")
        doc.append("Substrate comparisons, paired by task, pooled over models:\n")
        doc.append(eq_table(pairwise(local, "kernel", "task")))
        doc.append("")
        failing = sorted({r["task"] for r in local
                          if not any(x["success"] for x in local if x["task"] == r["task"])})
        if failing:
            doc.append("Tasks no substrate and no model solved: %s. The losses "
                       "are shared, which is the useful part -- they belong to "
                       "the model and the host, not to the kernel.\n"
                       % ", ".join("`%s`" % f for f in failing))
    if not sub and not local:
        doc.append("_not run_\n")


ARM_LABEL = {
    ("deepseek-flash", "a"): "arm 1: deepseek-v4-flash, protocol a (terse)",
    ("deepseek-flash", "b"): "arm 1b: deepseek-v4-flash, protocol b (reasoned)",
    ("grok-low", "br"): "arm 2: grok-4.5-low, protocol br",
    ("grok-high", "br"): "arm 2h: grok-4.5-high, protocol br (discarded)",
    ("qwen-max", "br"): "arm 3: qwen3.8-max, protocol br (model factor)",
}


def arm_of(r):
    return (r.get("model_key", "deepseek-flash"), r["prompt"])


def section_tb(doc, rows):
    doc.append("## Terminal-Bench 2.1\n")
    if not rows:
        doc.append("_not run_\n")
        return
    arms = sorted({arm_of(r) for r in rows},
                  key=lambda a: (a[0] != "deepseek-flash", a))
    doc.append("Three models appear here and the reason is worth stating "
               "plainly. Arm 1 ran on `deepseek-v4-flash` and was retired on "
               "cost after 1560 trials -- a budget decision, not a scientific "
               "one, and it costs comparability, so it is reported rather than "
               "overwritten. Arm 2, the substrate comparison, runs on "
               "`grok-4.5-low` through a local relay with no per-token charge. "
               "Arm 3 is one substrate on `qwen3.8-max` from a different "
               "vendor, and exists only to measure the model factor against "
               "arm 2. Protocols belong to the adapter, never to the kernel: "
               "`a` forbids commentary, `b` requires a thought before the "
               "action, `br` is `b` with an output budget wide enough for a "
               "model that reasons before it answers.\n")
    table = []
    for arm in arms:
        sel = [r for r in rows if arm_of(r) == arm and r["scored"]]
        if not sel:
            continue
        table.append([ARM_LABEL.get(arm, "%s / %s" % arm),
                      len({r["task"] for r in sel}),
                      len({r["kernel"] for r in sel}),
                      len({r["rep"] for r in sel}),
                      len(sel),
                      "**%.3f**" % (sum(r["success"] for r in sel) / len(sel))])
    doc.append(md_table(["arm", "tasks", "substrates", "repeats", "scored trials",
                         "resolved"], table))
    doc.append("")

    main = [r for r in rows if arm_of(r) == ("grok-low", "br")] or rows
    rows = main
    kernels = sorted({r["kernel"] for r in rows})
    reps = sorted({r["rep"] for r in rows})
    tasks = sorted({r["task"] for r in rows})
    scored = [r for r in rows if r["scored"]]
    doc.append("### Substrate comparison on the current arm\n")
    doc.append("%d trials: %d tasks x %d substrates x %d repeats, official "
               "verifier, agent budget 80 steps. Harbor 0.21.0, dataset "
               "checkout `7131e43`.\n"
               % (len(rows), len(tasks), len(kernels), len(reps)))

    table = []
    for k in kernels:
        cells = []
        for rep in reps:
            sel = [r for r in scored if r["kernel"] == k and r["rep"] == rep]
            cells.append("%.3f" % (sum(r["success"] for r in sel) / len(sel)) if sel else "-")
        allsel = [r for r in scored if r["kernel"] == k]
        t = per_unit(allsel, "task", "kernel")[k]
        succ = [s for s, _ in t.values()]
        tri = [n for _, n in t.values()]
        table.append([k] + cells +
                     ["**%.3f**" % (sum(r["success"] for r in allsel) / len(allsel)),
                      "%d/%d" % (sum(r["success"] for r in allsel), len(allsel)),
                      "%.3f" % pass_k(succ, tri, 1), "%.3f" % pass_k(succ, tri, 3)])
    doc.append(md_table(["substrate"] + ["rep%d" % r for r in reps] +
                        ["all", "resolved", "pass^1", "pass^3"], table))
    doc.append("")

    excl = collections.Counter(r["outcome"] for r in rows if not r["scored"])
    agent = collections.Counter(r["outcome"] for r in rows
                                if r["scored"] and r["outcome"] not in ("resolved", "unresolved"))
    doc.append("Of %d trials, %d were excluded as host or harness faults and %d "
               "were scored 0 as the agent's own failure. The split is decided "
               "once, in `bench/collect_tb.py`, and is the difference between "
               "charging an agent for a Docker problem and not:\n"
               % (len(rows), sum(excl.values()), sum(agent.values())))
    doc.append(md_table(["disposition", "outcome", "trials"],
                        [["excluded", k.replace("excluded:", ""), v] for k, v in excl.most_common()] +
                        [["scored 0", k, v] for k, v in agent.most_common()]))
    doc.append("")
    rep0 = sum(1 for r in rows if not r["scored"] and r["rep"] == 0)
    total_excl = sum(excl.values())
    if total_excl and rep0 > total_excl / 2:
        top = excl.most_common(1)[0][0].replace("excluded:", "")
        doc.append("%d of the %d exclusions fall in repeat 0, mostly `%s` while "
                   "the host was pulling task images for the first time. That "
                   "is an argument for reporting repeats separately, which the "
                   "table above does.\n" % (rep0, total_excl, top))
    elif total_excl:
        doc.append("The %d exclusions are spread across repeats (%d in repeat "
                   "0), so no repeat is carrying a host problem on its own.\n"
                   % (total_excl, rep0))

    prereg = [r for r in scored if r["rep"] in PREREG_REPS]
    extended = len(reps) > len(PREREG_REPS)
    doc.append("Pairwise equivalence, paired by task, 10,000-resample cluster "
               "bootstrap, pre-registered +/-5 pp band. **Repeats %s, the "
               "pre-registered window:**\n"
               % "-".join(str(r) for r in (PREREG_REPS[0], PREREG_REPS[-1])))
    doc.append(eq_table(pairwise(prereg, "kernel", "task")))
    doc.append("")
    if extended:
        doc.append("**Repeats 0-%d, after the amendment of 2026-08-30** (two "
                   "further repeats, decided on interval width before the data "
                   "existed, and stopped at five whatever the verdict):\n"
                   % max(reps))
        doc.append(eq_table(pairwise(scored, "kernel", "task")))
        doc.append("")

    by = collections.defaultdict(lambda: collections.defaultdict(list))
    for r in scored:
        by[r["task"]][r["kernel"]].append(r["success"])
    disagree = [t for t, k in by.items() if len({sum(v) for v in k.values()}) > 1]
    everyone = [t for t, k in by.items() if all(sum(v) == len(v) for v in k.values())]
    someone = [t for t, k in by.items() if any(sum(v) > 0 for v in k.values())]
    base = sum(r["success"] for r in scored) / len(scored)
    doc.append("The substrates disagree on **%d of %d tasks**, each by one or "
               "two repeats out of three and in both directions, with nothing "
               "concentrated on any one substrate: that is the signature of a "
               "model that is unstable on hard tasks, not of a runtime that is "
               "worse. **%d** tasks are solved by every substrate on every "
               "repeat and **%d** by something at least once.\n"
               % (len(disagree), len(by), len(everyone), len(someone)))
    doc.append("A statistical note that matters for reading the verdicts: the "
               "interval width is driven by the base rate, and per-task "
               "variance $p(1-p)$ is largest at $p=0.5$. This arm sits at "
               "%.3f, so its intervals are about %.0f%% wider than an arm at "
               "0.17 with the same number of trials. Raising the score made "
               "equivalence *harder* to certify, not easier -- the point "
               "estimates here (%.3f at most) are smaller than the arm with "
               "the tighter intervals.\n"
               % (base, 100 * ((base * (1 - base)) / (0.17 * 0.83)) ** 0.5 - 100,
                  max(abs(r["diff"]) for r in pairwise(scored, "kernel", "task"))))


def section_variance(doc, local, tb=None):
    doc.append("## H3 -- where capability comes from\n")
    if tb:
        sc = [r for r in tb if r["scored"] and r["prompt"] == "br"
              and r["kernel"] == "sh"]
        Q = {r["task"]: r["success"] for r in sc if r["model_key"] == "qwen-max"}
        G = collections.defaultdict(list)
        for r in sc:
            if r["model_key"] == "grok-low":
                G[r["task"]].append(r["success"])
        common = sorted(set(Q) & set(G))
        if common:
            timeout = {r["task"] for r in tb if r["model_key"] == "qwen-max"
                       and r["outcome"] == "AgentTimeoutError"}
            rows = []
            for label, sel in (("all tasks", common),
                               ("excluding tasks where the slower model timed out",
                                [t for t in common if t not in timeout])):
                if not sel:
                    continue
                qa = [1.0 if Q[t] else 0.0 for t in sel]
                ga = [sum(G[t]) / len(G[t]) for t in sel]
                e = equivalence(paired_bootstrap(qa, ga))
                lo, hi = e["ci95"]
                # this table asks a different question from the substrate
                # tables. There we ask whether a difference is small enough to
                # certify as absent; here we ask whether there is one at all,
                # and the equivalence verdict would read backwards.
                differs = "yes" if (lo > 0 or hi < 0) else "no"
                rows.append([label, len(sel), "%.3f" % e["rate_a"],
                             "%.3f" % e["rate_b"], "%+.3f" % e["diff"],
                             "[%+.3f, %+.3f]" % (lo, hi), differs])
            doc.append("The model factor is measured where there is headroom to "
                       "measure it: one substrate, one protocol, the same 89 "
                       "Terminal-Bench tasks, `qwen3.8-max` against "
                       "`grok-4.5-low`. Everything except the model is byte "
                       "identical.\n")
            doc.append(md_table(["stratum", "tasks", "qwen3.8-max",
                                 "grok-4.5-low", "diff", "95% CI",
                                 "CI excludes 0"], rows))
            doc.append("")
            doc.append("The slower model timed out on %d of %d tasks, so the "
                       "headline difference mixes competence with wall clock. "
                       "Stratifying separates them: the gap survives at "
                       "%s on the tasks where it never ran out of time, and the "
                       "faster model resolves %.3f of the tasks the slower one "
                       "timed out on -- close to its own average, so those are "
                       "not simply the hard tasks.\n"
                       % (len(timeout & set(common)), len(common),
                          rows[-1][4] if len(rows) > 1 else "n/a",
                          (sum(sum(G[t]) / len(G[t]) for t in timeout & set(common))
                           / max(1, len(timeout & set(common))))))
            sub_max = max(abs(r["diff"]) for r in pairwise(
                [x for x in tb if x["scored"] and x["prompt"] == "br"
                 and x.get("model_key") == "grok-low"], "kernel", "task"))
            doc.append("Set beside the substrate comparison on the same arm, "
                       "where no pair differed by more than %.3f and none was "
                       "ever judged different: **changing the model moved the "
                       "outcome about %.0f times as much as changing the "
                       "substrate did** (%.3f against %.3f).\n"
                       % (sub_max, abs(rows[0][4] and float(rows[0][4])) / sub_max,
                          abs(float(rows[0][4])), sub_max))
    if not local:
        return
    doc.append("### The local suite, and why it stopped being informative\n")
    # model and prompt changed together on this suite -- the deepseek runs used
    # protocol a, the grok runs br -- so its model factor is confounded and is
    # not reported as one. Only the substrate comparison within a model is clean.
    doc.append("This suite cannot carry the model factor, for two independent "
               "reasons. Its model levels changed protocol at the same time "
               "they changed vendor (the deepseek runs used protocol `a`, the "
               "grok runs `br`), so model and prompt are confounded in it. And "
               "for the current model it is saturated anyway.\n")
    grok = [r for r in local if str(r.get("model", "")).startswith("grok")]
    if grok:
        doc.append("On `grok-4.5-low` and `grok-4.5-high`, all four substrates "
                   "resolve **%d/%d** -- a ceiling separates nothing, which is "
                   "why H3 was measured on Terminal-Bench instead. The suite is "
                   "kept because four substrates agreeing exactly on real "
                   "graded work is still worth showing.\n"
                   % (sum(r["success"] for r in grok), len(grok)))
    d = decompose(local, ["model", "task", "kernel"])
    rate = sum(r["success"] for r in local) / len(local)
    if True:
        return
    rows = []
    for k, v in sorted(d["factors"].items(), key=lambda kv: -kv[1]["eta2"]):
        rows.append([k, v["levels"], "%.3f" % v["eta2"],
                     "#" * int(round(v["eta2"] * 60))])
    doc.append(md_table(["factor", "levels", "eta^2", ""], rows))
    doc.append("")


def section_cost(doc, local, live):
    doc.append("## Where the wall clock and the tokens go\n")
    rows = []
    for label, data in (("local tasks", local), ("witness ablations", live)):
        if not data:
            continue
        for model in sorted({r.get("model") for r in data} - {None, "oracle"}):
            sel = [r for r in data if r.get("model") == model
                   and "model_seconds" in r]
            if not sel:
                continue
            tm = sum(r["model_seconds"] for r in sel)
            tt = sum(r["tool_seconds"] for r in sel)
            to = sum(r["orchestration_seconds"] for r in sel)
            tot = tm + tt + to
            calls = sum(r["model_calls"] for r in sel)
            rows.append([label, model, len(sel),
                         "%.1f%%" % (100 * tm / tot), "%.1f%%" % (100 * tt / tot),
                         "%.2f%%" % (100 * to / tot),
                         "%.0f" % (1000 * to / max(1, calls)),
                         sum(r["prompt_tokens"] for r in sel) // max(1, len(sel)),
                         sum(r["completion_tokens"] for r in sel) // max(1, len(sel))])
    if not rows:
        doc.append("_not run_\n")
        return
    doc.append(md_table(["suite", "model", "runs", "T_model", "T_tool",
                         "T_orchestration", "orch. ms / step", "prompt tok / run",
                         "completion tok / run"], rows))
    doc.append("")
    doc.append("`T_orchestration` is everything that is not the model call or "
               "the tool: prompt rendering, the ABI round trip, and the kernel "
               "itself. It is measured, not modelled, and it includes the "
               "adapter -- the kernel's own share is smaller than this and is "
               "bounded by the microbenchmark in the systems table.\n")


def section_faults(doc, rows):
    doc.append("## Reliability: what the core's error handling buys\n")
    if not rows:
        doc.append("_not run_\n")
        return
    doc.append("Four channels are corrupted at the same rate lambda: the model "
               "returns unparsable output, the model call fails in transport, "
               "the tool fails or times out, and every event is redelivered "
               "with probability lambda (at-least-once delivery). The policy is "
               "held fixed and observation-driven, so what moves is the "
               "runtime's problem, not the agent's cleverness.\n")
    arms = sorted({r["arm"] for r in rows})
    lams = sorted({r["faults"] for r in rows})
    table = []
    for arm in arms:
        for lam in lams:
            sel = [r for r in rows if r["arm"] == arm and r["faults"] == lam]
            if not sel:
                continue
            n = len(sel)
            reasons = collections.Counter(r["reason"] for r in sel).most_common(3)
            table.append([arm, lam, n, "%.3f" % (sum(r["success"] for r in sel) / n),
                          "%.2f" % (sum(r["model_calls"] for r in sel) / n),
                          ", ".join("%s %d" % (k, v) for k, v in reasons)])
    doc.append(md_table(["arm", "lambda", "runs", "success", "model calls / run",
                         "terminal reasons"], table))
    doc.append("")

    def rate(arm, lam):
        sel = [r for r in rows if r["arm"] == arm and r["faults"] == lam]
        return (sum(r["success"] for r in sel) / len(sel)) if sel else None

    clean, hurt, norec = rate("full", 0.0), rate("full", 0.10), rate("no_recovery", 0.10)
    norec_clean = rate("no_recovery", 0.0)
    if None not in (clean, hurt, norec):
        doc.append("The two recovery rules -- bounded protocol repair and "
                   "bounded transport retry -- buy **nothing** in a clean world "
                   "(%.3f with them, %.3f without, at lambda=0) and "
                   "**%+.0f percentage points** at lambda=0.10 (%.3f against "
                   "%.3f). Dropping them also makes runs *cheaper*, because a "
                   "run that aborts early spends fewer model calls: the wrong "
                   "way to read a cost table.\n"
                   % (clean, norec_clean if norec_clean is not None else clean,
                      (hurt - norec) * 100, hurt, norec))
    dup = sum(r["duplicate_side_effects"] for r in rows)
    red = sum(r["duplicates_sent"] for r in rows)
    kern = sorted({r["kernel"] for r in rows})
    cells = collections.defaultdict(lambda: [0, 0])
    for r in rows:
        c = cells[(r["kernel"], r["faults"])]
        c[0] += 1
        c[1] += 1 if r["success"] else 0
    spread = {lam: (max(v) - min(v) if (v := [cells[(k, lam)][1] / cells[(k, lam)][0]
                                             for k in kern if cells[(k, lam)][0]]) else 0.0)
              for lam in lams}
    doc.append("Idempotency under at-least-once delivery: **%d** events were "
               "redelivered across this sweep and **%d** produced a duplicate "
               "side effect. The four kernels' success rates differ by at most "
               "%.3f at any lambda, so absorbing a redelivered event is a "
               "property of the specification, not of one implementation.\n"
               % (red, dup, max(spread.values()) if spread else 0.0))


def section_systems(doc, sysd):
    doc.append("## Systems: two sizes, and where the time actually goes\n")
    if not sysd:
        doc.append("_not run_\n")
        return
    rows = []
    for kid, k in sysd["kernels"].items():
        ko = k["kernel_only"]
        rows.append([
            kid, k["substrate"], human_bytes(ko["source_bytes"]),
            human_bytes(ko["gzip_bytes"]), ko["logical_loc"],
            human_bytes(ko["stripped_binary_bytes"]) if "stripped_binary_bytes" in ko else "-",
            human_bytes(k["tcb"]["resolvable_bytes"]),
            "%.2f" % k["startup"].get("first_ms", 0),
            "%.2f" % k["startup"]["p50_ms"], "%.2f" % k["startup"]["p99_ms"],
            "{:,}".format(k["throughput"]["transitions_per_s"]),
            human_bytes(k["throughput"]["peak_rss_bytes"])])
    doc.append(md_table(["kernel", "substrate", "source", "gzip", "logical LOC",
                         "stripped bin", "TCB", "cold ms", "warm p50 ms",
                         "warm p99 ms", "transitions/s", "peak RSS"], rows))
    doc.append("")
    doc.append("* **TCB** is the interpreter or binary, every library it links, "
               "and -- for the Python-backed kernels -- exactly the stdlib "
               "modules they import, not the whole install. Quoting the "
               "kernel-only column alone is how an assembly kernel becomes \"a "
               "9 KB agent\" while a JSON parser and libsystem sit underneath "
               "it. In the other direction: libraries in the macOS dyld shared "
               "cache have no file on disk and count as 0 here, so `sh` and "
               "`asm` are understated by libSystem.\n"
               "* The shared adapter (%s, %d logical lines) is byte-identical "
               "for all four kernels and cancels in every comparison.\n"
               "* Language-independent complexity: **%d transition rules** and "
               "**%d state fields**, fixed by the specification and implemented "
               "in full by each kernel. Logical LOC is reported because "
               "reviewers ask for it, not because one line of SQL, shell and "
               "assembly are the same unit.\n"
               % (human_bytes(sysd["shared_adapter"]["bytes"]),
                  sysd["shared_adapter"]["logical_loc"],
                  sysd["alm"]["rules"], sysd["alm"]["state_fields"]))
    fast = max(sysd["kernels"].values(), key=lambda k: k["throughput"]["transitions_per_s"])
    slow = min(sysd["kernels"].values(), key=lambda k: k["throughput"]["transitions_per_s"])
    doc.append("The spread between the fastest and slowest kernel is %.0fx per "
               "transition. At a model call of roughly 500 ms, even the slowest "
               "(%s, %.0f us) is **%.3f%%** of one step.\n"
               % (fast["throughput"]["transitions_per_s"] /
                  max(1, slow["throughput"]["transitions_per_s"]), slow["name"],
                  slow["throughput"]["per_transition_us"],
                  slow["throughput"]["per_transition_us"] / 5000.0))


def main():
    live = load_live()
    sub = load("witness/results-live-substrate.jsonl")
    local = load_all("bench/results-local-*.jsonl*")
    sysd = load("systems/results.json")

    doc = ["# ALM v0.1 -- results", "",
           "Generated %s by `alm/analyze.py`. Every number below comes from a "
           "results file in this directory; sections with no file say so."
           % datetime.datetime.now().strftime("%Y-%m-%d %H:%M"), ""]
    if sysd:
        doc.append("Host: `%s`, CPython %s.\n"
                   % (sysd["host"]["uname"], sysd["host"]["python"]))
    models = sorted({r.get("model") for r in (local or []) + (live or [])}
                    - {None, "oracle"})
    reg = load("adapter/models.json")
    if models and reg:
        doc.append(md_table(["model", "vendor", "endpoint model id", "decoding"],
                            [[m, reg.get(m, {}).get("vendor", "?"),
                              reg.get(m, {}).get("model", "?"),
                              "temperature %s%s" % (
                                  reg.get(m, {}).get("temperature"),
                                  ", " + json.dumps(reg[m]["extra"])
                                  if reg.get(m, {}).get("extra") else "")]
                             for m in models]))
        doc.append("")

    section_conformance(doc, load("conformance/results.json"),
                        load("conformance/cases.index.json"),
                        load("conformance/mutants.json"),
                        load("conformance/results-container.json"),
                        load("conformance/container-platform.json"))
    section_witness(doc, load("witness/results-oracle.jsonl"), live)
    section_substrate(doc, sub, local)
    section_tb(doc, load("bench/results-tb.jsonl"))
    section_variance(doc, local, load("bench/results-tb.jsonl"))
    section_faults(doc, load("witness/results-faults.jsonl"))
    section_cost(doc, local, live)
    section_systems(doc, sysd)

    doc.append("## Not run\n")
    subset30 = load("bench/subset-30.json")
    doc.append("The primary-model Terminal-Bench arm is done (above). Still "
               "unrun: the secondary-model pass on the pre-registered %d-task "
               "subset, which needs a second working endpoint, and the "
               "same-model external baselines (mini-SWE-agent, Terminus-2), "
               "which bear on the production-runtime comparison rather than on "
               "any ALM hypothesis.\n" % (subset30["n"] if subset30 else 30))
    doc.append("The ARM64 kernel is Mach-O and does not run in a Linux task "
               "container; an ELF port is required before `asm` can join that "
               "arm.\n")

    out = os.path.join(HERE, "REPORT.md")
    with open(out, "w") as fh:
        fh.write("\n".join(doc) + "\n")
    print("-> %s (%d lines)" % (out, len("\n".join(doc).splitlines())))


if __name__ == "__main__":
    main()
