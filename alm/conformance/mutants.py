#!/usr/bin/env python3
"""mutants.py -- does the conformance suite actually detect a broken kernel?

A suite that four kernels pass is worthless unless it can fail. This applies
one small semantic mutation at a time to the reference kernel -- each one a
plausible implementation mistake, not a syntax error -- and reports how many of
the 300 cases catch it.

    python3 alm/conformance/mutants.py

A mutant that no case detects is a hole in the suite and is reported as such.
"""

import argparse
import json
import os
import shutil
import sys
import tempfile
from concurrent.futures import ProcessPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
ALM = os.path.dirname(HERE)
sys.path.insert(0, HERE)
from run import run_case                                     # noqa: E402

REFERENCE = os.path.join(ALM, "kernels", "museed.py")

# name -> (description, old, new)
MUTATIONS = [
    ("budget-never-spent", "steps_left is not decremented on a tool response",
     "        self.steps_left -= 1\n        self.steps_used += 1",
     "        self.steps_used += 1"),
    ("repairs-unbounded", "protocol repair ignores its budget",
     "            if self.repairs_left > 0:\n                self.repairs_left -= 1",
     "            if True:\n                self.repairs_left -= 0"),
    ("retries-unbounded", "transport retry ignores its budget",
     "            if self.retries_left > 0:\n                self.retries_left -= 1",
     "            if True:\n                self.retries_left -= 0"),
    ("accepts-stale-eid", "an event answering an old effect is processed",
     "        if eid != self.pending or not known:",
     "        if not known:"),
    ("terminal-not-absorbing", "events after final are processed again",
     "        if self.phase == TERMINAL:\n            self.rec(step_in, phase_in, t, ev.get(\"status\", \"-\"), \"-\", \"-\", \"after_terminal\")\n            return",
     "        if self.phase == TERMINAL:\n            self.rec(step_in, phase_in, t, ev.get(\"status\", \"-\"), \"-\", \"-\", \"after_terminal\")"),
    ("feedback-always-on", "the observation is appended even when feedback is off",
     "        if self.feedback:\n            self.hist.append((ev.get(\"obs_ref\", \"o0\"), \"observation\"))",
     "        self.hist.append((ev.get(\"obs_ref\", \"o0\"), \"observation\"))"),
    ("history-unbounded", "history_max is ignored when selecting refs",
     "        if self.history_max < 0:\n            sel = self.hist",
     "        if True:\n            sel = self.hist"),
    ("repair-loses-note", "a protocol repair does not show the model its error",
     "                self.hist.append((ev.get(\"arg_ref\", \"r0\"), \"repair_note\"))\n                self.attempt += 1",
     "                self.attempt += 1"),
    ("retry-appends-note", "a transport retry pretends the model answered",
     "            if self.retries_left > 0:\n                self.retries_left -= 1\n                self.attempt += 1",
     "            if self.retries_left > 0:\n                self.retries_left -= 1\n                self.hist.append((ev.get(\"arg_ref\", \"r0\"), \"repair_note\"))\n                self.attempt += 1"),
    ("transport-is-repair", "a failed model call is charged to the repair budget",
     "        if status == \"transport_error\":\n            if self.retries_left > 0:",
     "        if status == \"transport_error\":\n            if self.repairs_left > 0:"),
    ("step-never-advances", "the step counter stays at 1",
     "        self.phase = AWAIT_MODEL\n        self.step += 1\n        self.attempt = 1",
     "        self.phase = AWAIT_MODEL\n        self.attempt = 1"),
    ("attempt-never-resets", "attempt is not reset at a new step",
     "        self.step += 1\n        self.attempt = 1",
     "        self.step += 1"),
    ("budget-off-by-one", "the run stops one step early",
     "        if self.steps_left <= 0:",
     "        if self.steps_left <= 1:"),
    ("halt-status-dropped", "the model's own verdict is not recorded",
     "                self.send_final(\"halted\", \"model_halt\", ev.get(\"halt\", \"ok\"))",
     "                self.send_final(\"halted\", \"model_halt\", \"ok\")"),
    ("allow-halt-ignored", "the fixed-horizon knob is not honoured",
     "            if self.allow_halt:\n                self.hist.append((ev[\"arg_ref\"], \"model_arg\"))",
     "            if True:\n                self.hist.append((ev[\"arg_ref\"], \"model_arg\"))"),
    ("refused-halt-spends-repair", "a refused halt is charged to the repair budget",
     "            self.hist.append((ev.get(\"arg_ref\", \"r0\"), \"repair_note\"))\n            self.attempt += 1\n            refs = self.send_model_request()\n            self.rec(step_in, phase_in, \"model_response\", \"invalid\", \"halt\", refs, \"-\")",
     "            self.repairs_left -= 1\n            self.hist.append((ev.get(\"arg_ref\", \"r0\"), \"repair_note\"))\n            self.attempt += 1\n            refs = self.send_model_request()\n            self.rec(step_in, phase_in, \"model_response\", \"invalid\", \"halt\", refs, \"-\")"),
    ("unknown-action-repaired", "an unrecognised action is guessed at instead of ignored",
     "                 (st in (\"invalid\", \"transport_error\") or\n                  (st == \"ok\" and act in (\"tool\", \"halt\")))",
     "                 (st in (\"invalid\", \"transport_error\") or st == \"ok\")"),
]


def build(tmp, name, old, new):
    with open(REFERENCE) as fh:
        src = fh.read()
    if old not in src:
        return None
    path = os.path.join(tmp, "mutant_%s.py" % name.replace("-", "_"))
    with open(path, "w") as fh:
        fh.write(src.replace(old, new, 1))
    return path


def _job(args):
    path, case_path = args
    with open(case_path) as fh:
        case = json.load(fh)
    try:
        r = run_case({"argv": ["python3", path]}, case)
    except Exception as exc:
        r = {"id": case["id"], "ok": False, "problems": [repr(exc)]}
    return r["id"], r["ok"], (r.get("problems") or [""])[0].split("\n")[0]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cases", default=os.path.join(HERE, "cases"))
    ap.add_argument("--jobs", type=int, default=os.cpu_count() or 4)
    ap.add_argument("--out", default=os.path.join(HERE, "mutants.json"))
    a = ap.parse_args()

    paths = sorted(os.path.join(a.cases, f) for f in os.listdir(a.cases)
                   if f.endswith(".json"))
    tmp = tempfile.mkdtemp(prefix="alm-mutants-")
    report = {"cases": len(paths), "mutants": []}
    print("%-24s %6s %6s  %s" % ("mutant", "caught", "rate", "first symptom"))
    undetected = 0
    try:
        for name, why, old, new in MUTATIONS:
            path = build(tmp, name, old, new)
            if path is None:
                print("%-24s %6s  (mutation site not found -- kernel changed?)"
                      % (name, "SKIP"))
                report["mutants"].append({"name": name, "applied": False})
                continue
            with ProcessPoolExecutor(max_workers=a.jobs) as pool:
                results = list(pool.map(_job, [(path, p) for p in paths],
                                        chunksize=8))
            failed = [r for r in results if not r[1]]
            symptom = failed[0][2][:60] if failed else "NOT DETECTED"
            if not failed:
                undetected += 1
            print("%-24s %6d %5.1f%%  %s"
                  % (name, len(failed), 100.0 * len(failed) / len(results), symptom))
            report["mutants"].append({
                "name": name, "applied": True, "description": why,
                "cases_failed": len(failed), "cases": len(results),
                "detection_rate": len(failed) / len(results),
                "first_symptom": symptom,
                "detected_by": sorted({f[0].rsplit("-", 1)[0] for f in failed}),
            })
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    report["undetected"] = undetected
    with open(a.out, "w") as fh:
        json.dump(report, fh, indent=1)
    print("\n%d/%d mutants detected; %d slipped through -> %s"
          % (len(MUTATIONS) - undetected, len(MUTATIONS), undetected, a.out))
    return 1 if undetected else 0


if __name__ == "__main__":
    sys.exit(main())
