jq binaries for the seed fallback mirror.

Served at the same plugin root as seed/ and agent/:
  http://127.0.0.1:7432/jq/jq-linux-amd64
  http://127.0.0.1:7432/jq/jq-linux-arm64
  http://127.0.0.1:7432/jq/jq-macos-amd64
  http://127.0.0.1:7432/jq/jq-macos-arm64
  http://127.0.0.1:7432/jq/jq-windows-amd64.exe

Populate:
  sh plugins/jq/fetch.sh

seed.sh tries this directory first, then GitHub.
