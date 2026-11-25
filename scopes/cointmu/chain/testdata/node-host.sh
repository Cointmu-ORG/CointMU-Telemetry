#!/usr/bin/env bash
# Runs inside the throwaway "geth node" container that check-chain.sh starts:
# two stub RPCs (bootnode :8545, miner :8546, as on server101),
# chain-metrics.py, its units and the tmpfiles line installed as on a real
# node. Checks the users, owners and modes (README's table), the refusal
# messages and alloy-preflight.sh, then runs chain-metrics.py every few
# seconds, like the timer, until /tmp/stop-timer exists. Never run this on a
# real host: it adds users and writes /etc/default/alloy.
set -euo pipefail

readonly SRC=/src
readonly OUT_DIR=/var/lib/cointmu-chain
readonly OUT_FILE="$OUT_DIR/chain.prom"
readonly SCRIPT=/usr/local/lib/cointmu-chain/chain-metrics.py
readonly CONFIG_FILE=/etc/cointmu-chain/cointmu-chain.conf
readonly NODES='NODES=bootnode=http://127.0.0.1:8545 miner=http://127.0.0.1:8546'
readonly STOP_FILE=/tmp/stop-timer
readonly FEED_INTERVAL_SECONDS=5
readonly SETTLE_SECONDS=2
# stub-rpc.py: 14 s blocks, difficulty 2355889.
readonly BLOCK_TIME='14.0'
readonly HASHRATE='168277.7857142857'

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }
as_user() { local user="$1"; shift; setpriv --reuid "$user" --regid "$user" --init-groups -- "$@"; }

# $1 description, $2 expected text in stderr, rest: the command.
expect_refusal() {
  local what="$1" expected="$2" output; shift 2
  if output=$("$@" 2>&1); then
    fail "$what: did not fail"
  elif [[ "$output" == *"$expected"* ]]; then
    pass "$what: ${output//$'\n'/ | }"
  else
    fail "$what: unexpected message: $output"
  fi
}

refuse_collector() { expect_refusal "$1" "$2" as_user cointmu-chain "$SCRIPT"; }

start_stubs() {
  python3 "$SRC/testdata/stub-rpc.py" 8545 bootnode &
  python3 "$SRC/testdata/stub-rpc.py" 8546 miner &
  mkdir -p /tmp/stub
  sleep "$SETTLE_SECONDS"
}

install_collector() {
  useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin cointmu-chain
  install -d -m 755 /usr/local/lib/cointmu-chain /etc/cointmu-chain
  install -m 755 "$SRC/chain-metrics.py" "$SCRIPT"
  printf '%s\n' "$NODES" > "$CONFIG_FILE"
  install -m 644 "$SRC/cointmu-chain.tmpfiles.conf" /etc/tmpfiles.d/cointmu-chain.conf
  install -m 644 "$SRC/cointmu-chain-metrics.service" "$SRC/cointmu-chain-metrics.timer" /etc/systemd/system/
}

check_config_refusals() {
  printf 'NODES=miner=http://192.0.2.10:8545\n' > "$CONFIG_FILE"
  refuse_collector "RPC not on loopback" "is not <role>=http://127.0.0.1:<port>"
  printf 'NODES=miner=http://127.0.0.1:8545 miner=http://127.0.0.1:8546\n' > "$CONFIG_FILE"
  refuse_collector "role twice" "role 'miner' appears twice"
  printf '# nothing\n' > "$CONFIG_FILE"
  refuse_collector "no NODES" "no NODES in"
  printf '%s\n' "$NODES" > "$CONFIG_FILE"
}

check_modes() {
  local expected actual path
  for expected in "$OUT_DIR cointmu-chain alloy 2750" "$OUT_FILE cointmu-chain alloy 640" \
    "$SCRIPT root root 755" "$CONFIG_FILE root root 644"; do
    path="${expected%% *}"
    actual="$path $(stat -c '%U %G %a' "$path")"
    if [[ "$actual" == "$expected" ]]; then pass "owner/mode $actual"; else fail "owner/mode $actual, expected $expected"; fi
  done
  if as_user alloy cat "$OUT_FILE" >/dev/null; then pass "alloy can read chain.prom"; else fail "alloy cannot read chain.prom"; fi
  if as_user nobody cat "$OUT_FILE" >/dev/null 2>&1; then fail "nobody can read chain.prom"; else pass "other users cannot read chain.prom"; fi
  if id -nG cointmu-chain | grep -qw alloy; then fail "cointmu-chain is in group alloy"; else pass "cointmu-chain is not in group alloy"; fi
}

# $1 regex that must match a whole line of chain.prom.
expect_line() {
  if grep -qxE "$1" "$OUT_FILE"; then pass "chain.prom has $1"; else fail "chain.prom lacks $1"; fi
}

check_output() {
  local role
  for role in bootnode miner; do
    expect_line "cointmu_chain_rpc_up\{role=\"$role\"\} 1"
    expect_line "cointmu_chain_head_block\{role=\"$role\"\} [0-9]+"
    expect_line "cointmu_chain_head_difficulty\{role=\"$role\"\} 2355889"
    expect_line "cointmu_chain_block_time_seconds\{role=\"$role\"\} ${BLOCK_TIME//./\\.}"
    expect_line "cointmu_chain_hashrate_estimate\{role=\"$role\"\} ${HASHRATE//./\\.}"
    expect_line "cointmu_chain_peers\{role=\"$role\"\} 2"
    expect_line "cointmu_chain_syncing\{role=\"$role\"\} 0"
    expect_line "cointmu_chain_scrape_timestamp_seconds\{role=\"$role\"\} [0-9]{10}"
  done
  if grep -qE '0x[0-9a-fA-F]{40}|([0-9]{1,3}\.){3}[0-9]{1,3}' "$OUT_FILE"; then
    fail "chain.prom contains an address"
  else
    pass "no address in chain.prom"
  fi
}

check_rpc_down() {
  echo down > /tmp/stub/miner
  as_user cointmu-chain "$SCRIPT" 2>/dev/null
  if [[ "$(grep -c '{role="miner"}' "$OUT_FILE")" == 2 ]] && grep -qxF 'cointmu_chain_rpc_up{role="miner"} 0' "$OUT_FILE" \
    && grep -qxF 'cointmu_chain_rpc_up{role="bootnode"} 1' "$OUT_FILE"; then
    pass "miner RPC down: only its rpc_up 0 and timestamp; bootnode unaffected"
  else
    fail "miner RPC down: $(tr '\n' ' ' < "$OUT_FILE")"
  fi
  rm /tmp/stub/miner
}

check_preflight() {
  local preflight="$SRC/alloy-preflight.sh"
  install -d -m 755 /etc/alloy /etc/default
  printf 'LOKI_PUSH_USER=x\n' > /etc/default/alloy
  expect_refusal "preflight without metrics password or METRICS_PUSH_*" "metrics-password missing or empty" "$preflight"
  expect_refusal "preflight names METRICS_PUSH_URL" "METRICS_PUSH_URL in /etc/default/alloy" "$preflight"
  printf 'x' | install -m 644 -o root -g alloy /dev/stdin /etc/alloy/metrics-password
  printf 'METRICS_PUSH_URL=https://proxy/prometheus/api/v1/write\nMETRICS_PUSH_USER=x\n' >> /etc/default/alloy
  expect_refusal "preflight, password file mode 644" "expected alloy 640" "$preflight"
  chmod 640 /etc/alloy/metrics-password
  if "$preflight" >/dev/null; then pass "preflight passes with both in place"; else fail "preflight refused a complete setup"; fi
}

start_stubs
install_collector
refuse_collector "before Alloy is installed" "no group 'alloy': install Alloy first"
# What the Alloy package does: a system user and group alloy.
useradd --system --user-group --no-create-home --shell /usr/sbin/nologin alloy
# check-chain.sh mounts a volume there, which already exists (root, 755).
if [[ -d "$OUT_DIR" ]]; then
  refuse_collector "before systemd-tmpfiles --create" "is group root mode 755, expected alloy 2750"
else
  refuse_collector "before systemd-tmpfiles --create" "missing $OUT_DIR"
fi
systemd-tmpfiles --create /etc/tmpfiles.d/cointmu-chain.conf
chmod g-s "$OUT_DIR"
refuse_collector "directory without setgid" "expected alloy 2750"
systemd-tmpfiles --create /etc/tmpfiles.d/cointmu-chain.conf
check_config_refusals
as_user cointmu-chain "$SCRIPT"
check_modes
check_output
check_rpc_down
check_preflight
if systemd-analyze verify /etc/systemd/system/cointmu-chain-metrics.service \
  /etc/systemd/system/cointmu-chain-metrics.timer 2>/tmp/verify.log; then
  pass "systemd-analyze verify (service and timer)"
else
  fail "systemd-analyze verify: $(cat /tmp/verify.log)"
fi

(( failures == 0 )) || { echo "$failures check(s) failed" >&2; exit 1; }
echo READY
while [[ ! -e "$STOP_FILE" ]]; do
  as_user cointmu-chain "$SCRIPT" || echo "chain-metrics.py failed" >&2
  sleep "$FEED_INTERVAL_SECONDS"
done
echo "timer stopped"
sleep infinity
