jq binaries for the seed fallback mirror.

Served at the same plugin root as seed/ and agent/:
  https://pipi.aichattrpg.com/downloads/slab/jq/jq-linux-amd64
  https://pipi.aichattrpg.com/downloads/slab/jq/jq-linux-arm64
  https://pipi.aichattrpg.com/downloads/slab/jq/jq-macos-amd64
  https://pipi.aichattrpg.com/downloads/slab/jq/jq-macos-arm64
  https://pipi.aichattrpg.com/downloads/slab/jq/jq-windows-amd64.exe

Populate:
  sh plugins/jq/fetch.sh

seed.sh tries this directory first, then GitHub.
