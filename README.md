# seed

**A coding agent that is one POSIX `/bin/sh` file.**

[中文版 README](README.zh-CN.md)

[`seed.sh`](seed.sh) at the repo root is the **only product, the only runtime, and the only source code**. There is no build step, no packaging pipeline, no generated `bin/agent`. It runs on `/bin/sh` + curl + jq — and if jq is missing, the seed downloads a compatible binary by itself.

Works on Linux, macOS, WSL, Git Bash, and Android Termux. Native cmd / PowerShell is not supported.

```sh
curl -fsSL https://raw.githubusercontent.com/Leehow/seed/main/seed.sh -o seed.sh
cd your-project
/bin/sh seed.sh deepseek sk-your-key
```

That's the whole install. No Node, no Python runtime, no installer, no container. On a bare Debian box whose only tool is curl, the seed bootstraps jq, initializes, and writes its first file in **15 seconds**.

---

## The question this repo asks

Every mainstream coding agent ships as a Node or Python application with a tool zoo: read, grep, glob, todo lists, sub-agents, planners. seed asks a deliberately narrow question:

> **Can POSIX `/bin/sh` + curl + jq alone sustain a tool-using coding agent — including streaming SSE, a persistent shell, and exact-replace editing?**

The answer so far: yes, and the constraint turns out to be a feature. A single portable file means zero install friction, auditable behavior (you can read your entire agent), and an agent that can carry itself onto any box that has a shell — including an Android tablet.

## Design principles

- **One file is everything.** Download `seed.sh`, feed it any OpenAI-compatible endpoint and key, and it is a complete agent. The same file is the documentation of itself: ~everything the agent does is readable shell.
- **The shell owns the loop; the model owns the judgment.** The main loop, SSE streaming, error handling, and round limits live in the shell. What to look at, what to change, and when to stop are the model's decisions. The model is never asked to write its own controller each turn.
- **Exactly two API tools.** A persistent `shell` (cwd and environment survive across calls) and an exact-replace `edit` (match zero or multiple times → fail, file untouched). No read/grep/glob/todo tools — those are ordinary commands inside the shell. "Two tools" is not "two abilities": everything the machine has is reachable through them.
- **Find, verify, register, reuse — build only as a last resort.** First launch records identity and a cheap `PATH` observation sweep. Tasks investigate plausible observations, verify only what they need, and register reusable capabilities. If `rg` exists, use `rg`; if a clean box lacks `fd`, look up that Debian ships it as `fd-find`, verify `fdfind`, then reuse it. Discovery is a graded skill, not a desktop-shaped assumption.
- **Policy extensions ship as prompts, not code.** The pack catalog under [`packs/agent/`](packs/agent/) publishes JSON prompts and empty scaffolds. Generic integrity boundaries — atomic state writes, publication gates, retrieval limits, and install rollback — stay in the kernel; product-specific behavior stays in packs.
- **Never trust the model's word for it.** `/ini` is an offline, deterministic shell transaction: it selects an existing user-owned writable directory from the frozen launch `PATH`, publishes an immutable content-addressed runtime without overwriting an existing `seed`, validates exact bytes and `--probe` identity, commits a receipt, and rolls back its own files on failure. No model call, profile edit, `sudo`, or network request is involved.

## Agent Kernel architecture

The narrow question was answered, and the answer generalizes: Seed does not chase feature-complete coding agents — it is the **Agent Kernel** that vertical agents grow from. The decision is recorded in [`docs/adr/0001-seed-as-agent-kernel.md`](docs/adr/0001-seed-as-agent-kernel.md). Three layers, each answering one question, nothing crossing:

- **Capability = CLI** — what this machine can do. The Machine index is three layers: **observations** (what was seen here — one cheap `PATH` sweep at launch, plus whatever a task notices), **capabilities** (what has been investigated and verified, each carrying the exact `probe` command whose exit status is its `ok`), and **resources** (what exists off this machine that Seed already found once). No fixed tool fields: `git`, `python`, `docker`, `opkg`, and a vendor's `device-cli` are all the same record shape, so a BusyBox or OpenWrt box is not asked six desktop questions. Discovery is hardcoded; environment knowledge is not. The LLM keeps only the two primitives, `shell` and `edit`. A new capability is a new index entry plus a CLI on the machine — never a new function tool. See [`docs/adr/0002`](docs/adr/0002-machine-index-as-cognition.md).
- **Skill = how to do things.** SKILL.md files per the agentskills.io spec, registered by name/description/path; the body is `cat`-ed only when a task hits (progressive disclosure). Distilled experiences are skills — one mechanism for method reuse, not two.
- **Pack = what Seed grows into.** Published packs are prompt-only; installing one never edits `seed.sh`. The coding pack yields a coding agent; a security pack yields a Strix-like agent. Same kernel, same two tools, different pack.

### Memory system ([`packs/agent/memory.json`](packs/agent/memory.json))

Cross-session method reuse built from plain files, English-only internal records, prompt policy, and deterministic kernel gates — no database, vector index, or resident service:

- Four layers: **L0 rules** (`rules.md`, always highest priority) → **L1 facts** (project notes/facts plus machine index) → **L2 experiences** (one directory per id, with a lifecycle) → **L3 evidence** (append-only `runs/*.jsonl`).
- Experiences live a lifecycle: `candidate → active → degraded → quarantined / stale / retired`; retired moves to the attic, nothing is deleted.
- The model has **proposal rights only**. `/maintain` and `--maintain` are offline runtime commands, never model turns: the kernel canonicalizes only unambiguous SKILL metadata (including adding wholly absent frontmatter), store-relative catalog/evidence spelling, and launch-path spelling; it runs every non-trivial `verify[]` separately in a fresh shell rooted at the launch workspace, writes its own exact receipt, and publishes only when the 16-field schema, timestamps, containment, canonical SKILL frontmatter, synchronized catalog row, and runtime evidence all agree. Present-but-invalid frontmatter and every non-contained path are rejected.
- **Opaque identifiers are runtime-owned.** The model may name semantic artifacts with stable, readable slugs. UUIDs, content hashes, run and receipt IDs, and temporary names are generated, persisted, correlated, and verified by the runtime. Seed never asks a model to invent, copy, or round-trip an opaque random identifier.
- Retrieval has one runtime-owned funnel: OS/tool scope → active or degraded-with-warning status → English keyword score → deterministic ranking → at most 3 metadata rows. `SKILL.md` is loaded only on a hit; models must not scan the experience index to create a second activation path.
- Experience is a skill: validated active/degraded experiences merge into `agent.skills` after every task. A capability going `ok:false` makes dependent experiences inapplicable immediately; maintenance can then move them to `stale`. The runtime fetches the catalog-declared memory prompt when absent, while automatic pack refresh remains opt-in (`SEED_AUTO_UPDATE=1`).

### Pack ecosystem

- [`packs/agent/`](packs/agent/) contains the prompt policies for `init`, memory, commands, skills, models, packs, delegation, delivery, and Web IDE. The agent catalog currently declares `init` as required and `memory` as the runtime-managed optional policy; product bundles may install the others under `agent-store/packs/`.
- The catalog [`index.json`](packs/agent/index.json) is versioned. Set `SEED_AUTO_UPDATE=1` to opt into startup refresh; otherwise installed prompt policy remains pinned. Explicit `/packs` installs are unchanged.
- `/packs install <slug>` lands a published pack into `agent-store/packs/`; `/packs` lists them all.

### Delegation

A subagent is one shell command — `seed --oneshot '<self-contained task>'` — with evidence landing under `.agent-runs/`. No scheduler, no orchestrator process: the Unix process tree is the multi-agent runtime.

## What's planned

Direction decided in ADR-0001; run provenance (`SEED_PARENT_RUN_ID` / `SEED_RUN_ROLE`) is already implemented. Remaining work:
- **Seed Console.** A web UI that reads the run files under `.agent-runs/` and renders the run graph. A view over the runtime's own evidence — not a second agent loop, and deliberately not a Web IDE.
- **Tighter capability contract.** Sharper semantics for `probe`, `scope`, and `ok` in the Machine index.
- **Vertical packs.** security (Strix-like), microscope, research — each a prompt-only pack over the same kernel.

## What it can do

- Act as a coding agent in any project directory: interactive `>` prompt, or one-shot `-p "task"`.
- Write project code in **any language** — the POSIX restriction covers the runtime, not the artifacts.
- Repair its own environment: fetch jq when missing, `apt-get install` what a task needs, look up the right package name before installing.
- Probe and reuse whatever the host already has (CLIs, interpreters, services), recording each capability with usage, invocation, and smoke-test results in a machine index that amortizes across tasks.
- Install itself as a global command (`/ini`) with shell-side acceptance testing.
- Run the official Terminal-Bench 2.1 suite (Harbor + Docker, all 89 tasks) by dropping the same `seed.sh` into each task container.
- Distill successful tasks into reusable experiences (skills) with deterministic promotion, and pull them back on later tasks through the scope + keyword retrieval funnel.
- Delegate self-contained subtasks to child agents via `seed --oneshot`, with run evidence under `.agent-runs/`.

## Experiments

### Cold start and capability indexing (Apple container, Debian 12 aarch64)

The same seed was dropped into a **clean** box (only curl + CA certificates) and a **rich** box (git / rg / python3 / jq / openssl / Codex preinstalled).

| Environment | Task | Result | Wall clock | What it actually did |
|---|---|---|---|---|
| clean | hello-file | pass | 15s | fetched jq itself → init → wrote the file |
| clean | web-install-fd | pass | 14s | discovered Debian package `fd-find`, used `fdfind` |
| clean | openssl-selfsigned-cert (TB 2.1 instruction) | pass | 50s | installed python3 on the fly, wrote its own check script |
| clean | nginx-request-logging (TB 2.1 instruction) | pass | 35s | installed nginx, fixed a 403, all four checks green |
| clean | fix-git (TB 2.1 instruction) | pass | 17s | installed git, merged the branch |

Index amortization: paying for a full capability census up front (54s, registering 11 tools including Codex 0.147.0) makes every subsequent task cheap — hello-file 6s, list-tools 16s, fix-git 10s. Skip the census and the index stays empty: later tasks that depend on it fail. The survey is a cost you pay once and collect on all session long.

### Official Terminal-Bench 2.1 (Harbor + Docker, 89 tasks)

Each task container gets only the standalone `seed.sh` plus curl and CA certificates — jq, git, and python are the seed's own problem. It runs `--oneshot` on the unmodified official instruction, and the official verifier grades.

- seed + `deepseek-v4-pro`, k=1 single pass: **Mean 0.360 (32/89)**. This is the full official task set with the official verifier — but a single-attempt score, not the k=5 leaderboard protocol. We label it accordingly.
- A second full run with `deepseek-v4-flash` (after fixing a streaming-stall bug and adding a time-budget preamble) is in progress, tracking above the first run at the midpoint.
- Same-model baselines (mini-swe-agent, terminus-2) are queued on the same task set and verifier.
- Failure analysis is published, not hidden: the three dominant modes are "never submitted", "ran out of time mid-work", and "declared done but failed verification". One notable finding: an earlier `--max-time` on the streaming curl was decapitating long model thinking and mis-charging the failure to the model — now replaced by stall detection.

### A tablet that codes itself, from the browser

We typed the seed into a stock Android tablet's Termux over adb: it self-healed the missing jq, initialized, and opened its `>` prompt. Then we gave it one task — *"make a 3D web game"* — and the agent on the tablet did the rest unaided: a single-file three.js game, served with `nohup python -m http.server 8080`, `curl localhost:8080` checked for 200 **before** the URL was reported, playable by touch.

Then we asked whether the tablet could drop the terminal entirely. A second pack, [`web-ide.json`](packs/agent/web-ide.json), ships no code at all: it describes an evidence contract and eleven acceptance checks, and the agent grows the console on the machine from that. The design it is held to is deliberately narrow — the shell keeps the loop, the server renders the run feed to HTML, and the page is a view over the evidence a run already writes to disk. Nothing in the console re-implements turns, tool dispatch, or streaming.

The console runs on `127.0.0.1` under a Termux wake lock. Into its text box, on the tablet, a human typed one sentence:

> make a 3d game i can play on this tablet

Seventeen rounds later, with no path, no library, no framing, and no instruction to serve or verify anything, the tablet had **3D Speeder**: three files, three lanes, obstacles that accelerate as you survive, on-screen arrows because the prompt said *tablet*, a best score in `localStorage`, and a crash screen. The agent started its own `python -m http.server` and curl-checked all three files for 200 before it answered.

The one-sentence result was better than the detailed prompt that preceded it. Asking for "a single file using three.js with spinning cubes you tap to score" got exactly that and nothing more; the constraint capped the outcome at the asker's imagination. Specify the checks, not the product.

No human wrote a line of either game. The runtime that did this is the same single shell file, running on a phone-grade ARM box.

### Notarized install and offline contract tests

- `/ini` acceptance covers offline execution, existing-command refusal, PATH pollution, exact-content validation, and rollback both before and after publishing the command entry.
- An offline product contract (fake pack transport + LLM stub; no network, no real keys) covers 20+ cases: SSE chunk merging, truncated streams triggering a retry, empty replies never being accepted as a final answer, and more.

## Usage

Download `seed.sh` from GitHub main first — do not `curl | sh`. The pack catalog is fetched from this repo's raw `packs/` by default (`https://raw.githubusercontent.com/Leehow/seed/main/packs`); override with `SEED_PACK_ROOT`.

```sh
curl -fsSL https://raw.githubusercontent.com/Leehow/seed/main/seed.sh -o seed.sh
cd your-project
/bin/sh /path/to/seed.sh deepseek sk-your-key
```

First run writes config to `~/.seed/.env`, initializes the machine capability index, then opens the `>` prompt. Exit with an empty line or Ctrl-D. Afterwards, run the same file from any project directory:

```sh
/bin/sh /path/to/seed.sh
/bin/sh /path/to/seed.sh -p "write the install instructions into README"
```

Any OpenAI-compatible endpoint (third argument, the model name, is optional):

```sh
/bin/sh seed.sh https://api.example.com/v1 sk-xxxx model-name
```

Type `/ini` at the interactive prompt to run the deterministic offline installer. It uses an existing user-owned writable directory already on the launch `PATH`, never edits shell profiles or overwrites another `seed`, and reports success only after exact-content, PATH, probe, and receipt checks. On success:

```sh
seed
seed -p "task"
```

The workspace is always the directory you launched from. State lives in `~/.seed` by default; isolate with `SEED_HOME`. Never commit `.env` or run evidence.

## Development

This GitHub tree **is** the product: [`seed.sh`](seed.sh) plus the prompt catalog. Edit the seed, then:

```sh
/bin/sh -n seed.sh
/bin/sh tests/test_seed_agent_kernel.sh
/bin/sh tests/test_seed_modes.sh
/bin/sh tests/test_seed_pack_manager.sh
```

The catalog in [`packs/agent/`](packs/agent/) publishes prompts, not a second runtime. Product policy belongs there; cross-pack safety and atomicity invariants belong in the kernel.

## What's in this repo

| Path | Role |
|---|---|
| [`seed.sh`](seed.sh) | the whole runtime — download it and run |
| [`packs/agent/`](packs/agent/) | prompt catalog: init, skills, commands, memory, lazy extensions |
| [`docs/adr/`](docs/adr/) | architecture decision records (ADR-0001: Seed as Agent Kernel) |
| [`packs/seed/`](packs/seed/) | provider / model catalog |
| [`packs/jq/`](packs/jq/) | jq fallback notes and fetch helper |
| [`LICENSE`](LICENSE) | MIT |

## Honest limits

- TB 2.1 scores are single-attempt (k=1), not leaderboard protocol (k=5); community submission is currently closed, so nothing here claims a leaderboard rank.
- The seed depends on a model that supports standard `tool_calls`; models that stop to ask questions mid-task score poorly under benchmark conditions.
- An empty toolbox **plus** no network is the design's weak spot — "find before build" needs somewhere to find.
