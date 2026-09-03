# ALM v0.1 -- results

Generated 2026-09-02 22:01 by `alm/analyze.py`. Every number below comes from a results file in this directory; sections with no file say so.

Host: `Darwin 25.6.0 arm64`, CPython 3.13.5.

| model | vendor | endpoint model id | decoding |
|---|---|---|---|
| deepseek-flash | deepseek | deepseek-v4-flash | temperature 0, {"thinking": {"type": "disabled"}} |
| deepseek-pro | deepseek | deepseek-v4-pro | temperature 0, {"thinking": {"type": "disabled"}} |
| grok-high | xai-via-local-relay | grok-4.5-high | temperature 0 |
| grok-low | xai-via-local-relay | grok-4.5-low | temperature 0 |

## H1 -- semantic portability

| kernel | branch | budget | envfault | ext | idempotency | normal | protocol | total |
|---|---|---|---|---|---|---|---|---|
| py | 50/50 | 50/50 | 50/50 | 50/50 | 50/50 | 50/50 | 50/50 | **350/350** |
| sh | 50/50 | 50/50 | 50/50 | 50/50 | 50/50 | 50/50 | 50/50 | **350/350** |

Cross-kernel canonical-trace disagreements: **0**. Every kernel also matched the case oracle record for record; the suite compares effect streams and trace records byte for byte, not just outcomes. 350 cases, 700 kernel runs, 2.4s wall.

### Second platform

The same cases, unchanged, inside a Terminal-Bench task container (`alexgshaw/fix-git:20260403`): **Linux x86_64, CPython 3.13.12, SQLite 3.40.1**, on linux/amd64 emulated over an arm64 host.

| kernel | cases passed |
|---|---|
| py | 350/350 |
| sh | 350/350 |
| sql | 350/350 |

The assembly kernel is not in that table because those images are linux/amd64. It does run on Linux: built from the same source with `cc -o museed-arm64 museed-arm64.S` in `gcc:13 (linux/arm64)`, it passes **350/350** on **Linux aarch64**. One source file, two operating systems; only syscall numbering, the syscall register, symbol-address spelling, section names and the `O_CREAT` bits are conditional. x86-64 would be a different instruction set, not a port, so `asm` still cannot join the Terminal-Bench arm.

This found a real portability bug rather than confirming one: the relational kernel had been written against SQLite's ordered `group_concat`, which arrived in 3.44, and task images ship 3.40. Unordered `group_concat` would have been a silent wrong answer -- the ref list is a sequence -- so the window is now walked with a recursive CTE, available since 3.8.3.

### Rule coverage

Every transition in ALM v0.1 s4 and s8, and how often the suite fires it:

| rule | spec | trace records | cases |
|---|---|---|---|
| start | s4.1 start | 350 | 350 |
| tool | s4.2 model calls a tool | 1195 | 317 |
| halt | s4.3 model halts | 204 | 204 |
| halt_disabled | s8 halt refused (ext) | 23 | 13 |
| repair | s4.5 protocol repair | 62 | 45 |
| abort_protocol | s4.5 repairs exhausted | 35 | 35 |
| retry | s4.5 transport retry | 23 | 18 |
| abort_transport | s4.5 retries exhausted | 13 | 13 |
| observe | s4.4 observation, run continues | 1097 | 307 |
| abort_budget | s4.4 budget exhausted | 98 | 98 |
| stale_event | s4.6 event ignored | 384 | 50 |
| after_terminal | s4.6 event after terminal | 102 | 50 |

### Can the suite fail?

A suite four kernels pass is worth nothing unless it can reject a broken one. Each row is one semantic mutation of the reference kernel -- a plausible mistake, not a syntax error -- and the share of the 350 cases that catch it.

| mutation | what it breaks | cases failing | rate |
|---|---|---|---|
| budget-never-spent | steps_left is not decremented on a tool response | 317 | 90.6% |
| repairs-unbounded | protocol repair ignores its budget | 65 | 18.6% |
| retries-unbounded | transport retry ignores its budget | 27 | 7.7% |
| accepts-stale-eid | an event answering an old effect is processed | 24 | 6.9% |
| terminal-not-absorbing | events after final are processed again | 50 | 14.3% |
| feedback-always-on | the observation is appended even when feedback is off | 17 | 4.9% |
| history-unbounded | history_max is ignored when selecting refs | 45 | 12.9% |
| repair-loses-note | a protocol repair does not show the model its error | 42 | 12.0% |
| retry-appends-note | a transport retry pretends the model answered | 18 | 5.1% |
| transport-is-repair | a failed model call is charged to the repair budget | 10 | 2.9% |
| step-never-advances | the step counter stays at 1 | 307 | 87.7% |
| attempt-never-resets | attempt is not reset at a new step | 46 | 13.1% |
| budget-off-by-one | the run stops one step early | 101 | 28.9% |
| halt-status-dropped | the model's own verdict is not recorded | 32 | 9.1% |
| allow-halt-ignored | the fixed-horizon knob is not honoured | 13 | 3.7% |
| refused-halt-spends-repair | a refused halt is charged to the repair budget | 13 | 3.7% |
| unknown-action-repaired | an unrecognised action is guessed at instead of ignored | 26 | 7.4% |

**17/17 detected, 0 undetected.** The `ext` category of the suite exists because of this test: with a core-only suite a kernel that ignored `feedback=off` passed all 300 cases.

## H4 -- what the core is for

### Information ceiling (oracle policy, no model)

| family | full | fixed_horizon | no_feedback | no_history | one_shot |
|---|---|---|---|---|---|
| feedback_required | 1.00 | 1.00 | 0.06 | 0.06 | 0.20 |
| recovery_required | 1.00 | 1.00 | 0.00 | 0.00 | 0.00 |
| state_required | 1.00 | 1.00 | 0.00 | 0.00 | 0.00 |
| unknown_horizon | 1.00 | 1.00 | 0.18 | 0.18 | 0.00 |

### Live model `deepseek-flash` (50 instances per family)

| family | full | fixed_horizon | no_feedback | no_history | one_shot |
|---|---|---|---|---|---|
| feedback_required | 1.00 | 1.00 | 0.00 | 0.00 | 0.00 |
| recovery_required | 1.00 | 1.00 | 0.00 | 0.00 | 0.00 |
| state_required | 1.00 | 1.00 | 0.00 | 0.00 | 0.00 |
| unknown_horizon | 1.00 | 1.00 | 0.00 | 0.00 | 0.00 |

### Live model `deepseek-pro` (15 instances per family)

| family | full | fixed_horizon | no_feedback | no_history | one_shot |
|---|---|---|---|---|---|
| feedback_required | 1.00 | - | 0.20 | 0.00 | 0.00 |
| recovery_required | 1.00 | - | 0.00 | 0.00 | 0.00 |
| state_required | 1.00 | - | 0.00 | 0.00 | 0.00 |
| unknown_horizon | 1.00 | - | 0.00 | 0.00 | 0.00 |

### Live model `grok-low` (50 instances per family)

| family | full | fixed_horizon | no_feedback | no_history | one_shot |
|---|---|---|---|---|---|
| feedback_required | 1.00 | 1.00 | 0.06 | 0.00 | 0.00 |
| recovery_required | 1.00 | 1.00 | 0.00 | 0.00 | 0.00 |
| state_required | 1.00 | 1.00 | 0.00 | 0.00 | 0.00 |
| unknown_horizon | 1.00 | 1.00 | 0.00 | 0.00 | 0.00 |

Live runs that hit the adapter's model-call cap: 357/3440, all in ablated arms, where the model keeps acting because the information it needs never arrives.

Arm comparisons against `full` (oracle ceiling, paired by instance, 10,000-resample bootstrap, +/-5 pp band):

| arm | rate | diff vs full | 95% CI | verdict | p (Holm) |
|---|---|---|---|---|---|
| fixed_horizon | 1.000 | +0.000 | [+0.000, +0.000] | equivalent | 1 |
| no_feedback | 0.060 | +0.940 | [+0.905, +0.970] | different | 1.53e-56 |
| no_history | 0.060 | +0.940 | [+0.905, +0.970] | different | 1.53e-56 |
| one_shot | 0.050 | +0.950 | [+0.920, +0.980] | different | 5.1e-57 |

Variance share of the outcome (eta^2, n=4000): **arm 0.869**, **family 0.005**, **kernel 0.000**.

One honest non-result: `fixed_horizon` loses nothing on any family here. An agent that cannot halt still has a harmless action available in three of the four environments, so removing the stopping rule costs budget and creates overrun risk rather than making the task unsolvable. The core's necessity claim rests on feedback, cross-step state and the recursion; it does not rest on halting.

## H2 -- substrate against task outcome

### Witness `full` arm, live model `deepseek-flash`, 3 repeats

| kernel | runs | rate | pass^1 | pass^3 |
|---|---|---|---|---|
| asm | 600 | 1.000 | 1.000 | 1.000 |
| py | 600 | 1.000 | 1.000 | 1.000 |
| sh | 600 | 1.000 | 1.000 | 1.000 |
| sql | 600 | 1.000 | 1.000 | 1.000 |

| A | B | rate A | rate B | diff | 95% CI | verdict | p (Holm) |
|---|---|---|---|---|---|---|---|
| asm | py | 1.000 | 1.000 | +0.000 | [+0.000, +0.000] | equivalent | 1 |
| asm | sh | 1.000 | 1.000 | +0.000 | [+0.000, +0.000] | equivalent | 1 |
| asm | sql | 1.000 | 1.000 | +0.000 | [+0.000, +0.000] | equivalent | 1 |
| py | sh | 1.000 | 1.000 | +0.000 | [+0.000, +0.000] | equivalent | 1 |
| py | sql | 1.000 | 1.000 | +0.000 | [+0.000, +0.000] | equivalent | 1 |
| sh | sql | 1.000 | 1.000 | +0.000 | [+0.000, +0.000] | equivalent | 1 |

### Local end-to-end tasks: 24 tasks x 4 substrates x 4 models x 5 repeats

| task | deepseek-flash | deepseek-pro | grok-high | grok-low |
|---|---|---|---|---|
| c-build | 1.00 | 1.00 | 1.00 | 1.00 |
| cli-args | 1.00 | 1.00 | 1.00 | 1.00 |
| count-lines | 1.00 | 1.00 | 1.00 | 1.00 |
| csv-filter | 1.00 | 1.00 | 1.00 | 1.00 |
| dedupe-csv | 1.00 | 0.00 | 1.00 | 1.00 |
| dep-error | 0.93 | 0.96 | 1.00 | 1.00 |
| dir-tree | 1.00 | 1.00 | 1.00 | 1.00 |
| env-default | 1.00 | 1.00 | 1.00 | 1.00 |
| exact-edit | 0.00 | 0.50 | 1.00 | 1.00 |
| fix-python | 1.00 | 1.00 | 1.00 | 1.00 |
| fix-shebang | 1.00 | 1.00 | 1.00 | 1.00 |
| grep-count | 1.00 | 1.00 | 1.00 | 1.00 |
| hello-file | 1.00 | 1.00 | 1.00 | 1.00 |
| json-extract | 1.00 | 1.00 | 1.00 | 1.00 |
| make-executable | 1.00 | 1.00 | 1.00 | 1.00 |
| patch-config | 0.14 | 1.00 | 1.00 | 1.00 |
| pipeline-report | 1.00 | 1.00 | 1.00 | 1.00 |
| rename-ext | 1.00 | 1.00 | 1.00 | 1.00 |
| sort-uniq | 1.00 | 1.00 | 1.00 | 1.00 |
| sqlite-query | 1.00 | 1.00 | 1.00 | 1.00 |
| sum-json | 1.00 | 1.00 | 1.00 | 1.00 |
| tar-roundtrip | 0.00 | 1.00 | 1.00 | 1.00 |
| two-file-refactor | 1.00 | 0.93 | 1.00 | 1.00 |
| word-count | 1.00 | 1.00 | 1.00 | 1.00 |
| **all** | **0.878** | **0.933** | **1.000** | **1.000** |

| substrate | deepseek-flash | deepseek-pro | grok-high | grok-low | all |
|---|---|---|---|---|---|
| asm | 0.881 | 0.952 | 1.000 | 1.000 | 0.942 |
| py | 0.881 | 0.940 | 1.000 | 1.000 | 0.938 |
| sh | 0.875 | 0.917 | 1.000 | 1.000 | 0.927 |
| sql | 0.875 | 0.923 | 1.000 | 1.000 | 0.929 |

Substrate comparisons, paired by task, pooled over models:

| A | B | rate A | rate B | diff | 95% CI | verdict | p (Holm) |
|---|---|---|---|---|---|---|---|
| asm | py | 0.942 | 0.938 | +0.004 | [-0.004, +0.015] | equivalent | 1 |
| asm | sh | 0.942 | 0.927 | +0.015 | [+0.002, +0.033] | equivalent | 1 |
| asm | sql | 0.942 | 0.929 | +0.013 | [+0.000, +0.031] | equivalent | 1 |
| py | sh | 0.938 | 0.927 | +0.010 | [+0.000, +0.023] | equivalent | 1 |
| py | sql | 0.938 | 0.929 | +0.008 | [+0.000, +0.019] | equivalent | 1 |
| sh | sql | 0.927 | 0.929 | -0.002 | [-0.006, +0.000] | equivalent | 1 |

## Terminal-Bench 2.1

Three models appear here and the reason is worth stating plainly. Arm 1 ran on `deepseek-v4-flash` and was retired on cost after 1560 trials -- a budget decision, not a scientific one, and it costs comparability, so it is reported rather than overwritten. Arm 2, the substrate comparison, runs on `grok-4.5-low` through a local relay with no per-token charge. Arm 3 is one substrate on `qwen3.8-max` from a different vendor, and exists only to measure the model factor against arm 2. Protocols belong to the adapter, never to the kernel: `a` forbids commentary, `b` requires a thought before the action, `br` is `b` with an output budget wide enough for a model that reasons before it answers.

| arm | tasks | substrates | repeats | scored trials | resolved |
|---|---|---|---|---|---|
| arm 1: deepseek-v4-flash, protocol a (terse) | 89 | 3 | 5 | 1263 | **0.171** |
| arm 1b: deepseek-v4-flash, protocol b (reasoned) | 89 | 3 | 1 | 266 | **0.199** |
| arm 2: grok-4.5-low, protocol br | 89 | 3 | 3 | 791 | **0.465** |
| arm 3: qwen3.8-max, protocol br (model factor) | 89 | 1 | 1 | 89 | **0.258** |

### Substrate comparison on the current arm

801 trials: 89 tasks x 3 substrates x 3 repeats, official verifier, agent budget 80 steps. Harbor 0.21.0, dataset checkout `7131e43`.

| substrate | rep0 | rep1 | rep2 | all | resolved | pass^1 | pass^3 |
|---|---|---|---|---|---|---|---|
| py | 0.461 | 0.483 | 0.384 | **0.443** | 116/262 | 0.440 | 0.286 |
| sh | 0.477 | 0.471 | 0.539 | **0.496** | 131/264 | 0.493 | 0.360 |
| sql | 0.494 | 0.404 | 0.471 | **0.457** | 121/265 | 0.455 | 0.345 |

Of 801 trials, 10 were excluded as host or harness faults and 23 were scored 0 as the agent's own failure. The split is decided once, in `bench/collect_tb.py`, and is the difference between charging an agent for a Docker problem and not:

| disposition | outcome | trials |
|---|---|---|
| excluded | VerifierTimeoutError | 8 |
| excluded | no_reward | 2 |
| scored 0 | AgentTimeoutError | 22 |
| scored 0 | NonZeroAgentExitCodeError | 1 |

The 10 exclusions are spread across repeats (1 in repeat 0), so no repeat is carrying a host problem on its own.

Pairwise equivalence, paired by task, 10,000-resample cluster bootstrap, pre-registered +/-5 pp band. **Repeats 0-2, the pre-registered window:**

| A | B | rate A | rate B | diff | 95% CI | verdict | p (Holm) |
|---|---|---|---|---|---|---|---|
| py | sh | 0.440 | 0.493 | -0.052 | [-0.105, -0.004] | inconclusive | 0.355 |
| py | sql | 0.440 | 0.455 | -0.015 | [-0.073, +0.045] | inconclusive | 1 |
| sh | sql | 0.493 | 0.455 | +0.037 | [-0.011, +0.086] | inconclusive | 0.359 |

The substrates disagree on **37 of 89 tasks**, each by one or two repeats out of three and in both directions, with nothing concentrated on any one substrate: that is the signature of a model that is unstable on hard tasks, not of a runtime that is worse. **21** tasks are solved by every substrate on every repeat and **62** by something at least once.

A statistical note that matters for reading the verdicts: the interval width is driven by the base rate, and per-task variance $p(1-p)$ is largest at $p=0.5$. This arm sits at 0.465, so its intervals are about 33% wider than an arm at 0.17 with the same number of trials. Raising the score made equivalence *harder* to certify, not easier -- the point estimates here (0.052 at most) are smaller than the arm with the tighter intervals.

## H3 -- where capability comes from

The model factor is measured where there is headroom to measure it: one substrate, one protocol, the same 89 Terminal-Bench tasks, `qwen3.8-max` against `grok-4.5-low`. Everything except the model is byte identical.

| stratum | tasks | qwen3.8-max | grok-4.5-low | diff | 95% CI | CI excludes 0 |
|---|---|---|---|---|---|---|
| all tasks | 89 | 0.258 | 0.493 | -0.234 | [-0.339, -0.129] | yes |
| excluding tasks where the slower model timed out | 60 | 0.383 | 0.547 | -0.164 | [-0.294, -0.036] | yes |

The slower model timed out on 29 of 89 tasks, so the headline difference mixes competence with wall clock. Stratifying separates them: the gap survives at -0.164 on the tasks where it never ran out of time, and the faster model resolves 0.379 of the tasks the slower one timed out on -- close to its own average, so those are not simply the hard tasks.

Set beside the substrate comparison on the same arm, where no pair differed by more than 0.052 and none was ever judged different: **changing the model moved the outcome about 4 times as much as changing the substrate did** (0.234 against 0.052).

### The local suite, and why it stopped being informative

This suite cannot carry the model factor, for two independent reasons. Its model levels changed protocol at the same time they changed vendor (the deepseek runs used protocol `a`, the grok runs `br`), so model and prompt are confounded in it. And for the current model it is saturated anyway.

On `grok-4.5-low` and `grok-4.5-high`, all four substrates resolve **576/576** -- a ceiling separates nothing, which is why H3 was measured on Terminal-Bench instead. The suite is kept because four substrates agreeing exactly on real graded work is still worth showing.

## Reliability: what the core's error handling buys

Four channels are corrupted at the same rate lambda: the model returns unparsable output, the model call fails in transport, the tool fails or times out, and every event is redelivered with probability lambda (at-least-once delivery). The policy is held fixed and observation-driven, so what moves is the runtime's problem, not the agent's cleverness.

| arm | lambda | runs | success | model calls / run | terminal reasons |
|---|---|---|---|---|---|
| full | 0.0 | 800 | 1.000 | 3.52 | model_halt 800 |
| full | 0.01 | 800 | 1.000 | 3.64 | model_halt 780, budget_exhausted 20 |
| full | 0.05 | 800 | 1.000 | 4.28 | model_halt 724, budget_exhausted 76 |
| full | 0.1 | 800 | 1.000 | 5.08 | model_halt 644, budget_exhausted 156 |
| full | 0.3 | 800 | 0.930 | 7.72 | model_halt 344, budget_exhausted 264, protocol_exhausted 132 |
| full | 0.5 | 800 | 0.520 | 7.96 | protocol_exhausted 404, transport_exhausted 168, model_halt 120 |
| no_recovery | 0.0 | 800 | 1.000 | 3.52 | model_halt 800 |
| no_recovery | 0.1 | 800 | 0.720 | 3.12 | model_halt 524, protocol_exhausted 148, transport_exhausted 128 |
| no_recovery | 0.3 | 800 | 0.305 | 2.48 | protocol_exhausted 340, transport_exhausted 284, model_halt 176 |
| no_repair | 0.0 | 800 | 1.000 | 3.52 | model_halt 800 |
| no_repair | 0.1 | 800 | 0.850 | 3.63 | model_halt 644, protocol_exhausted 156 |
| no_repair | 0.3 | 800 | 0.505 | 3.60 | protocol_exhausted 436, model_halt 344, transport_exhausted 16 |
| no_retry | 0.0 | 800 | 1.000 | 3.52 | model_halt 800 |
| no_retry | 0.1 | 800 | 0.840 | 4.21 | model_halt 524, transport_exhausted 172, budget_exhausted 104 |
| no_retry | 0.3 | 800 | 0.515 | 4.30 | transport_exhausted 508, model_halt 176, budget_exhausted 76 |

The two recovery rules -- bounded protocol repair and bounded transport retry -- buy **nothing** in a clean world (1.000 with them, 1.000 without, at lambda=0) and **+28 percentage points** at lambda=0.10 (1.000 against 0.720). Dropping them also makes runs *cheaper*, because a run that aborts early spends fewer model calls: the wrong way to read a cost table.

Idempotency under at-least-once delivery: **14288** events were redelivered across this sweep and **0** produced a duplicate side effect. The four kernels' success rates differ by at most 0.000 at any lambda, so absorbing a redelivered event is a property of the specification, not of one implementation.

## Where the wall clock and the tokens go

| suite | model | runs | T_model | T_tool | T_orchestration | orch. ms / step | prompt tok / run | completion tok / run |
|---|---|---|---|---|---|---|---|---|
| local tasks | deepseek-flash | 672 | 92.2% | 7.5% | 0.37% | 3 | 6853 | 253 |
| local tasks | deepseek-pro | 672 | 81.1% | 18.6% | 0.37% | 6 | 1532 | 95 |
| local tasks | grok-high | 288 | 99.1% | 0.7% | 0.15% | 7 | 4945 | 775 |
| local tasks | grok-low | 288 | 98.9% | 0.9% | 0.17% | 7 | 4196 | 501 |
| witness ablations | deepseek-flash | 1600 | 99.5% | 0.0% | 0.47% | 3 | 2932 | 39 |
| witness ablations | deepseek-pro | 240 | 99.5% | 0.0% | 0.52% | 6 | 1142 | 16 |
| witness ablations | grok-low | 1600 | 99.9% | 0.0% | 0.06% | 4 | 5041 | 2817 |

`T_orchestration` is everything that is not the model call or the tool: prompt rendering, the ABI round trip, and the kernel itself. It is measured, not modelled, and it includes the adapter -- the kernel's own share is smaller than this and is bounded by the microbenchmark in the systems table.

## Systems: two sizes, and where the time actually goes

| kernel | substrate | source | gzip | logical LOC | stripped bin | TCB | cold ms | warm p50 ms | warm p99 ms | transitions/s | peak RSS |
|---|---|---|---|---|---|---|---|---|---|---|---|
| py | cpython 3 | 9.1 KiB | 2.6 KiB | 212 | - | 6.6 MiB | 16.48 | 17.08 | 21.07 | 177,139 | 21.8 MiB |
| sh | POSIX /bin/sh | 6.8 KiB | 2.2 KiB | 180 | - | 98.7 KiB | 6.39 | 7.23 | 31.27 | 2,975 | 2.5 MiB |
| sql | SQLite relational | 15.1 KiB | 3.3 KiB | 239 | - | 7.0 MiB | 37.15 | 32.94 | 69.70 | 280 | 104.8 MiB |
| asm | ARM64 assembly | 39.6 KiB | 7.2 KiB | 1330 | 32.6 KiB | 36.5 KiB | 5.96 | 2.84 | 7.76 | 463,755 | 1.7 MiB |

* **TCB** is the interpreter or binary, every library it links, and -- for the Python-backed kernels -- exactly the stdlib modules they import, not the whole install. Quoting the kernel-only column alone is how an assembly kernel becomes "a 9 KB agent" while a JSON parser and libsystem sit underneath it. In the other direction: libraries in the macOS dyld shared cache have no file on disk and count as 0 here, so `sh` and `asm` are understated by libSystem.
* The shared adapter (14.7 KiB, 343 logical lines) is byte-identical for all four kernels and cancels in every comparison.
* Language-independent complexity: **9 transition rules** and **13 state fields**, fixed by the specification and implemented in full by each kernel. Logical LOC is reported because reviewers ask for it, not because one line of SQL, shell and assembly are the same unit.

The spread between the fastest and slowest kernel is 1656x per transition. At a model call of roughly 500 ms, even the slowest (muSeed-SQL, 3561 us) is **0.712%** of one step.

## Not run

The primary-model Terminal-Bench arm is done (above). Still unrun: the secondary-model pass on the pre-registered 30-task subset, which needs a second working endpoint, and the same-model external baselines (mini-SWE-agent, Terminus-2), which bear on the production-runtime comparison rather than on any ALM hypothesis.

The ARM64 kernel is Mach-O and does not run in a Linux task container; an ELF port is required before `asm` can join that arm.

