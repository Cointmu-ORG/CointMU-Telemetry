#!/usr/bin/env bash
# Runs config.alloy in the pinned Alloy image against the running stack's Loki
# (straight over the internal network, not through nginx), feeds it
# testdata/cointmu-check-error.log and fails if a line arrives unredacted,
# with the wrong labels, or if the DEBUG line is not dropped.
# Needs the compose stack up (at least loki). Run after changing config.alloy.
# Its lines go to host="redaction-check-<time>"; a delete request removes them
# (Loki's compactor deletes them within about two hours).
#
#   agents/alloy/check-redaction.sh
set -euo pipefail

cd "$(dirname "$0")"
readonly ALLOY_IMAGE="grafana/alloy:v1.21.0@sha256:9726bfba078de9bc2212c60c6e643238c700b4fe0868ea78cbe03163d03d95bf"
readonly PROBE_IMAGE="busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e"
readonly SAMPLE=testdata/cointmu-check-error.log
readonly EXPECTED_LINES=10
readonly WAIT_SECONDS=60
readonly HOST_LABEL="redaction-check-$(date +%s)"
readonly CONTAINER="alloy-redaction-check-$$"

loki_id=$(cd ../.. && docker compose ps -q loki)
[[ -n "$loki_id" ]] || { echo "loki is not running (docker compose up -d loki)" >&2; exit 1; }
network=$(docker inspect -f '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}}{{end}}' "$loki_id")

query="query_range?limit=100&since=1h&query=%7Bhost%3D%22$HOST_LABEL%22%7D"
probe() { docker run --rm --network "$network" "$PROBE_IMAGE" wget -qO- "$@"; }
fetch() { probe "http://loki:3100/loki/api/v1/$query"; }

work=$(mktemp -d)
cleanup() {
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  rm -rf "$work"
  probe --post-data= \
    "http://loki:3100/loki/api/v1/delete?query=%7Bhost%3D%22$HOST_LABEL%22%7D&start=$(date -d '-1 hour' +%s)" \
    >/dev/null || echo "could not request deletion of host=$HOST_LABEL" >&2
}
trap cleanup EXIT

# Throwaway files the config expects; plain HTTP to Loki ignores both.
mkdir -p "$work/etc" "$work/logs"
echo unused > "$work/etc/push-password"
openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
  -subj /CN=check -keyout "$work/etc/key.pem" -out "$work/etc/telemetry.crt" 2>/dev/null
: > "$work/logs/cointmu-check-error.log"
chmod -R a+rX "$work"

docker run -d --name "$CONTAINER" --network "$network" \
  -e LOKI_PUSH_URL=http://loki:3100/loki/api/v1/push \
  -e LOKI_PUSH_USER=check \
  -e AGENT_HOST="$HOST_LABEL" \
  -e GETH_LOG_FILES=/logs/cointmu-check-error.log \
  -e GETH_JOURNAL_UNIT= \
  -v "$PWD/config.alloy:/etc/alloy/config.alloy:ro" \
  -v "$work/etc/push-password:/etc/alloy/push-password:ro" \
  -v "$work/etc/telemetry.crt:/etc/alloy/telemetry.crt:ro" \
  -v "$work/logs:/logs" \
  "$ALLOY_IMAGE" run --stability.level=experimental --storage.path=/tmp/alloy \
  /etc/alloy/config.alloy >/dev/null

# tail_from_end: append only once the file is being tailed.
sleep 5
cat "$SAMPLE" >> "$work/logs/cointmu-check-error.log"

result=""
for _ in $(seq "$WAIT_SECONDS"); do
  result=$(fetch)
  count=$(python3 -c 'import json,sys; print(sum(len(s["values"]) for s in json.load(sys.stdin)["data"]["result"]))' <<<"$result")
  (( count >= EXPECTED_LINES )) && break
  sleep 1
done

RESULT="$result" python3 - "$EXPECTED_LINES" <<'EOF'
import json, os, re, sys

expected = int(sys.argv[1])
streams = json.loads(os.environ["RESULT"])["data"]["result"]
lines = [(s["stream"], v[1]) for s in streams for v in s["values"]]
leaks = re.compile(
    r"\b(?:\d{1,3}\.){3}\d{1,3}\b"      # IPv4, including Tailscale 100.x
    r"|2001:db8|\[::\]"                 # IPv6 from the sample
    r"|[0-9a-fA-F]{16,}"                # node IDs
    r"|enr:-"
)
errors = []
if len(lines) != expected:
    errors.append(f"expected {expected} lines, got {len(lines)}")
for labels, line in lines:
    print(f"{labels.get('level', '-'):5} {labels.get('role', '-'):6} {line}")
    if leaks.search(line):
        errors.append(f"not redacted: {line}")
    if labels.get("role") != "check":
        errors.append(f"role label {labels.get('role')!r}: {line}")
levels = {labels.get("level") for labels, _ in lines}
if levels != {"info", "warn", "error", "crit", "fatal"}:
    errors.append(f"level labels {sorted(map(str, levels))}")
if any("Served eth_blockNumber" in line for _, line in lines):
    errors.append("DEBUG line was not dropped")
for error in errors:
    print("FAIL:", error, file=sys.stderr)
sys.exit(1 if errors else 0)
EOF
echo "OK: redaction and labels as expected"
