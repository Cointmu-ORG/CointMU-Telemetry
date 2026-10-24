#!/usr/bin/env bash
# Writes the UPS's state for Alloy's textfile collector as
# /var/lib/cointmu-ups/ups.prom (Prometheus text format). Run every 15 s by
# cointmu-ups-metrics.timer as the cointmu-ups user (agents/ups/README.md).
#
#   ups-metrics.sh
#
# Reads UPS from /etc/cointmu-ups/cointmu-ups.conf and asks upsd (upsc, no
# login needed). ups_up is 0 when upsc fails or the driver's data is stale;
# then only ups_up and the timestamp are written. ups_scrape_timestamp_seconds
# is written on every run, so a stopped timer shows as old content in fresh
# scrapes (Grafana rule "UPS metrics stale").
#
# The directory must be group alloy, mode 2750 (setgid), from
# cointmu-ups.tmpfiles.conf: files written here then belong to group alloy,
# which the Alloy agent reads with, while this user stays out of that group.
set -euo pipefail

readonly CONFIG_FILE=/etc/cointmu-ups/cointmu-ups.conf
readonly OUT_DIR=/var/lib/cointmu-ups
readonly OUT_FILE="$OUT_DIR/ups.prom"
readonly READER_GROUP=alloy
readonly DIR_MODE=2750
readonly UPSC_TIMEOUT_SECONDS=5
readonly UPS_PATTERN='^([A-Za-z0-9_.-]+)(@[A-Za-z0-9_.-]+(:[0-9]+)?)?$'
readonly NUMBER_PATTERN='^-?[0-9]+(\.[0-9]+)?$'
# Flags of ups.status, always written (0 or 1), so every series is continuous.
readonly STATUS_FLAGS=(OL OB LB HB RB CHRG DISCHRG BYPASS CAL OFF OVER TRIM BOOST FSD)
# NUT variable -> metric name.
readonly GAUGES=(
  "battery.charge ups_battery_charge_percent"
  "battery.charge.low ups_battery_charge_low_percent"
  "battery.runtime ups_battery_runtime_seconds"
  "battery.runtime.low ups_battery_runtime_low_seconds"
  "ups.load ups_load_percent"
  "input.voltage ups_input_voltage_volts"
  "output.voltage ups_output_voltage_volts"
)

die() { echo "ups-metrics: $*" >&2; exit 1; }

check_out_dir() {
  getent group "$READER_GROUP" >/dev/null \
    || die "no group '$READER_GROUP': install Alloy first, then systemd-tmpfiles --create (README.md)"
  [[ -d "$OUT_DIR" ]] || die "missing $OUT_DIR: systemd-tmpfiles --create /etc/tmpfiles.d/cointmu-ups.conf"
  local group mode
  read -r group mode < <(stat -c '%G %a' "$OUT_DIR")
  [[ "$group" == "$READER_GROUP" && "$mode" == "$DIR_MODE" ]] \
    || die "$OUT_DIR is group $group mode $mode, expected $READER_GROUP $DIR_MODE (cointmu-ups.tmpfiles.conf)"
}

# $1 upsc output, $2 variable: prints its value.
ups_var() { sed -n "s/^$2: //p" <<<"$1" | head -1; }

# Label values: only characters that need no escaping.
label_value() { printf '%s' "$1" | tr -c 'A-Za-z0-9 ._-' '_' | head -c 64; }

# $1 upsc output, $2 labels; prints the metric lines of a readable UPS.
ups_metrics() {
  local vars="$1" labels="$2" entry var metric value flag status
  for entry in "${GAUGES[@]}"; do
    read -r var metric <<<"$entry"
    value=$(ups_var "$vars" "$var")
    [[ "$value" =~ $NUMBER_PATTERN ]] && printf '%s{%s} %s\n' "$metric" "$labels" "$value"
  done
  status=" $(ups_var "$vars" ups.status) "
  for flag in "${STATUS_FLAGS[@]}"; do
    printf 'ups_status{%s,flag="%s"} %d\n' "$labels" "$flag" "$([[ "$status" == *" $flag "* ]] && echo 1 || echo 0)"
  done
  printf 'ups_info{%s,model="%s",driver="%s"} 1\n' "$labels" \
    "$(label_value "$(ups_var "$vars" device.model)")" "$(label_value "$(ups_var "$vars" driver.name)")"
}

check_out_dir
[[ -r "$CONFIG_FILE" ]] || die "cannot read $CONFIG_FILE"
ups=$(sed -n 's/^UPS=//p' "$CONFIG_FILE")
[[ "$ups" =~ $UPS_PATTERN ]] || die "UPS in $CONFIG_FILE is not a NUT name (ups or ups@host)"
labels="ups=\"${BASH_REMATCH[1]}\""

umask 027
{
  # upsc exits non-zero when upsd is down, the driver is not connected or its
  # data is stale.
  if vars=$(timeout "$UPSC_TIMEOUT_SECONDS" upsc "$ups" 2>/dev/null); then
    echo "ups_up{$labels} 1"
    ups_metrics "$vars" "$labels"
  else
    echo "ups_up{$labels} 0"
  fi
  echo "ups_scrape_timestamp_seconds{$labels} $(date +%s)"
} > "$OUT_FILE.tmp"
# The collector reads *.prom only, so it never sees a half-written file.
mv "$OUT_FILE.tmp" "$OUT_FILE"
