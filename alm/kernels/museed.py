#!/usr/bin/env python3
"""museed.py -- ALM v0.1 reference kernel (mu-Seed-Python).

This is kappa and nothing else: state, budget, phase, termination. It never
reads the bytes behind a ref (ALM v0.1 s2.1), so it has no prompt to build and
no tool to run. The adapter on the other end of stdin/stdout owns mu and eps.

  stdin   events   (one canonical JSONL record per line, ABI v0.1 s4)
  stdout  effects  (ABI v0.1 s3)
  fd 3    canonical trace records (ALM v0.1 s5); $ALM_TRACE overrides

Exit 0 after final, 2 on internal error, 3 on EOF before terminal.
"""

import os
import sys

VERSION = "alm-0.1"

INIT, AWAIT_MODEL, AWAIT_TOOL, TERMINAL = "init", "await_model", "await_tool", "terminal"


def env_int(name, default):
    v = os.environ.get(name)
    if v is None or v == "":
        return default
    try:
        return int(v)
    except ValueError:
        return default


class Kernel:
    def __init__(self, out, trace):
        self.out = out
        self.trace = trace
        self.run = os.environ.get("ALM_RUN", "r1")
        # B
        self.steps_left = env_int("ALM_STEPS", 16)
        self.repairs_left = env_int("ALM_REPAIRS", 2)
        self.retries_left = env_int("ALM_RETRIES", 3)
        self.history_max = env_int("ALM_HISTORY_MAX", -1)
        # ext knobs
        self.feedback = env_int("ALM_FEEDBACK", 1)
        self.allow_halt = env_int("ALM_ALLOW_HALT", 1)
        # H
        self.hist = []          # list of (ref, kind)
        # Q, R
        self.phase = INIT
        self.step = 1
        self.attempt = 1
        self.eid_n = 0
        self.pending = None
        self.steps_used = 0
        self.outcome = None
        self.reason = None
        self.status = "-"

    # ---- plumbing ----------------------------------------------------

    def emit(self, line):
        self.out.write(line + "\n")
        self.out.flush()

    def next_eid(self):
        self.eid_n += 1
        eid = "e%d" % self.eid_n
        self.pending = eid
        return eid

    def refs(self):
        if self.history_max < 0:
            sel = self.hist
        elif self.history_max == 0:
            sel = []
        else:
            sel = self.hist[-self.history_max:]
        return ",".join(r for r, _ in sel) or "-"

    def rec(self, step, phase_in, event, status, action, refs, flag):
        self.trace.write("%d|%s|%s|%s|%s|%s|%d|%d|%d|%s|%s\n" % (
            step, phase_in, event, status, action, self.phase,
            self.steps_left, self.repairs_left, self.retries_left, refs, flag))
        self.trace.flush()

    # ---- effects -----------------------------------------------------

    def send_model_request(self):
        refs = self.refs()
        eid = self.next_eid()
        self.emit('{"v":1,"t":"model_request","run":"%s","step":%d,"eid":"%s",'
                  '"attempt":%d,"refs":"%s","steps_left":%d}'
                  % (self.run, self.step, eid, self.attempt, refs, self.steps_left))
        return refs

    def send_tool_request(self, tool, arg_ref):
        eid = self.next_eid()
        self.emit('{"v":1,"t":"tool_request","run":"%s","step":%d,"eid":"%s",'
                  '"tool":"%s","arg_ref":"%s"}'
                  % (self.run, self.step, eid, tool, arg_ref))
        return arg_ref

    def send_final(self, outcome, reason, status="-"):
        self.phase = TERMINAL
        self.pending = None
        self.outcome, self.reason, self.status = outcome, reason, status
        self.emit('{"v":1,"t":"final","run":"%s","step":%d,"outcome":"%s",'
                  '"status":"%s","reason":"%s","steps_used":%d}'
                  % (self.run, self.step, outcome, status, reason, self.steps_used))

    # ---- transitions -------------------------------------------------

    def start(self):
        phase_in = self.phase
        self.phase = AWAIT_MODEL
        refs = self.send_model_request()
        self.rec(self.step, phase_in, "start", "-", "-", refs, "-")

    def on_event(self, ev):
        t = ev.get("t", "?")
        phase_in = self.phase
        step_in = self.step
        eid = ev.get("eid")

        if self.phase == TERMINAL:
            self.rec(step_in, phase_in, t, ev.get("status", "-"), "-", "-", "after_terminal")
            return
        st, act = ev.get("status"), ev.get("action")
        known = (t == "model_response" and self.phase == AWAIT_MODEL and
                 (st in ("invalid", "transport_error") or
                  (st == "ok" and act in ("tool", "halt")))) or \
                (t == "tool_response" and self.phase == AWAIT_TOOL and
                 st in ("ok", "error", "timeout"))
        if eid != self.pending or not known:
            self.rec(step_in, phase_in, t, ev.get("status", "-"), "-", "-", "stale_event")
            return

        if t == "model_response":
            self.on_model(ev, step_in, phase_in)
        else:
            self.on_tool(ev, step_in, phase_in)

    def on_model(self, ev, step_in, phase_in):
        status = ev.get("status", "invalid")

        if status == "ok" and ev.get("action") == "tool":
            self.hist.append((ev["arg_ref"], "model_arg"))
            self.phase = AWAIT_TOOL
            refs = self.send_tool_request(ev.get("tool", "unknown"), ev["arg_ref"])
            self.rec(step_in, phase_in, "model_response", "ok", "tool", refs, "-")
            return

        if status == "ok" and ev.get("action") == "halt":
            if self.allow_halt:
                self.hist.append((ev["arg_ref"], "model_arg"))
                self.send_final("halted", "model_halt", ev.get("halt", "ok"))
                self.rec(step_in, phase_in, "model_response", "ok", "halt", "-", "-")
                return
            # ext: fixed-horizon. A disabled halt is a protocol error that does
            # not spend a repair, else the arm would abort instead of running on.
            self.hist.append((ev.get("arg_ref", "r0"), "repair_note"))
            self.attempt += 1
            refs = self.send_model_request()
            self.rec(step_in, phase_in, "model_response", "invalid", "halt", refs, "-")
            return

        if status == "invalid":
            if self.repairs_left > 0:
                self.repairs_left -= 1
                self.hist.append((ev.get("arg_ref", "r0"), "repair_note"))
                self.attempt += 1
                refs = self.send_model_request()
                self.rec(step_in, phase_in, "model_response", "invalid", "-", refs, "-")
            else:
                self.send_final("aborted", "protocol_exhausted")
                self.rec(step_in, phase_in, "model_response", "invalid", "-", "-", "-")
            return

        if status == "transport_error":
            if self.retries_left > 0:
                self.retries_left -= 1
                self.attempt += 1
                refs = self.send_model_request()
                self.rec(step_in, phase_in, "model_response", "transport_error", "-", refs, "-")
            else:
                self.send_final("aborted", "transport_exhausted")
                self.rec(step_in, phase_in, "model_response", "transport_error", "-", "-", "-")
            return


    def on_tool(self, ev, step_in, phase_in):
        status = ev.get("status", "error")
        if self.feedback:
            self.hist.append((ev.get("obs_ref", "o0"), "observation"))
        self.steps_left -= 1
        self.steps_used += 1
        if self.steps_left <= 0:
            self.send_final("aborted", "budget_exhausted")
            self.rec(step_in, phase_in, "tool_response", status, "-", "-", "-")
            return
        self.phase = AWAIT_MODEL
        self.step += 1
        self.attempt = 1
        refs = self.send_model_request()
        self.rec(step_in, phase_in, "tool_response", status, "-", refs, "-")


# ---- narrow-dialect parser (ABI v0.1 s1) -----------------------------

def parse(line):
    """Parse one canonical JSONL record. No nesting, no escapes."""
    out = {}
    body = line.strip()
    if not (body.startswith("{") and body.endswith("}")):
        return None
    for field in body[1:-1].split(","):
        k, _, v = field.partition(":")
        k = k.strip().strip('"')
        v = v.strip()
        if v.startswith('"'):
            out[k] = v.strip('"')
        else:
            try:
                out[k] = int(v)
            except ValueError:
                out[k] = v
    return out


def main():
    trace_path = os.environ.get("ALM_TRACE")
    if trace_path:
        trace = open(trace_path, "w")
    else:
        try:
            trace = os.fdopen(3, "w")
        except OSError:
            trace = open(os.devnull, "w")

    k = Kernel(sys.stdout, trace)
    k.start()
    for line in sys.stdin:
        if not line.strip():
            continue
        ev = parse(line)
        if ev is None:
            continue
        k.on_event(ev)          # terminal is absorbing; keep draining so that
                                # at-least-once redelivery is observable (s4.6)
    trace.close()
    if k.phase != TERMINAL:
        return 3
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(0)
    except Exception as exc:                      # kernel bug, not an abort
        sys.stderr.write("museed: internal error: %r\n" % (exc,))
        sys.exit(2)
