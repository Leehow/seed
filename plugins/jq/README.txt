Optional/manual jq binaries. seed.sh does not fetch from this directory by default.

When jq is missing, seed downloads the matching binary from official GitHub Releases
by OS/arch (jqlang/jq, default 1.7.1), unless SEED_JQ_URL overrides the URL.

This directory can still be populated for manual use:
  sh plugins/jq/fetch.sh
