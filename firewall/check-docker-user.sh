#!/usr/bin/env bash
# Tests firewall/ufw-after.rules.snippet as README.md ("Firewall") applies it:
# the same placeholder substitution, loaded into DOCKER-USER with
# iptables-restore --noflush, the way ufw loads /etc/ufw/after.rules. Checks:
# - a container still reaches an HTTPS server outside (GlitchTip's and
#   Grafana's Discord alerts go out on port 443 through DOCKER-USER too)
# - a client outside CAMPUS_SUBNET gets no answer on BIND_IP:HTTPS_PORT
# - a client inside CAMPUS_SUBNET does
# Clients are containers on two throwaway networks, one of them standing in
# for the campus LAN; the server publishes on this machine's own address.
#
# It replaces this machine's DOCKER-USER chain, so run it as root on a CI
# runner or another throwaway host, never on the telemetry VM.
#
#   sudo firewall/check-docker-user.sh
set -euo pipefail
cd "$(dirname "$0")"
ROOT_DIR="$(cd .. && pwd)"
readonly ROOT_DIR
IMAGE=$(sed -n 's|^ *image: \(nginxinc/nginx-unprivileged:.*\)$|\1|p' "$ROOT_DIR/compose.yml")
readonly IMAGE
readonly PROJECT="cointmu-fw-check-$$"
readonly HTTPS_PORT=443
readonly CONTAINER_PORT=8080
readonly CAMPUS_NET=172.31.250.0/24
readonly OUTSIDE_NET=172.31.251.0/24
readonly EGRESS_URL=https://github.com/
readonly TIMEOUT_SECONDS=5
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }
cleanup() {
  docker rm -f "$PROJECT-server" >/dev/null 2>&1 || true
  docker network rm "$PROJECT-campus" "$PROJECT-outside" >/dev/null 2>&1 || true
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || { echo "run as root (it replaces DOCKER-USER)" >&2; exit 2; }
test -n "$IMAGE"
# The address a published port binds to on the VM is BIND_IP; here it is
# whatever this machine uses for its default route.
bind_ip=$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')
test -n "$bind_ip"

docker network create --subnet "$CAMPUS_NET" "$PROJECT-campus" >/dev/null
docker network create --subnet "$OUTSIDE_NET" "$PROJECT-outside" >/dev/null
docker run -d --name "$PROJECT-server" -p "$bind_ip:$HTTPS_PORT:$CONTAINER_PORT" "$IMAGE" >/dev/null

# README.md's substitution, with no Tailscale addresses.
sed -e "s|<CAMPUS_SUBNET>|$CAMPUS_NET|g" -e "s|<HTTPS_PORT>|$HTTPS_PORT|g" \
  -e "s|<BIND_IP>|$bind_ip|g" -e '/<TAILSCALE_SUBNET>/d' ufw-after.rules.snippet \
  | sed -n '/^\*filter$/,/^COMMIT$/p' | iptables-restore --noflush
echo "DOCKER-USER now:"; iptables -S DOCKER-USER | sed 's/^/  /'

# $1 network, $2 URL: exit 0 when the client got an HTTP answer in time.
fetch() {
  docker run --rm --network "$1" --entrypoint wget "$IMAGE" -q -T "$TIMEOUT_SECONDS" -O /dev/null "$2" 2>/dev/null
}
for _ in $(seq 30); do fetch "$PROJECT-campus" "http://$bind_ip:$HTTPS_PORT/" && break; sleep 1; done

if fetch "$PROJECT-outside" "$EGRESS_URL"; then pass "container reaches $EGRESS_URL (port 443 out)"
else fail "container cannot reach $EGRESS_URL: DOCKER-USER drops outgoing HTTPS"; fi
if fetch "$PROJECT-campus" "http://$bind_ip:$HTTPS_PORT/"; then pass "campus client reaches BIND_IP:$HTTPS_PORT"
else fail "campus client gets no answer on BIND_IP:$HTTPS_PORT"; fi
if fetch "$PROJECT-outside" "http://$bind_ip:$HTTPS_PORT/"; then fail "client outside CAMPUS_SUBNET reaches BIND_IP:$HTTPS_PORT"
else pass "client outside CAMPUS_SUBNET gets no answer on BIND_IP:$HTTPS_PORT"; fi

if (( failures )); then echo "$failures check(s) failed" >&2; exit 1; fi
echo "OK: DOCKER-USER guards the published port and lets containers out"
