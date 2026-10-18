#!/usr/bin/env bash
# Poll the VM + local state, write status.json / events.jsonl / artifacts.json for the dashboard.
# Run as a loop: watch -n 15 ./update_status.sh  OR cron it.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_IP="81.85.0.144"
VM_USER="ubuntu"
SSH_KEY="$HOME/.ssh/id_ed25519_nebius_hack"
VM_SSH="ssh -i $SSH_KEY -o BatchMode=yes -o ConnectTimeout=4 $VM_USER@$VM_IP"

STATUS="$HERE/status.json"
EVENTS="$HERE/events.jsonl"
ART="$HERE/artifacts.json"

touch "$EVENTS"

# ---------- Collect counts from VM ----------
EP_COUNT=0
COSMOS_COUNT=0
REAL_COUNT=0
TRAIN_STEP=0
VM_UP="pending"
ISAAC_READY="pending"
GROOT="pending"
NIM_T="pending"
NIM_R="pending"

if timeout 5 $VM_SSH 'echo alive' >/dev/null 2>&1; then
  VM_UP="done"
  # Isaac Sim installed?
  if timeout 5 $VM_SSH "test -d ~/work/env_isaaclab && echo yes" 2>/dev/null | grep -q yes; then
    ISAAC_READY="done"
  fi
  # GR00T weights?
  if timeout 5 $VM_SSH "test -f ~/work/IsaacLab/Isaac-GR00T/checkpoints/GR00T-N1.7-3B/config.json && echo yes" 2>/dev/null | grep -q yes; then
    GROOT="done"
  fi
  # Cosmos NIM images?
  nim_out=$(timeout 5 $VM_SSH "docker image ls --format '{{.Repository}}:{{.Tag}}'" 2>/dev/null || true)
  echo "$nim_out" | grep -q "cosmos-transfer2.5-2b" && NIM_T="done"
  echo "$nim_out" | grep -q "cosmos-reason2-2b" && NIM_R="done"
  # Sim episode count
  EP_COUNT=$(timeout 5 $VM_SSH "find ~/datasets/local/so101_sim_pickplace/videos -name 'episode_*.mp4' 2>/dev/null | wc -l" 2>/dev/null | tr -d '[:space:]')
  COSMOS_COUNT=$(timeout 5 $VM_SSH "find ~/datasets/local/so101_sim_pickplace.cosmos/videos -name 'episode_*.mp4' 2>/dev/null | wc -l" 2>/dev/null | tr -d '[:space:]')
  REAL_COUNT=$(timeout 5 $VM_SSH "find ~/datasets/local/so101_sim_pickplace.real/videos -name 'episode_*.mp4' 2>/dev/null | wc -l" 2>/dev/null | tr -d '[:space:]')
  # Train step (last SAVED checkpoint number)
  TRAIN_STEP=$(timeout 5 $VM_SSH "ls -1 ~/finetune/so101_sim_pickplace/ 2>/dev/null | grep -oP 'checkpoint-\K[0-9]+' | sort -n | tail -1" 2>/dev/null | tr -d '[:space:]')
fi
EP_COUNT=${EP_COUNT:-0}
COSMOS_COUNT=${COSMOS_COUNT:-0}
REAL_COUNT=${REAL_COUNT:-0}
TRAIN_STEP=${TRAIN_STEP:-0}

# NIM pulled derived state
NIM_STATE="pending"
if [ "$NIM_T" = "done" ] && [ "$NIM_R" = "done" ]; then NIM_STATE="done"
elif [ "$NIM_T" = "done" ] || [ "$NIM_R" = "done" ]; then NIM_STATE="running"
fi

# Sim collect state
SIM_STATE="pending"
if [ "${EP_COUNT:-0}" -gt 0 ]; then
  if [ "${EP_COUNT:-0}" -ge 50 ]; then SIM_STATE="done"
  else SIM_STATE="running"
  fi
fi

# Projected score
PTS=0
BREAK=()
[ "$VM_UP" = "done" ] && PTS=$((PTS+5)) && BREAK+=("\"Nebius partial\":{\"points\":5,\"note\":\"VM live\"}")
[ "$TRAIN_STEP" -gt 0 ] && PTS=$((PTS+20-5)) && BREAK+=("\"Nebius full\":{\"points\":20,\"note\":\"trained on Nebius\"}")
[ "$NIM_T" = "done" ] && PTS=$((PTS+10)) && BREAK+=("\"Cosmos Transfer\":{\"points\":10,\"note\":\"used in pipeline\"}")
[ "$NIM_R" = "done" ] && PTS=$((PTS+10)) && BREAK+=("\"Cosmos Reason\":{\"points\":10,\"note\":\"used in curation\"}")
# Creativity: ensemble ready
PTS=$((PTS+15)) && BREAK+=("\"Creativity\":{\"points\":15,\"note\":\"ACT+GR00T ensemble planned\"}")
# Tech: real deploy
if [ "$REAL_COUNT" -gt 0 ]; then PTS=$((PTS+15)) && BREAK+=("\"Tech\":{\"points\":15,\"note\":\"real teleop recorded\"}"); fi

# ---------- Write status.json ----------
cat > "$STATUS" <<EOF
{
  "vm_up": {"state": "$VM_UP"},
  "isaac_installed": {"state": "$ISAAC_READY"},
  "groot_weights": {"state": "$GROOT"},
  "nim_pulled": {"state": "$NIM_STATE"},
  "sim_collect": {"state": "$SIM_STATE", "count": $EP_COUNT},
  "cosmos_transfer": {"state": "$([ $COSMOS_COUNT -gt 0 ] && echo done || echo pending)", "count": $COSMOS_COUNT},
  "cosmos_reason": {"state": "$([ $COSMOS_COUNT -gt 0 ] && echo done || echo pending)"},
  "teleop_recorded": {"state": "$([ $REAL_COUNT -gt 0 ] && echo done || echo pending)", "count": $REAL_COUNT},
  "dataset_prepared": {"state": "pending"},
  "training": {"state": "$([ $TRAIN_STEP -gt 0 ] && echo running || echo pending)", "count": $TRAIN_STEP},
  "ablation": {"state": "pending"},
  "eval_sim": {"state": "pending"},
  "deploy_real": {"state": "pending"},
  "judge_trials": {"state": "pending"},
  "submission": {"state": "pending"},
  "_projected_score": {"total": $PTS, "breakdown": {$(IFS=,; echo "${BREAK[*]}")}}
}
EOF

# ---------- Write artifacts.json ----------
cat > "$ART" <<EOF
[
  {"name": "MASTER.md", "href": "../MASTER.md"},
  {"name": "00-STACK-EXPLAINED.md", "href": "../00-STACK-EXPLAINED.md"},
  {"name": "dataset_manifest_template.json", "href": "../dataset_manifest_template.json"},
  {"name": "demo_video_shot_list.md", "href": "../demo_video_shot_list.md"},
  {"name": "SUBMISSION_README_TEMPLATE.md", "href": "../SUBMISSION_README_TEMPLATE.md"},
  {"name": "Dummy dataset viz", "href": "../viz/index.html"},
  {"name": "cosmos_transfer_wrapper.py", "href": "../cosmos_transfer_wrapper.py"},
  {"name": "cosmos_reason_curator.py", "href": "../cosmos_reason_curator.py"},
  {"name": "cosmos_nim_setup.sh", "href": "../cosmos_nim_setup.sh"},
  {"name": "cosmos_run_pipeline.sh", "href": "../cosmos_run_pipeline.sh"},
  {"name": "merge_real_teleop.sh", "href": "../merge_real_teleop.sh"},
  {"name": "submission_upload.sh", "href": "../submission_upload.sh"},
  {"name": "act_fallback_train.sh", "href": "../act_fallback_train.sh"},
  {"name": "ACT_FALLBACK_NOTES.md", "href": "../ACT_FALLBACK_NOTES.md"}
]
EOF
