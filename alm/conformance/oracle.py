#!/usr/bin/env python3
"""oracle.py -- a second derivation of ALM v0.1 s4, used to build cases.

The conformance criterion is not "the four kernels agree with each other" (four
identical misreadings would agree). It is "the four kernels agree with a
table-driven transition function written separately from any of them, on the
canonical trace, event by event". This file is that function.

It is deliberately shaped differently from kernels/museed.py: transitions are
looked up in RULES by (phase, event, status, action) and each rule is a small
mutation of a state dataclass.
"""

import hashlib

INIT, AWAIT_MODEL, AWAIT_TOOL, TERMINAL = "init", "await_model", "await_tool", "terminal"


class Oracle:
    def __init__(self, steps=16, repairs=2, retries=3, history_max=-1,
                 feedback=1, allow_halt=1, run="r1"):
        self.run = run
        self.b = dict(steps=steps, repairs=repairs, retries=retries,
                      history_max=history_max)
        self.feedback, self.allow_halt = feedback, allow_halt
        self.hist = []
        self.phase, self.step, self.attempt = INIT, 1, 1
        self.eidn, self.pending = 0, None
        self.steps_used = 0
        self.final = None
        self.effects, self.trace = [], []

    # -- helpers --------------------------------------------------------
    def _refs(self):
        hm = self.b["history_max"]
        sel = self.hist if hm < 0 else ([] if hm == 0 else self.hist[-hm:])
        return ",".join(sel) or "-"

    def _eid(self):
        self.eidn += 1
        self.pending = "e%d" % self.eidn
        return self.pending

    def _model_request(self):
        refs = self._refs()
        e = ('{"v":1,"t":"model_request","run":"%s","step":%d,"eid":"%s",'
             '"attempt":%d,"refs":"%s","steps_left":%d}'
             % (self.run, self.step, self._eid(), self.attempt, refs, self.b["steps"]))
        self.effects.append(e)
        return refs

    def _tool_request(self, tool, arg_ref):
        e = ('{"v":1,"t":"tool_request","run":"%s","step":%d,"eid":"%s",'
             '"tool":"%s","arg_ref":"%s"}'
             % (self.run, self.step, self._eid(), tool, arg_ref))
        self.effects.append(e)
        return arg_ref

    def _final(self, outcome, reason, status="-"):
        self.phase, self.pending = TERMINAL, None
        self.final = dict(outcome=outcome, reason=reason, status=status,
                          steps_used=self.steps_used)
        self.effects.append(
            '{"v":1,"t":"final","run":"%s","step":%d,"outcome":"%s","status":"%s",'
            '"reason":"%s","steps_used":%d}'
            % (self.run, self.step, outcome, status, reason, self.steps_used))
        return "-"

    def _rec(self, step, phase_in, event, status, action, refs, flag):
        self.trace.append("%d|%s|%s|%s|%s|%s|%d|%d|%d|%s|%s" % (
            step, phase_in, event, status, action, self.phase,
            self.b["steps"], self.b["repairs"], self.b["retries"], refs, flag))

    # -- rules ----------------------------------------------------------
    def start(self):
        p = self.phase
        self.phase = AWAIT_MODEL
        self._rec(self.step, p, "start", "-", "-", self._model_request(), "-")

    def _r_tool(self, ev):
        self.hist.append(ev["arg_ref"])
        self.phase = AWAIT_TOOL
        return ("ok", "tool", self._tool_request(ev["tool"], ev["arg_ref"]))

    def _r_halt(self, ev):
        if self.allow_halt:
            self.hist.append(ev["arg_ref"])
            return ("ok", "halt", self._final("halted", "model_halt", ev.get("halt", "ok")))
        self.hist.append(ev.get("arg_ref", "r0"))
        self.attempt += 1
        return ("invalid", "halt", self._model_request())

    def _r_invalid(self, ev):
        if self.b["repairs"] > 0:
            self.b["repairs"] -= 1
            self.hist.append(ev.get("arg_ref", "r0"))
            self.attempt += 1
            return ("invalid", "-", self._model_request())
        return ("invalid", "-", self._final("aborted", "protocol_exhausted"))

    def _r_transport(self, ev):
        if self.b["retries"] > 0:
            self.b["retries"] -= 1
            self.attempt += 1
            return ("transport_error", "-", self._model_request())
        return ("transport_error", "-", self._final("aborted", "transport_exhausted"))

    def _r_obs(self, ev):
        if self.feedback:
            self.hist.append(ev.get("obs_ref", "o0"))
        self.b["steps"] -= 1
        self.steps_used += 1
        if self.b["steps"] <= 0:
            return (ev["status"], "-", self._final("aborted", "budget_exhausted"))
        self.phase = AWAIT_MODEL
        self.step += 1
        self.attempt = 1
        return (ev["status"], "-", self._model_request())

    RULES = {
        (AWAIT_MODEL, "model_response", "ok", "tool"): "_r_tool",
        (AWAIT_MODEL, "model_response", "ok", "halt"): "_r_halt",
        (AWAIT_MODEL, "model_response", "invalid", None): "_r_invalid",
        (AWAIT_MODEL, "model_response", "transport_error", None): "_r_transport",
        (AWAIT_TOOL, "tool_response", "ok", None): "_r_obs",
        (AWAIT_TOOL, "tool_response", "error", None): "_r_obs",
        (AWAIT_TOOL, "tool_response", "timeout", None): "_r_obs",
    }

    def feed(self, ev):
        """Consume one event. Returns True iff an effect was emitted."""
        phase_in, step_in = self.phase, self.step
        t, status = ev.get("t", "?"), ev.get("status", "-")
        if phase_in == TERMINAL:
            self._rec(step_in, phase_in, t, status, "-", "-", "after_terminal")
            return False
        key = (phase_in, t, status, ev.get("action"))
        rule = self.RULES.get(key) or self.RULES.get((phase_in, t, status, None))
        if rule is None or ev.get("eid") != self.pending:
            self._rec(step_in, phase_in, t, status, "-", "-", "stale_event")
            return False
        st, action, refs = getattr(self, rule)(ev)
        self._rec(step_in, phase_in, t, st, action, refs, "-")
        return True

    def trace_hash(self):
        blob = "".join(line + "\n" for line in self.trace)
        return hashlib.sha256(blob.encode()).hexdigest()
