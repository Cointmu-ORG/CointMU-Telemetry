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

No app release needed. `renew` also resets the key permissions (`server.key` 640 with
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

- `docker system df` and `du -sh backup/` to see what grew.
- Lower `GLITCHTIP_RETENTION_DAYS` in `.env`, then `docker compose up -d web`. The
  cleanup runs as a periodic task in the all-in-one container.
- Old dumps can be removed from `backup/` once copied off the VM.

## Upgrade GlitchTip or Postgres

1. Run `scripts/backup.sh` first.
2. Read the GlitchTip release notes ([glitchtip.com/blog](https://glitchtip.com/blog)) for
   breaking changes. Bump the pinned tag in `compose.yml` through a PR.
3. `docker compose pull && docker compose up -d`. GlitchTip runs its migrations on start.
4. Postgres **major** upgrades (18 → 19) need a dump and restore into a fresh volume.
   Minor tags (18.6 → 18.7) only need a pull and restart.
