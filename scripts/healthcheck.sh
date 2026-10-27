#!/usr/bin/env bash
# VM health check, run from cron every 5 minutes (README.md, Alerts). Posts to
# Discord #infra through DISCORD_WEBHOOK_INFRA from .env, once when a check
# starts failing and once when it recovers. It needs neither Grafana nor Loki,
# so it still reports when they are down. Checks:
#   disk      every filesystem holding /, this folder or Docker's data root
#   services  every compose service running, and healthy where it has a
#             healthcheck; Loki through /ready from the grafana container.
#             For 15 minutes after a container starts (an upgrade or a
#             restart), "starting" or Loki not ready yet does not count;
#             not running or unhealthy always counts at once
#   backup    state/backup-offsite.ok (touched by the backup cron line after
#             the copy left the VM) younger than 26 hours
#   cert      certificate expires in 60 days or more (scripts/gen-cert.sh status)
#
#   scripts/healthcheck.sh     prints failing checks; exit 1 if any fails
#
# State per check lives in state/healthcheck/. With DISCORD_WEBHOOK_INFRA
# empty nothing is posted and the state is left alone, so current failures are
# announced once a webhook is set. Messages carry no addresses, only this VM's
# host name, the check, its value and the LAN dashboard link.
set -euo pipefail

cd "$(dirname "$0")/.."
readonly ENV_FILE=.env
readonly STATE_DIR=state/healthcheck
readonly BACKUP_STAMP=state/backup-offsite.ok
readonly DISK_MAX_PERCENT="${DISK_MAX_PERCENT:-85}"
readonly BACKUP_MAX_AGE_HOURS=26
readonly CERT_MIN_DAYS=60
# Loki can take minutes to report ready after an upgrade or restart.
readonly STARTUP_GRACE_SECONDS=900
readonly POST_TIMEOUT_SECONDS=10
readonly SECONDS_PER_HOUR=3600
readonly WEBHOOK_PATTERN='^https://(discord\.com|discordapp\.com)/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$'
# Anything else in a message is replaced, so the JSON needs no escaping.
readonly MESSAGE_CHARS='A-Za-z0-9 .,:/%=()_*'

env_value() { sed -n "s/^$1=//p" "$ENV_FILE" 2>/dev/null || true; }

check_disk() {
  local root_dir mount percent failed=""
  root_dir=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null || echo /)
  while read -r mount percent; do
    (( ${percent%\%} >= DISK_MAX_PERCENT )) && failed+="$mount at $percent, "
  done < <(df -P / "$PWD" "$root_dir" | awk 'NR > 1 {print $6, $5}' | sort -u)
  [[ -z "$failed" ]] && return 0
  echo "${failed%, } (limit ${DISK_MAX_PERCENT}%)"
  return 1
}

# $1 service; succeeds if its container started less than
# STARTUP_GRACE_SECONDS ago.
in_startup_grace() {
  local container started
  container=$(docker compose ps -q "$1" 2>/dev/null) || return 1
  [[ -n "$container" ]] || return 1
  started=$(docker inspect -f '{{.State.StartedAt}}' "$container" 2>/dev/null) || return 1
  (( $(date +%s) - $(date -d "$started" +%s) < STARTUP_GRACE_SECONDS ))
}

check_services() {
  local service state health failed=""
  for service in $(docker compose config --services); do
    read -r state health < <(docker compose ps -a --format '{{.State}} {{.Health}}' "$service" 2>/dev/null) \
      || state="missing"
    if [[ "$state" != running ]]; then
      failed+="$service ${state:-missing}, "
    elif [[ "$service" == loki ]]; then
      # Read through grafana, so a fresh grafana gets the grace as well.
      docker compose exec -T grafana wget -qO- http://loki:3100/ready 2>/dev/null | grep -q '^ready' \
        || in_startup_grace loki || in_startup_grace grafana \
        || failed+="loki not ready (or grafana down), "
    elif [[ "$health" == starting ]] && in_startup_grace "$service"; then
      continue
    elif [[ -n "$health" && "$health" != healthy ]]; then
      failed+="$service $health, "
    fi
  done
  [[ -z "$failed" ]] && return 0
  echo "${failed%, }"
  return 1
}

check_backup() {
  [[ -f "$BACKUP_STAMP" ]] || { echo "off-VM copy not configured or never succeeded"; return 1; }
  local age_hours=$(( ($(date +%s) - $(stat -c %Y "$BACKUP_STAMP")) / SECONDS_PER_HOUR ))
  (( age_hours < BACKUP_MAX_AGE_HOURS )) && return 0
  echo "last off-VM copy ${age_hours} h ago (limit ${BACKUP_MAX_AGE_HOURS} h)"
  return 1
}

check_cert() {
  local days_left
  days_left=$(scripts/gen-cert.sh status 2>/dev/null | sed -n 's/^days_left=//p')
  [[ -n "$days_left" ]] || { echo "cannot read certs/server.crt"; return 1; }
  (( days_left >= CERT_MIN_DAYS )) && return 0
  echo "certificate expires in ${days_left} days (renew, RUNBOOK.md)"
  return 1
}

# $1 is the message text; newlines become \n in the JSON.
post() {
  local text payload
  text=$(printf '%s' "$1" | tr -c "$MESSAGE_CHARS"'\n-' '?' | sed ':a;N;$!ba;s/\n/\\n/g')
  payload=$(printf '{"content":"%s","allowed_mentions":{"parse":[]}}' "$text")
  # The URL goes in through a config file descriptor, never the command line.
  curl -fsS --max-time "$POST_TIMEOUT_SECONDS" -o /dev/null -H 'Content-Type: application/json' \
    --data-binary @- -K <(printf 'url = "%s"\n' "$webhook") <<<"$payload"
}

# $1 check name, $2 0 (ok) or 1 (failing), $3 detail. Posts on a change only.
report() {
  local name="$1" failing="$2" detail="$3" state_file="$STATE_DIR/$1" message
  local was_failing=0
  [[ -f "$state_file" ]] && was_failing=1
  if (( failing )); then
    any_failing=1
    echo "FAIL $name: $detail"
  fi
  (( failing == was_failing )) && return 0
  [[ -n "$webhook" ]] || return 0
  if (( failing )); then
    message="**FAIL** $name on $vm_name: $detail"$'\n'"$dashboard"
  else
    message="**OK** $name on $vm_name recovered"
  fi
  if post "$message"; then
    if (( failing )); then : > "$state_file"; else rm -f "$state_file"; fi
    echo "posted $( (( failing )) && echo FAIL || echo OK ) $name to Discord"
  else
    echo "could not post $name to Discord; retrying next run" >&2
  fi
}

webhook=$(env_value DISCORD_WEBHOOK_INFRA)
if [[ -n "$webhook" && ! "$webhook" =~ $WEBHOOK_PATTERN ]]; then
  echo "DISCORD_WEBHOOK_INFRA in $ENV_FILE is not a Discord webhook URL" >&2
  exit 1
fi
vm_name=$(hostname -s)
https_port=$(env_value HTTPS_PORT)
dashboard="https://$(env_value GLITCHTIP_HOST):${https_port:-443}/grafana/"
install -d -m 700 state "$STATE_DIR"

any_failing=0
status=0; detail=$(check_disk) || status=1; report disk "$status" "$detail"
status=0; detail=$(check_services) || status=1; report services "$status" "$detail"
status=0; detail=$(check_backup) || status=1; report backup "$status" "$detail"
status=0; detail=$(check_cert) || status=1; report cert "$status" "$detail"
exit "$any_failing"
