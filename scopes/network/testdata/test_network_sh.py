"""Runs scripts/network.sh in a throwaway copy of the files it uses."""
import json
import pathlib
import shutil
import subprocess
import tempfile
import unittest

REPO = pathlib.Path(__file__).resolve().parents[3]
FILES = ("scripts/network.sh", "scopes/network/snmp/auths.yml")


class NetworkScriptTest(unittest.TestCase):
    def setUp(self) -> None:
        self.root = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        for name in FILES:
            (self.root / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(REPO / name, self.root / name)

    def run_script(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(["bash", self.root / "scripts/network.sh", *args], capture_output=True, text=True, check=False)

    def targets(self, path: str) -> list[dict]:
        return json.loads((self.root / path).read_text())

    def test_add_writes_probe_and_snmp_targets(self) -> None:
        self.assertEqual(self.run_script("add", "crs125", "10.64.21.2", "--auth", "mikrotik_v3").returncode, 0)
        self.assertEqual(self.run_script("add", "sg300", "10.64.24.2", "--auth", "cisco_v3_des", "--ssh-port", "2222").returncode, 0)
        probes = self.targets("prometheus/probes/network.json")
        self.assertIn({"targets": ["10.64.24.2:2222"], "labels": {"host": "sg300", "scope": "network", "probe": "ssh",
                                                                 "__param_module": "tcp"}}, probes)
        self.assertEqual(len(probes), 4)
        snmp = self.targets("prometheus/probes/snmp/targets.json")
        self.assertEqual(snmp[0], {"targets": ["10.64.21.2"], "labels": {"host": "crs125", "scope": "network",
                                   "__param_auth": "mikrotik_v3", "__param_module": "if_mib,system"}})
        self.assertIn("cisco_v3_des", self.run_script("list").stdout)

    def test_remove_drops_the_device_from_both_files(self) -> None:
        self.run_script("add", "crs125", "10.64.21.2", "--auth", "mikrotik_v3")
        self.assertEqual(self.run_script("remove", "crs125").returncode, 0)
        self.assertEqual(self.targets("prometheus/probes/network.json"), [])
        self.assertEqual(self.targets("prometheus/probes/snmp/targets.json"), [])

    def test_refusals_change_nothing(self) -> None:
        self.run_script("add", "crs125", "10.64.21.2", "--auth", "mikrotik_v3")
        before = (self.root / "inventory/network.tsv").read_text()
        for args, expected in ((("add", "x", "10.0.0.1", "--auth", "public_v2"), "unknown --auth"),
                               (("add", "x", "10.0.0.1"), "--auth is required"),
                               (("add", "Bad Name", "10.0.0.1", "--auth", "mikrotik_v3"), "invalid name"),
                               (("add", "x", "10.0.0.300", "--auth", "mikrotik_v3"), "invalid ip"),
                               (("add", "crs125", "10.0.0.1", "--auth", "mikrotik_v3"), "exists"),
                               (("remove", "nope"), "unknown device")):
            result = self.run_script(*args)
            self.assertNotEqual(result.returncode, 0, args)
            self.assertIn(expected, result.stderr, args)
        self.assertEqual((self.root / "inventory/network.tsv").read_text(), before)


if __name__ == "__main__":
    unittest.main()
