#!/usr/bin/env bash
# End-to-end test of paths B and C (README.md, "UPS monitoring") in a
# throwaway copy of the stack: its own compose project, volumes, certificate
# and nginx/local/, nothing published on the host, all removed afterwards. So
# it never touches a running deployment and runs anywhere with Docker.
#
# A fake UPS host (testdata/metrics-host.sh: dummy-ups, ups-metrics.sh, the
# owner/mode checks) feeds agents/ups/config.alloy, which pushes the metrics
# and test journal lines (testdata/ups-journal.txt) through nginx. Checks:
# - remote write via nginx: series arrive; 2xx and 403 in the noip log; wrong
#   password, a log login and other paths refused (401, 401, 404); a
#   non-allowlisted address gets 403 before auth
# - logs in Loki with job="ups" and their labels, no address left, other units
#   not shipped
# - every ups.json panel query returns data
# - the UPS rules (rules.yml) as Grafana evaluates them: nothing fires while
#   healthy; Alloy stopped: "missing" fires after 5 min, "stale" does not;
#   timer stopped while Alloy keeps scraping: "stale" fires, "missing" does not
# Takes about four minutes.
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
readonly OUTAGE_SECONDS=20
readonly STALE_WAIT_SECONDS=75
# "UPS data missing" looks back 5 minutes; evaluate a minute past that.
readonly MISSING_OFFSET_SECONDS=360
readonly NO_CONTENT=204
readonly UNAUTHORIZED=401
readonly FORBIDDEN=403
readonly NOT_FOUND=404
readonly EXPECTED_LOG_LINES=7

work=$(mktemp -d)
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }
compose() { docker compose -p "$PROJECT" -f "$ROOT_DIR/compose.yml" -f "$work/override.yml" --env-file "$work/env" "$@"; }
in_logs() { docker exec "$PROJECT-logs-probe" "$@"; }
queries() { in_logs python3 /repo/agents/ups/testdata/ups_queries.py "$@"; }
rule() { queries rules "${2:-0}" | sed -n "s/^$1 //p"; }

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
  metrics_pw=$(openssl rand -hex 16)
  printf 'ups-check-logs:%s\n' "$(openssl passwd -6 "$logs_pw")" > "$work/local/loki-agents.htpasswd"
  printf 'ups-check-metrics:%s\n' "$(openssl passwd -6 "$metrics_pw")" > "$work/local/metrics-agents.htpasswd"
  printf '%s' "$logs_pw" > "$work/alloy/push-password"
  printf '%s' "$metrics_pw" > "$work/alloy/metrics-password"
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
  compose up -d --no-deps loki prometheus grafana proxy >"$work/up.log" 2>&1 || { cat "$work/up.log"; return 1; }
  docker run -d --name "$PROJECT-logs-probe" --network "${PROJECT}_logs" -v "$ROOT_DIR:/repo:ro" \
    "$TEST_IMAGE" sleep infinity >/dev/null
  docker run -d --name "$PROJECT-front-probe" --network "${PROJECT}_frontend" -v "$work/certs:/certs:ro" \
    "$TEST_IMAGE" sleep infinity >/dev/null
  wait_for "prometheus ready" in_logs curl -fs http://prometheus:9090/-/ready
  wait_for "loki ready" in_logs sh -c 'curl -fs http://loki:3100/ready | grep -q ^ready'
  # Its healthcheck needs GlitchTip (/_health/), which is not started here.
  wait_for "proxy answers" docker exec "$PROJECT-front-probe" \
    curl -s --cacert /certs/server.crt -o /dev/null https://proxy:8443/loki/
  # The agents' network is allowlisted; the logs network (other probe) is not.
  docker network inspect -f '{{(index .IPAM.Config 0).Subnet}} 1;' "${PROJECT}_frontend" > "$work/local/agent-allow.conf"
  compose exec -T proxy nginx -s reload >/dev/null 2>&1
}

start_host() {
  docker volume create "$PROJECT-textfile" >/dev/null
  docker run -d --name "$PROJECT-host" --network none -v "$PWD:/src:ro" \
    -v "$PROJECT-textfile:/var/lib/cointmu-ups" "$TEST_IMAGE" bash /src/testdata/metrics-host.sh >/dev/null
  wait_for "fake UPS host ready" sh -c "docker logs $PROJECT-host 2>&1 | grep -q '^READY$'" \
    || { docker logs "$PROJECT-host"; return 1; }
  docker logs "$PROJECT-host" 2>&1 | grep -E '^(ok|FAIL)'
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
    -e METRICS_PUSH_URL=https://proxy:8443/prometheus/api/v1/write -e METRICS_PUSH_USER=ups-check-metrics \
    -v "$PWD/config.alloy:/etc/alloy/config.alloy:ro" \
    -v "$work/alloy/push-password:/etc/alloy/push-password:ro" \
    -v "$work/alloy/metrics-password:/etc/alloy/metrics-password:ro" \
    -v "$work/alloy/telemetry.crt:/etc/alloy/telemetry.crt:ro" \
    -v "$PROJECT-textfile:/var/lib/cointmu-ups:ro" -v "$PROJECT-journal:/journal:ro" \
    "$ALLOY_IMAGE" run --stability.level=experimental --storage.path=/tmp/alloy /etc/alloy/config.alloy >/dev/null
}

# $1 expected status, $2 description, rest: curl arguments.
expect_status() {
  local expected="$1" what="$2" status; shift 2
  status=$(docker exec "$@" -s -o /dev/null -w '%{http_code}' 2>/dev/null) || true
  if [[ "$status" == "$expected" ]]; then pass "$what: $status"; else fail "$what: got $status, expected $expected"; fi
}

# $1 description, $2 regex that must match a line of $log.
expect_log() {
  if grep -qE "$2" <<<"$log"; then pass "$1"; else fail "$1: no line matches $2"; fi
}

check_endpoint() {
  local url=https://proxy:8443/prometheus/api/v1/write front="$PROJECT-front-probe" log
  expect_status "$UNAUTHORIZED" "metrics push, wrong password" \
    "$front" curl --cacert /certs/server.crt -u ups-check-metrics:wrong -X POST --data-binary x "$url"
  expect_status "$UNAUTHORIZED" "metrics push with the logs login" \
    "$front" curl --cacert /certs/server.crt -u "ups-check-logs:$logs_pw" -X POST --data-binary x "$url"
  expect_status "$FORBIDDEN" "metrics push from a non-allowlisted address" \
    "$PROJECT-logs-probe" curl -k -u "ups-check-metrics:$metrics_pw" -X POST --data-binary x "$url"
  expect_status "$NOT_FOUND" "query API through nginx" \
    "$front" curl --cacert /certs/server.crt "https://proxy:8443/prometheus/api/v1/query?query=up"
  expect_status "$NOT_FOUND" "Prometheus UI through nginx" "$front" curl --cacert /certs/server.crt https://proxy:8443/prometheus/graph
  log=$(compose logs --no-log-prefix proxy)
  expect_log "successful pushes logged without address" "^\[[^]]+\] \"POST /prometheus/api/v1/write\" $NO_CONTENT "
  expect_log "401 in the audit log with address and login" \
    "^[0-9a-f.:]+ ups-check-metrics \[.*\"POST /prometheus/api/v1/write\" $UNAUTHORIZED "
  expect_log "403 logged without address" "^\[[^]]+\] \"POST /prometheus/api/v1/write\" $FORBIDDEN "
  if grep -qE "^[0-9a-f.:]+ .*\" ($NO_CONTENT|$FORBIDDEN) " <<<"$log"; then
    fail "a 2xx or 403 push was logged with an address"
  fi
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

# $1 rule uid, $2 expected state prefix, $3 offset in seconds (optional).
expect_rule() {
  local state
  state=$(rule "$1" "${3:-0}")
  if [[ "$state" == "$2"* ]]; then pass "rule $1 at +${3:-0} s: $state"; else fail "rule $1 at +${3:-0} s: $state, expected $2"; fi
}

docker build -q -t "$TEST_IMAGE" testdata >/dev/null
prepare
start_stack
start_host
write_journal
start_alloy
wait_for "metrics arrive through nginx" sh -c "[ -n \"\$(docker exec $PROJECT-logs-probe python3 /repo/agents/ups/testdata/ups_queries.py value 'ups_up{job=\"ups\",host=\"$AGENT_HOST\",ups=\"check\"} == 1')\" ]"
if [[ "$(queries value "ups_battery_charge_percent{host=\"$AGENT_HOST\"}")" == 76 ]]; then
  pass "charge value as written by ups-metrics.sh"
else
  fail "charge value"
fi
wait_for "logs arrive through nginx" sh -c "[ \"\$(docker exec $PROJECT-logs-probe python3 /repo/agents/ups/testdata/ups_queries.py logs $AGENT_HOST | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')\" -ge $EXPECTED_LOG_LINES ]"
check_logs
check_endpoint
if queries panels "$AGENT_HOST"; then pass "every ups.json panel query returns data"; else fail "dashboard panels"; fi
for uid in ups-on-battery-long ups-charge-low ups-runtime-low ups-unreadable ups-metrics-stale ups-data-missing; do
  expect_rule "$uid" Normal
done

# (b) transport outage: Alloy stopped, the timer keeps writing.
docker stop "$PROJECT-alloy" >/dev/null
sleep "$OUTAGE_SECONDS"
expect_rule ups-metrics-stale Normal
expect_rule ups-data-missing Normal
expect_rule ups-data-missing "NoData->Alerting" "$MISSING_OFFSET_SECONDS"
expect_rule ups-metrics-stale "NoData->OK" "$MISSING_OFFSET_SECONDS"

# (a) timer stopped while Alloy keeps scraping the last file.
restarted=$(date +%s)
start_alloy
wait_for "fresh samples after the Alloy restart" sh -c "[ \"\$(docker exec $PROJECT-logs-probe python3 /repo/agents/ups/testdata/ups_queries.py value 'timestamp(ups_up{host=\"$AGENT_HOST\"}) > $restarted')\" != '' ]"
docker exec "$PROJECT-host" touch /tmp/stop-timer
sleep "$STALE_WAIT_SECONDS"
expect_rule ups-metrics-stale Alerting
expect_rule ups-data-missing Normal
expect_rule ups-unreadable Normal

(( failures == 0 )) || { echo "$failures check(s) failed" >&2; docker logs --tail 30 "$PROJECT-alloy" >&2; exit 1; }
echo "OK: UPS logs and metrics pipeline as expected"
