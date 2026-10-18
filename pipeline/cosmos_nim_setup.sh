#!/bin/bash
# Cosmos NIM container prep + lifecycle for the Nebius VM.
# Addendum to setup_vm.sh.
#
# Day-master gate: DO NOT docker-pull without explicit ack (containers are ~tens of GB each).
#
# Usage on the VM:
#   NGC_API_KEY=<your-ngc-key> ./cosmos_nim_setup.sh login       # auth to nvcr.io
#   NGC_API_KEY=<your-ngc-key> ./cosmos_nim_setup.sh pull        # pull both NIM images (slow)
#   ./cosmos_nim_setup.sh run-transfer                       # run Cosmos Transfer 2.5 on :8000
#   ./cosmos_nim_setup.sh stop-transfer                      # kill it (free VRAM for Reason)
#   ./cosmos_nim_setup.sh run-reason                         # run Cosmos Reason 2 on :8001
#   ./cosmos_nim_setup.sh stop-reason                        # kill it
#   ./cosmos_nim_setup.sh status                             # which container is up
#
# Sequential run rule: Transfer (65.4 GB) and Reason (24 GB) EACH fit in 96 GB RTX PRO 6000,
# but running both at once risks tight scheduling. Day-master says SEQUENTIAL.

set -euo pipefail

TRANSFER_IMAGE="nvcr.io/nim/nvidia/cosmos-transfer2.5-2b:1.2.0"
REASON_IMAGE="nvcr.io/nim/nvidia/cosmos-reason2-2b:1.7.0"
TRANSFER_NAME="cosmos-transfer"
REASON_NAME="cosmos-reason"
TRANSFER_PORT="${TRANSFER_PORT:-8000}"
REASON_PORT="${REASON_PORT:-8001}"
NIM_CACHE="${NIM_CACHE:-$HOME/.cache/nim}"

cmd="${1:-help}"

preflight() {
  command -v docker >/dev/null || { echo "docker missing" >&2; exit 1; }
  command -v nvidia-container-runtime >/dev/null || \
    [[ -x /usr/bin/nvidia-container-runtime ]] || \
    { echo "nvidia-container-runtime missing (check: dpkg -s nvidia-container-toolkit)" >&2; exit 1; }
  mkdir -p "$NIM_CACHE"
}

case "$cmd" in
  login)
    preflight
    [[ -n "${NGC_API_KEY:-}" ]] || { echo "set NGC_API_KEY (NGC personal key)" >&2; exit 1; }
    echo "$NGC_API_KEY" | docker login nvcr.io -u '$oauthtoken' --password-stdin
    echo "login OK"
    ;;

  pull)
    preflight
    [[ -n "${NGC_API_KEY:-}" ]] || { echo "set NGC_API_KEY first (run: $0 login)" >&2; exit 1; }
    echo "=== pulling $TRANSFER_IMAGE (slow, several GB) ==="
    docker pull "$TRANSFER_IMAGE" &
    T_PID=$!
    echo "=== pulling $REASON_IMAGE in parallel ==="
    docker pull "$REASON_IMAGE" &
    R_PID=$!
    wait $T_PID && echo "transfer pulled" || echo "TRANSFER PULL FAILED"
    wait $R_PID && echo "reason pulled" || echo "REASON PULL FAILED"
    docker images | grep cosmos
    ;;

  run-transfer)
    preflight
    [[ -n "${NGC_API_KEY:-}" ]] || { echo "set NGC_API_KEY (container needs it to download model weights)" >&2; exit 1; }
    docker rm -f "$TRANSFER_NAME" 2>/dev/null || true
    docker run -d --name "$TRANSFER_NAME" \
      --gpus all \
      --shm-size=16g \
      -v "$NIM_CACHE:/opt/nim/.cache" \
      -p "$TRANSFER_PORT:8000" \
      -e NIM_HTTP_API_PORT=8000 \
      -e NGC_API_KEY="$NGC_API_KEY" \
      "$TRANSFER_IMAGE"
    echo "Transfer launched on :$TRANSFER_PORT. First call compiles (several minutes)."
    echo "  curl http://localhost:$TRANSFER_PORT/v1/health 2>/dev/null"
    echo "  docker logs -f $TRANSFER_NAME"
    ;;

  stop-transfer)
    docker stop "$TRANSFER_NAME" 2>/dev/null && docker rm "$TRANSFER_NAME" 2>/dev/null && echo "stopped" || echo "not running"
    ;;

  run-reason)
    preflight
    [[ -n "${NGC_API_KEY:-}" ]] || { echo "set NGC_API_KEY (container needs it to download model weights)" >&2; exit 1; }
    docker rm -f "$REASON_NAME" 2>/dev/null || true
    docker run -d --name "$REASON_NAME" \
      --gpus all \
      --shm-size=16g \
      -v "$NIM_CACHE:/opt/nim/.cache" \
      -p "$REASON_PORT:8000" \
      -e NIM_HTTP_API_PORT=8000 \
      -e NGC_API_KEY="$NGC_API_KEY" \
      "$REASON_IMAGE"
    echo "Reason launched on :$REASON_PORT (OpenAI-compat at /v1)."
    echo "  curl http://localhost:$REASON_PORT/v1/models 2>/dev/null"
    echo "  docker logs -f $REASON_NAME"
    ;;

  stop-reason)
    docker stop "$REASON_NAME" 2>/dev/null && docker rm "$REASON_NAME" 2>/dev/null && echo "stopped" || echo "not running"
    ;;

  status)
    docker ps --filter name="$TRANSFER_NAME" --filter name="$REASON_NAME" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
    echo ""
    echo "GPU use:"
    nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null || true
    ;;

  wait-transfer-ready)
    echo "polling http://localhost:$TRANSFER_PORT/v1/health (compile first run can take several minutes)..."
    for i in $(seq 1 60); do
      if curl -sf "http://localhost:$TRANSFER_PORT/v1/health" >/dev/null 2>&1; then
        echo "ready after ${i}0s"; exit 0
      fi
      sleep 10
    done
    echo "TIMEOUT after 10min"; exit 2
    ;;

  wait-reason-ready)
    echo "polling http://localhost:$REASON_PORT/v1/models..."
    for i in $(seq 1 60); do
      if curl -sf "http://localhost:$REASON_PORT/v1/models" >/dev/null 2>&1; then
        echo "ready after ${i}0s"; exit 0
      fi
      sleep 10
    done
    echo "TIMEOUT after 10min"; exit 2
    ;;

  help|*)
    echo "usage: $0 {login|pull|run-transfer|stop-transfer|run-reason|stop-reason|status|wait-transfer-ready|wait-reason-ready}"
    echo ""
    echo "Images:"
    echo "  Transfer: $TRANSFER_IMAGE  (65.4 GB VRAM, port $TRANSFER_PORT)"
    echo "  Reason:   $REASON_IMAGE  (24 GB VRAM, port $REASON_PORT)"
    echo ""
    echo "Sequential-run rule: stop one before starting the other."
    exit 0
    ;;
esac
