# shellcheck shell=bash
# A throwaway copy of the stack for the check scripts that source this: own
# clone of HEAD, compose project, certificate (SAN "proxy") and nginx/local/,
# nothing published, GlitchTip not started. Set PROJECT before sourcing.

readonly STACK_WAIT_SECONDS=120
readonly HAND_WRITTEN='192.0.2.9 1;'
ROOT_DIR=$(git rev-parse --show-toplevel)
work=$(mktemp -d)
repo="$work/repo"
failures=0
fail() { echo "FAIL: $*" >&2; failures=$((failures + 1)); }
pass() { echo "ok:   $*"; }
# $1 description, rest: a command that must succeed.
check() { local what="$1"; shift; if "$@" >/dev/null 2>&1; then pass "$what"; else fail "$what"; fi; }
enroll() { (cd "$repo" && scripts/enroll.sh "$@"); }
compose() { (cd "$repo" && docker compose "$@"); }

wait_for() {
  local what="$1" deadline=$((SECONDS + STACK_WAIT_SECONDS)); shift
  while (( SECONDS < deadline )); do "$@" >/dev/null 2>&1 && { pass "$what"; return 0; }; sleep 2; done
  fail "$what (gave up after $STACK_WAIT_SECONDS s)"; return 1
}

prepare_stack() {
  git clone -q "$ROOT_DIR" "$repo"
  git -C "$repo" -c advice.detachedHead=false checkout -q "$(git -C "$ROOT_DIR" rev-parse HEAD)"
  sed -e 's/^TLS_GID=.*/TLS_GID=12345/' -e 's/^BIND_IP=.*/BIND_IP=127.0.0.1/' \
    -e 's/^GLITCHTIP_HOST=.*/GLITCHTIP_HOST=proxy/' -e 's/^HTTPS_PORT=.*/HTTPS_PORT=8443/' \
    -e "s/^SECRET_KEY=.*/SECRET_KEY=$(openssl rand -hex 32)/" \
    -e "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 24)/" \
    -e "s/^GRAFANA_ADMIN_PASSWORD=.*/GRAFANA_ADMIN_PASSWORD=$(openssl rand -hex 24)/" "$repo/.env.example" > "$repo/.env"
  echo "COMPOSE_PROJECT_NAME=${PROJECT:?}" >> "$repo/.env"
  mkdir "$repo/certs"
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -days 1 -subj /CN=proxy \
    -addext subjectAltName=DNS:proxy -keyout "$repo/certs/server.key" -out "$repo/certs/server.crt" 2>/dev/null
  chmod 644 "$repo/certs/server.key"
  : > "$repo/nginx/local/admin-allow.conf"
  echo "$HAND_WRITTEN" > "$repo/nginx/local/agent-allow.conf"
  : > "$repo/nginx/local/loki-agents.htpasswd"
  : > "$repo/nginx/local/metrics-agents.htpasswd"
  # Loaded by docker compose on its own.
  cat > "$repo/compose.override.yml" <<'YAML'
services:
  proxy:
    ports: !reset []
    extra_hosts: ["web:127.0.0.1"]
YAML
}

loki_ready() { compose exec -T grafana wget -qO- http://loki:3100/ready </dev/null | grep '^ready'; }

start_stack() {
  compose up -d --no-deps loki prometheus blackbox grafana proxy >"$work/up.log" 2>&1 || { cat "$work/up.log" >&2; exit 1; }
  wait_for "stack ready" loki_ready
}

stack_cleanup() {
  compose down -v >/dev/null 2>&1 || true
  rm -rf "${work:?}"
}
