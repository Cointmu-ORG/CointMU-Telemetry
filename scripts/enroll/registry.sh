# shellcheck shell=bash
# Host registry, sourced by scripts/enroll.sh: inventory/hosts.tsv, one line per
# host, git-ignored (host names, addresses and racks never go into git) and part
# of the encrypted config backup. Columns: FIELDS below; "-" is empty.

readonly REGISTRY_DIR=inventory
readonly REGISTRY="$REGISTRY_DIR/hosts.tsv"
readonly FIELDS=(host ip scopes type ssh via rack ssh_port arch login state)

registry_init() {
  install -d -m 700 "$REGISTRY_DIR"
  [[ -f "$REGISTRY" ]] || (umask 077 && : > "$REGISTRY")
}

# Sets the variables h_<field> from $1's line; fails if the host is unknown.
registry_load() {
  local line values i
  line=$(awk -F'\t' -v host="$1" '$1 == host' "$REGISTRY")
  [[ -n "$line" ]] || return 1
  IFS=$'\t' read -r -a values <<<"$line"
  for i in "${!FIELDS[@]}"; do
    [[ "${values[i]}" == - ]] && values[i]=""
    printf -v "h_${FIELDS[i]}" '%s' "${values[i]}"
  done
}

registry_hosts() { cut -f1 "$REGISTRY"; }
registry_has_ip() { awk -F'\t' -v ip="$1" '$2 == ip { found = 1 } END { exit !found }' "$REGISTRY"; }

# Replaces the file's content in one rename.
registry_write() {
  local next
  next=$(mktemp "$REGISTRY_DIR/.hosts.XXXXXX")
  sort > "$next"
  mv "$next" "$REGISTRY"
}

registry_delete() { awk -F'\t' -v host="$1" '$1 != host' "$REGISTRY" | registry_write; }

# Writes the h_<field> variables as the line of $h_host.
registry_save() {
  local field name line=""
  for field in "${FIELDS[@]}"; do
    name="h_$field"
    line+="${!name:--}"$'\t'
  done
  { awk -F'\t' -v host="${h_host:?}" '$1 != host' "$REGISTRY"; printf '%s\n' "${line%$'\t'}"; } | registry_write
}
