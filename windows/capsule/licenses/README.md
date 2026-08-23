# Capsule license inventory

This directory is the *definition* of third-party provenance, not a vendor tree.

- SPDX identifiers, homepages, and MSYS2 source URLs live in `../packages.lock.json`.
- `build.sh assemble` writes `NOTICE` next to the extracted runtime from that lockfile plus the first-party `LICENSE`.
- Do not copy downloaded `.pkg.tar.zst` files or extracted `usr/bin/*.exe` into git.
- Copyleft source-offer text and a full SBOM belong to the `release-compliance` task.

First-party code (`seed.sh`, these build scripts) is MIT; see the repository `LICENSE`.
