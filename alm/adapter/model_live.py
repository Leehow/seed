#!/usr/bin/env python3
"""model_live.py -- minimal OpenAI-compatible chat client (mu, live).

No retries on purpose: a failed call is reported to the kernel as
`transport_error` so that the kernel's own retry rule (ALM s4.5) is the thing
being exercised, not a hidden loop in the adapter.
"""

import json
import os
import time
import urllib.error
import urllib.request


def load_dotenv(path):
    out = {}
    if not os.path.exists(path):
        return out
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.partition("=")[0], line.partition("=")[2].strip()
            if len(v) > 1 and v[0] == '"' and v[-1] == '"':
                v = v[1:-1].replace('\\"', '"')     # shell-quoted JSON blobs
            out[k.strip()] = v
    return out


REGISTRY = os.path.join(os.path.dirname(os.path.abspath(__file__)), "models.json")


def registry():
    """Missing registry is not fatal: fall back to the dotenv/env settings.

    The registry names endpoints for the model matrix; a container that only
    ever talks to one endpoint does not need it, and failing to start because a
    lookup table is absent would be the wrong trade."""
    try:
        with open(REGISTRY) as fh:
            return json.load(fh)
    except OSError:
        return {}


class Client:
    """One OpenAI-compatible endpoint.

    `name` selects an entry from models.json. Endpoints differ in what they
    accept -- the local proxy rejects `temperature` and `top_p` outright -- so
    a null temperature in the registry means "do not send the field", not
    "send zero". Decoding parameters are part of the frozen protocol, so what
    was actually sent is recorded with the results rather than assumed.
    """

    def __init__(self, url=None, key=None, model=None, dotenv=None,
                 temperature=0.0, max_tokens=200, timeout=180, extra=None,
                 name=None):
        cfg = load_dotenv(dotenv) if dotenv else {}
        spec = registry().get(name, {}) if name else {}
        self.name = name or "env"
        self.vendor = spec.get("vendor", "unknown")
        raw_extra = extra if extra is not None else (
            os.environ.get("LLM_EXTRA") or cfg.get("LLM_EXTRA") or "")
        try:
            self.extra = json.loads(raw_extra) if raw_extra else {}
        except ValueError:
            self.extra = {}
        if spec:
            self.extra = spec.get("extra", {})
        # a container cannot reach the host's 127.0.0.1; the runner sets
        # ALM_MODEL_URL to the host.docker.internal form and it wins over the
        # registry entry
        self.url = (os.environ.get("ALM_MODEL_URL") or url or spec.get("url") or
                    cfg.get(spec.get("url_env", "")) or
                    os.environ.get(spec.get("url_env", "")) or
                    os.environ.get("LLM_API_URL") or cfg.get("LLM_API_URL"))
        self.key = (key or spec.get("key") or
                    cfg.get(spec.get("key_env", "")) or
                    os.environ.get(spec.get("key_env", "")) or
                    (None if spec else
                     (os.environ.get("LLM_API_KEY") or cfg.get("LLM_API_KEY"))))
        self.model = model or spec.get("model") or os.environ.get("LLM_MODEL") \
            or cfg.get("LLM_MODEL")
        self.temperature = spec.get("temperature", temperature) if spec else temperature
        self.max_tokens = max_tokens
        self.timeout = timeout
        self.prompt_tokens = self.completion_tokens = self.calls = 0
        self.reasoning_tokens = 0
        if not (self.url and self.model):
            raise RuntimeError("live model needs a url and a model name")
        # A guard, not a policy: the official DeepSeek endpoint bills per token
        # and an earlier arm ran up a real bill there, partly on a loop bug.
        # Everything now goes through prepaid endpoints, so reaching that host
        # is almost certainly a fallback firing by accident rather than intent.
        if "api.deepseek.com" in self.url and not os.environ.get("ALM_ALLOW_PAID_DEEPSEEK"):
            raise RuntimeError(
                "refusing to call api.deepseek.com (retired on cost). Use "
                "ds-flash-plan / ds-pro-plan, or set ALM_ALLOW_PAID_DEEPSEEK=1 "
                "if you really mean it.")

    def describe(self):
        return {"name": self.name, "vendor": self.vendor, "model": self.model,
                "endpoint": self.url.split("//")[-1].split("/")[0],
                "temperature": self.temperature, "max_tokens": self.max_tokens,
                "extra": self.extra}

    def complete(self, system, user):
        body = {
            "model": self.model,
            "messages": [{"role": "system", "content": system},
                         {"role": "user", "content": user}],
            "max_tokens": self.max_tokens,
            "stream": False,
        }
        if self.temperature is not None:
            body["temperature"] = self.temperature
        body.update(self.extra)
        headers = {"Content-Type": "application/json"}
        if self.key:
            headers["Authorization"] = "Bearer " + self.key
        req = urllib.request.Request(self.url, data=json.dumps(body).encode(),
                                     headers=headers)
        t0 = time.time()
        with urllib.request.urlopen(req, timeout=self.timeout) as resp:
            payload = json.loads(resp.read().decode())
        seconds = time.time() - t0
        self.calls += 1
        usage = payload.get("usage") or {}
        details = usage.get("completion_tokens_details") or {}
        self.prompt_tokens += usage.get("prompt_tokens", 0)
        self.completion_tokens += usage.get("completion_tokens", 0)
        self.reasoning_tokens += details.get("reasoning_tokens", 0) or 0
        msg = payload["choices"][0]["message"]
        # some providers put the answer in `content` and the chain of thought in
        # `reasoning_content`; only the former is the action
        return {"text": msg.get("content") or "",
                "finish_reason": payload["choices"][0].get("finish_reason"),
                "prompt_tokens": usage.get("prompt_tokens", 0),
                "completion_tokens": usage.get("completion_tokens", 0),
                "reasoning_tokens": details.get("reasoning_tokens", 0) or 0,
                "seconds": seconds}
