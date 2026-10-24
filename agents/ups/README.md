# UPS monitoring on the UPS host

The UPS is attached to one Proxmox host and read there by NUT (Network UPS Tools: driver, `upsd`,
`upsmon`). `upsmon` runs **monitor-only**: it reports every event and never shuts anything down,
which is how the host behaved before. The telemetry VM runs on this same host, so it shares the UPS
(README.md, "UPS monitoring", blind spot).
The host reports the UPS three ways:

```
                    ┌─ A: upsmon → upssched (debounce) → ups-notify.sh ──HTTPS──▶ Discord #ups
UPS ─USB─ NUT ──────┼─ B: NUT journal ─▶ Alloy ──HTTPS + login──▶ nginx /loki/api/v1/push ──▶ Loki ─┐
  (UPS host)        └─ C: ups-metrics.sh (timer, 15 s) → ups.prom ─▶ Alloy ──HTTPS + login──▶       ├─▶ Grafana "UPS"
                          textfile collector                nginx /prometheus/api/v1/write ──▶ Prometheus ┘   + alerts → #ups
```

- **A** posts every power event straight from the host. It needs neither the telemetry VM nor
  Grafana, so it keeps working when the VM is down.
- **B** and **C** give the event history and the graphs, plus Grafana alerts on thresholds and on
  stale or missing data. They stop while the VM is down.

| File (this folder) | Goes to, on the UPS host | Owner, mode |
|---|---|---|
| `ups-notify.sh` | `/usr/local/lib/cointmu-ups/ups-notify.sh` | root:root 0755 |
| `cointmu-ups.conf.example` | `/etc/cointmu-ups/cointmu-ups.conf`, filled in | root:root 0644 (directory 0751 root:nut) |
| the host's own #ups webhook URL | `/etc/cointmu-ups/discord-webhook` | **nut:nut 0600** |
| `upssched.conf.snippet` | `/etc/nut/upssched.conf` (replaces it) | root:nut 0640 |
| `upsmon.conf.snippet` | lines merged into `/etc/nut/upsmon.conf` | unchanged (root:nut 0640) |
| `upsd.users.snippet` | appended to `/etc/nut/upsd.users` | unchanged (root:nut 0640) |
| `config.alloy` | `/etc/alloy/config.alloy` | root:root 0644 |
| `alloy.env.example` | `/etc/default/alloy`, filled in | root:root 0644 |
| `certs/server.crt` from the VM | `/etc/alloy/telemetry.crt` | root:root 0644 |
| log and metrics passwords (`scripts/agent-cred.sh`) | `/etc/alloy/push-password`, `/etc/alloy/metrics-password` | root:alloy 0640 |
| `ups-metrics.sh` | `/usr/local/lib/cointmu-ups/ups-metrics.sh` | root:root 0755 |
| `cointmu-ups-metrics.service`, `.timer` | `/etc/systemd/system/` | root:root 0644 |
| `cointmu-ups.tmpfiles.conf` | `/etc/tmpfiles.d/cointmu-ups.conf` | root:root 0644 |

Why the webhook file belongs to `nut` and not root: upsmon runs NOTIFYCMD, and with it upssched and
`ups-notify.sh`, as its unprivileged user (`RUN_AS_USER nut`). Only that system account (no login)
and root can read the file. The URL reaches curl through a config file descriptor, never a command
line or a log.

Why the directory is `0751` and not `0750`: the metrics collector reads `cointmu-ups.conf` as its own
user `cointmu-ups`, which is in neither `nut` nor `alloy` (`nut` could also read `/etc/nut/`, upsmon's
password included). The execute bit for others lets it open that file by name; it still cannot list
the directory, and the webhook file stays `nut` only.

## Requirements

- NUT 2.8 from Debian (Proxmox VE 8/9), the UPS readable with `upsc <ups>@localhost`. `upsmon`
  (`nut-monitor.service`) need not be running yet: "Discord notifier" configures and starts it,
  monitor-only.
- **Firewall.** These paths must be open; check both the campus firewall and pve-firewall if it is
  enabled:
  - A: outbound TCP 443 from `<UPS_HOST_IP>` to `discord.com`.
  - B and C: `<UPS_HOST_IP>` to `<TELEMETRY_IP>:<HTTPS_PORT>`. The VM's `DOCKER-USER` rule must let
    that address in, either because it lies in `CAMPUS_SUBNET` or through an extra rule (README.md,
    "Firewall").
  - `<UPS_HOST_IP> 1;` in the VM's `nginx/local/agent-allow.conf`.

## Install

Copy this folder to the UPS host first. "UPS" below is the name `upsc -l` prints (`ups` unless
`/etc/nut/ups.conf` says otherwise); the driver runs as `nut-driver@<ups>.service`.

**Order:** Alloy before the metrics collector, because Alloy's package creates the `alloy` group
that the metrics directory needs. `ups-metrics.sh` refuses to run, with a message saying what to do,
as long as the group or the directory is missing or wrong.

### On the telemetry VM

```bash
scripts/agent-cred.sh add <host>-1            # log login: prints the password once
scripts/agent-cred.sh add <host>-1 metrics    # metrics login: prints its password once
echo '<UPS_HOST_IP> 1;' >> nginx/local/agent-allow.conf && docker compose exec proxy nginx -s reload
# Grafana's #ups webhook (a different one from the host's):
nano .env        # DISCORD_WEBHOOK_UPS=https://discord.com/api/webhooks/...
docker compose up -d grafana
```

### Discord notifier (path A)

```bash
upsc -l; systemctl list-units --no-pager 'nut*'
sudo install -d -m 755 /usr/local/lib/cointmu-ups
sudo install -m 755 ups-notify.sh /usr/local/lib/cointmu-ups/
sudo install -d -m 751 -o root -g nut /etc/cointmu-ups
sudo install -m 644 cointmu-ups.conf.example /etc/cointmu-ups/cointmu-ups.conf
sudoedit /etc/cointmu-ups/cointmu-ups.conf          # UPS=<ups>@localhost, HOST_LABEL
# the host's own #ups webhook
read -rsp 'host #ups webhook URL: ' URL; echo
printf '%s' "$URL" | sudo install -m 600 -o nut -g nut /dev/stdin /etc/cointmu-ups/discord-webhook; unset URL
sudo cp -p /etc/nut/upssched.conf /etc/nut/upssched.conf.orig
sudo cp -p /etc/nut/upsmon.conf /etc/nut/upsmon.conf.orig
sudo cp -p /etc/nut/upsd.users /etc/nut/upsd.users.orig
sudo install -m 640 -o root -g nut upssched.conf.snippet /etc/nut/upssched.conf
# upsmon's login on the local upsd: one random password in both files. It goes
# through the environment, never a command line.
export UPSMON_PASSWORD=$(openssl rand -hex 16)
fill() { awk '{ gsub("<UPSMON_PASSWORD>", ENVIRON["UPSMON_PASSWORD"]); print }' "$1"; }
fill upsd.users.snippet | sudo tee -a /etc/nut/upsd.users >/dev/null
sudo sed -i -E '/^\s*(RUN_AS_USER|MONITOR|MINSUPPLIES|NOTIFYCMD|NOTIFYFLAG|FINALDELAY)\b/d' /etc/nut/upsmon.conf
fill upsmon.conf.snippet | sudo tee -a /etc/nut/upsmon.conf >/dev/null
unset UPSMON_PASSWORD; unset -f fill
sudo systemctl restart nut-server
sudo systemctl enable --now nut-monitor
ps -o user=,args= -C upsmon           # two lines: root (parent) and nut (the one that notifies)
journalctl -u nut-monitor -n 20 --no-pager   # "Login on UPS [ups@localhost]", no "insufficient power"
sudo -u nut /usr/local/lib/cointmu-ups/ups-notify.sh test      # a TEST message in #ups
journalctl -t cointmu-ups-notify -n 5 --no-pager                # "posted test"
```

### Alloy (paths B and C)

Copy the VM's `certs/server.crt` over as well.

```bash
# Alloy, pinned, exactly as agents/alloy/README.md step 1 (apt repository,
# alloy=1.21.0-1, apt-mark hold). This creates the alloy user and group.
getent group alloy                                  # must print a line
sudo install -m 644 config.alloy /etc/alloy/config.alloy
sudo install -m 644 server.crt /etc/alloy/telemetry.crt
read -rsp 'log push password: ' PW; echo
printf '%s' "$PW" | sudo install -m 640 -o root -g alloy /dev/stdin /etc/alloy/push-password
read -rsp 'metrics push password: ' PW; echo
printf '%s' "$PW" | sudo install -m 640 -o root -g alloy /dev/stdin /etc/alloy/metrics-password; unset PW
sudo install -m 644 alloy.env.example /etc/default/alloy
sudoedit /etc/default/alloy   # AGENT_HOST, UPS_NAME, both URLs and users
sudo systemctl enable --now alloy
journalctl -u alloy -n 50 --no-pager        # no "error sending batch", no 401/403
curl -s 127.0.0.1:12345/metrics | grep -E '^(loki_write_sent_entries_total|prometheus_remote_storage_samples_total)'
```

### Metrics collector (path C)

```bash
# its own user, not in group alloy
sudo useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin cointmu-ups
sudo install -m 755 ups-metrics.sh /usr/local/lib/cointmu-ups/
sudo install -m 644 cointmu-ups.tmpfiles.conf /etc/tmpfiles.d/cointmu-ups.conf
sudo systemd-tmpfiles --create /etc/tmpfiles.d/cointmu-ups.conf
sudo install -m 644 cointmu-ups-metrics.service cointmu-ups-metrics.timer /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl enable --now cointmu-ups-metrics.timer
sleep 20
sudo -u alloy cat /var/lib/cointmu-ups/ups.prom     # MUST print ups_up ... 1 and the values
stat -c '%U:%G %a %n' /var/lib/cointmu-ups /var/lib/cointmu-ups/ups.prom
#   cointmu-ups:alloy 2750 /var/lib/cointmu-ups
#   cointmu-ups:alloy 640  /var/lib/cointmu-ups/ups.prom
systemd-analyze security cointmu-ups-metrics.service   # review; expect a low exposure score
```

Then open Grafana, dashboard "UPS". "UPS data missing" resolves within a minute of the first samples.

## What it sends

- **Discord (A):** `**<EVENT>** <ups> on <HOST_LABEL>, charge N %, runtime M min` and one line of
  explanation. Nothing else, and `allowed_mentions` is empty, so no message can ping anyone.
- **Logs (B):** the journal of `nut-server`, `nut-monitor` (upsmon, upssched and `ups-notify.sh`) and
  the driver unit. Labels: `job="ups"`, `host`, `ups`, `unit`. Addresses (upsd logs
  `user@<address>` for each client login) become `<ip>`, as on the geth nodes. The host's other units
  are not read.
- **Metrics (C):** only the textfile collector. None of the host's other metrics leave it.
  - `ups_battery_charge_percent`, `ups_battery_runtime_seconds`, their NUT low levels
    `ups_battery_charge_low_percent` and `ups_battery_runtime_low_seconds` (only if the UPS reports
    them), `ups_load_percent`, `ups_input_voltage_volts`, `ups_output_voltage_volts`
  - `ups_status{flag}` 0/1 for each status flag (OL, OB, LB, RB, CHRG, ...), `ups_info{model,driver}`
  - `ups_up` 0/1: 0 when `upsc` fails or the driver's data is stale; then nothing else
  - `ups_scrape_timestamp_seconds`: when the file was written
  - Labels: `job="ups"`, `host`, `ups`, `instance="ups"`

## Events and debounce (A)

| Event (upsmon) | Message | When |
|---|---|---|
| ONBATT | ON BATTERY | after 30 s on battery; nothing for a shorter blip |
| ONLINE | BACK ON MAINS | only if ON BATTERY was posted |
| LOWBATT | LOW BATTERY | at once. Monitor-only: nothing shuts down; power can fail within minutes |
| FSD | FORCED SHUTDOWN | only with automatic shutdown on. NUT sends FSD to the hosts that monitor this UPS as **secondaries**; the primary goes straight to SHUTDOWN, so on a single host you see LOW BATTERY then SHUTTING DOWN |
| SHUTDOWN | SHUTTING DOWN | only with automatic shutdown on, before this host runs SHUTDOWNCMD |
| REPLBATT | REPLACE BATTERY | at once; upsmon repeats it every `RBWARNTIME` (12 h) |
| COMMBAD | COMM LOST | after 60 s without contact to the UPS |
| COMMOK | COMM RESTORED | only if COMM LOST was posted |

upsmon ignores the first OL at startup, so restarting NUT posts nothing.

**Monitor-only, and turning shutdown on later.** With power value 0 and `MINSUPPLIES 0`, upsmon
never shuts down; a low battery only posts LOW BATTERY. Turning automatic shutdown on is a separate
decision, best tested in a maintenance window. It takes three changes: power value 1 and
`primary` on the MONITOR line, `upsmon primary` in upsd.users, and `MINSUPPLIES 1`. Then on low
battery the host runs SHUTDOWNCMD, and pve-guests stops the telemetry VM first.

**Shutdown ordering (with shutdown on).** upsmon runs the notifier in a forked child, sends
SHUTDOWN, waits `FINALDELAY`, then runs `SHUTDOWNCMD`. For `fsd` and `shutdown`, `ups-notify.sh`
allows 1 s for `upsc` and 3 s for curl, so the post finishes or is given up after about 4 s.
`FINALDELAY 10` (upsmon.conf.snippet) leaves 6 s to spare. If Discord doesn't answer within 3 s,
that message is lost (README.md, blind spot). `FINALDELAY` delays only this host's own shutdown
command; the VMs are shut down after it.

## Changing it

- `agents/ups/check-notify.sh`: real NUT daemons on a fake UPS in a container, with discord.com
  pointed at a local listener. It checks:
  - monitor-only, as installed: the debounce, one post per transition, low battery without a shutdown
  - with automatic shutdown on: the shutdown ordering, including a slow Discord
  - the payloads

  About 2 minutes.
- `agents/ups/check-ups.sh`: a throwaway copy of the stack plus a fake UPS host running
  `ups-metrics.sh`. It checks:
  - the owner/mode table above
  - remote write and log push through nginx: 2xx, 401, 403, 404, audit log
  - redaction, the dashboard queries, and the alert rules (healthy, Alloy stopped, timer stopped)

  About 4 minutes; it never touches a running deployment.

Both run in CI (job `ups`).
