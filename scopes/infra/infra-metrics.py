#!/usr/bin/python3 -I
"""Writes host facts for Alloy's textfile collector (Prometheus text format),
run by the cointmu-infra-*.timer units (scopes/infra/README.md).

    infra-metrics.py smart   SMART health per disk           (smartctl, root)
    infra-metrics.py pve     guest states, storage usage     (qm, pct, pvesm, root)
    infra-metrics.py gpu     utilisation, memory, temperature (nvidia-smi, sysfs)

Each collector writes /var/lib/cointmu-infra/<collector>/<collector>.prom. A host
without the hardware or the tool gets infra_collector_timestamp_seconds only and
exit code 0, so its panels stay empty and nothing fails. Numbers, device or model
names, and Proxmox guest IDs and names: no serial numbers, no addresses.

The folder must be group alloy, mode 2750 (cointmu-infra.tmpfiles.conf): files
written here then belong to group alloy, which the Alloy agent reads with.
"""
from __future__ import annotations

import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import sys
import time

OUT_ROOT = pathlib.Path(os.environ.get("INFRA_OUT_ROOT", "/var/lib/cointmu-infra"))
SYS_ROOT = pathlib.Path(os.environ.get("INFRA_SYS_ROOT", "/sys"))
READER_GROUP_MODE = 0o2750
FILE_UMASK = 0o027
COMMAND_TIMEOUT_SECONDS = 30
KIB = 1024
MIB = 1024 * 1024
MILLI = 1000
SECONDS_PER_HOUR = 3600
MAX_LABEL_LENGTH = 64
# smartctl's exit status is a bit mask; with "-n standby" bit 1 also means the
# disk sleeps and was left alone.
SMARTCTL_OPEN_FAILED = 0b10
ATA_ATTRIBUTES = {5: "reallocated_sectors", 197: "pending_sectors", 198: "offline_uncorrectable_sectors"}
NVIDIA_FIELDS = ("index", "name", "utilization.gpu", "memory.used", "memory.total", "temperature.gpu")

HELP = {
    "infra_collector_timestamp_seconds": "When this collector last ran",
    "infra_smart_healthy": "1 if the disk's own SMART health check passes",
    "infra_smart_standby": "1 if the disk sleeps and was not read",
    "infra_smart_temperature_celsius": "Disk temperature",
    "infra_smart_power_on_seconds": "Time the disk has been on",
    "infra_smart_reallocated_sectors": "Reallocated sectors (ATA 5) or grown defects (SAS)",
    "infra_smart_pending_sectors": "Sectors waiting to be reallocated (ATA 197)",
    "infra_smart_offline_uncorrectable_sectors": "Uncorrectable sectors (ATA 198)",
    "infra_smart_wear_percent": "Used endurance of an SSD; 100 is the rated end",
    "infra_smart_media_errors": "NVMe media and data integrity errors",
    "infra_smart_critical_warning": "NVMe critical warning bits; 0 is fine",
    "infra_pve_guests": "Guests of this Proxmox host by type and state",
    "infra_pve_guest_running": "1 if this Proxmox guest runs, 0 if not",
    "infra_pve_storage_used_bytes": "Used bytes of an active Proxmox storage",
    "infra_pve_storage_size_bytes": "Size of an active Proxmox storage",
    "infra_gpu_utilization_percent": "GPU utilisation",
    "infra_gpu_memory_used_bytes": "GPU memory in use",
    "infra_gpu_memory_size_bytes": "GPU memory",
    "infra_gpu_temperature_celsius": "GPU temperature",
}


class Metrics:
    """Collects samples per metric name, so each name gets one TYPE line."""

    def __init__(self) -> None:
        self.samples: dict[str, list[str]] = {}

    def add(self, name: str, value: float | None, **labels: str) -> None:
        if value is None:
            return
        pairs = ",".join(f'{key}="{clean(text)}"' for key, text in labels.items())
        # Whole numbers as such: bytes and timestamps must not be rounded.
        shown = int(value) if value == int(value) else value
        self.samples.setdefault(name, []).append(f"{name}{{{pairs}}} {shown}" if pairs else f"{name} {shown}")

    def text(self) -> str:
        return "".join(
            f"# HELP {name} {HELP[name]}\n# TYPE {name} gauge\n" + "".join(f"{line}\n" for line in lines)
            for name, lines in self.samples.items())


def clean(text: str) -> str:
    """Label values: only characters that need no escaping."""
    return re.sub(r"[^A-Za-z0-9 ._:,/+-]", "_", text)[:MAX_LABEL_LENGTH]


def number(text: object) -> float | None:
    try:
        return float(str(text))
    except ValueError:
        return None


def run(*command: str) -> subprocess.CompletedProcess:
    return subprocess.run(command, capture_output=True, text=True, timeout=COMMAND_TIMEOUT_SECONDS, check=False)


def output_of(*command: str) -> str:
    """Standard output of a command that must succeed; exits with its error otherwise."""
    result = run(*command)
    if result.returncode != 0:
        sys.exit(f"infra-metrics: {' '.join(command)}: {result.stderr.strip()[:200]}")
    return result.stdout


# --- SMART ---------------------------------------------------------------------

def add_disk(metrics: Metrics, device: dict, seen_serials: set[str]) -> None:
    # A RAID member ("megaraid,0") needs its type, and shares the device name with
    # the others. Any other type is a guess of --scan ("scsi" for SATA disks):
    # without it smartctl looks for itself.
    name, kind = device["name"].removeprefix("/dev/"), device["type"]
    is_raid_member = "," in kind
    label = f"{name}:{kind}" if is_raid_member else name
    type_option = (f"--device={kind}",) if is_raid_member else ()
    result = run("smartctl", "--json", "--all", "--nocheck=standby", *type_option, device["name"])
    data = json.loads(result.stdout or "{}")
    if result.returncode & SMARTCTL_OPEN_FAILED:
        metrics.add("infra_smart_standby", 1 if "standby" in result.stdout.lower() else None, device=label)
        return
    # A MegaRAID JBOD disk is listed twice by --scan (/dev/sdX and megaraid,N):
    # one disk, one set of series, so its alerts fire once.
    serial = data.get("serial_number")
    if serial in seen_serials:
        return
    if serial:
        seen_serials.add(serial)
    labels = {"device": label, "model": data.get("model_name") or data.get("scsi_model_name") or "unknown"}
    passed = data.get("smart_status", {}).get("passed")
    metrics.add("infra_smart_healthy", None if passed is None else int(passed), **labels)
    metrics.add("infra_smart_standby", 0, device=label)
    metrics.add("infra_smart_temperature_celsius", data.get("temperature", {}).get("current"), **labels)
    hours = data.get("power_on_time", {}).get("hours")
    metrics.add("infra_smart_power_on_seconds", None if hours is None else hours * SECONDS_PER_HOUR, **labels)
    metrics.add("infra_smart_wear_percent", data.get("endurance_used", {}).get("current_percent"), **labels)
    metrics.add("infra_smart_reallocated_sectors", data.get("scsi_grown_defect_list"), **labels)
    for row in data.get("ata_smart_attributes", {}).get("table", []):
        if row["id"] in ATA_ATTRIBUTES:
            metrics.add(f"infra_smart_{ATA_ATTRIBUTES[row['id']]}", row["raw"]["value"], **labels)
    nvme = data.get("nvme_smart_health_information_log", {})
    metrics.add("infra_smart_critical_warning", nvme.get("critical_warning"), **labels)
    metrics.add("infra_smart_media_errors", nvme.get("media_errors"), **labels)
    if "endurance_used" not in data:
        metrics.add("infra_smart_wear_percent", nvme.get("percentage_used"), **labels)


def collect_smart(metrics: Metrics) -> None:
    if not shutil.which("smartctl"):
        return
    # --scan, not --scan-open: opening would wake sleeping disks.
    seen_serials: set[str] = set()
    for device in json.loads(output_of("smartctl", "--json", "--scan")).get("devices", []):
        add_disk(metrics, device, seen_serials)


# --- Proxmox -------------------------------------------------------------------

def rows(text: str) -> list[list[str]]:
    """Fields of every line after the header."""
    return [line.split() for line in text.splitlines()[1:] if line.strip()]


def collect_pve(metrics: Metrics) -> None:
    if not shutil.which("qm"):
        return
    # qm: VMID NAME STATUS ...; pct: VMID Status [Lock] [Name], the name last when there is one.
    guests = {"qemu": [(row[0], row[1], row[2]) for row in rows(output_of("qm", "list"))],
              "lxc": [(row[0], row[-1] if len(row) > 2 else "", row[1]) for row in rows(output_of("pct", "list"))]}
    for kind, found in guests.items():
        states = [state for _, _, state in found]
        metrics.add("infra_pve_guests", states.count("running"), type=kind, state="running")
        metrics.add("infra_pve_guests", len(states), type=kind, state="total")
        for vmid, name, state in found:
            metrics.add("infra_pve_guest_running", int(state == "running"), type=kind, vmid=vmid, guest=name)
    # Name Type Status Total Used Available %, sizes in KiB.
    for name, kind, status, total, used, *_ in rows(output_of("pvesm", "status")):
        if status == "active" and number(total):
            metrics.add("infra_pve_storage_size_bytes", float(total) * KIB, storage=name, type=kind)
            metrics.add("infra_pve_storage_used_bytes", float(used) * KIB, storage=name, type=kind)


# --- GPU -----------------------------------------------------------------------

def add_nvidia(metrics: Metrics) -> None:
    result = run("nvidia-smi", f"--query-gpu={','.join(NVIDIA_FIELDS)}", "--format=csv,noheader,nounits")
    # It fails when no GPU is left for the host (passed through to a guest).
    if result.returncode != 0:
        return
    for line in result.stdout.splitlines():
        index, name, *values = (field.strip() for field in line.split(","))
        used_percent, used_mib, size_mib, celsius = (number(value) for value in values)
        labels = {"gpu": f"nvidia{index}", "model": name}
        metrics.add("infra_gpu_utilization_percent", used_percent, **labels)
        metrics.add("infra_gpu_memory_used_bytes", None if used_mib is None else used_mib * MIB, **labels)
        metrics.add("infra_gpu_memory_size_bytes", None if size_mib is None else size_mib * MIB, **labels)
        metrics.add("infra_gpu_temperature_celsius", celsius, **labels)


def sysfs_number(path: pathlib.Path) -> float | None:
    try:
        return number(path.read_text().strip())
    except OSError:
        return None


def add_sysfs_card(metrics: Metrics, card: pathlib.Path) -> None:
    device = card / "device"
    driver = (device / "driver").resolve().name
    if driver not in ("amdgpu", "i915", "xe"):
        return
    labels = {"gpu": card.name, "model": driver}
    metrics.add("infra_gpu_utilization_percent", sysfs_number(device / "gpu_busy_percent"), **labels)
    metrics.add("infra_gpu_memory_used_bytes", sysfs_number(device / "mem_info_vram_used"), **labels)
    metrics.add("infra_gpu_memory_size_bytes", sysfs_number(device / "mem_info_vram_total"), **labels)
    temperatures = [sysfs_number(path) for path in sorted(device.glob("hwmon/hwmon*/temp1_input"))]
    if temperatures and temperatures[0] is not None:
        metrics.add("infra_gpu_temperature_celsius", temperatures[0] / MILLI, **labels)


def collect_gpu(metrics: Metrics) -> None:
    if shutil.which("nvidia-smi"):
        add_nvidia(metrics)
    for card in sorted((SYS_ROOT / "class/drm").glob("card[0-9]*")):
        if re.fullmatch(r"card\d+", card.name):
            add_sysfs_card(metrics, card)


# --- Output --------------------------------------------------------------------

def check_out_dir(folder: pathlib.Path) -> None:
    try:
        mode = stat.S_IMODE(folder.stat().st_mode)
    except FileNotFoundError:
        sys.exit(f"infra-metrics: missing {folder}: systemd-tmpfiles --create /etc/tmpfiles.d/cointmu-infra.conf")
    if mode != READER_GROUP_MODE:
        sys.exit(f"infra-metrics: {folder} has mode {mode:o}, expected {READER_GROUP_MODE:o} (cointmu-infra.tmpfiles.conf)")


COLLECTORS = {"smart": collect_smart, "pve": collect_pve, "gpu": collect_gpu}


def main() -> None:
    if len(sys.argv) != 2 or sys.argv[1] not in COLLECTORS:
        sys.exit(__doc__)
    name = sys.argv[1]
    folder = OUT_ROOT / name
    check_out_dir(folder)
    metrics = Metrics()
    COLLECTORS[name](metrics)
    metrics.add("infra_collector_timestamp_seconds", time.time(), collector=name)
    os.umask(FILE_UMASK)
    partial = folder / f"{name}.prom.tmp"
    partial.write_text(metrics.text())
    # The collector reads *.prom only, so it never sees a half-written file.
    partial.replace(folder / f"{name}.prom")


if __name__ == "__main__":
    main()
