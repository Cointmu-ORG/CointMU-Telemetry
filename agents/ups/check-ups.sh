#!/usr/bin/env bash
# End-to-end test of the UPS host's agent (README.md, "UPS monitoring") in a
# throwaway copy of the stack: its own compose project, volumes, certificate
# and nginx/local/, nothing published on the host, all removed afterwards. So
# it never touches a running deployment and runs anywhere with Docker.
#
# agents/ups/config.alloy pushes test journal lines (testdata/ups-journal.txt,
# written as a real journal file) through nginx. Checks:
# - logs in Loki with job="ups" and their labels, no address left, other units
#   not shipped
# Takes about two minutes.
#
#   agents/ups/check-ups.sh
set -euo pipefail

cd "$(dirname "$0")"
ROOT_DIR="$(cd ../.. && pwd)"
readonly ROOT_DIR
ALLOY_IMAGE=$(sed -n 's/^readonly ALLOY_IMAGE="\(.*\)"$/\1/p' ../alloy/check-redaction.sh)
readonly ALLOY_IMAGE
readonly TEST_IMAGE=cointmu-ups-test:local
readonly PROJECT="cointmu-ups-check-$$"
readonly AGENT_HOST=ups-check
readonly WAIT_SECONDS=120
readonly EXPECTED_LOG_LINES=7

work=$(mktemp -d)
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }
compose() { docker compose -p "$PROJECT" -f "$ROOT_DIR/compose.yml" -f "$work/override.yml" --env-file "$work/env" "$@"; }
in_logs() { docker exec "$PROJECT-logs-probe" "$@"; }
queries() { in_logs python3 /repo/agents/ups/testdata/ups_queries.py "$@"; }

cleanup() {
  docker rm -f "$PROJECT-alloy" "$PROJECT-host" "$PROJECT-logs-probe" "$PROJECT-front-probe" >/dev/null 2>&1 || true
  compose down -v >/dev/null 2>&1 || true
  docker volume rm "$PROJECT-textfile" "$PROJECT-journal" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

# Throwaway .env, certificate (SAN "proxy", the name the agent uses) and logins.
prepare() {
  sed -e 's/^TLS_GID=.*/TLS_GID=12345/' -e 's/^BIND_IP=.*/BIND_IP=127.0.0.1/' \
    -e "s/^SECRET_KEY=.*/SECRET_KEY=$(openssl rand -hex 32)/" \
    -e "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 24)/" \
    -e "s/^GRAFANA_ADMIN_PASSWORD=.*/GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 24)/" \
    "$ROOT_DIR/.env.example" > "$work/env"
  mkdir -p "$work/certs" "$work/local" "$work/alloy"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj /CN=proxy \
    -addext subjectAltName=DNS:proxy -keyout "$work/certs/server.key" -out "$work/certs/server.crt" 2>/dev/null
  chmod 644 "$work/certs/server.key"
  : > "$work/local/admin-allow.conf"
  : > "$work/local/agent-allow.conf"
  logs_pw=$(openssl rand -hex 16)
  printf 'ups-check-logs:%s\n' "$(openssl passwd -6 "$logs_pw")" > "$work/local/loki-agents.htpasswd"
  printf '%s' "$logs_pw" > "$work/alloy/push-password"
  cp "$work/certs/server.crt" "$work/alloy/telemetry.crt"
  chmod -R a+rX "$work"
  # Same mounts as compose.yml, from $work; no published port; GlitchTip is
  # not started, so "web" points nowhere.
  cat > "$work/override.yml" <<EOF
services:
  proxy:
    ports: !reset []
    extra_hosts: ["web:127.0.0.1"]
    volumes:
      - { type: bind, source: $work/local, target: /etc/nginx/local, read_only: true }
      - { type: bind, source: $work/certs, target: /etc/nginx/certs, read_only: true }
EOF
}

wait_for() {
  local what="$1" deadline=$((SECONDS + WAIT_SECONDS)); shift
  while (( SECONDS < deadline )); do "$@" >/dev/null 2>&1 && { pass "$what"; return 0; }; sleep 1; done
  fail "$what (gave up after $WAIT_SECONDS s)"; return 1
}

start_stack() {
  compose up -d --no-deps loki proxy >"$work/up.log" 2>&1 || { cat "$work/up.log"; return 1; }
  docker run -d --name "$PROJECT-logs-probe" --network "${PROJECT}_logs" -v "$ROOT_DIR:/repo:ro" \
    "$TEST_IMAGE" sleep infinity >/dev/null
  docker run -d --name "$PROJECT-front-probe" --network "${PROJECT}_frontend" -v "$work/certs:/certs:ro" \
    "$TEST_IMAGE" sleep infinity >/dev/null
  wait_for "loki ready" in_logs sh -c 'curl -fs http://loki:3100/ready | grep -q ^ready'
  # Its healthcheck needs GlitchTip (/_health/), which is not started here.
  wait_for "proxy answers" docker exec "$PROJECT-front-probe" \
    curl -s --cacert /certs/server.crt -o /dev/null https://proxy:8443/loki/
  # The agents' network is allowlisted; the logs network (other probe) is not.
  docker network inspect -f '{{(index .IPAM.Config 0).Subnet}} 1;' "${PROJECT}_frontend" > "$work/local/agent-allow.conf"
  compose exec -T proxy nginx -s reload >/dev/null 2>&1
}

# The test lines as a real journal file, stamped now.
write_journal() {
  docker volume create "$PROJECT-journal" >/dev/null
  docker run --rm --network none -v "$PWD/testdata:/t:ro" -v "$PROJECT-journal:/journal" "$TEST_IMAGE" bash -c '
    now=$(date +%s%6N); i=0
    grep -v "^#" /t/ups-journal.txt | while read -r unit ident message; do
      i=$((i + 1))
      printf "__REALTIME_TIMESTAMP=%s\n__MONOTONIC_TIMESTAMP=%s\n_BOOT_ID=0123456789abcdef0123456789abcdef\n_SYSTEMD_UNIT=%s\nSYSLOG_IDENTIFIER=%s\nMESSAGE=%s\n\n" \
        "$((now + i))" "$i" "$unit" "$ident" "$message"
    done | /lib/systemd/systemd-journal-remote -o /journal/check.journal - 2>/dev/null'
}

start_alloy() {
  docker rm -f "$PROJECT-alloy" >/dev/null 2>&1 || true
  docker run -d --name "$PROJECT-alloy" --network "${PROJECT}_frontend" \
    -e AGENT_HOST="$AGENT_HOST" -e UPS_NAME=check -e UPS_JOURNAL_PATH=/journal \
    -e LOKI_PUSH_URL=https://proxy:8443/loki/api/v1/push -e LOKI_PUSH_USER=ups-check-logs \
    -v "$PWD/config.alloy:/etc/alloy/config.alloy:ro" \
    -v "$work/alloy/push-password:/etc/alloy/push-password:ro" \
    -v "$work/alloy/telemetry.crt:/etc/alloy/telemetry.crt:ro" \
    -v "$PROJECT-journal:/journal:ro" \
    "$ALLOY_IMAGE" run --stability.level=experimental --storage.path=/tmp/alloy /etc/alloy/config.alloy >/dev/null
}

check_logs() {
  local lines
  lines=$(queries logs "$AGENT_HOST")
  if python3 - "$EXPECTED_LOG_LINES" "$lines" <<'EOF'; then pass "Loki: job=ups lines, labels, no address"; else fail "Loki lines"; fi
import json, re, sys
expected, lines = int(sys.argv[1]), json.loads(sys.argv[2])
leak = re.compile(r"\b(?:\d{1,3}\.){3}\d{1,3}\b|2001:db8")
errors = [] if len(lines) == expected else [f"expected {expected} lines, got {len(lines)}"]
for labels, line in lines:
    print(f"      {labels.get('unit')}: {line}")
    if leak.search(line): errors.append(f"not redacted: {line}")
    if labels.get("ups") != "check" or not labels.get("unit", "").startswith("nut-"): errors.append(f"labels {labels}")
    if "pveproxy" in line or "vanished" in line: errors.append(f"other unit shipped: {line}")
for error in errors: print("      " + error, file=sys.stderr)
sys.exit(1 if errors else 0)
EOF
}

docker build -q -t "$TEST_IMAGE" testdata >/dev/null
prepare
start_stack
write_journal
start_alloy
wait_for "logs arrive through nginx" sh -c "[ \"\$(docker exec $PROJECT-logs-probe python3 /repo/agents/ups/testdata/ups_queries.py logs $AGENT_HOST | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')\" -ge $EXPECTED_LOG_LINES ]"
check_logs

(( failures == 0 )) || { echo "$failures check(s) failed" >&2; docker logs --tail 30 "$PROJECT-alloy" >&2; exit 1; }
echo "OK: UPS logs pipeline as expected"
