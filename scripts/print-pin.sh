#!/usr/bin/env bash
# Prints the SPKI SHA-256 pin (base64) that the app expects.
#
#   scripts/print-pin.sh certs/server.crt   from a certificate file
#   scripts/print-pin.sh 10.64.24.250:443   from what a live server presents
set -euo pipefail

[[ $# -eq 1 ]] || { sed -n '2,5p' "$0" >&2; exit 2; }

if [[ -f "$1" ]]; then
  pem=$(cat "$1")
else
  pem=$(openssl s_client -connect "$1" </dev/null 2>/dev/null | openssl x509)
fi
openssl x509 -pubkey -noout <<<"$pem" \
  | openssl pkey -pubin -outform der \
  | openssl dgst -sha256 -binary \
  | base64
