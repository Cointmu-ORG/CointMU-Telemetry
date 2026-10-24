"""Queries for check-ups.sh, run in a probe container on the stack's internal
network (Prometheus at prometheus:9090, Loki at loki:3100), with the
repository mounted at /repo.

    ups_queries.py value <promql>          prints the first result's value
    ups_queries.py logs <host>             prints the job="ups" lines as JSON
"""
import json
import sys
import time
import urllib.parse
import urllib.request

PROMETHEUS = "http://prometheus:9090/api/v1/query"
LOKI = "http://loki:3100/loki/api/v1/query_range"
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


def main() -> None:
    command = sys.argv[1]
    if command == "value":
        result = prometheus(sys.argv[2], time.time())
        print(result[0]["value"][1] if result else "")
    elif command == "logs":
        query = '{job="ups", host="%s"}' % sys.argv[2]
        streams = get_json(LOKI, {"query": query, "since": LOG_LOOKBACK, "limit": LOG_LIMIT})["data"]["result"]
        print(json.dumps([[s["stream"], v[1]] for s in streams for v in s["values"]]))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
