#!/usr/bin/env bash
# Restore drill: loads a dump made by backup.sh into a throwaway Postgres
# container (no network, removed afterwards) and checks that GlitchTip's core
# tables are there and hold data. It never touches the running stack or its
# database; restore.sh is the one that replaces live data. Runs on any machine
# with Docker and this repository, e.g. a workstation holding the age key
# (RUNBOOK.md, "Restore drill").
#
#   scripts/restore-test.sh backup/glitchtip-<UTC>.sql.gz
#   scripts/restore-test.sh glitchtip-<UTC>.sql.gz.age <age identity file>
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
readonly ROOT_DIR
readonly TABLES=(organizations_ext_organization projects_project issue_events_issue issue_events_issueevent)
readonly READY_TRIES=60
readonly CONTAINER="cointmu-restore-test-$$"

usage() { sed -n '2,11p' "$0" >&2; exit 2; }
die() { echo "$*" >&2; exit 1; }

[[ $# -ge 1 && $# -le 2 && -f "$1" ]] || usage
dump="$1"
identity="${2:-}"
if [[ "$dump" == *.age ]]; then
  [[ -f "$identity" ]] || die "an encrypted dump needs the age identity file as second argument"
  command -v age >/dev/null || die "age is not installed"
fi

# The same pinned image as the live database (compose.yml), without needing .env.
image=$(sed -n 's/^ *image: \(postgres:.*\)$/\1/p' "$ROOT_DIR/compose.yml")
[[ -n "$image" ]] || die "no postgres image in $ROOT_DIR/compose.yml"

decrypt() {
  if [[ "$dump" == *.age ]]; then
    age -d -i "$identity" "$dump"
  else
    cat "$dump"
  fi
}

psql_in() {
  docker exec -i "$CONTAINER" psql -U glitchtip -d glitchtip -v ON_ERROR_STOP=1 -q "$@"
}

trap 'docker rm -f -v "$CONTAINER" >/dev/null 2>&1 || true' EXIT

# Trust auth is safe here: the container has no network at all. Same
# hardening and capabilities as the postgres service in compose.yml.
docker run -d --name "$CONTAINER" --network none \
  --cap-drop ALL --cap-add CHOWN --cap-add DAC_OVERRIDE --cap-add FOWNER \
  --cap-add SETGID --cap-add SETUID --security-opt no-new-privileges:true \
  --memory 1g --pids-limit 200 \
  -e POSTGRES_USER=glitchtip -e POSTGRES_DB=glitchtip -e POSTGRES_HOST_AUTH_METHOD=trust \
  "$image" >/dev/null

# Ask over TCP: the entrypoint's temporary init server listens on the socket
# only, and answering it would race the restart that follows.
for (( try = 1; try <= READY_TRIES; try++ )); do
  docker exec "$CONTAINER" pg_isready -q -h 127.0.0.1 -U glitchtip && break
  (( try < READY_TRIES )) || die "throwaway postgres did not start"
  sleep 1
done

start=$(date +%s)
# stdout is the dump's own SELECT setval(...) results; errors stay on stderr.
decrypt | gunzip | psql_in >/dev/null
echo "loaded $dump in $(( $(date +%s) - start )) s"

for table in "${TABLES[@]}"; do
  exists=$(psql_in -Atc "SELECT to_regclass('public.$table') IS NOT NULL")
  [[ "$exists" == t ]] || die "FAIL: table $table is missing"
  echo "$table: $(psql_in -Atc "SELECT count(*) FROM $table") rows"
done

projects=$(psql_in -Atc "SELECT count(*) FROM projects_project")
(( projects > 0 )) || die "FAIL: no projects in the dump"
echo "OK: $dump restores and holds data"
