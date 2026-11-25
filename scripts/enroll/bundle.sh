# shellcheck shell=bash
# The one-time bundle of a host, sourced by scripts/enroll.sh: a tar with
# everything install-agent.sh needs, so the host downloads nothing.

readonly BUNDLE_DIR=state/bundles
readonly BUNDLE_TTL_MINUTES=1440
readonly DEFAULT_HTTPS_PORT=443

bundle_file() { echo "$BUNDLE_DIR/$1.tar"; }

shred_bundle() {
  local file
  file=$(bundle_file "$1")
  if [[ -f "$file" ]]; then shred -u "$file"; fi
}

expire_bundles() {
  local file
  [[ -d "$BUNDLE_DIR" ]] || return 0
  while IFS= read -r -d '' file; do
    shred -u "$file"
    echo "bundle $(basename "$file" .tar) expired after $((BUNDLE_TTL_MINUTES / 60)) h: scripts/enroll.sh reissue" >&2
  done < <(find "$BUNDLE_DIR" -maxdepth 1 -name '*.tar' -mmin "+$BUNDLE_TTL_MINUTES" -print0)
}

# $1 directive, $2 scopes (space separated), $3 host type: the arguments of
# every matching manifest line.
manifest_lines() {
  local scope
  for scope in $2; do
    awk -v want="$1" -v type="$3" '
      /^#/ || NF == 0 { next }
      $1 ~ /^on:/ { n = split(substr($1, 4), types, ","); hit = 0
        for (i = 1; i <= n; i++) if (types[i] == type) hit = 1
        if (!hit) next
        sub(/^[^ ]+ +/, "") }
      $1 == want { sub(/^[^ ]+ +/, ""); print }' "scopes/$scope/agent.manifest"
  done
}

scope_logins() { manifest_lines logins "$1" "$2" | tr ' ' '\n' | sort -u | tr '\n' ' '; }

env_file_value() { sed -n "s/^$1=//p" .env | tail -1; }

vm_url() {
  local host port
  host=$(env_file_value GLITCHTIP_HOST)
  port=$(env_file_value HTTPS_PORT)
  [[ -n "$host" ]] || die "GLITCHTIP_HOST is empty in .env"
  if [[ "${port:-$DEFAULT_HTTPS_PORT}" == "$DEFAULT_HTTPS_PORT" ]]; then echo "https://$host"; else echo "https://$host:$port"; fi
}

# $1 stage folder, $2 logins: the bundle's own part of /etc/default/alloy.
write_alloy_env() {
  local url key value
  url=$(vm_url)
  {
    echo "AGENT_HOST=\"$h_host\""
    if [[ " $2" == *" logs "* ]]; then echo "LOKI_PUSH_URL=\"$url/loki/api/v1/push\""; echo "LOKI_PUSH_USER=\"$h_login\""; fi
    if [[ " $2" == *" metrics "* ]]; then echo "METRICS_PUSH_URL=\"$url/prometheus/api/v1/write\""; echo "METRICS_PUSH_USER=\"$h_login\""; fi
    echo "AGENT_TYPE=\"$h_type\""
    echo "AGENT_RACK=\"${h_rack:-none}\""
    while read -r key value; do echo "$key=\"$value\""; done < <(manifest_lines setenv "${h_scopes//,/ }" "$h_type")
    while read -r key _; do
      if [[ -n "${SETTINGS[$key]:-}" ]]; then echo "$key=\"${SETTINGS[$key]}\""; fi
    done < <(manifest_lines env "${h_scopes//,/ }" "$h_type")
  } > "$1/alloy.env"
}

# $1 stage folder: settings for "conf" files.
write_settings() {
  local key
  : > "$1/settings.env"
  for key in "${!SETTINGS[@]}"; do printf '%s=%s\n' "$key" "${SETTINGS[$key]}" >> "$1/settings.env"; done
}

# $1 stage folder, $2 logins: repository files named by the manifests.
copy_files() {
  local src scope scopes="${h_scopes//,/ }"
  {
    for scope in $scopes; do echo "scopes/$scope/agent.manifest"; done
    manifest_lines fragment "$scopes" "$h_type"
    manifest_lines tmpfiles "$scopes" "$h_type"
    manifest_lines unit "$scopes" "$h_type"
    manifest_lines timer "$scopes" "$h_type"
    manifest_lines file "$scopes" "$h_type" | cut -d' ' -f1
    if [[ " $2" == *" logs "* ]]; then echo agent/push-logs.alloy; fi
    if [[ " $2" == *" metrics "* ]]; then echo agent/push-metrics.alloy; fi
    echo agent/alloy.pin
  } | sort -u | while read -r src; do
    install -D -m 600 "$src" "$1/$src"
  done
  install -m 700 agent/install-agent.sh "$1/install-agent.sh"
  install -m 600 certs/server.crt "$1/telemetry.crt"
}

# $1 "with-alloy" or "without-alloy", $2 stage folder that already holds the
# password files (none for adopt). Uses h_* and SETTINGS; writes the bundle.
build_bundle() {
  local stage="$2" logins target deb sums
  logins="$(scope_logins "${h_scopes//,/ }" "$h_type")"
  write_alloy_env "$stage" "$logins"
  write_settings "$stage"
  copy_files "$stage" "$logins"
  if [[ "$1" == with-alloy ]]; then
    deb=$(alloy_deb "$h_arch")
    cp "$deb" "$stage/alloy.deb"
  fi
  printf 'HOST=%s\nSCOPES=%s\nTYPE=%s\nARCH=%s\nLOGINS="%s"\n' \
    "$h_host" "$h_scopes" "$h_type" "$h_arch" "${logins% }" > "$stage/bundle.conf"
  sums=$(cd "$stage" && find . -type f -printf '%P\0' | sort -z | xargs -0 sha256sum)
  printf '%s\n' "$sums" > "$stage/manifest.sha256"
  install -d -m 700 state "$BUNDLE_DIR"
  target=$(bundle_file "$h_host")
  (umask 077 && tar -C "$stage" --owner=0 --group=0 --sort=name -cf "$target.partial" .)
  mv "$target.partial" "$target"
}
