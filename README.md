# autoos-deploy

A lightweight, polling-based deploy pipeline for a static website (Ron's Automotive).
A small watcher runs on an EC2 instance, notices new commits on `main`, and syncs the
changed files to S3 behind CloudFront.

## How it works

```
push to main  ──▶  EC2 runs deploy-watch.sh  ──▶  git pull  ──▶  aws s3 cp/rm changed files  ──▶  CloudFront invalidation
                     (polls every 10s)
```

`deploy-watch.sh` polls `origin/main`. When the remote moves ahead of the local checkout it
fast-forwards, then deploys **only the files that changed in the new commits**:

- added/modified files are uploaded with an appropriate `Content-Type`
- deleted files are removed from the bucket
- a CloudFront invalidation is issued for **just those paths** (not `/*`)

Each step's exit code is checked and logged; a failed pull or upload skips the rest of that
cycle instead of firing a billable invalidation on a half-finished deploy.

## Configuration

All settings are environment variables with defaults baked in for the current setup:

| Variable          | Default                      | Purpose                          |
| ----------------- | ---------------------------- | -------------------------------- |
| `DEPLOY_DIR`      | `/home/ec2-user/autoos-deploy` | Repo working tree to watch     |
| `DEPLOY_BRANCH`   | `main`                       | Branch to track                  |
| `S3_BUCKET`       | `rons-automotive-website`    | Target S3 bucket                 |
| `CF_DISTRIBUTION` | `EV5Z7DZBRS6S6`              | CloudFront distribution id       |
| `POLL_INTERVAL`   | `10`                         | Seconds between checks           |

## Requirements

- `git`, `bash` (4+, for `mapfile`), and the AWS CLI v2 on the host
- AWS credentials with `s3:PutObject`, `s3:DeleteObject`, and
  `cloudfront:CreateInvalidation` permissions (an instance role is recommended)

## Running

```bash
./deploy-watch.sh
```

For production, run it under a process supervisor so it restarts on reboot or crash —
for example a systemd unit:

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

## Notes

- Polling every 10s is simple and dependency-free. If you want near-instant deploys without
  the constant polling, replace the loop with a GitHub webhook or a `git` post-receive hook.
- `test-deploy.html` is a placeholder used to verify the pipeline end to end.
