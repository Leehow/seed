#!/usr/bin/env python3
"""adapter.py -- mu and eps behind the ALM ABI.

The adapter owns everything the kernel is forbidden to touch: prompt bytes,
tool execution, the ref store, transport. It talks ABI v0.1 to any kernel in
kernels/registry.json, so the same mu and eps drive the Python, shell, SQL and
assembly kernels without knowing which one is on the other end.

Two policies for mu:

  oracle  an agent that plays optimally given exactly what the kernel let it
          see, and guesses uniformly when the needed fact is not there. It
          computes the information ceiling of an ablation arm with no API and
          no model variance.
  live    an OpenAI-compatible chat endpoint.
"""

import json
import os
import random
import re
import select
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))), "witness"))

READ_TIMEOUT = 300.0

DEFAULT_PROTOCOL = (
    "You are driving a tool loop through a text protocol. There is no "
    "function-calling API here: you act by emitting one line, the harness runs "
    "it, and you see the result on your next turn.\n"
    "\n"
    "Reply with EXACTLY ONE line, nothing else:\n"
    "  TOOL <name> <argument>\n"
    "  HALT <short report>\n"
    "\n"
    "The tools named in the task exist and are available to you this way and "
    "only this way. Emitting TOOL runs it. No human will answer a question, so "
    "never end a turn by asking one and never report that a tool is "
    "unavailable without having called it.\n"
    "No markdown, no code fences, no explanation, no second line."
)


def parse_record(line):
    """Effects may carry a comma inside `refs` (ABI s1 note 2a), so this end of
    the wire uses a real parser. Kernels do not need one."""
    body = line.strip()
    if not (body.startswith("{") and body.endswith("}")):
        return None
    try:
        return json.loads(body)
    except ValueError:
        return None


class Adapter:
    def __init__(self, kernel_argv, env, policy, kernel_env=None,
                 trace_path=None, obs_cap=4096, call_cap=None,
                 system_prompt=DEFAULT_PROTOCOL, duplicate_rate=0.0, seed=0,
                 transcript=None, render_obs=None, repair_note=None):
        self.argv = kernel_argv
        self.env = env
        self.policy = policy
        self.system_prompt = system_prompt
        # how a tool result is shown to mu. The kernel never sees any of this.
        self.repair_note = repair_note or (
            "your last reply was rejected (%s). Reply with exactly one line: "
            "TOOL <name> <arg>, or HALT <report>.")
        self.render_obs = render_obs or (
            lambda tool, code, text, truncated: "exit=%d %s" % (code, text))
        self.args = {}          # ref -> the raw tool argument bytes
        self.kernel_env = dict(kernel_env or {})
        self.trace_path = trace_path
        self.obs_cap = obs_cap
        self.refs = {}          # ref -> (kind, text)
        self.mn = self.on = self.rn = 0
        self.model_calls = 0
        self.transport_errors = 0
        self.invalids = 0
        steps = int(self.kernel_env.get("ALM_STEPS", 8))
        self.call_cap = call_cap or (4 * steps + 12)
        # at-least-once delivery, injected on purpose: every duplicate must be
        # absorbed by the kernel (ALM s4.6) and must not re-run a tool
        # a human-readable log of what mu was shown and what it said. Off by
        # default and behaviourally inert: it is for finding out why a run went
        # the way it did, which the canonical trace cannot tell you because the
        # kernel never sees the bytes.
        self.transcript = open(transcript, "w") if transcript else None
        self.duplicate_rate = duplicate_rate
        self.rng = random.Random(seed)
        self.duplicates_sent = 0
        self.tool_requests = 0
        # T_total = T_model + T_tool + T_orchestration (ALM's share is the rest)
        self.model_seconds = 0.0
        self.tool_seconds = 0.0
        self.prompt_tokens = self.completion_tokens = self.reasoning_tokens = 0

    # -- rendering: the only place prompt bytes exist ---------------------
    def render(self, refs):
        if refs == "-":
            entries = []
        else:
            entries = [self.refs[r] for r in refs.split(",") if r in self.refs]
        lines = []
        for kind, text in entries:
            if kind == "model_arg":
                lines.append("you: " + text)
            elif kind == "observation":
                lines.append("tool: " + text)
            else:
                lines.append("system: " + text)
        return lines

    def visible_observations(self, refs):
        if refs == "-":
            return []
        return [self.refs[r][1] for r in refs.split(",")
                if r in self.refs and self.refs[r][0] == "observation"]

    # -- the loop ---------------------------------------------------------
    def run(self):
        env_vars = dict(os.environ)
        env_vars.update(self.kernel_env)
        if self.trace_path:
            env_vars["ALM_TRACE"] = self.trace_path
        else:
            env_vars["ALM_TRACE"] = os.devnull
        proc = subprocess.Popen(self.argv, stdin=subprocess.PIPE,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=env_vars)
        buf = b""
        final = None
        t0 = time.time()
        capped = False

        def readline():
            nonlocal buf
            deadline = time.time() + READ_TIMEOUT
            while b"\n" not in buf:
                r, _, _ = select.select([proc.stdout], [], [],
                                        max(0.0, deadline - time.time()))
                if not r:
                    return None
                chunk = os.read(proc.stdout.fileno(), 65536)
                if not chunk:
                    return None
                buf += chunk
            line, _, buf = buf.partition(b"\n")
            return line.decode()

        while True:
            line = readline()
            if line is None:
                break
            eff = parse_record(line)
            if eff is None:
                continue
            if eff["t"] == "final":
                final = eff
                break
            if self.model_calls > self.call_cap:
                capped = True
                break
            if eff["t"] == "model_request":
                ev = self.answer_model(eff)
            else:
                self.tool_requests += 1
                ev = self.answer_tool(eff)
            try:
                proc.stdin.write((ev + "\n").encode())
                proc.stdin.flush()
                if self.duplicate_rate and self.rng.random() < self.duplicate_rate:
                    proc.stdin.write((ev + "\n").encode())   # redelivery
                    proc.stdin.flush()
                    self.duplicates_sent += 1
            except BrokenPipeError:
                break

        try:
            proc.stdin.close()
        except (BrokenPipeError, OSError):
            pass
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            proc.kill()
        proc.stdout.close()
        stderr = proc.stderr.read().decode()[:300]
        proc.stderr.close()
        if self.transcript:
            self.transcript.close()

        wall = time.time() - t0
        return {
            "final": final,
            "capped": capped,
            "model_seconds": round(self.model_seconds, 3),
            "tool_seconds": round(self.tool_seconds, 3),
            "orchestration_seconds": round(
                max(0.0, wall - self.model_seconds - self.tool_seconds), 4),
            "prompt_tokens": self.prompt_tokens,
            "completion_tokens": self.completion_tokens,
            "reasoning_tokens": self.reasoning_tokens,
            "success": bool(self.env.verify()),
            "model_calls": self.model_calls,
            "invalids": self.invalids,
            "transport_errors": self.transport_errors,
            "tool_calls": len(self.env.calls),
            "tool_requests": self.tool_requests,
            "duplicates_sent": self.duplicates_sent,
            "duplicate_side_effects": len(self.env.calls) - self.tool_requests,
            "seconds": round(wall, 3),
            "exit": proc.returncode,
            "stderr": stderr,
        }

    def log(self, kind, text):
        if self.transcript:
            self.transcript.write("\n===== %s =====\n%s\n" % (kind, text))
            self.transcript.flush()

    def answer_model(self, eff):
        self.model_calls += 1
        act = self.policy(self, eff)
        self.log("step %s -> action" % eff.get("step"),
                 " ".join(str(x)[:2000] for x in act))
        kind = act[0]
        if kind == "tool":
            _, name, arg = act
            self.mn += 1
            ref = "m%d" % self.mn
            self.refs[ref] = ("model_arg", "TOOL %s %s" % (name, arg))
            self.args[ref] = arg
            return ('{"v":1,"t":"model_response","eid":"%s","status":"ok",'
                    '"action":"tool","tool":"%s","arg_ref":"%s"}'
                    % (eff["eid"], name, ref))
        if kind == "halt":
            self.mn += 1
            ref = "m%d" % self.mn
            self.refs[ref] = ("model_arg", "HALT " + act[1])
            return ('{"v":1,"t":"model_response","eid":"%s","status":"ok",'
                    '"action":"halt","halt":"ok","arg_ref":"%s"}'
                    % (eff["eid"], ref))
        if kind == "transport":
            self.transport_errors += 1
            return ('{"v":1,"t":"model_response","eid":"%s",'
                    '"status":"transport_error","reason":"%s"}'
                    % (eff["eid"], act[1]))
        self.invalids += 1
        self.rn += 1
        ref = "r%d" % self.rn
        if act[1] == "output_truncated":
            note = ("Your last reply hit the output token limit before you "
                    "produced an action, so nothing was run. Think more briefly "
                    "and emit the action.")
        else:
            note = self.repair_note % act[1]
        self.refs[ref] = ("repair_note", note)
        return ('{"v":1,"t":"model_response","eid":"%s","status":"invalid",'
                '"reason":"%s","arg_ref":"%s"}' % (eff["eid"], act[1], ref))

    def answer_tool(self, eff):
        arg = self.args.get(eff["arg_ref"], "")
        t0 = time.time()
        status, code, text = self.env.call(eff["tool"], arg)
        self.tool_seconds += time.time() - t0
        truncated = 0
        if len(text) > self.obs_cap:
            text = text[:self.obs_cap] + "\n[truncated]"
            truncated = 1
        self.on += 1
        ref = "o%d" % self.on
        self.refs[ref] = ("observation",
                          self.render_obs(eff["tool"], code, text, truncated))
        self.log("tool %s exit=%d" % (eff["tool"], code), text[:2000])
        return ('{"v":1,"t":"tool_response","eid":"%s","status":"%s","exit":%d,'
                '"obs_ref":"%s","nbytes":%d,"truncated":%d}'
                % (eff["eid"], status, code, ref, len(text), truncated))


# ---------------------------------------------------------------- policies

def build_prompt(ad, eff):
    lines = ad.render(eff["refs"])
    body = "TASK: %s\n\n" % ad.env.prompt()
    if lines:
        body += "TRANSCRIPT SO FAR:\n" + "\n".join(lines) + "\n\n"
    else:
        body += "TRANSCRIPT SO FAR: (empty)\n\n"
    body += ("step %s of this run, %s tool calls remain.\nYour one-line reply:"
             % (eff["step"], eff["steps_left"]))
    return ad.system_prompt, body


def oracle_policy(ad, eff):
    """Optimal play given exactly the visible entries.

    Observation-driven rather than step-indexed, so that an injected tool
    failure costs a step instead of derailing a fixed plan: what degrades under
    fault injection is then the runtime's business, not a naive policy's. When
    the fact it needs is not visible, it guesses uniformly -- which is what
    makes this the information ceiling of an ablation arm.
    """
    import random
    fam = ad.env.family
    left = int(eff["steps_left"])
    obs = ad.visible_observations(eff["refs"])
    seen = " ".join(obs)
    rng = random.Random(ad.env.seed * 31 + int(eff["step"]))
    halt_refused = any(kind == "repair_note" for kind, _ in
                       (ad.refs[r] for r in eff["refs"].split(",") if r in ad.refs))
    last = obs[-1] if obs else ""

    def guess_hex():
        return "".join(rng.choice("0123456789abcdef") for _ in range(6))

    if fam == "feedback_required":
        from tasks import KEYS
        m = re.search(r"key=(\S+)", seen)
        if m:
            if "recorded" in last:
                return ("tool", "probe", "") if halt_refused else ("halt", "answered")
            return ("tool", "answer", m.group(1))
        if left <= 1:
            return ("tool", "answer", rng.choice(KEYS))
        return ("tool", "probe", "")

    if fam == "state_required":
        m = re.search(r"secret=([0-9a-f]{6})", seen)
        if m:
            if "recorded" in last:
                return ("tool", "noise", "") if halt_refused else ("halt", "answered")
            return ("tool", "answer", m.group(1))
        if left <= 1 or "E_ONCE" in seen:
            return ("tool", "answer", guess_hex())
        return ("tool", "reveal", "")

    if fam == "recovery_required":
        m = re.search(r"--token=([0-9a-f]{6})", seen)
        if "deployed" in seen:
            return ("tool", "deploy_safe", "--token=%s" % (m.group(1) if m else guess_hex())) \
                if halt_refused else ("halt", "deployed")
        if m or left <= 1:
            return ("tool", "deploy_safe",
                    "--token=%s" % (m.group(1) if m else guess_hex()))
        return ("tool", "deploy", "")

    # unknown_horizon
    if "finished" in seen:
        return ("tool", "finish", "") if halt_refused else ("halt", "done")
    if "DONE" in seen:
        return ("tool", "finish", "")
    if obs:
        return ("tool", "tick", "")
    # blind: commit to a horizon guess up front and stop there
    horizon = random.Random(ad.env.seed * 17).randint(1, 5)
    if int(eff["step"]) <= horizon and left > 1:
        return ("tool", "tick", "")
    return ("tool", "finish", "")


FENCE = re.compile(r"^```[a-zA-Z0-9_-]*\n|\n```$")


def parse_action(text):
    """TOOL/HALT on the first line; the argument may continue over later lines.

    Models reach for a one-line JSON-escaped string when told "exactly one
    line", so an argument that is wrapped in quotes and carries no real newline
    is unescaped rather than handed to the shell with literal backslash-n in
    it. That is a mu-side convenience; the kernel sees an action either way.
    """
    text = FENCE.sub("", (text or "").strip()).strip()
    if not text:
        return ("invalid", "empty_completion")
    first, _, tail = text.partition("\n")
    head = first.strip()
    if head.upper().startswith("HALT"):
        return ("halt", (head[4:].strip() or "done")[:120])
    if not head.upper().startswith("TOOL"):
        return ("invalid", "unknown_action")
    rest = head[4:].strip()
    if not rest:
        return ("invalid", "missing_field")
    name, _, inline = rest.partition(" ")
    name = re.sub(r"[^A-Za-z0-9_]", "", name)[:32]
    arg = inline.strip()
    if tail:
        arg = (arg + "\n" + tail) if arg else tail
    elif len(arg) > 1 and arg[0] == arg[-1] == '"':
        arg = (arg[1:-1].replace("\\n", "\n").replace("\\t", "\t")
               .replace('\\"', '"').replace("\\\\", "\\"))
    if not name:
        return ("invalid", "missing_field")
    return ("tool", name, arg)


def make_live_policy(client, parse=None):
    parse = parse or parse_action

    def live_policy(ad, eff):
        system, user = build_prompt(ad, eff)
        t0 = time.time()
        try:
            res = client.complete(system, user)
        except Exception as exc:                     # transport is mu's problem
            ad.model_seconds += time.time() - t0
            return ("transport", type(exc).__name__.lower()[:24])
        ad.model_seconds += res["seconds"]
        ad.prompt_tokens += res["prompt_tokens"]
        ad.completion_tokens += res["completion_tokens"]
        ad.reasoning_tokens += res["reasoning_tokens"]
        ad.log("step %s <- model (finish=%s, reasoning_tok=%s)"
               % (eff.get("step"), res.get("finish_reason"),
                  res.get("reasoning_tokens")), res["text"][:2500])
        if res.get("finish_reason") == "length" and not (res["text"] or "").strip():
            # a reasoning model can spend the whole output budget thinking and
            # return no visible content at all. That is not the model failing to
            # follow the protocol, and calling it a protocol error spends the
            # kernel's repair budget on a mistake the adapter made.
            return ("invalid", "output_truncated")
        return parse(res["text"])
    return live_policy
