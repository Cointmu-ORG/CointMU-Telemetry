"""Turns rules.yml into Prometheus alerting rules and writes a promtool test per
scenario: which rules fire for which host, and that nothing else does.

    check_rules.py <output folder>   then: promtool test rules <folder>/rules-test.yml
"""
import pathlib
import sys

import series
import yaml

RULES = pathlib.Path(__file__).parent.parent / "alerting/rules.yml"
START = 1500  # minute at which a scenario begins
EVAL = 1600
AFTER = series.LENGTH - START
OPERATORS = {"gt": ">", "lt": "<"}
HOST = "pve1"


def prometheus_rules() -> dict:
    found = []
    for rule in yaml.safe_load(RULES.read_text())["groups"][0]["rules"]:
        data = {d["refId"]: d["model"] for d in rule["data"]}
        evaluator = data["C"]["conditions"][0]["evaluator"]
        condition = f"({data['A']['expr']}) {OPERATORS[evaluator['type']]} {evaluator['params'][0]}"
        found.append({"alert": rule["uid"], "expr": condition, "for": rule["for"]})
    return {"groups": [{"name": "infra", "rules": found}]}


def change(found: list[dict], name: str, values: str, labels: str = "") -> list[dict]:
    """The same series, with new values for every series of that name and labels."""
    changed = [dict(s, values=values) if s["series"].startswith(f"{name}{{") and labels in s["series"] else s for s in found]
    assert changed != found, f"no series {name} with {labels}"
    return changed


def then(before: float, after: float, at: int = START) -> str:
    return f"{before}+0x{at} {after}+0x{series.LENGTH - at}"


def dead(host: str, rack: str = "R1") -> list[dict]:
    """Metrics stop, probes fail."""
    found = [s for s in series.full_host(host, rack) if not s["series"].startswith("probe_")]
    found = [dict(s, values=s["values"].replace(f"x{series.LENGTH}", f"x{START}")) for s in found]
    return found + series.probes(host, ("icmp", "ssh", "web"), then(1, 0))


def silent(found: list[dict]) -> list[dict]:
    return [s if s["series"].startswith("probe_") else dict(s, values=s["values"].replace(f"x{series.LENGTH}", f"x{START}")) for s in found]


def without_probes(found: list[dict]) -> list[dict]:
    return [s for s in found if not s["series"].startswith("probe_")]


def scenarios() -> dict[str, tuple[list[dict], list[tuple[str, str]]]]:
    ok = series.full_host(HOST, "R1")
    other = series.base_host("vm1", "linux", "none") + series.probes("vm1", ("icmp", "ssh"), series.flat(1))
    gib = series.GIB
    cpu = change(ok, "node_cpu_seconds_total", f"0+54x{START} {54 * START}+1x{AFTER}", 'mode="idle"')
    arc = change(ok, "node_memory_MemAvailable_bytes", then(32 * gib, 4 * gib))
    ram = change(arc, "node_zfs_arc_size", then(16 * gib, 2 * gib))
    disk = change(ok, "node_filesystem_avail_bytes", then(70 * gib, 10 * gib))
    readonly = change(disk, "node_filesystem_readonly", series.flat(1))
    pool = change(ok, "infra_pve_storage_used_bytes", then(40 * gib, 97 * gib))
    # 35 GiB free, then losing 2.4 GiB an hour.
    filling = change(ok, "node_filesystem_avail_bytes", f"{80 * gib}+0x{START - 300} {35 * gib}-{gib // 25}x{series.LENGTH - START + 300}")
    pool_filling = change(ok, "infra_pve_storage_used_bytes", f"{20 * gib}+0x{START - 300} {65 * gib}+{gib // 25}x{AFTER + 300}")
    young = [dict(s, values=f"_x{EVAL - 60} " + f"{35 * gib}-{gib // 5}x100") if s["series"].startswith("node_filesystem_avail") else s for s in ok]
    chips = [series.series("node_hwmon_chip_names", HOST, series.flat(1), 'chip="platform_coretemp_0",chip_name="coretemp"')]
    hot_cpu = change(ok, "node_hwmon_temp_celsius", then(45, 95)) + chips
    hot_other = change(ok, "node_hwmon_temp_celsius", then(45, 95))
    stale_smart = change(ok, "infra_collector_timestamp_seconds", f"0+60x{START} {60 * START}+0x{AFTER}", 'collector="smart"')
    stale_pve = change(ok, "infra_collector_timestamp_seconds", f"0+60x{START} {60 * START}+0x{AFTER}", 'collector="pve"')
    watchdog = [series.series("infra_collector_timestamp_seconds", "vm1", f"0+60x{START} {60 * START}+0x{AFTER}", 'collector="watchdog"')]
    many = [s for i in range(5) for s in dead(f"pve{i}")] + other
    few = [s for i in range(3) for s in dead(f"pve{i}")] + other
    host = [("infra-host-down", HOST)]
    return {
        "healthy": (ok + other, []),
        "host dead": (dead(HOST) + other, host),
        "agent stopped, host up": (silent(ok) + other, [("infra-agent-silent", HOST)]),
        "host dead while the probes do not work": (without_probes(dead(HOST)) + other, [("infra-agent-silent", HOST)]),
        "probes fail, pushes arrive": (without_probes(ok) + series.probes(HOST, ("icmp", "ssh", "web"), then(1, 0)) + other, [("infra-unreachable", HOST)]),
        "only one probe fails": (without_probes(ok) + series.probes(HOST, ("icmp", "ssh"), series.flat(1)) + series.probes(HOST, ("web",), then(1, 0)) + other, []),
        "three of four hosts dead": (few, [("infra-host-down", f"pve{i}") for i in range(3)]),
        "five of six hosts dead": (many, [("infra-many-down", "")]),
        "no probe results at all": (without_probes(ok) + without_probes(other), [("infra-probes-blind", "")]),
        "CPU busy": (cpu + other, [("infra-cpu-high", HOST)]),
        "RAM full of ZFS cache": (arc + other, []),
        "RAM full": (ram + other, [("infra-ram-high", HOST)]),
        "filesystem at 90 %": (disk + other, [("infra-disk-high", HOST)]),
        "full read-only filesystem": (readonly + other, []),
        "thin pool at 97 %": (pool + other, [("infra-disk-critical", HOST), ("infra-disk-high", HOST)]),
        "filling up": (filling + other, [("infra-disk-filling", HOST)]),
        "thin pool filling up": (pool_filling + other, [("infra-disk-filling", HOST)]),
        "filling up, one hour of data": (young + other, []),
        "CPU hot": (hot_cpu + other, [("infra-temperature-high", HOST)]),
        "hot sensor that is not the CPU": (hot_other + other, []),
        "NVMe hot": (change(ok, "infra_smart_temperature_celsius", then(50, 75), "nvme0") + other, [("infra-temperature-high", HOST)]),
        "disk at 65": (change(ok, "infra_smart_temperature_celsius", then(40, 65), "sda") + other, [("infra-temperature-high", HOST)]),
        "GPU hot": (change(ok, "infra_gpu_temperature_celsius", then(60, 90)) + other, [("infra-temperature-high", HOST)]),
        "SMART failing": (change(ok, "infra_smart_healthy", then(1, 0)) + other, [("infra-smart-failing", HOST)]),
        "pending sectors": (change(ok, "infra_smart_pending_sectors", then(0, 8)) + other, [("infra-smart-prefail", HOST)]),
        "new reallocated sectors": (change(ok, "infra_smart_reallocated_sectors", then(8, 16)) + other, [("infra-smart-prefail", HOST)]),
        "NVMe warning": (change(ok, "infra_smart_critical_warning", then(0, 1)) + other, [("infra-smart-prefail", HOST)]),
        "SSD worn": (change(ok, "infra_smart_wear_percent", then(10, 95)) + other, [("infra-smart-prefail", HOST)]),
        "ZFS degraded": (change(change(ok, "node_zfs_zpool_state", then(0, 1), "degraded"), "node_zfs_zpool_state", then(1, 0), "online") + other, [("infra-zfs-degraded", HOST)]),
        "SMART collector stopped": (stale_smart + other, [("infra-collector-stale", HOST)]),
        "Proxmox collector stopped": (stale_pve + other, [("infra-collector-stale", HOST)]),
        "watchdog stopped": (ok + other + watchdog, [("infra-watchdog-stale", "vm1")]),
    }


def test(name: str, input_series: list[dict], firing: list[tuple[str, str]]) -> dict:
    samples = [{"labels": f'{{alertname="{uid}"' + (f',host="{host}"' if host else "") + "}", "value": 1} for uid, host in firing]
    return {"name": name, "interval": series.INTERVAL, "input_series": input_series, "promql_expr_test": [{
        "expr": 'group by (alertname, host) (ALERTS{alertstate="firing"})', "eval_time": f"{EVAL}m", "exp_samples": samples}]}


def main() -> None:
    folder = pathlib.Path(sys.argv[1])
    cases = scenarios()
    covered = {uid for _, firing in cases.values() for uid, _ in firing}
    missing = {r["alert"] for r in prometheus_rules()["groups"][0]["rules"]} - covered
    if missing:
        raise SystemExit(f"rules without a scenario: {sorted(missing)}")
    (folder / "rules.yml").write_text(yaml.safe_dump(prometheus_rules(), sort_keys=False))
    (folder / "rules-test.yml").write_text(yaml.safe_dump(
        {"rule_files": ["rules.yml"], "evaluation_interval": "1m",
         "tests": [test(name, *case) for name, case in cases.items()]}, sort_keys=False))
    print(f"{len(cases)} alert scenarios")


if __name__ == "__main__":
    main()
