# Scope network (switches)

Switches cannot run Alloy, so nothing is installed on them. The VM watches them itself:

- **Probes** (blackbox exporter, as for enrolled hosts): ping and the SSH port, every 30 s.
- **SNMPv3** (`snmp` container, prom/snmp-exporter): uptime and, per port, status, enabled or not,
  speed, traffic, errors and discards, every 60 s. Modules `if_mib` and `system` from the exporter's
  built-in `snmp.yml`; the logins are in `snmp/auths.yml`, their values in `.env`.

Grafana folder "Network", dashboard "Network" (`/d/network`). Alerts go to #servers (`policies.yml`,
label `scope=network`):

| Rule | Fires when |
|---|---|
| Switch down | neither ping nor SSH answer for 3 min |
| Switch SNMP unreadable | it answers ping or SSH, but no SNMP scrape succeeded for 10 min |
| Switch port down | an enabled port is down that was up without a break from 48 to 24 h ago (servers, uplinks); desk ports that come and go, and ports switched off on purpose, never fire |
| Switch port errors | in + out errors above 1 per second over 15 min |

Only SNMPv3 (authPriv, read-only): the exporter reads secrets from the environment for usernames and
passwords only, so a v1/v2c community string would have to sit in git.

## Add a switch

1. On the switch, a read-only SNMPv3 user that only this VM (10.64.24.104) may use. Passwords at
   least 8 characters, not reused anywhere else.
2. The login in `.env` (`SNMP_MIKROTIK_*` or `SNMP_CISCO_*`), then `docker compose up -d snmp`.
3. Check it from the VM before adding it (prints `sysName`, no secrets):
   ```bash
   docker compose exec prometheus wget -qO- \
     'http://snmp:9116/snmp?target=<ip>&auth=<auth>&module=system' | grep '^sysName'
   ```
4. `scripts/network.sh add <name> <ip> --auth <auth>`. Name = the ssh alias scheme. Probes and SNMP
   start within a minute; `scripts/network.sh list` shows the registry.

Remove: `scripts/network.sh remove <name>`, then the SNMP user on the switch.

### MikroTik (RouterOS 7), auth `mikrotik_v3`

```
/snmp community add name=<SNMP_MIKROTIK_USER> security=private read-access=yes write-access=no \
    authentication-protocol=SHA1 authentication-password=<SNMP_MIKROTIK_AUTH_PASSWORD> \
    encryption-protocol=AES encryption-password=<SNMP_MIKROTIK_PRIV_PASSWORD> addresses=10.64.24.104/32
/snmp community set [find default=yes] disabled=yes
/snmp set enabled=yes
```

The second line matters: the default community `public` answers everyone once SNMP is on. SNMP is a
management service of the switch, like SSH: it changes nothing in the bridge.

### Cisco Small Business (SG300), auth `cisco_v3` or `cisco_v3_des`

In the web UI:

1. Security > TCP/UDP Services: SNMP Service on.
2. SNMP > Views: a view `cointmu-ro` that includes `iso` (1).
3. SNMP > Groups: group `cointmu-ro`, SNMPv3, Authentication and Privacy, Read view `cointmu-ro`, no
   write or notify view.
4. SNMP > Users: user `<SNMP_CISCO_USER>` in group `cointmu-ro`, authentication SHA, privacy with
   `<SNMP_CISCO_PRIV_PASSWORD>`.
5. Security > Mgmt Access Method: limit SNMP to 10.64.24.104.

If the firmware offers DES only for privacy (older 1.x releases), add the switch with
`--auth cisco_v3_des`; otherwise `cisco_v3` (AES).
