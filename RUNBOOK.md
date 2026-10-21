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
the new `certs/server.crt` to every agent ("Server certificate changed" below).
`renew` also resets the key permissions (`server.key` 640 with
group `TLS_GID`, everything else 600), so run it once on a server whose key was made by
an older `gen-cert.sh` (mode 644 or group 101). Also use this when the server IP changes, together with
`BIND_IP`/`GLITCHTIP_HOST` in `.env`. A new IP also changes the DSN, which does need an
app release.

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
- Emergency: `docker compose stop loki grafana`. GlitchTip and its ingest keep running, and
  the agents keep their logs in their WAL (up to 24 h) until Loki is back.

## Upgrade Loki or Grafana

Dependabot opens the PRs (tag + digest in `compose.yml`). Read the release notes (Loki:
[upgrade guide](https://grafana.com/docs/loki/latest/setup/upgrade/), Grafana: "What's new"),
then `docker compose pull loki grafana && docker compose up -d loki grafana`. Loki keeps its
data in `loki-data`; a Grafana major upgrade migrates its SQLite database on start.

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

### Grafana admin password

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
