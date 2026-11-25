# Chain metrics on the geth node servers

Each geth node server reads the chain state from its own geth RPC (loopback only) and pushes it to
Prometheus through the same Alloy agent that ships its geth logs:

```
geth HTTP RPC ─127.0.0.1─▶ chain-metrics.py (timer, 15 s) → chain.prom ─▶ Alloy ──HTTPS + login──▶ nginx /prometheus/api/v1/write ──▶ Prometheus ──▶ Grafana "Chain"
  (each geth process         textfile collector                (scopes/cointmu/alloy/cointmu.alloy)                                                           + alerts → #block-update
   on the host)
```

| Host | NODES (`/etc/cointmu-chain/cointmu-chain.conf`) | Logins (log + metrics) |
|---|---|---|
| server101 | `bootnode=http://127.0.0.1:8545 miner=http://127.0.0.1:8546` | `server101-1` |
| CT 106 | `miner=http://127.0.0.1:8545` | `server106-1` |

The miner on server101 had no HTTP RPC (IPC only, readable by its owner alone). It needs
`--http --http.addr 127.0.0.1 --http.port 8546 --http.api eth,net,web3 --http.vhosts localhost,127.0.0.1`
in `~/cointmu-network/start-miner.sh` ("Install", step 1).

| File (this folder) | Goes to, on the node | Owner, mode |
|---|---|---|
| `chain-metrics.py` | `/usr/local/lib/cointmu-chain/chain-metrics.py` | root:root 0755 |
| `cointmu-chain.conf.example` | `/etc/cointmu-chain/cointmu-chain.conf`, filled in | root:root 0644 (directory 0755; no secrets) |
| `cointmu-chain-metrics.service`, `.timer` | `/etc/systemd/system/` | root:root 0644 |
| `cointmu-chain.tmpfiles.conf` | `/etc/tmpfiles.d/cointmu-chain.conf` | root:root 0644 |
| `../alloy/cointmu.alloy`, `agent/push-logs.alloy`, `agent/push-metrics.alloy` | `/etc/alloy/conf.d/` | root:root 0644 |
| metrics password (`scripts/agent-cred.sh … metrics`) | `/etc/alloy/metrics-password` | root:alloy 0640 |

`/var/lib/cointmu-chain` is `cointmu-chain:alloy 2750` and `chain.prom` `cointmu-chain:alloy 640`:
Alloy reads the file through the group, while `cointmu-chain` stays out of group `alloy` (which can
read `/etc/alloy/*-password`). The RPC needs no login: anything on the host can already reach it.

## What it sends

Only the textfile collector; none of the host's other metrics leave it. Labels: `job="chain"`,
`instance="chain"`, `host` (`AGENT_HOST`) and `role` (from NODES). No addresses, node IDs or
etherbase: every miner mines to the same etherbase, so nodes are told apart by host and role.

| Metric | Meaning |
|---|---|
| `cointmu_chain_rpc_up` | 1 if the RPC answered. 0: only this and the timestamp for that role |
| `cointmu_chain_head_block` | head block number |
| `cointmu_chain_head_timestamp_seconds` | head block time; last-block age is `time() - x` |
| `cointmu_chain_head_difficulty` | head difficulty |
| `cointmu_chain_block_time_seconds` | average block time over the last 32 blocks (about 7.5 min) |
| `cointmu_chain_hashrate_estimate` | difficulty / average block time, H/s, for the whole network |
| `cointmu_chain_peers` | `net_peerCount` |
| `cointmu_chain_syncing` | 1 while `eth_syncing` reports a sync |
| `cointmu_chain_scrape_timestamp_seconds` | when the file was written (rule "Chain metrics stale") |

There is no per-miner hashrate: geth 1.10.26 answers `eth_hashrate` with 0 on these miners.

## Install

Copy this folder and `scopes/cointmu/alloy/` to the node. Alloy is already installed there for the geth
logs (scopes/cointmu/alloy/README.md), so the `alloy` group exists. Commands with `sudo` go in your own
terminal; on CT 106 that is the `server106` admin login, not `cointmu`.

### 1. server101 only: HTTP RPC for the miner

One soft restart of the 101 miner; the CT 106 miner keeps the chain going meanwhile. As the user
that runs PM2, in `~/cointmu-network`, with PM2 on the PATH:

```bash
cp -p start-miner.sh start-miner.sh.bak-$(date +%Y%m%d)
nano start-miner.sh   # add: --http --http.addr 127.0.0.1 --http.port 8546 --http.api eth,net,web3 --http.vhosts 'localhost,127.0.0.1' \
pm2 restart cointmu-miner           # SIGINT, up to 60 s for geth to flush state
pm2 logs cointmu-miner --lines 40 --nostream   # "Blockchain stopped", then the new start, "HTTP server started ... 127.0.0.1:8546"
curl -s -H 'Content-Type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}' http://127.0.0.1:8546
```

### 2. Enroll the host

`scripts/enroll.sh add ... --scopes cointmu --set NODES=...` on the telemetry VM (RUNBOOK.md, "Enroll a
host"). `install-agent.sh` installs the collector, its user, unit and timer, writes
`/etc/cointmu-chain/cointmu-chain.conf` if it does not exist yet, and starts them. Check:

```bash
systemctl status cointmu-chain-metrics.service --no-pager   # exited 0/SUCCESS
sudo -u alloy cat /var/lib/cointmu-chain/chain.prom   # rpc_up 1 and a head block for every role
systemd-analyze security cointmu-chain-metrics.service   # review; expect a low exposure score
```

**CT 106 (unprivileged LXC, nesting on).** If the first start fails with a namespace or
`Permission denied` error from systemd (not from the script), drop only the option it names, in a
drop-in (`sudo systemctl edit cointmu-chain-metrics.service`, e.g. `PrivateDevices=no`), and write
down which one in RUNBOOK.md. The repository unit stays as it is.

## Changing it

`scopes/cointmu/chain/check-chain.sh`: a throwaway copy of the stack plus a fake node, with stub RPCs,
running `chain-metrics.py`. It checks:
- the owner/mode table, the refusal messages and `alloy-preflight.sh`
- `promtool check metrics`, every dashboard panel, and each chain rule per scenario (behind, no
  peers, RPC down, stalled, Alloy stopped, timer stopped)
- that Alloy without the metrics password keeps shipping logs and names the missing file

About five minutes; it never touches a running deployment. It runs in CI (job `chain`).
