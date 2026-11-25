#!/usr/bin/env bash
# Deploys the current commit's Grafana provisioning over an older one, the way
# the VM does, in a throwaway copy of the stack (own compose project, volumes
# and clone; nothing published). Checks:
# - old provisioning, then "git checkout" of HEAD in the same folder, then the
#   command from RUNBOOK.md "Deploying a config change": Grafana serves exactly
#   the files' dashboards, rules and contact points, in the scope folders, with
#   unchanged UIDs and no duplicate folders
# - a rule file replaced the way git does it (new file, then rename): a plain
#   "up -d" keeps serving the old rule, the documented command the new one
# Tests committed files only. Takes a few minutes.
#
#   grafana/check-upgrade.sh <old ref>
set -euo pipefail

[[ $# -eq 1 ]] || { sed -n '2,14p' "$0" >&2; exit 2; }
readonly OLD_REF="$1"
cd "$(dirname "$0")/.."
ROOT_DIR="$PWD"
readonly ROOT_DIR
readonly TEST_IMAGE=cointmu-upgrade-test:local
readonly PROJECT="cointmu-upgrade-check-$$"
readonly WAIT_SECONDS=420
readonly SWAPPED_RULES=scopes/ups/alerting/rules.yml
readonly SWAPPED_UID=ups-unreadable
readonly OLD_TITLE="UPS unreadable"
readonly NEW_TITLE="UPS unreadable (swapped)"

work=$(mktemp -d)
repo="$work/repo"
fail() { echo "FAIL: $*" >&2; compose logs --tail 40 grafana >&2 || true; exit 1; }
pass() { echo "ok:   $*"; }
compose() {
  docker compose -p "$PROJECT" --project-directory "$repo" -f "$repo/compose.yml" -f "$work/override.yml" \
    --env-file "$work/env" "$@"
}
cleanup() { compose down -v >/dev/null 2>&1 || true; rm -rf "$work"; }
trap cleanup EXIT

probe() {
  docker run --rm --network "${PROJECT}_logs" -e GRAFANA_AUTH="$auth" -v "$repo:/checkout:ro" \
    -v "$ROOT_DIR/grafana/testdata:/test:ro" -v "$work:/work:ro" "$TEST_IMAGE" python3 /test/check_provisioned.py "$@"
}

wait_healthy() {
  compose up -d --no-deps --no-recreate --wait --wait-timeout "$WAIT_SECONDS" grafana >"$work/wait.log" 2>&1 \
    || { cat "$work/wait.log" >&2; fail "Grafana is not healthy"; }
}

# The documented command, with this test's compose project in place of the VM's.
deploy() {
  local documented
  documented=$(sed -n 's/^git pull --ff-only && docker compose \(.*\) <service>$/\1/p' "$ROOT_DIR/RUNBOOK.md")
  [[ -n "$documented" ]] || fail "RUNBOOK.md has no deploy command"
  # shellcheck disable=SC2086 # the documented options are separate words
  compose $documented grafana >"$work/deploy.log" 2>&1 || { cat "$work/deploy.log" >&2; fail "deploy command"; }
  wait_healthy
}

expect_title() {
  local title
  title=$(probe title "$SWAPPED_UID")
  if [[ "$title" == "$2" ]]; then pass "$1: \"$title\""; else fail "$1: \"$title\", expected \"$2\""; fi
}

prepare() {
  local password
  password=$(openssl rand -hex 16)
  auth=$(printf 'admin:%s' "$password" | base64 -w0)
  sed -e 's/^TLS_GID=.*/TLS_GID=12345/' -e "s/^SECRET_KEY=.*/SECRET_KEY=$(openssl rand -hex 32)/" \
    -e "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 24)/" \
    -e "s/^GRAFANA_ADMIN_PASSWORD=.*/GRAFANA_ADMIN_PASSWORD=$password/" "$ROOT_DIR/.env.example" > "$work/env"
  cat > "$work/override.yml" <<'YAML'
services:
  grafana:
    environment: { GF_AUTH_BASIC_ENABLED: "true" }
YAML
  git clone -q "$ROOT_DIR" "$repo"
  git -C "$repo" checkout -q "$(git rev-parse "$OLD_REF")"
}

docker build -q -t "$TEST_IMAGE" scopes/ups/testdata >/dev/null
prepare
compose up -d --no-deps grafana >"$work/up.log" 2>&1 || { cat "$work/up.log" >&2; fail "old Grafana"; }
wait_healthy
probe state > "$work/before.json"
pass "old provisioning ($OLD_REF): $(cat "$work/before.json")"

git -C "$repo" checkout -q "$(git rev-parse HEAD)"
deploy
probe verify /work/before.json || fail "provisioning after the upgrade"
pass "HEAD provisioned over $OLD_REF"

sed "s/title: $OLD_TITLE\$/title: $NEW_TITLE/" "$repo/$SWAPPED_RULES" > "$repo/$SWAPPED_RULES.new"
grep -q "title: $NEW_TITLE" "$repo/$SWAPPED_RULES.new" || fail "no rule titled \"$OLD_TITLE\" to change"
mv "$repo/$SWAPPED_RULES.new" "$repo/$SWAPPED_RULES"
compose up -d --no-deps grafana >/dev/null 2>&1
wait_healthy
expect_title "after a plain up -d (the trap)" "$OLD_TITLE"
deploy
expect_title "after the documented command" "$NEW_TITLE"
echo "OK: Grafana upgrade as expected"
