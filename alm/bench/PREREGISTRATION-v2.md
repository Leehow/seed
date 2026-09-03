# Pre-registration v2 -- the Grok arm

Frozen 2026-08-31, before any Terminal-Bench trial was run with this model or
this protocol. Supersedes [`PREREGISTRATION.md`](PREREGISTRATION.md) for
everything below; that document still governs the arm it describes, which is
reported rather than deleted (s6).

## 0. Why there is a v2

The first arm ran 1560 Terminal-Bench trials on `deepseek-v4-flash`. It is
being retired for one reason, stated plainly: **money**. The arm cost roughly
400 RMB, and a large share of that was waste rather than measurement -- the
protocol it used made the model repeat itself until the step budget ran out, so
the average run spent 74 of its 80 steps and, because every call resends the
visible history, about eight times the tokens a converging run needs.

The replacement endpoint is a local relay with no per-token cost. Changing the
model is therefore not a scientific improvement being dressed up as one; it is
a budget decision, and it costs comparability, which is why the first arm's
results are kept and reported rather than overwritten.

## 1. What is retained from arm 1

Nothing about arm 1 is deleted. Specifically retained and reported:

* the substrate-equivalence result (1560 trials: one pair equivalent, two
  inconclusive, none different, largest point difference 0.034);
* the protocol A/B comparison on 89 tasks (0.171 vs 0.199) and the mechanism
  behind it (median steps 80 -> 15, voluntary halts 12% -> 36%);
* the three adapter defects it exposed, which are findings in their own right.

Arm 1's amendment promised five repeats and got through four and 82% of the
fifth before it was stopped. That is a deviation from `PREREGISTRATION.md` s7,
it was stopped on cost and not on the results, and repeat 4 is reported as the
partial repeat it is.

## 2. Frozen parameters for arm 2

| parameter | value |
|---|---|
| model | `grok-4.5-low` via a local relay, no API key |
| model factor (H3) | `grok-4.5-low` vs `grok-4.5-high`, same family, different reasoning effort |
| decoding | temperature 0; reasoning is on and not configurable at this endpoint |
| protocol | `br` in `alm/adapter/prompts.py` |
| system prompt | SHA-256 `b61aa19933b96a35adae43c93c3a006f1aa27034a0ebe6ee652c13584f075e2a`, 2481 bytes |
| max output tokens | 32768 (it must cover reasoning tokens, or the model returns an empty completion) |
| `ALM_REPAIRS` | 4 |
| `ALM_STEPS` | 80 |
| observation cap | 8 KiB |
| tools | `shell`, `edit`, `HALT` -- unchanged |
| dataset | `terminal-bench/terminal-bench-2-1`, checkout `7131e43`, 89 tasks |
| substrates | `py`, `sh`, `sql` (the assembly kernel is arm64; the images are amd64) |
| container install | `python3` only; no credential is shipped into the container |
| exclusion rule | unchanged: agent timeouts and non-zero exits score 0; environment and verifier faults are excluded and counted |
| equivalence band | unchanged: +/-5 pp, 10,000-resample task-clustered bootstrap, McNemar with Holm |

## 3. Sample size, and the stopping rule, declared now

**Three repeats of all 89 tasks on all three substrates: 801 trials.** At the
measured rate (roughly 7.5 hours per repeat on this host) that is about 22
hours of wall clock.

The rule, fixed before the first trial: **repeats are added or dropped on
wall-clock availability alone, never on the results.** If the arm is stopped
early, the number of completed repeats is reported along with the reason, and
the analysis is presented at whatever repeat count was reached. There is no
"run until a verdict appears" clause, because that is how a pre-registered band
turns into a formality -- which is exactly what happened in arm 1 and is
recorded in its s7 amendment.

## 4. What a low absolute score would and would not mean

Arm 1 taught us that the absolute rate is dominated by the adapter, not the
kernel: the same kernels scored 0.171 and 0.199 under two prompts, and a third
configuration (reasoning enabled) failed outright until the output budget was
raised. So for this arm:

* a low rate is a statement about mu -- prompt, model and decoding -- and about
  task difficulty, not about the substrate;
* the substrate comparison is unaffected by all of that, because every
  substrate shares one adapter, byte for byte;
* we are not tuning the prompt against Terminal-Bench scores. `br` was fixed
  before this arm began and its hash is above.

## 5. H3 on this arm

The model factor is `grok-4.5-low` vs `grok-4.5-high` on the 24-task local
suite, four substrates, three repeats each. That is a within-family effort
difference and is therefore a conservative estimate of what a model change can
do -- the same limitation the deepseek flash/pro pair had, stated again here.

## 6. Status at freezing

Executed and unaffected by the model change (no model is involved): the
conformance suite on two platforms, the oracle ceiling for every ablation arm,
the fault-injection sweep, and the systems measurements.

Executed on the retired model and reported as arm 1: the Terminal-Bench matrix,
the live witness ablations, and the local task suite.

To run on `grok-4.5-low`: the local task suite (running at the time of
freezing), the live witness ablations, and the Terminal-Bench arm specified
above.

## 7. Addition, 2026-09-01 (written before the arm was run)

The 24-task local suite saturated: `grok-4.5-low` and `grok-4.5-high` both
resolve 288/288 on all four substrates. It can no longer separate models or
substrates, so the H3 model factor it was supposed to carry has to come from
somewhere with headroom.

Declared before running: **one Terminal-Bench arm with `grok-4.5-high`, the
`sh` kernel only, 89 tasks, one repeat.** One kernel because the substrate
question already has its evidence and this arm is about the model; everything
else -- protocol `br`, prompt hash, budgets, dataset, exclusion rule -- is
identical to s2, so `grok-4.5-low` versus `grok-4.5-high` is a clean
within-family reasoning-effort contrast.

Also declared now, so it cannot be decided later: **the Terminal-Bench arm
stops at the three pre-registered repeats.** At the observed base rate near
0.46 the per-task variance is near its maximum and the +/-5 pp interval is
about +/-0.05 at three repeats; reaching +/-0.035 would take roughly six. We
are not adding them. The reported outcome is whatever three repeats give,
including "inconclusive", and the reason recorded here is wall-clock cost, not
the direction of the estimates.

## 8. Discarded repeat, 2026-09-01

Repeat 2 of the Terminal-Bench arm was run while the host ran out of disk. The
Docker daemon died mid-arm and the trials that survived did so on a machine
with under 20 GB free. The repeat is discarded and re-run.

The decision rests on host evidence that is independent of the scores:
repeat 2 recorded **17 infrastructure faults against repeat 1's 4** -- eleven
`VerifierTimeoutError` and six trials that produced no reward at all, which is
what resource starvation looks like. The scores corroborate it (0.368 against
0.450 and 0.452, and -0.098 on the 88 tasks all three repeats share) but they
are not the reason: a repeat is not thrown away for being low.

The H3 arm of s7 was discarded on the same grounds and for the same reason: it
ran in the window between the failing repeat 2 and the disk being freed, and
recorded **23 infrastructure faults against the reference arm's 1** -- nineteen
of them `docker compose` failures. Its 0.367 is therefore not usable as a model
factor: the gap to grok-4.5-low's 0.46 cannot be separated from the host. It is
re-run.

The discarded job directories are kept locally as `*-contaminated` rather than
deleted. They are a few hundred megabytes of per-trial container logs and are
not in the repository; what is in the repository is
`bench/results-discarded.jsonl` -- the same per-trial outcomes, in the same
schema as the analysed data, regenerated by

```sh
python3 alm/bench/collect_tb.py --scope all --discarded \
        --out alm/bench/results-discarded.jsonl
```

so the claims above can be checked without taking anyone's word for them.

Disk was freed by deleting an 81 GB Apple `container` build cache (zero images,
left over from August) and the APFS local snapshot that was still pinning it.
Two attempts to move that cache to an external SSD instead were abandoned: both
`cp` and `rsync -aS` expanded the sparse file rather than preserving it -- 59 GB
of real data became 670 GB on the destination before the second attempt was
stopped.
