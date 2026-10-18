#!/usr/bin/env bash
# SO-101 one-shot helper for Mac. lerobot[feetech] in ~/lerobot-venv.
# Usage:
#   bash ~/so101_run.sh calibrate <leader_port> <follower_port>
#   bash ~/so101_run.sh check
#   bash ~/so101_run.sh teleop
#   bash ~/so101_run.sh record [N]
#   bash ~/so101_run.sh replay [episode_idx]
#   bash ~/so101_run.sh smoketest     # record 1 ep + replay it
#   bash ~/so101_run.sh env | help

export PATH="$HOME/lerobot-venv/bin:$PATH"
export HF_HUB_OFFLINE=1
export HF_DATASETS_OFFLINE=1
export VIRTUAL_ENV="$HOME/lerobot-venv"
WORKSHOP="$HOME/Sim-to-Real-SO-101-Workshop"
cd "$WORKSHOP" 2>/dev/null || { echo "ERR: $WORKSHOP missing"; exit 1; }

CAL_DIR="$HOME/.cache/huggingface/lerobot/calibration/robots"
if [ -d "$CAL_DIR/so_follower" ] && [ ! -e "$CAL_DIR/so101_follower" ]; then
  ln -s so_follower "$CAL_DIR/so101_follower" 2>/dev/null
fi

CAM_INDEX="${CAM_INDEX:-1}"
CAM_WIDTH="${CAM_WIDTH:-640}"
CAM_HEIGHT="${CAM_HEIGHT:-480}"
CAM_FPS="${CAM_FPS:-30}"
CAM_DICT="{top: {type: opencv, index_or_path: $CAM_INDEX, width: $CAM_WIDTH, height: $CAM_HEIGHT, fps: $CAM_FPS}}"
CAM_FLAGS=(--robot.cameras="$CAM_DICT")
if [ "$NO_CAM" = "1" ]; then CAM_FLAGS=(); fi

clear_motor_faults() {
  python3 ~/nebius-arm-robot/clear_faults.py "$@"
}

CMD="${1:-help}"

case "$CMD" in
  calibrate)
    LEADER="${2:?leader port required}"
    FOLLOWER="${3:?follower port required}"
    export TELEOP_PORT="$LEADER" ROBOT_PORT="$FOLLOWER"
    export TELEOP_ID=orange_teleop ROBOT_ID=orange_robot
    cat > ~/.so101_env <<ENV
export TELEOP_PORT=$LEADER
export ROBOT_PORT=$FOLLOWER
export TELEOP_ID=orange_teleop
export ROBOT_ID=orange_robot
ENV
    echo "LEADER=$LEADER  FOLLOWER=$FOLLOWER (saved to ~/.so101_env)"
    echo "=== CALIBRATE LEADER (teleop) ==="
    lerobot-calibrate --teleop.type=so101_leader --teleop.port="$LEADER" --teleop.id="$TELEOP_ID"
    echo "=== CALIBRATE FOLLOWER (robot) ==="
    lerobot-calibrate --robot.type=so101_follower --robot.port="$FOLLOWER" --robot.id="$ROBOT_ID"
    [ -d "$CAL_DIR/so_follower" ] && [ ! -e "$CAL_DIR/so101_follower" ] && ln -s so_follower "$CAL_DIR/so101_follower" 2>/dev/null
    echo "=== CHECK ==="
    python docker/real/scripts/so101_check_calibration.py || true
    echo "=== NEXT: bash ~/so101_run.sh smoketest  (record 1 ep + replay) ==="
    ;;
  check)
    [ -f ~/.so101_env ] || { echo "run calibrate first"; exit 1; }
    source ~/.so101_env
    python docker/real/scripts/so101_check_calibration.py
    ;;
  teleop)
    [ -f ~/.so101_env ] || { echo "run calibrate first"; exit 1; }
    source ~/.so101_env
    echo "Live teleop: LEADER=$TELEOP_PORT FOLLOWER=$ROBOT_PORT. Ctrl+C to stop."
    lerobot-teleoperate \
      --robot.type=so101_follower --robot.port="$ROBOT_PORT" --robot.id="$ROBOT_ID" --robot.max_relative_target=30 \
      --teleop.type=so101_leader --teleop.port="$TELEOP_PORT" --teleop.id="$TELEOP_ID"
    ;;
  record)
    N="${2:-15}"
    DATASET="${DATASET_NAME:-local/so101_realteleop}"
    [ -f ~/.so101_env ] || { echo "run calibrate first"; exit 1; }
    source ~/.so101_env
    echo "Clearing motor faults on both arms..."
    : # clear_motor_faults DISABLED: it wrote 0 to servo reg 19 (protection bitmask)
    echo "Recording $N episodes to ~/.cache/huggingface/lerobot/$DATASET/"
    echo "Controls: Enter=next, s=stop ep, r=re-record last, Esc=quit"
    DS_DIR=~/.cache/huggingface/lerobot/$DATASET
    if ls "$DS_DIR"/data/chunk-000/episode_*.parquet >/dev/null 2>&1 && [ -f "$DS_DIR/meta/info.json" ]; then
      RESUME_FLAG="--resume=true"; echo "Dataset has $(ls "$DS_DIR"/data/chunk-000/episode_*.parquet | wc -l | tr -d ' ') episode(s) -> appending"
    else
      if [ -d "$DS_DIR" ]; then
        mv "$DS_DIR" "$DS_DIR.partial-$(date +%H%M%S)"; echo "Moved partial/empty dataset aside"
      fi
      RESUME_FLAG=""; echo "Creating fresh dataset"
    fi
    lerobot-record \
      --robot.type=so101_follower --robot.port="$ROBOT_PORT" --robot.id="$ROBOT_ID" --robot.max_relative_target=30 \
      "${CAM_FLAGS[@]}" \
      --teleop.type=so101_leader --teleop.port="$TELEOP_PORT" --teleop.id="$TELEOP_ID" \
      --dataset.repo_id="$DATASET" \
      --dataset.num_episodes="$N" \
      --dataset.single_task="pick up the red block and place it on the green pad" \
      --dataset.push_to_hub=false --play_sounds=false \
      $RESUME_FLAG
    ;;
  replay)
    EP="${2:-0}"
    DATASET="${DATASET_NAME:-local/so101_realteleop}"
    [ -f ~/.so101_env ] || { echo "run calibrate first"; exit 1; }
    source ~/.so101_env
    echo "Replaying episode $EP from $DATASET on follower."
    lerobot-replay \
      --robot.type=so101_follower --robot.port="$ROBOT_PORT" --robot.id="$ROBOT_ID" --robot.max_relative_target=30 \
      --dataset.repo_id="$DATASET" \
      --dataset.episode="$EP"
    ;;
  smoketest)
    [ -f ~/.so101_env ] || { echo "run calibrate first"; exit 1; }
    source ~/.so101_env
    echo "Clearing motor faults on both arms..."
    : # clear_motor_faults DISABLED: it wrote 0 to servo reg 19 (protection bitmask)
    DATASET=local/so101_smoketest
    # nuke prior smoketest so this is a clean 1-ep record
    rm -rf ~/.cache/huggingface/lerobot/$DATASET
    echo "============================================"
    echo "SMOKETEST: record 1 episode, then replay it"
    echo "============================================"
    echo ""
    echo "STEP 1/2 — Record 1 pick-and-place episode."
    echo "  Press Enter to start, do the task on leader arm."
    echo "  Press  s  when done (or let it auto-stop)."
    echo ""
    DATASET_NAME=$DATASET lerobot-record \
      --robot.type=so101_follower --robot.port="$ROBOT_PORT" --robot.id="$ROBOT_ID" --robot.max_relative_target=30 \
      "${CAM_FLAGS[@]}" \
      --teleop.type=so101_leader --teleop.port="$TELEOP_PORT" --teleop.id="$TELEOP_ID" \
      --dataset.repo_id=$DATASET \
      --dataset.num_episodes=1 \
      --dataset.single_task="smoketest: pick up red cube, place on pad" \
      --dataset.push_to_hub=false --play_sounds=false
    echo ""
    echo "============================================"
    echo "STEP 2/2 — Replay the recorded episode on follower."
    echo "  Hands off! Follower will move autonomously."
    echo "  Watch: did it do what you did?"
    echo "  Press Enter to start replay..."
    echo "============================================"
    read -r _
    lerobot-replay \
      --robot.type=so101_follower --robot.port="$ROBOT_PORT" --robot.id="$ROBOT_ID" --robot.max_relative_target=30 \
      --dataset.repo_id=$DATASET \
      --dataset.episode=0
    echo ""
    echo "============================================"
    echo "SMOKETEST DONE."
    echo "If replay looked like your recording, system works ✓"
    echo "Next: bash ~/so101_run.sh record 15"
    echo "============================================"
    ;;
  recal-leader|recal-l)
    [ -f ~/.so101_env ] || { echo "run calibrate first"; exit 1; }
    source ~/.so101_env
    echo "Re-calibrating LEADER only. Sweep EVERY joint through FULL range (incl. gripper open+close)."
    lerobot-calibrate --teleop.type=so101_leader --teleop.port=$TELEOP_PORT --teleop.id=$TELEOP_ID
    ;;
  recal-follower|recal-f)
    [ -f ~/.so101_env ] || { echo "run calibrate first"; exit 1; }
    source ~/.so101_env
    echo "Re-calibrating FOLLOWER only. Sweep EVERY joint through FULL range (incl. gripper open+close)."
    lerobot-calibrate --robot.type=so101_follower --robot.port=$ROBOT_PORT --robot.id=$ROBOT_ID
    ;;
  findcam)
    echo "Testing cameras. macOS will prompt for Terminal camera permission on first try."
    lerobot-find-cameras opencv
    ;;
  camsnap)
    SNAP_DIR="$HOME/nebius-arm-robot/viz"
    mkdir -p "$SNAP_DIR"
    echo "Snapping cameras. macOS may prompt for Terminal camera permission. Allow it."
    for IDX in 0 1; do
      OUT="$SNAP_DIR/cam${IDX}.jpg"
      echo "  index $IDX -> $OUT"
      ffmpeg -y -hide_banner -loglevel error -f avfoundation -framerate 15 -video_size 1280x720 -i "$IDX" -frames:v 1 "$OUT" 2>&1 | tail -5
    done
    cat > "$SNAP_DIR/cams.html" <<HTML
<!doctype html>
<html><head><title>Cam snaps</title><style>body{background:#0b0d10;color:#c8d1d9;font-family:ui-monospace,monospace;padding:16px}img{max-width:48%;border:1px solid #30363d;border-radius:8px;margin:4px}h2{color:#58a6ff;font-size:14px}</style></head>
<body><h1>SO-101 Camera Snaps</h1>
<p>Refresh page after re-running <code>bash ~/so101_run.sh camsnap</code>.</p>
<h2>Index 0 (FaceTime HD, built-in)</h2><img src="cam0.jpg?t=$(date +%s)">
<h2>Index 1 (IW-2000-1, USB — the one we want)</h2><img src="cam1.jpg?t=$(date +%s)">
</body></html>
HTML
    echo
    echo "Snaps saved:"
    ls -la "$SNAP_DIR"/cam*.jpg 2>&1 | tail -3
    echo
    echo "Open: file://$SNAP_DIR/cams.html"
    # Push to cupcake dashboard
    rsync -azq -e "ssh -o BatchMode=yes" "$SNAP_DIR/cam0.jpg" "$SNAP_DIR/cam1.jpg" "$SNAP_DIR/cams.html" cupcake:~/nebius-arm-robot/viz/ 2>&1 | tail -3
    echo "Dashboard: http://<dashboard-host>:8777/viz/cams.html"
    ;;
  ui)
    echo "Launching record UI backend (holds BOTH arm ports while running; do NOT run native record at the same time)."
    pkill -f record_backend.py 2>/dev/null; sleep 1
    cd ~/nebius-arm-robot && (nohup ~/lerobot-venv/bin/python record_backend.py </dev/null >/tmp/record_backend.log 2>&1 &)
    sleep 2
    echo "Open: http://localhost:8778/record-ui.html"
    echo "Stop later: bash ~/so101_run.sh ui-stop"
    ;;
  ui-stop)
    pkill -f record_backend.py && echo "backend stopped, arm ports free" || echo "backend was not running"
    ;;
  recal)
    source ~/.so101_env
    echo "Re-calibrating BOTH arms: LEADER=$TELEOP_PORT FOLLOWER=$ROBOT_PORT"
    echo "Pose BOTH arms identically before each middle prompt. Type c at the prompts. Sweep every joint fully."
    exec bash ~/so101_run.sh calibrate "$TELEOP_PORT" "$ROBOT_PORT"
    ;;
  gapwatch)
    source ~/.so101_env
    echo "Move the LEADER by hand until every gap is < 150 and it says READY. Ctrl+C to stop."
    while true; do
      clear; date +%H:%M:%S
      ~/lerobot-venv/bin/python ~/nebius-arm-robot/gapcheck.py "$TELEOP_PORT" "$ROBOT_PORT"
      sleep 1
    done
    ;;
  gapcheck)
    source ~/.so101_env
    ~/lerobot-venv/bin/python ~/nebius-arm-robot/gapcheck.py "$TELEOP_PORT" "$ROBOT_PORT"
    ;;
  test)
    source ~/.so101_env
    export HF_HUB_OFFLINE=1 PYTHONUNBUFFERED=1
    rm -rf ~/.cache/huggingface/lerobot/local/so101_selftest
    echo "6-second lerobot self-test (no camera). Hands off the arms."
    printf "\n\n\n" | timeout 60 lerobot-record --robot.type=so101_follower --robot.port="$ROBOT_PORT" --robot.id="$ROBOT_ID" --robot.max_relative_target=30 --teleop.type=so101_leader --teleop.port="$TELEOP_PORT" --teleop.id="$TELEOP_ID" --dataset.repo_id=local/so101_selftest --dataset.num_episodes=1 --dataset.episode_time_s=6 --dataset.reset_time_s=1 --dataset.single_task=t --dataset.push_to_hub=false --play_sounds=false 2>&1 | grep -iE "^(RuntimeError|ConnectionError)|Recording episode|Missing motor|Overload|Overheat|no status" | tail -5
    if ls ~/.cache/huggingface/lerobot/local/so101_selftest/data/chunk-000/*.parquet >/dev/null 2>&1; then echo "RESULT: PASS - episode saved. Run: bash ~/so101_run.sh record 10"; else echo "RESULT: FAIL - see lines above (gapcheck first, power-cycle follower if flagged)"; fi
    rm -rf ~/.cache/huggingface/lerobot/local/so101_selftest
    ;;
  env|status)
    echo "WORKSHOP: $WORKSHOP"
    echo "VENV:     $VIRTUAL_ENV"
    echo "SAVED-ENV:"
    cat ~/.so101_env 2>/dev/null || echo "  (none, run calibrate)"
    echo "ARMS:"
    ls /dev/tty.usbmodem* 2>&1
    echo "DATASETS:"
    ls ~/.cache/huggingface/lerobot/local/ 2>&1 | head -5
    ;;
  help|*)
    cat <<HELP
SO-101 helper. Commands:
  calibrate <leader_port> <follower_port>   Calibrate both arms
  smoketest                                 Record 1 ep + replay it (sanity check)
  recal-leader                              Re-calibrate leader only (no args)
  recal-follower                            Re-calibrate follower only (no args)
  findcam                                   List cameras (allow Terminal access on first run)
  camsnap                                   Snap frames from cams, serve HTML viewer
  check                                     Verify calibration
  teleop                                    Live mirror test (no save)
  record [N]                                Record N teleop episodes (default 15)
  replay [episode_idx]                      Replay recorded episode on follower
  ui | ui-stop                              Browser record UI (fallback; frees ports on stop)
  recal                                     Re-calibrate BOTH arms using saved ports (no args)
  gapwatch                                  Live gap display while you pose the leader (Ctrl+C)
  gapcheck                                  Read-only: arm pose gap + flags (READY/NOT READY)
  test                                      6s lerobot self-test, no camera (PASS/FAIL)
  env | status                              Show state

Arms on this Mac:
HELP
    ls /dev/tty.usbmodem* 2>&1
    ;;
esac
