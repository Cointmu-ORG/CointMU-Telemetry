# CointMU Telemetry

Error collector for the CointMU desktop app ([CointMU-App#57](https://github.com/Cointmu-ORG/CointMU-App/issues/57)):
[GlitchTip](https://glitchtip.com) (Sentry-protocol compatible) behind an nginx TLS proxy,
reachable only from the campus LAN. The app talks plain Sentry protocol, so this server
can be swapped for any Sentry-compatible backend by changing the DSN and pin in the app build.

The same VM also collects the logs of the geth node **servers** (bootnode, miner) in
[Loki](https://grafana.com/oss/loki/), with a [Grafana](https://grafana.com/oss/grafana/)
dashboard for admins. Agents on the nodes ([agents/alloy/](agents/alloy/README.md)) push over the
same HTTPS port with their own logins; the desktop app never uses that path.

```
CointMU app ──HTTPS (pinned key)──▶ nginx :443 ──▶ GlitchTip ──▶ PostgreSQL
  campus LAN only (firewall + bind)   rate limit     IP + PII scrub

geth node ─Alloy, HTTPS + login──▶ nginx /loki/api/v1/push ──▶ Loki ◀── Grafana ◀── nginx /grafana/
  IPs/node IDs redacted, WAL       agent allowlist, rate limit    internal network     admin allowlist
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
A VM with **2 vCPU, 4 GB RAM and 50 GB disk** is plenty for this stack including the log
stack (next section).

### Log stack sizing

Measured on the bootnode server (two geth processes at the default INFO level): about
**7–12 MB of log per day**. Loki stores roughly a tenth of that after compression.

| | RAM (limit) | Disk |
|---|---|---|
| Loki | 60–300 MB used (768 MB) | under 0.5 GB for 5 such servers × 30 days, plus compaction headroom |
| Grafana | about 240 MB used (512 MB) | under 100 MB (SQLite) |
| Alloy on each node | 50–100 MB | WAL: at most a day of that node's logs |

The container memory limits add up to about 2.9 GB (GlitchTip stack 1.6 GB, log stack 1.3 GB),
hence 4 GB. Loki shares the disk with PostgreSQL and has no size-based retention: the ingest limits
in `loki/config.yml` stop a runaway agent, the disk-full section of the runbook covers the rest.

## What this repo sets up

| Piece | Choice |
|---|---|
| Images (pinned by digest) | `postgres:18.6-alpine`, `glitchtip/glitchtip:6.2.6` (all-in-one, no Valkey), `nginxinc/nginx-unprivileged:1.31.7-alpine`, `grafana/loki:3.7.8`, `grafana/grafana:13.2.4`, each as `tag@sha256:…`; Dependabot proposes new tags and digests weekly for every image in `compose.yml` (the Alloy agents on the nodes are apt packages, upgraded by hand); CI (`.github/workflows/ci.yml`) tests every PR: `docker compose config`, `nginx -t` in the pinned image, shellcheck, `alloy fmt`, `check-redaction.sh` against a real Loki, and a clean Grafana start |
| Exposure | Only nginx is published, on `BIND_IP:HTTPS_PORT`; Postgres sits on an internal network with no route out, Loki and Grafana on another one. Event ingest and `/_health/` are open to the campus LAN; the GlitchTip dashboard and API and Grafana (`/grafana/`) only to the addresses in `nginx/local/admin-allow.conf`; the log push (`/loki/api/v1/push`) only to `nginx/local/agent-allow.conf` plus a per-agent login. The rest of Loki's API is not proxied |
| Node logs | Loki single binary, filesystem storage, retention `LOKI_RETENTION_PERIOD` (30 days) by the compactor, ingest limits. Agents redact IP addresses and node IDs before sending (`agents/alloy/`) |
| TLS | Self-signed (or internal-CA) certificate; the app pins the **public key** (SPKI SHA-256). `server.key` is `640` with a dedicated host group (`TLS_GID`) that only the proxy joins, all other keys `600` |
| Rate limit | nginx: 5 req/s per client with burst 20 on the ingest endpoints (429 above), 1 MB body cap. GlitchTip 6.2.6 stores per-key rate limits but does not enforce them at ingest, so nginx is the limit |
| IP addresses | nginx clears `X-Forwarded-For`/`X-Real-IP`, its access log has no client IP or query string, and IP scrubbing is on for the org and project (GlitchTip ignores private, non-routable IPs anyway) |
| PII | Server-side scrubber on for every project (`GLITCHTIP_PII_SCRUB_DEFAULT`), as a second layer behind the app's allowlist + sanitizer |
| Retention | `GLITCHTIP_RETENTION_DAYS` (default 60) |
| Accounts | GlitchTip: registration and organization creation closed; Django admin, OpenAPI, logs, uptime and MCP off. Grafana: one admin (password from `.env`), sign-up, anonymous access and API basic auth off, no outbound calls |
| Logs | `json-file` driver rotated at 10 MB × 3 files per container |
| Hardening | `cap_drop: ALL` (Postgres gets back only what its entrypoint needs), `no-new-privileges`, read-only root filesystems for nginx, Loki and Grafana, memory and PID limits, health checks on every service except Loki (distroless image, see RUNBOOK.md) |

## Deploy

On the VM (Docker Engine with the Compose plugin):

```bash
git clone https://github.com/Cointmu-ORG/CointMU-Telemetry.git && cd CointMU-Telemetry

# 1. Configuration
cp .env.example .env && chmod 600 .env
# set BIND_IP and GLITCHTIP_HOST to the VM's campus IP, then:
sed -i "s/^SECRET_KEY=.*/SECRET_KEY=$(openssl rand -hex 32)/" .env
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 24)/" .env
sed -i "s|^GRAFANA_ADMIN_PASSWORD=.*|GRAFANA_ADMIN_PASSWORD=$(openssl rand -base64 24)|" .env

# 2. Host group for the TLS key. The proxy joins it (group_add), nobody else does.
#    groupadd --system picks a free GID; check it is not taken, and not 101 (syslog):
sudo groupadd --system cointmu-tls
TLS_GID=$(getent group cointmu-tls | cut -d: -f3) && getent group "$TLS_GID"
sed -i "s/^TLS_GID=.*/TLS_GID=$TLS_GID/" .env

#    TLS key + certificate (SAN must match GLITCHTIP_HOST); prints the pin.
#    Run as yourself, not root: it asks for sudo once to hand the key to that group.
scripts/gen-cert.sh new IP:10.0.0.10

# 3. Per-host nginx files in nginx/local/ (the proxy refuses to start without all three)
cp nginx/local/admin-allow.conf.example nginx/local/admin-allow.conf
# add one "allow <address or subnet>;" line per admin machine or subnet
cp nginx/local/agent-allow.conf.example nginx/local/agent-allow.conf
# add one "<address or subnet> 1;" line per geth node server (campus or tailnet IP)
sudo install -m 640 -o "$USER" -g "$TLS_GID" /dev/null nginx/local/loki-agents.htpasswd
# agent logins are added later with scripts/agent-cred.sh (agents/alloy/README.md)

# 4. Firewall (see below), then start
docker compose up -d
docker compose ps          # all "healthy" except loki (no healthcheck, see RUNBOOK.md)

# 5. Admin account and the CointMU project; prints the DSN
docker compose exec web ./manage.py createsuperuser
scripts/init-project.sh admin@example.com
```

Back up `.env`, `nginx/local/` and `certs/` somewhere safe and private. They are git-ignored and the
server cannot be rebuilt with the same pin without `certs/server.key`.

Grafana is at `https://<GLITCHTIP_HOST>/grafana/` (user `admin`, `GRAFANA_ADMIN_PASSWORD`), with the
"Geth node logs" dashboard. To ship a node's logs, follow [agents/alloy/README.md](agents/alloy/README.md).

## Connect the app

The app reads both values at **build time**. In the CointMU-App repository, set the
repository variables (Settings → Secrets and variables → Actions → Variables):

| Variable | Value |
|---|---|
| `TELEMETRY_DSN` | the `DSN=` line from `init-project.sh` |
| `TELEMETRY_PINS` | the pin from `gen-cert.sh`; during a key rotation, `current,next` |

Check the pin the live server presents: `scripts/print-pin.sh 10.0.0.10:443`.
Release builds made without these variables have reporting off.

## Firewall

Allow HTTPS only from the campus LAN (and allowed Tailscale addresses) and SSH only from the
admins' subnet. Docker's published ports bypass ufw's normal rules, so the HTTPS rule goes in the
`DOCKER-USER` chain (`firewall/ufw-after.rules.snippet`). The snippet has three placeholders,
`<CAMPUS_SUBNET>`, `<TAILSCALE_SUBNET>` and `<HTTPS_PORT>`; the port is taken from `.env` so the
rule guards the port that is actually published:

```bash
sudo ufw default deny incoming
sudo ufw allow from <ADMIN_SUBNET> to any port 22 proto tcp
CAMPUS_SUBNET='<CAMPUS_SUBNET>'   # the real campus LAN, e.g. 10.0.0.0/16
TAILSCALE_SUBNET=''               # tailnet IPs allowed in, comma-separated, e.g. 100.101.102.103/32; empty = none
HTTPS_PORT=$(sed -n 's/^HTTPS_PORT=//p' .env)
if [ -n "$TAILSCALE_SUBNET" ]; then TAILSCALE_RULE="s|<TAILSCALE_SUBNET>|$TAILSCALE_SUBNET|g"
else TAILSCALE_RULE='/<TAILSCALE_SUBNET>/d'; fi
sed -e "s|<CAMPUS_SUBNET>|$CAMPUS_SUBNET|g" -e "s|<HTTPS_PORT>|${HTTPS_PORT:-443}|g" -e "$TAILSCALE_RULE" \
  firewall/ufw-after.rules.snippet | sudo tee -a /etc/ufw/after.rules >/dev/null
sudo ufw enable && sudo ufw reload && sudo systemctl restart docker
```

**Tailscale.** Admins and node servers may come in over the Tailscale VPN (`100.64.0.0/10`).
Allow single tailnet addresses rather than the whole range, here and in `nginx/local/*.conf`.
The proxy listens only on `BIND_IP`, so tailnet clients must reach that campus address, through a
subnet router. A subnet router SNATs by default, so their requests arrive from the router's
campus address. Allow that address instead, or run the router with
`--snat-subnet-routes=false` so the `100.x` addresses arrive and the rules above apply.

If you change `HTTPS_PORT` later, change every `--ctorigdstport` value in
`/etc/ufw/after.rules` to match, or the new port is open to every network.

The proxy is also bound to `BIND_IP` only, so it never listens on other interfaces.
Verify from a machine outside the LAN that `HTTPS_PORT` times out, and from a campus
machine that is not in `admin-allow.conf` that the dashboard and `/grafana/` answer 403,
and from one not in `agent-allow.conf` that `POST /loki/api/v1/push` answers 403.

The admin allowlist sees the real client address only with rootful Docker (the default
iptables port publishing). Rootless Docker's default port driver hides it, so every
request would look like the same internal address.

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
restore, disk full, upgrades, "reports are not arriving", and for the log stack: adding a
node agent, rotating agent logins, retention, Grafana's admin password, and "logs are not arriving".
