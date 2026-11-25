# shellcheck shell=bash
# Does a host's data arrive? Sourced by scripts/enroll.sh. Asks Prometheus and
# Loki through the grafana container, like healthcheck.sh.

readonly FRESH_WINDOW=3m

urlencode() {
  local text="$1" i char
  for (( i = 0; i < ${#text}; i++ )); do
    char="${text:i:1}"
    case "$char" in
      [A-Za-z0-9._~-]) printf '%s' "$char" ;;
      *) printf '%%%02X' "'$char" ;;
    esac
  done
}

# $1 metrics|logs, $2 selector; succeeds if it returned data in FRESH_WINDOW.
has_fresh_data() {
  local url answer
  if [[ "$1" == metrics ]]; then
    url="http://prometheus:9090/api/v1/query?query=$(urlencode "count(last_over_time($2[$FRESH_WINDOW]))")"
  else
    url="http://loki:3100/loki/api/v1/query?query=$(urlencode "sum(count_over_time($2[$FRESH_WINDOW]))")"
  fi
  answer=$(docker compose exec -T grafana wget -qO- "$url" 2>/dev/null </dev/null) || return 1
  grep -q '"result":\[{' <<<"$answer"
}

# Prints one line per check of the loaded host; fails if any has no data.
check_host_data() {
  local kind selector missing=0
  while read -r kind selector; do
    selector="${selector//HOST/$h_host}"
    if has_fresh_data "$kind" "$selector"; then
      echo "ok:      $kind $selector"
    else
      echo "MISSING: $kind $selector (nothing in the last $FRESH_WINDOW)"
      missing=1
    fi
  done < <(manifest_lines verify "${h_scopes//,/ }" "$h_type")
  return "$missing"
}
