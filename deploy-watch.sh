#!/usr/bin/env bash
#
# deploy-watch.sh — poll `main` and deploy on change (fallback to the webhook server).
#
# This is the simple, dependency-free path: every POLL_INTERVAL seconds it runs deploy.sh,
# which fetches the tracked branch and deploys only if the remote has moved ahead. For
# near-instant deploys without constant polling, run webhook-server.py instead (or alongside
# this — deploy.sh serialises the two with a lock).
#
# Config: same environment variables as deploy.sh, plus:
#   POLL_INTERVAL     seconds between checks         (10)

set -uo pipefail

POLL_INTERVAL="${POLL_INTERVAL:-10}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "[$(date '+%Y-%m-%d %H:%M:%S')] Polling every ${POLL_INTERVAL}s via $SCRIPT_DIR/deploy.sh"

while true; do
  "$SCRIPT_DIR/deploy.sh"
  sleep "$POLL_INTERVAL"
done
