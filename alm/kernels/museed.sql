-- museed.sql -- ALM v0.1 kernel as relational state evolution (mu-Seed-SQL).
--
-- The loop is not in the pump. kernels/sqlpump.py only moves bytes: it INSERTs
-- each stdin line into `inbox`, then prints whatever rows appeared in `outbox`
-- and `trace`. Every decision -- which rule fires, what the next phase is,
-- whether the budget is spent, what the model is shown next -- is a WHERE
-- clause in this file.
--
-- Requires SQLite >= 3.44 (ordered group_concat). Tested on 3.50.2.
--
-- Shape:
--   cfg      configuration handed in at boot (ABI s5)
--   state    the single row (H is `hist`, B/Q/R are columns here)
--   hist     H, append only
--   inbox    one row per event; the AFTER INSERT trigger IS kappa
--   kv/ev    the parsed current event (ABI s1 needs no JSON library)
--   pre      pre-transition snapshot, so guards cannot read their own writes
--   outbox   effects for the adapter
--   trace    canonical trace records (ALM s5)

PRAGMA journal_mode = MEMORY;
PRAGMA synchronous = OFF;

CREATE TABLE cfg   (k TEXT PRIMARY KEY, v TEXT);
CREATE TABLE hist  (ord INTEGER PRIMARY KEY, ref TEXT NOT NULL);
CREATE TABLE inbox (id INTEGER PRIMARY KEY, raw TEXT NOT NULL);
CREATE TABLE outbox(id INTEGER PRIMARY KEY, line TEXT NOT NULL);
CREATE TABLE trace (id INTEGER PRIMARY KEY, line TEXT NOT NULL);
CREATE TABLE control(id INTEGER PRIMARY KEY, cmd TEXT NOT NULL);
CREATE TABLE keys  (k TEXT PRIMARY KEY);
INSERT INTO keys(k) VALUES ('t'),('eid'),('status'),('action'),('tool'),
                           ('halt'),('arg_ref'),('obs_ref');
CREATE TABLE kv (k TEXT PRIMARY KEY, v TEXT);

CREATE TABLE state (
    id           INTEGER PRIMARY KEY CHECK (id = 1),
    run          TEXT,
    phase        TEXT,
    step         INTEGER,
    attempt      INTEGER,
    eidn         INTEGER,
    pending      TEXT,
    steps_left   INTEGER,
    repairs_left INTEGER,
    retries_left INTEGER,
    history_max  INTEGER,
    feedback     INTEGER,
    allow_halt   INTEGER,
    steps_used   INTEGER,
    outcome      TEXT,
    reason       TEXT,
    status       TEXT
);
CREATE TABLE pre (
    id           INTEGER PRIMARY KEY CHECK (id = 1),
    run          TEXT, phase TEXT, step INTEGER, attempt INTEGER,
    eidn INTEGER, pending TEXT, steps_left INTEGER, repairs_left INTEGER,
    retries_left INTEGER, history_max INTEGER, feedback INTEGER,
    allow_halt INTEGER, steps_used INTEGER, outcome TEXT, reason TEXT,
    status TEXT
);

-- the parsed event, one column per ABI key
CREATE VIEW ev AS SELECT
    COALESCE((SELECT v FROM kv WHERE k='t'), '?')      AS t,
    (SELECT v FROM kv WHERE k='eid')                   AS eid,
    COALESCE((SELECT v FROM kv WHERE k='status'), '-') AS status,
    (SELECT v FROM kv WHERE k='action')                AS action,
    (SELECT v FROM kv WHERE k='tool')                  AS tool,
    COALESCE((SELECT v FROM kv WHERE k='halt'), 'ok')  AS halt,
    COALESCE((SELECT v FROM kv WHERE k='arg_ref'), 'r0') AS arg_ref,
    COALESCE((SELECT v FROM kv WHERE k='obs_ref'), 'o0') AS obs_ref;

-- H as the model will see it next (ALM s4.1 select()).
--
-- Ordered group_concat would say this in one line, but it landed in SQLite
-- 3.44 and Terminal-Bench task images ship 3.40. Unordered group_concat is not
-- an option: the ref list is a sequence, and getting it out of order is a
-- silent wrong answer rather than an error. So the window is walked with a
-- recursive CTE, which has been available since 3.8.3.
CREATE VIEW refs_now AS
WITH RECURSIVE win(ord, ref) AS (
    SELECT ord, ref FROM hist
     WHERE (SELECT history_max FROM state) < 0
        OR ord > (SELECT COALESCE(MAX(ord),0) FROM hist)
                 - (SELECT history_max FROM state)
),
walk(ord, acc) AS (
    SELECT (SELECT MIN(ord) FROM win),
           (SELECT ref FROM win WHERE ord = (SELECT MIN(ord) FROM win))
    UNION ALL
    SELECT w.ord, walk.acc || ',' || w.ref
      FROM walk JOIN win w ON w.ord = (SELECT MIN(ord) FROM win WHERE ord > walk.ord)
)
SELECT COALESCE((SELECT acc FROM walk ORDER BY ord DESC LIMIT 1), '-') AS refs;

-- classification, straight off ALM s4.6
CREATE VIEW cls AS SELECT CASE
    WHEN pre.phase = 'terminal' THEN 'after_terminal'
    WHEN ev.eid IS NOT pre.pending THEN 'stale'
    WHEN ev.t = 'model_response' AND pre.phase = 'await_model'
         AND (ev.status IN ('invalid','transport_error')
              OR (ev.status = 'ok' AND ev.action IN ('tool','halt'))) THEN 'match'
    WHEN ev.t = 'tool_response' AND pre.phase = 'await_tool'
         AND ev.status IN ('ok','error','timeout') THEN 'match'
    ELSE 'stale' END AS c
  FROM ev, pre;

-- the transition table (ALM s4.2 - s4.5)
CREATE VIEW rule AS SELECT CASE
    WHEN (SELECT c FROM cls) <> 'match' THEN (SELECT c FROM cls)
    WHEN ev.t = 'model_response' AND ev.status = 'ok' AND ev.action = 'tool'  THEN 'tool'
    WHEN ev.t = 'model_response' AND ev.status = 'ok' AND pre.allow_halt = 1  THEN 'halt'
    WHEN ev.t = 'model_response' AND ev.status = 'ok'                          THEN 'halt_disabled'
    WHEN ev.status = 'invalid'         AND pre.repairs_left > 0 THEN 'repair'
    WHEN ev.status = 'invalid'                                  THEN 'abort_protocol'
    WHEN ev.status = 'transport_error' AND pre.retries_left > 0 THEN 'retry'
    WHEN ev.status = 'transport_error'                          THEN 'abort_transport'
    WHEN pre.steps_left - 1 <= 0 THEN 'abort_budget'
    ELSE 'observe' END AS r
  FROM ev, pre;

-- ---------------------------------------------------------------- boot
CREATE TRIGGER control_boot AFTER INSERT ON control WHEN NEW.cmd = 'boot'
BEGIN
    INSERT INTO state VALUES (
        1,
        COALESCE((SELECT v FROM cfg WHERE k='ALM_RUN'), 'r1'),
        'await_model', 1, 1, 1, 'e1',
        CAST(COALESCE((SELECT v FROM cfg WHERE k='ALM_STEPS'), '16') AS INTEGER),
        CAST(COALESCE((SELECT v FROM cfg WHERE k='ALM_REPAIRS'), '2') AS INTEGER),
        CAST(COALESCE((SELECT v FROM cfg WHERE k='ALM_RETRIES'), '3') AS INTEGER),
        CAST(COALESCE((SELECT v FROM cfg WHERE k='ALM_HISTORY_MAX'), '-1') AS INTEGER),
        CAST(COALESCE((SELECT v FROM cfg WHERE k='ALM_FEEDBACK'), '1') AS INTEGER),
        CAST(COALESCE((SELECT v FROM cfg WHERE k='ALM_ALLOW_HALT'), '1') AS INTEGER),
        0, NULL, NULL, '-');

    INSERT INTO outbox(line) SELECT printf(
        '{"v":1,"t":"model_request","run":"%s","step":%d,"eid":"%s","attempt":%d,"refs":"%s","steps_left":%d}',
        run, step, pending, attempt, (SELECT refs FROM refs_now), steps_left) FROM state;

    INSERT INTO trace(line) SELECT printf(
        '%d|init|start|-|-|%s|%d|%d|%d|%s|-',
        step, phase, steps_left, repairs_left, retries_left,
        (SELECT refs FROM refs_now)) FROM state;
END;

-- ------------------------------------------------------------- kappa
CREATE TRIGGER inbox_step AFTER INSERT ON inbox
BEGIN
    -- parse: one expression, applied once per ABI key (ABI s1)
    DELETE FROM kv;
    INSERT INTO kv(k, v)
    SELECT k, CASE WHEN instr(NEW.raw, '"'||k||'":') = 0 THEN NULL ELSE
        (SELECT trim(substr(tail, 1,
                    CASE WHEN c = 0 THEN b - 1
                         WHEN b = 0 THEN c - 1
                         ELSE min(b, c) - 1 END), '"')
           FROM (SELECT tail, instr(tail, ',') AS c, instr(tail, '}') AS b
                   FROM (SELECT substr(NEW.raw,
                                instr(NEW.raw, '"'||k||'":') + length(k) + 3) AS tail)))
        END
      FROM keys;

    DELETE FROM pre;
    INSERT INTO pre SELECT * FROM state;

    -- s4.2 model answered with a tool call
    INSERT INTO hist(ref) SELECT arg_ref FROM ev WHERE (SELECT r FROM rule) = 'tool';
    UPDATE state SET phase = 'await_tool', eidn = eidn + 1,
                     pending = 'e' || (eidn + 1)
     WHERE (SELECT r FROM rule) = 'tool';
    INSERT INTO outbox(line) SELECT printf(
        '{"v":1,"t":"tool_request","run":"%s","step":%d,"eid":"%s","tool":"%s","arg_ref":"%s"}',
        s.run, s.step, s.pending, COALESCE(ev.tool,'unknown'), ev.arg_ref)
        FROM state s, ev WHERE (SELECT r FROM rule) = 'tool';
    INSERT INTO trace(line) SELECT printf(
        '%d|%s|model_response|ok|tool|%s|%d|%d|%d|%s|-',
        p.step, p.phase, s.phase, s.steps_left, s.repairs_left, s.retries_left, ev.arg_ref)
        FROM state s, pre p, ev WHERE (SELECT r FROM rule) = 'tool';

    -- s4.3 model answered with halt
    INSERT INTO hist(ref) SELECT arg_ref FROM ev
     WHERE (SELECT r FROM rule) IN ('halt','halt_disabled');
    UPDATE state SET phase = 'terminal', pending = NULL, outcome = 'halted',
                     reason = 'model_halt', status = (SELECT halt FROM ev)
     WHERE (SELECT r FROM rule) = 'halt';
    INSERT INTO outbox(line) SELECT printf(
        '{"v":1,"t":"final","run":"%s","step":%d,"outcome":"halted","status":"%s","reason":"model_halt","steps_used":%d}',
        run, step, status, steps_used) FROM state WHERE (SELECT r FROM rule) = 'halt';
    INSERT INTO trace(line) SELECT printf(
        '%d|%s|model_response|ok|halt|%s|%d|%d|%d|-|-',
        p.step, p.phase, s.phase, s.steps_left, s.repairs_left, s.retries_left)
        FROM state s, pre p WHERE (SELECT r FROM rule) = 'halt';

    -- s8 ext: halt disabled (fixed-horizon), no repair is spent
    UPDATE state SET attempt = attempt + 1, eidn = eidn + 1,
                     pending = 'e' || (eidn + 1)
     WHERE (SELECT r FROM rule) = 'halt_disabled';
    INSERT INTO outbox(line) SELECT printf(
        '{"v":1,"t":"model_request","run":"%s","step":%d,"eid":"%s","attempt":%d,"refs":"%s","steps_left":%d}',
        run, step, pending, attempt, (SELECT refs FROM refs_now), steps_left)
        FROM state WHERE (SELECT r FROM rule) = 'halt_disabled';
    INSERT INTO trace(line) SELECT printf(
        '%d|%s|model_response|invalid|halt|%s|%d|%d|%d|%s|-',
        p.step, p.phase, s.phase, s.steps_left, s.repairs_left, s.retries_left,
        (SELECT refs FROM refs_now))
        FROM state s, pre p WHERE (SELECT r FROM rule) = 'halt_disabled';

    -- s4.5 protocol repair
    INSERT INTO hist(ref) SELECT arg_ref FROM ev WHERE (SELECT r FROM rule) = 'repair';
    UPDATE state SET repairs_left = repairs_left - 1, attempt = attempt + 1,
                     eidn = eidn + 1, pending = 'e' || (eidn + 1)
     WHERE (SELECT r FROM rule) = 'repair';
    INSERT INTO outbox(line) SELECT printf(
        '{"v":1,"t":"model_request","run":"%s","step":%d,"eid":"%s","attempt":%d,"refs":"%s","steps_left":%d}',
        run, step, pending, attempt, (SELECT refs FROM refs_now), steps_left)
        FROM state WHERE (SELECT r FROM rule) = 'repair';
    INSERT INTO trace(line) SELECT printf(
        '%d|%s|model_response|invalid|-|%s|%d|%d|%d|%s|-',
        p.step, p.phase, s.phase, s.steps_left, s.repairs_left, s.retries_left,
        (SELECT refs FROM refs_now))
        FROM state s, pre p WHERE (SELECT r FROM rule) = 'repair';

    -- s4.5 repairs exhausted
    UPDATE state SET phase = 'terminal', pending = NULL, outcome = 'aborted',
                     reason = 'protocol_exhausted', status = '-'
     WHERE (SELECT r FROM rule) = 'abort_protocol';
    INSERT INTO outbox(line) SELECT printf(
        '{"v":1,"t":"final","run":"%s","step":%d,"outcome":"aborted","status":"-","reason":"protocol_exhausted","steps_used":%d}',
        run, step, steps_used) FROM state WHERE (SELECT r FROM rule) = 'abort_protocol';
    INSERT INTO trace(line) SELECT printf(
        '%d|%s|model_response|invalid|-|%s|%d|%d|%d|-|-',
        p.step, p.phase, s.phase, s.steps_left, s.repairs_left, s.retries_left)
        FROM state s, pre p WHERE (SELECT r FROM rule) = 'abort_protocol';

    -- s4.5 transport retry (H untouched: nothing happened to learn from)
    UPDATE state SET retries_left = retries_left - 1, attempt = attempt + 1,
                     eidn = eidn + 1, pending = 'e' || (eidn + 1)
     WHERE (SELECT r FROM rule) = 'retry';
    INSERT INTO outbox(line) SELECT printf(
        '{"v":1,"t":"model_request","run":"%s","step":%d,"eid":"%s","attempt":%d,"refs":"%s","steps_left":%d}',
        run, step, pending, attempt, (SELECT refs FROM refs_now), steps_left)
        FROM state WHERE (SELECT r FROM rule) = 'retry';
    INSERT INTO trace(line) SELECT printf(
        '%d|%s|model_response|transport_error|-|%s|%d|%d|%d|%s|-',
        p.step, p.phase, s.phase, s.steps_left, s.repairs_left, s.retries_left,
        (SELECT refs FROM refs_now))
        FROM state s, pre p WHERE (SELECT r FROM rule) = 'retry';

    UPDATE state SET phase = 'terminal', pending = NULL, outcome = 'aborted',
                     reason = 'transport_exhausted', status = '-'
     WHERE (SELECT r FROM rule) = 'abort_transport';
    INSERT INTO outbox(line) SELECT printf(
        '{"v":1,"t":"final","run":"%s","step":%d,"outcome":"aborted","status":"-","reason":"transport_exhausted","steps_used":%d}',
        run, step, steps_used) FROM state WHERE (SELECT r FROM rule) = 'abort_transport';
    INSERT INTO trace(line) SELECT printf(
        '%d|%s|model_response|transport_error|-|%s|%d|%d|%d|-|-',
        p.step, p.phase, s.phase, s.steps_left, s.repairs_left, s.retries_left)
        FROM state s, pre p WHERE (SELECT r FROM rule) = 'abort_transport';

    -- s4.4 tool answered
    INSERT INTO hist(ref) SELECT obs_ref FROM ev
     WHERE (SELECT r FROM rule) IN ('observe','abort_budget')
       AND (SELECT feedback FROM pre) = 1;
    UPDATE state SET steps_left = steps_left - 1, steps_used = steps_used + 1,
                     step = step + 1, attempt = 1, phase = 'await_model',
                     eidn = eidn + 1, pending = 'e' || (eidn + 1)
     WHERE (SELECT r FROM rule) = 'observe';
    INSERT INTO outbox(line) SELECT printf(
        '{"v":1,"t":"model_request","run":"%s","step":%d,"eid":"%s","attempt":%d,"refs":"%s","steps_left":%d}',
        run, step, pending, attempt, (SELECT refs FROM refs_now), steps_left)
        FROM state WHERE (SELECT r FROM rule) = 'observe';
    INSERT INTO trace(line) SELECT printf(
        '%d|%s|tool_response|%s|-|%s|%d|%d|%d|%s|-',
        p.step, p.phase, ev.status, s.phase, s.steps_left, s.repairs_left,
        s.retries_left, (SELECT refs FROM refs_now))
        FROM state s, pre p, ev WHERE (SELECT r FROM rule) = 'observe';

    UPDATE state SET steps_left = steps_left - 1, steps_used = steps_used + 1,
                     phase = 'terminal', pending = NULL, outcome = 'aborted',
                     reason = 'budget_exhausted', status = '-'
     WHERE (SELECT r FROM rule) = 'abort_budget';
    INSERT INTO outbox(line) SELECT printf(
        '{"v":1,"t":"final","run":"%s","step":%d,"outcome":"aborted","status":"-","reason":"budget_exhausted","steps_used":%d}',
        run, step, steps_used) FROM state WHERE (SELECT r FROM rule) = 'abort_budget';
    INSERT INTO trace(line) SELECT printf(
        '%d|%s|tool_response|%s|-|%s|%d|%d|%d|-|-',
        p.step, p.phase, ev.status, s.phase, s.steps_left, s.repairs_left, s.retries_left)
        FROM state s, pre p, ev WHERE (SELECT r FROM rule) = 'abort_budget';

    -- s4.6 ignored events
    INSERT INTO trace(line) SELECT printf(
        '%d|%s|%s|%s|-|%s|%d|%d|%d|-|%s',
        p.step, p.phase, ev.t, ev.status, s.phase, s.steps_left, s.repairs_left,
        s.retries_left,
        CASE (SELECT r FROM rule) WHEN 'stale' THEN 'stale_event'
                                  ELSE 'after_terminal' END)
        FROM state s, pre p, ev
       WHERE (SELECT r FROM rule) IN ('stale','after_terminal');
END;
