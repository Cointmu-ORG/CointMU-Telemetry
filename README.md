# CointMU Telemetry

Error collector for the CointMU desktop app ([CointMU-App#57](https://github.com/Cointmu-ORG/CointMU-App/issues/57)):
[GlitchTip](https://glitchtip.com) (Sentry-protocol compatible) behind an nginx TLS proxy,
reachable only from the campus LAN. The app talks plain Sentry protocol, so this server
can be swapped for any Sentry-compatible backend by changing the DSN and pin in the app build.

```
CointMU app ──HTTPS (pinned key)──▶ nginx :443 ──▶ GlitchTip ──▶ PostgreSQL
  campus LAN only (firewall + bind)   rate limit     IP + PII scrub
```

## Why GlitchTip, not self-hosted Sentry

| | Self-hosted Sentry | GlitchTip |
|---|---|---|
| CPU | 4 cores minimum | x86 or arm64 |
| RAM | 16 GB + 16 GB swap minimum, 32 GB recommended | 512 MB recommended, 256 MB minimum (all-in-one) |
| Disk | 20 GB minimum, high IOPS | about 30 GB per 1M events/month |
| Services | many containers, Docker Compose ≥ 2.32.2 | PostgreSQL 14+ and one app container (Valkey optional) |

Sources: [develop.sentry.dev/self-hosted](https://develop.sentry.dev/self-hosted/),
[glitchtip.com/documentation/install](https://glitchtip.com/documentation/install).
A VM with **2 vCPU, 2–4 GB RAM and 40 GB disk** is plenty for this stack.

## What this repo sets up

| Piece | Choice |
|---|---|
| Images (pinned) | `postgres:18.6-alpine`, `glitchtip/glitchtip:6.2.6` (all-in-one, no Valkey), `nginxinc/nginx-unprivileged:1.31.7-alpine` |
| Exposure | Only nginx is published, on `BIND_IP:HTTPS_PORT`; Postgres sits on an internal network with no route out |
| TLS | Self-signed (or internal-CA) certificate; the app pins the **public key** (SPKI SHA-256) |
| Rate limit | nginx: 5 req/s per client with burst 20 on the ingest endpoints (429 above), 1 MB body cap. GlitchTip 6.2.6 stores per-key rate limits but does not enforce them at ingest, so nginx is the limit |
| IP addresses | nginx clears `X-Forwarded-For`/`X-Real-IP`, its access log has no client IP or query string, and IP scrubbing is on for the org and project (GlitchTip ignores private, non-routable IPs anyway) |
| PII | Server-side scrubber on for every project (`GLITCHTIP_PII_SCRUB_DEFAULT`), as a second layer behind the app's allowlist + sanitizer |
| Retention | `GLITCHTIP_RETENTION_DAYS` (default 60) |
| Accounts | Registration and organization creation closed; Django admin, OpenAPI, logs, uptime and MCP off |
| Hardening | `cap_drop: ALL` (Postgres gets back only what its entrypoint needs), `no-new-privileges`, read-only nginx, memory and PID limits, health checks on every service |

## Deploy

On the VM (Docker Engine with the Compose plugin):

```bash
git clone https://github.com/Cointmu-ORG/CointMU-Telemetry.git && cd CointMU-Telemetry

# 1. Configuration
cp .env.example .env && chmod 600 .env
# set BIND_IP and GLITCHTIP_HOST to the VM's campus IP, then:
sed -i "s/^SECRET_KEY=.*/SECRET_KEY=$(openssl rand -hex 32)/" .env
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 24)/" .env

# 2. TLS key + certificate (SAN must match GLITCHTIP_HOST); prints the pin
scripts/gen-cert.sh new IP:10.64.24.250

# 3. Firewall (see below), then start
docker compose up -d
docker compose ps          # all three services "healthy"

# 4. Admin account and the CointMU project; prints the DSN
docker compose exec web ./manage.py createsuperuser
scripts/init-project.sh admin@example.com
```

Back up `.env` and `certs/` somewhere safe and private. They are git-ignored and the
server cannot be rebuilt with the same pin without `certs/server.key`.

## Connect the app

The app reads both values at **build time**. In the CointMU-App repository, set the
repository variables (Settings → Secrets and variables → Actions → Variables):

| Variable | Value |
|---|---|
| `TELEMETRY_DSN` | the `DSN=` line from `init-project.sh` |
| `TELEMETRY_PINS` | the pin from `gen-cert.sh`; during a key rotation, `current,next` |

Check the pin the live server presents: `scripts/print-pin.sh 10.64.24.250:443`.
Release builds made without these variables have reporting off.

## Firewall

Allow HTTPS only from the campus LAN and SSH only from the admins' subnet. Docker's
published ports bypass ufw's normal rules, so the HTTPS rule goes in the `DOCKER-USER`
chain (`firewall/ufw-after.rules.snippet`):

```bash
sudo ufw default deny incoming
sudo ufw allow from <admin-subnet> to any port 22 proto tcp
# edit the subnet in the snippet, then append it to /etc/ufw/after.rules
sudo sh -c 'cat firewall/ufw-after.rules.snippet >> /etc/ufw/after.rules'
sudo ufw enable && sudo ufw reload && sudo systemctl restart docker
```

The proxy is also bound to `BIND_IP` only, so it never listens on other interfaces.
Verify from a machine outside the LAN that port 443 times out.

## Backups

`scripts/backup.sh` writes `backup/glitchtip-<UTC>.sql.gz` and keeps every dump from the
last 7 days plus Sunday dumps for 28 days. Schedule it and copy the folder off the VM:

```cron
15 2 * * * cd /opt/CointMU-Telemetry && scripts/backup.sh >> backup/backup.log 2>&1 && rsync -a --delete backup/ backup-host:/srv/cointmu-telemetry/
```

Restore with `scripts/restore.sh backup/<file>.sql.gz` (asks for confirmation, replaces
all current data). Test a restore after setting this up.

## Operations

See [RUNBOOK.md](RUNBOOK.md): key rotation and its release order, certificate renewal,
restore, disk full, upgrades, and "reports are not arriving".
