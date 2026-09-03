#!/usr/bin/env python3
"""tasks.py -- necessity witnesses for the ALM core.

Terminal-Bench cannot separate "the agent needed feedback" from "the model
happened to write a correct script in one shot". These four families can: each
one is built so that a controller missing one specific piece of the ALM core
provably cannot be right on every instance, whatever model drives it.

  feedback_required   the second action depends on a value only the first
                      action's observation can reveal
  state_required      information appears once and is not re-readable, so it
                      must survive in some carrier the next decision can see
  recovery_required   the tool fails on purpose and the error names the way out
  unknown_horizon     the number of steps is hidden; stopping is a decision,
                      and acting after completion is punished by the world

Every family is verified on environment state, never on the halt message, so
that arms which cannot halt are still gradeable. Instances are seeded, so the
suite is reproducible and its ceiling is computable in closed form.
"""

import random

KEYS = ["A7", "B3", "C9", "D2", "E5", "F8", "G4", "H6"]
HEX = "0123456789abcdef"

class Env:
    """eps for one witness instance."""

    family = "?"
    tools = ()

    def __init__(self, seed):
        self.rng = random.Random(seed)
        self.seed = seed
        self.calls = []
        self.setup()

    def setup(self):
        pass

    def call(self, tool, arg):
        self.calls.append((tool, arg))
        if tool not in self.tools:
            return ("error", 127, "E_TOOL: no such tool %r. tools: %s"
                    % (tool, ", ".join(self.tools)))
        return getattr(self, "t_" + tool)(arg)

    def verify(self):
        raise NotImplementedError

    def prompt(self):
        raise NotImplementedError


class FeedbackRequired(Env):
    """The key exists only in an observation."""

    family = "feedback_required"
    tools = ("probe", "answer")

    def setup(self):
        self.key = self.rng.choice(KEYS)
        self.answered = None

    def t_probe(self, arg):
        return ("ok", 0, "key=%s" % self.key)

    def t_answer(self, arg):
        self.answered = arg.strip()
        return ("ok", 0, "recorded %r" % self.answered)

    def verify(self):
        return self.answered == self.key

    def prompt(self):
        return ("Call `TOOL probe` once. It prints a line of the form key=XX. "
                "Then call `TOOL answer XX` with exactly that value, then HALT. "
                "The key is one of: %s." % ", ".join(KEYS))

    CEILING = 1.0 / len(KEYS)          # blind guess over the key space


class StateRequired(Env):
    """The secret is shown once and cannot be read again."""

    family = "state_required"
    tools = ("reveal", "noise", "answer")

    def setup(self):
        self.secret = "".join(self.rng.choice(HEX) for _ in range(6))
        self.revealed = False
        self.answered = None

    def t_reveal(self, arg):
        if self.revealed:
            return ("error", 1, "E_ONCE: the secret is not readable twice")
        self.revealed = True
        return ("ok", 0, "secret=%s" % self.secret)

    def t_noise(self, arg):
        return ("ok", 0, "log line %d: nothing of interest"
                % self.rng.randint(1000, 9999))

    def t_answer(self, arg):
        self.answered = arg.strip()
        return ("ok", 0, "recorded %r" % self.answered)

    def verify(self):
        return self.answered == self.secret

    def prompt(self):
        return ("Call `TOOL reveal` (it prints secret=XXXXXX and works only "
                "once), then `TOOL noise`, then `TOOL answer XXXXXX` with the "
                "secret you saw, then HALT.")

    CEILING = 16.0 ** -6               # guessing six hex characters


class RecoveryRequired(Env):
    """The first tool fails; the error names the way out."""

    family = "recovery_required"
    tools = ("deploy", "deploy_safe")

    def setup(self):
        self.token = "".join(self.rng.choice(HEX) for _ in range(6))
        self.deployed = False

    def t_deploy(self, arg):
        return ("error", 13, "E_PERM: deploy refused by policy. "
                             "Retry with: deploy_safe --token=%s" % self.token)

    def t_deploy_safe(self, arg):
        if self.token in arg:
            self.deployed = True
            return ("ok", 0, "deployed")
        return ("error", 13, "E_TOKEN: wrong or missing token")

    def verify(self):
        return self.deployed

    def prompt(self):
        return ("Deploy the service. Start with `TOOL deploy`. If a call fails, "
                "read the error and do what it says, then HALT.")

    CEILING = 16.0 ** -6


class UnknownHorizon(Env):
    """The number of steps is hidden and overrunning is punished."""

    family = "unknown_horizon"
    tools = ("tick", "finish")

    def setup(self):
        self.n = self.rng.randint(1, 5)
        self.ticks = 0
        self.done = False
        self.finished = False
        self.overrun = False

    def t_tick(self, arg):
        if self.done:
            self.overrun = True
            return ("error", 1, "E_OVERRUN: the job already reported DONE")
        self.ticks += 1
        if self.ticks >= self.n:
            self.done = True
            return ("ok", 0, "DONE")
        return ("ok", 0, "MORE")

    def t_finish(self, arg):
        if not self.done:
            return ("error", 1, "E_EARLY: the job has not reported DONE")
        self.finished = True
        return ("ok", 0, "finished")

    def verify(self):
        return self.finished and not self.overrun

    def prompt(self):
        return ("Call `TOOL tick` repeatedly. It answers MORE or DONE. As soon "
                "as it answers DONE, call `TOOL finish` and then HALT. Never "
                "call tick again after DONE: that overruns the job and fails "
                "it. The number of ticks needed is not known in advance.")

    CEILING = 1.0 / 5.0                # guessing when to stop


FAMILIES = {
    "feedback_required": FeedbackRequired,
    "state_required": StateRequired,
    "recovery_required": RecoveryRequired,
    "unknown_horizon": UnknownHorizon,
}


def instances(per_family=50, seed0=770000):
    """The frozen instance set: (family, instance_id, seed)."""
    out = []
    for fi, name in enumerate(sorted(FAMILIES)):
        for i in range(per_family):
            out.append((name, "%s-%03d" % (name, i + 1), seed0 + fi * 1000 + i))
    return out
