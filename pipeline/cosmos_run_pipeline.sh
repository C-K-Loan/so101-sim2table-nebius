#!/bin/bash
# End-to-end Cosmos pipeline: Transfer the sim videos, Reason-score + curate.
# Sequential-run convention: Transfer → stop → Reason → stop. One container at a time.
#
# Usage:
#   ./cosmos_run_pipeline.sh <sim_dataset_dir> [limit]
# Produces:
#   <sim_dataset_dir>.cosmos/   - Cosmos-augmented videos + transfer_manifest.json
#   <sim_dataset_dir>.cosmos/cosmos_reason_scores.json
# Prints kept episode count at end.
#
# Prereqs on the VM:
#   - cosmos_nim_setup.sh available at /home/ubuntu/cosmos_nim_setup.sh (or $NIM)
#   - cosmos_transfer_wrapper.py + cosmos_reason_curator.py in CWD or on PYTHONPATH
#   - NGC_API_KEY in env or ~/.ngc/api_key
#   - docker group membership (sg docker -c "..." if fresh session)

set -euo pipefail

SIM_DS="${1:?usage: $0 <sim_dataset_dir> [limit]}"
LIMIT="${2:-}"
NIM="${NIM:-/home/ubuntu/cosmos_nim_setup.sh}"
WRAPPERS_DIR="${WRAPPERS_DIR:-/home/ubuntu}"
TRANSFER_WAIT_MAX="${TRANSFER_WAIT_MAX:-600}"   # compile first run can take ~10min
REASON_WAIT_MAX="${REASON_WAIT_MAX:-180}"
export NGC_API_KEY="${NGC_API_KEY:-$(cat ~/.ngc/api_key 2>/dev/null || echo)}"

[[ -d "$SIM_DS" ]] || { echo "ERROR: $SIM_DS not found" >&2; exit 1; }
[[ -x "$NIM" ]] || { echo "ERROR: $NIM not executable" >&2; exit 1; }
[[ -n "$NGC_API_KEY" ]] || { echo "ERROR: NGC_API_KEY not set" >&2; exit 1; }

COSMOS_OUT="${SIM_DS}.cosmos"
SCORES_OUT="$COSMOS_OUT/cosmos_reason_scores.json"

echo "=== 1/5 TRANSFER: run container ==="
"$NIM" run-transfer

echo "=== 2/5 TRANSFER: wait for /v1/health/ready (up to ${TRANSFER_WAIT_MAX}s) ==="
START=$(date +%s)
until curl -sf http://localhost:8000/v1/health/ready >/dev/null 2>&1; do
  sleep 10
  NOW=$(date +%s); DELTA=$((NOW-START))
  [[ $DELTA -gt $TRANSFER_WAIT_MAX ]] && { echo "TIMEOUT at ${DELTA}s" >&2; "$NIM" stop-transfer; exit 2; }
  echo "waited ${DELTA}s..."
done
echo "transfer ready after $(($(date +%s)-START))s"

echo "=== 3/5 run cosmos_transfer_wrapper.py ==="
cd "$WRAPPERS_DIR"
LIMIT_ARG="${LIMIT:+$LIMIT}"
python3 cosmos_transfer_wrapper.py "$SIM_DS" "$COSMOS_OUT" $LIMIT_ARG 2>&1 | tail -40
echo "transfer wrapper done. Outputs in $COSMOS_OUT"

echo "=== 4a/5 TRANSFER: stop container to free VRAM ==="
"$NIM" stop-transfer
# allow a moment for VRAM release
sleep 5

echo "=== 4b/5 REASON: run container ==="
"$NIM" run-reason

echo "=== 4c/5 REASON: wait for /v1/health/ready (up to ${REASON_WAIT_MAX}s) ==="
START=$(date +%s)
until curl -sf http://localhost:8001/v1/health/ready >/dev/null 2>&1; do
  sleep 10
  NOW=$(date +%s); DELTA=$((NOW-START))
  [[ $DELTA -gt $REASON_WAIT_MAX ]] && { echo "TIMEOUT at ${DELTA}s" >&2; "$NIM" stop-reason; exit 2; }
  echo "waited ${DELTA}s..."
done
echo "reason ready after $(($(date +%s)-START))s"

echo "=== 5/5 run cosmos_reason_curator.py on Cosmos output ==="
python3 cosmos_reason_curator.py "$COSMOS_OUT" "$SCORES_OUT" 2>&1 | tail -20

echo "=== REASON: stop container ==="
"$NIM" stop-reason

echo ""
echo "=== PIPELINE DONE ==="
echo "cosmos out:  $COSMOS_OUT"
echo "scores:      $SCORES_OUT"
if [[ -f "$SCORES_OUT" ]]; then
  python3 -c "
import json
d = json.load(open('$SCORES_OUT'))
print(f'scored:  {d[\"scored_count\"]}')
print(f'kept:    {d[\"kept_count\"]}')
print(f'dropped: {d[\"dropped_count\"]}')
print(f'stated:  {d[\"stated_curation_decision\"]}')
"
fi
