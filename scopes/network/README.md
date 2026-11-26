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

### Cisco Small Business (SG300), auth `cisco_v3` or `cisco_v3_authnopriv`

Firmware 1.1.x (`show version`) has SNMPv3 users without privacy: `snmp-server user ... v3 auth sha
<password>` and nothing after it. Use `cisco_v3_authnopriv` there: the login is SHA-protected, the
read-only counters are not encrypted. Firmware that offers `priv` takes `cisco_v3` (AES) and
`priv <SNMP_CISCO_PRIV_PASSWORD>` at the end of the user line.

CLI (SSH needs `-o KexAlgorithms=+diffie-hellman-group-exchange-sha1 -o HostKeyAlgorithms=+ssh-rsa`
on 1.1.x; the switch asks for User Name and Password after connecting):

```
configure
snmp-server engineID local default
snmp-server group cointmu-ro v3 auth read Default
snmp-server user <SNMP_CISCO_USER> cointmu-ro v3 auth sha <SNMP_CISCO_AUTH_PASSWORD>
snmp-server server
end
copy running-config startup-config
```

`engineID local default` asks twice (unique engine ID, SNMPv3 database erased): answer Y. Use
`group ... v3 priv` instead of `auth` with `cisco_v3`. These switches have no v3 source-address filter
in the user line; with no community defined, v1/v2c stay closed.
