"""Synthetic series of scope infra for promtool test rules (check_panels.py and
check_rules.py): two healthy hosts, "pve1" with every kind of hardware and "vm1"
without ZFS, SMART, GPU or guests."""

INTERVAL = "1m"
LENGTH = 1800  # minutes; the longest look-back is 24 h
COMMON = 'job="infra",instance="infra",scope="infra"'
GIB = 1024 ** 3


def flat(value: float) -> str:
    return f"{value}+0x{LENGTH}"


def rising(start: float, step: float) -> str:
    return f"{start}+{step}x{LENGTH}" if step >= 0 else f"{start}{step}x{LENGTH}"


def series(name: str, host: str, values: str, labels: str = "") -> dict:
    extra = f",{labels}" if labels else ""
    return {"series": f'{name}{{{COMMON},host="{host}"{extra}}}', "values": values}


def probes(host: str, kinds: tuple[str, ...], values: str) -> list[dict]:
    found = []
    for probe in kinds:
        labels = f'job="infra-probe",instance="probe",scope="infra",host="{host}",probe="{probe}"'
        found.append({"series": f"probe_success{{{labels}}}", "values": values})
        if probe == "web":
            found.append({"series": f"probe_ssl_earliest_cert_expiry{{{labels}}}", "values": flat(10 ** 9)})
    return found


def base_host(host: str, kind: str, rack: str) -> list[dict]:
    disk = 'device="/dev/sda1",fstype="ext4",mountpoint="/"'
    return [
        series("infra_host_info", host, flat(1), f'rack="{rack}",type="{kind}",release="6",machine="x86_64"'),
        series("node_time_seconds", host, rising(0, 60)),
        series("node_boot_time_seconds", host, flat(0)),
        series("node_cpu_seconds_total", host, rising(0, 54), 'cpu="0",mode="idle"'),
        series("node_cpu_seconds_total", host, rising(0, 1), 'cpu="0",mode="iowait"'),
        series("node_load1", host, flat(0.5)),
        series("node_load15", host, flat(0.5)),
        series("node_memory_MemTotal_bytes", host, flat(64 * GIB)),
        series("node_memory_MemAvailable_bytes", host, flat(32 * GIB)),
        series("node_memory_SwapTotal_bytes", host, flat(8 * GIB)),
        series("node_memory_SwapFree_bytes", host, flat(8 * GIB)),
        series("node_filesystem_size_bytes", host, flat(100 * GIB), disk),
        series("node_filesystem_avail_bytes", host, flat(70 * GIB), disk),
        series("node_filesystem_readonly", host, flat(0), disk),
        series("node_disk_read_bytes_total", host, rising(0, 1000), 'device="sda"'),
        series("node_disk_written_bytes_total", host, rising(0, 1000), 'device="sda"'),
        series("node_disk_io_time_seconds_total", host, rising(0, 6), 'device="sda"'),
        series("node_network_receive_bytes_total", host, rising(0, 1000), 'device="eno1"'),
        series("node_network_transmit_bytes_total", host, rising(0, 1000), 'device="eno1"'),
        series("node_hwmon_temp_celsius", host, flat(45), 'chip="platform_coretemp_0",sensor="temp1"'),
        series("infra_collector_timestamp_seconds", host, rising(0, 60), 'collector="smart"'),
    ]


def full_host(host: str, rack: str) -> list[dict]:
    disk = 'device="sda",model="X"'
    nvme = 'device="nvme0",model="Y"'
    return base_host(host, "pve", rack) + probes(host, ("icmp", "ssh", "web"), flat(1)) + [
        series("node_zfs_arc_size", host, flat(16 * GIB)),
        series("node_zfs_arc_c_min", host, flat(2 * GIB)),
        series("node_zfs_zpool_state", host, flat(1), 'zpool="rpool",state="online"'),
        series("node_zfs_zpool_state", host, flat(0), 'zpool="rpool",state="degraded"'),
        series("infra_smart_healthy", host, flat(1), disk),
        series("infra_smart_temperature_celsius", host, flat(40), disk),
        series("infra_smart_power_on_seconds", host, flat(1000), disk),
        series("infra_smart_reallocated_sectors", host, flat(8), disk),
        series("infra_smart_pending_sectors", host, flat(0), disk),
        series("infra_smart_offline_uncorrectable_sectors", host, flat(0), disk),
        series("infra_smart_temperature_celsius", host, flat(50), nvme),
        series("infra_smart_wear_percent", host, flat(10), nvme),
        series("infra_smart_media_errors", host, flat(0), nvme),
        series("infra_smart_critical_warning", host, flat(0), nvme),
        series("infra_gpu_utilization_percent", host, flat(20), 'gpu="nvidia0",model="Z"'),
        series("infra_gpu_memory_used_bytes", host, flat(1), 'gpu="nvidia0",model="Z"'),
        series("infra_gpu_memory_size_bytes", host, flat(2), 'gpu="nvidia0",model="Z"'),
        series("infra_gpu_temperature_celsius", host, flat(60), 'gpu="nvidia0",model="Z"'),
        series("infra_pve_guests", host, flat(3), 'type="qemu",state="running"'),
        series("infra_pve_guests", host, flat(5), 'type="qemu",state="total"'),
        series("infra_pve_guests", host, flat(1), 'type="lxc",state="running"'),
        series("infra_pve_guests", host, flat(1), 'type="lxc",state="total"'),
        series("infra_pve_storage_size_bytes", host, flat(100 * GIB), 'storage="local-lvm",type="lvmthin"'),
        series("infra_pve_storage_used_bytes", host, flat(40 * GIB), 'storage="local-lvm",type="lvmthin"'),
        series("infra_collector_timestamp_seconds", host, rising(0, 60), 'collector="pve"'),
        series("infra_collector_timestamp_seconds", host, rising(0, 60), 'collector="gpu"'),
    ]
