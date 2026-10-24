# Runbook

Commands run from the repository folder on the VM.

## Key rotation (changes the pin)

The app accepts only the public keys pinned in its build. Changing the server key before
the app knows the new pin makes every installed app reject the server. Its reports then
stay queued on the laptops (up to 5 MB / 30 days each) until an app with the new pin
is installed. Rotate in this order:

1. **Generate the next key** (the server keeps using the current one):
   ```bash
   scripts/gen-cert.sh next      # prints "pin (current)" and "pin (next)"
   ```
2. **Release the app with both pins**: set `TELEMETRY_PINS=<current>,<next>` in
   CointMU-App and ship a release.
3. **Wait** until most users run that release (auto-updater). Reports from older apps
   keep working because the server still presents the current key.
4. **Switch the server**:
   ```bash
   scripts/gen-cert.sh promote IP:10.0.0.10
   docker compose restart proxy
   scripts/print-pin.sh 10.0.0.10:443   # must equal the former "next" pin
   ```
   Apps from step 2 on accept it. Older apps queue reports until they update.
   Copy the new `certs/server.crt` to every node agent (see "Server certificate changed"
   below); they buffer logs until then.
5. **Drop the old pin**: set `TELEMETRY_PINS=<new current>` in the next app release.
   `certs/server.key.old` is kept at mode 600 (the proxy cannot read it); delete it
   once no supported release pins it.

If the key leaked, skip the waiting in step 3: promote immediately and ship the release
with the new pin as soon as possible. Reports from older apps queue until users update.

## Certificate renewal (same key, pin unchanged)

```bash
scripts/gen-cert.sh renew IP:10.0.0.10
docker compose restart proxy
```

No app release needed, but the node agents trust the certificate itself, not the key: copy
the new `certs/server.crt` to every agent ("Server certificate changed" below). The new
certificate is valid for 825 days; "Scheduled renewal and key rotation" plans the next one.
`renew` also resets the key permissions (`server.key` 640 with
group `TLS_GID`, everything else 600), so run it once on a server whose key was made by
an older `gen-cert.sh` (mode 644 or group 101). Also use this when the server IP changes, together with
`BIND_IP`/`GLITCHTIP_HOST` in `.env`. A new IP also changes the DSN, which does need an
app release.

## Scheduled renewal and key rotation (about every 2 years)

`gen-cert.sh` issues certificates valid for 825 days (`VALID_DAYS`). The app pins the key and
accepts an expired certificate. The node agents check the certificate: once it has expired they
reject every push, keep retrying, and buffer in their WAL for up to 24 hours. So the renewal is a
routine, and the key rotation is done in the same window.

- **Existing certificates keep their current expiry until the next `renew` or `promote`.** One made
  with the old 3650-day setting stays valid that long; the new value only applies to certificates
  issued from then on.
- **When:** `scripts/healthcheck.sh` posts "cert" to #infra 60 days before expiry. Put the date in
  the team calendar as well. Starting about 3 months ahead leaves time for the app release in step 2.

```bash
scripts/gen-cert.sh status     # expires, days_left, pin, key_age_days, next_key
```

1. Rotate the key with the steps in "Key rotation" above, unchanged: `next` → app release with both
   pins → wait → `promote`. `promote` issues a fresh 825-day certificate for the new key, so it is the
   renewal too.
2. If the app release can't happen before the certificate expires, run "Certificate renewal" (same
   key, no app impact) first, and rotate the key in the next window.
3. Either way, copy the new `certs/server.crt` to every node agent ("Server certificate changed")
   and check that each host shows new lines in Grafana.
4. `scripts/gen-cert.sh status` again: `days_left` about 825, and after a promote a new `pin` and
   `next_key=no`.

## Reports are not arriving

1. `docker compose ps`: all services healthy? `docker compose logs --tail=100 web proxy`.
2. From a campus machine: `curl -k https://<server>/_health/` returns 200?
3. Pin: `scripts/print-pin.sh <server>:<HTTPS_PORT>` must be in the app's `TELEMETRY_PINS`.
4. nginx log (`docker compose logs proxy`): `POST /api/<id>/envelope/` lines with 200?
   429 means rate limited, 413 too large.

   **Many laptops behind one address.** The limit (5 req/s, burst 20) is per client address.
   Laptops behind one NAT/SNAT address share it: a lab router, a Tailscale subnet router, a campus
   NAT. A busy lab then gets 429s even though no single laptop misbehaves. The app keeps rejected
   reports queued and retries them, so they arrive late, not lost.

   The ingest log has no client address, so confirm it from the pattern instead. Look for 429s that
   cluster in a few minutes (a lab session) while the other minutes get 200:
   ```bash
   # per minute: ingest requests, of which 429
   docker compose logs --no-log-prefix --since 2h proxy \
     | grep -E '"POST /api/[0-9]+/(envelope|store)/"' \
     | awk '{m = substr($1, 2, 17); n[m]++; if ($5 == 429) r[m]++}
            END {for (m in n) print m, n[m], r[m] + 0}' | sort
   ```
5. Still unclear why requests fail (502/504, TLS errors)? nginx's error log is limited to
   critical errors, because its lines name the client. Raise it for **one short debugging session
   only**. `nginx/default.conf` is a single-file mount, so an edit needs a restart, not a reload
   (a few seconds without ingest; the apps retry):
   ```bash
   sed -i 's|^  error_log /dev/stderr crit;|  error_log /dev/stderr error;|' nginx/default.conf
   docker compose restart proxy
   # reproduce the problem, then:
   docker compose logs --since 10m proxy | grep -F '[error]'
   git checkout -- nginx/default.conf && docker compose restart proxy   # back to crit
   ```
   While it is raised, **client addresses are logged, students' laptops included**, and they stay in
   the proxy log until it rotates (README.md, "Logs"). Keep it short and revert in the same session.
6. On the laptop: Settings → Privacy & Diagnostics shows reporting on and the queue.
   Reports are held until the first-run notice is dismissed.

## Admin access audit

Requests that pass the admin allowlist (GlitchTip dashboard and API, `/grafana/`) and failed log
pushes are logged with the client address. A push also carries the agent login. 403s and
everything else carry no address (README.md, "IP addresses").

```bash
# who reached the admin paths, newest last (audit lines start with an address)
docker compose logs --no-log-prefix proxy | grep -E '^[0-9a-f.:]+ ' | grep -v '/loki/api/v1/push'
# failed pushes per agent login and status
docker compose logs --no-log-prefix proxy | grep -E '^[0-9a-f.:]+ .*"POST /loki/api/v1/push"' \
  | awk '{print $2, $(NF-2)}' | sort | uniq -c
# how far back the proxy log reaches (README.md states at least 30 days)
docker compose logs --no-log-prefix --timestamps proxy | head -1
```

If it reaches back less than 30 days, real traffic is heavier than the worst case it was sized for:
raise `max-file` of the proxy in `compose.yml`, then `docker compose up -d proxy`.

## Rotate secrets

Each secret below also has an "if leaked" variant. The config bundles from `backup-config.sh` and the
database dumps hold copies of these secrets. They are encrypted, and they are pruned after 28 days.

### POSTGRES_PASSWORD

The `pg-data` volume ignores `POSTGRES_PASSWORD` after its first start, so changing only `.env`
locks GlitchTip out. Change it inside the running database first, then in `.env`, then recreate
`web`. The password is read by psql from the environment (`\getenv`), so it never appears in a
process list or the shell history:

```bash
PW=$(openssl rand -hex 24)
printf '%s\n' '\getenv pw PW' "ALTER USER glitchtip PASSWORD :'pw';" \
  | PW="$PW" docker compose exec -T -e PW postgres psql -U glitchtip -d glitchtip -v ON_ERROR_STOP=1 -q
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$PW/" .env; unset PW
docker compose up -d web
docker compose ps web            # healthy again within about a minute
```

Then check that ingest still works: `POST /api/<id>/envelope/` lines with 200 in
`docker compose logs --since 5m proxy`. `backup.sh` and `restore.sh` connect inside the postgres
container and need no change.

**If leaked:** Postgres is only on the internal `backend` network (web and postgres), so using the
password needs access to the VM. Rotate immediately as above. Then list the connections: only `web`'s
address should appear.

```bash
docker compose exec -T postgres psql -U glitchtip -d glitchtip \
  -c "SELECT usename, client_addr, backend_start FROM pg_stat_activity WHERE client_addr IS NOT NULL"
```

### GlitchTip SECRET_KEY

What it protects in GlitchTip 6.2.6 (read from the source), and so what a new key invalidates:

- all logged-in sessions (everyone logs in again)
- password-reset links
- pending organization invitations (re-send them)
- MFA "trust this browser" cookies

It does **not** affect DSN and project keys (no app impact, no release), API tokens, TOTP secrets and
recovery codes, or alert recipients: none of these are derived from or encrypted with it. There is no
fallback key, so the switch is immediate.

```bash
sed -i "s/^SECRET_KEY=.*/SECRET_KEY=$(openssl rand -hex 32)/" .env
docker compose up -d web
```

**If leaked:** rotate immediately. With the key, someone who also knows account details can forge
password-reset links, invitations and MFA trust cookies. Then:

- check organization members and API tokens in GlitchTip for anything you did not create;
- check the admin paths' audit trail for addresses that are not yours ("Admin access audit"). The
  dashboard and API are reachable only from the admin allowlist.

### Discord webhook

1. In Discord: Edit Channel → Integrations → Webhooks → delete the old webhook, then create a new one
   and copy its URL.
2. Put it in `.env` (`DISCORD_WEBHOOK_APP_ERRORS`, `_NODE_LOGS`, `_INFRA` or `_UPS`).
3. Apply it:
   - **#app-errors:** `scripts/init-project.sh <owner email>`, which updates GlitchTip's recipient.
   - **#node-logs, #ups (Grafana):** `docker compose up -d grafana`, which recreates Grafana with the new URL.
   - **#infra:** nothing; `healthcheck.sh` reads `.env` on every run.
4. Send a test message (README.md, "Alerts").

**If leaked:** anyone with the URL can post to that channel. Delete the webhook in Discord **first**:
that stops any misuse at once, and the only cost is missed alerts until step 3. Then follow steps 1–4.
Copies of the old URL in `.env` bundles and database dumps are harmless once the webhook is deleted.

### UPS host webhook (#ups)

The UPS host has its own #ups webhook, separate from Grafana's `DISCORD_WEBHOOK_UPS`. It never goes in
`.env`, so rotating one leaves the other alone. On the UPS host:

```bash
read -rsp 'new host #ups webhook URL: ' URL; echo
printf '%s' "$URL" | sudo install -m 600 -o nut -g nut /dev/stdin /etc/cointmu-ups/discord-webhook; unset URL
sudo -u nut /usr/local/lib/cointmu-ups/ups-notify.sh test     # a TEST message in #ups
```

The next event uses it; nothing needs a restart. **If leaked:** delete it in Discord first, as above.
Power events are lost until the new one is in place.

## Alerts (Discord)

What each message means and where to start. README.md ("Alerts") has the setup and the tests.

**#infra** (`scripts/healthcheck.sh`, every 5 minutes; one message on failure, one on recovery):

| Check | First steps |
|---|---|
| disk | "Disk full" below |
| services | `docker compose ps`, then `docker compose logs --tail=100 <service>`. For Loki: "Is Loki up?" |
| backup | `tail backup/backup.log`; run the backup cron line by hand. "off-VM copy not configured" on a VM that hasn't migrated: "Moving to encrypted backups" |
| cert | "Scheduled renewal and key rotation" above |

A `services` failure for `prometheus` means pushed host metrics are not stored; the agents keep them in
their WAL (up to 8 h) and replay them. Check `docker compose logs --tail=50 prometheus`. Meanwhile the
UPS graphs and #ups Grafana alerts are blind; the UPS host's own #ups messages still work.

`scripts/healthcheck.sh` prints every failing check; `journalctl -t cointmu-healthcheck` shows what
cron saw. Its state is in `state/healthcheck/` (one file per failing check that was posted).

**#node-logs** (Grafana; repeats at most every 12 h; one message when resolved):

| Rule | First steps |
|---|---|
| Host silent | Is the node up, is geth running, is Alloy running? "Logs are not arriving". If the node is down on purpose: "Silence a node that is down on purpose" |
| Fatal or crit line | Open the dashboard link (level fatal/crit) and read the full line in the node's own log file over SSH |
| Loki unreachable or no logs | "Is Loki up?". On a fresh deployment it fires until the first agent ships logs. While Loki does not answer, the other two rules keep their last state: no false "resolved" |

**#app-errors** (GlitchTip, each new issue once): open the issue link from the campus LAN.

**#ups from the UPS host** (`ups-notify.sh`, one message per transition; agents/ups/README.md):

| Message | Meaning, first steps |
|---|---|
| ON BATTERY | Mains lost for 30 s. Check whether the outage is local (breaker, PDU) or campus-wide. Note the runtime in the message: nothing shuts down by itself (monitor-only), so a long outage needs a shutdown by hand ("LOW BATTERY") |
| BACK ON MAINS | Power is back. The UPS recharges, and "UPS charge below 50 %" may still be firing; it resolves on its own |
| LOW BATTERY | **Nothing shuts down by itself (monitor-only)**: power can fail within minutes, taking the host and the telemetry VM down hard. If mains is not back, shut down by hand now ("UPS runtime below 15 min" below) |
| FORCED SHUTDOWN | Only once automatic shutdown is on: sent to hosts that monitor this UPS as secondaries; they shut down now |
| SHUTTING DOWN | Only once automatic shutdown is on: this host is running its shutdown command. It may be the last message: the post is given up after about 4 s |
| REPLACE BATTERY | The UPS failed its battery test. Order a battery. NUT repeats it every 12 h until the battery is replaced |
| COMM LOST / COMM RESTORED | The UPS was unreachable for 60 s (USB cable, driver). `systemctl status 'nut-driver@*'` and `journalctl -u 'nut*' -n 50` on the host. While it lasts, nothing else is reported |

**#ups from Grafana** (repeats at most every 12 h; one message when resolved):

| Rule | Meaning, first steps |
|---|---|
| UPS on battery for 10 min | A long outage. Estimate from the runtime whether the host will last, and shut down non-essential guests by hand to stretch it |
| UPS charge below 50 % | On battery: the charge is estimated from the battery voltage, which sags under load, so watch the runtime instead. Right after an outage: the UPS is recharging, no action |
| UPS runtime below 15 min | Nothing shuts down by itself (monitor-only). Shut down cleanly by hand while there is time: on the telemetry VM `docker compose stop`, then on the UPS host `shutdown -h now` (Proxmox stops the VM first). If it fires while on mains, the battery is worn: test or replace it |
| UPS unreadable | `upsc` fails on the host: driver crashed, USB cable, or upsd down. `upsc <ups>@localhost` and `journalctl -u 'nut*' -n 50` there |
| UPS metrics stale | `ups-metrics.sh` or its timer stopped, so the graphs show old values. `systemctl status cointmu-ups-metrics.timer cointmu-ups-metrics.service` and `journalctl -u cointmu-ups-metrics -n 20` on the host (it names a wrong directory group or mode) |
| UPS data missing | Nothing from the UPS host for 5 min: the host is down, Alloy stopped, the network is down, or the push is refused. "Logs are not arriving" below applies to the metrics push as well (`journalctl -u alloy` on the host: 401/403). After a power-fail shutdown it fires until the host is back. On a fresh deployment it fires until the host ships metrics |

### After the battery ran out (or a shutdown by hand)

1. Did the UPS host come back, and the telemetry VM with it (it starts on boot)? Check in the Proxmox UI.
2. On the VM: `docker compose ps`, then `scripts/healthcheck.sh`. After a hard power loss also
   `docker compose logs --tail=50 postgres` (crash recovery should say "database system is ready").
3. In Grafana "UPS": data again, and charge rising. "UPS data missing" resolves once the host pushes.

### Silence a node that is down on purpose

"Host silent" looks back 24 hours, so a node that is shut down on purpose keeps it firing (repeated
every 12 h) until its last line is a day old. Silence that host only. As an org Editor or Admin:
Grafana → Alerting → Silences → New silence, with matchers `alertname = Host silent` and
`host = <name>` and a comment saying why.

- **Maintenance:** set the duration to the window, and expire the silence as soon as the node ships
  logs again.
- **Node retired:** about 25 hours. After that the host has dropped out of the 24-hour window and the
  rule stops on its own. Let the silence expire; never leave a permanent one.
- **Never silence by `alertname` alone:** that hides every host.

## Restore from backup

```bash
scripts/restore.sh backup/glitchtip-<UTC>.sql.gz   # type "restore" to confirm
```

Stops web and proxy, recreates the database from the dump, starts them again.

### Restore drill (quarterly)

Proves that the off-VM copies decrypt and load, without touching the VM. Run it on a workstation that
has Docker, this repository and the age key. The plaintext never touches the disk: both commands
decrypt into a pipe.

```bash
rsync -a backup-host:/srv/cointmu-telemetry/offsite/ drill/
# newest dump into a throwaway Postgres (no network, removed afterwards): tables + row counts
scripts/restore-test.sh "$(ls drill/glitchtip-*.sql.gz.age | tail -1)" cointmu-backup.key
# newest config bundle: must list .env, certs/ (server.key, server.crt) and nginx/local/
age -d -i cointmu-backup.key "$(ls drill/config-*.tar.gz.age | tail -1)" | tar -tzf -
rm -rf drill
```

Write down the date, the dump's name, the row counts and the load time it printed. The first drill
also sets the RTO in README.md ("Backups"). If the drill fails, fixing the backups comes before
anything else.

### Rebuild on a new VM

The age key stays on your workstation: you decrypt there and stream the plaintext over SSH.

1. On the new VM: Docker Engine, `git clone` into `/opt/CointMU-Telemetry`, and the host group
   (`sudo groupadd --system cointmu-tls`, README.md "Deploy" step 2). Don't create `.env` or keys;
   they come from the bundle.
2. From the workstation, unpack the newest config bundle into the repository folder:
   ```bash
   age -d -i cointmu-backup.key config-<UTC>.tar.gz.age \
     | ssh <vm> 'cd /opt/CointMU-Telemetry && tar -xzf -'
   ```
   With the default umask (022), tar restores the original modes: `.env` 600, and `server.crt` and
   the `*.conf` files readable by the proxy. Don't add a stricter umask here.
3. On the VM, give the TLS key and agent logins to the new host group:
   ```bash
   TLS_GID=$(getent group cointmu-tls | cut -d: -f3) && sed -i "s/^TLS_GID=.*/TLS_GID=$TLS_GID/" .env
   sudo chgrp "$TLS_GID" certs/server.key nginx/local/loki-agents.htpasswd
   chmod 640 certs/server.key nginx/local/loki-agents.htpasswd
   ```
   If the VM's address changed: `BIND_IP` and `GLITCHTIP_HOST` in `.env`, then `scripts/gen-cert.sh
   renew IP:<new>` (same key, same pin; "Certificate renewal" above). A new address also changes the
   DSN, which needs an app release.
4. Firewall (README.md), then `docker compose up -d`.
5. From the workstation, put the newest dump on the VM, then restore it there:
   ```bash
   age -d -i cointmu-backup.key glitchtip-<UTC>.sql.gz.age \
     | ssh <vm> 'cd /opt/CointMU-Telemetry && umask 077 && mkdir -p backup && cat > backup/glitchtip-<UTC>.sql.gz'
   ssh -t <vm> 'cd /opt/CointMU-Telemetry && scripts/restore.sh backup/glitchtip-<UTC>.sql.gz'
   ```
6. Cron lines (README.md), `install -d -m 700 state`. If the certificate was renewed, copy the new
   `certs/server.crt` to every node agent ("Server certificate changed").

## Disk full

- `docker system df -v` and `du -sh backup/` to see what grew (`loki-data` is the log stack).
- Lower `GLITCHTIP_RETENTION_DAYS` in `.env`, then `docker compose up -d web`. The
  cleanup runs as a periodic task in the all-in-one container.
- Old dumps can be removed from `backup/` once copied off the VM.
- Loki: lower `LOKI_RETENTION_PERIOD` ("Retention" below). To drop one noisy host right away, ask
  the compactor (deleted within about `retention_delete_delay`, 2 h):
  ```bash
  # query is {host="<host>"} URL-encoded; replace <host>
  docker compose exec grafana wget -qO- --post-data= \
    "http://loki:3100/loki/api/v1/delete?query=%7Bhost%3D%22<host>%22%7D&start=$(date -d '-30 days' +%s)"
  docker compose exec grafana wget -qO- http://loki:3100/loki/api/v1/delete   # lists requests
  ```
- Prometheus: lower `PROMETHEUS_RETENTION_SIZE` or `PROMETHEUS_RETENTION_TIME` in `.env`, then
  `docker compose up -d prometheus`. Prometheus deletes whole blocks once a limit is passed, so the
  disk use drops in steps, not at once.
- Emergency: `docker compose stop loki grafana`. GlitchTip and its ingest keep running, and
  the agents keep their logs in their WAL (up to 24 h) until Loki is back.

## Upgrade Loki, Prometheus or Grafana

Dependabot opens the PRs (tag + digest in `compose.yml`). Read the release notes (Loki:
[upgrade guide](https://grafana.com/docs/loki/latest/setup/upgrade/), Prometheus:
[release notes](https://github.com/prometheus/prometheus/releases), Grafana: "What's new").
CI runs `promtool check config` with the new image, then:

```bash
docker compose pull loki prometheus grafana && docker compose up -d loki prometheus grafana
docker compose ps prometheus            # healthy
```

Loki keeps its data in `loki-data`, and Prometheus in `prometheus-data`. A Prometheus restart is a gap
of a few seconds: the agents buffer and replay it. A Grafana major upgrade migrates its SQLite database
on start. For a Prometheus **major** upgrade (3 → 4), read its migration guide first.

## Upgrade Alloy on a node

Alloy is held at a pinned version because the WAL is experimental. On a workstation first, set
`ALLOY_IMAGE` in `agents/alloy/check-redaction.sh` to the new version and run it. Then on each node:

```bash
# <version> from apt-cache madison alloy, e.g. 1.22.0-1; confold keeps our /etc/default/alloy
sudo apt-mark unhold alloy && sudo apt-get update
sudo apt-get install -y -o Dpkg::Options::=--force-confold alloy=<version>
sudo apt-mark hold alloy && sudo systemctl restart alloy
journalctl -u alloy -n 50 --no-pager
```

## Upgrade GlitchTip or Postgres

1. Run `scripts/backup.sh` first.
2. Read the GlitchTip release notes ([glitchtip.com/blog](https://glitchtip.com/blog)) for
   breaking changes. Dependabot opens a weekly PR that bumps the tag and digest in
   `compose.yml`; to bump by hand, change both, taking the digest from
   `docker buildx imagetools inspect <image>:<tag>` (the top-level `Digest`).
3. `docker compose pull && docker compose up -d`. GlitchTip runs its migrations on start.
4. Postgres **major** upgrades (18 → 19) need a dump and restore into a fresh volume.
   Minor tags (18.6 → 18.7) only need a pull and restart.

## Host patching (VM and node servers)

Security updates install themselves; everything that restarts services is done by hand.

```bash
sudo apt-get install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades      # "Yes": writes 20auto-upgrades
sudoedit /etc/apt/apt.conf.d/50unattended-upgrades
```

In `50unattended-upgrades`, allow only the security pockets, never upgrade Docker, and never reboot:

```
Unattended-Upgrade::Allowed-Origins {
        "${distro_id}:${distro_codename}-security";
        "${distro_id}ESMApps:${distro_codename}-apps-security";
        "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::Package-Blacklist {
        "docker-ce"; "docker-ce-cli"; "containerd.io";
        "docker-buildx-plugin"; "docker-compose-plugin"; "docker.io";
};
Unattended-Upgrade::Automatic-Reboot "false";
```

Check it: `sudo unattended-upgrade --dry-run --debug 2>&1 | grep -iE 'allowed origins|blacklist|held'`.

- **Alloy (node servers):** `apt-mark hold alloy` is respected, and Grafana's apt repository is not
  a security pocket anyway. Alloy stays at its pinned version until "Upgrade Alloy on a node".
- **Docker Engine (VM), by hand:** restarting the engine restarts every container (`unless-stopped`
  brings them back), so ingest is down for about a minute. The apps queue their reports meanwhile.
  ```bash
  sudo apt-get update
  sudo apt-get install --only-upgrade docker-ce docker-ce-cli containerd.io \
    docker-buildx-plugin docker-compose-plugin
  docker compose ps                          # all healthy again
  sudo iptables -S DOCKER-USER | grep ctorigdstport   # the cointmu rules (README.md, Firewall)
  ```
  The `DOCKER-USER` rules come from `/etc/ufw/after.rules`, loaded by ufw at boot and on
  `ufw reload`. If the `grep` prints nothing, run `sudo ufw reload` before anything else: without
  them the HTTPS port is open to every network.
- **Kernel and library updates** need a reboot (`/var/run/reboot-required` exists;
  `/var/run/reboot-required.pkgs` lists why). Reboot in a fixed weekly window outside lab hours:
  - **The VM:** containers come back by themselves. Afterwards: `docker compose ps`, the
    `iptables` check above and `scripts/healthcheck.sh`. The apps queue reports during the reboot.
  - **Node servers:** one at a time, so the network keeps a bootnode. Alloy's WAL keeps the lines
    meanwhile. If a node stays down longer than 15 minutes, "Host silent" fires: silence it first
    ("Silence a node that is down on purpose").

## Moving to nginx/local/ (deployments from before the log stack)

The per-host nginx files now live in one bind-mounted folder, so an edit that replaces the file
(`sed -i`, most editors) is seen after `nginx -s reload`. The proxy refuses to start until all
three files exist:

```bash
mv nginx/admin-allow.conf nginx/local/admin-allow.conf
cp nginx/local/agent-allow.conf.example nginx/local/agent-allow.conf
TLS_GID=$(sed -n 's/^TLS_GID=//p' .env)
sudo install -m 640 -o "$USER" -g "$TLS_GID" /dev/null nginx/local/loki-agents.htpasswd
# .env: add GRAFANA_ADMIN_PASSWORD (openssl rand -base64 24) and LOKI_RETENTION_PERIOD=720h
docker compose up -d
```

## Moving to the admin access audit log (deployments from before it)

The proxy now logs allowed admin requests and failed log pushes with the client address, limits
nginx's error log to critical errors, and keeps its log longer (README.md, "IP addresses" and
"Logs"). The logging options only apply to a recreated container:

```bash
git pull
docker compose up -d proxy        # recreates the proxy (a few seconds without ingest)
# from an admin machine, open the dashboard, then:
docker compose logs --no-log-prefix --since 5m proxy | grep -E '^[0-9a-f.:]+ '   # your address
```

Recreating the proxy discards its current log (it had no addresses anyway); the 30-day window
starts from this point.

## Moving to encrypted backups (deployments from before it)

Until this is done, `backup.sh` keeps writing plaintext dumps and warns on stderr that the off-VM
copy is disabled. The old cron line, which copies all of `backup/`, keeps working in the meantime.

1. `sudo apt install age` on the VM.
2. On a workstation, **not** the VM: `age-keygen -o cointmu-backup.key`. Keep that file offline
   (password manager, safe); it is the only way to read the backups.
3. **In one step**, so the old line never runs with the recipient set:
   ```bash
   install -d -m 700 state
   nano .env      # BACKUP_AGE_RECIPIENT=<the printed public key>; add the line if it is missing
   crontab -e     # replace the backup line with the one in README.md ("Backups")
   ```
4. Run the new cron line once by hand, then check:
   ```bash
   ls -l backup/offsite/ state/backup-offsite.ok
   ```
5. On backup-host, delete the old **plaintext** copies (everything in `/srv/cointmu-telemetry/`
   except `offsite/`). The new line copies into `offsite/` only, so `--delete` never removes them.
6. Run the restore drill ("Restore drill" above).

## Moving to Discord alerting (deployments from before it)

1. In Discord, create one webhook each in #app-errors, #node-logs and #infra (README.md, "Alerts").
2. Add `DISCORD_WEBHOOK_APP_ERRORS`, `DISCORD_WEBHOOK_NODE_LOGS` and `DISCORD_WEBHOOK_INFRA` to
   `.env` (see `.env.example`). Leave one empty to keep that source off.
3. Check outbound HTTPS to discord.com: test 1 in README.md ("Alerts"). Without it nothing arrives.
4. `docker compose up -d`. This creates the `alerts-egress` network and recreates Grafana with its
   alert rules.
5. `scripts/init-project.sh <owner email>`. It prints the same `DSN=` line as before and turns on
   the GlitchTip alert.
6. Add the health check cron line (README.md, "Alerts"). Its backup check needs the stamp from
   "Moving to encrypted backups"; until that is done it reports "off-VM copy not configured".
7. Create the per-admin Grafana users ("Grafana users") and stop using `admin` day to day.

## Moving to UPS monitoring (deployments from before it)

The pieces came in this order; do the steps that are not done yet, in order. Host steps are in
[agents/ups/README.md](agents/ups/README.md).

1. **Discord from the UPS host (path A).** Nothing changes on the VM. On the UPS host: "Discord
   notifier", which also starts `upsmon`, monitor-only.
2. **UPS journal in Loki (path B).** Nothing to restart on the VM. Add the host's log login and
   address there ("On the telemetry VM", logs), then on the host: "Alloy".
3. **Prometheus and the metrics push endpoint.** **The proxy refuses to start without
   `nginx/local/metrics-agents.htpasswd`**, so create it before recreating the proxy:
   ```bash
   git pull
   TLS_GID=$(sed -n 's/^TLS_GID=//p' .env)
   sudo install -m 640 -o "$USER" -g "$TLS_GID" /dev/null nginx/local/metrics-agents.htpasswd
   nano .env      # add PROMETHEUS_RETENTION_TIME=90d and PROMETHEUS_RETENTION_SIZE=2GB
   docker compose up -d           # creates prometheus, recreates grafana and proxy
   docker compose ps              # prometheus healthy
   # from a campus laptop (not an agent): the endpoint answers 403
   curl -sk -o /dev/null -w '%{http_code}\n' -X POST https://<VM>/prometheus/api/v1/write
   ```
   `scripts/backup-config.sh` already covers the new htpasswd (all of `nginx/local/`). Prometheus
   data is not backed up (README.md, "Backups").
4. **UPS metrics, dashboard and #ups alerts.** Add the host's metrics login ("On the telemetry VM",
   metrics), then on the host: "Metrics collector" and the metrics part of "Alloy". Then on the VM:
   ```bash
   git pull
   nano .env      # DISCORD_WEBHOOK_UPS=<Grafana's #ups webhook>; empty = off
   docker compose up -d grafana
   ```
   Grafana fires "UPS data missing" until the host ships metrics, so do the host part first or set
   the webhook only afterwards.

## Node logs (Loki + Grafana)

### Is Loki up?

Loki's image has no shell, so there is no healthcheck; ask it from the Grafana container:

```bash
docker compose exec grafana wget -qO- http://loki:3100/ready     # "ready"
```

### Add a node agent

1. `scripts/agent-cred.sh add <host>-1` (prints the password once).
2. Add the node's address to `nginx/local/agent-allow.conf` (`<ip> 1;`), then
   `docker compose exec proxy nginx -s reload`.
3. Install Alloy on the node: [agents/alloy/README.md](agents/alloy/README.md).

### Rotate an agent login

Alloy drops batches answered with 401, so add the new login before removing the old one:

1. `scripts/agent-cred.sh add <host>-2`
2. On the node: put the new password in `/etc/alloy/push-password`, set
   `LOKI_PUSH_USER=<host>-2` in `/etc/default/alloy`, `sudo systemctl restart alloy`.
3. Check new lines arrive (Grafana, or `journalctl -u alloy`).
4. `scripts/agent-cred.sh revoke <host>-1`

The UPS host also has a **metrics login**, rotated the same way with the kind `metrics`:
`scripts/agent-cred.sh add <host>-2 metrics`, the new password in `/etc/alloy/metrics-password`,
`METRICS_PUSH_USER=<host>-2`, restart Alloy, check the "UPS" dashboard, then
`scripts/agent-cred.sh revoke <host>-1 metrics`. The two logins are separate: a log login cannot
write metrics, and the other way round.

If a password leaked, revoke first and accept the gap: the node's lines between revoke and
step 2 are lost (Grafana shows a gap; the node's own log files still have them).

### Server certificate changed (renew or promote)

The agents trust `certs/server.crt` itself, so after `gen-cert.sh renew` or `promote`, copy it to
every node: `sudo install -m 644 server.crt /etc/alloy/telemetry.crt && sudo systemctl restart alloy`.
Until then their pushes fail TLS verification; that is retried, so the lines wait in the WAL
(up to 24 h).

### Retention

`LOKI_RETENTION_PERIOD` in `.env` (default `720h`, 30 days), then `docker compose up -d loki`.
The compactor applies it within about 10 minutes plus `retention_delete_delay` (2 h).

### Grafana users

Every admin has their own Grafana login. `admin` is break-glass only. New users are Viewers
(`GF_USERS_AUTO_ASSIGN_ORG_ROLE`). Sign-up is off, and the API takes no basic auth. Roles:

- **1–2 named admins:** Grafana Admin (server administrator) and org role Admin. They manage users
  and silences.
- **Everyone else:** Viewer (dashboards and Explore). Alert rules and the contact point are
  provisioned from this repository, so nobody needs to edit them in the UI.

Add an admin, logged in as a Grafana Admin:
1. Administration → Users and access → Users → New user: name, e-mail, username and a temporary
   password. Send the password over a private channel; they change it under Profile → Change
   password.
2. For a named admin only: on the user's page, set the organization role to Admin and turn on Grafana
   Admin.

Remove one: Administration → Users and access → Users → the user → Delete user. Do it on the day
they leave the admin group, and remove their address from `nginx/local/admin-allow.conf` too.

### Break-glass admin

Log in as `admin` only when no named Grafana Admin can, for example when all of them are locked out
or have left, and only to restore a named admin. Afterwards rotate its password (below) and note
who used it and why.

### Break-glass admin password

`GRAFANA_ADMIN_PASSWORD` is used only when Grafana's database is first created. To change it later:

```bash
read -rsp 'new password: ' PW; echo
printf '%s\n' "$PW" | docker compose exec -T grafana grafana cli admin reset-admin-password --password-from-stdin
unset PW    # and update .env, so a rebuilt Grafana gets the same one
```

### Logs are not arriving

1. On the node: `journalctl -u alloy -n 100`. `status=401` wrong login or password file,
   `403` the node's address is not in `agent-allow.conf`, `413` batch too large, TLS errors mean
   `telemetry.crt` is not the VM's current certificate. 401/403/413 batches are dropped.
2. `curl -s 127.0.0.1:12345/metrics | grep -E '^loki_write_(sent|dropped)_entries_total'` on the node.
3. On the VM: `docker compose logs --tail=50 proxy | grep /loki/` shows the push status codes;
   429 means rate limited (retried).
4. Loki up? (above). `docker compose logs --tail=50 loki` for rejected samples or limits.
5. Files: `sudo -u alloy head -1 <log file>` on the node must work; `GETH_LOG_FILES` must match
   the live file only.
