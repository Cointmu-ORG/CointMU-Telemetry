#!/bin/sh
# Runs from the image's /docker-entrypoint.d/ before nginx starts: refuse to
# start without the per-host files in nginx/local/ (README.md, Deploy). nginx
# itself would only notice a missing htpasswd file on the first push request.
set -eu
for f in admin-allow.conf agent-allow.conf loki-agents.htpasswd; do
  if [ ! -f "/etc/nginx/local/$f" ]; then
    echo "missing nginx/local/$f on the host, see README.md" >&2
    exit 1
  fi
done
