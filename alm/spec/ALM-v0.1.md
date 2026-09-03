# ALM v0.1 — Agent Loop Machine

Normative specification. Frozen 2026-08-28. Any change to a MUST in this file
is a new version number, not an edit.

ALM is an operational semantics for **finite-horizon, single-agent,
observation-dependent tool-use loops**. It is not a semantics for multi-agent
systems, human-in-the-loop workflows, long-lived memory, or real-time control.
Those are out of scope for v0.1 and MUST NOT be read into the claims below.

An implementation of this specification is called a **kernel**. Four kernels
ship with this repository (`alm/kernels/`): a Python reference, a POSIX shell
kernel, a relational (SQL) kernel, and an ARM64 assembly kernel. A kernel is *conformant* if it passes the suite in `alm/conformance/`: 350
recorded cases whose expected effects and canonical traces come from a
table-driven derivation of s4 written separately from any kernel. The suite
fires all twelve transition rules below, and 17 seeded mutations of the
reference kernel are each caught by at least ten cases.

---

## 1. The three interfaces

An agent run is the interaction of three separable functions.

    a_t  ~  mu( serialize(s_t) )              model
    (w_{t+1}, o_t) = eps( w_t, a_t )          environment
    s_{t+1} = kappa( s_t, a_t, o_t )          kernel

* `mu` — the model. Stochastic. Maps a serialized state to an action or a halt.
* `eps` — the environment. Executes an action against world state `w_t`
  (filesystem, processes, network) and returns an observation.
* `kappa` — the **kernel**. Deterministic. Owns state update, budget, phase
  advance, error handling and termination.

ALM v0.1 specifies `kappa` **only**. `mu` and `eps` are supplied by an
*adapter* across the ABI in [`ABI-v0.1.md`](ABI-v0.1.md). This is the whole
point of the split: `mu` and `eps` are where cost, nondeterminism and task
capability live; `kappa` is the part we are asking how small it can be.

## 2. Agent state

    s_t = (H_t, B_t, Q_t, R_t)

### 2.1 H — history

`H` is an ordered list of **entries**. An entry is a pair

    (ref, kind)      kind in { model_arg, observation, repair_note }

`ref` is an opaque identifier minted by the adapter. **A kernel MUST NOT
inspect, decode, concatenate, or otherwise depend on the bytes a ref names.**
This is the *payload-blind rule* and it is normative.

Rationale: everything a kernel decides — which step is next, whether the budget
is spent, whether a run is over — is a function of event kinds, statuses and
counters. Prompt text, tool output and diff hunks are the adapter's business.
A kernel that stays payload-blind can be written in a substrate with no string
library at all, and a cross-substrate conformance claim about it is meaningful
rather than an artifact of four copies of the same JSON parser.

### 2.2 B — budget

    B = (steps_left, repairs_left, retries_left, history_max, obs_cap)

* `steps_left` — remaining model/tool step pairs. Decremented once per
  completed step (§4.4). MUST be an integer >= 0.
* `repairs_left` — remaining protocol repairs (model produced an ill-formed or
  unknown action).
* `retries_left` — remaining transport retries (the model call itself failed).
* `history_max` — maximum number of entries carried into a model request.
  `-1` means unbounded. When the limit binds, the kernel drops **oldest first**.
* `obs_cap` — observation byte cap, enforced by the adapter and reported back;
  the kernel records the truncation flag and never sees the bytes.

Wall-clock deadlines are deliberately **not** part of `B` in v0.1. They are
nondeterministic and would make conformance untestable. A wall-clock budget is
a conforming extension (§8).

### 2.3 Q — phase

    Q in { init, await_model, await_tool, terminal }

### 2.4 R — recovery

    R = (run_id, step, pending_eid, attempt, outcome, reason)

`pending_eid` is the identifier of the single outstanding effect. A kernel has
**at most one** effect in flight at any time (v0.1 is strictly sequential).
`outcome`/`reason` are set exactly once, on entry to `terminal`.

## 3. Effects and events

The kernel emits **effects** and consumes **events**. One effect is
outstanding at a time; the event that answers it carries the same `eid`.

| effect          | answered by     |
|-----------------|-----------------|
| `model_request` | `model_response`|
| `tool_request`  | `tool_response` |
| `final`         | — (terminal)    |

Event statuses:

* `model_response.status` in `{ ok, invalid, transport_error }`
* `tool_response.status` in `{ ok, error, timeout }`

`ok` model responses carry `action` in `{ tool, halt }`.

## 4. Transitions (kappa)

Let `E` be the incoming event. All rules are total: any (phase, event) pair not
listed below is handled by §4.6.

### 4.1 Start

    init  --start-->  await_model
      emit model_request(step=1, attempt=1, refs=select(H, history_max))

`select` returns the last `history_max` entries in order, or all of them when
`history_max = -1`.

### 4.2 Model answered with a tool call

    await_model + model_response(ok, action=tool)
      H := H ++ [(arg_ref, model_arg)]
      Q := await_tool
      emit tool_request(tool, arg_ref)

The kernel does **not** validate the tool name against a list. Unknown tools
are an environment error (`tool_response(status=error)`), not a kernel concern.
This keeps the kernel's tool vocabulary open and is what lets one kernel serve
`shell`/`edit`/`halt` and a witness-task tool set unchanged.

### 4.3 Model answered with halt

    await_model + model_response(ok, action=halt, halt=H)
      H := H ++ [(arg_ref, model_arg)]
      Q := terminal, outcome := halted, reason := model_halt, status := H
      emit final

`halt` in `{ ok, fail }` is the model's own verdict and is recorded, not
trusted. Grading is the harness's job.

### 4.4 Tool answered

    await_tool + tool_response(status=S)
      H := H ++ [(obs_ref, observation)]        -- omitted when feedback=off (§8)
      steps_left := steps_left - 1
      if steps_left = 0:
        Q := terminal, outcome := aborted, reason := budget_exhausted
        emit final
      else:
        Q := await_model
        emit model_request(step := step+1, attempt=1, refs=select(H, history_max))

The observation is appended regardless of `S`. A failed tool call is
information, not an error to be swallowed: this is the transition the
recovery-required witness family (§`alm/witness/`) probes.

### 4.5 Model failed

    await_model + model_response(invalid)
      if repairs_left > 0:
        repairs_left -= 1
        H := H ++ [(reason_ref, repair_note)]
        attempt := attempt + 1
        re-emit model_request(same step, attempt, refs)
      else:
        Q := terminal, outcome := aborted, reason := protocol_exhausted
        emit final

    await_model + model_response(transport_error)
      if retries_left > 0:
        retries_left -= 1
        attempt := attempt + 1
        re-emit model_request(same step, attempt, refs)   -- H unchanged
      else:
        Q := terminal, outcome := aborted, reason := transport_exhausted
        emit final

A repair adds a note to history (the model must see what it did wrong); a
transport retry does not (nothing happened that the model could learn from).
Neither consumes a step: `steps_left` counts *work*, not attempts.

### 4.6 Events that do not match

An event is **ignored** -- state unchanged, no effect emitted, one trace
record with `flag = stale_event` -- when any of these hold:

* its `eid` differs from `pending_eid`;
* its `t` is not the response type the current phase awaits;
* its `t` or `status`, or (when `status = ok`) its `action`, is not one of the
  tokens in ABI v0.1 s4.

In `terminal` every event is ignored with `flag = after_terminal`.

The third rule matters more than it looks. A kernel MUST NOT guess what an
unrecognized status meant -- in particular it MUST NOT treat it as a protocol
repair, because a repair asserts that the model answered, and an unparsable
record is not evidence that it did. Garbage on the wire is an adapter fault;
the kernel keeps its effect outstanding and lets the adapter answer properly
or hit EOF (exit 3).

This makes the kernel idempotent under at-least-once event delivery, which is
what a crash-and-resume adapter actually provides.

### 4.7 Termination

`terminal` is absorbing. `outcome`/`reason` pairs:

| outcome  | reason                | meaning                              |
|----------|-----------------------|--------------------------------------|
| halted   | model_halt            | the model called halt                |
| aborted  | budget_exhausted      | `steps_left` reached 0               |
| aborted  | protocol_exhausted    | repairs ran out                      |
| aborted  | transport_exhausted   | retries ran out                      |

## 5. Canonical trace

Every kernel MUST write, to its trace stream, exactly one record per consumed
event plus one for `start`, in order, as tab-free pipe-joined fields:

    step|phase_in|event|status|action|phase_out|steps_left|repairs_left|retries_left|refs|flag

* `step` is the step counter **before** the transition.
* `event` is `start`, `model_response`, or `tool_response`.
* `status`/`action` are `-` when not applicable.
* `refs` is the comma-joined ref list of the effect emitted by this transition,
  or `-` when the transition emits `final` or emits nothing.
* `flag` is `-`, `stale_event`, or `after_terminal`.

Every matched event produces **exactly one** effect
(`model_request`, `tool_request` or `final`); every ignored event produces
none. An adapter can therefore run in lock-step without polling.

The **trace hash** is `sha256` over the concatenation of records, each
terminated by `\n`. Two kernels are *trace-equivalent* on a case iff their
trace hashes are equal. This is the object the conformance suite compares; it
covers action sequence, phase sequence, budget evolution, which refs the model
was shown, and the terminal state, in one 64-hex-digit string.

## 6. What a kernel MUST NOT do

1. Read payload bytes behind a ref (§2.1).
2. Keep more than one effect in flight.
3. Retry a *tool* on its own. Tool failure is returned to the model. (An
   adapter may retry transport under the model call; that is `mu`'s business.)
4. Invent an action the model did not emit, including a "give up" turn.
5. Depend on wall-clock time for any transition in the `core` profile.

## 7. Profiles

* **core** — §§2–6 with `feedback=on`, `allow_halt=on`. All four shipped
  kernels implement `core`. The conformance suite is entirely `core`.
* **ext** — the ablation knobs in §8. The Python reference implements `ext`;
  the shell kernel implements `history_max` and `steps_max` from it. Ablation
  arms in the paper therefore run on the reference kernel, which is
  trace-equivalent to the other three on `core`.

## 8. Extension knobs (profile `ext`)

| knob             | effect                                                          | ablation it defines |
|------------------|-----------------------------------------------------------------|---------------------|
| `history_max=0`  | model request carries no prior entries                          | no-history          |
| `feedback=off`   | §4.4 does not append the observation                            | no-feedback         |
| `steps_max=1`    | one step only                                                   | one-shot            |
| `allow_halt=off` | `action=halt` becomes `invalid` with reason `halt_disabled`, which does **not** consume `repairs_left` | fixed-horizon |
| `repairs=0`      | first protocol error aborts                                     | no-repair           |
| `retries=0`      | first transport error aborts                                    | no-retry            |
| `wall_deadline`  | non-core; a deadline check before emitting `model_request`       | (excluded from conformance) |

## 9. Claim boundary

What §§1–8 support: *a candidate minimal core for finite-horizon, single-agent,
observation-dependent tool use.* Nothing here establishes that this core is
minimal for agents in general, and the words "irreducible" and "the minimal
agent" do not appear in the normative text on purpose.
