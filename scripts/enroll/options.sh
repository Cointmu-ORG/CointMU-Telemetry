# shellcheck shell=bash
# Options and settings of a host and their checks, sourced by scripts/enroll.sh.

readonly NAME_PATTERN='^[a-z0-9][a-z0-9-]{0,40}$'
readonly LOGIN_PATTERN='^[a-z0-9][a-z0-9.-]{0,62}$'
readonly SCOPE_PATTERN='^[a-z0-9-]+(,[a-z0-9-]+)*$'
readonly IPV4_PATTERN='^((25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}(25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])$'
readonly SSH_PATTERN='^([a-z_][a-z0-9_-]*@)?[A-Za-z0-9][A-Za-z0-9._-]*$'
readonly VIA_PATTERN='^([a-z_][a-z0-9_-]*@)?[A-Za-z0-9][A-Za-z0-9._-]*:[0-9]+$'
readonly RACK_PATTERN='^[A-Za-z0-9._-]{1,32}$'
readonly PORT_PATTERN='^[1-9][0-9]{0,4}$'
# The value ends up in /etc/default/alloy, which a shell may source: no quotes,
# no "$", no backtick, no backslash.
readonly SETTING_PATTERN='^[A-Z][A-Z0-9_]*=[A-Za-z0-9_./:@*,= -]*$'
readonly SETTINGS_DIR=inventory/settings
readonly DEFAULT_SSH_PORT=22

declare -A SETTINGS=()

parse_options() {
  h_scopes="" h_type=linux h_ssh="" h_via="" h_rack="" h_ssh_port="$DEFAULT_SSH_PORT" h_arch=amd64 h_login="" h_state=pending
  while (( $# > 0 )); do
    (( $# >= 2 )) || usage
    case "$1" in
      --scopes) h_scopes="$2" ;;
      --type) h_type="$2" ;;
      --ssh) h_ssh="$2" ;;
      --via) h_via="$2" ;;
      --rack) h_rack="$2" ;;
      --ssh-port) h_ssh_port="$2" ;;
      --arch) h_arch="$2" ;;
      --login) h_login="$2" ;;
      --set)
        [[ "$2" =~ $SETTING_PATTERN ]] || die "--set '$2' is not KEY=VALUE with plain characters"
        SETTINGS["${2%%=*}"]="${2#*=}"
        ;;
      *) usage ;;
    esac
    shift 2
  done
}

# $1 what, $2 value, $3 pattern.
check_format() { [[ "$2" =~ $3 ]] || die "invalid $1 '$2'"; }

check_host() {
  local scope
  check_format host "$h_host" "$NAME_PATTERN"
  check_format address "$h_ip" "$IPV4_PATTERN"
  check_format --scopes "$h_scopes" "$SCOPE_PATTERN"
  check_format --ssh-port "$h_ssh_port" "$PORT_PATTERN"
  check_format --type "$h_type" '^(pve|linux|lxc)$'
  check_format --arch "$h_arch" '^(amd64|arm64)$'
  if [[ -n "$h_rack" ]]; then check_format --rack "$h_rack" "$RACK_PATTERN"; fi
  if [[ "$h_type" == lxc ]]; then
    check_format "--via (pve ssh alias:ctid)" "$h_via" "$VIA_PATTERN"
  else
    check_format --ssh "$h_ssh" "$SSH_PATTERN"
  fi
  for scope in ${h_scopes//,/ }; do
    [[ -f "scopes/$scope/agent.manifest" ]] || die "no scope '$scope' (scopes/$scope/agent.manifest)"
  done
  if registry_hosts | grep -qxF "$h_host"; then die "host '$h_host' exists (remove it first, or reissue)"; fi
  if registry_has_ip "$h_ip"; then die "another host has the address $h_ip"; fi
}

# Settings the chosen scopes know, one per line.
known_settings() {
  manifest_lines env "${h_scopes//,/ }" "$h_type" | cut -d' ' -f1
  manifest_lines conf "${h_scopes//,/ }" "$h_type" | cut -d' ' -f2- | tr ' ' '\n'
}

# $1 add or adopt: every --set key must be known, and add needs the required ones.
check_settings() {
  local key known
  known=$(known_settings)
  for key in "${!SETTINGS[@]}"; do
    grep -qxF "$key" <<<"$known" || die "no chosen scope has a setting '$key'; known: $(tr '\n' ' ' <<<"$known")"
  done
  [[ "$1" == add ]] || return 0
  while read -r key; do
    [[ -n "${SETTINGS[$key]:-}" ]] || die "--set $key=... is required"
  done < <(manifest_lines env "${h_scopes//,/ }" "$h_type" | awk '$2 == "required" { print $1 }')
}

settings_file() { echo "${SETTINGS_DIR:?}/${h_host:?}"; }

save_settings() {
  local key
  install -d -m 700 "$SETTINGS_DIR"
  (umask 077 && : > "$(settings_file)")
  for key in "${!SETTINGS[@]}"; do printf '%s=%s\n' "$key" "${SETTINGS[$key]}" >> "$(settings_file)"; done
}

load_settings() {
  local line
  [[ -f "$(settings_file)" ]] || return 0
  while IFS= read -r line; do SETTINGS["${line%%=*}"]="${line#*=}"; done < "$(settings_file)"
}

delete_settings() { rm -f "${SETTINGS_DIR:?}/${h_host:?}"; }
