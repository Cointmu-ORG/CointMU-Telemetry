# Watchdog for the telemetry VM

The telemetry VM and its Proxmox host cannot report their own death. `watchdog.sh` runs every minute on
another machine and posts to Discord by itself:

| Condition | Channel |
|---|---|
| The Proxmox host and the VM are unreachable | #servers |
| The VM is unreachable, its host answers | #infra |
| The VM answers, GlitchTip or Grafana does not | #infra |

Three runs in a row (about 3 min) before a message, one message per condition, one when it ends. If this
machine loses its own network, nothing can be posted and nothing is recorded, so no false alarm follows.
If it dies together with the Proxmox host (shared power or switch), no message arrives. Grafana alerts in
turn when the watchdog's timestamp gets old.

**Install** on a host that has scope `infra`, on the telemetry VM (RUNBOOK.md, "Enroll a host"); the port
lists are tried in order:

```bash
scripts/enroll.sh change <host> --scopes <its scopes>,infra,watchdog \
  --set WATCHDOG_PVE_NAME=<name in messages> --set WATCHDOG_PVE=<PROXMOX_IP> --set "WATCHDOG_PVE_PORTS=8006 22" \
  --set WATCHDOG_VM=<TELEMETRY_IP> --set "WATCHDOG_VM_PORTS=443 <SSH_PORT>" --set WATCHDOG_VM_URL=https://<TELEMETRY_IP>
```

Then, on the host, its own two webhooks (new ones: never the VM's). Without a file the messages of that
channel go to the journal only:

```bash
for channel in servers infra; do
  read -rsp "own #$channel webhook URL: " URL; echo
  printf '%s' "$URL" | sudo install -m 600 -o cointmu-watchdog -g cointmu-watchdog /dev/stdin /etc/cointmu-watchdog/webhook-$channel
done; unset URL
```

The host must be in `nginx/local/admin-allow.conf`, or the Grafana check answers 403 and counts as unhealthy.
State is in `/var/lib/cointmu-watchdog`; `journalctl -u cointmu-watchdog` shows every failing run.

Test: `scopes/watchdog/testdata/test_watchdog.py`.
