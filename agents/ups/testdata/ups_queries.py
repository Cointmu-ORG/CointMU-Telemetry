"""Queries for check-ups.sh, run in a probe container on the stack's internal
network (Prometheus at prometheus:9090, Loki at loki:3100), with the
repository mounted at /repo.

    ups_queries.py value <promql>          prints the first result's value
    ups_queries.py rules [<offset s>]      prints "<uid> <state>" for every
                                           rule of RULE_GROUP, evaluated now
                                           (+ offset) the way Grafana does
                                           (A -> last -> C)
    ups_queries.py panels <host>           fails if a DASHBOARD panel query
                                           returns nothing for that host
    ups_queries.py logs <host> [<job>]     prints the lines of that job
                                           (default ups) as JSON

RULE_GROUP (default ups) and DASHBOARD (default ups.json) come from the
environment, so agents/chain/check-chain.sh uses this file as well.
"""
import json
import os
import sys
import time
import urllib.parse
import urllib.request

import yaml

PROMETHEUS = "http://prometheus:9090/api/v1/query"
LOKI = "http://loki:3100/loki/api/v1/query_range"
RULES = "/repo/grafana/provisioning/alerting/rules.yml"
RULE_GROUP = os.environ.get("RULE_GROUP", "ups")
DASHBOARD = os.environ.get("DASHBOARD", "/repo/grafana/dashboards/ups.json")
TIMEOUT_SECONDS = 10
LOG_LIMIT = 100
LOG_LOOKBACK = "1h"


def get_json(url: str, params: dict) -> dict:
    with urllib.request.urlopen(f"{url}?{urllib.parse.urlencode(params)}", timeout=TIMEOUT_SECONDS) as response:
        return json.load(response)


def prometheus(expr: str, at: float) -> list:
    body = get_json(PROMETHEUS, {"query": expr, "time": f"{at:.3f}"})
    if body["status"] != "success":
        raise SystemExit(f"query failed: {expr}: {body}")
    return body["data"]["result"]


def rule_state(rule: dict, at: float) -> str:
    query = next(d for d in rule["data"] if d["refId"] == "A")["model"]["expr"]
    condition = next(d for d in rule["data"] if d["refId"] == "C")["model"]["conditions"][0]["evaluator"]
    series = prometheus(query, at)
    if not series:
        return f"NoData->{rule['noDataState']}"
    limit = condition["params"][0]
    values = [float(s["value"][1]) for s in series]
    firing = any(v > limit if condition["type"] == "gt" else v < limit for v in values)
    return ("Alerting" if firing else "Normal") + f"({','.join(f'{v:g}' for v in values)})"


def group_rules() -> list:
    groups = yaml.safe_load(open(RULES))["groups"]
    return next(g for g in groups if g["name"] == RULE_GROUP)["rules"]


def panel_targets() -> list:
    panels = json.load(open(DASHBOARD))["panels"]
    return [(p["title"], p["datasource"]["type"], t["expr"]) for p in panels for t in p["targets"]]


def check_panels(host: str) -> None:
    empty = []
    for title, kind, expr in panel_targets():
        expr = expr.replace("$host", host)
        if kind == "prometheus":
            found = prometheus(expr, time.time())
        else:
            found = get_json(LOKI, {"query": expr, "since": LOG_LOOKBACK, "limit": LOG_LIMIT})["data"]["result"]
        print(f"{'ok  ' if found else 'EMPTY'} {title}: {expr}")
        if not found:
            empty.append(title)
    if empty:
        raise SystemExit(f"panels without data: {empty}")


def main() -> None:
    command = sys.argv[1]
    if command == "value":
        result = prometheus(sys.argv[2], time.time())
        print(result[0]["value"][1] if result else "")
    elif command == "rules":
        at = time.time() + float(sys.argv[2] if len(sys.argv) > 2 else 0)
        for rule in group_rules():
            print(rule["uid"], rule_state(rule, at))
    elif command == "panels":
        check_panels(sys.argv[2])
    elif command == "logs":
        job = sys.argv[3] if len(sys.argv) > 3 else "ups"
        query = '{job="%s", host="%s"}' % (job, sys.argv[2])
        streams = get_json(LOKI, {"query": query, "since": LOG_LOOKBACK, "limit": LOG_LIMIT})["data"]["result"]
        print(json.dumps([[s["stream"], v[1]] for s in streams for v in s["values"]]))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
