#!/usr/bin/env python3
"""gen_cases.py -- generate the 300-case ALM v0.1 conformance suite.

Six categories of 50. Every case is fully deterministic: the model, the tools
and the faults are all recorded, so a case exercises kappa and only kappa.

    python3 alm/conformance/gen_cases.py [--out DIR] [--seed 20260828]

Each case is one JSON file:

    id, category, env            kernel configuration (ABI s5)
    events[]                     {line, expect_effect} in delivery order
    expect_trace[]               canonical trace records (ALM s5)
    expect_trace_sha256          the trace hash
    expect_final                 outcome/reason/status/steps_used
"""

import argparse
import json
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from oracle import Oracle, AWAIT_MODEL, AWAIT_TOOL, TERMINAL

TOOLS = ["shell", "edit", "probe", "read_key", "http", "unknown_tool"]
INVALID_REASONS = ["bad_json", "unknown_action", "missing_field",
                   "empty_completion", "truncated_stream"]
TRANSPORT_REASONS = ["http_429", "http_500", "conn_reset", "sse_split"]


class Builder:
    """Drives an Oracle and records the event lines that drove it."""

    def __init__(self, rng, **cfg):
        self.rng = rng
        self.o = Oracle(**cfg)
        self.events = []
        self.mn = self.on = self.rn = 0
        self.last_line = None
        self.last_obs_status = None

    # -- event constructors (eid taken from the oracle's pending effect) --
    def _send(self, line, ev):
        expect = self.o.feed(ev)
        self.events.append({"line": line, "expect_effect": expect})
        self.last_line = line

    def tool(self, name=None):
        name = name or self.rng.choice(TOOLS[:5])
        self.mn += 1
        ref = "m%d" % self.mn
        eid = self.o.pending
        self._send('{"v":1,"t":"model_response","eid":"%s","status":"ok","action":"tool",'
                   '"tool":"%s","arg_ref":"%s"}' % (eid, name, ref),
                   dict(t="model_response", eid=eid, status="ok", action="tool",
                        tool=name, arg_ref=ref))

    def halt(self, verdict="ok"):
        self.mn += 1
        ref = "m%d" % self.mn
        eid = self.o.pending
        self._send('{"v":1,"t":"model_response","eid":"%s","status":"ok","action":"halt",'
                   '"halt":"%s","arg_ref":"%s"}' % (eid, verdict, ref),
                   dict(t="model_response", eid=eid, status="ok", action="halt",
                        halt=verdict, arg_ref=ref))

    def invalid(self, reason=None):
        reason = reason or self.rng.choice(INVALID_REASONS)
        self.rn += 1
        ref = "r%d" % self.rn
        eid = self.o.pending
        self._send('{"v":1,"t":"model_response","eid":"%s","status":"invalid",'
                   '"reason":"%s","arg_ref":"%s"}' % (eid, reason, ref),
                   dict(t="model_response", eid=eid, status="invalid",
                        reason=reason, arg_ref=ref))

    def transport(self, reason=None):
        reason = reason or self.rng.choice(TRANSPORT_REASONS)
        eid = self.o.pending
        self._send('{"v":1,"t":"model_response","eid":"%s","status":"transport_error",'
                   '"reason":"%s"}' % (eid, reason),
                   dict(t="model_response", eid=eid, status="transport_error",
                        reason=reason))

    def obs(self, status="ok", exit_code=None, nbytes=None, truncated=0):
        if exit_code is None:
            exit_code = {"ok": 0, "error": self.rng.choice([1, 2, 127]), "timeout": -1}[status]
        if nbytes is None:
            nbytes = 0 if status == "timeout" else self.rng.randint(0, 4096)
        self.on += 1
        ref = "o%d" % self.on
        eid = self.o.pending
        self.last_obs_status = status
        self._send('{"v":1,"t":"tool_response","eid":"%s","status":"%s","exit":%d,'
                   '"obs_ref":"%s","nbytes":%d,"truncated":%d}'
                   % (eid, status, exit_code, ref, nbytes, truncated),
                   dict(t="tool_response", eid=eid, status=status, exit=exit_code,
                        obs_ref=ref, nbytes=nbytes, truncated=truncated))

    # -- fault injections: none of these may move the machine -------------
    def dup(self):
        if self.last_line is None:
            return
        line = self.last_line
        ev = json.loads(line)
        self._send(line, ev)

    def stale(self):
        eid = "e900"
        self._send('{"v":1,"t":"model_response","eid":"%s","status":"ok","action":"halt",'
                   '"halt":"ok","arg_ref":"m99"}' % eid,
                   dict(t="model_response", eid=eid, status="ok", action="halt",
                        halt="ok", arg_ref="m99"))

    def cross(self):
        """Right eid, wrong phase."""
        eid = self.o.pending or "e1"
        if self.o.phase == AWAIT_MODEL:
            self._send('{"v":1,"t":"tool_response","eid":"%s","status":"ok","exit":0,'
                       '"obs_ref":"o99","nbytes":1,"truncated":0}' % eid,
                       dict(t="tool_response", eid=eid, status="ok", exit=0,
                            obs_ref="o99", nbytes=1, truncated=0))
        else:
            self._send('{"v":1,"t":"model_response","eid":"%s","status":"ok","action":"tool",'
                       '"tool":"shell","arg_ref":"m99"}' % eid,
                       dict(t="model_response", eid=eid, status="ok", action="tool",
                            tool="shell", arg_ref="m99"))

    def bad_action(self):
        eid = self.o.pending or "e1"
        self._send('{"v":1,"t":"model_response","eid":"%s","status":"ok",'
                   '"action":"frobnicate","tool":"shell","arg_ref":"m97"}' % eid,
                   dict(t="model_response", eid=eid, status="ok",
                        action="frobnicate", tool="shell", arg_ref="m97"))

    def bad_status(self):
        eid = self.o.pending or "e1"
        self._send('{"v":1,"t":"model_response","eid":"%s","status":"weird_status",'
                   '"action":"tool","tool":"shell","arg_ref":"m98"}' % eid,
                   dict(t="model_response", eid=eid, status="weird_status",
                        action="tool", tool="shell", arg_ref="m98"))

    def unknown_type(self):
        eid = self.o.pending or "e1"
        self._send('{"v":1,"t":"heartbeat","eid":"%s","status":"ok"}' % eid,
                   dict(t="heartbeat", eid=eid, status="ok"))

    # -- close out --------------------------------------------------------
    def finish(self, tail_faults=0):
        # with halting disabled there is no way out but the budget, so close the
        # case with work rather than with a halt the kernel will keep refusing
        guard = 0
        while self.o.phase != TERMINAL and guard < 400:
            guard += 1
            if self.o.phase == AWAIT_TOOL:
                self.obs("ok")
            elif self.o.allow_halt:
                self.halt("ok")
            else:
                self.tool()
        for _ in range(tail_faults):
            self.dup()


def case_normal(b, rng):
    for _ in range(rng.randint(1, 10)):
        b.tool()
        b.obs("ok")
        if b.o.phase == TERMINAL:
            return
    b.halt("ok" if rng.random() < 0.85 else "fail")


def case_branch(b, rng):
    for _ in range(rng.randint(2, 8)):
        b.tool()
        st = rng.choice(["ok", "ok", "error", "timeout"])
        b.obs(st)
        if b.o.phase == TERMINAL:
            return
        # the adapter's next move depends on what it just observed
        if b.last_obs_status == "error":
            b.tool("shell")
            b.obs("ok")
        elif b.last_obs_status == "timeout":
            b.invalid("truncated_stream") if rng.random() < 0.3 else b.tool("probe")
            if b.o.phase == AWAIT_TOOL:
                b.obs("ok")
        if b.o.phase == TERMINAL:
            return
    b.halt("ok")


def case_protocol(b, rng):
    n = rng.randint(1, 5)
    for _ in range(n):
        if b.o.phase == TERMINAL:
            return
        # a run's two failure channels: ill-formed model output (repairs) and a
        # model call that never landed (retries)
        b.transport() if rng.random() < 0.4 else b.invalid()
        if b.o.phase == TERMINAL:
            return
        if rng.random() < 0.5:
            b.tool()
            b.obs("ok")
        if b.o.phase == TERMINAL:
            return
    if b.o.phase == AWAIT_MODEL:
        b.halt("ok")


def case_envfault(b, rng):
    for _ in range(rng.randint(1, 6)):
        if b.o.phase == TERMINAL:
            return
        b.tool(rng.choice(TOOLS))
        b.obs(rng.choice(["error", "timeout", "error"]),
              truncated=1 if rng.random() < 0.3 else 0)
        if b.o.phase == TERMINAL:
            return
    b.halt(rng.choice(["ok", "fail"]))


def case_budget(b, rng):
    for _ in range(20):
        if b.o.phase == TERMINAL:
            return
        if b.o.phase == AWAIT_MODEL:
            b.tool()
        else:
            b.obs(rng.choice(["ok", "ok", "error"]),
                  nbytes=rng.choice([0, 65536, 65537]),
                  truncated=rng.choice([0, 1]))


def case_ext(b, rng):
    """profile ext: the ablation knobs are part of the contract too."""
    for _ in range(rng.randint(1, 6)):
        if b.o.phase == TERMINAL:
            return
        if b.o.phase == AWAIT_MODEL:
            roll = rng.random()
            if roll < 0.15:
                b.invalid()
            elif roll < 0.70:
                b.tool()
            else:
                # a halt against allow_halt=0 must be refused without spending a
                # repair, so the case sends one on purpose
                b.halt("ok")
        else:
            b.obs(rng.choice(["ok", "ok", "error", "timeout"]))


def case_idem(b, rng):
    faults = [b.dup, b.stale, b.cross, b.unknown_type, b.bad_status, b.bad_action]
    for _ in range(rng.randint(2, 6)):
        if b.o.phase == TERMINAL:
            break
        rng.choice(faults)()
        if b.o.phase == AWAIT_MODEL:
            b.tool()
        else:
            b.obs("ok")
        rng.choice(faults)()
    b.finish(tail_faults=rng.randint(1, 3))


CATEGORIES = [
    ("normal", case_normal, lambda rng: {}),
    ("branch", case_branch, lambda rng: {}),
    ("protocol", case_protocol, lambda rng: {"repairs": rng.choice([0, 1, 2, 3]),
                                             "retries": rng.choice([0, 1, 3])}),
    ("envfault", case_envfault, lambda rng: {}),
    ("budget", case_budget, lambda rng: {"steps": rng.choice([1, 2, 3, 5, 8]),
                                         "history_max": rng.choice([-1, -1, 1, 2, 3])}),
    ("idempotency", case_idem, lambda rng: {}),
    ("ext", case_ext, lambda rng: {"feedback": rng.choice([0, 0, 1]),
                                   "allow_halt": rng.choice([0, 1, 1]),
                                   "history_max": rng.choice([-1, 0, 1, 2]),
                                   "steps": rng.choice([2, 3, 5, 8])}),
]


RULE_LABELS = [
    ("start", "s4.1 start"),
    ("tool", "s4.2 model calls a tool"),
    ("halt", "s4.3 model halts"),
    ("halt_disabled", "s8 halt refused (ext)"),
    ("repair", "s4.5 protocol repair"),
    ("abort_protocol", "s4.5 repairs exhausted"),
    ("retry", "s4.5 transport retry"),
    ("abort_transport", "s4.5 retries exhausted"),
    ("observe", "s4.4 observation, run continues"),
    ("abort_budget", "s4.4 budget exhausted"),
    ("stale_event", "s4.6 event ignored"),
    ("after_terminal", "s4.6 event after terminal"),
]


def classify(record):
    """Which ALM rule fired, read back off a canonical trace record."""
    f = record.split("|")
    event, status, action, phase_out, flag = f[2], f[3], f[4], f[5], f[10]
    if flag != "-":
        return flag
    if event == "start":
        return "start"
    if event == "model_response":
        if status == "ok" and action == "tool":
            return "tool"
        if status == "ok" and action == "halt":
            return "halt"
        if status == "invalid" and action == "halt":
            return "halt_disabled"
        if status == "invalid":
            return "abort_protocol" if phase_out == "terminal" else "repair"
        if status == "transport_error":
            return "abort_transport" if phase_out == "terminal" else "retry"
    if event == "tool_response":
        return "abort_budget" if phase_out == "terminal" else "observe"
    return "?"


def main():
    ap = argparse.ArgumentParser()
    here = os.path.dirname(os.path.abspath(__file__))
    ap.add_argument("--out", default=os.path.join(here, "cases"))
    ap.add_argument("--seed", type=int, default=20260828)
    ap.add_argument("--per-category", type=int, default=50)
    a = ap.parse_args()

    os.makedirs(a.out, exist_ok=True)
    for stale_file in os.listdir(a.out):
        if stale_file.endswith(".json"):
            os.remove(os.path.join(a.out, stale_file))

    rng = random.Random(a.seed)
    total = 0
    index = []
    coverage = {}
    for name, fn, cfgfn in CATEGORIES:
        for i in range(1, a.per_category + 1):
            cfg = {"steps": rng.choice([4, 8, 16, 16, 32]),
                   "repairs": rng.choice([0, 1, 2, 2]),
                   "retries": rng.choice([0, 1, 3, 3])}
            cfg.update(cfgfn(rng))
            b = Builder(rng, **cfg)
            b.o.start()
            fn(b, rng)
            b.finish()
            env = {"ALM_RUN": "r1", "ALM_STEPS": str(cfg["steps"]),
                   "ALM_REPAIRS": str(cfg["repairs"]),
                   "ALM_RETRIES": str(cfg["retries"]),
                   "ALM_HISTORY_MAX": str(cfg.get("history_max", -1)),
                   "ALM_FEEDBACK": str(cfg.get("feedback", 1)),
                   "ALM_ALLOW_HALT": str(cfg.get("allow_halt", 1))}
            cid = "%s-%03d" % (name, i)
            case = {
                "id": cid, "category": name, "env": env,
                "events": b.events,
                "expect_effects": b.o.effects,
                "expect_trace": b.o.trace,
                "expect_trace_sha256": b.o.trace_hash(),
                "expect_final": b.o.final,
            }
            assert b.o.final is not None, cid
            with open(os.path.join(a.out, cid + ".json"), "w") as fh:
                json.dump(case, fh, indent=1)
            for rec in b.o.trace:
                r = classify(rec)
                cov = coverage.setdefault(r, {"records": 0, "cases": set()})
                cov["records"] += 1
                cov["cases"].add(cid)
            index.append({"id": cid, "category": name,
                          "events": len(b.events),
                          "sha256": b.o.trace_hash(),
                          "outcome": b.o.final["outcome"],
                          "reason": b.o.final["reason"]})
            total += 1
    cov_out = {}
    for rule, label in RULE_LABELS:
        c = coverage.get(rule, {"records": 0, "cases": set()})
        cov_out[rule] = {"label": label, "records": c["records"],
                         "cases": len(c["cases"])}
    with open(os.path.join(a.out, "..", "cases.index.json"), "w") as fh:
        json.dump({"seed": a.seed, "count": total, "coverage": cov_out,
                   "cases": index}, fh, indent=1)
    missed = [r for r, v in cov_out.items() if v["records"] == 0]
    if missed:
        print("WARNING: rules never exercised: %s" % ", ".join(missed))
    by_reason = {}
    for c in index:
        by_reason[c["reason"]] = by_reason.get(c["reason"], 0) + 1
    print("%d cases in %s" % (total, a.out))
    print("terminal reasons:", json.dumps(by_reason, sort_keys=True))


if __name__ == "__main__":
    main()
