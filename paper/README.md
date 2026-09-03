# Paper: How Small Can an Agent Runtime Be?

English preprint for [arXiv](https://arxiv.org) (`cs.AI` primary, `cs.SE` and
`cs.PL` as cross-lists). The Chinese reading copy [`seed-zh.md`](seed-zh.md)
predates this rewrite and describes the earlier, Seed-only framing.

## What changed

The earlier draft was a systems report about `seed.sh` on Terminal-Bench. This
one is about the semantics underneath it: [ALM v0.1](../alm/spec/ALM-v0.1.md),
four conformant kernels, and the experiments in [`../alm/`](../alm/). The
production runtime now appears in exactly one section, clearly separated, with
its Terminal-Bench numbers marked as a report about a production agent rather
than evidence about minimality.

## Numbers are generated, not typed

Every table and every scalar in `seed.tex` comes from a results file:

```bash
python3 alm/paper_tables.py
```

writes `paper/gen/macros.tex` and `paper/gen/tab-*.tex`, then lints `seed.tex`
for macros or table files that do not exist. Re-running an experiment changes
the paper; nothing is transcribed by hand. Do not edit anything under
`paper/gen/`.

## Build

```bash
cd paper && tectonic seed.tex
```

Tectonic 0.17 resolves the bibliography itself, so that one command is the
whole build. With a TeX Live installation instead:

```bash
cd paper && pdflatex seed.tex && bibtex seed && pdflatex seed.tex && pdflatex seed.tex
```

Needs `article`, `hyperref`, `booktabs`, `amsmath`, `graphicx`. The draft
compiles clean: no undefined references, no overfull boxes. `alm/paper_tables.py`
lints the source first (every `\input`/`\widetable` resolves, every macro is
defined, every generated table's row width matches its column spec), which
catches the errors a build would catch and some it would not.

## Before you upload

1. Author block is complete: Hao Li, Institute of Chemistry, Chinese Academy
   of Sciences, `leeehow@gmail.com`, ORCID `0009-0004-2696-3267`.
2. Citations were checked against arXiv on 2026-08-29: `wu2024stateflow`
   (2403.11322), `bahdanau2024tapeagents` (2412.08445), `quine2026`
   (2603.18030, author Hao Ke), `xia2024agentless` (2407.01489),
   `yao2024taubench` (2406.12045) and `merrill2026terminalbench` (2601.11868)
   all resolve with matching titles, authors and years. Venue fields for the
   older entries (conference vs preprint) were not re-checked.
3. Re-read the limitations section. The Terminal-Bench matrix in
   [`../alm/bench/PREREGISTRATION.md`](../alm/bench/PREREGISTRATION.md) is
   pre-registered and **unrun**; the paper says so, and it must keep saying so
   until it is run.
4. Zip `seed.tex` + `refs.bib` + `gen/` (+ `seed.bbl` after a local bibtex
   pass). Upload the compiled PDF as the paper.

Source of the Terminal-Bench numbers in the production-runtime section: Harbor
jobs on the evaluation host (`2026-08-19__21-31-54` seed,
`2026-08-20__20-35-52` mini-swe-agent, `2026-08-21__19-42-10` terminus-2).
Those directories are not in git. Do not put API keys, hostnames, or gateway
names in the paper.
