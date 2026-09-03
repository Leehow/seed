# ABI v0.1 — the kernel/adapter wire

Normative. Frozen 2026-08-28 alongside [`ALM-v0.1.md`](ALM-v0.1.md).

A **kernel** implements `kappa`. An **adapter** implements `mu` and `eps`.
They talk over two byte streams:

* kernel **stdout** — effects, one record per line
* kernel **stdin** — events, one record per line
* kernel **fd 3** (or `ALM_TRACE` file) — canonical trace records (§5 of ALM)

The kernel process is started by the adapter, runs one agent run, emits
`final`, then keeps draining stdin until EOF so that redelivered events are
absorbed visibly (ALM s4.6) rather than by dying. It exits 0 at EOF. Exit 2 means the kernel itself broke (a bug), which the conformance runner
distinguishes from an `aborted` outcome. Exit 3 means stdin reached EOF before
the kernel reached `terminal`: the adapter stopped answering, which is an
adapter fault and is never a conformance case outcome.

## 1. Canonical JSONL

Records are JSON objects on one line. The dialect is deliberately narrow so
that a kernel in shell, SQL or assembly can parse it with a byte scan and no
JSON library:

1. **Flat.** No nested objects, no arrays.
2. **No escapes.** Every string value matches `[A-Za-z0-9_,.+/=:-]*`. Free text
   never crosses this wire — it lives behind a ref (§2).
3. **Fixed emission order.** Emitters write keys in the order given below.
   Parsers MUST scan by key name and MUST NOT rely on order.
4. **No whitespace** except the single `\n` terminator.
5. Integers are decimal, optionally `-` prefixed.

A conforming record therefore parses with `scan for "key":`, read to the next
`,` or `}`. That is ~40 lines of assembly, one `awk` pattern, or one SQL
`regexp_substr`. The narrowness is the interoperability mechanism, not an
accident.

## 2. Refs

A **ref** is an opaque token `[a-z][a-z0-9_]*` minted by the adapter, naming a
byte string the adapter holds (a rendered prompt fragment, a tool argument, a
tool observation, a repair note). Kernels move refs; they never dereference
them. See ALM §2.1.

Conventional prefixes — informative only, no kernel may depend on them:
`m*` model arguments, `o*` observations, `r*` repair notes.

## 3. Effects (kernel -> adapter)

    {"v":1,"t":"model_request","run":R,"step":N,"eid":E,"attempt":A,"refs":REFS,"steps_left":S}
    {"v":1,"t":"tool_request","run":R,"step":N,"eid":E,"tool":T,"arg_ref":REF}
    {"v":1,"t":"final","run":R,"step":N,"outcome":O,"status":ST,"reason":RE,"steps_used":U}

* `refs` — comma-joined ref list, or `-` when empty.
* `tool` — the token the model emitted; the kernel does not validate it.
* `outcome` in `{halted,aborted}`; `status` in `{ok,fail,-}`; `reason` per
  ALM §4.7.

## 4. Events (adapter -> kernel)

    {"v":1,"t":"model_response","eid":E,"status":"ok","action":"tool","tool":T,"arg_ref":REF}
    {"v":1,"t":"model_response","eid":E,"status":"ok","action":"halt","halt":H,"arg_ref":REF}
    {"v":1,"t":"model_response","eid":E,"status":"invalid","reason":RE,"arg_ref":REF}
    {"v":1,"t":"model_response","eid":E,"status":"transport_error","reason":RE}
    {"v":1,"t":"tool_response","eid":E,"status":ST,"exit":X,"obs_ref":REF,"nbytes":B,"truncated":TR}

* `model_response.invalid` carries a `reason` token (`bad_json`,
  `unknown_action`, `missing_field`, `empty_completion`, ...) and an `arg_ref`
  naming the repair note the adapter prepared. The kernel appends that ref
  (ALM §4.5) without reading it.
* `tool_response.status` in `{ok,error,timeout}`; `exit` is informative
  (`-1` for timeout); `nbytes` is the observation size after the adapter
  applied `obs_cap`; `truncated` is `0`/`1`.
* A `start` event is not sent: the kernel starts itself (ALM §4.1).

## 5. Configuration

Passed as environment variables at exec time. All optional; defaults shown.

| var                | default | meaning                          |
|--------------------|---------|----------------------------------|
| `ALM_RUN`          | `r1`    | run id, echoed in every effect    |
| `ALM_STEPS`        | `16`    | initial `steps_left`              |
| `ALM_REPAIRS`      | `2`     | initial `repairs_left`            |
| `ALM_RETRIES`      | `3`     | initial `retries_left`            |
| `ALM_HISTORY_MAX`  | `-1`    | entries carried into a request    |
| `ALM_FEEDBACK`     | `1`     | `0` = profile `ext` no-feedback   |
| `ALM_ALLOW_HALT`   | `1`     | `0` = profile `ext` fixed-horizon |
| `ALM_TRACE`        | fd 3    | trace file path if set            |

## 6. Duplicate and out-of-order delivery

The adapter may deliver an event more than once (crash-and-resume). The kernel
answers per ALM §4.6: unchanged state, no effect, one `stale_event` /
`after_terminal` trace record. An adapter that receives no effect after
sending an event MUST NOT block forever; the conformance runner treats
"kernel consumed input and emitted nothing" as the expected response to a
stale event.

## 7. Worked example

Adapter feeds (stdin):

    {"v":1,"t":"model_response","eid":"e1","status":"ok","action":"tool","tool":"shell","arg_ref":"m1"}
    {"v":1,"t":"tool_response","eid":"e2","status":"ok","exit":0,"obs_ref":"o1","nbytes":12,"truncated":0}
    {"v":1,"t":"model_response","eid":"e3","status":"ok","action":"halt","halt":"ok","arg_ref":"m2"}

Kernel emits (stdout), with `ALM_STEPS=16`:

    {"v":1,"t":"model_request","run":"r1","step":1,"eid":"e1","attempt":1,"refs":"-","steps_left":16}
    {"v":1,"t":"tool_request","run":"r1","step":1,"eid":"e2","tool":"shell","arg_ref":"m1"}
    {"v":1,"t":"model_request","run":"r1","step":2,"eid":"e3","attempt":1,"refs":"m1,o1","steps_left":15}
    {"v":1,"t":"final","run":"r1","step":2,"outcome":"halted","status":"ok","reason":"model_halt","steps_used":1}

Trace (fd 3):

    1|init|start|-|-|await_model|16|2|3|-|-
    1|await_model|model_response|ok|tool|await_tool|16|2|3|m1|-
    1|await_tool|tool_response|ok|-|await_model|15|2|3|m1,o1|-
    2|await_model|model_response|ok|halt|terminal|15|2|3|-|-
