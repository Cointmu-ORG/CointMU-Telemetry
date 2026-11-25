"""Compares a running Grafana with the provisioning files of a checkout, for
grafana/check-upgrade.sh. Runs in a probe container on the stack's internal
network, with the checkout mounted at /checkout.

    check_provisioned.py state             prints what Grafana serves, as JSON
    check_provisioned.py verify <before>   fails unless Grafana serves exactly
                                           the checkout's dashboards, rules and
                                           contact points, each once and in its
                                           scope's folder, and every UID of
                                           <before> (a "state" file) that the
                                           checkout still has kept its UID
    check_provisioned.py title <rule uid>  prints the title Grafana serves

Login: GRAFANA_AUTH, base64 of user:password (basic auth is on in the test only).
"""
import json
import os
import pathlib
import sys
import urllib.request

import yaml

API = "http://grafana:3000/grafana/api"
CHECKOUT = pathlib.Path("/checkout")
PROVIDERS = CHECKOUT / "grafana/provisioning/dashboards/scopes.yml"
TIMEOUT_SECONDS = 15


def get(path: str):
    request = urllib.request.Request(API + path, headers={"Authorization": f"Basic {os.environ['GRAFANA_AUTH']}"})
    with urllib.request.urlopen(request, timeout=TIMEOUT_SECONDS) as response:
        return json.load(response)


def served() -> dict:
    folders = {f["uid"]: f["title"] for f in get("/folders")}
    return {
        "folders": sorted(folders.values()),
        "dashboards": {d["uid"]: d.get("folderTitle", "") for d in get("/search?type=dash-db&limit=500")},
        "rules": {r["uid"]: [folders.get(r["folderUID"], "?"), r["ruleGroup"], r["title"]]
                  for r in get("/v1/provisioning/alert-rules")},
        "contact_points": sorted(c["uid"] for c in get("/v1/provisioning/contact-points") if c["uid"]),
    }


def alerting_files(kind: str) -> list:
    return [yaml.safe_load(path.read_text()) for path in sorted(CHECKOUT.glob(f"scopes/*/alerting/{kind}.yml"))]


def expected() -> dict:
    dashboards = {}
    for provider in yaml.safe_load(PROVIDERS.read_text())["providers"]:
        for path in (CHECKOUT / "scopes" / provider["name"] / "dashboards").glob("*.json"):
            dashboards[json.loads(path.read_text())["uid"]] = provider["folder"]
    groups = [g for content in alerting_files("rules") for g in content["groups"]]
    points = [p for content in alerting_files("contact-points") for p in content["contactPoints"]]
    return {
        "dashboards": dashboards,
        "rules": {r["uid"]: [g["folder"], g["name"], r["title"]] for g in groups for r in g["rules"]},
        "contact_points": sorted(r["uid"] for p in points for r in p["receivers"]),
    }


def verify(before: dict) -> list:
    now, want = served(), expected()
    errors = [f"{kind}: Grafana serves {now[kind]}, the files say {want[kind]}"
              for kind in ("dashboards", "rules") if now[kind] != want[kind]]
    missing = set(want["contact_points"]) - set(now["contact_points"])
    if missing:
        errors.append(f"contact points missing: {sorted(missing)}")
    if len(now["folders"]) != len(set(now["folders"])):
        errors.append(f"duplicate folder titles: {now['folders']}")
    for kind in ("dashboards", "rules"):
        lost = (set(before[kind]) & set(want[kind])) - set(now[kind])
        if lost:
            errors.append(f"{kind} lost in the upgrade: {sorted(lost)}")
    return errors


def main() -> None:
    command = sys.argv[1]
    if command == "state":
        print(json.dumps(served()))
    elif command == "verify":
        errors = verify(json.loads(pathlib.Path(sys.argv[2]).read_text()))
        print(json.dumps(served(), indent=1))
        if errors:
            raise SystemExit("\n".join(f"FAIL: {e}" for e in errors))
    elif command == "title":
        print(get(f"/v1/provisioning/alert-rules/{sys.argv[2]}")["title"])
    else:
        raise SystemExit(__doc__)


if __name__ == "__main__":
    main()
