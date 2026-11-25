#!/usr/bin/env bash
# Watches the telemetry VM and its Proxmox host from a machine that is neither,
# because nothing on them can report their own death. Run every minute by
# cointmu-watchdog.timer (scopes/watchdog/README.md). One of these at a time:
#   pve_down         the Proxmox host and the VM are unreachable  -> #servers
#   vm_down          the host answers, the VM does not            -> #infra
#   stack_unhealthy  the VM answers, GlitchTip or Grafana do not  -> #infra
# A condition is posted once after CONFIRM_RUNS runs in a row, and its end once, to
# the same channel. It counts as posted only when Discord accepted it, so a loss
# of this machine's own network posts nothing: by the time posting works again,
# the hosts answer again. Messages carry names, never addresses.
set -euo pipefail

readonly CONFIG_FILE="${WATCHDOG_CONFIG:-/etc/cointmu-watchdog/cointmu-watchdog.conf}"
readonly WEBHOOK_DIR="${WATCHDOG_WEBHOOK_DIR:-/etc/cointmu-watchdog}"
readonly STATE_DIR="${WATCHDOG_STATE_DIR:-/var/lib/cointmu-watchdog}"
readonly METRICS_FILE="${WATCHDOG_METRICS_FILE:-/var/lib/cointmu-infra/watchdog/watchdog.prom}"
readonly CA_FILE="${WATCHDOG_CA_FILE:-/etc/alloy/telemetry.crt}"
readonly CONFIRM_RUNS=3
readonly TIMEOUT_SECONDS=5
readonly WEBHOOK_PATTERN='^https://(discord\.com|discordapp\.com)/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$'
# Anything else in a message is replaced, so the JSON needs no escaping.
readonly MESSAGE_CHARS='A-Za-z0-9 .,:/()_*-'

die() { echo "watchdog: $*" >&2; exit 1; }
conf() { sed -n "s/^$1=//p" "$CONFIG_FILE" | tail -1; }

# shellcheck disable=SC2016 # expanded by the inner bash
tcp_open() { timeout "$TIMEOUT_SECONDS" bash -c '</dev/tcp/"$1"/"$2"' _ "$1" "$2" 2>/dev/null; }

# $1 address, $2 ports: any of them answers.
any_port_open() {
  local port
  for port in $2; do if tcp_open "$1" "$port"; then return 0; fi; done
  return 1
}

# The VM's certificate is the only trust anchor.
url_ok() { curl -fsS --max-time "$TIMEOUT_SECONDS" --cacert "$CA_FILE" -o /dev/null "$1" 2>/dev/null; }

current_condition() {
  if any_port_open "$(conf WATCHDOG_VM)" "$(conf WATCHDOG_VM_PORTS)"; then
    if url_ok "$(conf WATCHDOG_VM_URL)/_health/" && url_ok "$(conf WATCHDOG_VM_URL)/grafana/api/health"; then echo ok; else echo stack_unhealthy; fi
  elif any_port_open "$(conf WATCHDOG_PVE)" "$(conf WATCHDOG_PVE_PORTS)"; then echo vm_down
  else echo pve_down; fi
}

channel_of() { if [[ "$1" == pve_down ]]; then echo servers; else echo infra; fi; }

describe() {
  case "$1" in
    pve_down) echo "Proxmox host $(conf WATCHDOG_PVE_NAME) is unreachable, and the telemetry VM on it: no other alerts until it is back" ;;
    vm_down) echo "telemetry VM is unreachable, its host $(conf WATCHDOG_PVE_NAME) answers: no other alerts until it is back" ;;
    stack_unhealthy) echo "telemetry VM answers, but GlitchTip or Grafana does not" ;;
  esac
}

describe_recovery() {
  case "$1" in
    pve_down) echo "Proxmox host $(conf WATCHDOG_PVE_NAME) is reachable again" ;;
    vm_down) echo "telemetry VM is reachable again" ;;
    stack_unhealthy) echo "GlitchTip and Grafana answer again" ;;
  esac
}

# $1 channel, $2 text.
post() {
  local webhook text
  webhook=$(cat "$WEBHOOK_DIR/webhook-$1" 2>/dev/null) || webhook=""
  if [[ -z "$webhook" ]]; then echo "no webhook-$1 in $WEBHOOK_DIR, not posted: $2" >&2; return 1; fi
  [[ "$webhook" =~ $WEBHOOK_PATTERN ]] || die "webhook-$1 is not a Discord webhook URL"
  text=$(printf '%s' "$2" | tr -c "$MESSAGE_CHARS" '?')
  # The URL goes in through a config file descriptor, never the command line.
  printf '{"content":"%s","allowed_mentions":{"parse":[]}}' "$text" \
    | curl -fsS --max-time "$TIMEOUT_SECONDS" -o /dev/null -H 'Content-Type: application/json' \
        --data-binary @- -K <(printf 'url = "%s"\n' "$webhook")
}

read_state() { cat "$STATE_DIR/$1" 2>/dev/null || true; }

# How many runs in a row saw $1, this one included.
count_runs() {
  local last runs
  read -r last runs < <(read_state seen) || true
  if [[ "${last:-}" == "$1" ]]; then runs=$((runs + 1)); else runs=1; fi
  echo "$1 $runs" > "$STATE_DIR/seen"
  echo "$runs"
}

write_metrics() {
  umask 027
  printf 'infra_collector_timestamp_seconds{collector="watchdog"} %s\n' "$(date +%s)" > "$METRICS_FILE.tmp"
  mv "$METRICS_FILE.tmp" "$METRICS_FILE"
}

[[ -r "$CONFIG_FILE" ]] || die "cannot read $CONFIG_FILE"
condition=$(current_condition)
runs=$(count_runs "$condition")
posted=$(read_state posted)
if [[ "$condition" != ok ]]; then echo "$condition ($runs in a row)"; fi
if (( runs >= CONFIRM_RUNS )) && [[ "$condition" != "${posted:-ok}" ]]; then
  if [[ -n "$posted" ]] && post "$(channel_of "$posted")" "**OK** $(describe_recovery "$posted")"; then
    : > "$STATE_DIR/posted"
    posted=""
  fi
  if [[ -z "$posted" && "$condition" != ok ]] && post "$(channel_of "$condition")" "**FAIL** $(describe "$condition")"; then
    echo "$condition" > "$STATE_DIR/posted"
  fi
fi
write_metrics
