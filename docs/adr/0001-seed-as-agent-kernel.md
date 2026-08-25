# 0001. Seed as Agent Kernel: Capability = CLI, Pack = Product

## Status

Accepted (2026-08-24). Superseded in part by
[0002](0002-machine-index-as-cognition.md) (2026-08-25): the three-layer architecture
stands, but the Machine index shape it describes — `system.tools` / `system.resources`
/ `system.skills` — is replaced by observations / capabilities / resources plus
`agent.skills`.

## Context

A Strix analysis (2026-08-24) looked at how a serious security-agent product gets its power: complex capabilities — browser automation, security tooling — are standalone CLIs the agent drives through a shell, not per-capability function tools. The orchestration layer stays small; the machine provides the depth.

Seed already leans this way and has proven the pieces:

- The runtime is one POSIX `/bin/sh` file. The LLM sees exactly two API tools: a persistent `shell` and an exact-replace `edit`. Everything else — read, grep, glob, web fetch — is an ordinary command inside the shell. This has carried the agent through Terminal-Bench 2.1, a self-hosting tablet, and cold-start capability indexing.
- At the time of this decision, the Machine index (`packs/agent/init.json`) recorded what the machine could do in `system.tools` and `system.resources`, with `system.web` describing fetch policy. ADR 0002 replaces those fixed v1 namespaces with observations, capabilities, resources, and `agent.skills`.
- Delegation exists and is boring: `packs/agent/delegate.json` defines it as one shell command, `seed --oneshot '<task>'`, with evidence landing under `.agent-runs/`. No scheduler, no orchestrator process.
- The memory system (`packs/agent/memory.json`) validated the pack mechanism end to end: experiences are distilled into SKILL.md directories (agentskills.io format) and registered by metadata. The pack remains prompt-only; the kernel owns the generic integrity boundary around it: shared locking, schema and containment checks, runtime-executed maintenance verifiers, runtime-authored evidence, bounded retrieval, and publication into `agent.skills`.

The judgment this ADR records: Seed should not chase being a feature-complete coding agent. It should be the **Agent Kernel** that Strix-like products grow from. Feature completeness competes on a crowded axis; a kernel that turns one pack plus one machine into a working vertical agent does not.

## Decision

Seed adopts a three-layer architecture. Each layer answers one question, and nothing crosses layers.

1. **Capability = CLI** — "what can be done on this machine." Callable capabilities (git, rg, python, agent browsers, docker, host agent CLIs) are registered in the Machine index with locator, usage, and a probe. ADR 0002 defines the current `capabilities` / `resources` representation. The LLM keeps only the two primitives — `shell` and `edit`. No new function tools, ever; a new capability is a new index entry plus a CLI on the machine, not a new tool schema.

2. **Skill = how to do things** — "what method to follow." Skills are SKILL.md files per the agentskills.io specification (YAML frontmatter with `name` + `description`, then the body). The Machine index registers only name/description/path; the body is `cat`-ed only when a task hits — progressive disclosure. Distilled experiences are skills (memory system L2): one mechanism for method reuse, not two.

3. **Pack = what Seed grows into** — "who is this agent today." Published packs are prompt-only, and installing one never modifies `seed.sh`. A pack may ship skills, capability-discovery instructions, bootstrap instructions, and acceptance tests. The coding pack yields a coding agent; a security pack yields a Strix-like agent; a microscope pack yields a microscope agent. Same kernel, same two tools, different pack.

Supporting decisions:

- **Multi-agent = Unix process tree.** A subagent is `seed --oneshot '<self-contained task>'` started from the persistent shell, exactly as `delegate.json` describes. No Python MultiAgentOrchestrator, no scheduler process. `SEED_PARENT_RUN_ID` and `SEED_RUN_ROLE` carry provenance into evidence under `.agent-runs/`.
- **Console is a view, not a loop.** Any future Seed Console UI reads the run evidence already written to `.agent-runs/`. It never re-implements turns, tool dispatch, or streaming, and it is not a Web IDE — the web-ide pack already holds the line: the shell keeps the loop, the page renders evidence.
- **Sandbox is a capability.** docker/podman/bwrap are Machine index entries like any other CLI. A pack may instruct "prefer sandboxed execution for this class of task"; Docker is never a hard requirement of the kernel.

Explicitly not doing:

- Native tool sprawl (browser_tool, image_tool, database_tool, …).
- A built-in multi-agent scheduler.
- A built-in Web Agent runtime.

## Consequences

- `seed.sh` stays a small kernel: loop, transport, two tools, deterministic pack management and installation, machine-index bootstrap, cross-process state integrity, bounded experience publication/retrieval, and provenance. Product-specific methods and temperament remain outside it.
- Any vertical agent product = `seed.sh` + one pack + the CLIs the machine already has (or installs on demand via find-verify-register-reuse).
- The memory system supplies cross-session method reuse (experience → skill); the capability contract supplies execution (index entry → shell call). Together they make a grown agent compound instead of reset.
- Product extension lands in packs and Machine index entries. A `seed.sh` change is justified only for a cross-pack invariant that prompt compliance cannot safely enforce, such as atomicity, containment, publication authority, or rollback.

## References

- Strix analysis (user, 2026-08-24) — the kernel-vs-product judgment this ADR records.
- Memory system design — `packs/agent/memory.json`; experience-as-skill and the deterministic promote gate.
- Machine index structure — `packs/agent/init.json`; delegation — `packs/agent/delegate.json`.
- Agent Skills specification — https://agentskills.io/specification
