#!/usr/bin/env bash
#
# deploy.sh — perform a single deploy pass.
#
# Fetches the tracked branch, and if the remote is ahead of the local checkout, fast-forwards
# and syncs only the files that changed in the new commits (upload added/modified, remove
# deleted) to S3, then issues a CloudFront invalidation scoped to just those paths.
#
# This is the shared worker used by both deploy-watch.sh (polling) and webhook-server.py
# (push-triggered). It is safe to invoke concurrently: an flock serialises overlapping runs,
# and because every run pulls to the newest origin HEAD, a queued run always deploys the
# latest state.
#
# Exit codes: 0 = success or nothing to do, non-zero = a step failed.
#
# Config via environment variables (defaults shown):
#   DEPLOY_DIR        repo working tree to deploy   (/home/ec2-user/autoos-deploy)
#   DEPLOY_BRANCH     branch to track               (main)
#   S3_BUCKET         target bucket name            (rons-automotive-website)
#   CF_DISTRIBUTION   CloudFront distribution id    (EV5Z7DZBRS6S6)

set -uo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-/home/ec2-user/autoos-deploy}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"
S3_BUCKET="${S3_BUCKET:-rons-automotive-website}"
CF_DISTRIBUTION="${CF_DISTRIBUTION:-EV5Z7DZBRS6S6}"
LOCK_FILE="${LOCK_FILE:-/tmp/autoos-deploy.lock}"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }

# Map a file path to a Content-Type. Returns empty for unknown extensions so the
# caller can let S3 fall back to its own guess.
content_type_for() {
  case "${1##*.}" in
    html|htm) echo "text/html" ;;
    css)      echo "text/css" ;;
    js|mjs)   echo "application/javascript" ;;
    json)     echo "application/json" ;;
    svg)      echo "image/svg+xml" ;;
    png)      echo "image/png" ;;
    jpg|jpeg) echo "image/jpeg" ;;
    gif)      echo "image/gif" ;;
    webp)     echo "image/webp" ;;
    ico)      echo "image/x-icon" ;;
    woff)     echo "font/woff" ;;
    woff2)    echo "font/woff2" ;;
    txt)      echo "text/plain" ;;
    xml)      echo "application/xml" ;;
    pdf)      echo "application/pdf" ;;
    *)        echo "" ;;
  esac
}

deploy() {
  cd "$DEPLOY_DIR" || { log "FATAL: cannot cd into $DEPLOY_DIR"; return 1; }

  if ! git fetch origin "$DEPLOY_BRANCH" --quiet 2>/dev/null; then
    log "WARN: git fetch failed"
    return 1
  fi

  local LOCAL REMOTE OLD NEW
  LOCAL=$(git rev-parse HEAD 2>/dev/null)
  REMOTE=$(git rev-parse "origin/$DEPLOY_BRANCH" 2>/dev/null)

  if [ -z "$REMOTE" ] || [ "$LOCAL" = "$REMOTE" ]; then
    return 0
  fi

  log "Change detected: $LOCAL -> $REMOTE"

  OLD="$LOCAL"
  if ! git pull --ff-only origin "$DEPLOY_BRANCH"; then
    log "ERROR: git pull failed (non-fast-forward or conflict), skipping deploy"
    return 1
  fi
  NEW=$(git rev-parse HEAD 2>/dev/null)

  # Files added or modified between the old and new commit.
  local CHANGED DELETED
  mapfile -t CHANGED < <(git diff --name-only --diff-filter=d "$OLD" "$NEW")
  # Files deleted between the old and new commit.
  mapfile -t DELETED < <(git diff --name-only --diff-filter=D "$OLD" "$NEW")

  if [ "${#CHANGED[@]}" -eq 0 ] && [ "${#DELETED[@]}" -eq 0 ]; then
    log "No file changes to deploy"
    return 0
  fi

  local -a INVALIDATE=()
  local DEPLOY_OK=1 FILE CT ARGS

  for FILE in "${CHANGED[@]}"; do
    [ -f "$FILE" ] || continue
    CT=$(content_type_for "$FILE")
    if [ -n "$CT" ]; then
      ARGS=(--content-type "$CT")
    else
      ARGS=()
    fi
    if aws s3 cp "$FILE" "s3://$S3_BUCKET/$FILE" "${ARGS[@]}"; then
      log "DEPLOYED: $FILE"
      INVALIDATE+=("/$FILE")
    else
      log "ERROR: failed to upload $FILE"
      DEPLOY_OK=0
    fi
  done

  for FILE in "${DELETED[@]}"; do
    if aws s3 rm "s3://$S3_BUCKET/$FILE"; then
      log "REMOVED: $FILE"
      INVALIDATE+=("/$FILE")
    else
      log "ERROR: failed to remove $FILE"
      DEPLOY_OK=0
    fi
  done

  if [ "${#INVALIDATE[@]}" -gt 0 ]; then
    if aws cloudfront create-invalidation \
        --distribution-id "$CF_DISTRIBUTION" \
        --paths "${INVALIDATE[@]}" >/dev/null; then
      log "INVALIDATED: ${INVALIDATE[*]}"
    else
      log "ERROR: CloudFront invalidation failed"
      DEPLOY_OK=0
    fi
  fi

  if [ "$DEPLOY_OK" -eq 1 ]; then
    log "Deploy complete"
    return 0
  fi
  log "Deploy finished with errors"
  return 1
}

# Serialise concurrent deploys (poller + webhook, or rapid pushes). The blocking flock
# means a second trigger queues and then deploys the latest origin state.
exec 9>"$LOCK_FILE" || { log "FATAL: cannot open lock file $LOCK_FILE"; exit 1; }
flock 9
deploy
exit $?
