#!/usr/bin/env bash
# Installs the telemetry agent (Grafana Alloy and the collectors of the host's
# scopes) from a bundle made by scripts/enroll.sh on the telemetry VM. Uses
# only what is in the bundle: no downloads. One file on purpose: it travels in
# the bundle and runs alone (RUNBOOK.md, "Enroll a host"). Run as root.
#
#   install-agent.sh <bundle.tar> [--dry-run]
#   install-agent.sh --uninstall [--dry-run]
#
# Order: check everything, install, validate the new config, swap it in, restart
# Alloy, check that pushes succeed; on failure the old config is put back and the
# bundle is kept. After success the bundle is shredded. Running it again changes
# nothing that is already right. Directives of the scopes' agent.manifest files
# are described in scopes/cointmu/agent.manifest.
set -euo pipefail
umask 077

readonly ALLOY_DIR=/etc/alloy
readonly CONF_DIR="$ALLOY_DIR/conf.d"
readonly ENV_FILE=/etc/default/alloy
readonly STATE_DIR=/var/lib/cointmu-agent
readonly INSTALLED="$STATE_DIR/installed"
readonly SELF_COPY=/usr/local/lib/cointmu-agent/install-agent.sh
readonly METRICS_HOST=127.0.0.1
readonly METRICS_PORT=12345
readonly PUSH_WAIT_SECONDS=90
readonly SENT_MAX_AGE_SECONDS=120
readonly MIN_FREE_KIB=1500000
readonly NOLOGIN=/usr/sbin/nologin

dry_run=0
changed=0
work=""
problems=0

die() { echo "install-agent: $*" >&2; exit 1; }
say() { echo "$*"; }
problem() { echo "STOP: $*" >&2; problems=$((problems + 1)); }
cleanup() { if [[ -n "$work" ]]; then rm -rf "${work:?}"; fi; }
trap cleanup EXIT

# Runs a command that changes the host, or prints it in a dry run.
act() {
  if (( dry_run )); then say "would run: $*"; else "$@"; fi
}

record() {
  (( dry_run )) && return 0
  install -d -m 700 "$STATE_DIR"
  touch "$INSTALLED"
  grep -qxF "$*" "$INSTALLED" || echo "$*" >> "$INSTALLED"
}

# $1 source, $2 destination, $3 mode, $4 group: installs if content or mode differ.
put() {
  local source="$1" dest="$2" mode="$3" group="${4:-root}"
  if [[ -f "$dest" ]] && cmp -s "$source" "$dest" && [[ "$(stat -c '%a %U:%G' "$dest")" == "$mode root:$group" ]]; then
    return 0
  fi
  changed=1
  say "$([[ -e "$dest" ]] && echo update || echo create) $dest ($mode root:$group)"
  (( dry_run )) && return 0
  # Only what was not here before is removed by --uninstall.
  [[ -e "$dest" ]] || record "file $dest"
  install -d -m 755 "$(dirname "$dest")"
  install -m "$mode" -o root -g "$group" "$source" "$dest"
}

# --- Bundle -----------------------------------------------------------------

conf_value() { sed -n "s/^$1=//p" "$work/bundle.conf" | tr -d '"'; }

open_bundle() {
  local bundle="$1" mode
  [[ -f "$bundle" ]] || die "no bundle $bundle"
  mode=$(stat -c %a "$bundle")
  [[ "$mode" == 600 || "$mode" == 400 ]] || die "$bundle has mode $mode, expected 600: it holds passwords"
  work=$(mktemp -d -p /var/tmp)   # about 170 MB; /tmp may be a small tmpfs
  tar --no-same-owner -xf "$bundle" -C "$work" || die "cannot unpack $bundle (truncated? copy it again)"
  (cd "$work" && sha256sum --quiet --strict -c manifest.sha256) || die "bundle content does not match its manifest"
  diff <(cd "$work" && find . -type f ! -name manifest.sha256 -printf '%P\n' | sort) \
    <(sed 's/^[^ ]*  //' "$work/manifest.sha256" | sort) >/dev/null || die "bundle has files its manifest does not list"
  scopes=$(conf_value SCOPES); scopes="${scopes//,/ }"
  host_type=$(conf_value TYPE)
  logins=$(conf_value LOGINS)
}

# $1 directive: the arguments of every matching manifest line for this host type.
manifest_lines() {
  local scope
  for scope in $scopes; do
    awk -v want="$1" -v type="$host_type" '
      /^#/ || NF == 0 { next }
      $1 ~ /^on:/ { n = split(substr($1, 4), types, ","); hit = 0
        for (i = 1; i <= n; i++) if (types[i] == type) hit = 1
        if (!hit) next
        sub(/^[^ ]+ +/, "") }
      $1 == want { sub(/^[^ ]+ +/, ""); print }' "$work/scopes/$scope/agent.manifest"
  done
}

# --- Checks -----------------------------------------------------------------

detect_type() {
  if command -v pveversion >/dev/null; then echo pve
  elif [[ "$(systemd-detect-virt -c 2>/dev/null || true)" == lxc ]]; then echo lxc
  else echo linux; fi
}

check_platform() {
  local id="" like="" arch found
  # shellcheck disable=SC1091 # the host's own file
  id=$(. /etc/os-release && echo "$ID") like=$(. /etc/os-release && echo "${ID_LIKE:-}")
  [[ " $id $like " == *" debian "* ]] || problem "$id is not Debian or Ubuntu based"
  arch=$(dpkg --print-architecture)
  case "$arch" in
    amd64 | arm64) ;;
    armhf | armel) problem "$arch: Alloy has no 32-bit ARM build; install a 64-bit OS (arm64) on this machine" ;;
    *) problem "architecture $arch is not supported" ;;
  esac
  [[ "$arch" == "$(conf_value ARCH)" ]] || problem "this host is $arch, the bundle is for $(conf_value ARCH) (enroll.sh --arch)"
  found=$(detect_type)
  [[ "$found" == "$host_type" ]] || problem "this host is a '$found', the bundle is for '$host_type' (enroll.sh --type)"
}

check_tools() {
  local tool
  while read -r tool; do
    command -v "$tool" >/dev/null || problem "$tool is missing; install it from this host's own distribution"
  done < <(manifest_lines tool)
  while read -r tool; do
    command -v "$tool" >/dev/null || say "WARNING: $tool is missing; its metrics stay empty until it is installed"
  done < <(manifest_lines want)
}

alloy_version() { dpkg-query -W -f '${Status} ${Version}' alloy 2>/dev/null | sed -n 's/^install ok installed //p;s/^hold ok installed //p'; }
pin_value() { sed -n "s/^$1=//p" "$work/agent/alloy.pin"; }

check_alloy_package() {
  local installed wanted free
  installed=$(alloy_version)
  wanted=$(pin_value VERSION)
  if [[ -n "$installed" ]]; then
    [[ "$installed" == "$wanted" ]] || problem "alloy $installed is installed, the bundle is for $wanted (RUNBOOK.md, \"Upgrade Alloy\")"
    return 0
  fi
  [[ -f "$work/alloy.deb" ]] || { problem "Alloy is not installed and the bundle has no package (adopted host?)"; return 0; }
  [[ "$(sha256sum "$work/alloy.deb" | cut -d' ' -f1)" == "$(pin_value "SHA256_$(dpkg --print-architecture)")" ]] \
    || problem "the Alloy package in the bundle is not the pinned one"
  free=$(df -Pk /usr | awk 'NR == 2 { print $4 }')
  (( free >= MIN_FREE_KIB )) || problem "only $((free / 1024)) MiB free on /usr; Alloy needs about $((MIN_FREE_KIB / 1024))"
}

password_name() { if [[ "$1" == logs ]]; then echo push-password; else echo metrics-password; fi; }

check_passwords() {
  local kind file
  for kind in $logins; do
    file=$(password_name "$kind")
    [[ -s "$work/$file" || -s "$ALLOY_DIR/$file" ]] || problem "no $kind password in the bundle or in $ALLOY_DIR/$file"
  done
}

setting() { sed -n "s/^$1=//p" "$work/settings.env" | tail -1; }

check_conf_files() {
  local dest key keys
  while read -r dest keys; do
    [[ -e "$dest" ]] && continue
    for key in $keys; do
      grep -q "^$key=" "$work/settings.env" || problem "$dest does not exist here and the bundle has no $key (enroll.sh --set $key=...)"
    done
  done < <(manifest_lines conf)
}

check_all() {
  check_platform
  check_tools
  check_alloy_package
  check_passwords
  check_conf_files
  (( problems == 0 )) || die "nothing changed; fix the above, then run this again"
}

# --- Install ----------------------------------------------------------------

install_alloy() {
  if [[ -n "$(alloy_version)" ]]; then
    (( dry_run )) || [[ -f "$INSTALLED" ]] || record "alloy kept"
  else
    changed=1
    record "alloy new"
    act dpkg -i "$work/alloy.deb"
  fi
  if command -v apt-mark >/dev/null && ! apt-mark showhold 2>/dev/null | grep -qx alloy; then act apt-mark hold alloy >/dev/null; fi
}

install_conf_files() {
  local dest keys key
  while read -r dest keys; do
    if [[ -e "$dest" ]]; then continue; fi
    for key in $keys; do printf '%s=%s\n' "$key" "$(setting "$key")"; done > "$work/conf"
    put "$work/conf" "$dest" 644
  done < <(manifest_lines conf)
}

install_collectors() {
  local name src dest mode units_changed
  while read -r name; do
    getent passwd "$name" >/dev/null \
      || act useradd --system --no-create-home --home-dir /nonexistent --shell "$NOLOGIN" "$name"
  done < <(manifest_lines user)
  while read -r src dest mode; do put "$work/$src" "$dest" "$mode"; done < <(manifest_lines file)
  install_conf_files
  while read -r src; do
    put "$work/$src" "/etc/tmpfiles.d/$(basename "$src")" 644
    act systemd-tmpfiles --create "/etc/tmpfiles.d/$(basename "$src")"
  done < <(manifest_lines tmpfiles)
  units_changed=$changed
  changed=0
  while read -r src; do put "$work/$src" "/etc/systemd/system/$(basename "$src")" 644; done < <(manifest_lines unit; manifest_lines timer)
  if (( changed )); then act systemctl daemon-reload; fi
  changed=$(( changed || units_changed ))
}

start_collectors() {
  local src name
  while read -r src; do
    name=$(basename "$src" .timer)
    systemctl is-enabled --quiet "$name.timer" 2>/dev/null || record "timer $name.timer"
    if ! act systemctl start "$name.service"; then
      journalctl -u "$name.service" -n 20 --no-pager >&2 || true
      die "$name.service fails. In a container, drop the sandbox option it names with systemctl edit, then run this again"
    fi
    act systemctl enable --now "$name.timer"
  done < <(manifest_lines timer)
}

# Keys of $ENV_FILE that this bundle does not set stay as they are.
write_env() {
  local line key
  {
    echo "# Written by install-agent.sh; host settings below are kept on the next run."
    echo "CONFIG_FILE=\"$CONF_DIR\""
    echo "CUSTOM_ARGS=\"--stability.level=experimental --server.http.listen-addr=$METRICS_HOST:$METRICS_PORT --disable-reporting\""
    echo "RESTART_ON_UPGRADE=false"
    cat "$work/alloy.env"
  } > "$work/env"
  [[ -f "$ENV_FILE" ]] || return 0
  while IFS= read -r line; do
    key="${line%%=*}"
    grep -q "^$key=" "$work/env" || printf '%s\n' "$line" >> "$work/env"
  done < <(grep -E '^[A-Z][A-Z0-9_]*=' "$ENV_FILE")
}

stage_fragments() {
  local src
  mkdir "$work/conf.d"
  while read -r src; do cp "$work/$src" "$work/conf.d/"; done < <(manifest_lines fragment)
  for src in push-logs push-metrics; do
    if [[ -f "$work/agent/$src.alloy" ]]; then cp "$work/agent/$src.alloy" "$work/conf.d/"; fi
  done
}

# shellcheck disable=SC1091 # generated above
new_env() { (set -a; . "$work/env"; exec "$@"); }

check_new_config() {
  local key pattern file found
  (( dry_run )) && ! command -v alloy >/dev/null && return 0
  new_env alloy validate --stability.level=experimental "$work/conf.d" || die "the new config is not valid; the running one is unchanged"
  while read -r key; do
    pattern=$(new_env bash -c "printf '%s' \"\${$key:-}\"")
    [[ -n "$pattern" ]] || continue
    found=0
    for file in $pattern; do
      if [[ -f "$file" ]] && runuser -u alloy -- test -r "$file"; then found=1; fi
    done
    (( found )) || die "user alloy cannot read any file of $key=$pattern (permissions or path); the running config is unchanged"
  done < <(manifest_lines readable)
}

# --- Swap, check, restore ---------------------------------------------------

# "<bundle file> <name in /etc/alloy> <mode> <group>" for what the bundle brings.
secrets() {
  local kind file
  for kind in $logins; do
    file=$(password_name "$kind")
    if [[ -s "$work/$file" ]]; then echo "$file 640 alloy"; fi
  done
  echo "telemetry.crt 644 root"
}

config_differs() {
  local file mode group
  while read -r file mode group; do
    cmp -s "$work/$file" "$ALLOY_DIR/$file" || return 0
    [[ "$(stat -c '%a %U:%G' "$ALLOY_DIR/$file")" == "$mode root:$group" ]] || return 0
  done < <(secrets)
  ! diff -rq "$work/conf.d" "$CONF_DIR" >/dev/null 2>&1 || ! cmp -s "$work/env" "$ENV_FILE"
}

# Config, settings, passwords and certificate belong together: an old config with
# a new password would not push either.
backup_config() {
  local file
  rm -rf "${STATE_DIR:?}/backup"
  install -d -m 700 "$STATE_DIR/backup/alloy"
  if [[ -f "$ENV_FILE" ]]; then cp -p "$ENV_FILE" "$STATE_DIR/backup/env"; fi
  for file in push-password metrics-password telemetry.crt conf.d; do
    if [[ -e "$ALLOY_DIR/$file" ]]; then cp -Rp "$ALLOY_DIR/$file" "$STATE_DIR/backup/alloy/"; fi
  done
  # What an adopted host had before its first enrollment, for --uninstall.
  if [[ ! -e "$STATE_DIR/original" ]] && grep -qx "alloy kept" "$INSTALLED"; then cp -Rp "$STATE_DIR/backup" "$STATE_DIR/original"; fi
}

swap_config() {
  local file mode group
  backup_config
  while read -r file mode group; do
    install -m "$mode" -o root -g "$group" "$work/$file" "$ALLOY_DIR/$file"
  done < <(secrets)
  rm -rf "${CONF_DIR:?}"
  install -d -m 755 "$CONF_DIR"
  install -m 644 "$work"/conf.d/*.alloy "$CONF_DIR/"
  install -m 644 "$work/env" "$ENV_FILE"
}

# $1 folder made by backup_config.
restore_config() {
  local file
  for file in push-password metrics-password telemetry.crt conf.d; do
    rm -rf "${ALLOY_DIR:?}/${file:?}"
    if [[ -e "$1/alloy/$file" ]]; then cp -Rp "$1/alloy/$file" "$ALLOY_DIR/"; fi
  done
  if [[ -f "$1/env" ]]; then cp -p "$1/env" "$ENV_FILE"; fi
  systemctl restart alloy || true
}

alloy_metrics() {
  exec 3<>"/dev/tcp/$METRICS_HOST/$METRICS_PORT" || return 1
  printf 'GET /metrics HTTP/1.0\r\nHost: %s\r\n\r\n' "$METRICS_HOST" >&3
  cat <&3
  exec 3>&-
}

# $1 metrics text, $2 metric name: sum of its series.
metric_sum() { awk -v name="$2" '$1 == name || index($1, name "{") == 1 { sum += $NF } END { printf "%d", sum }' <<<"$1"; }

# $1 restarted or running: samples were accepted lately, and (counted from the
# restart) nothing was refused: 401, 403 and 413 show up as failed or dropped.
pushes_succeed() {
  local metrics sent
  metrics=$(alloy_metrics 2>/dev/null) || return 1
  if [[ " $logins " == *" metrics "* ]]; then
    sent=$(awk '/^prometheus_remote_storage_queue_highest_sent_timestamp_seconds/ { printf "%d", $NF; exit }' <<<"$metrics")
    (( $(date +%s) - ${sent:-0} <= SENT_MAX_AGE_SECONDS )) || return 1
  fi
  [[ "$1" == restarted ]] || return 0
  (( $(metric_sum "$metrics" loki_write_dropped_entries_total) == 0 )) || return 1
  (( $(metric_sum "$metrics" prometheus_remote_storage_samples_failed_total) == 0 ))
}

wait_for_pushes() {
  local deadline=$((SECONDS + PUSH_WAIT_SECONDS))
  while (( SECONDS < deadline )); do
    if pushes_succeed "$1"; then return 0; fi
    sleep 2
  done
  return 1
}

apply_config() {
  local state=running swapped=0
  if ! config_differs && systemctl is-active --quiet alloy; then
    say "config unchanged"
    if (( changed )); then systemctl restart alloy; state=restarted; fi
  else
    swap_config
    swapped=1
    state=restarted
    systemctl enable --quiet alloy
    systemctl restart alloy || true
  fi
  if wait_for_pushes "$state"; then
    say "Alloy runs and its pushes succeed"
    return 0
  fi
  journalctl -u alloy -n 30 --no-pager >&2 || true
  if (( swapped )); then restore_config "$STATE_DIR/backup"; fi
  die "no successful push within $PUSH_WAIT_SECONDS s; the previous config is in place, the bundle is kept"
}

install_agent() {
  local bundle="$1"
  open_bundle "$bundle"
  check_all
  install_alloy
  install_collectors
  stage_fragments
  write_env
  check_new_config
  if (( dry_run )); then
    if config_differs; then say "would replace $CONF_DIR ($(cd "$work/conf.d" && echo *)) and $ENV_FILE, then restart alloy"; else say "config unchanged"; fi
    say "dry run: nothing changed"
    return 0
  fi
  start_collectors
  apply_config
  put "$work/install-agent.sh" "$SELF_COPY" 700
  shred -u "$bundle"
  say "done: scopes $scopes on $(conf_value HOST). Bundle shredded."
}

# --- Uninstall --------------------------------------------------------------

uninstall_agent() {
  local kind path alloy_state
  [[ -f "$INSTALLED" ]] || die "nothing installed by this script ($INSTALLED is missing)"
  alloy_state=$(sed -n 's/^alloy //p' "$INSTALLED" | head -1)
  while read -r kind path; do
    if [[ "$kind" == timer ]]; then act systemctl disable --now "$path" || true; fi
  done < "$INSTALLED"
  if [[ "$alloy_state" == new ]]; then act systemctl disable --now alloy || true; fi
  while read -r kind path; do
    if [[ "$kind" == file ]]; then act rm -f -- "${path:?}"; fi
  done < "$INSTALLED"
  act systemctl daemon-reload
  if [[ "$alloy_state" == new ]]; then
    if command -v apt-mark >/dev/null; then act apt-mark unhold alloy >/dev/null; fi
    act dpkg --purge alloy
    act rm -rf "${ALLOY_DIR:?}"
  elif [[ -d "$STATE_DIR/original" ]]; then
    act restore_config "$STATE_DIR/original"
  fi
  act rm -rf "${STATE_DIR:?}"
  say "uninstalled. System users and collector output in /var/lib stay. On the VM: scripts/enroll.sh remove <host>"
}

(( EUID == 0 )) || die "run as root"
bundle="" uninstall=0
for argument in "$@"; do
  case "$argument" in
    --dry-run) dry_run=1 ;;
    --uninstall) uninstall=1 ;;
    -*) sed -n '7,8p' "$0" >&2; exit 2 ;;
    *) bundle="$argument" ;;
  esac
done
if (( uninstall )); then uninstall_agent
elif [[ -n "$bundle" ]]; then install_agent "$bundle"
else sed -n '7,8p' "$0" >&2; exit 2; fi
