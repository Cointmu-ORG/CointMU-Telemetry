#!/usr/bin/env bash
# Network devices (switches) watched from this VM: ping and SSH probes through
# the blackbox exporter, ports and uptime over SNMPv3 through the snmp exporter
# (scopes/network/README.md). No agent, login or bundle: the device only needs
# SNMP switched on. Run as the admin user, never as root.
#
#   scripts/network.sh add <name> <ip> --auth <auth> [--ssh-port <n>]
#       <auth> is a name under auths: in scopes/network/snmp/auths.yml
#   scripts/network.sh remove <name>
#   scripts/network.sh list
#
# Devices are kept in inventory/network.tsv (git-ignored, part of the encrypted
# config backup). Every change rewrites prometheus/probes/network.json and
# prometheus/probes/snmp/targets.json, which Prometheus re-reads within a minute.
set -euo pipefail

cd "$(dirname "$0")/.."
readonly REGISTRY=inventory/network.tsv
readonly AUTHS=scopes/network/snmp/auths.yml
readonly PROBE_TARGETS=prometheus/probes/network.json
readonly SNMP_TARGETS=prometheus/probes/snmp/targets.json
readonly SNMP_MODULES=if_mib,system
readonly DEFAULT_SSH_PORT=22
readonly NAME_PATTERN='^[a-z0-9][a-z0-9-]{0,40}$'
readonly IPV4_PATTERN='^((25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])$'
readonly PORT_PATTERN='^[1-9][0-9]{0,4}$'

usage() { sed -n '2,13p' "$0" >&2; exit 2; }
die() { echo "network: $*" >&2; exit 1; }
check_format() { [[ "$2" =~ $3 ]] || die "invalid $1 '$2'"; }

known_auths() { sed -n 's/^  \([a-z0-9_]*\):$/\1/p' "$AUTHS"; }
has_device() { [[ -f "$REGISTRY" ]] && cut -f1 "$REGISTRY" | grep -qx "$1"; }

# One file_sd entry. Arguments: target, name, probe or "snmp", extra labels.
target_entry() {
  printf '{"targets":["%s"],"labels":{"host":"%s","scope":"network",%s}}\n' "$1" "$2" "$3"
}

# Writes $2 from the JSON entries on stdin, atomically, readable by Prometheus.
write_targets() (
  local entries
  entries=$(cat)
  umask 022
  mkdir -p "$(dirname "$1")"
  printf '[%s]\n' "$(paste -sd, - <<<"$entries")" > "$1.tmp"
  mv "$1.tmp" "$1"
)

write_all_targets() {
  local name ip auth ssh_port
  touch "$REGISTRY"
  while IFS=$'\t' read -r name ip auth ssh_port; do
    target_entry "$ip" "$name" '"probe":"icmp","__param_module":"icmp"'
    target_entry "$ip:$ssh_port" "$name" '"probe":"ssh","__param_module":"tcp"'
  done < "$REGISTRY" | write_targets "$PROBE_TARGETS"
  while IFS=$'\t' read -r name ip auth ssh_port; do
    target_entry "$ip" "$name" "\"__param_auth\":\"$auth\",\"__param_module\":\"$SNMP_MODULES\""
  done < "$REGISTRY" | write_targets "$SNMP_TARGETS"
}

cmd_add() {
  local name="$1" ip="$2" auth="" ssh_port="$DEFAULT_SSH_PORT"
  shift 2
  while (( $# > 0 )); do
    case "$1" in
      --auth) auth="${2:-}"; shift 2 || usage ;;
      --ssh-port) ssh_port="${2:-}"; shift 2 || usage ;;
      *) usage ;;
    esac
  done
  check_format name "$name" "$NAME_PATTERN"
  check_format ip "$ip" "$IPV4_PATTERN"
  check_format --ssh-port "$ssh_port" "$PORT_PATTERN"
  [[ -n "$auth" ]] || die "--auth is required: one of $(known_auths | paste -sd' ' -)"
  known_auths | grep -qx "$auth" || die "unknown --auth '$auth': one of $(known_auths | paste -sd' ' -)"
  ! has_device "$name" || die "'$name' exists (scripts/network.sh remove $name first)"
  printf '%s\t%s\t%s\t%s\n' "$name" "$ip" "$auth" "$ssh_port" >> "$REGISTRY"
  write_all_targets
  echo "added $name: probes within a minute, SNMP once the switch answers (scripts/network.sh list)"
}

cmd_remove() {
  has_device "$1" || die "unknown device '$1' (scripts/network.sh list)"
  awk -F'\t' -v name="$1" '$1 != name' "$REGISTRY" > "$REGISTRY.tmp"
  mv "$REGISTRY.tmp" "$REGISTRY"
  write_all_targets
  echo "removed $1"
}

cmd_list() {
  printf '%-16s %-16s %-14s %s\n' NAME IP AUTH SSH-PORT
  [[ -f "$REGISTRY" ]] || return 0
  while IFS=$'\t' read -r name ip auth ssh_port; do
    printf '%-16s %-16s %-14s %s\n' "$name" "$ip" "$auth" "$ssh_port"
  done < "$REGISTRY"
}

(( EUID != 0 )) || die "run as the admin user, not root: root-owned files would break the next run"
(( $# >= 1 )) || usage
install -d -m 700 inventory
command="$1"; shift
case "$command" in
  add) (( $# >= 2 )) || usage; cmd_add "$@" ;;
  remove) (( $# == 1 )) || usage; cmd_remove "$1" ;;
  list) (( $# == 0 )) || usage; cmd_list ;;
  *) usage ;;
esac
