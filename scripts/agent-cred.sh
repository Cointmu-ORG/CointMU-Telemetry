#!/usr/bin/env bash
# Manages the geth node agents' logins for the Loki push endpoint, kept in
# nginx/local/loki-agents.htpasswd (sha512-crypt hashes). nginx reads that file
# on every request, so changes apply at once, without a reload.
#
#   scripts/agent-cred.sh add <name>      new login; prints its password once
#   scripts/agent-cred.sh revoke <name>   removes the login
#
# <name> is lowercase letters, digits, "." and "-", e.g. bootnode-a-1.
# Rotation adds a new name first and revokes the old one after the agent has
# switched (RUNBOOK.md): the agent drops log batches answered with 401.
#
# The file is rewritten in place and kept at mode 640 with group TLS_GID from
# .env, the host group the proxy joins (README.md); creating it may ask for
# sudo once to set that group.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly ROOT_DIR
readonly HTPASSWD="$ROOT_DIR/nginx/local/loki-agents.htpasswd"
readonly ENV_FILE="$ROOT_DIR/.env"
readonly NAME_PATTERN='^[a-z0-9][a-z0-9.-]{0,62}$'
readonly PASSWORD_BYTES=24
# nginx's own GID in nginxinc/nginx-unprivileged, a system group on the host.
readonly NGINX_IMAGE_GID=101

usage() { sed -n '2,15p' "$0" >&2; exit 2; }
die() { echo "$*" >&2; exit 1; }

tls_gid() {
  local gid="${TLS_GID:-}"
  if [[ -z "$gid" && -f "$ENV_FILE" ]]; then
    gid=$(sed -n 's/^TLS_GID=//p' "$ENV_FILE")
  fi
  [[ "$gid" =~ ^[0-9]+$ ]] || die "TLS_GID is not set in $ENV_FILE (see README.md)"
  (( gid != NGINX_IMAGE_GID )) || die "TLS_GID must not be $NGINX_IMAGE_GID (a host system group)"
  echo "$gid"
}

ensure_file() {
  [[ -f "$HTPASSWD" ]] && return
  local gid
  gid=$(tls_gid)
  (umask 077 && : > "$HTPASSWD")
  if ! chgrp "$gid" "$HTPASSWD" 2>/dev/null; then
    echo "chgrp $gid $HTPASSWD needs root:" >&2
    sudo chgrp "$gid" "$HTPASSWD"
  fi
  chmod 640 "$HTPASSWD"
}

has_login() { grep -q "^$1:" "$HTPASSWD"; }

[[ $# -eq 2 ]] || usage
name="$2"
[[ "$name" =~ $NAME_PATTERN ]] || die "invalid name '$name' (see usage)"

case "$1" in
  add)
    ensure_file
    has_login "$name" && die "login '$name' exists; add a new name to rotate (RUNBOOK.md)"
    password=$(openssl rand -base64 "$PASSWORD_BYTES")
    hash=$(openssl passwd -6 -stdin <<<"$password")
    printf '%s:%s\n' "$name" "$hash" >> "$HTPASSWD"
    echo "login:    $name"
    echo "password: $password"
    echo "Put the password in /etc/alloy/push-password on the node; it is not stored here."
    ;;
  revoke)
    if [[ ! -f "$HTPASSWD" ]] || ! has_login "$name"; then
      die "no login '$name' in $HTPASSWD"
    fi
    remaining=$(grep -v "^$name:" "$HTPASSWD" || true)
    # ">" truncates and rewrites, so owner, group and mode stay as they are.
    if [[ -n "$remaining" ]]; then
      printf '%s\n' "$remaining" > "$HTPASSWD"
    else
      : > "$HTPASSWD"
    fi
    echo "revoked $name"
    ;;
  *) usage ;;
esac
