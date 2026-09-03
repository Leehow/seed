# Pre-registration -- ALM v0.1 cross-substrate study

> **Superseded for the model and protocol by
> [`PREREGISTRATION-v2.md`](PREREGISTRATION-v2.md) (2026-08-31).** This
> document governs arm 1 (`deepseek-v4-flash`, protocol `a`), which is still
> reported. Its s7 amendment promised five repeats; the arm was stopped on cost
> after four and 82% of the fifth.

Frozen 2026-08-28, before any Terminal-Bench run of a mu-Seed kernel. Anything
below that changes afterwards is a deviation and gets written down in
`DEVIATIONS.md`, not edited away here.

## 0. Question

Holding the model, the tool interface, the prompt bytes and the environment
fixed, does the substrate that runs the agent kernel change what the agent can
do -- and by how much does it change what the agent costs?

## 1. Hypotheses

**H1 (semantic portability).** Kernels written in Python, POSIX shell, SQL and
ARM64 assembly pass the same ALM v0.1 conformance suite and produce identical
canonical traces on every case.
*Falsified by:* any case where two conformant-claimed kernels differ in trace
hash, or differ from the oracle.
*Status: executed (2026-08-28) -- 350 cases x 4 kernels, 0 failures, 0
disagreements, all twelve transition rules exercised, and 17/17 seeded mutations
of the reference kernel caught.*

**H2 (task-capability equivalence).** With mu, eps, prompt and budget fixed,
per-task success rates of the four substrates differ by less than
**5 percentage points**.
*Falsified by:* a 95% paired-bootstrap CI for a pairwise difference lying
wholly outside [-0.05, +0.05].
*Status: executed on the local task suite, the witness suite, and
Terminal-Bench 2.1 (801 trials). On Terminal-Bench one pair of substrates is
certified equivalent and two are inconclusive at the +/-5 pp band; no pair is
different. The pre-registered three repeats were reported as such rather than
extended until a verdict appeared.*

**H3 (where capability comes from).** In a crossed design, the variance in
outcomes attributable to substrate is small relative to the variance
attributable to model and task.
*Falsified by:* substrate eta^2 within a factor of two of the model or task
eta^2.
*Status: executed on the local task suite, fully crossed over 3 models x 4
substrates x 12 tasks x 3 repeats.*

**H4 (core necessity).** Removing feedback, cross-step state or the recursion
collapses success on the matching witness family; removing framework features
above the ALM core does not.
*Falsified by:* an ablation arm matching the full arm on its own witness family.
*Status: executed -- oracle ceiling and live model, 4 families x 50 instances
x 5 arms.*

## 2. Frozen parameters

| parameter | value |
|---|---|
| dataset | `terminal-bench/terminal-bench-2-1`, checkout `7131e43`, 89 tasks |
| task manifest | `dataset-manifest.json` (name, difficulty, category, timeouts, image) |
| harness | Harbor, version recorded per job in the job directory |
| verifier | official, unmodified |
| container | fresh per run, no cross-task memory |
| max steps | `ALM_STEPS=80` for every substrate |
| repairs / retries | `ALM_REPAIRS=2`, `ALM_RETRIES=3` |
| observation cap | 64 KiB, truncation marker appended by the adapter |
| tools | `shell`, `edit`, and `HALT`; identical schema and prompt for all arms |
| system prompt | byte-identical across substrates; SHA-256 recorded per job |
| shell | one persistent session; `cd` and exports persist |
| temperature / top_p | 0 / 1 |
| max output tokens | 1200 |
| transport retry | none in the adapter; the kernel's `ALM_RETRIES` rule handles it |
| tool retry | none; a failed tool is an observation, per ALM s4.4 |
| task timeout | the task's own `agent.timeout_sec` |
| ordering | substrates interleaved per task block, never run substrate-by-substrate |
| logging | per step: model ms, tool ms, tokens, action, status, canonical trace |

Recorded per run, never inferred later: provider, exact model id and snapshot,
endpoint, prompt/completion/reasoning/cached token counts, HTTP retries and
429/5xx counts, start and end timestamps, container image digest, kernel git
commit.

## 3. Sample sizes

| arm | tasks | repeats | runs |
|---|---|---|---|
| primary model x 4 substrates | 89 | 3 | 1068 |
| second model x 4 substrates | 30 (pre-registered subset) | 3 | 360 |
| external baselines (mini-SWE-agent, Terminus-2), primary model | 89 | 3 | 534 |

Stretch, budget permitting: 5 repeats on the primary model (1780 runs) to
report pass^5 alongside pass^1.

The 30-task subset is fixed by `select_subset.py` (proportional allocation over
`difficulty`, largest remainder; within a stratum ordered by
`sha256("alm-v0.1:" + task_dir)`) and written to `subset-30.json` **before**
any run. Quotas: easy 1, medium 19, hard 10.

## 4. Analysis plan

* **Primary.** Pairwise substrate differences in per-task success rate, paired
  by task, 10,000-resample task-clustered bootstrap, 95% percentile CI,
  equivalence band +/-5 pp. Verdicts: `equivalent` (CI inside the band),
  `different` (CI outside), `inconclusive` (overlapping).
* **Secondary.** McNemar exact on discordant tasks with Holm correction across
  the six substrate pairs; pass^1 and pass^3 per substrate; variance shares
  (eta^2) for substrate, model and task.
* **Diagnostics, not hypotheses.** Timeout counts, `AgentTimeoutError` vs
  reward-0 splits, orchestration time as a share of wall clock, tokens per
  resolved task.

No result is reported as a leaderboard rank: the community protocol is k=5 and
these runs are not a submission.

## 5. Known confounds, declared in advance

1. **Install surface is not equal.** mini-SWE-agent's Harbor adapter installs a
   Python toolchain; a mu-Seed container is given curl and CA certificates.
   Reported next to every number, never equalised silently.
2. **SQL and assembly kernels need an interpreter or a binary in the container.**
   The Python and shell kernels do not. TCB size is reported per substrate
   (`alm/systems/results.json`), and the comparison is about kappa, not about
   who has the smaller container.
3. **Hosted models move under a fixed name.** Substrates are interleaved within
   a task block so that drift hits all arms equally.
4. **The witness families are designed to separate arms.** They are evidence
   about the ALM core, not an estimate of how often real tasks need feedback.

## 6. Status

Executed: H1 (conformance, on two platforms), H4 (witness ablations, oracle
ceiling + live model), the fault-injection reliability sweep, the systems
measurements, H2/H3 on the witness and local task suites, and the
primary-model Terminal-Bench arm (89 tasks x 3 substrates x 3 repeats = 801
trials, `run_tb_full.sh` + `collect_tb.py`).

One declared deviation: substrates were run as three concurrent Harbor jobs
rather than interleaved inside each task block. That is tighter interleaving,
not looser -- all three see the same wall clock and the same endpoint state.

Not executed: the secondary-model pass on the 30-task subset (needs a second
working endpoint) and the same-model external baselines (they bear on the
production runtime, not on H1-H4). The assembly kernel is absent from the
Terminal-Bench arm: those images are linux/amd64.

## 7. Amendment, 2026-08-30 (written before repeats 3 and 4 were run)

The pre-registered three repeats left two of the three substrate pairs
`inconclusive`: the point differences were inside the +/-5 pp band but the 95%
intervals reached past it. We are extending to **five repeats** and fixing the
terms here, before the extra data exists, because deciding how much data to
collect after seeing a result is how optional stopping produces whatever answer
the author wanted.

* **Exactly two more repeats (3 and 4), then stop.** Not "until a verdict
  appears". If five repeats still leave a pair inconclusive, that is the
  reported outcome.
* **The trigger was interval width, not the sign of the difference.** All three
  point estimates already sat inside the band; none of them moved the decision.
* **Both analyses are reported side by side**: the pre-registered
  repeats 0--2, and the extended repeats 0--4. If they disagree, that
  disagreement is the finding, and the pre-registered number is the one that
  carries the pre-registration's authority.
* Nothing else changes: same tasks, same dataset checkout, same budgets, same
  prompt bytes, same exclusion rule, same +/-5 pp band, same bootstrap.
