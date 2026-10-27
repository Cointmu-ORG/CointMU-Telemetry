# Grafana Alloy agent for geth node servers

Ships the geth logs of a node **server** (bootnode, miner) to the telemetry VM:

```
geth (PM2 log file or journal) ──▶ Alloy ──HTTPS + login──▶ nginx /loki/api/v1/push ──▶ Loki ──▶ Grafana
   level label, DEBUG dropped,     WAL (disk     VM cert as     agent allowlist,
   IPs and node IDs redacted       buffer)       trust anchor   rate limit
```

| File | Goes to |
|---|---|
| `config.alloy` | `/etc/alloy/config.alloy` |
| `alloy.env.example` | `/etc/default/alloy`, filled in |
| `certs/server.crt` from the VM | `/etc/alloy/telemetry.crt` |
| the password from `scripts/agent-cred.sh add` | `/etc/alloy/push-password` (0640 root:alloy) |

`config.alloy` also pushes the node's **chain metrics** to Prometheus, with a second login
(`/etc/alloy/metrics-password`, `METRICS_PUSH_*`). Set those up first and run
`agents/chain/alloy-preflight.sh` before installing this config (agents/chain/README.md). Without
them Alloy still ships the logs, but every metrics batch fails with a warning.

## What it sends

- **Labels:** `job="geth"`, `host` (`AGENT_HOST`), `role` (from the file name,
  `cointmu-bootnode-error.log` → `bootnode`, or the unit name, `geth.service` → `geth`), `level`
  (`fatal`, `crit`, `error`, `warn`, `info`; lines without a level, such as stack traces, have none),
  and `filename` for file sources.
- **Dropped:** DEBUG and TRACE lines.
- **Redacted:** IPv4 (Tailscale `100.x` included) and IPv6 addresses become `<ip>`, node IDs
  (`enode://<id>@`, `id=`, `peer=`) become `<node-id>`, ENR records become `<enr>`. The peers of a
  bootnode are students' laptops, and a node ID is a stable per-install identifier, so neither leaves
  the node. The unredacted lines stay in the node's own log files for debugging over SSH.
- **Timestamps** are the time Alloy read the line, not geth's clock (geth's format has no year or
  zone). `tail_from_end` makes a first start skip what was logged before it.

## Install (Ubuntu/Debian, systemd)

On the **telemetry VM**:

```bash
scripts/agent-cred.sh add bootnode-a-1         # prints the password once
# allow the node's address (campus or tailnet IP) in nginx/local/agent-allow.conf:
echo '<NODE_IP> 1;' >> nginx/local/agent-allow.conf && docker compose exec proxy nginx -s reload
```

On the **node**:

```bash
# 1. Alloy from Grafana's apt repository, pinned (upgrades are manual, RUNBOOK.md)
sudo install -d -m 755 /etc/apt/keyrings
wget -qO- https://apt.grafana.com/gpg.key | gpg --dearmor | sudo tee /etc/apt/keyrings/grafana.gpg >/dev/null
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
  | sudo tee /etc/apt/sources.list.d/grafana.list
sudo apt-get update && sudo apt-get install -y alloy=1.21.0-1
sudo apt-mark hold alloy

# 2. Config, certificate and password (copy the repo's agents/alloy/ and the VM's certs/server.crt over first)
sudo install -m 644 config.alloy /etc/alloy/config.alloy
sudo install -m 644 server.crt /etc/alloy/telemetry.crt
read -rsp 'push password: ' PW; echo
printf '%s' "$PW" | sudo install -m 640 -o root -g alloy /dev/stdin /etc/alloy/push-password; unset PW
sudo install -m 644 alloy.env.example /etc/default/alloy   # replaces the package's defaults
sudoedit /etc/default/alloy     # AGENT_HOST, LOKI_PUSH_URL, LOKI_PUSH_USER, GETH_LOG_FILES / GETH_JOURNAL_UNIT

# 3. Read access. The package already puts the alloy user in systemd-journal (and adm);
#    log files need to be readable by others or by a group alloy is in:
sudo -u alloy head -1 /home/<USER>/.pm2/logs/cointmu-bootnode-error.log   # must print a line

# 4. Start and check
sudo systemctl enable --now alloy
journalctl -u alloy -n 50 --no-pager      # no "error sending batch"
curl -s 127.0.0.1:12345/metrics | grep -E '^loki_write_(sent|dropped)_entries_total'
```

Then open Grafana (`https://<VM>/grafana/`, dashboard "Geth node logs") and pick the new host.

**Choosing sources.** A geth run by PM2 (as on the bootnode server) writes its log, including
`Fatal:` lines, to stderr, which PM2 stores in `~/.pm2/logs/<name>-error.log`: use `GETH_LOG_FILES`.
For geth under its own systemd unit without `--log.file`, use `GETH_JOURNAL_UNIT`. Both can be set
at once; their lines go through the same pipeline.

**Disk buffer.** While the VM is unreachable (or answers 429/5xx) Alloy keeps retrying and keeps the
lines in its write-ahead log under `/var/lib/alloy/data`, up to 24 hours; they arrive once the VM is
back. Limits, all tested:
- Batches answered with 401, 403 or 413 are dropped, which is why login rotation adds the new login
  before removing the old one (RUNBOOK.md).
- If Alloy restarts (or the node reboots) *during* an outage, the batches in its in-memory send
  queue are dropped: at most three batches, the first lines after the outage began. The rest is
  replayed from the WAL. The queue is kept at two batches (`queue_config`) for this reason.
- The WAL is an experimental Alloy feature, hence `--stability.level=experimental` and the pinned
  version.

## The desktop app does not use this path

This agent is for node servers only. The CointMU desktop app runs its own geth on each laptop and
never ships its geth logs anywhere: they stay in the app's local diagnostics, and crash reports go to
GlitchTip through the app's DSN. Agent logins are never put in an app build or in this repository,
and the push endpoint answers 403 to every address not in `nginx/local/agent-allow.conf`, before any
login prompt. Check from a campus laptop:

```bash
curl -sk -o /dev/null -w '%{http_code}\n' -X POST https://<VM>/loki/api/v1/push   # 403
```

## Changing the config

Run `agents/alloy/check-redaction.sh` on a machine with the stack running. It feeds
`testdata/cointmu-check-error.log` through `config.alloy` in the pinned Alloy image and fails if an
address or node ID gets through, a label is wrong, or the DEBUG line is not dropped. Add a line to
the test data for every new kind of address you see in real logs.
