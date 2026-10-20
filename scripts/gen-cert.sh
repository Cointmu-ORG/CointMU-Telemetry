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
set -euo pipefail

CERT_DIR="$(cd "$(dirname "$0")/.." && pwd)/certs"
readonly CERT_DIR
readonly VALID_DAYS=3650
readonly KEY="$CERT_DIR/server.key"
readonly CERT="$CERT_DIR/server.crt"
readonly NEXT_KEY="$CERT_DIR/next.key"

usage() { sed -n '2,12p' "$0" >&2; exit 2; }

new_key() {
  (umask 077 && openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1")
}

issue_cert() {
  local san="$1"
  openssl req -x509 -new -key "$KEY" -out "$CERT" -days "$VALID_DAYS" \
    -subj "/CN=cointmu-telemetry" -addext "subjectAltName=$san"
  # nginx runs as an unprivileged user inside the container.
  chmod 644 "$KEY" "$CERT"
}

pin_of_key() {
  openssl pkey -in "$1" -pubout -outform der | openssl dgst -sha256 -binary | base64
}

mkdir -p "$CERT_DIR"
case "${1:-}" in
  new)
    [[ $# -eq 2 ]] || usage
    [[ -e "$KEY" ]] && { echo "refusing: $KEY exists (use renew or promote)" >&2; exit 1; }
    new_key "$KEY"
    issue_cert "$2"
    echo "pin (current): $(pin_of_key "$KEY")"
    ;;
  renew)
    [[ $# -eq 2 ]] || usage
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
    [[ -e "$NEXT_KEY" ]] || { echo "no $NEXT_KEY; run 'next' first" >&2; exit 1; }
    mv "$KEY" "$KEY.old"
    mv "$NEXT_KEY" "$KEY"
    issue_cert "$2"
    echo "pin (current, was next): $(pin_of_key "$KEY")"
    echo "restart the proxy: docker compose restart proxy"
    ;;
  *) usage ;;
esac
