# Seed Package Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans (tasks are tightly coupled in one file). Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `seed.sh` with a silent three-cabin installer that materializes a two-tool interactive coding agent.

**Architecture:** One file; cabins (LOOP / SYSTEM / TASK) live as functions. Tools and product re-enter the same file via shims (`--edit`, `--shell`, `--llm`, `--agent`). Seed specializes a persistent `$SHELL` and unique-match edit, writes `.env`, then runs a `tool_calls` loop. Verify does not trust the model.

**Tech Stack:** POSIX `/bin/sh`, curl, jq for `seed.sh` / `bin/agent` loop and the two built-in tools. Later extensions are unrestricted.

## Global Constraints

- CLI: `sh seed.sh <provider> <API_KEY> [install-dir]`; resume: `sh seed.sh [install-dir]`
- Tools: persistent shell + unique edit only; API `tool_calls` only
- Workspace for product: `$PWD` at `bin/agent` launch; no baked host paths
- Credentials: cwd `.env` and `$INSTALL/.env`, mode 600; never log the key
- Seed terminal: token heartbeat only; product: banner + user input + final answer
- Exit: 64 / 69 / 71 / 72 / 75 / 76 / 77 as specified
- Do not commit unless the user asks

---

### Task 1: Offline contract tests, then the package

**Files:**
- Create: `tests/seed-package.sh`
- Modify: `seed.sh` (replace)
- Modify: `.gitignore`, `README.md`
- Modify: `docs/superpowers/specs/2026-08-13-seed-package-design.md` (status line)

**Interfaces:**
- Produces: `seed.sh --selftest`, `--edit`, `--shell-init/--shell/--shell-stop`, `--agent`, `--llm`
- Produces: shims in `$INSTALL/bin/{agent,llm,shell,edit}` that exec `$INSTALL/seed.sh`

- [x] Write `tests/seed-package.sh` (failing against old seed)
- [x] Run it and confirm RED
- [x] Implement new `seed.sh` and make tests GREEN
- [x] Update README / spec status
- [x] Do not commit
