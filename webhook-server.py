#!/usr/bin/env python3
"""
webhook-server.py — receive GitHub push webhooks and trigger a deploy.

Listens for GitHub `push` events, verifies the HMAC-SHA256 signature against a shared secret,
and on a push to the tracked branch runs deploy.sh (the same worker the poller uses). This
gives near-instant deploys without polling.

Configuration (environment variables):
  WEBHOOK_SECRET    shared secret configured on the GitHub webhook (REQUIRED)
  WEBHOOK_HOST      bind address                                   (127.0.0.1)
  WEBHOOK_PORT      bind port                                      (8080)
  WEBHOOK_PATH      URL path GitHub posts to                       (/webhook)
  DEPLOY_BRANCH     branch to deploy on push                       (main)
  DEPLOY_SCRIPT     path to deploy.sh                              (alongside this file)

GitHub webhook settings: Payload URL -> http(s)://<host>/webhook, Content type ->
application/json, Secret -> same as WEBHOOK_SECRET, events -> "Just the push event".

Run it behind a TLS-terminating reverse proxy (nginx/Caddy) and keep WEBHOOK_HOST on
127.0.0.1 so the raw HTTP port is never exposed directly.
"""

import hashlib
import hmac
import json
import os
import subprocess
import sys
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))

SECRET = os.environ.get("WEBHOOK_SECRET", "").encode()
HOST = os.environ.get("WEBHOOK_HOST", "127.0.0.1")
PORT = int(os.environ.get("WEBHOOK_PORT", "8080"))
PATH = os.environ.get("WEBHOOK_PATH", "/webhook")
BRANCH = os.environ.get("DEPLOY_BRANCH", "main")
DEPLOY_SCRIPT = os.environ.get("DEPLOY_SCRIPT", os.path.join(HERE, "deploy.sh"))

MAX_BODY = 5 * 1024 * 1024  # reject absurdly large payloads


def log(msg):
    print(f"[{datetime.now():%Y-%m-%d %H:%M:%S}] {msg}", flush=True)


def valid_signature(body, header):
    """Constant-time check of GitHub's X-Hub-Signature-256 header."""
    if not header or not header.startswith("sha256="):
        return False
    expected = "sha256=" + hmac.new(SECRET, body, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, header)


def run_deploy():
    log("Push received, running deploy.sh")
    try:
        result = subprocess.run(
            [DEPLOY_SCRIPT],
            capture_output=True,
            text=True,
            timeout=600,
        )
    except Exception as exc:  # noqa: BLE001 - log and move on, server stays up
        log(f"ERROR: deploy failed to run: {exc}")
        return
    for line in result.stdout.splitlines():
        log(f"  {line}")
    if result.returncode != 0:
        log(f"ERROR: deploy exited {result.returncode}")
        for line in result.stderr.splitlines():
            log(f"  err: {line}")


class Handler(BaseHTTPRequestHandler):
    def _reply(self, code, message):
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.end_headers()
        self.wfile.write(message.encode())

    def do_POST(self):
        if self.path != PATH:
            self._reply(404, "not found")
            return

        length = int(self.headers.get("Content-Length", 0))
        if length <= 0 or length > MAX_BODY:
            self._reply(400, "bad content length")
            return

        body = self.rfile.read(length)

        if not valid_signature(body, self.headers.get("X-Hub-Signature-256", "")):
            log("Rejected request with invalid signature")
            self._reply(401, "invalid signature")
            return

        event = self.headers.get("X-GitHub-Event", "")
        if event == "ping":
            self._reply(200, "pong")
            return
        if event != "push":
            self._reply(202, f"ignored event: {event}")
            return

        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            self._reply(400, "invalid json")
            return

        ref = payload.get("ref", "")
        if ref != f"refs/heads/{BRANCH}":
            self._reply(202, f"ignored ref: {ref}")
            return

        # Acknowledge immediately, then deploy. GitHub only cares that we 200 quickly.
        self._reply(200, "deploying")
        run_deploy()

    def log_message(self, *args):  # silence default per-request stderr logging
        pass


def main():
    if not SECRET:
        log("FATAL: WEBHOOK_SECRET is not set")
        sys.exit(1)
    server = ThreadingHTTPServer((HOST, PORT), Handler)
    log(f"Listening on http://{HOST}:{PORT}{PATH} for push events on {BRANCH}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        log("Shutting down")
        server.shutdown()


if __name__ == "__main__":
    main()
