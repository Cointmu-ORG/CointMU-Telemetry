#!/usr/bin/env bash
# Runs inside the throwaway "UPS host" container that check-ups.sh starts: a
# fake UPS (dummy-ups behind the real upsd), ups-metrics.sh, its units and the
# tmpfiles line installed as on the real host. Checks the users, owners and
# modes (README's table) and the failure messages, then runs ups-metrics.sh
# every few seconds, like the timer, until /tmp/stop-timer exists. Never run
# this on a real host: it rewrites /etc/nut and adds users.
set -euo pipefail

readonly SRC=/src
readonly OUT_DIR=/var/lib/cointmu-ups
readonly SCRIPT=/usr/local/lib/cointmu-ups/ups-metrics.sh
readonly STOP_FILE=/tmp/stop-timer
readonly FEED_INTERVAL_SECONDS=5
readonly SETTLE_SECONDS=3

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }
as_user() { local user="$1"; shift; setpriv --reuid "$user" --regid "$user" --init-groups -- "$@"; }

# $1 description, $2 expected text in stderr; runs ups-metrics.sh as cointmu-ups.
expect_refusal() {
  local output
  if output=$(as_user cointmu-ups "$SCRIPT" 2>&1); then
    fail "$1: ups-metrics.sh did not fail"
  elif [[ "$output" == *"$2"* ]]; then
    pass "$1: $output"
  else
    fail "$1: unexpected message: $output"
  fi
}

start_fake_ups() {
  echo 'MODE=standalone' > /etc/nut/nut.conf
  printf '[check]\n  driver = dummy-ups\n  port = check.dev\n' > /etc/nut/ups.conf
  cat > /etc/nut/check.dev <<'EOF'
battery.charge: 76
battery.charge.low: 20
battery.runtime: 1500
battery.runtime.low: 180
ups.load: 23
input.voltage: 229.5
output.voltage: 230.1
ups.status: OL CHRG
EOF
  echo 'LISTEN 127.0.0.1 3493' > /etc/nut/upsd.conf
  : > /etc/nut/upsd.users
  chown root:nut /etc/nut/*
  chmod 640 /etc/nut/*
  /lib/nut/dummy-ups -a check -u nut >/dev/null 2>&1
  upsd -u nut >/dev/null 2>&1
  sleep "$SETTLE_SECONDS"
}

install_collector() {
  useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin cointmu-ups
  install -d -m 755 /usr/local/lib/cointmu-ups /etc/cointmu-ups
  install -m 755 "$SRC/ups-metrics.sh" "$SCRIPT"
  printf 'UPS=check@localhost\nHOST_LABEL=\n' > /etc/cointmu-ups/cointmu-ups.conf
  install -m 644 "$SRC/cointmu-ups.tmpfiles.conf" /etc/tmpfiles.d/cointmu-ups.conf
  install -m 644 "$SRC/cointmu-ups-metrics.service" "$SRC/cointmu-ups-metrics.timer" /etc/systemd/system/
}

check_modes() {
  local expected actual path
  for expected in "/var/lib root root 755" "$OUT_DIR cointmu-ups alloy 2750" \
    "$OUT_DIR/ups.prom cointmu-ups alloy 640" "$SCRIPT root root 755"; do
    path="${expected%% *}"
    actual="$path $(stat -c '%U %G %a' "$path")"
    if [[ "$actual" == "$expected" ]]; then pass "owner/mode $actual"; else fail "owner/mode $actual, expected $expected"; fi
  done
  if as_user alloy cat "$OUT_DIR/ups.prom" >/dev/null; then pass "alloy can read ups.prom"; else fail "alloy cannot read ups.prom"; fi
  if as_user nobody cat "$OUT_DIR/ups.prom" >/dev/null 2>&1; then fail "nobody can read ups.prom"; else pass "other users cannot read ups.prom"; fi
  if id -nG cointmu-ups | grep -qw alloy; then fail "cointmu-ups is in group alloy"; else pass "cointmu-ups is not in group alloy"; fi
}

check_output() {
  local file="$OUT_DIR/ups.prom" line
  for line in 'ups_up{ups="check"} 1' 'ups_battery_charge_percent{ups="check"} 76' \
    'ups_battery_runtime_seconds{ups="check"} 1500' 'ups_input_voltage_volts{ups="check"} 229.5' \
    'ups_status{ups="check",flag="OL"} 1' 'ups_status{ups="check",flag="OB"} 0' \
    'ups_info{ups="check",model="Dummy UPS",driver="dummy-ups"} 1'; do
    if grep -qxF "$line" "$file"; then pass "ups.prom has $line"; else fail "ups.prom lacks $line"; fi
  done
  if grep -q '^ups_scrape_timestamp_seconds{ups="check"} [0-9]\{10\}$' "$file"; then
    pass "ups.prom has ups_scrape_timestamp_seconds"
  else
    fail "no ups_scrape_timestamp_seconds"
  fi
}

check_driver_down() {
  pkill -f '/lib/nut/dummy-ups'
  sleep "$SETTLE_SECONDS"
  as_user cointmu-ups "$SCRIPT"
  if [[ "$(grep -c . "$OUT_DIR/ups.prom")" == 2 ]] && grep -qxF 'ups_up{ups="check"} 0' "$OUT_DIR/ups.prom"; then
    pass "driver down: only ups_up 0 and the timestamp"
  else
    fail "driver down: $(tr '\n' ' ' < "$OUT_DIR/ups.prom")"
  fi
  /lib/nut/dummy-ups -a check -u nut >/dev/null 2>&1
  sleep "$SETTLE_SECONDS"
}

start_fake_ups
install_collector
expect_refusal "before Alloy is installed" "no group 'alloy': install Alloy first"
# What the Alloy package does: a system user and group alloy.
useradd --system --user-group --no-create-home --shell /usr/sbin/nologin alloy
# check-ups.sh mounts a volume there, which already exists (root, 755).
if [[ -d "$OUT_DIR" ]]; then
  expect_refusal "before systemd-tmpfiles --create" "is group root mode 755, expected alloy 2750"
else
  expect_refusal "before systemd-tmpfiles --create" "missing $OUT_DIR"
fi
systemd-tmpfiles --create /etc/tmpfiles.d/cointmu-ups.conf
chmod g-s "$OUT_DIR"
expect_refusal "directory without setgid" "expected alloy 2750"
systemd-tmpfiles --create /etc/tmpfiles.d/cointmu-ups.conf
as_user cointmu-ups "$SCRIPT"
check_modes
check_output
check_driver_down
if systemd-analyze verify /etc/systemd/system/cointmu-ups-metrics.service \
  /etc/systemd/system/cointmu-ups-metrics.timer 2>/tmp/verify.log; then
  pass "systemd-analyze verify (service and timer)"
else
  fail "systemd-analyze verify: $(cat /tmp/verify.log)"
fi

(( failures == 0 )) || { echo "$failures check(s) failed" >&2; exit 1; }
echo READY
while [[ ! -e "$STOP_FILE" ]]; do
  as_user cointmu-ups "$SCRIPT" || echo "ups-metrics.sh failed" >&2
  sleep "$FEED_INTERVAL_SECONDS"
done
echo "timer stopped"
sleep infinity
