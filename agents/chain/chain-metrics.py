#!/usr/bin/python3 -I
"""Writes the chain state of this host's geth nodes for Alloy's textfile
collector as /var/lib/cointmu-chain/chain.prom (Prometheus text format). Run
every 15 s by cointmu-chain-metrics.timer as the cointmu-chain user
(agents/chain/README.md).

    chain-metrics.py

Reads NODES from /etc/cointmu-chain/cointmu-chain.conf, "<role>=<url> ...",
each url a geth HTTP RPC on loopback (no login needed). Per node:
cointmu_chain_rpc_up is 0 when the RPC does not answer; then only that and
the timestamp are written for its role. cointmu_chain_scrape_timestamp_seconds
is written on every run, so a stopped timer shows as old content in fresh
scrapes (Grafana rule "Chain metrics stale").

The only label is role; Alloy adds host. No addresses: every miner shares one
etherbase, so nodes are told apart by host and role.

The directory must be group alloy, mode 2750 (setgid), from
cointmu-chain.tmpfiles.conf: files written here then belong to group alloy,
which the Alloy agent reads with, while this user stays out of that group.
"""
import grp
import http.client
import json
import os
import re
import stat
import sys
import time
import urllib.request

CONFIG_FILE = "/etc/cointmu-chain/cointmu-chain.conf"
OUT_DIR = "/var/lib/cointmu-chain"
OUT_FILE = f"{OUT_DIR}/chain.prom"
READER_GROUP = "alloy"
DIR_MODE = 0o2750
FILE_UMASK = 0o027
# Two requests per node; the unit's TimeoutStartSec allows two nodes.
RPC_TIMEOUT_SECONDS = 3
# Average block time over this many blocks (32 x ~14 s, about 7.5 min).
BLOCK_TIME_WINDOW = 32
ROLE_PATTERN = re.compile(r"^[a-z]+$")
LOOPBACK_URL_PATTERN = re.compile(r"^http://(127\.0\.0\.1|localhost|\[::1\]):[0-9]{1,5}/?$")
HEX = 16

HELP = {
    "cointmu_chain_rpc_up": "1 if the node's RPC answered",
    "cointmu_chain_head_block": "Head block number",
    "cointmu_chain_head_timestamp_seconds": "Head block timestamp",
    "cointmu_chain_head_difficulty": "Head block difficulty",
    "cointmu_chain_block_time_seconds": f"Average block time over the last {BLOCK_TIME_WINDOW} blocks",
    "cointmu_chain_hashrate_estimate": "Network hashrate estimate in H/s: difficulty / average block time",
    "cointmu_chain_peers": "Connected peers (net_peerCount)",
    "cointmu_chain_syncing": "1 while eth_syncing reports a sync",
    "cointmu_chain_scrape_timestamp_seconds": "When this file was written",
}


class RpcError(Exception):
    """The node answered, but not with a usable result."""


def die(message: str) -> None:
    print(f"chain-metrics: {message}", file=sys.stderr)
    sys.exit(1)


def check_out_dir() -> None:
    try:
        grp.getgrnam(READER_GROUP)
    except KeyError:
        die(f"no group '{READER_GROUP}': install Alloy first, then systemd-tmpfiles --create (README.md)")
    try:
        info = os.stat(OUT_DIR)
    except FileNotFoundError:
        die(f"missing {OUT_DIR}: systemd-tmpfiles --create /etc/tmpfiles.d/cointmu-chain.conf")
    group = grp.getgrgid(info.st_gid).gr_name
    mode = stat.S_IMODE(info.st_mode)
    if group != READER_GROUP or mode != DIR_MODE:
        die(f"{OUT_DIR} is group {group} mode {mode:o}, expected {READER_GROUP} {DIR_MODE:o}"
            " (cointmu-chain.tmpfiles.conf)")


def read_nodes() -> list[tuple[str, str]]:
    """Returns [(role, url)] from NODES in the config file; exits on anything else."""
    try:
        with open(CONFIG_FILE, encoding="utf-8") as config:
            lines = config.read().splitlines()
    except OSError as error:
        die(f"cannot read {CONFIG_FILE}: {error.strerror}")
    value = next((line[len("NODES="):] for line in lines if line.startswith("NODES=")), "")
    nodes = []
    for entry in value.strip().strip('"').split():
        role, _, url = entry.partition("=")
        if not ROLE_PATTERN.match(role) or not LOOPBACK_URL_PATTERN.match(url):
            die(f"NODES entry '{entry}' in {CONFIG_FILE} is not <role>=http://127.0.0.1:<port>")
        if role in (known for known, _ in nodes):
            die(f"role '{role}' appears twice in NODES ({CONFIG_FILE})")
        nodes.append((role, url))
    if not nodes:
        die(f"no NODES in {CONFIG_FILE}")
    return nodes


def rpc_batch(url: str, calls: list[tuple[str, list]]) -> list:
    """Sends one JSON-RPC batch; returns the results in call order."""
    body = json.dumps([{"jsonrpc": "2.0", "id": i, "method": m, "params": p} for i, (m, p) in enumerate(calls)])
    request = urllib.request.Request(url, body.encode(), {"Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=RPC_TIMEOUT_SECONDS) as response:
        replies = {reply["id"]: reply for reply in json.load(response)}
    if any("error" in reply or reply.get("result") is None for reply in replies.values()):
        raise RpcError(f"error in reply: {[r.get('error') for r in replies.values()]}")
    return [replies[i]["result"] for i in range(len(calls))]


def node_metrics(url: str) -> dict[str, float]:
    """Returns the metric values of one node; raises on any RPC failure."""
    head, peers, syncing = rpc_batch(url, [
        ("eth_getBlockByNumber", ["latest", False]),
        ("net_peerCount", []),
        ("eth_syncing", []),
    ])
    number, timestamp, difficulty = (int(head[key], HEX) for key in ("number", "timestamp", "difficulty"))
    values = {
        "cointmu_chain_head_block": number,
        "cointmu_chain_head_timestamp_seconds": timestamp,
        "cointmu_chain_head_difficulty": difficulty,
        "cointmu_chain_peers": int(peers, HEX),
        "cointmu_chain_syncing": 0 if syncing is False else 1,
    }
    window = min(BLOCK_TIME_WINDOW, number)
    if window > 0:
        (old,) = rpc_batch(url, [("eth_getBlockByNumber", [hex(number - window), False])])
        block_time = (timestamp - int(old["timestamp"], HEX)) / window
        if block_time > 0:
            values["cointmu_chain_block_time_seconds"] = block_time
            values["cointmu_chain_hashrate_estimate"] = difficulty / block_time
    return values


def collect(nodes: list[tuple[str, str]]) -> dict[str, list[tuple[str, float]]]:
    """Returns {metric: [(role, value)]} for every node."""
    samples: dict[str, list[tuple[str, float]]] = {name: [] for name in HELP}
    for role, url in nodes:
        try:
            values = {"cointmu_chain_rpc_up": 1, **node_metrics(url)}
        except (OSError, ValueError, KeyError, TypeError, RpcError, http.client.HTTPException) as error:
            print(f"chain-metrics: {role} at {url}: {error}", file=sys.stderr)
            values = {"cointmu_chain_rpc_up": 0}
        values["cointmu_chain_scrape_timestamp_seconds"] = int(time.time())
        for name, value in values.items():
            samples[name].append((role, value))
    return samples


def render(samples: dict[str, list[tuple[str, float]]]) -> str:
    lines = []
    for name, series in samples.items():
        if not series:
            continue
        lines += [f"# HELP {name} {HELP[name]}", f"# TYPE {name} gauge"]
        lines += [f'{name}{{role="{role}"}} {value}' for role, value in series]
    return "\n".join(lines) + "\n"


def main() -> None:
    check_out_dir()
    nodes = read_nodes()
    text = render(collect(nodes))
    os.umask(FILE_UMASK)
    # The collector reads *.prom only, so it never sees a half-written file.
    with open(f"{OUT_FILE}.tmp", "w", encoding="utf-8") as out:
        out.write(text)
    os.replace(f"{OUT_FILE}.tmp", OUT_FILE)


if __name__ == "__main__":
    main()
