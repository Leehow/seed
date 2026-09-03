#!/usr/bin/env python3
"""prompts.py -- what mu is told, and how its answer is read back.

Two protocols ship, and the difference between them is the point.

`a` (terse) was the original: state the action, nothing else. It reads like the
minimal thing that could work, and on Terminal-Bench it fails in a specific
way -- with reasoning disabled and commentary forbidden, the model has no
channel in which to notice that its last command failed, so it re-issues it.
In one measured run: 25 actions, 9 distinct, one command repeated verbatim ten
times.

`b` (reasoned) borrows the three things mini-swe-agent does that `a` did not: a
mandatory thought before the action, a workflow that ends in an explicit
finish, and concrete command idioms. The action space is identical -- the same
two primitives and the same halt -- so the kernel and the ABI are untouched.
This is a change to mu, and it is shared byte-for-byte by every substrate.
"""

import re

# ---------------------------------------------------------------- protocol a

PROMPT_A = (
    "You are a coding agent driving one persistent /bin/sh session through a "
    "text protocol. There is no function-calling API here: you act by emitting "
    "an action, the harness runs it, and you see the result on your next turn.\n"
    "\n"
    "Reply with an action and nothing else. The first line names the action; "
    "everything after it is the argument, so multi-line commands and heredocs "
    "are fine:\n"
    "  TOOL shell <command on this line, or on the lines that follow>\n"
    "  TOOL edit\n<path>\n<old_text>\n---\n<new_text>\n"
    "  HALT <short report>\n"
    "\n"
    "`edit` replaces old_text with new_text only when old_text occurs exactly "
    "once; otherwise the file is left untouched and you are told so. cd and "
    "exports persist between shell calls. Commands must be non-interactive. No "
    "human will answer a question, so never end a turn by asking one. Verify "
    "your work before you HALT.\n"
    "No markdown fences, no commentary."
)

FENCE = re.compile(r"^```[a-zA-Z0-9_-]*\n|\n```$")


def parse_a(text):
    """TOOL/HALT on the first line; the argument may continue over later lines."""
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


def render_obs_a(tool, code, text, truncated):
    return "exit=%d %s" % (code, text)


# ---------------------------------------------------------------- protocol b

PROMPT_B = """You are a coding agent working in one persistent /bin/sh session. \
There is no function-calling API: you emit an action, the harness runs it, and \
you see the result on your next turn.

Every reply has exactly two parts, in this order.

1. THOUGHT: two or three sentences. What did the last output actually tell you? \
What will you do next, and why? If your last command failed or told you \
nothing, say plainly what you will do DIFFERENTLY. Never re-issue a command \
that just failed -- if a tool is missing, find another way; if a file is not \
what you assumed, look at it.

2. Exactly one action, alone in a fenced block:

```action
TOOL shell <command; it may span several lines, heredocs are fine>
```

```action
TOOL edit
<path>
<old_text>
---
<new_text>
```

```action
HALT <one line saying what you delivered>
```

Rules that matter:

* `cd` and exported variables persist between shell calls; every command runs \
in the same session.
* `edit` replaces old_text with new_text only when old_text occurs exactly \
once in the file. Otherwise nothing changes and you are told the match count.
* Commands must be non-interactive. Never run an editor, a pager or a REPL.
* No human will answer a question. Never end a turn by asking one.

How to work:

1. Look before you leap: list the directory, read the files the task names, \
check what tools exist (`command -v x`).
2. Make the smallest change that could work.
3. Run it, and read the output.
4. Verify the exact deliverable the task asked for -- the right path, the right \
filename, the right format. Print it and check it with your own eyes.
5. Before you HALT, prove to yourself that you are done: re-read the task, then list and print the exact deliverable it named (`ls -l <path>` and `cat` or `head` it). If the task named a file, that file must exist, at that path, in that format. If it named a service, it must answer. A HALT without that check is a failed task.
6. Then, and only then, HALT.

You have a limited number of steps and they are shown to you each turn. Do not spend them re-running something that already worked, and do not stop early with the work half done: the run is graded on what is on disk when it ends, not on what you say.

Useful idioms:

```action
TOOL shell cat > solve.py <<'EOF'
import json
print(json.dumps({"ok": True}))
EOF
```

```action
TOOL shell nl -ba config.py | sed -n '1,40p'
```

```action
TOOL shell command -v sqlite3 || python3 -c "import sqlite3; print(sqlite3.sqlite_version)"
```
"""

ACTION_BLOCK = re.compile(r"```(?:action)?\s*\n(.*?)```", re.S)


def parse_b(text):
    """The action is the last fenced block; anything before it is thinking."""
    raw = (text or "").strip()
    if not raw:
        return ("invalid", "empty_completion")
    blocks = ACTION_BLOCK.findall(raw)
    body = blocks[-1].strip() if blocks else None
    if body is None:
        # the model wrote the action without a fence; accept it if the last
        # non-empty line still names one, rather than burning a step on form
        lines = [l for l in raw.splitlines() if l.strip()]
        for i in range(len(lines) - 1, -1, -1):
            if lines[i].strip().upper().startswith(("TOOL", "HALT")):
                body = "\n".join(lines[i:]).strip()
                break
        if body is None:
            return ("invalid", "no_action_block")
    first, _, tail = body.partition("\n")
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
    if not name:
        return ("invalid", "missing_field")
    return ("tool", name, arg)


def render_obs_b(tool, code, text, truncated):
    """Tagged, and explicit about what a long or empty output means."""
    out = "<returncode>%d</returncode>\n" % code
    if truncated:
        out += ("<warning>The output was too long and has been cut. Use head, "
                "tail, sed -n or a more selective pattern, or redirect to a "
                "file and search in it.</warning>\n")
    if not text.strip():
        out += "<output>(the command produced no output)</output>"
    else:
        out += "<output>\n%s\n</output>" % text
    return out


# max_tokens is part of the protocol, not a free knob: repeats 0-2 of the
# Terminal-Bench arm ran protocol `a` at 1200, and repeats 3-4 must match them
# or they are not the same experiment. `b` needs more room because it thinks
# in the open before it acts.
# The note the model is shown after a rejected reply is part of the protocol
# too. Protocol `a`'s wording is the one that ran repeats 0-2 of the
# Terminal-Bench arm and must not drift, or the later repeats are a different
# experiment.
NOTE_A = ("your last reply was rejected (%s). Reply with exactly one line: "
          "TOOL <name> <arg>, or HALT <report>.")
NOTE_B = ("Your last reply was rejected (%s). Reply with a short THOUGHT and "
          "then exactly one action in a fenced block.")
NOTE_TRUNCATED = ("Your last reply hit the output token limit before you "
                  "produced an action, so nothing was run. Think more briefly "
                  "and emit the action.")

PROTOCOLS = {
    "a": {"system": PROMPT_A, "parse": parse_a, "render_obs": render_obs_a,
          "label": "terse", "max_tokens": 1200, "note": NOTE_A},
    "b": {"system": PROMPT_B, "parse": parse_b, "render_obs": render_obs_b,
          "label": "reasoned", "max_tokens": 1600, "note": NOTE_B},
    # same protocol as b, sized for a model that reasons before it answers:
    # max_tokens covers reasoning tokens too, and 1600 is not enough to think
    # and then speak, which shows up as an empty completion.
    "br": {"system": PROMPT_B, "parse": parse_b, "render_obs": render_obs_b,
           "label": "reasoned, wide output budget", "max_tokens": 32768,
           "repairs": 4, "note": NOTE_B},
}
