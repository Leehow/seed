#!/usr/bin/env python3
"""runtask.py -- drive a real task with any ALM kernel.

    python3 alm/adapter/runtask.py --kernel asm --workdir /tmp/x \
        --task "write hello.txt containing hello, then verify it"

Same kernel binaries as the conformance suite; the only thing that changed is
which eps is plugged in.
"""

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ALM = os.path.dirname(HERE)
sys.path.insert(0, HERE)

from adapter import Adapter, make_live_policy      # noqa: E402
from prompts import PROTOCOLS                      # noqa: E402
from shell_env import ShellEnv                     # noqa: E402
from model_live import Client                      # noqa: E402

SYSTEM = PROTOCOLS["a"]["system"]   # kept: run_local.py imports it


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kernel", default="py")
    ap.add_argument("--task", required=True)
    ap.add_argument("--workdir", default=os.getcwd())
    ap.add_argument("--steps", type=int, default=20)
    ap.add_argument("--tool-timeout", type=int, default=120)
    ap.add_argument("--obs-cap", type=int, default=8192)
    ap.add_argument("--trace", default="")
    ap.add_argument("--transcript", default="",
                    help="log what the model was shown and said (diagnosis)")
    ap.add_argument("--prompt", default="b", choices=sorted(PROTOCOLS),
                    help="which mu protocol: a=terse, b=reasoned")
    ap.add_argument("--dotenv", default=os.path.join(ALM, "..", ".env"))
    ap.add_argument("--model", default="grok-low")
    ap.add_argument("--verbose", action="store_true")
    a = ap.parse_args()

    with open(os.path.join(ALM, "kernels", "registry.json")) as fh:
        spec = json.load(fh)[a.kernel]
    argv = [x.replace("KERNELS", os.path.join(ALM, "kernels")) for x in spec["argv"]]

    os.makedirs(a.workdir, exist_ok=True)
    proto = PROTOCOLS[a.prompt]
    env = ShellEnv(a.task, workdir=a.workdir, timeout=a.tool_timeout)
    client = Client(dotenv=a.dotenv, max_tokens=proto["max_tokens"],
                    name=a.model)
    policy = make_live_policy(client, parse=proto["parse"])
    if a.verbose:
        inner = policy

        def policy(ad, eff):                       # noqa: F811
            act = inner(ad, eff)
            print("[step %s] %s" % (eff["step"], " ".join(str(x)[:120] for x in act)),
                  file=sys.stderr)
            return act

    kernel_env = {"ALM_STEPS": str(a.steps)}
    if proto.get("repairs"):
        # an output-budget truncation is reported to the kernel as a protocol
        # repair, which is the right channel -- the model is told it was cut off
        # -- but a model that reasons at length trips it occasionally, so the
        # arm that reasons gets a repair budget that can absorb that.
        kernel_env["ALM_REPAIRS"] = str(proto["repairs"])
    ad = Adapter(argv, env, policy, kernel_env=kernel_env,
                 trace_path=a.trace or None, obs_cap=a.obs_cap,
                 system_prompt=proto["system"], render_obs=proto["render_obs"],
                 repair_note=proto.get("note"),
                 transcript=a.transcript or None)
    r = ad.run()
    env.close()
    r.pop("success", None)                          # graded outside, not here
    print(json.dumps({"kernel": a.kernel, "substrate": spec["substrate"],
                      "prompt": a.prompt, **r}, indent=1))


if __name__ == "__main__":
    main()
