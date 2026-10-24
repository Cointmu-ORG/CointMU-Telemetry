#!/usr/bin/env bash
# Runs inside the throwaway container that check-notify.sh starts: a fake UPS
# (dummy-ups) behind the real upsd, upsmon and upssched, with the repository's
# upssched.conf.snippet, upsmon.conf.snippet and ups-notify.sh installed at
# their real paths. discord.com resolves to 127.0.0.1, where
# discord-listener.py records every post. Never run this on a real host: it
# rewrites /etc/nut.
set -euo pipefail

readonly SRC=/src
readonly POSTS=/tmp/posts.jsonl
readonly DELAY_FILE=/tmp/listener-delay
readonly STAMP=/tmp/shutdown-stamp
readonly NUT_LOG=/tmp/nut.log
# What ups-notify.sh sends to syslog (logger), received on /dev/log.
readonly SYSLOG=/tmp/syslog.log
readonly WEBHOOK_SECRET=check-webhook-token
readonly UPS_DEV=/etc/nut/ups.dev
readonly SETTLE_SECONDS=4
readonly ONBATT_WAIT_SECONDS=35
readonly FINALDELAY_SECONDS=10
readonly SHUTDOWN_WAIT_SECONDS=25
readonly LISTENER_DELAY_SECONDS=5
readonly MONITOR_ONLY_WAIT_SECONDS=15
readonly UPSMON_PASSWORD=check-upsmon-pw

failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }
post_count() { if [[ -f "$POSTS" ]]; then wc -l < "$POSTS"; else echo 0; fi; }
set_status() { sed -i "s/^ups.status: .*/ups.status: $1/" "$UPS_DEV"; }

# $1 expected number of posts, $2 description.
expect_posts() {
  local count
  count=$(post_count)
  if (( count == $1 )); then pass "$2 ($count posts)"; else fail "$2: expected $1 posts, got $count"; fi
}

# $1 index (0-based), $2 text the post must contain.
expect_post_text() {
  if python3 - "$POSTS" "$1" "$2" <<'EOF'; then pass "post $1 contains '$2'"; else fail "post $1 lacks '$2'"; fi
import json, sys
posts = [json.loads(line) for line in open(sys.argv[1])]
index, text = int(sys.argv[2]), sys.argv[3]
sys.exit(0 if index < len(posts) and text in json.loads(posts[index]["body"])["content"] else 1)
EOF
}

# The container has no syslog daemon; keep logger's lines for the checks.
start_syslog_sink() {
  python3 - "$SYSLOG" <<'EOF' &
import socket, sys
sock = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
sock.bind("/dev/log")
with open(sys.argv[1], "ab", buffering=0) as log:
    while True:
        log.write(sock.recv(65536) + b"\n")
EOF
  for _ in $(seq 20); do [[ -S /dev/log ]] && break; sleep 0.1; done
  chmod 666 /dev/log
}

setup_listener() {
  local dir=/tmp/tls
  mkdir -p "$dir"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj /CN=check-ca \
    -addext basicConstraints=critical,CA:TRUE -keyout "$dir/ca.key" -out "$dir/ca.crt" 2>/dev/null
  openssl req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -subj /CN=discord.com \
    -keyout "$dir/server.key" -out "$dir/server.csr" 2>/dev/null
  openssl x509 -req -in "$dir/server.csr" -CA "$dir/ca.crt" -CAkey "$dir/ca.key" -days 1 \
    -extfile <(echo 'subjectAltName=DNS:discord.com') -out "$dir/server.crt" 2>/dev/null
  cp "$dir/ca.crt" /usr/local/share/ca-certificates/check-ca.crt
  update-ca-certificates >/dev/null 2>&1
  python3 "$SRC/testdata/discord-listener.py" "$dir/server.crt" "$dir/server.key" "$POSTS" "$DELAY_FILE" &
}

install_notifier() {
  install -d -m 755 /usr/local/lib/cointmu-ups
  install -m 755 "$SRC/ups-notify.sh" /usr/local/lib/cointmu-ups/ups-notify.sh
  install -d -m 750 -o root -g nut /etc/cointmu-ups
  printf 'UPS=ups@localhost\nHOST_LABEL=check-host\n' > /etc/cointmu-ups/cointmu-ups.conf
  printf 'https://discord.com/api/webhooks/123456/%s' "$WEBHOOK_SECRET" \
    | install -m 600 -o nut -g nut /dev/stdin /etc/cointmu-ups/discord-webhook
  install -m 640 -o root -g nut "$SRC/upssched.conf.snippet" /etc/nut/upssched.conf
  printf '#!/bin/sh\ndate +%%s.%%N > %s\n' "$STAMP" > /usr/local/bin/stub-shutdown
  chmod 755 /usr/local/bin/stub-shutdown
}

# $1: monitor-only (as installed) or shutdown (automatic shutdown turned on
# the way upsmon.conf.snippet describes). Both snippets are used as they are,
# with the password filled in.
write_nut_config() {
  echo 'MODE=standalone' > /etc/nut/nut.conf
  printf '[ups]\n  driver = dummy-ups\n  port = ups.dev\n' > /etc/nut/ups.conf
  printf 'battery.charge: 87\nbattery.runtime: 1380\nups.status: OL\n' > "$UPS_DEV"
  echo 'LISTEN 127.0.0.1 3493' > /etc/nut/upsd.conf
  sed "s/<UPSMON_PASSWORD>/$UPSMON_PASSWORD/" "$SRC/upsd.users.snippet" > /etc/nut/upsd.users
  {
    echo 'SHUTDOWNCMD "/usr/local/bin/stub-shutdown"'
    echo 'POWERDOWNFLAG /tmp/killpower'
    echo 'POLLFREQ 1'
    echo 'POLLFREQALERT 1'
    sed "s/<UPSMON_PASSWORD>/$UPSMON_PASSWORD/" "$SRC/upsmon.conf.snippet" | grep -vE '^\s*(#|$)'
  } > /etc/nut/upsmon.conf
  if [[ "$1" == shutdown ]]; then
    sed -i -e 's/^\(MONITOR [^ ]*\) 0 \(.*\) secondary$/\1 1 \2 primary/' -e 's/^MINSUPPLIES 0$/MINSUPPLIES 1/' \
      /etc/nut/upsmon.conf
    sed -i 's/upsmon secondary/upsmon primary/' /etc/nut/upsd.users
  fi
  chown root:nut /etc/nut/*
  chmod 640 /etc/nut/*
}

start_nut() {
  /lib/nut/dummy-ups -a ups -u nut >>"$NUT_LOG" 2>&1
  upsd -u nut >>"$NUT_LOG" 2>&1
  upsmon -F >>"$NUT_LOG" 2>&1 &
  sleep "$SETTLE_SECONDS"
}

stop_nut() {
  pkill -x upsmon || true
  pkill -x upssched || true
  pkill -x upsd || true
  pkill -f '/lib/nut/dummy-ups' || true
  sleep 1
  rm -f /tmp/killpower /run/nut/upssched.pipe /run/nut/upssched.lock "$STAMP"
}

# Every post: allowed_mentions empty, content without the webhook or "@".
check_payloads() {
  if python3 - "$POSTS" <<'EOF'; then pass "every payload has allowed_mentions empty, no @"; else fail "payload check"; fi
import json, sys
for line in open(sys.argv[1]):
    body = json.loads(json.loads(line)["body"])
    assert body["allowed_mentions"] == {"parse": []}, body
    assert "@" not in body["content"], body
EOF
  if grep -rqF "$WEBHOOK_SECRET" "$NUT_LOG" "$SYSLOG" /tmp/notify-direct.log; then
    fail "the webhook token appears in a log"
  else
    pass "no webhook token in the logs"
  fi
}

direct_events() {
  local event before
  for event in fsd commbad commok replbatt test; do
    before=$(post_count)
    sudo_nut /usr/local/lib/cointmu-ups/ups-notify.sh "$event" 2>>/tmp/notify-direct.log \
      || fail "ups-notify.sh $event exited non-zero"
    (( $(post_count) == before + 1 )) || fail "ups-notify.sh $event did not post"
  done
  pass "direct calls post one message each (fsd commbad commok replbatt test)"
  if sudo_nut /usr/local/lib/cointmu-ups/ups-notify.sh bogus 2>>/tmp/notify-direct.log; then
    fail "unknown event accepted"
  fi
}

sudo_nut() { setpriv --reuid nut --regid nut --init-groups -- "$@"; }

# Seconds between two "time" values: post $1 and the shutdown stamp.
seconds_before_stamp() {
  python3 - "$POSTS" "$1" "$STAMP" <<'EOF'
import json, sys
posts = [json.loads(line) for line in open(sys.argv[1])]
print(f"{float(open(sys.argv[3]).read()) - posts[int(sys.argv[2])]['time']:.1f}")
EOF
}

start_syslog_sink
setup_listener
install_notifier
write_nut_config monitor-only
start_nut
expect_posts 0 "upsmon start while OL"

set_status 'OB DISCHRG'; sleep "$SETTLE_SECONDS"; set_status OL; sleep "$SETTLE_SECONDS"
expect_posts 0 "blip shorter than the 30 s onbatt timer"

set_status 'OB DISCHRG'; sleep "$ONBATT_WAIT_SECONDS"
expect_posts 1 "on battery for 35 s"
expect_post_text 0 'ON BATTERY'
expect_post_text 0 'charge 87 %, runtime 23 min'
set_status OL; sleep "$SETTLE_SECONDS"
expect_posts 2 "back on mains after the outage"
expect_post_text 1 'BACK ON MAINS'

set_status 'OL RB'; sleep "$SETTLE_SECONDS"; set_status OL
expect_posts 3 "replace battery"
expect_post_text 2 'REPLACE BATTERY'

direct_events

# Monitor only, as installed: low battery posts LOW BATTERY, nothing shuts down.
before=$(post_count)
set_status 'OB DISCHRG LB'; sleep "$MONITOR_ONLY_WAIT_SECONDS"
expect_posts $(( before + 1 )) "monitor only: low battery"
expect_post_text "$before" 'LOW BATTERY'
if [[ -f "$STAMP" ]]; then fail "monitor only: SHUTDOWNCMD ran"; else pass "monitor only: no shutdown"; fi

# With automatic shutdown on: upsmon's critical path (LOWBATT, then SHUTDOWN,
# FINALDELAY, SHUTDOWNCMD). A primary never notifies FSD to itself; FSD
# reaches the secondaries only (covered by the direct call above).
stop_nut
write_nut_config shutdown
start_nut
before=$(post_count)
set_status 'OB DISCHRG LB'
for _ in $(seq "$SHUTDOWN_WAIT_SECONDS"); do [[ -f "$STAMP" ]] && break; sleep 1; done
if [[ -f "$STAMP" ]]; then pass "stub SHUTDOWNCMD ran"; else fail "stub SHUTDOWNCMD never ran"; fi
if python3 - "$POSTS" "$before" <<'EOF'; then pass "LOW BATTERY and SHUTTING DOWN posted"; else fail "shutdown posts missing"; fi
import json, sys
contents = [json.loads(json.loads(l)["body"])["content"] for l in list(open(sys.argv[1]))[int(sys.argv[2]):]]
for text in ("LOW BATTERY", "SHUTTING DOWN"):
    assert any(text in c for c in contents), (text, contents)
EOF
last=$(( $(post_count) - 1 ))
lead=$(seconds_before_stamp "$last")
if python3 -c "import sys; sys.exit(0 if $lead > 0 else 1)"; then
  pass "last shutdown post received ${lead} s before SHUTDOWNCMD"
else
  fail "a shutdown post arrived after SHUTDOWNCMD (${lead} s)"
fi

# Slow Discord: the shutdown post is given up, SHUTDOWNCMD still runs on time.
stop_nut
write_nut_config shutdown
echo "$LISTENER_DELAY_SECONDS" > "$DELAY_FILE"
start_nut
before=$(post_count)
started=$(date +%s.%N)
upsmon -c fsd >>"$NUT_LOG" 2>&1
for _ in $(seq "$SHUTDOWN_WAIT_SECONDS"); do [[ -f "$STAMP" ]] && break; sleep 1; done
rm -f "$DELAY_FILE"
if [[ -f "$STAMP" ]]; then
  took=$(python3 -c "print(f'{float(open(\"$STAMP\").read()) - $started:.1f}')")
  pass "slow Discord: SHUTDOWNCMD ran ${took} s after upsmon -c fsd (FINALDELAY $FINALDELAY_SECONDS)"
else
  fail "slow Discord: SHUTDOWNCMD never ran"
fi
if grep -q 'could not post shutdown to Discord (curl exit 28)' "$SYSLOG"; then
  pass "slow Discord: shutdown post given up (curl timeout)"
else
  fail "slow Discord: no curl timeout logged for the shutdown post"
fi
if python3 - "$POSTS" "$before" "$STAMP" <<'EOF'; then pass "slow Discord: shutdown post sent before SHUTDOWNCMD"; else fail "slow Discord: post timing"; fi
import json, sys
posts = [json.loads(l) for l in list(open(sys.argv[1]))[int(sys.argv[2]):]]
shutdown = [p for p in posts if "SHUTTING DOWN" in json.loads(p["body"])["content"]]
assert shutdown and shutdown[-1]["time"] < float(open(sys.argv[3]).read()), posts
EOF

check_payloads
if grep -q 'cointmu-ups-notify.*posted onbatt' "$SYSLOG"; then
  pass "ups-notify.sh logs to syslog"
else
  fail "no ups-notify.sh line in syslog"
fi
stop_nut
echo "--- nut log (tail)"; tail -20 "$NUT_LOG"
(( failures == 0 )) || { echo "$failures check(s) failed" >&2; exit 1; }
echo "OK: notifier, debounce and shutdown ordering as expected"
