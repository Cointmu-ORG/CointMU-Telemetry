# shellcheck shell=bash
# Logins and the nginx allowlist of a host, sourced by scripts/enroll.sh.

readonly LOCAL_DIR=nginx/local
readonly ALLOWLIST="$LOCAL_DIR/agent-allow.conf"
readonly LOGS_HTPASSWD="$LOCAL_DIR/loki-agents.htpasswd"
readonly METRICS_HTPASSWD="$LOCAL_DIR/metrics-agents.htpasswd"

htpasswd_of() { if [[ "$1" == logs ]]; then echo "$LOGS_HTPASSWD"; else echo "$METRICS_HTPASSWD"; fi; }
password_name() { if [[ "$1" == logs ]]; then echo push-password; else echo metrics-password; fi; }
has_login() { grep -q "^$1:" "$(htpasswd_of "$2")"; }

# agent-cred.sh would ask for sudo to create a missing file; enroll.sh runs in
# pipes and from cron, where nobody can answer.
check_access_files() {
  local file
  for file in "$LOGS_HTPASSWD" "$METRICS_HTPASSWD" "$ALLOWLIST"; do
    [[ -w "$file" ]] || die "$file is missing or not writable by $(id -un) (README.md, Deploy)"
  done
}

# $1 login, $2 kinds, $3 folder for the password files.
add_logins() {
  local kind
  for kind in $2; do
    scripts/agent-cred.sh add "$1" "$kind" "$3/$(password_name "$kind")"
  done
}

# Removes the login $1 from both endpoints, wherever it exists.
revoke_logins() {
  local kind
  for kind in logs metrics; do
    if has_login "$1" "$kind"; then scripts/agent-cred.sh revoke "$1" "$kind" >&2; fi
  done
}

nginx_reload() {
  docker compose exec -T proxy nginx -t >/dev/null 2>&1 </dev/null || return 1
  docker compose exec -T proxy nginx -s reload >/dev/null 2>&1 </dev/null
}

# Rewrites the allowlist with the filter command in "$@" and reloads nginx; puts
# the old content back if nginx rejects the new one.
change_allowlist() {
  local before after
  before=$(cat "$ALLOWLIST")
  after=$("$@") || return 1
  [[ "$after" == "$before" ]] && return 0
  printf '%s\n' "$after" > "$ALLOWLIST"
  if ! nginx_reload; then
    printf '%s\n' "$before" > "$ALLOWLIST"
    die "nginx rejects the new $ALLOWLIST (or the proxy is down); nothing changed there"
  fi
}

with_host_line() { cat "$ALLOWLIST"; printf '%s 1; # enroll:%s\n' "$2" "$1"; }
# Only enroll's own line: hand-written ones are never touched.
without_host_line() { awk -v tag="# enroll:$1" 'substr($0, length($0) - length(tag) + 1) != tag' "$ALLOWLIST"; }

allow_host() {
  if grep -qE "^[[:space:]]*${2//./\\.}[[:space:]]+1;" "$ALLOWLIST"; then
    echo "$2 is already allowed by a hand-written line in $ALLOWLIST; left as it is" >&2
    return 0
  fi
  change_allowlist with_host_line "$1" "$2"
}

disallow_host() { change_allowlist without_host_line "$1"; }
