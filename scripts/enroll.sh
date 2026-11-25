#!/usr/bin/env bash
# Enrolls hosts with this telemetry VM: logins, nginx allowlist, a one-time
# bundle for the host and the commands to run on your workstation
# (RUNBOOK.md, "Enroll a host"). Run as the admin user, never as root.
#
#   scripts/enroll.sh add <host> <ip> --scopes a,b --ssh <user@alias> [options]
#   scripts/enroll.sh adopt <host> <ip> --scopes a,b --ssh <user@alias> --login <name> [options]
#       a host that already ships data: keeps its login, passwords and Alloy
#   scripts/enroll.sh verify <host>     data of every scope arrives? then removes the bundle
#   scripts/enroll.sh commands <host>   prints the workstation commands again
#   scripts/enroll.sh reissue <host> [--leaked]   new login and bundle
#   scripts/enroll.sh revoke-old <host> after a reissue, once the host runs the new login
#   scripts/enroll.sh remove <host>     revokes logins and allowlist entry
#   scripts/enroll.sh list              hosts, scopes, state, data fresh or not
#   scripts/enroll.sh bundle <host>     writes the bundle to stdout (for the pipe)
#   scripts/enroll.sh expire            removes bundles older than 24 h (hourly cron)
#   scripts/enroll.sh fetch-alloy <amd64|arm64>   downloads and checks the pinned package
#
# Options: --type pve|linux|lxc (default linux), --via <pve ssh alias>:<ctid> (lxc),
#   --rack <name>, --ssh-port <n> (default 22), --arch amd64|arm64 (default amd64),
#   --set KEY=VALUE (a setting of a scope's agent.manifest; repeatable)
set -euo pipefail

cd "$(dirname "$0")/.."
readonly LOCK_FILE=state/enroll.lock
readonly LOCK_WAIT_SECONDS=30

usage() { sed -n '2,22p' "$0" >&2; exit 2; }
die() { echo "enroll: $*" >&2; exit 1; }

# shellcheck source=scripts/enroll/registry.sh
. scripts/enroll/registry.sh
# shellcheck source=scripts/enroll/access.sh
. scripts/enroll/access.sh
# shellcheck source=scripts/enroll/bundle.sh
. scripts/enroll/bundle.sh
# shellcheck source=scripts/enroll/options.sh
. scripts/enroll/options.sh
# shellcheck source=scripts/enroll/commands.sh
. scripts/enroll/commands.sh
# shellcheck source=scripts/enroll/verify.sh
. scripts/enroll/verify.sh
# shellcheck source=scripts/enroll/alloy-package.sh
. scripts/enroll/alloy-package.sh

stage=""
# Functions that undo what a failed add, adopt or reissue did, in order.
undo=()
finish() {
  local status=$? step
  if [[ -n "$stage" ]]; then rm -rf "${stage:?}"; fi
  (( status != 0 && ${#undo[@]} > 0 )) || return 0
  for step in "${undo[@]}"; do ("$step") || true; done
  echo "enroll: failed, undone" >&2
}
trap finish EXIT

undo_login() { revoke_logins "$h_login"; }
undo_allow() { disallow_host "$h_host"; }
undo_bundle() { shred_bundle "$h_host"; }
undo_record() { registry_delete "$h_host"; delete_settings; }

load_host() { registry_load "$1" || die "unknown host '$1' (scripts/enroll.sh list)"; }
host_logins() { scope_logins "${h_scopes//,/ }" "$h_type"; }

cmd_add() {
  (( $# >= 2 )) || usage
  h_host="$1" h_ip="$2"; shift 2
  parse_options "$@"
  [[ -z "$h_login" ]] || die "--login is for adopt"
  check_host
  check_settings add
  alloy_deb "$h_arch" >/dev/null
  h_login="$h_host-1"
  if has_login "$h_login" logs || has_login "$h_login" metrics; then
    die "login '$h_login' exists: this host ships data already? use adopt"
  fi
  stage=$(mktemp -d)
  undo=(undo_login undo_allow undo_bundle undo_record)
  add_logins "$h_login" "$(host_logins)" "$stage"
  allow_host "$h_host" "$h_ip"
  record_and_build with-alloy
}

cmd_adopt() {
  local kind
  (( $# >= 2 )) || usage
  h_host="$1" h_ip="$2"; shift 2
  parse_options "$@"
  check_host
  check_settings adopt
  check_format --login "$h_login" "$LOGIN_PATTERN"
  for kind in $(host_logins); do
    has_login "$h_login" "$kind" || die "no $kind login '$h_login' to adopt (scripts/agent-cred.sh add $h_login $kind)"
  done
  stage=$(mktemp -d)
  undo=(undo_allow undo_bundle undo_record)
  allow_host "$h_host" "$h_ip"
  record_and_build without-alloy
}

record_and_build() {
  save_settings
  build_bundle "$1" "$stage"
  registry_save
  print_commands
}

cmd_verify() {
  load_host "$1"
  check_host_data || die "$h_host is not complete yet; the bundle stays until it is, at most 24 h"
  h_state=active
  registry_save
  shred_bundle "$h_host"
  echo "$h_host is active"
}

# Next login name of $h_login: server101-1 -> server101-2.
next_login() {
  local base="${h_login%-*}" number="${h_login##*-}"
  if [[ "$number" =~ ^[0-9]+$ ]]; then echo "$base-$((number + 1))"; else echo "$h_login-2"; fi
}

cmd_reissue() {
  local old
  load_host "$1"
  [[ -z "${2:-}" || "$2" == --leaked ]] || usage
  old="$h_login"
  alloy_deb "$h_arch" >/dev/null
  load_settings
  h_login=$(next_login)
  if [[ "${2:-}" == --leaked ]]; then revoke_logins "$old"; fi
  stage=$(mktemp -d)
  shred_bundle "$h_host"
  undo=(undo_login undo_bundle)
  add_logins "$h_login" "$(host_logins)" "$stage"
  build_bundle with-alloy "$stage"
  h_state=pending
  registry_save
  undo=()
  print_commands
  if [[ "${2:-}" != --leaked ]]; then
    echo "# $old still works. Once the installer has finished on $h_host: scripts/enroll.sh revoke-old $h_host"
  fi
}

# Every login of the host except the current one. Only the host knows which
# login it uses, so this is a step of its own.
cmd_revoke_old() {
  local name
  load_host "$1"
  while IFS= read -r name; do
    if [[ "$name" != "$h_login" ]]; then revoke_logins "$name"; fi
  done < <(sed -n "s/^\(${h_login%-*}-[0-9][0-9]*\):.*/\1/p" "$LOGS_HTPASSWD" "$METRICS_HTPASSWD" | sort -u)
}

cmd_remove() {
  load_host "$1"
  cmd_revoke_old "$1"
  revoke_logins "$h_login"
  disallow_host "$h_host"
  shred_bundle "$h_host"
  delete_settings
  registry_delete "$h_host"
  echo "removed $h_host. A hand-written line for $h_ip in $ALLOWLIST, if any, is still there."
  echo "On the host: install-agent.sh --uninstall. Rules that look back 24 h: RUNBOOK.md, \"Silence a node\"."
}

cmd_list() {
  local host data
  printf '%-16s %-24s %-20s %-8s %-20s %s\n' HOST STATE SCOPES RACK LOGIN DATA
  while IFS= read -r host; do
    load_host "$host"
    if check_host_data >/dev/null; then data=fresh; else data="NOT FRESH"; fi
    if [[ "$h_state" == pending && ! -f "$(bundle_file "$host")" ]]; then h_state="pending, bundle expired"; fi
    printf '%-16s %-24s %-20s %-8s %-20s %s\n' "$host" "$h_state" "$h_scopes" "${h_rack:--}" "$h_login" "$data"
  done < <(registry_hosts)
}

cmd_bundle() {
  load_host "$1"
  [[ ! -t 1 ]] || die "refusing to print a bundle with passwords to a terminal (use the printed pipe)"
  [[ -f "$(bundle_file "$1")" ]] || die "no bundle for $1 (expired or verified): scripts/enroll.sh reissue $1"
  cat "$(bundle_file "$1")"
}

cmd_commands() {
  load_host "$1"
  [[ -f "$(bundle_file "$1")" ]] || die "no bundle for $1 (expired or verified): scripts/enroll.sh reissue $1"
  print_commands
}

(( EUID != 0 )) || die "run as the admin user, not root: root-owned files would break the next run"
(( $# >= 1 )) || usage
install -d -m 700 state
exec 9> "$LOCK_FILE"
flock -w "$LOCK_WAIT_SECONDS" 9 || die "another enroll.sh is running"
registry_init
expire_bundles
command="$1"; shift
case "$command" in
  add | adopt) check_access_files; "cmd_$command" "$@" ;;
  list) (( $# == 0 )) || usage; cmd_list ;;
  expire) (( $# == 0 )) || usage ;;
  fetch-alloy) (( $# == 1 )) || usage; fetch_alloy "$1" ;;
  verify | bundle | commands) (( $# == 1 )) || usage; "cmd_$command" "$1" ;;
  revoke-old | remove) (( $# == 1 )) || usage; check_access_files; "cmd_${command//-/_}" "$1" ;;
  reissue) (( $# == 1 || $# == 2 )) || usage; check_access_files; cmd_reissue "$@" ;;
  *) usage ;;
esac
