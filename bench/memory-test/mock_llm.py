#!/usr/bin/env python3
"""OpenAI-compatible mock for seed.sh memory e2e. stdlib only. No host keys."""
from __future__ import annotations

import json
import os
import re
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

PACKS = Path(os.environ.get("MOCK_PACKS", "/work/packs"))
PORT = int(os.environ.get("MOCK_PORT", "8765"))
CALL_N = 0


def _text(content: str) -> dict:
    return {
        "id": "mock-1",
        "object": "chat.completion",
        "choices": [
            {
                "index": 0,
                "message": {"role": "assistant", "content": content},
                "finish_reason": "stop",
            }
        ],
        "usage": {"prompt_tokens": 8, "completion_tokens": 8, "total_tokens": 16},
    }


def _shell(command: str) -> dict:
    global CALL_N
    CALL_N += 1
    cid = "call_%d" % CALL_N
    return {
        "id": "mock-1",
        "object": "chat.completion",
        "choices": [
            {
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": "",
                    "tool_calls": [
                        {
                            "id": cid,
                            "type": "function",
                            "function": {
                                "name": "shell",
                                "arguments": json.dumps({"command": command}),
                            },
                        }
                    ],
                },
                "finish_reason": "tool_calls",
            }
        ],
        "usage": {"prompt_tokens": 8, "completion_tokens": 8, "total_tokens": 16},
    }


def _last_user(messages):
    for m in reversed(messages):
        if m.get("role") == "user":
            return m.get("content") or ""
    return ""


def _system(messages):
    for m in messages:
        if m.get("role") == "system":
            return m.get("content") or ""
    return ""


def _tool_count(messages):
    return sum(1 for m in messages if m.get("role") == "tool")


def _index_path(system: str) -> str:
    m = re.search(r"Machine index:\s+(\S+)", system)
    return m.group(1) if m else os.path.join(
        os.environ.get("SEED_HOME", "/tmp/seed-e2e-home"), "agent-store", "index.json"
    )


def _store(system: str) -> str:
    idx = _index_path(system)
    return str(Path(idx).parent)


def decide(messages):
    user = _last_user(messages)
    sysmsg = _system(messages)
    tools = _tool_count(messages)
    store = _store(sysmsg)
    idx = _index_path(sysmsg)

    if "initialize" in user.lower() and "machine index" in user.lower():
        if tools == 0:
            cmd = """
idx=__IDX__
store=__STORE__
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# identity and the PATH sweep are the runtime's job and already landed before
# this turn. The mock writes ready, and deliberately writes nothing else, so
# the e2e assertions about identity are assertions about seed.sh.
while ! mkdir "$store/.state.lock" 2>/dev/null; do sleep 1; done
printf '%s\n' "$$" > "$store/.state.lock/owner"
jq --arg now "$now" '.ready=true | .updated=$now' \
  "$idx" > "$idx.tmp.$$" && mv "$idx.tmp.$$" "$idx"
rm -f "$store/.state.lock/owner"
rmdir "$store/.state.lock"
jq -e '.ready==true' "$idx"
""".replace("__IDX__", idx).replace("__STORE__", store)
            return _shell(cmd)
        return _text("ready")

    if "--maintain" in user or user.strip() in ("/maintain", "maintain"):
        print("MODEL_MAINTAIN_CALLED", flush=True)
        if tools == 0:
            cmd = r"""
set -eu
store=__STORE__
# The runtime, not prompt code, installs catalog-declared optional policy.
[ -f "$store/packs/memory.json" ]
install=${store%/agent-store}
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
while ! mkdir "$store/.state.lock" 2>/dev/null; do sleep 1; done
printf '%s\n' "$$" > "$store/.state.lock/owner"
for exp in "$store"/experiences/*/exp.json; do
  [ -f "$exp" ] || continue
  st=$(jq -r .status "$exp")
  [ "$st" = candidate ] || continue
  id=$(jq -r .id "$exp")
  ok=1
  ev_rel=$(jq -r '.evidence[0]' "$exp")
  ev=$install/$ev_rel
  while IFS= read -r vcmd; do
    [ -n "$vcmd" ] || continue
    if /bin/sh -c "$vcmd"; then
      jq -nc --arg utc "$now" --arg cmd "$vcmd" --arg id "$id" \
        '{utc:$utc,cmd:$cmd,exit:0,note:"maintenance verification",exp_id:$id}' >> "$ev"
    else
      ok=0
    fi
  done <<EOF
$(jq -r '.verify[]' "$exp")
EOF
  if [ "$ok" -eq 1 ]; then
    jq --arg now "$now" '.status="active" | .last_verified=$now | .successes = (if .successes < 1 then 1 else .successes end)' \
      "$exp" > "$exp.tmp.$$" && mv "$exp.tmp.$$" "$exp"
    row=$(jq -c '{id,title,status,version,scope,applies_if,path:.id}' "$exp")
    jq --argjson row "$row" --arg id "$id" \
      '.experiences = ([.experiences[] | select(.id != $id)] + [$row])' \
      "$store/experiences/index.json" > "$store/experiences/index.json.tmp.$$" \
      && mv "$store/experiences/index.json.tmp.$$" "$store/experiences/index.json"
  fi
done
rm -f "$store/.state.lock/owner"
rmdir "$store/.state.lock"
# The skill-catalog bridge is deliberately NOT done here. A mock that performs
# the step it is meant to be testing can only ever pass: the real model dropped
# exactly this step in report-real-smoke-20260824T160553Z while every offline
# suite stayed green. seed.sh owns the merge now, so the e2e assertion on
# agent.skills after maintain is an assertion about the runtime.
jq -r '.experiences[] | "\(.id) \(.status)"' "$store/experiences/index.json"
""".replace("__STORE__", store)
            return _shell(cmd)
        return _text("maintain complete")

    # Non-trivial coding task: two approaches, independent verify, distill candidate.
    if tools == 0:
        cmd = r"""
set -eu
store=__STORE__
ws=$(pwd)
# Optional policy is fetched and validated by seed.sh before this model turn.
[ -f "$store/packs/memory.json" ]
mkdir -p "$ws/project/hello-ok" "$store/experiences" "$store/runs" "$store/experiences/hello-ok"
if sh "$ws/project/hello-ok/hello.sh" >/tmp/hello1.out 2>/tmp/hello1.err; then
  echo unexpected_success
else
  echo approach1_failed
fi
printf '#!/bin/sh\nprintf hello-ok\n' > "$ws/project/hello-ok/hello.sh"
chmod +x "$ws/project/hello-ok/hello.sh"
out=$(sh "$ws/project/hello-ok/hello.sh")
[ "$out" = hello-ok ]
now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
slug=$(date -u +%Y%m%dT%H%M%SZ)-hello-ok
ev_rel=agent-store/runs/$slug.jsonl
ev=$store/runs/$slug.jsonl
verify='sh project/hello-ok/hello.sh | grep -qx hello-ok'
/bin/sh -c "$verify"
while ! mkdir "$store/.state.lock" 2>/dev/null; do sleep 1; done
printf '%s\n' "$$" > "$store/.state.lock/owner"
jq -nc --arg utc "$now" --arg cmd "$verify" \
  '{utc:$utc,cmd:$cmd,exit:0,note:"independent verify",exp_id:"hello-ok"}' >> "$ev"
jq -n --arg ev "$ev_rel" --arg verify "$verify" '{
  id:"hello-ok", kind:"procedure", title:"Print hello-ok via hello.sh",
  status:"candidate", version:1,
  scope:{os:[], tools:[], task_kinds:["toolchain"]},
  applies_if:["hello","verify","shell script"],
  preconditions:["writable project dir"],
  verify:[$verify],
  evidence:[$ev], successes:0, failures:0,
  created_at:"2026-08-25T00:00:00Z", last_verified:"", supersedes:"", quarantine_reason:""
}' > "$store/experiences/hello-ok/exp.json.tmp.$$" \
  && mv "$store/experiences/hello-ok/exp.json.tmp.$$" "$store/experiences/hello-ok/exp.json"
cat > "$store/experiences/hello-ok/SKILL.md" << 'SKILL'
---
name: hello-ok
description: Print hello-ok via hello.sh
---

# Print hello-ok via hello.sh

When to use: need a tiny hello.sh that prints hello-ok.

## Steps
1. Write project/hello-ok/hello.sh
2. Run the verify command.

## Verify
sh project/hello-ok/hello.sh | grep -qx hello-ok
SKILL
if [ ! -f "$store/experiences/index.json" ]; then
  printf '%s\n' '{"version":"1","experiences":[]}' > "$store/experiences/index.json.tmp.$$" \
    && mv "$store/experiences/index.json.tmp.$$" "$store/experiences/index.json"
fi
row=$(jq -c '{id,title,status,version,scope,applies_if,path:.id}' \
  "$store/experiences/hello-ok/exp.json")
jq --argjson row "$row" \
  '.experiences = ([.experiences[] | select(.id != "hello-ok")] + [$row])' \
  "$store/experiences/index.json" > "$store/experiences/index.json.tmp.$$" \
  && mv "$store/experiences/index.json.tmp.$$" "$store/experiences/index.json"
rm -f "$store/.state.lock/owner"
rmdir "$store/.state.lock"
leftover=$(find "$store" \( -name '*.tmp' -o -name '*.tmp.*' \) || true)
[ -z "$leftover" ]
jq -r '.status' "$store/experiences/hello-ok/exp.json"
""".replace("__STORE__", store)
        return _shell(cmd)
    return _text("task complete")


def to_sse(obj: dict) -> bytes:
    choice = obj["choices"][0]
    msg = choice["message"]
    chunks = []
    if msg.get("tool_calls"):
        tc = msg["tool_calls"][0]
        chunks.append(
            {
                "id": obj["id"],
                "object": "chat.completion.chunk",
                "choices": [
                    {
                        "index": 0,
                        "delta": {
                            "role": "assistant",
                            "tool_calls": [
                                {
                                    "index": 0,
                                    "id": tc["id"],
                                    "type": "function",
                                    "function": {
                                        "name": tc["function"]["name"],
                                        "arguments": "",
                                    },
                                }
                            ],
                        },
                        "finish_reason": None,
                    }
                ],
            }
        )
        chunks.append(
            {
                "id": obj["id"],
                "object": "chat.completion.chunk",
                "choices": [
                    {
                        "index": 0,
                        "delta": {
                            "tool_calls": [
                                {
                                    "index": 0,
                                    "function": {
                                        "arguments": tc["function"]["arguments"]
                                    },
                                }
                            ]
                        },
                        "finish_reason": None,
                    }
                ],
            }
        )
        chunks.append(
            {
                "id": obj["id"],
                "object": "chat.completion.chunk",
                "choices": [
                    {
                        "index": 0,
                        "delta": {},
                        "finish_reason": "tool_calls",
                    }
                ],
                "usage": obj.get("usage", {}),
            }
        )
    else:
        chunks.append(
            {
                "id": obj["id"],
                "object": "chat.completion.chunk",
                "choices": [
                    {
                        "index": 0,
                        "delta": {"role": "assistant", "content": msg.get("content") or ""},
                        "finish_reason": "stop",
                    }
                ],
                "usage": obj.get("usage", {}),
            }
        )
    out = []
    for c in chunks:
        out.append("data: %s\n\n" % json.dumps(c, separators=(",", ":")))
    out.append("data: [DONE]\n\n")
    return "".join(out).encode("utf-8")


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys_stderr = __import__("sys").stderr
        sys_stderr.write("mock %s\n" % (fmt % args))

    def _send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = urlparse(self.path).path
        mapping = {
            "/packs/agent/index.json": PACKS / "agent" / "index.json",
            "/packs/agent/init.json": PACKS / "agent" / "init.json",
            "/packs/agent/memory.json": PACKS / "agent" / "memory.json",
        }
        if path in ("/v1/models", "/models"):
            self._send(
                200,
                json.dumps(
                    {
                        "object": "list",
                        "data": [{"id": "mock", "object": "model"}],
                    }
                ),
            )
            return
        f = mapping.get(path)
        if f and f.is_file():
            self._send(200, f.read_bytes(), "application/json")
            return
        self._send(404, json.dumps({"error": "not found", "path": path}))

    def do_POST(self):
        path = urlparse(self.path).path
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b"{}"
        try:
            req = json.loads(raw.decode("utf-8"))
        except Exception:
            self._send(400, json.dumps({"error": "bad json"}))
            return
        if path not in (
            "/v1/chat/completions",
            "/chat/completions",
            "/v1/chat/completions/",
        ):
            self._send(404, json.dumps({"error": "no such route", "path": path}))
            return
        try:
            obj = decide(req.get("messages") or [])
        except Exception as exc:
            obj = _text("mock error: %s" % exc)
        if req.get("stream"):
            data = to_sse(obj)
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        self._send(200, json.dumps(obj))


def main():
    httpd = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print("mock listening 127.0.0.1:%s packs=%s" % (PORT, PACKS), flush=True)
    httpd.serve_forever()


if __name__ == "__main__":
    main()
