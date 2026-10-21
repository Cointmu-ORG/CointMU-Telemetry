#!/usr/bin/env bash
# Dumps the GlitchTip database to backup/glitchtip-<UTC time>.sql.gz, checks
# the gzip stream, and writes an age-encrypted copy to backup/offsite/. Only
# backup/offsite/ is copied off this VM (README.md, Backups). Both folders are
# pruned: every dump from the last 7 days, plus Sunday dumps for 28 days.
# Run daily from cron.
#
# The copy is encrypted to BACKUP_AGE_RECIPIENT from .env (a public key; the
# private key never lives on this VM). While it is empty the script keeps the
# old behaviour, plaintext dumps only, and warns on stderr, so a VM that has
# not migrated yet keeps working (RUNBOOK.md, "Moving to encrypted backups").
set -euo pipefail

cd "$(dirname "$0")/.."
readonly BACKUP_DIR=backup
readonly OFFSITE_DIR=backup/offsite
readonly ENV_FILE=.env
readonly DAILY_KEEP_DAYS=7
readonly WEEKLY_KEEP_DAYS=28
readonly SUNDAY=7
readonly SECONDS_PER_DAY=86400
# age1 followed by 58 bech32 characters.
readonly RECIPIENT_PATTERN='^age1[02-9ac-hj-np-z]{58}$'

die() { echo "$*" >&2; exit 1; }

recipient=""
if [[ -f "$ENV_FILE" ]]; then
  recipient=$(sed -n 's/^BACKUP_AGE_RECIPIENT=//p' "$ENV_FILE")
fi
if [[ -n "$recipient" ]]; then
  [[ "$recipient" =~ $RECIPIENT_PATTERN ]] || die "BACKUP_AGE_RECIPIENT in $ENV_FILE is not an age public key (age1...)"
  command -v age >/dev/null || die "age is not installed (sudo apt install age)"
fi

# Keeps every dump from the last DAILY_KEEP_DAYS, Sunday dumps until
# WEEKLY_KEEP_DAYS. Arguments: the dump files (an unmatched glob is skipped).
prune() {
  local dump age_days weekday now
  now=$(date -u +%s)
  for dump in "$@"; do
    [[ -e "$dump" ]] || continue
    age_days=$(( (now - $(stat -c %Y "$dump")) / SECONDS_PER_DAY ))
    weekday=$(date -u -d "@$(stat -c %Y "$dump")" +%u)
    if (( age_days >= WEEKLY_KEEP_DAYS )) \
      || (( age_days >= DAILY_KEEP_DAYS && weekday != SUNDAY )); then
      rm -- "$dump"
      echo "pruned $dump"
    fi
  done
}

umask 077
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
target="$BACKUP_DIR/glitchtip-$(date -u +%Y%m%dT%H%M%SZ).sql.gz"

# Write to a temp name first so a failed or truncated dump never looks like a
# good one; a bad .partial stays behind for inspection.
docker compose exec -T postgres pg_dump -U glitchtip -d glitchtip --no-owner \
  | gzip > "$target.partial"
gzip -t "$target.partial" || die "gzip check failed: $target.partial"
mv "$target.partial" "$target"
echo "wrote $target ($(du -h "$target" | cut -f1))"

if [[ -n "$recipient" ]]; then
  mkdir -p "$OFFSITE_DIR"
  chmod 700 "$OFFSITE_DIR"
  encrypted="$OFFSITE_DIR/$(basename "$target").age"
  age -r "$recipient" -o "$encrypted.partial" "$target"
  mv "$encrypted.partial" "$encrypted"
  echo "wrote $encrypted"
else
  echo "WARNING: BACKUP_AGE_RECIPIENT is empty: encrypted off-VM copy DISABLED" \
    "(see RUNBOOK.md, \"Moving to encrypted backups\")" >&2
fi

prune "$BACKUP_DIR"/glitchtip-*.sql.gz
prune "$OFFSITE_DIR"/glitchtip-*.sql.gz.age
