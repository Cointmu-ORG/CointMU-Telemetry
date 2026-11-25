# Scope infra: the health of any server

Every enrolled server can carry this scope (`scripts/enroll.sh add ... --scopes infra`, RUNBOOK.md, "Enroll
a host"). Metrics only, no log login. `install-agent.sh` installs what `agent.manifest` lists for the
host's type:

| Type | What |
|---|---|
| `pve` (Proxmox host) | host metrics, SMART, GPU, guest counts and storage usage |
| `linux` (physical or virtual) | host metrics, SMART and GPU where present |
| `lxc` (container) | the collectors that show the container itself; no disks, temperatures, ZFS, SMART |

| Source | Metrics | Every |
|---|---|---|
| Alloy `prometheus.exporter.unix` (`infra.alloy`) | CPU, load, memory, swap, disk IO, filesystems, network, temperatures, ZFS pool state, boot time | 30 s |
| `infra-metrics.py smart` | per disk: health, temperature, reallocated/pending/uncorrectable sectors, wear, NVMe warnings. Sleeping disks stay asleep | 10 min |
| `infra-metrics.py pve` | running and total guests by type (counts only), used and total bytes per active storage (LVM-thin pools are not filesystems) | 60 s |
| `infra-metrics.py gpu` | NVIDIA (`nvidia-smi`) and AMD (sysfs): utilisation, memory, temperature; Intel: temperature only. A GPU passed through to a guest is invisible to the host | 30 s |

A host without the hardware or the tool writes `infra_collector_timestamp_seconds` only. A tool that fails
fails its unit (`systemctl status 'cointmu-infra-*'`), and the timestamp gets old.

- **Labels:** `job="infra"`, `scope="infra"`, `host`, `instance="infra"`. `infra_host_info` carries `rack`
  and `type` (`--rack`, `--type`). No guest names or IDs, no serial numbers, no addresses.
- **smartmontools** must come from the host's own distribution (Proxmox ships it); without it SMART stays
  empty and the installer warns.
- **SMART behind a RAID controller:** members show as `<device>:megaraid,<n>` if `smartctl --scan` lists
  them. Check the first host of each controller type by hand.

The sandbox of `cointmu-infra-pve.service` is looser than the others: `pvesm` talks to LVM, ZFS and network
storages. It is tested with stubs only; watch its first run on a real Proxmox host:
`systemctl status cointmu-infra-pve.service` and `cat /var/lib/cointmu-infra/pve/pve.prom`.

Tests: `scopes/infra/testdata/test_infra_metrics.py` (collector against stub tools) and
`agent/check-install.sh` (installed on a host with systemd).
