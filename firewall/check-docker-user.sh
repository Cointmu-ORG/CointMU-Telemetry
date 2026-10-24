#!/usr/bin/env bash
# Tests firewall/ufw-after.rules.snippet as README.md ("Firewall") applies it:
# the same placeholder substitution, loaded into DOCKER-USER with
# iptables-restore --noflush, the way ufw loads /etc/ufw/after.rules. Checks:
# - a container still reaches an HTTPS server outside (GlitchTip's and
#   Grafana's Discord alerts go out on port 443 through DOCKER-USER too)
# - a client outside CAMPUS_SUBNET gets no answer on BIND_IP:HTTPS_PORT
# - a client inside CAMPUS_SUBNET does
# The clients sit in two throwaway network namespaces behind veth pairs, one
# standing in for the campus LAN: like a real client they arrive on a non-Docker
# interface, get DNATed and pass DOCKER-USER (a container client would go
# through docker-proxy instead). The server publishes on this machine's address.
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
readonly CAMPUS_PREFIX=172.31.250
readonly OUTSIDE_PREFIX=172.31.251
readonly CAMPUS_NET="$CAMPUS_PREFIX.0/24"
readonly EGRESS_URL=https://github.com/
readonly TIMEOUT_SECONDS=5
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }
cleanup() {
  docker rm -f "$PROJECT-server" >/dev/null 2>&1 || true
  for name in fwck-campus fwck-outside; do
    ip netns del "$name" 2>/dev/null || true
    ip link del "$name-h" 2>/dev/null || true
  done
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || { echo "run as root (it replaces DOCKER-USER)" >&2; exit 2; }
test -n "$IMAGE"
# The address a published port binds to on the VM is BIND_IP; here it is
# whatever this machine uses for its default route.
bind_ip=$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')
test -n "$bind_ip"

# $1 namespace name (also the veth prefix, at most 13 characters), $2 /24 prefix:
# host side .1, client .2, default route back through the host.
add_client() {
  ip netns add "$1"
  ip link add "$1-h" type veth peer name "$1-c"
  ip link set "$1-c" netns "$1"
  ip addr add "$2.1/24" dev "$1-h"
  ip link set "$1-h" up
  ip netns exec "$1" ip addr add "$2.2/24" dev "$1-c"
  ip netns exec "$1" ip link set "$1-c" up
  ip netns exec "$1" ip route add default via "$2.1"
}
add_client fwck-campus "$CAMPUS_PREFIX"
add_client fwck-outside "$OUTSIDE_PREFIX"
docker run -d --name "$PROJECT-server" -p "$bind_ip:$HTTPS_PORT:$CONTAINER_PORT" "$IMAGE" >/dev/null

# README.md's substitution, with no Tailscale addresses.
sed -e "s|<CAMPUS_SUBNET>|$CAMPUS_NET|g" -e "s|<HTTPS_PORT>|$HTTPS_PORT|g" \
  -e "s|<BIND_IP>|$bind_ip|g" -e '/<TAILSCALE_SUBNET>/d' ufw-after.rules.snippet \
  | sed -n '/^\*filter$/,/^COMMIT$/p' | iptables-restore --noflush
echo "DOCKER-USER now:"; iptables -S DOCKER-USER | sed 's/^/  /'

# $1 namespace: exit 0 when the client got an HTTP answer from the published port in time.
fetch_published() {
  ip netns exec "$1" curl -s -o /dev/null -m "$TIMEOUT_SECONDS" "http://$bind_ip:$HTTPS_PORT/"
}
for _ in $(seq 30); do fetch_published fwck-campus && break; sleep 1; done

if docker run --rm --entrypoint wget "$IMAGE" -q -T "$TIMEOUT_SECONDS" -O /dev/null "$EGRESS_URL" 2>/dev/null; then
  pass "container reaches $EGRESS_URL (port 443 out)"
else fail "container cannot reach $EGRESS_URL: DOCKER-USER drops outgoing HTTPS"; fi
if fetch_published fwck-campus; then pass "campus client reaches BIND_IP:$HTTPS_PORT"
else fail "campus client gets no answer on BIND_IP:$HTTPS_PORT"; fi
if fetch_published fwck-outside; then fail "client outside CAMPUS_SUBNET reaches BIND_IP:$HTTPS_PORT"
else pass "client outside CAMPUS_SUBNET gets no answer on BIND_IP:$HTTPS_PORT"; fi

if (( failures )); then echo "$failures check(s) failed" >&2; exit 1; fi
echo "OK: DOCKER-USER guards the published port and lets containers out"
