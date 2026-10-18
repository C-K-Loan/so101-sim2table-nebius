#!/usr/bin/env bash
# Append an event to events.jsonl for the dashboard dev diary.
#   ./log_event.sh <phase> <title> [body]
# phase examples: infra, collect, cosmos, train, teleop, submit, blocker
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PHASE="${1:-info}"
TITLE="${2:-event}"
BODY="${3:-}"
TS=$(date -u -Iseconds)
printf '{"ts":"%s","phase":"%s","title":%s,"body":%s}\n' \
  "$TS" "$PHASE" \
  "$(printf '%s' "$TITLE" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
  "$(printf '%s' "$BODY" | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read()))')" \
  >> "$HERE/events.jsonl"
