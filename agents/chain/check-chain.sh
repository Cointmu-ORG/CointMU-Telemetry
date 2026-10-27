#!/usr/bin/env bash
# End-to-end test of the chain metrics (README.md, "Chain metrics") in a
# throwaway copy of the stack: its own compose project, volumes, certificate
# and nginx/local/, nothing published on the host, all removed afterwards. So
# it never touches a running deployment and runs anywhere with Docker.
#
# A fake geth node (testdata/node-host.sh: stub RPCs, chain-metrics.py, the
# owner/mode and preflight checks) feeds agents/alloy/config.alloy, which
# pushes the metrics through nginx. Checks:
# - chain.prom passes promtool check metrics
# - every chain.json panel query returns data
# - the chain rules (rules.yml) as Grafana evaluates them: nothing fires
#   while healthy; node behind, no peers, RPC down and stalled each fire their
#   rule; Alloy stopped: "missing" fires after 5 min, "stale" does not; timer
#   stopped while Alloy keeps scraping: "stale" fires, "missing" does not
# - Alloy without /etc/alloy/metrics-password keeps running and shipping
#   logs, and its log names the missing file
# The nginx endpoint itself is checked by agents/ups/check-ups.sh.
# Takes about five minutes.
#
#   agents/chain/check-chain.sh
set -euo pipefail

cd "$(dirname "$0")"
ROOT_DIR="$(cd ../.. && pwd)"
readonly ROOT_DIR
ALLOY_IMAGE=$(sed -n 's/^readonly ALLOY_IMAGE="\(.*\)"$/\1/p' ../alloy/check-redaction.sh)
readonly ALLOY_IMAGE
PROMETHEUS_IMAGE=$(sed -n 's|^ *image: \(prom/prometheus:.*\)$|\1|p' "$ROOT_DIR/compose.yml")
readonly PROMETHEUS_IMAGE
readonly TEST_IMAGE=cointmu-chain-test:local
readonly PROJECT="cointmu-chain-check-$$"
readonly AGENT_HOST=chain-check
readonly NOPW_HOST=chain-check-nopw
readonly WAIT_SECONDS=120
readonly OUTAGE_SECONDS=20
readonly STALE_WAIT_SECONDS=75
# "Chain metrics missing" looks back 5 minutes; evaluate a minute past that.
readonly MISSING_OFFSET_SECONDS=360
readonly GETH_LINE='INFO [10-27|13:00:00.000] Imported new chain segment number=1 txs=0'

work=$(mktemp -d)
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }
compose() { docker compose -p "$PROJECT" -f "$ROOT_DIR/compose.yml" -f "$work/override.yml" --env-file "$work/env" "$@"; }
in_logs() { docker exec "$PROJECT-logs-probe" "$@"; }
queries() {
  in_logs env RULE_GROUP=chain DASHBOARD=/repo/grafana/dashboards/chain.json \
    python3 /repo/agents/ups/testdata/ups_queries.py "$@"
}
rule() { queries rules "${2:-0}" | sed -n "s/^$1 //p"; }
value() { queries value "$1"; }

cleanup() {
  docker rm -f "$PROJECT-alloy" "$PROJECT-nopw" "$PROJECT-host" "$PROJECT-logs-probe" >/dev/null 2>&1 || true
  compose down -v >/dev/null 2>&1 || true
  docker volume rm "$PROJECT-textfile" >/dev/null 2>&1 || true
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
  mkdir -p "$work/certs" "$work/local" "$work/alloy" "$work/logs" "$work/nopw-logs"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj /CN=proxy \
    -addext subjectAltName=DNS:proxy -keyout "$work/certs/server.key" -out "$work/certs/server.crt" 2>/dev/null
  chmod 644 "$work/certs/server.key"
  : > "$work/local/admin-allow.conf"
  : > "$work/local/agent-allow.conf"
  local logs_pw metrics_pw
  logs_pw=$(openssl rand -hex 16)
  metrics_pw=$(openssl rand -hex 16)
  printf 'chain-check-logs:%s\n' "$(openssl passwd -6 "$logs_pw")" > "$work/local/loki-agents.htpasswd"
  printf 'chain-check-metrics:%s\n' "$(openssl passwd -6 "$metrics_pw")" > "$work/local/metrics-agents.htpasswd"
  printf '%s' "$logs_pw" > "$work/alloy/push-password"
  printf '%s' "$metrics_pw" > "$work/alloy/metrics-password"
  cp "$work/certs/server.crt" "$work/alloy/telemetry.crt"
  : > "$work/logs/cointmu-miner-error.log"
  : > "$work/nopw-logs/cointmu-miner-error.log"
  chmod -R a+rwX "$work/logs" "$work/nopw-logs"
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

has_result() { [[ -n "$(value "$1")" ]]; }

# $1 description, $2 PromQL that must return a result.
wait_for_query() { wait_for "$1" has_result "$2"; }

start_stack() {
  compose up -d --no-deps loki prometheus grafana proxy >"$work/up.log" 2>&1 || { cat "$work/up.log"; return 1; }
  docker run -d --name "$PROJECT-logs-probe" --network "${PROJECT}_logs" -v "$ROOT_DIR:/repo:ro" \
    "$TEST_IMAGE" sleep infinity >/dev/null
  wait_for "prometheus ready" in_logs curl -fs http://prometheus:9090/-/ready
  wait_for "loki ready" in_logs sh -c 'curl -fs http://loki:3100/ready | grep -q ^ready'
  docker network inspect -f '{{(index .IPAM.Config 0).Subnet}} 1;' "${PROJECT}_frontend" > "$work/local/agent-allow.conf"
  wait_for "proxy reloaded with the agents' network" compose exec -T proxy nginx -s reload
}

host_ready() { docker logs "$PROJECT-host" 2>&1 | grep -q '^READY$'; }

start_host() {
  docker volume create "$PROJECT-textfile" >/dev/null
  docker run -d --name "$PROJECT-host" --network none -v "$PWD:/src:ro" \
    -v "$PROJECT-textfile:/var/lib/cointmu-chain" "$TEST_IMAGE" bash /src/testdata/node-host.sh >/dev/null
  wait_for "fake geth node ready" host_ready \
    || { docker logs "$PROJECT-host"; return 1; }
  docker logs "$PROJECT-host" 2>&1 | grep -E '^(ok|FAIL)'
  if docker logs "$PROJECT-host" 2>&1 | grep -q '^FAIL'; then fail "fake geth node checks"; fi
}

check_promtool() {
  local output
  if output=$(docker run --rm --user 0 -v "$PROJECT-textfile:/d:ro" --entrypoint sh "$PROMETHEUS_IMAGE" \
    -c 'promtool check metrics < /d/chain.prom' 2>&1); then
    pass "promtool check metrics"
  else
    fail "promtool check metrics: $output"
  fi
}

# $1 container name, $2 host label, $3 log directory, $4 metrics password
# mount ("" = none).
start_alloy() {
  local name="$1" host="$2" logs="$3" password_mount=()
  [[ -n "$4" ]] && password_mount=(-v "$4:/etc/alloy/metrics-password:ro")
  docker rm -f "$name" >/dev/null 2>&1 || true
  docker run -d --name "$name" --network "${PROJECT}_frontend" \
    -e AGENT_HOST="$host" -e GETH_LOG_FILES=/logs/cointmu-miner-error.log -e GETH_JOURNAL_UNIT= \
    -e LOKI_PUSH_URL=https://proxy:8443/loki/api/v1/push -e LOKI_PUSH_USER=chain-check-logs \
    -e METRICS_PUSH_URL=https://proxy:8443/prometheus/api/v1/write -e METRICS_PUSH_USER=chain-check-metrics \
    -v "$ROOT_DIR/agents/alloy/config.alloy:/etc/alloy/config.alloy:ro" \
    -v "$work/alloy/push-password:/etc/alloy/push-password:ro" "${password_mount[@]}" \
    -v "$work/alloy/telemetry.crt:/etc/alloy/telemetry.crt:ro" \
    -v "$logs:/logs" -v "$PROJECT-textfile:/var/lib/cointmu-chain:ro" \
    "$ALLOY_IMAGE" run --stability.level=experimental --storage.path=/tmp/alloy /etc/alloy/config.alloy >/dev/null
}

# $1 rule uid, $2 expected state prefix, $3 offset in seconds (optional).
expect_rule() {
  local state
  state=$(rule "$1" "${3:-0}")
  if [[ "$state" == "$2"* ]]; then pass "rule $1 at +${3:-0} s: $state"; else fail "rule $1 at +${3:-0} s: $state, expected $2"; fi
}

expect_healthy() {
  local uid
  for uid in chain-stalled chain-peers-zero chain-node-behind chain-rpc-down chain-metrics-stale; do
    expect_rule "$uid" Normal
  done
  expect_rule chain-metrics-missing "NoData->OK"
}

# $1 scenario, $2 roles, $3 PromQL that shows it arrived, $4 rule uid that must fire.
check_scenario() {
  local role
  for role in $2; do docker exec "$PROJECT-host" sh -c "echo $1 > /tmp/stub/$role"; done
  wait_for_query "scenario $1 arrived" "$3" && expect_rule "$4" Alerting
  docker exec "$PROJECT-host" sh -c 'rm -f /tmp/stub/*'
}

# Appends a geth line (tail_from_end skips older ones), then looks for it in Loki.
nopw_line_arrived() {
  echo "$GETH_LINE" >> "$work/nopw-logs/cointmu-miner-error.log"
  queries logs "$NOPW_HOST" geth | grep -q Imported
}

alloy_names_password() { docker logs "$PROJECT-nopw" 2>&1 | grep -q 'metrics-password: no such file'; }

# Alloy without the metrics password: logs keep flowing, the failure is named.
check_missing_password() {
  start_alloy "$PROJECT-nopw" "$NOPW_HOST" "$work/nopw-logs" ""
  wait_for "logs still arrive without the metrics password" nopw_line_arrived
  if [[ "$(docker inspect -f '{{.State.Running}}' "$PROJECT-nopw")" == true ]]; then
    pass "Alloy keeps running without the metrics password"
  else
    fail "Alloy stopped without the metrics password"
  fi
  wait_for "Alloy's log names the missing metrics password" alloy_names_password
  if [[ -n "$(value "cointmu_chain_rpc_up{host=\"$NOPW_HOST\"}")" ]]; then
    fail "metrics arrived without the metrics password"
  fi
  docker rm -f "$PROJECT-nopw" >/dev/null
}

docker build -q -t "$TEST_IMAGE" ../ups/testdata >/dev/null
prepare
start_stack
start_host
check_promtool
start_alloy "$PROJECT-alloy" "$AGENT_HOST" "$work/logs" "$work/alloy/metrics-password"
check_missing_password
wait_for_query "metrics arrive through nginx (both roles)" \
  "count(cointmu_chain_rpc_up{job=\"chain\",host=\"$AGENT_HOST\"} == 1) == 2"
if [[ "$(value "cointmu_chain_head_difficulty{host=\"$AGENT_HOST\",role=\"miner\"}")" == 2355889 ]]; then
  pass "difficulty as written by chain-metrics.py"
else
  fail "difficulty value"
fi
if queries panels "$AGENT_HOST"; then pass "every chain.json panel query returns data"; else fail "dashboard panels"; fi
expect_healthy

check_scenario behind miner 'scalar(max(cointmu_chain_head_block)) - cointmu_chain_head_block{role="miner"} > 10' chain-node-behind
check_scenario peers0 miner 'cointmu_chain_peers{role="miner"} == 0' chain-peers-zero
check_scenario down miner 'cointmu_chain_rpc_up{role="miner"} == 0' chain-rpc-down
check_scenario stalled "bootnode miner" 'time() - max(cointmu_chain_head_timestamp_seconds) > 600' chain-stalled
wait_for_query "back to healthy" \
  'time() - max(cointmu_chain_head_timestamp_seconds) < 60 and on() count(cointmu_chain_head_block) == 2 and on() min(cointmu_chain_peers) > 0'
expect_healthy

# (b) transport outage: Alloy stopped, the timer keeps writing.
docker stop "$PROJECT-alloy" >/dev/null
sleep "$OUTAGE_SECONDS"
expect_rule chain-metrics-missing "NoData->OK"
expect_rule chain-metrics-missing Alerting "$MISSING_OFFSET_SECONDS"
expect_rule chain-metrics-stale "NoData->OK" "$MISSING_OFFSET_SECONDS"

# (a) timer stopped while Alloy keeps scraping the last file.
restarted=$(date +%s)
start_alloy "$PROJECT-alloy" "$AGENT_HOST" "$work/logs" "$work/alloy/metrics-password"
wait_for_query "fresh samples after the Alloy restart" "timestamp(cointmu_chain_rpc_up{host=\"$AGENT_HOST\"}) > $restarted"
docker exec "$PROJECT-host" touch /tmp/stop-timer
sleep "$STALE_WAIT_SECONDS"
expect_rule chain-metrics-stale Alerting
expect_rule chain-metrics-missing "NoData->OK"
expect_rule chain-rpc-down Normal

(( failures == 0 )) || { echo "$failures check(s) failed" >&2; docker logs --tail 30 "$PROJECT-alloy" >&2; exit 1; }
echo "OK: chain metrics pipeline as expected"
