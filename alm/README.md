# ALM -- the Agent Loop Machine

A specification for the smallest thing that is still an agent loop, four
implementations of it on deliberately unlike computational substrates, and the
experiments that say whether the substrate matters.

This directory is a research instrument, not a product. The production runtime
in this repository is [`seed.sh`](../seed.sh): a real agent kernel with a
capability index, packs, skills, memory, delegation and run evidence. Nothing
here replaces it, and no claim about "minimality" applies to it. The two must
stay separate on purpose -- a 120 KB file with a memory system is not a
minimal-core argument, and pretending otherwise is the first thing a reviewer
would catch.

```
spec/           ALM v0.1 (operational semantics) and ABI v0.1 (the wire)
kernels/        four implementations of kappa, one per substrate
adapter/        mu and eps: prompts, tools, transport, a persistent shell
conformance/    300 deterministic cases, an oracle, and the runner
witness/        four task families that isolate one piece of the core each
bench/          local graded tasks, plus the pre-registered Terminal-Bench plan
systems/        footprint, TCB, startup, throughput, memory
stats/          equivalence testing, McNemar/Holm, pass^k, variance shares
REPORT.md       generated from the results files by analyze.py
```

## The idea in one paragraph

An agent run is three functions, not one program: a model `mu`, an environment
`eps`, and a kernel `kappa` that decides what to send next, what the budget is,
and when the run is over. ALM specifies `kappa` alone, and it specifies it so
that the kernel is **payload-blind**: prompt bytes, tool output and diff hunks
are named by opaque refs the kernel moves but never reads. What is left is a
transition table over small integers and short tokens -- which is why the same
semantics fit in CPython, POSIX shell, SQL triggers and ARM64 assembly, and why
their agreement is a fact about the semantics rather than about four copies of
the same JSON parser.

## Reproduce

```sh
# 1. conformance: 300 cases x 4 kernels, byte-identical traces
clang -arch arm64 -o alm/kernels/museed-arm64 alm/kernels/museed-arm64.S
python3 alm/conformance/gen_cases.py
python3 alm/conformance/run.py --kernels py,sh,sql,asm

# 2. minimality: information ceiling per ablation arm, no API needed
python3 alm/witness/run.py --policy oracle --kernels py,sh,sql,asm

# 3. every live experiment, three models (needs .env and adapter/models.json)
sh alm/bench/run_model_matrix.sh

# 4. reliability: fault injection on four channels, and what recovery buys
for l in 0 0.01 0.05 0.10 0.30 0.50; do
  python3 alm/witness/run.py --policy oracle --kernels py,sh,sql,asm \
    --arms full --faults $l --out /tmp/f-$l.jsonl
done
python3 alm/witness/run.py --policy oracle --kernels py,sh,sql,asm \
  --arms no_recovery --faults 0.10 --out /tmp/f-norec.jsonl
cat /tmp/f-*.jsonl > alm/witness/results-faults.jsonl

# 5. real graded shell tasks (also part of the matrix above)
python3 alm/bench/run_local.py --model deepseek-flash --kernels py,sh,sql,asm --repeats 7

# 6. footprint, startup, 100k transitions, peak RSS
python3 alm/systems/measure.py --startup 200 --transitions 100000

# 7. Terminal-Bench 2.1 (needs Docker + Harbor; ~6 h per repeat on 10 cores)
sh alm/bench/run_tb_full.sh            # resumable: stop it, run it again
python3 alm/bench/collect_tb.py        # 801 trial dirs -> one analysable file

# 8. one report, and the figures, out of all of it
python3 alm/analyze.py
python3 alm/figures.py
python3 alm/paper_tables.py
```

Drive a real task with any kernel:

```sh
python3 alm/adapter/runtask.py --kernel asm --workdir /tmp/x --verbose \
  --task "write primes.py printing the first ten primes, run it, verify, then HALT"
```

## The four kernels

| id | substrate | what it shows |
|----|-----------|---------------|
| `py` | CPython | the readable reference; also the only kernel used for ablation arms in the paper's tables |
| `sh` | POSIX `/bin/sh` | no `jq`, no `awk`, no forks after start-up: parameter expansion is enough |
| `sql` | SQLite triggers | the loop is `WHERE` clauses; `sqlpump.py` may only move bytes |
| `asm` | ARM64 assembly | five syscalls, no allocator, no string library; one source builds Mach-O and ELF |

`sqlpump.py` is the SQL kernel's I/O device and is deliberately stupid: insert
the line, print the new `outbox` and `trace` rows, read `state.phase` once at
EOF for the exit status. Delete the pump and the database still holds the whole
loop; delete `museed.sql` and the pump can do nothing. That asymmetry is what
makes it a SQL kernel rather than a Python loop with a logging database.

## Limits, stated here rather than discovered later

* The assembly kernel builds for macOS/arm64 (Mach-O) and Linux/arm64 (ELF)
  from one source and passes the suite on both. It still cannot join the
  Terminal-Bench arm: those task images are linux/amd64, and x86-64 is a
  different instruction set, not a port.
* Its history ring holds 4096 entries: exact for any `ALM_HISTORY_MAX <= 4096`,
  lossy for an unbounded history longer than that.
* The SQL kernel needs SQLite >= 3.44 for ordered `group_concat`.
* ALM v0.1 covers finite-horizon, single-agent, observation-dependent tool use.
  Multi-agent, human-in-the-loop, long-lived memory and real-time control are
  out of scope, and the specification says so in normative text.
* Wall-clock deadlines are not part of the core: they are not testable
  deterministically, so they are a conforming extension instead.
