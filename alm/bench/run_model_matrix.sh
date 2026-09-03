#!/bin/sh
# run_model_matrix.sh -- every live experiment in the paper.
#
# Two streams, one per endpoint, run in parallel: the vendor API and the local
# proxy do not contend, and the proxy serialises requests internally, so its
# share of the matrix is sized to what it can deliver rather than to what would
# be symmetric.
#
#   sh alm/bench/run_model_matrix.sh
set -eu
HERE=$(CDPATH= cd "$(dirname "$0")" && pwd -P)
ALM=$(CDPATH= cd "$HERE/.." && pwd -P)
W="python3 $ALM/witness/run.py"
L="python3 $HERE/run_local.py"
C=${CONCURRENCY:-10}

# The four arms that carry the capability claim. `fixed_horizon` is in the
# primary model's run and the oracle ceiling but not the secondary models': a
# kernel that refuses to halt makes the model act until the adapter's call cap,
# 45 calls per run, and the arm has no capability effect to replicate.
ABL=full,no_feedback,no_history,one_shot

vendor_stream() {
  # H4 replication on a second tier of the same vendor
  $W --policy live --model deepseek-pro --kernels py --arms "$ABL" --limit 15 \
     --concurrency "$C"
  # H2: same task, four substrates, three repeats, live and stochastic
  $W --policy live --model deepseek-flash --kernels py,sh,sql,asm --arms full \
     --per-family 50 --repeats 3 --concurrency "$C" \
     --out "$ALM/witness/results-live-substrate.jsonl"
  # H2/H3: the crossed design, vendor half
  # 7 repeats, not 3: with 24 task clusters the paired bootstrap CI at 3
  # repeats is wider than the pre-registered 5 pp band, so most substrate pairs
  # come back "inconclusive" -- a statement about sample size, not about
  # substrates.
  $L --model deepseek-flash --kernels py,sh,sql,asm --repeats 7 --concurrency 8
  $L --model deepseek-pro   --kernels py,sh,sql,asm --repeats 7 --concurrency 8
}

proxy_stream() {
  # This endpoint serialises requests: about 6.6 s per call whatever the client
  # concurrency. Its budget goes to the crossed design, where a second vendor is
  # the point, rather than to duplicating an ablation table that the oracle
  # ceiling and a second model tier already establish.
  $L --model gpt-5.6-low --kernels py,sh,sql,asm --repeats 3 --concurrency 4
}

vendor_stream > "$ALM/bench/stream-vendor.log" 2>&1 &
V=$!
proxy_stream > "$ALM/bench/stream-proxy.log" 2>&1 &
P=$!
wait $V; wait $P
echo "both streams done"
