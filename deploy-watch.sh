#!/usr/bin/env bash
#
# deploy-watch.sh — watch `main` for new commits and deploy the static site to S3/CloudFront.
#
# Behaviour: poll the remote, and when it moves ahead of the local checkout, pull and sync
# only the files that actually changed (upload modified/added, remove deleted), then issue a
# CloudFront invalidation scoped to just those paths. Failures are logged and the loop keeps
# running rather than firing a (billable) invalidation on a half-finished deploy.
#
# Config via environment variables (defaults shown):
#   DEPLOY_DIR        repo working tree to watch   (/home/ec2-user/autoos-deploy)
#   DEPLOY_BRANCH     branch to track              (main)
#   S3_BUCKET         target bucket name           (rons-automotive-website)
#   CF_DISTRIBUTION   CloudFront distribution id   (EV5Z7DZBRS6S6)
#   POLL_INTERVAL     seconds between checks        (10)

set -uo pipefail

DEPLOY_DIR="${DEPLOY_DIR:-/home/ec2-user/autoos-deploy}"
DEPLOY_BRANCH="${DEPLOY_BRANCH:-main}"
S3_BUCKET="${S3_BUCKET:-rons-automotive-website}"
CF_DISTRIBUTION="${CF_DISTRIBUTION:-EV5Z7DZBRS6S6}"
POLL_INTERVAL="${POLL_INTERVAL:-10}"

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

cd "$DEPLOY_DIR" || { log "FATAL: cannot cd into $DEPLOY_DIR"; exit 1; }

log "Watching $DEPLOY_BRANCH in $DEPLOY_DIR -> s3://$S3_BUCKET (CF $CF_DISTRIBUTION), every ${POLL_INTERVAL}s"

while true; do
  if ! git fetch origin "$DEPLOY_BRANCH" --quiet 2>/dev/null; then
    log "WARN: git fetch failed, will retry"
    sleep "$POLL_INTERVAL"
    continue
  fi

  LOCAL=$(git rev-parse HEAD 2>/dev/null)
  REMOTE=$(git rev-parse "origin/$DEPLOY_BRANCH" 2>/dev/null)

  if [ -z "$REMOTE" ] || [ "$LOCAL" = "$REMOTE" ]; then
    sleep "$POLL_INTERVAL"
    continue
  fi

  log "Change detected: $LOCAL -> $REMOTE"

  OLD="$LOCAL"
  if ! git pull --ff-only origin "$DEPLOY_BRANCH"; then
    log "ERROR: git pull failed (non-fast-forward or conflict), skipping deploy"
    sleep "$POLL_INTERVAL"
    continue
  fi
  NEW=$(git rev-parse HEAD 2>/dev/null)

  # Files added or modified between the old and new commit.
  mapfile -t CHANGED < <(git diff --name-only --diff-filter=d "$OLD" "$NEW")
  # Files deleted between the old and new commit.
  mapfile -t DELETED < <(git diff --name-only --diff-filter=D "$OLD" "$NEW")

  if [ "${#CHANGED[@]}" -eq 0 ] && [ "${#DELETED[@]}" -eq 0 ]; then
    log "No file changes to deploy"
    sleep "$POLL_INTERVAL"
    continue
  fi

  declare -a INVALIDATE=()
  DEPLOY_OK=1

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

  [ "$DEPLOY_OK" -eq 1 ] && log "Deploy complete" || log "Deploy finished with errors"

  sleep "$POLL_INTERVAL"
done
