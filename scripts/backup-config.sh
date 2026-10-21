#!/usr/bin/env bash
# Writes this VM's git-ignored configuration (.env, certs/, nginx/local/) as an
# age-encrypted bundle, backup/offsite/config-<UTC time>.tar.gz.age, and keeps
# the newest 8. These files hold every secret of the deployment: the TLS key
# behind the app's pin, the database password, the agent logins and the
# Discord webhooks. So the bundle is never written unencrypted, not even
# briefly. Run daily after backup.sh (README.md, Backups).
#
#   scripts/backup-config.sh
#
# Unpack (RUNBOOK.md, "Rebuild on a new VM"):
#   age -d -i <identity file> config-<time>.tar.gz.age | tar -xzf -
set -euo pipefail

cd "$(dirname "$0")/.."
readonly OFFSITE_DIR=backup/offsite
readonly ENV_FILE=.env
readonly KEEP_BUNDLES=8
readonly CONFIG_PATHS=(.env certs nginx/local)
# age1 followed by 58 bech32 characters.
readonly RECIPIENT_PATTERN='^age1[02-9ac-hj-np-z]{58}$'

die() { echo "$*" >&2; exit 1; }

[[ -f "$ENV_FILE" ]] || die "no $ENV_FILE in $PWD"
recipient=$(sed -n 's/^BACKUP_AGE_RECIPIENT=//p' "$ENV_FILE")
[[ "$recipient" =~ $RECIPIENT_PATTERN ]] \
  || die "BACKUP_AGE_RECIPIENT in $ENV_FILE is empty or not an age public key (age1...)"
command -v age >/dev/null || die "age is not installed (sudo apt install age)"
for path in "${CONFIG_PATHS[@]}"; do
  [[ -e "$path" ]] || die "missing $path"
done

umask 077
mkdir -p "$OFFSITE_DIR"
chmod 700 backup "$OFFSITE_DIR"
target="$OFFSITE_DIR/config-$(date -u +%Y%m%dT%H%M%SZ).tar.gz.age"

tar -czf - "${CONFIG_PATHS[@]}" | age -r "$recipient" -o "$target.partial"
mv "$target.partial" "$target"
echo "wrote $target"

# The names sort by UTC time, so the glob lists the oldest first.
bundles=("$OFFSITE_DIR"/config-*.tar.gz.age)
excess=$(( ${#bundles[@]} - KEEP_BUNDLES ))
for (( i = 0; i < excess; i++ )); do
  rm -- "${bundles[i]}"
  echo "pruned ${bundles[i]}"
done
