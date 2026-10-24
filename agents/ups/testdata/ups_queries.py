"""Queries for check-ups.sh, run in a probe container on the stack's internal
network (Loki at loki:3100), with the repository mounted at /repo.

    ups_queries.py logs <host>             prints the job="ups" lines as JSON
"""
import json
import sys
import time
import urllib.parse
import urllib.request

LOKI = "http://loki:3100/loki/api/v1/query_range"
TIMEOUT_SECONDS = 10
LOG_LIMIT = 100
LOG_LOOKBACK = "1h"


def get_json(url: str, params: dict) -> dict:
    with urllib.request.urlopen(f"{url}?{urllib.parse.urlencode(params)}", timeout=TIMEOUT_SECONDS) as response:
        return json.load(response)


def main() -> None:
    command = sys.argv[1]
    if command == "logs":
        query = '{job="ups", host="%s"}' % sys.argv[2]
        streams = get_json(LOKI, {"query": query, "since": LOG_LOOKBACK, "limit": LOG_LIMIT})["data"]["result"]
        print(json.dumps([[s["stream"], v[1]] for s in streams for v in s["values"]]))
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
