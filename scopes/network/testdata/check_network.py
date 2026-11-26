"""Writes promtool tests for scope network on synthetic series of two switches:
- every query of network.json returns data for one switch, and only for it
  when the host variable selects it
- every alert rule per scenario: what fires, for which switch and port, and
  nothing else; every rule is covered by a scenario

    check_network.py <output folder>
    then: promtool test rules <folder>/panels.yml <folder>/rules-test.yml
"""
import json
import pathlib
import sys

import yaml

SCOPE = pathlib.Path(__file__).parent.parent
OPERATORS = {"gt": ">", "lt": "<"}
INTERVAL = "1m"
LENGTH = 3200  # minutes: the port rule looks back two days
START = 3000  # minute at which a scenario begins
EVAL = f"{START + 100}m"
SWITCH, OTHER = "sw1", "sw2"
# Per minute: enough traffic to show, errors far below the alert threshold.
OCTETS_PER_MINUTE = 600000
QUIET_ERRORS_PER_MINUTE = 1
NOISY_ERRORS_PER_MINUTE = 180
UP, DOWN, NO_LINK = 1, 2, 7
# Port: (ifIndex, admin status, operational status). ether2 flaps, ether3 is switched off.
PORTS = {"ether1": (1, UP, UP), "ether2": (2, UP, None), "ether3": (3, DOWN, DOWN)}
FLAPPING = " ".join(str(UP if minute % 2 else NO_LINK) for minute in range(LENGTH + 1))


def flat(value: float) -> str:
    return f"{value}+0x{LENGTH}"


def then(before: float, after: float) -> str:
    return f"{before}+0x{START} {after}+0x{LENGTH - START}"


def gone_after_start(value: float) -> str:
    return f"{value}+0x{START} _x{LENGTH - START}"


def counter(per_minute: float) -> str:
    return f"0+{per_minute}x{LENGTH}"


def labels(name: str, host: str, **extra: str) -> str:
    pairs = {"host": host, "scope": "network", **extra}
    return name + "{" + ",".join(f'{key}="{value}"' for key, value in pairs.items()) + "}"


def switch_series(host: str, errors_per_minute: float = QUIET_ERRORS_PER_MINUTE) -> list[dict]:
    snmp = {"job": "network-snmp", "instance": "snmp"}
    found = [{"series": labels("probe_success", host, probe=probe, job="infra-probe", instance="probe"), "values": flat(1)}
             for probe in ("icmp", "ssh")]
    found.append({"series": labels("up", host, **snmp), "values": flat(1)})
    found.append({"series": labels("sysUpTime", host, **snmp), "values": counter(6000)})
    for name, (index, admin, oper) in PORTS.items():
        port = {**snmp, "ifIndex": str(index), "ifName": name, "ifAlias": f"to {name}", "ifDescr": name}
        found += [
            {"series": labels("ifAdminStatus", host, **port), "values": flat(admin)},
            {"series": labels("ifOperStatus", host, **port), "values": FLAPPING if oper is None else flat(oper)},
            {"series": labels("ifHighSpeed", host, **port), "values": flat(1000)},
            {"series": labels("ifHCInOctets", host, **port), "values": counter(OCTETS_PER_MINUTE)},
            {"series": labels("ifHCOutOctets", host, **port), "values": counter(OCTETS_PER_MINUTE)},
            {"series": labels("ifInErrors", host, **port), "values": counter(errors_per_minute if name == "ether1" else 0)},
            {"series": labels("ifOutErrors", host, **port), "values": counter(0)},
            {"series": labels("ifInDiscards", host, **port), "values": counter(QUIET_ERRORS_PER_MINUTE)},
            {"series": labels("ifOutDiscards", host, **port), "values": counter(0)},
        ]
    return found


def change(found: list[dict], name: str, values: str, match: str = "") -> list[dict]:
    """The same series, with new values for every series of that name containing match."""
    changed = [dict(s, values=values) if s["series"].startswith(f"{name}{{") and match in s["series"] else s for s in found]
    assert changed != found, f"no series {name} with {match}"
    return changed


def silent_snmp(found: list[dict]) -> list[dict]:
    """No SNMP data from SWITCH after START: every SNMP series ends, up turns 0."""
    snmp_names = ("sysUpTime", "ifAdminStatus", "ifOperStatus", "ifHighSpeed", "ifHC", "ifIn", "ifOut")
    ended = [dict(s, values=gone_after_start(0)) if s["series"].startswith(snmp_names) and f'host="{SWITCH}"' in s["series"] else s
             for s in found]
    return change(ended, "up", then(1, 0), f'host="{SWITCH}"')


def scenarios() -> dict[str, tuple[list[dict], list[dict]]]:
    """Name: (input series, expected alerts as {rule uid: labels})."""
    healthy = switch_series(SWITCH) + switch_series(OTHER)
    on_switch = f'host="{SWITCH}"'
    down = change(silent_snmp(healthy), "probe_success", then(1, 0), on_switch)
    port_down = change(healthy, "ifOperStatus", then(UP, DOWN), f'{on_switch},scope="network",job="network-snmp",instance="snmp",ifIndex="1"')
    noisy = switch_series(SWITCH, NOISY_ERRORS_PER_MINUTE) + switch_series(OTHER)
    return {
        "healthy (flapping and disabled ports included)": (healthy, []),
        "switch unreachable": (down, [{"rule": "network-switch-down", "labels": {"host": SWITCH}}]),
        "SNMP silent, switch reachable": (silent_snmp(healthy), [{"rule": "network-snmp-unreadable", "labels": {"host": SWITCH}}]),
        "steady port goes down": (port_down, [{"rule": "network-port-down", "labels": {"host": SWITCH, "ifName": "ether1"}}]),
        "port with errors": (noisy, [{"rule": "network-port-errors", "labels": {"host": SWITCH, "ifName": "ether1"}}]),
    }


def prometheus_rules() -> dict:
    found = []
    for rule in yaml.safe_load((SCOPE / "alerting/rules.yml").read_text())["groups"][0]["rules"]:
        data = {d["refId"]: d["model"] for d in rule["data"]}
        evaluator = data["C"]["conditions"][0]["evaluator"]
        condition = f"({data['A']['expr']}) {OPERATORS[evaluator['type']]} {evaluator['params'][0]}"
        found.append({"alert": rule["uid"], "expr": condition, "for": rule["for"]})
    return {"groups": [{"name": "network", "rules": found}]}


def rule_tests(rules: dict) -> list[dict]:
    uids = [rule["alert"] for rule in rules["groups"][0]["rules"]]
    covered = set()
    tests = []
    for name, (series, expected) in scenarios().items():
        alerts = []
        for uid in uids:
            fired = [{"exp_labels": {"alertname": uid, **e["labels"]}} for e in expected if e["rule"] == uid]
            covered.update(uid for _ in fired)
            alerts.append({"alertname": uid, "eval_time": EVAL, "exp_alerts": fired})
        tests.append({"name": name, "interval": INTERVAL, "input_series": series, "alert_rule_test": alerts})
    missing = set(uids) - covered
    assert not missing, f"rules without a scenario that fires them: {sorted(missing)}"
    return tests


def panel_tests() -> list[dict]:
    panels = json.loads((SCOPE / "dashboards/network.json").read_text())["panels"]
    tests = []
    # Collapsed rows keep their panels inside the row.
    panels += [inner for panel in panels for inner in panel.get("panels", [])]
    for expr in (target["expr"] for panel in panels for target in panel.get("targets", [])):
        selected = expr.replace("$host", SWITCH)
        tests.append({"expr": f"count({selected}) > bool 0", "eval_time": EVAL, "exp_samples": [{"labels": "{}", "value": 1}]})
        if "$host" in expr:
            tests.append({"expr": f'({selected}) and on (host) probe_success{{host="{OTHER}"}}', "eval_time": EVAL, "exp_samples": []})
    return [{"name": "panels", "interval": INTERVAL, "input_series": switch_series(SWITCH) + switch_series(OTHER),
             "promql_expr_test": tests}]


def main() -> None:
    folder = pathlib.Path(sys.argv[1])
    rules = prometheus_rules()
    (folder / "rules.yml").write_text(yaml.safe_dump(rules, sort_keys=False))
    content = {"rule_files": ["rules.yml"], "evaluation_interval": "1m", "tests": rule_tests(rules)}
    (folder / "rules-test.yml").write_text(yaml.safe_dump(content, sort_keys=False))
    panels = {"rule_files": [], "evaluation_interval": "1m", "tests": panel_tests()}
    (folder / "panels.yml").write_text(yaml.safe_dump(panels, sort_keys=False))
    print(f"{len(rules['groups'][0]['rules'])} rules, {len(scenarios())} scenarios")


if __name__ == "__main__":
    main()
