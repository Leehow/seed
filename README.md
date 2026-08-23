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
- **Find, verify, register, reuse — build only as a last resort.** On first start the seed surveys the machine and writes a capability index. If `rg` exists, use `rg`; if the box has Codex installed, register it. On a clean box with no `fd`, the agent looked up that Debian ships it as `fd-find` with binary `fdfind`, installed it, and finished the search task. Tool discovery is a graded skill, not an assumption.
- **Extensions ship as prompts, not code.** The plugin catalog under [`plugins/agent/`](plugins/agent/) publishes JSON prompts and empty scaffolds. New capabilities are grown by the model on the local machine, guided by prompts — never by fattening the seed.
- **Never trust the model's word for it.** The interactive `/ini` command lets the model choose how to install the runtime as a global `seed` command, but the shell independently notarizes the result: the receipt, the frozen original PATH, the executable entry point, and a `--probe` identity check must all agree before success is declared. Fake receipts and PATH pollution are part of the test suite.

## What it can do

- Act as a coding agent in any project directory: interactive `>` prompt, or one-shot `-p "task"`.
- Write project code in **any language** — the POSIX restriction covers the runtime, not the artifacts.
- Repair its own environment: fetch jq when missing, `apt-get install` what a task needs, look up the right package name before installing.
- Probe and reuse whatever the host already has (CLIs, interpreters, services), recording each capability with usage, invocation, and smoke-test results in a machine index that amortizes across tasks.
- Install itself as a global command (`/ini`) with shell-side acceptance testing.
- Run the official Terminal-Bench 2.1 suite (Harbor + Docker, all 89 tasks) by dropping the same `seed.sh` into each task container.

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

Then we asked whether the tablet could drop the terminal entirely. A second prompt block, [`web-ide.json`](plugins/agent/web-ide.json), ships no code at all: it describes an evidence contract and eleven acceptance checks, and the agent grows the console on the machine from that. The design it is held to is deliberately narrow — the shell keeps the loop, the server renders the run feed to HTML, and the page is a view over the evidence a run already writes to disk. Nothing in the console re-implements turns, tool dispatch, or streaming.

The console runs on `127.0.0.1` under a Termux wake lock. Into its text box, on the tablet, a human typed one sentence:

> make a 3d game i can play on this tablet

Seventeen rounds later, with no path, no library, no framing, and no instruction to serve or verify anything, the tablet had **3D Speeder**: three files, three lanes, obstacles that accelerate as you survive, on-screen arrows because the prompt said *tablet*, a best score in `localStorage`, and a crash screen. The agent started its own `python -m http.server` and curl-checked all three files for 200 before it answered.

The one-sentence result was better than the detailed prompt that preceded it. Asking for "a single file using three.js with spinning cubes you tap to score" got exactly that and nothing more; the constraint capped the outcome at the asker's imagination. Specify the checks, not the product.

No human wrote a line of either game. The runtime that did this is the same single shell file, running on a phone-grade ARM box.

### Notarized install and offline contract tests

- `/ini` acceptance has been tested against fake receipts and PATH pollution: the model claiming success does nothing; the shell re-resolves `seed` with the frozen pre-run PATH and re-checks identity via `--probe`.
- An offline product contract (fake plugin transport + LLM stub; no network, no real keys) covers 20+ cases: SSE chunk merging, truncated streams triggering a retry, empty replies never being accepted as a final answer, and more.

## Usage

Download `seed.sh` from GitHub main first — do not `curl | sh`. The plugin catalog is fetched from this repo's raw `plugins/` by default (`https://raw.githubusercontent.com/Leehow/seed/main/plugins`); override with `SEED_PLUGIN_ROOT`.

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

Type `/ini` at the interactive prompt and the model will try to install the current runtime as a global command; the shell independently checks the receipt, PATH, and probe. On success:

```sh
seed
seed -p "task"
```

The workspace is always the directory you launched from. State lives in `~/.seed` by default; isolate with `SEED_HOME`. Never commit `.env` or run evidence.

## Development

This GitHub tree **is** the product: [`seed.sh`](seed.sh) plus the prompt catalog. Edit the seed, then:

```sh
/bin/sh -n seed.sh
```

The catalog in [`plugins/agent/`](plugins/agent/) publishes prompts, not a second runtime. Change the agent's temperament by changing those JSON files; do not fatten `seed.sh`.

## What's in this repo

| Path | Role |
|---|---|
| [`seed.sh`](seed.sh) | the whole runtime — download it and run |
| [`plugins/agent/`](plugins/agent/) | prompt catalog: init, skills, commands, lazy extensions |
| [`plugins/seed/`](plugins/seed/) | provider / model catalog |
| [`plugins/jq/`](plugins/jq/) | jq fallback notes and fetch helper |
| [`LICENSE`](LICENSE) | MIT |

## Honest limits

- TB 2.1 scores are single-attempt (k=1), not leaderboard protocol (k=5); community submission is currently closed, so nothing here claims a leaderboard rank.
- The seed depends on a model that supports standard `tool_calls`; models that stop to ask questions mid-task score poorly under benchmark conditions.
- An empty toolbox **plus** no network is the design's weak spot — "find before build" needs somewhere to find.
