#!/usr/bin/env python3
"""sqlpump.py -- the I/O device for kernels/museed.sql.

It is deliberately stupid, and the paper's SQL claim depends on it staying
that way. The pump may only:

  1. create an in-memory database and run museed.sql,
  2. copy $ALM_* configuration into `cfg` and insert the `boot` control row,
  3. INSERT each stdin line, verbatim, into `inbox`,
  4. print rows that appeared in `outbox` / `trace` since the last insert,
  5. read `state.phase` once at EOF to choose its exit status.

It never parses an event, never decides a transition, never chooses what the
model sees next. Deleting steps 3-4 leaves a database that still contains the
whole agent loop; deleting museed.sql leaves a program that can do nothing.
"""

import os
import sqlite3
import sys

CFG_KEYS = ("ALM_RUN", "ALM_STEPS", "ALM_REPAIRS", "ALM_RETRIES",
            "ALM_HISTORY_MAX", "ALM_FEEDBACK", "ALM_ALLOW_HALT")


def main():
    schema_path = sys.argv[1] if len(sys.argv) > 1 else \
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "museed.sql")
    trace_path = os.environ.get("ALM_TRACE")
    trace = open(trace_path, "w") if trace_path else os.fdopen(3, "w")

    db = sqlite3.connect(":memory:")
    with open(schema_path) as fh:
        db.executescript(fh.read())
    db.executemany("INSERT INTO cfg(k,v) VALUES (?,?)",
                   [(k, os.environ[k]) for k in CFG_KEYS if k in os.environ])
    db.execute("INSERT INTO control(cmd) VALUES ('boot')")

    seen_out = seen_trace = 0

    def flush():
        nonlocal seen_out, seen_trace
        for (i, line) in db.execute("SELECT id,line FROM outbox WHERE id>? ORDER BY id",
                                    (seen_out,)):
            seen_out = i
            sys.stdout.write(line + "\n")
        sys.stdout.flush()
        for (i, line) in db.execute("SELECT id,line FROM trace WHERE id>? ORDER BY id",
                                    (seen_trace,)):
            seen_trace = i
            trace.write(line + "\n")
        trace.flush()

    flush()
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        db.execute("INSERT INTO inbox(raw) VALUES (?)", (line,))
        flush()

    phase = db.execute("SELECT phase FROM state").fetchone()[0]
    trace.close()
    return 0 if phase == "terminal" else 3


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        sys.exit(0)
    except sqlite3.Error as exc:
        sys.stderr.write("sqlpump: %s\n" % exc)
        sys.exit(2)
