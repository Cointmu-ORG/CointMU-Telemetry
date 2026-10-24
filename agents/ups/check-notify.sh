#!/usr/bin/env bash
# Tests the Discord notifier (path A, README.md "UPS monitoring") without
# Discord: a throwaway Debian 13 container runs the real NUT daemons on a fake
# UPS (dummy-ups), with upssched.conf.snippet, upsmon.conf.snippet and
# ups-notify.sh installed as on the UPS host. discord.com resolves to a local
# listener inside the container, which has no network at all. Checks the
# debounce, one post per transition, the payloads, and that the shutdown
# posts are sent before SHUTDOWNCMD runs (also with a slow Discord).
# Takes about two minutes.
#
#   agents/ups/check-notify.sh
set -euo pipefail

cd "$(dirname "$0")"
readonly TEST_IMAGE=cointmu-ups-test:local

docker build -q -t "$TEST_IMAGE" testdata >/dev/null
docker run --rm --network none --add-host discord.com:127.0.0.1 \
  -v "$PWD:/src:ro" "$TEST_IMAGE" bash /src/testdata/notify-scenario.sh
