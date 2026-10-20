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
5. On the laptop: Settings → Privacy & Diagnostics shows reporting on and the queue.
   Reports are held until the first-run notice is dismissed.

## Restore from backup

```bash
scripts/restore.sh backup/glitchtip-<UTC>.sql.gz   # type "restore" to confirm
```

Stops web and proxy, recreates the database from the dump, starts them again.

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
