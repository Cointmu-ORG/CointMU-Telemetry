# CointMU Telemetry

Error collector for the CointMU desktop app ([CointMU-App#57](https://github.com/Cointmu-ORG/CointMU-App/issues/57)):
[GlitchTip](https://glitchtip.com) (Sentry-protocol compatible) behind an nginx TLS proxy,
reachable only from the campus LAN. The app talks plain Sentry protocol, so this server
can be swapped for any Sentry-compatible backend by changing the DSN and pin in the app build.

The same VM also collects the logs of the geth node **servers** (bootnode, miner) in
[Loki](https://grafana.com/oss/loki/), with a [Grafana](https://grafana.com/oss/grafana/)
dashboard for admins. Agents on the nodes ([agents/alloy/](agents/alloy/README.md)) push over the
same HTTPS port with their own logins; the desktop app never uses that path.

It also watches the **UPS** on one Proxmox host ("UPS monitoring" below): the host posts power
events to Discord itself, and ships the UPS daemon's journal to Loki and its metrics to
[Prometheus](https://prometheus.io/), with a Grafana dashboard and threshold alerts.

The geth node servers push **chain metrics** too ("Chain metrics" below): height, last-block age,
block time, difficulty, estimated hashrate, peers and sync state per node, with a Grafana dashboard
and alerts to #block-update.

```
CointMU app ──HTTPS (pinned key)──▶ nginx :443 ──▶ GlitchTip ──▶ PostgreSQL
  campus LAN only (firewall + bind)   rate limit     IP + PII scrub

geth node ─Alloy, HTTPS + login──▶ nginx /loki/api/v1/push ──▶ Loki ◀── Grafana ◀── nginx /grafana/
  IPs/node IDs redacted, WAL       agent allowlist, rate limit    internal network     admin allowlist
                                                                                    │
UPS host ─Alloy, HTTPS + login──▶ nginx /prometheus/api/v1/write ──▶ Prometheus ◀───┘   alerts → #ups, #block-update
geth node ─(same agent) chain metrics──▶ (same endpoint, own login)
  NUT journal (→ /loki) + metrics   agent allowlist, own logins     internal network
  └─ upssched → ups-notify.sh ──HTTPS──▶ Discord #ups   (straight from the host, VM not needed)
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
| Prometheus (host metrics) | about 100 MB used (384 MB) | the UPS writes about 0.3 MB a day; capped at `PROMETHEUS_RETENTION_SIZE` (2 GB) and `PROMETHEUS_RETENTION_TIME` (90 days), whichever comes first |

The container memory limits add up to about 3.3 GB (GlitchTip stack 1.6 GB, log and metrics stack
1.7 GB), within the 4 GB. Loki shares the disk with PostgreSQL and has no size-based retention: the
ingest limits in `loki/config.yml` stop a runaway agent, the disk-full section of the runbook covers
the rest. Prometheus has both a time and a size limit.

## What this repo sets up

| Piece | Choice |
|---|---|
| Images (pinned by digest) | `postgres:18.6-alpine`, `glitchtip/glitchtip:6.2.6` (all-in-one, no Valkey), `nginxinc/nginx-unprivileged:1.31.7-alpine`, `grafana/loki:3.7.8`, `prom/prometheus:v3.15.1`, `grafana/grafana:13.2.4`, each as `tag@sha256:…`; Dependabot proposes new tags and digests weekly for every image in `compose.yml` (the Alloy agents on the nodes are apt packages, upgraded by hand); CI (`.github/workflows/ci.yml`) tests every PR: `docker compose config`, `nginx -t` and `promtool check config` in the pinned images, shellcheck, `alloy fmt`, `check-redaction.sh` against a real Loki, a clean Grafana start, the UPS paths end to end (`agents/ups/check-notify.sh`, `check-ups.sh`) and the chain metrics end to end (`agents/chain/check-chain.sh`) |
| Exposure | Only nginx is published, on `BIND_IP:HTTPS_PORT`; Postgres sits on an internal network with no route out, Loki, Prometheus and Grafana on another one; Grafana's only route out is `alerts-egress`, for the Discord webhook. Event ingest and `/_health/` are open to the campus LAN; the GlitchTip dashboard and API and Grafana (`/grafana/`) only to the addresses in `nginx/local/admin-allow.conf`; the log push (`/loki/api/v1/push`) and the metrics push (`/prometheus/api/v1/write`) only to `nginx/local/agent-allow.conf` plus a per-agent login, a separate one per endpoint. The rest of Loki's and Prometheus' APIs is not proxied |
| Node logs | Loki single binary, filesystem storage, retention `LOKI_RETENTION_PERIOD` (30 days) by the compactor, ingest limits. Agents redact IP addresses and node IDs before sending (`agents/alloy/`) |
| Host metrics | Prometheus single binary with the remote-write receiver, no scrape targets of its own; retention by time and size. Each source pushes with its own login (`scripts/agent-cred.sh add <name> metrics`) and `job` label, so more sources (e.g. CointMU-Bot) only need a login |
| TLS | Self-signed (or internal-CA) certificate; the app pins the **public key** (SPKI SHA-256). `server.key` is `640` with a dedicated host group (`TLS_GID`) that only the proxy joins, all other keys `600` |
| Rate limit | nginx: 5 req/s per client with burst 20 on the ingest endpoints (429 above), 1 MB body cap. GlitchTip 6.2.6 stores per-key rate limits but does not enforce them at ingest, so nginx is the limit |
| IP addresses | nginx clears `X-Forwarded-For`/`X-Real-IP`. Its access log has no client IP or query string for event ingest, `/_health/`, successful log pushes and every 403. The exception is an audit trail: requests that pass the admin allowlist (GlitchTip dashboard and API, `/grafana/`) are logged with the client address, and failed log and metrics pushes (401/413/429/5xx) with the address and the agent login. Admin logins happen inside GlitchTip and Grafana, so nginx records addresses, not user names. The audit lines are kept at least 30 days ("Logs"). nginx's error log is limited to critical errors (rare TLS failures, which include the client address), except on the log push, where errors name the agent's address. IP scrubbing is on for the org and project (GlitchTip ignores private, non-routable IPs anyway) |
| PII | Server-side scrubber on for every project (`GLITCHTIP_PII_SCRUB_DEFAULT`), as a second layer behind the app's allowlist + sanitizer |
| Retention | `GLITCHTIP_RETENTION_DAYS` (default 60) |
| Accounts | GlitchTip: registration and organization creation closed; Django admin, OpenAPI, logs, uptime and MCP off. Grafana: one login per admin, Viewer by default; the `admin` account (password from `.env`) is break-glass only (RUNBOOK.md, "Grafana users"). Sign-up, anonymous access and API basic auth off; no outbound calls except the Discord webhook |
| Alerts | Discord, one channel per source: GlitchTip new issues, Grafana rules on the node logs, `scripts/healthcheck.sh` for the VM, #ups for the UPS (Grafana rules plus the UPS host itself), and #block-update for the chain ("Alerts" below) |
| Logs | `json-file` driver rotated at 10 MB × 3 files per container. The proxy (audit trail) keeps 30 × 100 MB, with rotated files gzipped: at least 30 days at the worst-case push volume (5 agents, one push a second). RUNBOOK.md shows how far back it currently reaches |
| Hardening | `cap_drop: ALL` (Postgres gets back only what its entrypoint needs), `no-new-privileges`, read-only root filesystems for nginx, Loki, Prometheus and Grafana, memory and PID limits, health checks on every service except Loki (distroless image, see RUNBOOK.md) |

## Deploy

On the VM (Docker Engine with the Compose plugin):

```bash
git clone https://github.com/Cointmu-ORG/CointMU-Telemetry.git && cd CointMU-Telemetry

# 1. Configuration
cp .env.example .env && chmod 600 .env
install -d -m 700 state      # per-host stamps (git-ignored), e.g. the off-VM backup stamp
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

# 3. Per-host nginx files in nginx/local/ (the proxy refuses to start without all four)
cp nginx/local/admin-allow.conf.example nginx/local/admin-allow.conf
# add one "allow <address or subnet>;" line per admin machine or subnet
cp nginx/local/agent-allow.conf.example nginx/local/agent-allow.conf
# add one "<address or subnet> 1;" line per geth node server (campus or tailnet IP)
sudo install -m 640 -o "$USER" -g "$TLS_GID" /dev/null nginx/local/loki-agents.htpasswd
sudo install -m 640 -o "$USER" -g "$TLS_GID" /dev/null nginx/local/metrics-agents.htpasswd
# agent logins are added later with scripts/agent-cred.sh (agents/alloy/README.md, agents/ups/README.md, agents/chain/README.md)

# 4. Firewall (see below), then start
docker compose up -d
docker compose ps          # all "healthy" except loki (no healthcheck, see RUNBOOK.md)

# 5. Admin account and the CointMU project; prints the DSN
docker compose exec web ./manage.py createsuperuser
scripts/init-project.sh admin@example.com
```

`.env`, `nginx/local/` and `certs/` are git-ignored, and the server cannot be rebuilt with the same
pin without `certs/server.key`. `scripts/backup-config.sh` copies them off the VM, encrypted
("Backups" below). Until that is set up, keep a copy somewhere safe and private.

Grafana is at `https://<GLITCHTIP_HOST>/grafana/`. Log in once as `admin` (`GRAFANA_ADMIN_PASSWORD`) to
create one login per admin (RUNBOOK.md, "Grafana users"), then use your own. It has the
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
`DOCKER-USER` chain (`firewall/ufw-after.rules.snippet`). The snippet has four placeholders,
`<CAMPUS_SUBNET>`, `<TAILSCALE_SUBNET>`, `<BIND_IP>` and `<HTTPS_PORT>`; address and port are taken
from `.env` so the rule guards what is actually published, and only that: the containers' own
outgoing HTTPS (the Discord alerts) passes the same chain:

```bash
sudo ufw default deny incoming
sudo ufw allow from <ADMIN_SUBNET> to any port 22 proto tcp
CAMPUS_SUBNET='<CAMPUS_SUBNET>'   # the real campus LAN, e.g. 10.0.0.0/16
TAILSCALE_SUBNET=''               # tailnet IPs allowed in, comma-separated, e.g. 100.101.102.103/32; empty = none
BIND_IP=$(sed -n 's/^BIND_IP=//p' .env)
HTTPS_PORT=$(sed -n 's/^HTTPS_PORT=//p' .env)
if [ -n "$TAILSCALE_SUBNET" ]; then TAILSCALE_RULE="s|<TAILSCALE_SUBNET>|$TAILSCALE_SUBNET|g"
else TAILSCALE_RULE='/<TAILSCALE_SUBNET>/d'; fi
sed -e "s|<CAMPUS_SUBNET>|$CAMPUS_SUBNET|g" -e "s|<BIND_IP>|$BIND_IP|g" -e "s|<HTTPS_PORT>|${HTTPS_PORT:-443}|g" \
  -e "$TAILSCALE_RULE" \
  firewall/ufw-after.rules.snippet | sudo tee -a /etc/ufw/after.rules >/dev/null
sudo ufw enable && sudo ufw reload && sudo systemctl restart docker
```

**Tailscale.** Admins and node servers may come in over the Tailscale VPN (`100.64.0.0/10`).
Allow single tailnet addresses rather than the whole range, here and in `nginx/local/*.conf`.
The proxy listens only on `BIND_IP`, so tailnet clients must reach that campus address, through a
subnet router. A subnet router SNATs by default, so their requests arrive from the router's
campus address. Allow that address instead, or run the router with
`--snat-subnet-routes=false` so the `100.x` addresses arrive and the rules above apply.

If you change `BIND_IP` or `HTTPS_PORT` later, change every `--ctorigdst` or `--ctorigdstport`
value in `/etc/ufw/after.rules` to match, or the new address or port is open to every network.

The proxy is also bound to `BIND_IP` only, so it never listens on other interfaces.
Verify from a machine outside the LAN that `HTTPS_PORT` times out, and from a campus
machine that is not in `admin-allow.conf` that the dashboard and `/grafana/` answer 403,
and from one not in `agent-allow.conf` that `POST /loki/api/v1/push` answers 403.

The admin allowlist sees the real client address only with rootful Docker (the default
iptables port publishing). Rootless Docker's default port driver hides it, so every
request would look like the same internal address.

## Backups

| | |
|---|---|
| Database | `scripts/backup.sh`, daily: `backup/glitchtip-<UTC>.sql.gz`, checked with `gzip -t` before it gets its final name. It stays on the VM (mode 600, folder 700), and an age-encrypted copy goes to `backup/offsite/` |
| Configuration | `scripts/backup-config.sh`: `.env`, `certs/` and `nginx/local/` as one encrypted bundle in `backup/offsite/`, newest 8 kept. Together they hold every secret of the deployment, including the TLS key behind the app's pin |
| Off the VM | Only `backup/offsite/`. Everything there is encrypted to `BACKUP_AGE_RECIPIENT` (a public key in `.env`); the private key is kept offline, never on the VM |
| Retention | Every dump from the last 7 days plus Sunday dumps for 28 days, on the VM and in `offsite/` |
| RPO | 24 hours (one dump a day) |
| Not backed up | Loki's node logs and Prometheus' host metrics (`loki-data`, `prometheus-data`). They are history for debugging, not records; a rebuilt VM starts them empty |
| RTO | About 1 hour to rebuild on a new VM from the newest bundle and dump (RUNBOOK.md, "Rebuild on a new VM"). The first restore drill measures it; replace this estimate with the measured time |

Set up once:

```bash
sudo apt install age
# on a workstation, NOT on the VM; keep the key file offline (password manager, safe):
age-keygen -o cointmu-backup.key        # prints "Public key: age1..."
# on the VM, in .env:
BACKUP_AGE_RECIPIENT=age1...
```

Schedule it and copy only `backup/offsite/` off the VM. The stamp `state/backup-offsite.ok` is
touched only when every step, the copy included, has succeeded:

```cron
15 2 * * * cd /opt/CointMU-Telemetry && scripts/backup.sh >> backup/backup.log 2>&1 && scripts/backup-config.sh >> backup/backup.log 2>&1 && rsync -a --delete backup/offsite/ backup-host:/srv/cointmu-telemetry/offsite/ && touch state/backup-offsite.ok
```

Without `BACKUP_AGE_RECIPIENT`, `backup.sh` writes the plaintext dump only and warns on stderr, so a
VM that still runs the old cron line (which copied all of `backup/`) keeps working until it migrates
(RUNBOOK.md, "Moving to encrypted backups").

Restore with `scripts/restore.sh backup/<file>.sql.gz` (asks for confirmation, replaces all current
data). `scripts/restore-test.sh` checks a dump in a throwaway database instead; RUNBOOK.md has the
quarterly restore drill.

## Alerts (Discord)

All alerts go to one Discord server, one channel per source:

| Channel | Source | `.env` variable | Applied by |
|---|---|---|---|
| #app-errors | GlitchTip: each new issue of the desktop project, once | `DISCORD_WEBHOOK_APP_ERRORS` | `scripts/init-project.sh <email>` (re-run after a change) |
| #node-logs | Grafana alert rules on the geth node logs (log rules only) | `DISCORD_WEBHOOK_NODE_LOGS` | `docker compose up -d grafana` |
| #infra | `scripts/healthcheck.sh` from cron: VM health, independent of Grafana and Loki | `DISCORD_WEBHOOK_INFRA` | read on every run |
| #ups | Grafana alert rules on the UPS metrics (thresholds, stale or missing data) | `DISCORD_WEBHOOK_UPS` | `docker compose up -d grafana` |
| #ups | The UPS host itself: power events ("UPS monitoring") | its own webhook, on the host only | read on every event |
| #block-update | Grafana alert rules on the chain metrics ("Chain metrics") | `DISCORD_WEBHOOK_BLOCK_UPDATE` | `docker compose up -d grafana` |
| #block-update | Later: the CointMU-Bot block feed | its own webhook, in the bot's config only | the bot |

**Setup.** One webhook per channel: in Discord, Edit Channel → Integrations → Webhooks → New
Webhook → Copy Webhook URL, then put it in `.env` under that channel's variable.
- The URLs are **secrets**: anyone who has one can post to that channel. They live only in `.env`
  (mode 600, copied off the VM encrypted by `backup-config.sh`).
- An empty variable turns that source off, and nothing else fails.
- Server and channel IDs never go in this repository; a webhook URL is all a sender needs.

**What a message contains.**
- **#app-errors:** GlitchTip's own Discord message. It carries the issue title, a link to the issue
  on the LAN dashboard, and the fields Project, Release and Environment.
  - The title is the error type plus the first line of the error message (at most 100 characters),
    after the app's sanitizer and GlitchTip's scrubber.
  - GlitchTip 6.2.6 never fills the issue's culprit, so no code location is sent.
  - **The Discord server must stay admin-only:** the title is free text from an error message. If
    anyone else joins, empty `DISCORD_WEBHOOK_APP_ERRORS` and re-run
    `scripts/init-project.sh <email>` to turn this source off.
- **#node-logs:** the rule, the host, a count and the dashboard link for that host.
  - Rules:
    - **Host silent:** logged in the last 24 h but not in the last 15 min.
    - **Fatal or crit line.**
    - **Loki unreachable or no logs:** Loki query error, or nothing from any host for 15 min; pending
      for 5 min first. It also fires on a fresh deployment until the first agent ships logs.
  - A firing alert repeats at most every 12 h, and its resolution is posted once.
- **#ups (Grafana):** the rule, the host and UPS, the value and the UPS dashboard link.
- **#ups (host):** the event, the UPS, the host label, charge and runtime.
- **#block-update (Grafana):** the rule, the host and role, the value and the Chain dashboard link.
- **#infra:** the check, the VM's host name, the value against its limit, and the Grafana link.
  - Checks: disk at 85 % or more; a compose service not running or unhealthy (Loki through `/ready`);
    no successful off-VM backup copy in 26 h; certificate valid for less than 60 days. For 15 min
    after a container starts, "starting" or Loki not ready yet does not count (upgrades, restarts).
  - Posted once when a check fails and once when it recovers.
- **Never** log lines, event payloads, stack traces, or client or peer addresses. The only address is
  the VM's own campus address in the dashboard links.
- **No message can ping anyone.** GlitchTip's message text is fixed, and Discord takes mentions only
  from that text, not from embeds. Grafana puts its message into the embed.
  `healthcheck.sh` and the UPS host's `ups-notify.sh` send `allowed_mentions: none` and strip `@`,
  `<` and `>`.

Schedule the health check. It runs as the admin user, who must be in the `docker` group;
`journalctl -t cointmu-healthcheck` shows its output:

```cron
*/5 * * * * cd /opt/CointMU-Telemetry && scripts/healthcheck.sh 2>&1 | logger -t cointmu-healthcheck
```

**Network.** The VM needs outbound HTTPS (TCP 443) to `discord.com`, and only there: ask the campus
network team to allow it through their firewall or proxy.
- Senders: GlitchTip (from its container), Grafana (from its container, over the `alerts-egress`
  network) and `healthcheck.sh` (from the host).
- An HTTP proxy is not configured here; the VM needs a direct route.
- Docker cannot restrict the containers to `discord.com`; the VM's own firewall decides what else is
  reachable.

**Test each channel** on the VM, from the repository folder:

```bash
# 1. Webhook and VM egress: a test message to each configured channel (expect 204).
#    The URL goes to curl through a config file descriptor, never on the command line.
for var in DISCORD_WEBHOOK_APP_ERRORS DISCORD_WEBHOOK_NODE_LOGS DISCORD_WEBHOOK_INFRA DISCORD_WEBHOOK_UPS DISCORD_WEBHOOK_BLOCK_UPDATE; do
  url=$(sed -n "s/^$var=//p" .env); [ -n "$url" ] || continue
  printf '{"content":"test: %s on %s","allowed_mentions":{"parse":[]}}' "$var" "$(hostname -s)" \
    | curl -sS -o /dev/null -w "$var: %{http_code}\n" -H 'Content-Type: application/json' \
        --data-binary @- -K <(printf 'url = "%s"\n' "$url")
done

# 2. #app-errors through GlitchTip's own Discord code (posts the newest issue; expect 204)
DISCORD_WEBHOOK_APP_ERRORS=$(sed -n 's/^DISCORD_WEBHOOK_APP_ERRORS=//p' .env) \
docker compose exec -T -e DISCORD_WEBHOOK_APP_ERRORS web ./manage.py shell -c '
import asyncio, os
from apps.alerts.webhooks import send_test_notification
from apps.projects.models import Project
r = asyncio.run(send_test_notification(os.environ["DISCORD_WEBHOOK_APP_ERRORS"], "discord",
                                       Project.objects.get(slug="desktop")))
print("Discord answered", r.status if r else "nothing (blocked or unreachable)")'

# 3. #infra through healthcheck.sh: it posts on changes only, so force one and undo it
DISK_MAX_PERCENT=1 scripts/healthcheck.sh; scripts/healthcheck.sh   # "FAIL disk", then "OK disk"
```

For #node-logs, #ups and #block-update, open Grafana → Alerting → Contact points →
`discord-node-logs`, `discord-ups` or `discord-chain` → Test (as an org Admin). The UPS host tests its own webhook with
`sudo -u nut /usr/local/lib/cointmu-ups/ups-notify.sh test` (agents/ups/README.md).

**Blind spot.** GlitchTip, Grafana and `healthcheck.sh` all run on this VM. If the whole VM is down
or loses its network, nothing alerts. This is accepted for now. A possible later addition is an external heartbeat, e.g. a
cron job on a node server that checks `https://<VM>/_health/` and posts to #infra when it fails; it
is not set up.

## UPS monitoring

The UPS hangs on one Proxmox host, which runs NUT (`upsmon` monitor-only: it reports, it never
shuts anything down). The telemetry VM runs on that same host, so it is on the same UPS. Install
and details are in [agents/ups/README.md](agents/ups/README.md).

| Path | What | Where it shows | Needs the VM |
|---|---|---|---|
| A | upsmon → upssched (debounce) → `ups-notify.sh`, straight to Discord | #ups: on battery (after 30 s), back on mains, low battery, replace battery, comm lost (after 60 s) and restored; forced shutdown and shutting down once automatic shutdown is turned on | no |
| B | NUT's journal through Alloy into Loki (`job="ups"`, addresses redacted) | Grafana dashboard "UPS", log panel | yes |
| C | `ups-metrics.sh` every 15 s, Alloy's textfile collector, remote write into Prometheus | dashboard "UPS"; alerts to #ups | yes |

**No double messages.** The host posts every power transition (A). Grafana alerts only on what
needs a threshold or what the host can't report about itself:
- **UPS on battery for 10 min**
- **UPS charge below 50 %**
- **UPS runtime below 15 min.** The UPS reports no low-battery levels of its own (no
  `battery.charge.low` or `battery.runtime.low`), and nothing shuts down by itself. 15 minutes
  leaves time to shut the telemetry VM and the host down by hand before the UPS raises its own
  low-battery flag. The charge is estimated from the battery voltage, so it drops quickly under
  load; runtime is the better signal.
- **UPS unreadable:** `upsc` fails.
- **UPS metrics stale:** the collector stopped while Alloy keeps sending its last file.
- **UPS data missing:** nothing from the UPS host for 5 min.

RUNBOOK.md ("Alerts") has what each one means.

**Blind spot.** The telemetry VM runs on the UPS host itself.
- **During an outage** the host and the VM are both on battery, so A, B and C all keep working.
  B and C go from the host to the VM over the host's own bridge. A needs the campus uplink to
  discord.com, so it stops if the switch or uplink loses power first.
- **When the battery runs out**, the host and the VM lose power at the same moment, and B and C
  stop with them; nothing shuts down cleanly first (monitor-only). The last messages are "LOW
  BATTERY" from the host (if the UPS raises it in time) and "UPS runtime below 15 min" from
  Grafana. Shutting down by hand on that alert is the only clean way out (RUNBOOK.md).
- **Afterwards**, the gap stays in the graphs. The Alloy WAL replays what the host collected while
  the VM was unreachable: metrics from up to 8 h back, logs from up to 24 h back. Nothing is
  collected while the host itself is off.
- **If automatic shutdown is turned on later** (upsmon.conf.snippet), A's shutdown post is best
  effort: it is given up after about 4 s, so that `FINALDELAY` (10 s) is never exceeded. If
  Discord is slow at that moment, the "SHUTTING DOWN" message is lost.

## Chain metrics

Each geth node server runs `chain-metrics.py` every 15 s against its own geth RPC (loopback only),
and the node's Alloy agent pushes the result to Prometheus with its own metrics login. Install and
details are in [agents/chain/README.md](agents/chain/README.md). Nodes: server101 (bootnode and
miner) and CT 106 (miner). Grafana dashboard "Chain": height, blocks behind the highest node,
last-block age, block time, difficulty, estimated network hashrate, peers, sync state and RPC state
per node.

Alerts go to **#block-update** (`DISCORD_WEBHOOK_BLOCK_UPDATE`); #node-logs keeps the log rules
only. Later the CointMU-Bot block feed will post to #block-update as well, with its own webhook.
Blocks come about every 14 s.
- **Chain stalled:** no node has seen a new block for 10 min. One alert for the whole chain.
- **Chain node has no peers:** for 5 min.
- **Chain node behind:** more than 10 blocks behind the highest node, for 5 min.
- **Chain RPC down:** a node's RPC does not answer for 3 min (geth stopped or hangs).
- **Chain metrics stale:** the collector stopped while Alloy keeps sending its last file.
- **Chain metrics missing:** a node that sent metrics in the last 24 h sent none for 5 min.

RUNBOOK.md ("Alerts") has what each one means.

## Operations

See [RUNBOOK.md](RUNBOOK.md): key rotation and its release order, certificate renewal and its
2-year schedule, rotating secrets (database password, `SECRET_KEY`, Discord webhooks), host
patching, restore (with the quarterly restore drill and a rebuild on a new VM), disk full, upgrades,
"reports are not arriving" (including rate limits behind NAT), the admin access audit, what each
alert means, and for the log stack: adding a node agent, rotating agent logins, retention, Grafana
users and the break-glass admin, and "logs are not arriving"; for the UPS: the alerts, rotating the
host's webhook and logins, upgrading Prometheus, and "Moving to UPS monitoring".
