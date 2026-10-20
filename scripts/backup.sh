#!/usr/bin/env bash
# Dumps the GlitchTip database to backup/glitchtip-<UTC time>.sql.gz and prunes
# old dumps: every dump from the last 7 days, plus Sunday dumps for 28 days.
# Run daily from cron, then copy backup/ off this VM (see README.md).
set -euo pipefail

cd "$(dirname "$0")/.."
readonly BACKUP_DIR=backup
readonly DAILY_KEEP_DAYS=7
readonly WEEKLY_KEEP_DAYS=28
readonly SUNDAY=7

umask 077
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
target="$BACKUP_DIR/glitchtip-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"

# Write to a temp name first so a failed dump never looks like a good one.
docker compose exec -T postgres pg_dump -U glitchtip -d glitchtip --no-owner \
  | gzip > "$target.partial"
mv "$target.partial" "$target"
echo "wrote $target ($(du -h "$target" | cut -f1))"

now=$(date -u +%s)
for dump in "$BACKUP_DIR"/glitchtip-*.sql.gz; do
  age_days=$(( (now - $(stat -c %Y "$dump")) / 86400 ))
  weekday=$(date -u -d "@$(stat -c %Y "$dump")" +%u)
  if (( age_days >= WEEKLY_KEEP_DAYS )) \
    || (( age_days >= DAILY_KEEP_DAYS && weekday != SUNDAY )); then
    rm -- "$dump"
    echo "pruned $dump"
  fi
done
