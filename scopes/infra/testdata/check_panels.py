"""Writes a promtool test file that fails if a query of servers.json returns
nothing for a host with every kind of hardware, or anything but that host's
data when the host variable selects it.

    check_panels.py <output folder>   then: promtool test rules <folder>/panels.yml
"""
import json
import pathlib
import sys

import series
import yaml

DASHBOARD = pathlib.Path(__file__).parent.parent / "dashboards/servers.json"
HOST, OTHER = "pve1", "vm1"
EVAL_TIME = "1600m"


def queries() -> list[str]:
    panels = json.loads(DASHBOARD.read_text())["panels"]
    found = [target["expr"] for panel in panels for target in panel.get("targets", [])]
    return [expr.replace("$host", HOST).replace("$type", "pve") for expr in found]


def main() -> None:
    folder = pathlib.Path(sys.argv[1])
    tests = []
    for expr in queries():
        tests.append({"expr": f"count({expr}) > bool 0", "eval_time": EVAL_TIME, "exp_samples": [{"labels": "{}", "value": 1}]})
        # Nothing of the other host, which is of another type.
        tests.append({"expr": f'({expr}) and on (host) infra_host_info{{host="{OTHER}"}}', "eval_time": EVAL_TIME, "exp_samples": []})
    content = {"rule_files": [], "evaluation_interval": "1m", "tests": [{
        "interval": series.INTERVAL,
        "input_series": series.full_host(HOST, "R1") + series.base_host(OTHER, "linux", "none"),
        "promql_expr_test": tests}]}
    (folder / "panels.yml").write_text(yaml.safe_dump(content, sort_keys=False))
    print(f"{len(queries())} panel queries")


if __name__ == "__main__":
    main()
