#!/usr/bin/env bash
# Tests scope network without a running stack:
# - scripts/network.sh: add, remove, refusals, the target files it writes
# - every query of network.json on synthetic series of two switches
# - every alert rule per scenario: what fires, for which switch and port, and
#   nothing else
# - the snmp exporter accepts its built-in modules plus auths.yml
# Needs Docker (the pinned Prometheus and snmp exporter images, a small test image).
#
#   scopes/network/check-network.sh
set -euo pipefail

cd "$(dirname "$0")/../.."
readonly TEST_IMAGE=cointmu-network-test:local
PROMETHEUS_IMAGE=$(sed -n 's|^ *image: \(prom/prometheus:.*\)$|\1|p' compose.yml)
SNMP_IMAGE=$(sed -n 's|^ *image: \(prom/snmp-exporter:.*\)$|\1|p' compose.yml)
readonly PROMETHEUS_IMAGE SNMP_IMAGE
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT

in_image() { docker run --rm --network none -u "$(id -u):$(id -g)" -e PYTHONDONTWRITEBYTECODE=1 -v "$PWD:/repo:ro" -v "$work:/out" "$TEST_IMAGE" "$@"; }
promtool() { docker run --rm --network none -v "$work:/out:ro" -w /out --entrypoint promtool "$PROMETHEUS_IMAGE" "$@"; }

docker build -q -t "$TEST_IMAGE" scopes/ups/testdata >/dev/null
chmod 755 "$work"
in_image python3 /repo/scopes/network/testdata/test_network_sh.py
in_image python3 /repo/scopes/network/testdata/check_network.py /out
promtool test rules panels.yml rules-test.yml
# The placeholders compose.yml passes while .env has no login.
docker run --rm --network none -v "$PWD/scopes/network/snmp/auths.yml:/etc/snmp/auths.yml:ro" \
  -e SNMP_MIKROTIK_USER=x -e SNMP_MIKROTIK_AUTH_PASSWORD=not-configured -e SNMP_MIKROTIK_PRIV_PASSWORD=not-configured \
  -e SNMP_CISCO_USER=x -e SNMP_CISCO_AUTH_PASSWORD=not-configured -e SNMP_CISCO_PRIV_PASSWORD=not-configured \
  "$SNMP_IMAGE" --config.file=/etc/snmp_exporter/snmp.yml --config.file=/etc/snmp/auths.yml \
  --config.expand-environment-variables --dry-run
echo "OK: scope network as expected"
