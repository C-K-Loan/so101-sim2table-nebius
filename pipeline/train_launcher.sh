#!/bin/bash
# Final finetune launcher.
# - Checks for real teleop at ~/datasets/local/so101_sim_pickplace.real/
# - If present: merges into base (sim+cosmos+curation drops) via merge_real_teleop.sh
# - Launches finetune.sh with MAX_STEPS=1500 as planned
#
# Usage:
#   ./train_launcher.sh main     # main checkpoint (sim+cosmos+real if present, curated)
#   ./train_launcher.sh ablation # ablation (sim+real only, no cosmos)

set -euo pipefail

MODE="${1:-main}"
STARTER=/home/ubuntu/work/IsaacLab/so101_sim_pickplace
SIM_DS=/home/ubuntu/datasets/local/so101_sim_pickplace
COSMOS_DS=/home/ubuntu/datasets/local/so101_sim_pickplace.cosmos
REAL_DS=/home/ubuntu/datasets/local/so101_sim_pickplace.real
MERGED_DS=/home/ubuntu/datasets/local/so101_sim_pickplace.merged
ABLATION_DS=/home/ubuntu/datasets/local/so101_sim_pickplace.ablation

export MAX_STEPS="${MAX_STEPS:-1500}"
export GLOBAL_BATCH_SIZE="${GLOBAL_BATCH_SIZE:-16}"
export SAVE_STEPS="${SAVE_STEPS:-500}"

echo "=== $MODE train launcher $(date) ==="

# Patch env.sh gr00t_activate to drop DGX-Spark-only lines (Nebius has no activate_spark.sh / nvpl)
if grep -q "source scripts/activate_spark.sh" "$STARTER/env.sh"; then
  echo "patching env.sh: remove DGX-Spark-only activate_spark + nvpl lines"
  sed -i 's|^\(.*source scripts/activate_spark.sh.*\)$|# \1  # removed for Nebius|' "$STARTER/env.sh"
  sed -i 's|^\(.*export LD_LIBRARY_PATH="\$VIRTUAL_ENV/lib/python3.12/site-packages/nvpl/lib.*\)$|# \1  # removed for Nebius|' "$STARTER/env.sh"
fi

if [[ "$MODE" == "main" ]]; then
  # Decide training dataset: merged if real teleop landed, else sim+cosmos drop-curated
  if [[ -d "$REAL_DS" ]] && [[ "$(find "$REAL_DS" -type f -name 'episode_*.mp4' 2>/dev/null | wc -l)" -gt 0 ]]; then
    echo "real teleop found at $REAL_DS — merging into $COSMOS_DS → $MERGED_DS"
    SCORES="$COSMOS_DS/cosmos_reason_scores.json"
    [[ -f "$SCORES" ]] || SCORES=""
    # merge_real_teleop.sh writes to .merged
    bash /home/ubuntu/merge_real_teleop.sh "$REAL_DS" "$COSMOS_DS" "$SCORES" 2>&1 | tail -20
    export TRAIN_DATASET="$MERGED_DS"
  else
    echo "no real teleop found — training on sim+cosmos (no merge)"
    export TRAIN_DATASET="$COSMOS_DS"
    # Make sure prepare_dataset ran on this (modality.json + stats.json required)
    cd "$STARTER" && source ./env.sh
    DATASET_ROOT="$COSMOS_DS" ./prepare_dataset.sh 2>&1 | tail -10 || echo "prepare failed, continuing"
  fi
  OUTDIR=/home/ubuntu/finetune/so101_main
elif [[ "$MODE" == "ablation" ]]; then
  # Ablation: sim-only (optionally + real), no cosmos
  if [[ -d "$REAL_DS" ]] && [[ "$(find "$REAL_DS" -type f -name 'episode_*.mp4' 2>/dev/null | wc -l)" -gt 0 ]]; then
    # cp sim → ablation, merge real
    rm -rf "$ABLATION_DS"; cp -r "$SIM_DS" "$ABLATION_DS"
    bash /home/ubuntu/merge_real_teleop.sh "$REAL_DS" "$ABLATION_DS" "" 2>&1 | tail -10
    export TRAIN_DATASET="${ABLATION_DS}.merged"
  else
    export TRAIN_DATASET="$SIM_DS"
  fi
  OUTDIR=/home/ubuntu/finetune/so101_ablation
else
  echo "ERROR: unknown mode '$MODE' (use: main | ablation)" >&2
  exit 1
fi

echo "---train config---"
echo "  mode:          $MODE"
echo "  TRAIN_DATASET: $TRAIN_DATASET"
echo "  OUTDIR:        $OUTDIR"
echo "  MAX_STEPS:     $MAX_STEPS"
echo "  BATCH:         $GLOBAL_BATCH_SIZE"

mkdir -p "$OUTDIR"
cd "$STARTER"
source ./env.sh
export FINETUNE_OUTPUT="$OUTDIR"
TRAIN_DATASET="$TRAIN_DATASET" MAX_STEPS="$MAX_STEPS" GLOBAL_BATCH_SIZE="$GLOBAL_BATCH_SIZE" SAVE_STEPS="$SAVE_STEPS" ./finetune.sh 2>&1 | tee -a "$OUTDIR/launcher.log"
echo "=== $MODE DONE at $(date) ==="
