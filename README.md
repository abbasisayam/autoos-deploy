# autoos-deploy

A lightweight, polling-based deploy pipeline for a static website (Ron's Automotive).
A small watcher runs on an EC2 instance, notices new commits on `main`, and syncs the
changed files to S3 behind CloudFront.

## How it works

```
                    ┌─ deploy-watch.sh  (polls origin every 10s)        ─┐
push to main  ──▶   │                                                     ├─▶  deploy.sh
                    └─ webhook-server.py (GitHub push webhook, instant)  ─┘        │
                                                                                   ▼
                          git pull  ──▶  aws s3 cp/rm changed files  ──▶  CloudFront invalidation
```

The deploy logic lives in **`deploy.sh`**, a single worker shared by both triggers. When the
remote moves ahead of the local checkout it fast-forwards, then deploys **only the files that
changed in the new commits**:

- added/modified files are uploaded with an appropriate `Content-Type`
- deleted files are removed from the bucket
- a CloudFront invalidation is issued for **just those paths** (not `/*`)

Each step's exit code is checked and logged; a failed pull or upload skips the rest of that
cycle instead of firing a billable invalidation on a half-finished deploy. An `flock`
serialises overlapping runs, so the poller and webhook can safely run at the same time.

You pick how `deploy.sh` is triggered:

- **`webhook-server.py`** — receives GitHub `push` webhooks (HMAC-SHA256 verified) and deploys
  within a second or two of a push. No constant polling. Recommended.
- **`deploy-watch.sh`** — runs `deploy.sh` on a timer every `POLL_INTERVAL` seconds. Simple and
  dependency-free; a good fallback or for hosts that can't receive inbound webhooks.

## Configuration

All settings are environment variables with defaults baked in for the current setup:

| Variable          | Default                      | Purpose                          |
| ----------------- | ---------------------------- | -------------------------------- |
| `DEPLOY_DIR`      | `/home/ec2-user/autoos-deploy` | Repo working tree to watch     |
| `DEPLOY_BRANCH`   | `main`                       | Branch to track                  |
| `S3_BUCKET`       | `rons-automotive-website`    | Target S3 bucket                 |
| `CF_DISTRIBUTION` | `EV5Z7DZBRS6S6`              | CloudFront distribution id       |
| `POLL_INTERVAL`   | `10`                         | Seconds between checks (poller)  |

The webhook server (`webhook-server.py`) adds:

| Variable          | Default          | Purpose                                          |
| ----------------- | ---------------- | ------------------------------------------------ |
| `WEBHOOK_SECRET`  | _(required)_     | Shared secret matching the GitHub webhook        |
| `WEBHOOK_HOST`    | `127.0.0.1`      | Bind address (keep local, front with a proxy)    |
| `WEBHOOK_PORT`    | `8080`           | Bind port                                        |
| `WEBHOOK_PATH`    | `/webhook`       | URL path GitHub posts to                         |

## Requirements

- `git`, `bash` (4+, for `mapfile`), and the AWS CLI v2 on the host
- Python 3 (standard library only) if using the webhook server
- AWS credentials with `s3:PutObject`, `s3:DeleteObject`, and
  `cloudfront:CreateInvalidation` permissions (an instance role is recommended)

## Running — webhook (recommended)

1. Pick a strong secret and export it (store it somewhere safe, e.g. SSM Parameter Store):

   ```bash
   export WEBHOOK_SECRET='…a long random string…'
   ./webhook-server.py
   ```

2. In GitHub: **Settings → Webhooks → Add webhook**
   - Payload URL: `https://<your-host>/webhook`
   - Content type: `application/json`
   - Secret: the same `WEBHOOK_SECRET`
   - Events: **Just the push event**

3. Terminate TLS with a reverse proxy (nginx/Caddy) in front of `127.0.0.1:8080`. GitHub
   needs to reach the proxy on 443; the Python server itself stays bound to localhost.

systemd unit:

```ini
# /etc/systemd/system/autoos-webhook.service
[Unit]
Description=autoos deploy webhook server
After=network-online.target

[Service]
ExecStart=/home/ec2-user/autoos-deploy/webhook-server.py
Environment=WEBHOOK_SECRET=…a long random string…
Restart=always
User=ec2-user

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now autoos-webhook
journalctl -u autoos-webhook -f
```

## Running — polling (fallback)

```bash
./deploy-watch.sh
```

```ini
# /etc/systemd/system/autoos-deploy.service
[Unit]
Description=autoos static site deploy watcher
After=network-online.target

[Service]
ExecStart=/home/ec2-user/autoos-deploy/deploy-watch.sh
Restart=always
User=ec2-user

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl enable --now autoos-deploy
journalctl -u autoos-deploy -f   # follow the deploy log
```

You can run both at once if you like — `deploy.sh` locks, so they won't collide.

## Notes

- `deploy.sh` can also be run by hand for a one-off deploy: `./deploy.sh`.
- `test-deploy.html` is a placeholder used to verify the pipeline end to end.
