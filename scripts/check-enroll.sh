#!/usr/bin/env bash
# Tests scripts/enroll.sh against a throwaway copy of the stack: own clone,
# compose project, certificate and nginx/local/, nothing published. Checks:
# - root, unknown scopes, unsafe settings and a tampered package are refused,
#   and a refused or failed add leaves no login, allowlist line or record
# - add: no password in the output, bundle 0600 with a matching manifest; the
#   login works on its own endpoint only (401/403/204 through nginx)
# - verify keeps the bundle until data arrives, then removes it; a broken pipe
#   keeps it; the TTL removes it
# - reissue, revoke-old and remove; hand-written allowlist lines stay
# - fetch-alloy refuses a key that is not Grafana's
# Tests committed files only. Takes about two minutes.
#
#   scripts/check-enroll.sh
set -euo pipefail

cd "$(dirname "$0")/.."
readonly TEST_IMAGE=cointmu-enroll-test:local
readonly PROJECT="cointmu-enroll-check-$$"
readonly HOST=probe
readonly SETTINGS=(--set "GETH_LOG_FILES=/var/log/geth-*.log" --set NODES=miner=http://127.0.0.1:8545)
readonly UNAUTHORIZED=401 FORBIDDEN=403 NO_CONTENT=204

# shellcheck source=testing/stack.sh
. testing/stack.sh
cleanup() {
  docker rm -f "$PROJECT-agent" "$PROJECT-other" >/dev/null 2>&1 || true
  stack_cleanup
}
trap cleanup EXIT

# $1 description, $2 expected text, rest: an enroll.sh command that must fail.
refuse() {
  local what="$1" expected="$2" output; shift 2
  if output=$(enroll "$@" 2>&1); then fail "$what: did not fail"
  elif [[ "$output" == *"$expected"* ]]; then pass "$what"
  else fail "$what: $output"; fi
}

# A logs-only scope, so plain curl can be the agent.
add_test_scope() {
  mkdir -p "$repo/scopes/testscope"
  printf 'logins logs\nverify logs {job="enroll-test",host="HOST"}\n' > "$repo/scopes/testscope/agent.manifest"
  [[ -f "$repo/agent/install-agent.sh" ]] || echo '#!/bin/sh' > "$repo/agent/install-agent.sh"
}

start_agents() {
  local name
  for name in agent other; do
    docker run -d --name "$PROJECT-$name" --network "${PROJECT}_frontend" -v "$repo/certs/server.crt:/server.crt:ro" \
      "$TEST_IMAGE" sleep infinity >/dev/null
  done
  agent_ip=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$PROJECT-agent")
}

# A package that matches the (changed) pin; the real one is 168 MB.
fake_package() {
  mkdir -p "$repo/state/alloy"
  echo "not really alloy" > "$repo/state/alloy/alloy_1.21.0-1_amd64.deb"
  sed -i "s/^SHA256_amd64=.*/SHA256_amd64=$(sha256sum "$repo/state/alloy/alloy_1.21.0-1_amd64.deb" | cut -d' ' -f1)/" "$repo/agent/alloy.pin"
}

state_of_access() { (cd "$repo" && cat nginx/local/*.htpasswd nginx/local/agent-allow.conf inventory/hosts.tsv 2>/dev/null; ls state/bundles inventory/settings 2>/dev/null) || true; }

# $1 container, $2 login, $3 password, $4 push path; prints the status.
push() {
  docker exec "$1" curl -s --cacert /server.crt -o /dev/null -w '%{http_code}' -u "$2:$3" -H 'Content-Type: application/json' \
    -X POST --data-binary "{\"streams\":[{\"stream\":{\"job\":\"enroll-test\",\"host\":\"$HOST\"},\"values\":[[\"$(date +%s%N)\",\"hello\"]]}]}" \
    "https://proxy:8443$4"
}
expect_push() {
  local what="$1" expected="$2" status; shift 2
  status=$(push "$@") || true
  if [[ "$status" == "$expected" ]]; then pass "$what: $status"; else fail "$what: $status, expected $expected"; fi
}

# $1 member of the bundle file.
from_bundle() { tar -xOf "$repo/state/bundles/$HOST.tar" "./$1"; }

check_refusals() {
  local before after
  before=$(state_of_access)
  refuse "unknown scope" "no scope 'nope'" add h 10.0.1.5 --scopes nope --ssh me@h
  # shellcheck disable=SC2016 # literal on purpose
  refuse "unsafe setting" "plain characters" add h 10.0.1.5 --scopes cointmu --ssh me@h --set 'NODES=$(id)'
  refuse "unknown setting" "no chosen scope has a setting" add h 10.0.1.5 --scopes cointmu --ssh me@h --set FOO=x
  refuse "bad address" "invalid address" add h 10.0.1.555 --scopes cointmu --ssh me@h
  refuse "host name with a shell character" "invalid host" add 'h;id' 10.0.1.5 --scopes cointmu --ssh me@h
  refuse "no package fetched" "fetch-alloy" add h 10.0.1.5 --scopes testscope --ssh me@h
  fake_package
  echo tampered >> "$repo/state/alloy/alloy_1.21.0-1_amd64.deb"
  refuse "tampered package" "does not match agent/alloy.pin" add h 10.0.1.5 --scopes testscope --ssh me@h
  fake_package
  refuse "adopt without an existing login" "to adopt" adopt h 10.0.1.5 --scopes cointmu --ssh me@h --login h-1
  # Not with compose: its start would wait for GlitchTip.
  docker stop "$PROJECT-proxy-1" >/dev/null
  refuse "add while nginx cannot reload" "nothing changed there" add h 10.0.1.5 --scopes cointmu --ssh me@h "${SETTINGS[@]}"
  docker start "$PROJECT-proxy-1" >/dev/null
  wait_for "proxy is back" compose exec -T proxy nginx -t
  after=$(state_of_access)
  if [[ "$before" == "$after" ]]; then pass "refused and failed adds leave nothing behind"; else fail "left behind: $(diff <(echo "$before") <(echo "$after"))"; fi
  if sudo -n true 2>/dev/null; then
    if sudo -n bash -c "cd '$repo' && scripts/enroll.sh list" 2>&1 | grep "not root" >/dev/null; then pass "root refused"; else fail "root not refused"; fi
  fi
}

check_key_refusal() {
  local key="$work/key" port=18089 server
  mkdir -p "$key/gnupg" && chmod 700 "$key/gnupg"
  GNUPGHOME="$key/gnupg" gpg --batch --quiet --passphrase '' --quick-generate-key test@example.invalid ed25519 sign never 2>/dev/null
  GNUPGHOME="$key/gnupg" gpg --batch --armor --export > "$key/gpg.key"
  python3 -m http.server --bind 127.0.0.1 --directory "$key" "$port" >/dev/null 2>&1 &
  server=$!
  sleep 1
  ENROLL_APT_URL="http://127.0.0.1:$port" refuse "apt key that is not Grafana's" "the apt key is not exactly" fetch-alloy arm64
  kill "$server"
}

check_add() {
  local output password
  output=$(enroll add "$HOST" "$agent_ip" --scopes testscope --ssh "me@$HOST" --rack R1)
  password=$(from_bundle push-password)
  if [[ "$output" == *"$password"* ]]; then fail "add printed the password"; else pass "add prints no password"; fi
  check "bundle is 0600" test "$(stat -c %a "$repo/state/bundles/$HOST.tar")" = 600
  check "printed sha256 is the bundle's" grep -F "$(sha256sum "$repo/state/bundles/$HOST.tar" | cut -d' ' -f1)" <<<"$output"
  mkdir "$work/unpacked" && tar -xf "$repo/state/bundles/$HOST.tar" -C "$work/unpacked"
  check "bundle manifest" bash -c "cd '$work/unpacked' && sha256sum --quiet -c manifest.sha256"
  check "bundle holds installer, certificate and package" test -f "$work/unpacked/install-agent.sh" -a -f "$work/unpacked/telemetry.crt" -a -f "$work/unpacked/alloy.deb"
  check "a logs-only scope gets no metrics login" test ! -e "$work/unpacked/metrics-password"
  check "registry is private" test "$(stat -c %a "$repo/inventory/hosts.tsv")" = 600
  check "registry and bundles are git-ignored" bash -c "cd '$repo' && git check-ignore inventory/hosts.tsv state/bundles/$HOST.tar"
  refuse "same address twice" "another host has the address" add other "$agent_ip" --scopes testscope --ssh me@o
  expect_push "push before any check, wrong password" "$UNAUTHORIZED" "$PROJECT-agent" "$HOST-1" wrong /loki/api/v1/push
  expect_push "logs login on the metrics endpoint" "$UNAUTHORIZED" "$PROJECT-agent" "$HOST-1" "$password" /prometheus/api/v1/write
  expect_push "from another address" "$FORBIDDEN" "$PROJECT-other" "$HOST-1" "$password" /loki/api/v1/push
}

check_lifecycle() {
  local password first second
  password=$(from_bundle push-password)
  refuse "verify without data" "not complete yet" verify "$HOST"
  check "bundle kept after a failed verify" test -f "$repo/state/bundles/$HOST.tar"
  first=$(enroll bundle "$HOST" | sha256sum)
  enroll bundle "$HOST" 2>/dev/null | head -c 100 >/dev/null || true
  second=$(enroll bundle "$HOST" | sha256sum)
  if [[ "$first" == "$second" ]]; then pass "same bundle again after a broken pipe"; else fail "bundle changed after a broken pipe"; fi
  expect_push "push with the new login" "$NO_CONTENT" "$PROJECT-agent" "$HOST-1" "$password" /loki/api/v1/push
  sleep 5
  check "verify once data arrived" enroll verify "$HOST"
  check "bundle removed after verify" test ! -e "$repo/state/bundles/$HOST.tar"
  refuse "no bundle after verify" "reissue $HOST" bundle "$HOST"
}

check_reissue() {
  local old_password="$1" password
  enroll reissue "$HOST" >/dev/null 2>&1
  password=$(from_bundle push-password)
  expect_push "new login after reissue" "$NO_CONTENT" "$PROJECT-agent" "$HOST-2" "$password" /loki/api/v1/push
  expect_push "old login still works" "$NO_CONTENT" "$PROJECT-agent" "$HOST-1" "$old_password" /loki/api/v1/push
  enroll revoke-old "$HOST" >/dev/null 2>&1
  expect_push "old login after revoke-old" "$UNAUTHORIZED" "$PROJECT-agent" "$HOST-1" "$old_password" /loki/api/v1/push
  touch -d '25 hours ago' "$repo/state/bundles/$HOST.tar"
  enroll expire 2>/dev/null
  check "bundle expired after 24 h" test ! -e "$repo/state/bundles/$HOST.tar"
  check "list shows the expired bundle" grep -F "pending, bundle expired" <(enroll list)
  enroll remove "$HOST" >/dev/null 2>&1
  expect_push "after remove" "$FORBIDDEN" "$PROJECT-agent" "$HOST-2" "$password" /loki/api/v1/push
  if [[ "$(cat "$repo/nginx/local/agent-allow.conf")" == "$HAND_WRITTEN" ]]; then pass "hand-written allowlist line untouched"; else fail "allowlist: $(cat "$repo/nginx/local/agent-allow.conf")"; fi
  check "no login left" test ! -s "$repo/nginx/local/loki-agents.htpasswd"
}

docker build -q -t "$TEST_IMAGE" scopes/ups/testdata >/dev/null
prepare_stack
add_test_scope
start_stack
start_agents
check_refusals
check_key_refusal
check_add
old_password=$(from_bundle push-password)
check_lifecycle
check_reissue "$old_password"
(( failures == 0 )) || { echo "$failures check(s) failed" >&2; exit 1; }
echo "OK: enroll.sh as expected"
