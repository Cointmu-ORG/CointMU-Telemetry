#!/usr/bin/env bash
# Replaces the GlitchTip database with a dump made by backup.sh.
# DESTRUCTIVE: all current events are lost. Asks for confirmation.
#
#   scripts/restore.sh backup/glitchtip-20261020T020000Z.sql.gz
set -euo pipefail

[[ $# -eq 1 && -f "$1" ]] || { sed -n '2,5p' "$0" >&2; exit 2; }
cd "$(dirname "$0")/.."
dump="$1"

read -r -p "Type 'restore' to replace the current database with $dump: " answer
[[ "$answer" == "restore" ]] || { echo "aborted"; exit 1; }

docker compose stop web proxy
docker compose exec -T postgres dropdb -U glitchtip --if-exists --force glitchtip
docker compose exec -T postgres createdb -U glitchtip glitchtip
gunzip -c "$dump" | docker compose exec -T postgres psql -U glitchtip -d glitchtip -v ON_ERROR_STOP=1 -q
docker compose up -d web proxy
echo "restored $dump"
