#!/usr/bin/env python3
"""shell_env.py -- eps for real work: one persistent /bin/sh, plus `edit`.

This is the environment half of a genuine coding agent, kept deliberately at
the two primitives Seed exposes:

    shell <command>              runs in ONE session; cd and exports persist
    edit  <path>\\n<old>\\n---\\n<new>  unique-match replace, or the file is untouched

Nothing here knows about ALM. It is handed to Adapter exactly like a witness
environment is, which is the point: the same four kernels drive a toy witness
task and a real repository the same way.
"""

import os
import select
import signal
import subprocess
import time
import uuid


class ShellEnv:
    family = "shell"

    def __init__(self, task, workdir=None, timeout=120, seed=0):
        self.task_text = task
        self.workdir = workdir or os.getcwd()
        self.timeout = timeout
        self.seed = seed
        self.calls = []
        self.halted = False
        self.marker = "__ALM_%s__" % uuid.uuid4().hex[:12]
        self.proc = subprocess.Popen(
            ["/bin/sh"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT, cwd=self.workdir, start_new_session=True,
            env=dict(os.environ, PS1="", TERM="dumb"))
        self.buf = b""

    # -- tools ---------------------------------------------------------
    def call(self, tool, arg):
        self.calls.append((tool, arg[:200]))
        if tool == "shell":
            return self.sh(arg)
        if tool == "edit":
            return self.edit(arg)
        return ("error", 127, "E_TOOL: unknown tool %r; this loop has shell and edit"
                % tool)

    def sh(self, command):
        if self.proc.poll() is not None:
            return ("error", 1, "E_SHELL: the session died")
        payload = "%s\nprintf '\\n%s %%s\\n' \"$?\"\n" % (command, self.marker)
        self.proc.stdin.write(payload.encode())
        self.proc.stdin.flush()
        deadline = time.time() + self.timeout
        while self.marker.encode() not in self.buf:
            remaining = deadline - time.time()
            if remaining <= 0:
                try:
                    os.killpg(os.getpgid(self.proc.pid), signal.SIGINT)
                except OSError:
                    pass
                out = self.buf.decode(errors="replace")
                self.buf = b""
                return ("timeout", -1, out + "\n[timed out after %ds]" % self.timeout)
            r, _, _ = select.select([self.proc.stdout], [], [], remaining)
            if not r:
                continue
            chunk = os.read(self.proc.stdout.fileno(), 65536)
            if not chunk:
                break
            self.buf += chunk
        text, _, rest = self.buf.partition(self.marker.encode())
        code_line, _, self.buf = rest.partition(b"\n")
        try:
            code = int(code_line.strip() or b"0")
        except ValueError:
            code = 0
        body = text.decode(errors="replace").strip("\n")
        return ("ok" if code == 0 else "error", code, body)

    def edit(self, arg):
        """path, old and new separated by lines of exactly ---."""
        parts = arg.split("\n---\n")
        if len(parts) != 2 or "\n" not in parts[0]:
            return ("error", 2, "E_EDIT: expected <path>\\n<old_text>\\n---\\n<new_text>")
        head, new = parts
        path, _, old = head.partition("\n")
        path = os.path.join(self.workdir, path.strip()) if not os.path.isabs(path.strip()) \
            else path.strip()
        if not os.path.exists(path):
            return ("error", 2, "E_EDIT: no such file: %s" % path)
        with open(path, errors="replace") as fh:
            body = fh.read()
        hits = body.count(old)
        if hits != 1:
            return ("error", 3, "E_EDIT: old_text matched %d times; it must match "
                                "exactly once. The file is unchanged." % hits)
        with open(path, "w") as fh:
            fh.write(body.replace(old, new, 1))
        return ("ok", 0, "edited %s" % path)

    # -- adapter contract ----------------------------------------------
    def prompt(self):
        return self.task_text

    def verify(self):
        """Grading is the harness's job, not the environment's."""
        return False

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(timeout=5)
        except Exception:
            self.proc.kill()
