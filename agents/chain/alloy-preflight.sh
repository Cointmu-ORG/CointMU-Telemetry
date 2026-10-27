#!/usr/bin/env bash
# Checks a geth node is ready for the agents/alloy/config.alloy that also
# pushes chain metrics, BEFORE that config replaces the running one
# (agents/chain/README.md, "Alloy"). Run as root:
#
#   sudo agents/chain/alloy-preflight.sh && sudo install -m 644 ../alloy/config.alloy /etc/alloy/config.alloy
#
# Prints every missing piece and exits 1, so "&&" leaves the running config
# alone. Without these, Alloy 1.21 still starts and keeps pushing logs, but
# every metrics batch fails with only a warning in its journal.
set -euo pipefail

readonly ENV_FILE=/etc/default/alloy
readonly PASSWORD_FILE=/etc/alloy/metrics-password
readonly PASSWORD_GROUP=alloy
readonly PASSWORD_MODE=640
readonly URL_PATTERN='^https://[^/]+/prometheus/api/v1/write$'

problems=0
problem() { echo "STOP: $*" >&2; problems=$((problems + 1)); }

env_value() { sed -n "s/^$1=//p" "$ENV_FILE" | tail -1 | tr -d '"'; }

(( EUID == 0 )) || { echo "run as root (sudo)" >&2; exit 2; }

if [[ ! -s "$PASSWORD_FILE" ]]; then
  problem "$PASSWORD_FILE missing or empty: scripts/agent-cred.sh add <host>-1 metrics on the VM, then install it (README.md)"
elif [[ "$(stat -c '%G %a' "$PASSWORD_FILE")" != "$PASSWORD_GROUP $PASSWORD_MODE" ]]; then
  problem "$PASSWORD_FILE is $(stat -c '%G %a' "$PASSWORD_FILE"), expected $PASSWORD_GROUP $PASSWORD_MODE"
fi

if [[ ! -r "$ENV_FILE" ]]; then
  problem "cannot read $ENV_FILE"
else
  [[ "$(env_value METRICS_PUSH_URL)" =~ $URL_PATTERN ]] \
    || problem "METRICS_PUSH_URL in $ENV_FILE is not https://<TELEMETRY_IP>/prometheus/api/v1/write"
  [[ -n "$(env_value METRICS_PUSH_USER)" ]] || problem "METRICS_PUSH_USER in $ENV_FILE is empty"
fi

(( problems == 0 )) || { echo "nothing changed; fix the above, then run this again" >&2; exit 1; }
echo "ok: metrics password and METRICS_PUSH_* in place"
