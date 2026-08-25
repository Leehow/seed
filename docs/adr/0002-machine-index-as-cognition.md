# 0002. Machine index v2: observations, capabilities, resources

## Status

Accepted (2026-08-25)

## Context

ADR 0001 fixed "Capability = CLI": a new capability is an index entry plus a CLI on
the machine, never a new function tool. It left the index shape as it stood —
`system.tools` (a fixed object keyed `sh`, `curl`, `jq`, `rg`, `git`, `python`),
`system.resources` (a discovered census), `system.other`, `system.skills`.

That shape carries a desktop assumption. `rg`, `git`, and `python` are *fields*,
so every machine is asked the same six questions whether or not they mean anything
there, and the runtime re-probes exactly those six at every launch. An OpenWrt box
with `opkg` and a vendor `device-cli`, or a BusyBox appliance, answers "not found"
six times and then has nowhere structured to put what it does have. The index says
what Seed expected, not what Seed found.

It also conflates three different epistemic states under one `ok` boolean: *I saw
this name*, *I understand what it does*, and *I ran its probe and it exited 0*.

## Decision

The machine index becomes a record of what Seed has observed, understood, and
verified on this machine — grown by tasks, never presumed at boot.

**Three layers, one direction.**

    Resources ──install──> Observations ──understand+verify──> Capabilities

1. **Observations** — what is here. Flat records, no interpretation:
   `{type, name, path, source, observed_at?}`. Written by the bootstrap sweep and
   by any deeper probe a task runs (`busybox --list`, a vendor directory, an env
   fact). Discovery only: an observation never asserts that anything works.

2. **Capabilities** — what Seed understands and has verified. One open-schema
   record per capability: `{id, name, kind, locator, purpose[], use, needs[],
   observed, understood, verified, ok, probe, evidence[], observed_at,
   verified_at, scope[], skill, note}`. This is the layer a task queries first.

3. **Resources** — what exists outside this machine that Seed has already found
   once: projects, packages, docs, endpoints. Installing one produces a new
   observation, which investigation may promote to a capability.

**No fixed capability keys.** Every layer is an array. `rg`, `git`, `python`,
`docker`, `opkg`, `device-cli`, and a microscope vendor CLI are all the same shape.
The runtime keeps exactly three prerequisites of its own — `sh`, `curl`, `jq` —
under `identity.prereqs`, because the loop cannot run without them; they are not
capabilities the model discovered and are not subject to discovery policy.

**Discovery is hardcoded; environment knowledge is not.** The runtime knows how to
enumerate `PATH` and read `uname`. It does not know that macOS means brew or that
OpenWrt means opkg. A package manager is an observation the model investigates like
anything else.

**Bootstrap is cheap and total.** At first init the runtime writes identity
(kernel, os, arch, shell, home, PATH dirs) and one sweep of executable names
on PATH. It runs no `--version`, installs nothing, and asks no OS-specific
question. Everything past that is task-driven.

**Verification is per-use, not per-boot.** A capability's `ok` is the result of its
own recorded `probe`, re-run when it is used, when its locator fails, or on an
explicit refresh — not re-derived for every capability at every launch.

**History is not deleted.** A capability that breaks becomes `ok:false` with a
note; the record and its evidence stay. "I used to know this and now it is broken"
is information.

### Three refinements to the proposal as received

- **The timestamp belongs to the sweep, not to each row.** A PATH sweep on this Mac
  finds 2501 executables. As full observation records with a per-row `observed_at`
  that is 400 KB of JSON, 368 KB of which is 2501 copies of one timestamp and one
  source string. Sweep rows carry `{type, name, path, source}` and the time lives
  once in `identity.scans`. Records written for a reason keep their own
  `observed_at`.

- **Observations live in their own file.** `observations.json` is the only part
  that grows to hundreds of KB; capabilities, resources, and skills together stay
  under ~20 KB. Splitting the big one means a capability query never parses the
  sweep, and the sweep is rewritten without touching curated records. The other
  three layers stay in `index.json` — four files would quadruple the atomic-write
  and repair surface for no measured gain.

- **Machine and Agent are namespaces, not files.** `agent.skills` moves out of
  `system.skills` so the machine layers stand alone, but stays in the same file:
  the skill catalog is small, and one file keeps one repair path.

## Consequences

- `system.tools` is gone. v1 tool and resource rows migrate into capability or
  resource records without inventing absent tools; the next PATH sweep rebuilds
  current executable observations separately.
- The runtime's launch work drops from "probe six named tools" to "confirm three
  prerequisites and refresh identity" — and stops being wrong on machines that
  never had those six.
- The memory system gains a real coupling point. An experience's `scope.tools`
  resolves against capabilities, so it becomes inapplicable as soon as a required
  capability stops verifying; maintenance can then record the `stale` transition.
- Retrieval order for a task becomes explicit: rules → capabilities → observations
  → resources → web, and only then build.
- `skill_catalog()` renders `agent.skills`; the machine layers are never injected
  into the system prompt. The index is queried with `jq`, never `cat`.

## References

- ADR 0001 — Capability = CLI, Pack = Product.
- `packs/agent/memory.json` — the L0–L3 memory layers this index couples to.
- Machine index v2 proposal (user, 2026-08-25).
