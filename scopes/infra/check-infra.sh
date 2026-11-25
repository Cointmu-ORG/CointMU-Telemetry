#!/usr/bin/env bash
# Tests scope infra without a running stack:
# - infra-metrics.py against stub tools; its output as promtool sees it
# - every query of servers.json on synthetic series: data for a host with every
#   kind of hardware, and only for the selected host
# Needs Docker (the pinned Prometheus image and a small test image).
#
#   scopes/infra/check-infra.sh
set -euo pipefail

cd "$(dirname "$0")/../.."
readonly TEST_IMAGE=cointmu-infra-test:local
PROMETHEUS_IMAGE=$(sed -n 's|^ *image: \(prom/prometheus:.*\)$|\1|p' compose.yml)
readonly PROMETHEUS_IMAGE
work=$(mktemp -d)
trap 'rm -rf "${work:?}"' EXIT

in_image() { docker run --rm --network none -u "$(id -u):$(id -g)" -e PYTHONDONTWRITEBYTECODE=1 -v "$PWD:/repo:ro" -v "$work:/out" "$TEST_IMAGE" "$@"; }
promtool() { docker run --rm -i --network none -v "$work:/out:ro" --entrypoint promtool "$PROMETHEUS_IMAGE" "$@"; }

docker build -q -t "$TEST_IMAGE" scopes/ups/testdata >/dev/null
chmod 755 "$work"
in_image python3 /repo/scopes/infra/testdata/test_infra_metrics.py /out
for file in "$work"/*.prom; do promtool check metrics < "$file"; done
in_image python3 /repo/scopes/infra/testdata/check_panels.py /out
promtool test rules /out/panels.yml
echo "OK: scope infra as expected"
