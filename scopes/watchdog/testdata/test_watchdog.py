"""Runs watchdog.sh against local listeners and a stub curl that records posts."""
import pathlib
import shutil
import socket
import subprocess
import tempfile
import unittest

SCRIPT = pathlib.Path(__file__).parent.parent / "watchdog.sh"
CONFIRM_RUNS = 3
# Health checks: fail while the file "unhealthy" exists. Posts: channel and text
# are appended to "posts"; they fail while "offline" exists.
CURL = """#!/bin/bash
root="{root}"
for argument in "$@"; do
  case "$argument" in
    https://vm.test/*) [ ! -e "$root/unhealthy" ]; exit $? ;;
    -K) next=config ;;
    *) if [ "$next" = config ]; then url=$(cat "$argument"); next=""; fi ;;
  esac
done
[ -e "$root/offline" ] && exit 7
case "$*" in *discord.com*) echo LEAK >> "$root/posts" ;; esac
channel=infra; case "$url" in */111/*) channel=servers ;; esac
echo "$channel $(cat)" >> "$root/posts"
"""


class WatchdogTest(unittest.TestCase):
    def setUp(self) -> None:
        self.root = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        self.listeners: dict[str, socket.socket] = {}
        self.ports = {name: self.listen(name) for name in ("pve", "vm")}
        for folder in ("bin", "state", "metrics"):
            (self.root / folder).mkdir()
        curl = self.root / "bin/curl"
        curl.write_text(CURL.replace("{root}", str(self.root)))
        curl.chmod(0o755)
        (self.root / "conf").write_text(
            "WATCHDOG_PVE_NAME=proxmox-test\nWATCHDOG_PVE=127.0.0.1\n"
            f"WATCHDOG_PVE_PORTS=1 {self.ports['pve']}\nWATCHDOG_VM=127.0.0.1\n"
            f"WATCHDOG_VM_PORTS={self.ports['vm']}\nWATCHDOG_VM_URL=https://vm.test\n")
        self.webhook("servers", "111")
        self.webhook("infra", "222")

    def listen(self, name: str, port: int = 0) -> int:
        listener = socket.socket()
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("127.0.0.1", port))
        listener.listen(64)
        self.listeners[name] = listener
        self.addCleanup(listener.close)
        return listener.getsockname()[1]

    def webhook(self, channel: str, number: str) -> None:
        (self.root / f"webhook-{channel}").write_text(f"https://discord.com/api/webhooks/{number}/token")

    def down(self, *names: str) -> None:
        for name in names:
            self.listeners[name].close()

    def up(self, *names: str) -> None:
        for name in names:
            self.listen(name, self.ports[name])

    def run_times(self, times: int = CONFIRM_RUNS) -> list[str]:
        """Runs the watchdog; returns what it posted meanwhile."""
        posts = self.root / "posts"
        before = posts.read_text().splitlines() if posts.exists() else []
        env = {"PATH": f"{self.root}/bin:/usr/bin:/bin", "WATCHDOG_CONFIG": str(self.root / "conf"),
               "WATCHDOG_WEBHOOK_DIR": str(self.root), "WATCHDOG_STATE_DIR": str(self.root / "state"),
               "WATCHDOG_METRICS_FILE": str(self.root / "metrics/watchdog.prom")}
        for _ in range(times):
            subprocess.run([SCRIPT], env=env, check=True, capture_output=True, text=True)
        return (posts.read_text().splitlines() if posts.exists() else [])[len(before):]

    def test_healthy_posts_nothing_and_writes_the_timestamp(self) -> None:
        self.assertEqual(self.run_times(), [])
        self.assertRegex((self.root / "metrics/watchdog.prom").read_text(),
                         r'^infra_collector_timestamp_seconds{collector="watchdog"} \d{10}\n$')

    def test_host_down_goes_to_servers_once_and_recovers_there(self) -> None:
        self.down("pve", "vm")
        self.assertEqual(self.run_times(CONFIRM_RUNS - 1), [])
        posts = self.run_times(5)
        self.assertEqual(len(posts), 1)
        self.assertRegex(posts[0], r'^servers \{"content":"\*\*FAIL\*\* Proxmox host proxmox-test is unreachable')
        self.assertIn('"allowed_mentions":{"parse":[]}', posts[0])
        self.up("pve", "vm")
        posts = self.run_times(5)
        self.assertEqual(len(posts), 1)
        self.assertRegex(posts[0], r"^servers .*\*\*OK\*\* Proxmox host proxmox-test is reachable again")

    def test_vm_down_goes_to_infra(self) -> None:
        self.down("vm")
        posts = self.run_times()
        self.assertEqual(len(posts), 1)
        self.assertRegex(posts[0], r"^infra .*telemetry VM is unreachable")

    def test_stack_unhealthy_goes_to_infra(self) -> None:
        (self.root / "unhealthy").touch()
        posts = self.run_times()
        self.assertEqual(len(posts), 1)
        self.assertRegex(posts[0], r"^infra .*GlitchTip or Grafana")

    def test_management_ports_closed_while_the_vm_works_is_no_outage(self) -> None:
        self.down("pve")
        self.assertEqual(self.run_times(), [])

    def test_short_blip_posts_nothing(self) -> None:
        self.down("vm")
        self.assertEqual(self.run_times(CONFIRM_RUNS - 1), [])
        self.up("vm")
        self.assertEqual(self.run_times(), [])

    def test_host_back_before_the_vm_moves_to_the_other_channel(self) -> None:
        self.down("pve", "vm")
        self.run_times()
        self.up("pve")
        self.assertEqual([post.split()[0] for post in self.run_times()], ["servers", "infra"])

    def test_own_network_lost_posts_nothing_afterwards(self) -> None:
        self.down("pve", "vm")
        (self.root / "offline").touch()
        self.assertEqual(self.run_times(5), [])
        (self.root / "offline").unlink()
        self.up("pve", "vm")
        self.assertEqual(self.run_times(), [])

    def test_failed_post_is_retried(self) -> None:
        self.down("vm")
        (self.root / "offline").touch()
        self.run_times()
        (self.root / "offline").unlink()
        self.assertEqual(len(self.run_times(1)), 1)

    def test_url_never_on_the_command_line(self) -> None:
        self.down("vm")
        self.assertNotIn("LEAK", self.run_times())

    def test_missing_webhook_is_no_failure(self) -> None:
        (self.root / "webhook-infra").unlink()
        self.down("vm")
        self.assertEqual(self.run_times(), [])


if __name__ == "__main__":
    unittest.main()
