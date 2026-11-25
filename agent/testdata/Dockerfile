# Throwaway "host" with a real systemd for agent/check-install.sh. No curl, wget
# or gpg on purpose: install-agent.sh must not need them.
ARG BASE
FROM ${BASE}
RUN apt-get update \
  && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    systemd systemd-sysv python3 procps sudo \
  && rm -rf /var/lib/apt/lists/* \
  && useradd -m -s /bin/bash netadmin \
  && echo 'netadmin ALL=(ALL) NOPASSWD: ALL' > /etc/sudoers.d/netadmin
CMD ["/lib/systemd/systemd"]
