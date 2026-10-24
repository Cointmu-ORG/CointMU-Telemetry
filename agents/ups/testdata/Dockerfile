# Throwaway "UPS host" for check-notify.sh: Debian 13 (the base of Proxmox
# VE 9) with the distribution's NUT and curl. Never used in production.
FROM debian:13.6-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    nut-server nut-client curl ca-certificates python3 openssl procps \
  && rm -rf /var/lib/apt/lists/*
