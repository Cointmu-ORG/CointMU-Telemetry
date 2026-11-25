#!/usr/bin/env bash
# Moves an agent from the old single config (testdata/legacy-*.alloy, what the
# hosts ran before the fragments) to the fragments, on the same data folder, in
# a throwaway Loki and Prometheus (own compose project). Checks:
# - geth log file: lines written before the switch, while Alloy is stopped, and
#   after it all arrive exactly once; the later ones carry scope=cointmu
# - UPS journal: the same, scope=ups
# - the metrics arrive with their scope label; all fragments load as one config
# Takes about two minutes.
#
#   agent/check-migration.sh
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT_DIR="$PWD"
readonly ROOT_DIR
ALLOY_IMAGE=$(sed -n 's/^readonly ALLOY_IMAGE="\(.*\)"$/\1/p' scopes/cointmu/alloy/check-redaction.sh)
readonly ALLOY_IMAGE
readonly TEST_IMAGE=cointmu-migration-test:local
readonly PROJECT="cointmu-migration-check-$$"
readonly WAIT_SECONDS=120
# Lines per phase: before the switch, while Alloy is stopped, after it.
readonly PHASE_LINES=20
readonly GETH_HOST=migration-geth
readonly UPS_HOST=migration-ups

work=$(mktemp -d)
fail() { echo "FAIL: $*" >&2; docker logs --tail 30 "$PROJECT-alloy" >&2 || true; exit 1; }
pass() { echo "ok:   $*"; }
compose() { docker compose -p "$PROJECT" -f compose.yml --env-file "$work/env" "$@"; }
queries() { docker exec "$PROJECT-probe" python3 /repo/scopes/ups/testdata/ups_queries.py "$@"; }

cleanup() {
  docker rm -f "$PROJECT-alloy" "$PROJECT-probe" >/dev/null 2>&1 || true
  compose down -v >/dev/null 2>&1 || true
  docker volume rm "$PROJECT-cointmu" "$PROJECT-ups" "$PROJECT-journal" >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

wait_for() {
  local what="$1" deadline=$((SECONDS + WAIT_SECONDS)); shift
  while (( SECONDS < deadline )); do "$@" >/dev/null 2>&1 && { pass "$what"; return 0; }; sleep 1; done
  fail "$what (gave up after $WAIT_SECONDS s)"
}

prepare() {
  sed -e 's/^TLS_GID=.*/TLS_GID=12345/' -e "s/^SECRET_KEY=.*/SECRET_KEY=$(openssl rand -hex 32)/" \
    -e "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 24)/" \
    -e "s/^GRAFANA_ADMIN_PASSWORD=.*/GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 24)/" .env.example > "$work/env"
  mkdir -p "$work/conf.d" "$work/logs" "$work/textfile"
  cp agent/push-logs.alloy agent/push-metrics.alloy scopes/cointmu/alloy/cointmu.alloy scopes/ups/ups.alloy "$work/conf.d/"
  echo unused > "$work/password"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 \
    -subj /CN=check -keyout "$work/key.pem" -out "$work/telemetry.crt" 2>/dev/null
  : > "$work/logs/cointmu-miner-error.log"
  echo 'cointmu_chain_rpc_up{role="miner"} 1' > "$work/textfile/chain.prom"
  echo 'ups_up{ups="check"} 1' > "$work/textfile/ups.prom"
  chmod -R a+rX "$work"
}

start_stack() {
  compose up -d --no-deps loki prometheus >"$work/up.log" 2>&1 || { cat "$work/up.log" >&2; exit 1; }
  docker run -d --name "$PROJECT-probe" --network "${PROJECT}_logs" -v "$ROOT_DIR:/repo:ro" "$TEST_IMAGE" sleep infinity >/dev/null
  wait_for "prometheus ready" docker exec "$PROJECT-probe" curl -fs http://prometheus:9090/-/ready
  wait_for "loki ready" docker exec "$PROJECT-probe" sh -c 'curl -fs http://loki:3100/ready | grep -q ^ready'
}

# $1 host label, $2 storage volume, $3 config file or folder in the container.
start_alloy() {
  docker run -d --name "$PROJECT-alloy" --network "${PROJECT}_logs" \
    -e AGENT_HOST="$1" -e GETH_LOG_FILES=/logs/cointmu-miner-error.log -e GETH_JOURNAL_UNIT= \
    -e UPS_NAME=check -e UPS_JOURNAL_PATH=/journal -e CHAIN_TEXTFILE_DIR=/textfile -e UPS_TEXTFILE_DIR=/textfile \
    -e LOKI_PUSH_URL=http://loki:3100/loki/api/v1/push -e LOKI_PUSH_USER=check \
    -e METRICS_PUSH_URL=http://prometheus:9090/api/v1/write -e METRICS_PUSH_USER=check \
    -v "$work/password:/etc/alloy/push-password:ro" -v "$work/password:/etc/alloy/metrics-password:ro" \
    -v "$work/telemetry.crt:/etc/alloy/telemetry.crt:ro" -v "$work/conf.d:/etc/alloy/conf.d:ro" \
    -v "$ROOT_DIR/agent/testdata:/legacy:ro" -v "$work/logs:/logs:ro" -v "$work/textfile:/textfile:ro" \
    -v "$PROJECT-journal:/journal:ro" -v "$2:/data" \
    "$ALLOY_IMAGE" run --stability.level=experimental --storage.path=/data \
    --server.http.listen-addr=0.0.0.0:12345 "$3" >/dev/null
}
stop_alloy() { docker stop -t 30 "$PROJECT-alloy" >/dev/null && docker rm "$PROJECT-alloy" >/dev/null; }

tailing() {
  local metrics
  metrics=$(docker exec "$PROJECT-probe" curl -fs "http://$PROJECT-alloy:12345/metrics") || return 1
  grep -q '^loki_source_file_files_active_total{component_id="loki.source.file.geth",.*} 1$' <<<"$metrics"
}

# Numbered lines $1..$2.
geth_lines() {
  local i
  for i in $(seq "$1" "$2"); do
    echo "INFO [10-27|13:00:00.000] Imported new chain segment number=$i txs=0"
  done >> "$work/logs/cointmu-miner-error.log"
}

# Numbered lines $1..$2 of nut-server.service as one more journal file.
journal_lines() {
  docker run --rm --network none -v "$PROJECT-journal:/journal" "$TEST_IMAGE" bash -c '
    now=$(date +%s%6N)
    for i in $(seq '"$1 $2"'); do
      printf "__REALTIME_TIMESTAMP=%s\n__MONOTONIC_TIMESTAMP=%s\n_BOOT_ID=0123456789abcdef0123456789abcdef\n_SYSTEMD_UNIT=nut-server.service\nSYSLOG_IDENTIFIER=upsd\nMESSAGE=migration number=%s\n\n" "$((now + i))" "$i" "$i"
    done | /lib/systemd/systemd-journal-remote -o "/journal/part-'"$1"'.journal" - 2>/dev/null'
}

# $1 host, $2 job: every number 1..3*PHASE_LINES exactly once; scope $3 on the
# lines after the first phase only (what Alloy read before the switch has none).
check_lines() {
  queries logs "$1" "$2" | python3 -c '
import collections, json, re, sys
scope, phase = sys.argv[1], int(sys.argv[2])
lines = [(labels, int(re.search(r"number=(\d+)", line).group(1))) for labels, line in json.load(sys.stdin)]
counts = collections.Counter(n for _, n in lines)
wrong = {n: counts[n] for n in range(1, 3 * phase + 1) if counts[n] != 1}
if wrong: sys.exit(f"line number -> times received: {wrong}")
bad = [n for labels, n in lines if labels.get("scope") != (scope if n > phase else None)]
if bad: sys.exit(f"scope label wrong on lines {bad}")
' "$3" "$PHASE_LINES"
}

received() { [[ "$(queries logs "$1" "$2" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" -ge "$3" ]]; }
has_metric() { [[ -n "$(queries value "$1")" ]]; }

# $1 scope, $2 job, $3 host, $4 legacy config, $5 function that writes lines,
# $6 metric that must carry the scope.
migrate() {
  local scope="$1" job="$2" host="$3" writer="$5"
  if [[ "$scope" == ups ]]; then "$writer" 1 "$PHASE_LINES"; fi   # a journal is read from its start
  start_alloy "$host" "$PROJECT-$scope" "/legacy/$4"
  if [[ "$scope" == cointmu ]]; then                              # a file is tailed from its end
    wait_for "$scope: old config tails the log" tailing
    "$writer" 1 "$PHASE_LINES"
  fi
  wait_for "$scope: old config ships the first lines" received "$host" "$job" "$PHASE_LINES"
  stop_alloy
  "$writer" $((PHASE_LINES + 1)) $((2 * PHASE_LINES))
  start_alloy "$host" "$PROJECT-$scope" /etc/alloy/conf.d
  wait_for "$scope: fragments ship the lines written meanwhile" received "$host" "$job" $((2 * PHASE_LINES))
  if [[ "$scope" == cointmu ]]; then "$writer" $((2 * PHASE_LINES + 1)) $((3 * PHASE_LINES)); else
    stop_alloy; "$writer" $((2 * PHASE_LINES + 1)) $((3 * PHASE_LINES)); start_alloy "$host" "$PROJECT-$scope" /etc/alloy/conf.d
  fi
  wait_for "$scope: fragments ship new lines" received "$host" "$job" $((3 * PHASE_LINES))
  check_lines "$host" "$job" "$scope" || fail "$scope: lines lost, duplicated or mislabelled"
  pass "$scope: every line exactly once, scope label from the switch on"
  wait_for "$scope: metrics carry the scope" has_metric "$6{host=\"$host\",scope=\"$scope\"}"
  stop_alloy
}

docker build -q -t "$TEST_IMAGE" scopes/ups/testdata >/dev/null
for volume in cointmu ups journal; do docker volume create "$PROJECT-$volume" >/dev/null; done
prepare
start_stack
migrate cointmu geth "$GETH_HOST" legacy-cointmu.alloy geth_lines cointmu_chain_rpc_up
migrate ups ups "$UPS_HOST" legacy-ups.alloy journal_lines ups_up
echo "OK: switching to the fragments loses and duplicates nothing"
