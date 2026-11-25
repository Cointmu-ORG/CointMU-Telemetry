#!/usr/bin/env bash
# Enrolls throwaway hosts end to end: enroll.sh on a throwaway VM stack, the
# printed commands run as printed (stub ssh and pct), install-agent.sh on real
# systemd in containers on a network without internet. Checks:
# - Debian 12/13 and Ubuntu 22.04/24.04; pve (root), linux (sudo user) and lxc
#   (pct push/exec) transport; data arrives and enroll.sh verify passes
# - dry run changes nothing; a second run changes nothing; the bundle is gone
# - truncated and tampered bundles, wrong type and arch, armhf, missing tools and
#   settings are refused before anything changes
# - a refused push (wrong password) puts the previous config back
# - adopt keeps the host's password and settings; uninstall
# Tests committed files only; downloads the pinned Alloy package once.
#
#   agent/check-install.sh
# shellcheck disable=SC2016 # commands for the test hosts are quoted on purpose
set -euo pipefail

cd "$(dirname "$0")/.."
readonly PROJECT="cointmu-install-check-$$"
readonly GETH_LOG=/var/log/geth/cointmu-miner-error.log
readonly SETTINGS=(--set "GETH_LOG_FILES=$GETH_LOG" --set NODES=miner=http://127.0.0.1:8545)
# Pinned by hand; Dependabot does not see them.
declare -A BASES=(
  [debian13]=debian:13.6-slim@sha256:d7e12182ce18b85b93007c1dedf31f2d29e01ccf3182cc4017c709b6259bc132
  [debian12]=debian:12-slim@sha256:e67eeead736ff7bbe258ef088bff683635c561b1fcfefad0806c1df4ab49ce0e
  [ubuntu2404]=ubuntu:24.04@sha256:562111b88caa79c71391c0c4d3c2114a7d5c35915c20561fd893cb1e07929e6b
  [ubuntu2204]=ubuntu:22.04@sha256:b000e69a50ff940390233025e7a337fb8469b509e2334fa4d018ac30f3e18cdb
)
hosts=()

# shellcheck source=testing/stack.sh
. testing/stack.sh
cleanup() {
  local host
  for host in "${hosts[@]}"; do docker rm -f "$PROJECT-$host" >/dev/null 2>&1 || true; done
  stack_cleanup
}
trap cleanup EXIT

on() { local host="$1"; shift; docker exec -i "$PROJECT-$host" "$@"; }
host_ip() { docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' "$PROJECT-$1"; }
systemd_up() { on "$1" systemctl list-units >/dev/null 2>&1; }

# $1 host name, $2 base. On the stack's internal network: the proxy is there,
# the internet is not. "/data" keeps bundles of refused runs.
start_host() {
  docker build -q -t "cointmu-host-$2:local" --build-arg BASE="${BASES[$2]}" agent/testdata >/dev/null
  hosts+=("$1")
  docker run -d --name "$PROJECT-$1" --hostname "$1" --network "${PROJECT}_logs" --privileged --cgroupns=private \
    --tmpfs /run --tmpfs /run/lock "cointmu-host-$2:local" >/dev/null
  wait_for "$1 ($2) runs systemd" systemd_up "$1"
  on "$1" bash -c "install -d -m 755 /var/log/geth && : > $GETH_LOG && chmod 644 $GETH_LOG"
}

# ssh as the printed commands call it: server104 is the VM checkout, anything
# else a host container ("root@pve..." and "netadmin@..." as that user).
write_stubs() {
  mkdir -p "$work/bin"
  cat > "$work/bin/ssh" <<STUB
#!/usr/bin/env bash
[[ "\$1" == -t ]] && shift
target="\$1"; shift
[[ "\$target" == server104 ]] && exec bash -c "\$*"
user="\${target%@*}"; host="\${target#*@}"; home=/root
[[ "\$user" == root ]] || home="/home/\$user"
exec docker exec -i -u "\$user" -e "HOME=\$home" -w "\$home" "$PROJECT-\$host" bash -c "\$*"
STUB
  chmod +x "$work/bin/ssh"
}

# $1 host: the printed commands, as the operator would paste them.
run_printed() { PATH="$work/bin:$PATH" bash -e -c "$(grep -v '^#' <<<"$2")"; }

geth_feed() {
  on "$1" bash -c "for i in 1 2 3; do echo 'INFO [10-27|13:00:00.000] Imported new chain segment number='\$i >> $GETH_LOG; done"
}

feed_and_run() { geth_feed "$1"; run_printed "$1" "$2"; }
feed_and_verify() { geth_feed "$1"; enroll verify "$1"; }

# Transfer, install, then verify once lines are written after the install.
# $1 host, $2 output of enroll.sh.
enroll_host() {
  local host="$1" steps verify
  steps=$(grep -v '^#' <<<"$2" | head -n -1)
  verify=$(grep -v '^#' <<<"$2" | tail -1)
  if run_printed "$host" "$steps" >"$work/$host.log" 2>&1; then pass "$host: printed commands"; else
    fail "$host: printed commands"; tail -40 "$work/$host.log" >&2; return 1; fi
  wait_for "$host: enroll.sh verify" feed_and_run "$host" "$verify"
}

# $1 host, $2.. options of enroll.sh add.
add_host() { local host="$1"; shift; enroll add "$host" "$(host_ip "$host")" --scopes cointmu "${SETTINGS[@]}" "$@"; }

# $1 description, $2 expected text, $3 host, rest: command on the host that must fail.
refuse_on() {
  local what="$1" expected="$2" host="$3" output; shift 3
  if output=$(on "$host" "$@" 2>&1); then fail "$what: did not fail"
  elif [[ "$output" == *"$expected"* ]]; then pass "$what"
  else fail "$what: $output"; fi
}

host_state() { on "$1" bash -c 'dpkg-query -W 2>/dev/null; find /etc /usr/local /var/lib/cointmu* -type f -printf "%p %s %m %T@\n" 2>/dev/null | sort' | grep -v -e /etc/machine-id -e /etc/resolv.conf; }

# $1 host: bundle and installer put there by hand, for the refusal tests.
put_bundle() {
  enroll bundle "$1" | on "$1" bash -c 'umask 077; cat > /root/b.tar'
  on "$1" bash -c 'cd /root && tar -xf b.tar ./install-agent.sh'
}

check_refusals() {
  local host=deb13 before
  add_host "$host" --type linux --ssh "netadmin@$host" >/dev/null
  put_bundle "$host"
  before=$(host_state "$host")
  refuse_on "not root" "run as root" "$host" runuser -u netadmin -- bash -c 'cat /root/install-agent.sh 2>/dev/null; bash -s -- /root/b.tar' < agent/install-agent.sh
  refuse_on "truncated bundle" "truncated?" "$host" bash -c 'umask 077; head -c 1000000 /root/b.tar > /root/t.tar; bash /root/install-agent.sh /root/t.tar'
  refuse_on "tampered bundle" "does not match its manifest" "$host" bash -c 'umask 077; rm -rf /root/x && mkdir /root/x && tar -xf /root/b.tar -C /root/x && echo x >> /root/x/alloy.env && tar -C /root/x -cf /root/t.tar . && bash /root/install-agent.sh /root/t.tar'
  refuse_on "file outside the manifest" "does not list" "$host" bash -c 'umask 077; rm -rf /root/x && mkdir /root/x && tar -xf /root/b.tar -C /root/x && echo x > /root/x/extra && tar -C /root/x -cf /root/t.tar . && bash /root/install-agent.sh /root/t.tar'
  refuse_on "bundle readable by others" "expected 600" "$host" bash -c 'cp /root/b.tar /root/t.tar && chmod 644 /root/t.tar && bash /root/install-agent.sh /root/t.tar'
  refuse_on "wrong host type" "this host is a 'pve'" "$host" bash -c 'mkdir -p /tmp/s && printf "#!/bin/sh\n" > /tmp/s/pveversion && chmod +x /tmp/s/pveversion && PATH=/tmp/s:$PATH bash /root/install-agent.sh /root/b.tar; s=$?; rm -r /tmp/s; exit $s'
  refuse_on "armhf" "no 32-bit ARM build" "$host" bash -c 'mkdir -p /tmp/s && printf "#!/bin/sh\necho armhf\n" > /tmp/s/dpkg && chmod +x /tmp/s/dpkg && PATH=/tmp/s:$PATH bash /root/install-agent.sh /root/b.tar; s=$?; rm -r /tmp/s; exit $s'
  refuse_on "other architecture" "the bundle is for amd64" "$host" bash -c 'mkdir -p /tmp/s && printf "#!/bin/sh\necho arm64\n" > /tmp/s/dpkg && chmod +x /tmp/s/dpkg && PATH=/tmp/s:$PATH bash /root/install-agent.sh /root/b.tar; s=$?; rm -r /tmp/s; exit $s'
  refuse_on "missing tool" "python3 is missing" "$host" bash -c 'mv /usr/bin/python3 /usr/bin/python3.off; bash /root/install-agent.sh /root/b.tar; s=$?; mv /usr/bin/python3.off /usr/bin/python3; exit $s'
  check "dry run" on "$host" bash /root/install-agent.sh /root/b.tar --dry-run
  on "$host" bash -c 'rm -rf /root/x /root/t.tar'
  if diff <(echo "$before" | grep -v /root) <(host_state "$host") >"$work/diff"; then pass "refusals and dry run change nothing"; else fail "changed: $(head -5 "$work/diff")"; fi
  on "$host" chmod 000 "$GETH_LOG"
  refuse_on "log file alloy cannot read" "cannot read any file" "$host" bash /root/install-agent.sh /root/b.tar
  on "$host" chmod 644 "$GETH_LOG"
  enroll remove "$host" >/dev/null 2>&1
  on "$host" bash -c 'bash /root/install-agent.sh --uninstall >/dev/null 2>&1; rm -f /root/b.tar /root/install-agent.sh'
}

check_installed() {
  local host="$1" mode
  for mode in "/etc/alloy/push-password root:alloy 640" "/etc/alloy/metrics-password root:alloy 640" \
    "/etc/alloy/conf.d root:root 755" "/var/lib/cointmu-chain cointmu-chain:alloy 2750"; do
    check "$host: $mode" on "$host" bash -c "[ \"\$(stat -c '%n %U:%G %a' ${mode%% *})\" = '$mode' ]"
  done
  check "$host: bundle is gone" on "$host" bash -c '! ls /root/*.tar /home/*/*.tar 2>/dev/null | grep .'
  check "$host: alloy is held" on "$host" bash -c 'apt-mark showhold | grep -x alloy'
  check "$host: no internet was needed or reachable" on "$host" bash -c '! timeout 3 bash -c "</dev/tcp/1.1.1.1/443"'
}

# Same bundle again (from before verify): nothing to do, no restart.
check_idempotent() {
  local host="$1" before output
  enroll reissue "$host" >/dev/null 2>&1
  put_bundle "$host"
  on "$host" bash /root/install-agent.sh /root/b.tar >/dev/null 2>&1 || fail "$host: reissued bundle"
  put_bundle "$host"
  before=$(on "$host" systemctl show -p MainPID alloy)
  output=$(on "$host" bash /root/install-agent.sh /root/b.tar 2>&1) || true
  if [[ "$output" == *"config unchanged"* && "$(on "$host" systemctl show -p MainPID alloy)" == "$before" ]]; then
    pass "$host: second run changes nothing"
  else
    fail "$host: second run: $output"
  fi
  enroll revoke-old "$host" >/dev/null 2>&1
  wait_for "$host: data with the reissued login" feed_and_verify "$host"
}

# A bundle whose login the VM does not know: pushes fail, the old config returns.
check_restore() {
  local host="$1" before
  enroll reissue "$host" >/dev/null 2>&1
  put_bundle "$host"
  enroll reissue "$host" --leaked >/dev/null 2>&1
  before=$(on "$host" cat /etc/default/alloy /etc/alloy/push-password /etc/alloy/metrics-password)
  refuse_on "$host: refused push" "the previous config is in place, the bundle is kept" "$host" bash /root/install-agent.sh /root/b.tar
  if [[ "$(on "$host" cat /etc/default/alloy /etc/alloy/push-password /etc/alloy/metrics-password)" == "$before" ]]; then pass "$host: previous settings and passwords are back"; else fail "$host: not restored"; fi
  check "$host: bundle kept after a failure" on "$host" test -f /root/b.tar
  put_bundle "$host"
  check "$host: next bundle installs" on "$host" bash /root/install-agent.sh /root/b.tar
}

# A host set up by hand before enrollment (old single config, its own extra setting).
check_adopt() {
  local host=adopted password
  start_host "$host" debian13
  password=$(openssl rand -hex 16)
  printf 'legacy-1:%s\n' "$(openssl passwd -6 "$password")" | tee -a "$repo/nginx/local/loki-agents.htpasswd" >> "$repo/nginx/local/metrics-agents.htpasswd"
  docker cp -q "$(ls "$repo"/state/alloy/*_amd64.deb)" "$PROJECT-$host:/root/alloy.deb"
  on "$host" bash -c "dpkg -i /root/alloy.deb >/dev/null 2>&1 && rm /root/alloy.deb
    printf '%s' '$password' | install -m 640 -o root -g alloy /dev/stdin /etc/alloy/push-password
    cp -p /etc/alloy/push-password /etc/alloy/metrics-password
    printf 'CONFIG_FILE=\"/etc/alloy/config.alloy\"\nAGENT_HOST=oldname\nGETH_LOG_FILES=$GETH_LOG\nMY_SETTING=kept\n' > /etc/default/alloy
    install -d /etc/cointmu-chain && echo NODES=miner=http://127.0.0.1:8545 > /etc/cointmu-chain/cointmu-chain.conf"
  enroll_host "$host" "$(enroll adopt "$host" "$(host_ip "$host")" --scopes cointmu --type linux --ssh "root@$host" --login legacy-1)"
  check "$host: own setting kept" on "$host" grep -x MY_SETTING=kept /etc/default/alloy
  check "$host: password untouched" on "$host" grep -x "$password" /etc/alloy/push-password
  check "$host: uninstall" on "$host" bash /usr/local/lib/cointmu-agent/install-agent.sh --uninstall
  check "$host: old settings are back" on "$host" grep -x AGENT_HOST=oldname /etc/default/alloy
  check "$host: Alloy stays installed" on "$host" dpkg-query -W alloy
}

check_uninstall() {
  local host="$1"
  check "$host: uninstall" on "$host" bash /usr/local/lib/cointmu-agent/install-agent.sh --uninstall
  check "$host: nothing of the agent left" on "$host" bash -c '! ls -d /etc/alloy /etc/systemd/system/cointmu-* /usr/local/lib/cointmu-*/* /var/lib/cointmu-agent 2>/dev/null | grep . && ! dpkg-query -W alloy 2>/dev/null | grep .'
  enroll remove "$host" >/dev/null 2>&1
}

prepare_stack
start_stack
enroll fetch-alloy amd64
write_stubs

start_host deb13 debian13
check_refusals
enroll_host deb13 "$(add_host deb13 --type linux --ssh netadmin@deb13)" && check_installed deb13
check_idempotent deb13
check_restore deb13
check_uninstall deb13

start_host deb12 debian12
on deb12 bash -c 'printf "#!/bin/sh\necho stub\n" > /usr/local/bin/pveversion && chmod +x /usr/local/bin/pveversion'
enroll_host deb12 "$(add_host deb12 --type pve --ssh root@deb12)" && check_installed deb12

start_host ubu24 ubuntu2404
enroll_host ubu24 "$(add_host ubu24 --type linux --ssh netadmin@ubu24)" && check_installed ubu24

# The container is its own "Proxmox host": pct push only checks its options,
# pct exec runs the command, and systemd-detect-virt says lxc.
start_host ubu22 ubuntu2204
on ubu22 bash -c 'cat > /usr/local/bin/pct && chmod +x /usr/local/bin/pct' <<'STUB'
#!/usr/bin/env bash
case "$1" in
  push) [[ "$*" == "push 106 $3 $4 --perms 0600 --user 0 --group 0" && "$3" == "$4" ]] ;;
  exec) [[ "$2 $3" == "106 --" ]] && shift 3 && exec "$@" ;;
  *) exit 1 ;;
esac
STUB
on ubu22 bash -c 'printf "#!/bin/sh\necho lxc\n" > /usr/local/bin/systemd-detect-virt && chmod +x /usr/local/bin/systemd-detect-virt'
enroll_host ubu22 "$(add_host ubu22 --type lxc --via root@ubu22:106)" && check_installed ubu22

check_adopt

(( failures == 0 )) || { echo "$failures check(s) failed" >&2; exit 1; }
echo "OK: enrollment and install as expected"
