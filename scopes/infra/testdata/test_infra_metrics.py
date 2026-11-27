"""Runs infra-metrics.py against stub tools and a fake /sys.

    test_infra_metrics.py [<folder>]   also copies the .prom files there (promtool)
"""
import json
import pathlib
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).parent.parent / "infra-metrics.py"
KEEP = pathlib.Path(sys.argv.pop(1)) if len(sys.argv) > 1 and not sys.argv[1].startswith("-") else None
GOOD, FAILING, NVME, ASLEEP, RAID = "/dev/sda", "/dev/sdb", "/dev/nvme0", "/dev/sdc", "/dev/bus/0"
SCAN = {"devices": [{"name": GOOD, "type": "scsi"}, {"name": FAILING, "type": "scsi"}, {"name": NVME, "type": "nvme"},
                    {"name": ASLEEP, "type": "scsi"}, {"name": RAID, "type": "megaraid,3"}]}


def ata(passed: bool, pending: int) -> dict:
    table = [{"id": 5, "raw": {"value": 8}}, {"id": 197, "raw": {"value": pending}}, {"id": 9, "raw": {"value": 1}}]
    return {"model_name": "WDC \"X\"", "smart_status": {"passed": passed}, "temperature": {"current": 41},
            "power_on_time": {"hours": 123456}, "ata_smart_attributes": {"table": table}}


DISKS = {
    GOOD: (0, ata(True, 0)),
    FAILING: (8, ata(False, 16)),
    NVME: (0, {"model_name": "Samsung", "smart_status": {"passed": True}, "temperature": {"current": 50},
               "nvme_smart_health_information_log": {"critical_warning": 4, "percentage_used": 93, "media_errors": 2}}),
    ASLEEP: (2, {"smartctl": {"messages": [{"string": "Device is in STANDBY mode, exit(2)"}]}}),
    RAID: (0, {"scsi_model_name": "SEAGATE", "smart_status": {"passed": True}, "scsi_grown_defect_list": 3}),
}


class InfraMetricsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.root = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        self.bin, self.sys = self.root / "bin", self.root / "sys"
        self.bin.mkdir()
        # Nothing else on PATH: the machine running this may have the real tools.
        (self.bin / "cat").symlink_to(shutil.which("cat"))
        for name in ("smart", "pve", "gpu"):
            (self.root / name).mkdir()
            (self.root / name).chmod(0o2750)

    def stub(self, name: str, script: str) -> None:
        path = self.bin / name
        path.write_text(f"#!/bin/sh\n{script}\n")
        path.chmod(0o755)

    def collect(self, name: str) -> str:
        env = {"PATH": str(self.bin), "INFRA_OUT_ROOT": str(self.root), "INFRA_SYS_ROOT": str(self.sys)}
        subprocess.run([sys.executable, "-I", SCRIPT, name], env=env, check=True, capture_output=True, text=True)
        text = (self.root / name / f"{name}.prom").read_text()
        if KEEP:
            (KEEP / f"{self.id().rsplit('.', 1)[-1]}.prom").write_text(text)
        return text

    def stub_smartctl(self) -> None:
        cases = "\n".join(f"*' {device}') cat <<'E'\n{json.dumps(data)}\nE\nexit {code};;"
                          for device, (code, data) in DISKS.items())
        self.stub("smartctl", f"echo \"$@\" >> {self.root}/calls\ncase \"$*\" in\n*--scan*) cat <<'E'\n{json.dumps(SCAN)}\nE\n;;\n{cases}\nesac")

    def test_smart(self) -> None:
        self.stub_smartctl()
        text = self.collect("smart")
        for line in ('infra_smart_healthy{device="sda",model="WDC _X_"} 1', 'infra_smart_healthy{device="sdb",model="WDC _X_"} 0',
                     'infra_smart_pending_sectors{device="sdb",model="WDC _X_"} 16',
                     'infra_smart_power_on_seconds{device="sda",model="WDC _X_"} 444441600',
                     'infra_smart_critical_warning{device="nvme0",model="Samsung"} 4',
                     'infra_smart_wear_percent{device="nvme0",model="Samsung"} 93', 'infra_smart_standby{device="sdc"} 1',
                     'infra_smart_reallocated_sectors{device="bus/0:megaraid,3",model="SEAGATE"} 3'):
            self.assertIn(line + "\n", text)
        self.assertNotIn('infra_smart_healthy{device="sdc"', text)

    def test_smart_lets_smartctl_detect_the_type_except_for_raid_members(self) -> None:
        self.stub_smartctl()
        self.collect("smart")
        calls = (self.root / "calls").read_text().splitlines()
        self.assertEqual([c for c in calls if "--device" in c], [f"--json --all --nocheck=standby --device=megaraid,3 {RAID}"])

    def test_smart_reports_a_disk_seen_twice_once(self) -> None:
        # A MegaRAID JBOD disk is listed by --scan as /dev/sdX and as a RAID member.
        scan = {"devices": [{"name": GOOD, "type": "scsi"}, {"name": RAID, "type": "megaraid,1"}]}
        disk = json.dumps({"scsi_model_name": "SEAGATE", "serial_number": "WX121JRE", "smart_status": {"passed": True}})
        self.stub("smartctl", f"case \"$*\" in\n*--scan*) echo '{json.dumps(scan)}';;\n*) echo '{disk}';;\nesac")
        text = self.collect("smart")
        self.assertIn('infra_smart_healthy{device="sda",model="SEAGATE"} 1\n', text)
        self.assertNotIn("megaraid", text)

    def test_pve(self) -> None:
        self.stub("qm", "printf ' VMID NAME STATUS MEM(MB) BOOTDISK(GB) PID\\n 104 a running 4096 200.00 1\\n 9000 t stopped 1 1 0\\n'")
        self.stub("pct", "printf 'VMID Status Lock Name\\n106 running  x\\n107 stopped backup locked\\n108 stopped\\n'")
        self.stub("pvesm", "printf 'Name Type Status Total Used Available %%\\nlocal-lvm lvmthin active 1000000000 900000000 100000000 90.00%%\\nnas nfs inactive 0 0 0 0.00%%\\n'")
        text = self.collect("pve")
        for line in ('infra_pve_guests{type="qemu",state="running"} 1', 'infra_pve_guests{type="qemu",state="total"} 2',
                     'infra_pve_guests{type="lxc",state="running"} 1',
                     'infra_pve_guest_running{type="qemu",vmid="104",guest="a"} 1',
                     'infra_pve_guest_running{type="qemu",vmid="9000",guest="t"} 0',
                     'infra_pve_guest_running{type="lxc",vmid="106",guest="x"} 1',
                     'infra_pve_guest_running{type="lxc",vmid="107",guest="locked"} 0',
                     'infra_pve_guest_running{type="lxc",vmid="108",guest=""} 0',
                     'infra_pve_storage_used_bytes{storage="local-lvm",type="lvmthin"} 921600000000'):
            self.assertIn(line + "\n", text)
        self.assertNotIn("nas", text)
        # Guest IDs and names only on the per-guest metric, never the qm memory or disk columns.
        self.assertNotIn("4096", text)

    def test_pve_without_guests(self) -> None:
        for name in ("qm", "pct"):
            self.stub(name, "true")
        self.stub("pvesm", "printf 'Name Type Status Total Used Available %%\\n'")
        self.assertIn('infra_pve_guests{type="lxc",state="total"} 0\n', self.collect("pve"))

    def test_gpu_nvidia(self) -> None:
        self.stub("nvidia-smi", "echo '0, NVIDIA RTX A2000, 37, 512, 6138, 61'; echo '1, Old, [N/A], 10, 20, 50'")
        text = self.collect("gpu")
        self.assertIn('infra_gpu_memory_used_bytes{gpu="nvidia0",model="NVIDIA RTX A2000"} 536870912\n', text)
        self.assertNotIn('infra_gpu_utilization_percent{gpu="nvidia1"', text)

    def test_gpu_amd_sysfs(self) -> None:
        device = self.sys / "class/drm/card0/device"
        (device / "hwmon/hwmon3").mkdir(parents=True)
        (self.sys / "drivers/amdgpu").mkdir(parents=True)
        (device / "driver").symlink_to(self.sys / "drivers/amdgpu")
        (device / "gpu_busy_percent").write_text("12\n")
        (device / "hwmon/hwmon3/temp1_input").write_text("55500\n")
        (self.sys / "class/drm/card0-DP-1").mkdir()
        text = self.collect("gpu")
        self.assertIn('infra_gpu_temperature_celsius{gpu="card0",model="amdgpu"} 55.5\n', text)
        self.assertIn('infra_gpu_utilization_percent{gpu="card0",model="amdgpu"} 12\n', text)

    def test_gpu_passed_through_to_a_guest(self) -> None:
        self.stub("nvidia-smi", "echo 'No devices were found'; exit 6")
        self.assertNotIn("infra_gpu", self.collect("gpu"))

    def test_hosts_without_the_hardware_write_the_timestamp_only(self) -> None:
        for name in ("smart", "pve", "gpu"):
            with self.subTest(name):
                lines = [line for line in self.collect(name).splitlines() if not line.startswith("#")]
                self.assertEqual(len(lines), 1)
                self.assertRegex(lines[0], rf'^infra_collector_timestamp_seconds{{collector="{name}"}} \d{{10}}')

    def test_refuses_a_folder_alloy_cannot_read(self) -> None:
        (self.root / "gpu").chmod(0o755)
        with self.assertRaises(subprocess.CalledProcessError) as caught:
            self.collect("gpu")
        self.assertIn("expected 2750", caught.exception.stderr)

    def test_a_failing_tool_fails_the_unit(self) -> None:
        self.stub("qm", "echo 'ipcc_send_rec failed' >&2; exit 255")
        with self.assertRaises(subprocess.CalledProcessError) as caught:
            self.collect("pve")
        self.assertIn("ipcc_send_rec failed", caught.exception.stderr)


if __name__ == "__main__":
    unittest.main()
