#!/usr/bin/env bash
# Manages the collector's TLS key and self-signed certificate in certs/.
# The app pins the PUBLIC KEY, not the certificate, so renewing the certificate
# with the same key needs no app release; changing the key does (see RUNBOOK.md).
#
#   scripts/gen-cert.sh new <san>      first key + certificate (refuses to overwrite)
#   scripts/gen-cert.sh renew <san>    new certificate, same key (pin unchanged)
#   scripts/gen-cert.sh next           pre-generate the next key, print its pin
#   scripts/gen-cert.sh promote <san>  switch to the next key (old key kept as .old)
#
# <san> is the subjectAltName, e.g. IP:10.64.24.250 or DNS:telemetry.lan
#
# Run as the admin user, not root. server.key ends up mode 640, owned by you
# with group TLS_GID from .env (a dedicated host group the proxy joins through
# group_add, see README.md); every other key is 600. Changing the group needs
# root unless you are in that group, so the script then asks for sudo once.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly ROOT_DIR
readonly CERT_DIR="$ROOT_DIR/certs"
readonly ENV_FILE="$ROOT_DIR/.env"
readonly VALID_DAYS=3650
readonly KEY="$CERT_DIR/server.key"
readonly CERT="$CERT_DIR/server.crt"
readonly NEXT_KEY="$CERT_DIR/next.key"
readonly OLD_KEY="$KEY.old"
# nginx's own GID in nginxinc/nginx-unprivileged. On the host it belongs to an
# unrelated system group (syslog on Ubuntu), so it must never own the key.
readonly NGINX_IMAGE_GID=101

usage() { sed -n '2,16p' "$0" >&2; exit 2; }
die() { echo "$*" >&2; exit 1; }

# TLS_GID from the environment or .env, checked against the host's groups.
tls_gid() {
  local gid="${TLS_GID:-}"
  if [[ -z "$gid" && -f "$ENV_FILE" ]]; then
    gid=$(sed -n 's/^TLS_GID=//p' "$ENV_FILE")
  fi
  [[ "$gid" =~ ^[0-9]+$ ]] || die "TLS_GID is not set in $ENV_FILE (see README.md)"
  (( gid != NGINX_IMAGE_GID )) || die "TLS_GID must not be $NGINX_IMAGE_GID (a host system group)"
  getent group "$gid" >/dev/null || die "no host group with GID $gid; create it first (README.md)"
  echo "$gid"
}

new_key() {
  (umask 077 && openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1")
  chmod 600 "$1"
}

# Group first, then the group read bit, so no other group can ever read it.
grant_proxy_read() {
  if ! chgrp "$TLS_GROUP" "$1" 2>/dev/null; then
    echo "chgrp $TLS_GROUP $1 needs root:" >&2
    sudo chgrp "$TLS_GROUP" "$1"
  fi
  chmod 640 "$1"
}

issue_cert() {
  local san="$1"
  openssl req -x509 -new -key "$KEY" -out "$CERT" -days "$VALID_DAYS" \
    -subj "/CN=cointmu-telemetry" -addext "subjectAltName=$san"
  chmod 644 "$CERT"
  grant_proxy_read "$KEY"
}

pin_of_key() {
  openssl pkey -in "$1" -pubout -outform der | openssl dgst -sha256 -binary | base64
}

mkdir -p "$CERT_DIR"
case "${1:-}" in
  new)
    [[ $# -eq 2 ]] || usage
    TLS_GROUP=$(tls_gid)
    [[ -e "$KEY" ]] && { echo "refusing: $KEY exists (use renew or promote)" >&2; exit 1; }
    new_key "$KEY"
    issue_cert "$2"
    echo "pin (current): $(pin_of_key "$KEY")"
    ;;
  renew)
    [[ $# -eq 2 ]] || usage
    TLS_GROUP=$(tls_gid)
    issue_cert "$2"
    echo "pin (unchanged): $(pin_of_key "$KEY")"
    ;;
  next)
    [[ -e "$NEXT_KEY" ]] && { echo "refusing: $NEXT_KEY exists" >&2; exit 1; }
    new_key "$NEXT_KEY"
    echo "pin (current): $(pin_of_key "$KEY")"
    echo "pin (next):    $(pin_of_key "$NEXT_KEY")"
    ;;
  promote)
    [[ $# -eq 2 ]] || usage
    TLS_GROUP=$(tls_gid)
    [[ -e "$NEXT_KEY" ]] || { echo "no $NEXT_KEY; run 'next' first" >&2; exit 1; }
    mv "$KEY" "$OLD_KEY"
    chmod 600 "$OLD_KEY"
    mv "$NEXT_KEY" "$KEY"
    issue_cert "$2"
    echo "pin (current, was next): $(pin_of_key "$KEY")"
    echo "restart the proxy: docker compose restart proxy"
    ;;
  *) usage ;;
esac
