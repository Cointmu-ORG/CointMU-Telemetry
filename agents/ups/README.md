# UPS monitoring on the UPS host

The UPS is attached to one Proxmox host and read there by NUT (Network UPS Tools: driver, `upsd`,
`upsmon`). `upsmon` runs **monitor-only**: it reports every event and never shuts anything down,
which is how the host behaved before. The telemetry VM runs on this same host, so it shares the UPS
(README.md, "UPS monitoring", blind spot).
The host reports the UPS two ways:

```
                    ┌─ A: upsmon → upssched (debounce) → ups-notify.sh ──HTTPS──▶ Discord #ups
UPS ─USB─ NUT ──────┤
  (UPS host)        └─ B: NUT journal ─▶ Alloy ──HTTPS + login──▶ nginx /loki/api/v1/push ──▶ Loki ──▶ Grafana (Explore)
```

- **A** posts every power event straight from the host. It needs neither the telemetry VM nor
  Grafana, so it keeps working when the VM is down.
- **B** keeps the event history (`{job="ups"}` in Grafana). It stops while the VM is down.

| File (this folder) | Goes to, on the UPS host | Owner, mode |
|---|---|---|
| `ups-notify.sh` | `/usr/local/lib/cointmu-ups/ups-notify.sh` | root:root 0755 |
| `cointmu-ups.conf.example` | `/etc/cointmu-ups/cointmu-ups.conf`, filled in | root:root 0644 (directory 0750 root:nut) |
| the host's own #ups webhook URL | `/etc/cointmu-ups/discord-webhook` | **nut:nut 0600** |
| `upssched.conf.snippet` | `/etc/nut/upssched.conf` (replaces it) | root:nut 0640 |
| `upsmon.conf.snippet` | lines merged into `/etc/nut/upsmon.conf` | unchanged (root:nut 0640) |
| `upsd.users.snippet` | appended to `/etc/nut/upsd.users` | unchanged (root:nut 0640) |
| `config.alloy` | `/etc/alloy/config.alloy` | root:root 0644 |
| `alloy.env.example` | `/etc/default/alloy`, filled in | root:root 0644 |
| `certs/server.crt` from the VM | `/etc/alloy/telemetry.crt` | root:root 0644 |
| the log password (`scripts/agent-cred.sh`) | `/etc/alloy/push-password` | root:alloy 0640 |

Why the webhook file belongs to `nut` and not root: upsmon runs NOTIFYCMD, and with it upssched and
`ups-notify.sh`, as its unprivileged user (`RUN_AS_USER nut`). Only that system account (no login)
and root can read the file. The URL reaches curl through a config file descriptor, never a command
line or a log.

## Requirements

- NUT 2.8 from Debian (Proxmox VE 8/9), the UPS readable with `upsc <ups>@localhost`. `upsmon`
  (`nut-monitor.service`) need not be running yet: "Discord notifier" configures and starts it,
  monitor-only.
- **Firewall.** These paths must be open; check both the campus firewall and pve-firewall if it is
  enabled:
  - A: outbound TCP 443 from `<UPS_HOST_IP>` to `discord.com`.
  - B: `<UPS_HOST_IP>` to `<TELEMETRY_IP>:<HTTPS_PORT>`. The VM's `DOCKER-USER` rule must let
    that address in, either because it lies in `CAMPUS_SUBNET` or through an extra rule (README.md,
    "Firewall").
  - `<UPS_HOST_IP> 1;` in the VM's `nginx/local/agent-allow.conf`.

## Install

Copy this folder to the UPS host first. "UPS" below is the name `upsc -l` prints (`ups` unless
`/etc/nut/ups.conf` says otherwise); the driver runs as `nut-driver@<ups>.service`.

### On the telemetry VM

```bash
scripts/agent-cred.sh add <host>-1            # log login: prints the password once
echo '<UPS_HOST_IP> 1;' >> nginx/local/agent-allow.conf && docker compose exec proxy nginx -s reload
```

### Discord notifier (path A)

```bash
upsc -l; systemctl list-units --no-pager 'nut*'
sudo install -d -m 755 /usr/local/lib/cointmu-ups
sudo install -m 755 ups-notify.sh /usr/local/lib/cointmu-ups/
sudo install -d -m 750 -o root -g nut /etc/cointmu-ups
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

### Alloy (path B)

Copy the VM's `certs/server.crt` over as well.

```bash
# Alloy, pinned, exactly as agents/alloy/README.md step 1 (apt repository,
# alloy=1.21.0-1, apt-mark hold). This creates the alloy user and group.
getent group alloy                                  # must print a line
sudo install -m 644 config.alloy /etc/alloy/config.alloy
sudo install -m 644 server.crt /etc/alloy/telemetry.crt
read -rsp 'log push password: ' PW; echo
printf '%s' "$PW" | sudo install -m 640 -o root -g alloy /dev/stdin /etc/alloy/push-password; unset PW
sudo install -m 644 alloy.env.example /etc/default/alloy
sudoedit /etc/default/alloy   # AGENT_HOST, UPS_NAME, LOKI_PUSH_URL, LOKI_PUSH_USER
sudo systemctl enable --now alloy
journalctl -u alloy -n 50 --no-pager        # no "error sending batch", no 401/403
curl -s 127.0.0.1:12345/metrics | grep -E '^loki_write_sent_entries_total'
```

Then in Grafana → Explore → Loki: `{job="ups"}` shows the host's NUT lines.

## What it sends

- **Discord (A):** `**<EVENT>** <ups> on <HOST_LABEL>, charge N %, runtime M min` and one line of
  explanation. Nothing else, and `allowed_mentions` is empty, so no message can ping anyone.
- **Logs (B):** the journal of `nut-server`, `nut-monitor` (upsmon, upssched and `ups-notify.sh`) and
  the driver unit. Labels: `job="ups"`, `host`, `ups`, `unit`. Addresses (upsd logs
  `user@<address>` for each client login) become `<ip>`, as on the geth nodes. The host's other units
  are not read.

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
- `agents/ups/check-ups.sh`: a throwaway copy of the stack. It feeds test journal lines through
  `config.alloy` and nginx into Loki, and checks the labels and the redaction. About 2 minutes; it
  never touches a running deployment.

Both run in CI (job `ups`).
