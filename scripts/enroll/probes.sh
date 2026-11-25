# shellcheck shell=bash
# Targets of the external probes, sourced by scripts/enroll.sh. Prometheus reads
# the folder by itself (file_sd), no reload. Derived from the registry, so it is
# git-ignored and not backed up.

readonly PROBE_TARGETS=prometheus/probes/targets.json
readonly PVE_WEB_PORT=8006

# $1 address, $2 probe name, $3 module: one file_sd entry of the loaded host.
probe_entry() {
  printf '{"targets":["%s"],"labels":{"host":"%s","probe":"%s","scope":"infra","__param_module":"%s"}}\n' \
    "$1" "${h_host:?}" "$2" "$3"
}

probe_entries() {
  local host
  while IFS= read -r host; do
    registry_load "$host"
    # Not before the first successful verify: a half-finished enrollment must not page.
    [[ "${h_state:?}" != pending && ",${h_scopes:?}," == *,infra,* ]] || continue
    probe_entry "${h_ip:?}" icmp icmp
    probe_entry "$h_ip:${h_ssh_port:?}" ssh tcp
    if [[ "${h_type:?}" == pve ]]; then probe_entry "$h_ip:$PVE_WEB_PORT" web tls; fi
  done < <(registry_hosts)
}

# In a subshell: it loads every host, the caller keeps its own.
write_probe_targets() (
  local entries
  entries=$(probe_entries)
  umask 022
  printf '[%s]\n' "$(paste -sd, - <<<"$entries")" > "$PROBE_TARGETS.tmp"
  mv "$PROBE_TARGETS.tmp" "$PROBE_TARGETS"
)
