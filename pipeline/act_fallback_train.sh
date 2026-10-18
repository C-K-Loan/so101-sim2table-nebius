#!/bin/bash
# ACT fallback training path, via huggingface/lerobot (no HF gating).
# Use when GR00T N1.7-3B access is blocked or we need a faster/smaller training iteration.
#
# vs GR00T N1.7-3B: ACT is ~35-50M params (ResNet18 + ~15M transformer + ~5M VAE).
#   - About 60-85x smaller than GR00T 3B
#   - Public weights, no gated HF access needed
#   - Trains ~5-10x faster per step (smaller model + CPU-friendly if needed)
#   - Trades generality (no language-conditioned foundation prior) for speed
#   - Still SOTA-ish for single-task imitation on bimanual arms (Zhao et al. 2023)
#
# Dataset shape expected: LeRobot v2.1 format at $DATASET_ROOT with
#   - meta/info.json  (codebase_version=v2.1, fps, video_keys)
#   - data/chunk-000/episode_XXXXXX.parquet  (per-frame state + action)
#   - videos/chunk-000/observation.images.<cam>/episode_XXXXXX.mp4
# Our pipeline writes exactly this (so101_pickplace.lerobot_writer.LeRobotV21Writer).
#
# DO NOT RUN YET. This is the fallback - switch on only if GR00T path is blocked.

set -euo pipefail

LEROBOT_DIR="${LEROBOT_DIR:-~/nebius-arm-robot/lerobot}"
DATASET_ROOT="${DATASET_ROOT:-$HOME/Desktop/nvidia/datasets/local/so101_sim_pickplace}"
OUTPUT_DIR="${OUTPUT_DIR:-~/nebius-arm-robot/checkpoints/act}"

# Match SO-101 pipeline shape:
#   - 2 cameras: observation.images.front, observation.images.wrist
#   - 5 arm joints + 1 gripper = 6-dim state and action
#   - GR00T config uses ACTION_HORIZON=16, we match it as the ACT chunk size
#     (smaller than ACT default 100, better fit for our 30 Hz 20s episodes)
CHUNK_SIZE="${CHUNK_SIZE:-16}"
N_ACTION_STEPS="${N_ACTION_STEPS:-16}"
BATCH_SIZE="${BATCH_SIZE:-8}"
STEPS="${STEPS:-20000}"
SAVE_FREQ="${SAVE_FREQ:-5000}"
EVAL_FREQ="${EVAL_FREQ:-5000}"
SEED="${SEED:-1000}"

cd "$LEROBOT_DIR"

if [[ ! -d .venv ]]; then
  echo "ERROR: no .venv in $LEROBOT_DIR. Run first:" >&2
  echo "  python3.11 -m venv .venv && source .venv/bin/activate" >&2
  echo "  pip install -e ." >&2
  exit 1
fi
source .venv/bin/activate

if [[ ! -d "$DATASET_ROOT" ]]; then
  echo "ERROR: dataset not found at $DATASET_ROOT" >&2
  echo "Run starter/collect.sh first (or point DATASET_ROOT env to an existing LeRobot v2.1 dir)." >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

echo "=== ACT training (fallback) ==="
echo "dataset: $DATASET_ROOT"
echo "output:  $OUTPUT_DIR"
echo "chunk:   $CHUNK_SIZE, steps: $STEPS, batch: $BATCH_SIZE"
echo ""

# LeRobot v2.1 lives on disk as a path (no HF repo_id needed).
# `lerobot-train` auto-detects features from meta/info.json.
lerobot-train \
  --dataset.repo_id="$DATASET_ROOT" \
  --dataset.root="$DATASET_ROOT" \
  --policy.type=act \
  --policy.chunk_size="$CHUNK_SIZE" \
  --policy.n_action_steps="$N_ACTION_STEPS" \
  --policy.vision_backbone=resnet18 \
  --policy.pretrained_backbone_weights=ResNet18_Weights.IMAGENET1K_V1 \
  --output_dir="$OUTPUT_DIR" \
  --batch_size="$BATCH_SIZE" \
  --steps="$STEPS" \
  --save_freq="$SAVE_FREQ" \
  --eval_freq="$EVAL_FREQ" \
  --seed="$SEED" \
  --device=cuda \
  2>&1 | tee "$OUTPUT_DIR/train.log"

echo ""
echo "=== DONE ==="
echo "Latest checkpoint: $OUTPUT_DIR/last/pretrained_model/"
echo ""
echo "To serve for eval:"
echo "  lerobot-policy-server --policy.path=$OUTPUT_DIR/last/pretrained_model --host=0.0.0.0 --port=5555"
echo ""
echo "To eval against sim or real arm, use the starter's eval harness or lerobot-eval."
