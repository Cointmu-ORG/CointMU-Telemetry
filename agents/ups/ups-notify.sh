#!/usr/bin/env bash
# Posts one UPS power event to Discord #ups, straight from the UPS host, so it
# also works while the telemetry VM is down. upssched runs it as the nut user
# (CMDSCRIPT in upssched.conf.snippet), with the event as the only argument;
# upssched's timers do the debouncing, so every call is one message.
#
#   ups-notify.sh onbatt|online|lowbatt|fsd|shutdown|replbatt|commbad|commok|test
#
# Reads UPS and HOST_LABEL from /etc/cointmu-ups/cointmu-ups.conf and the
# webhook URL from /etc/cointmu-ups/discord-webhook (0600 nut). The URL goes
# to curl through a config file descriptor, never on a command line or in a
# log. Messages carry the host label, the UPS name, the event, charge and
# runtime; nothing else, and no mention can ping anyone.
#
# fsd and shutdown get short timeouts: upsmon runs SHUTDOWNCMD FINALDELAY
# seconds after the SHUTDOWN notification (upsmon.conf.snippet), and the post
# has to be finished or given up by then.
set -euo pipefail

readonly CONFIG_FILE=/etc/cointmu-ups/cointmu-ups.conf
readonly WEBHOOK_FILE=/etc/cointmu-ups/discord-webhook
readonly LOG_TAG=cointmu-ups-notify
readonly WEBHOOK_PATTERN='^https://(discord\.com|discordapp\.com)/api/webhooks/[0-9]+/[A-Za-z0-9_-]+$'
readonly UPS_PATTERN='^[A-Za-z0-9_.-]+(@[A-Za-z0-9_.-]+(:[0-9]+)?)?$'
# Anything else in a message is replaced, so the JSON needs no escaping.
readonly MESSAGE_CHARS='A-Za-z0-9 .,:/%=()_*'
readonly SECONDS_PER_MINUTE=60
# Worst case for fsd/shutdown: UPSC_TIMEOUT_FAST + POST_MAX_FAST (about 4 s).
readonly UPSC_TIMEOUT_FAST_SECONDS=1
readonly UPSC_TIMEOUT_SECONDS=3
readonly CONNECT_TIMEOUT_FAST_SECONDS=2
readonly POST_MAX_FAST_SECONDS=3
readonly CONNECT_TIMEOUT_SECONDS=5
readonly POST_MAX_SECONDS=10

log() { logger -t "$LOG_TAG" -- "$*" 2>/dev/null || echo "$LOG_TAG: $*" >&2; }
die() { log "$*"; exit 1; }

# $1 event; prints the headline and the explanation, tab-separated.
describe() {
  case "$1" in
    onbatt) printf 'ON BATTERY\tmains power lost for 30 s' ;;
    online) printf 'BACK ON MAINS\tpower restored after an outage' ;;
    lowbatt) printf 'LOW BATTERY\tthe UPS reports low battery, power can fail within minutes' ;;
    fsd) printf 'FORCED SHUTDOWN\tforced shutdown set, hosts on this UPS shut down now' ;;
    shutdown) printf 'SHUTTING DOWN\tthis host runs its shutdown command now' ;;
    replbatt) printf 'REPLACE BATTERY\tthe UPS asks for a new battery (repeats every 12 h)' ;;
    commbad) printf 'COMM LOST\tno contact with the UPS for 60 s' ;;
    commok) printf 'COMM RESTORED\tcontact with the UPS is back' ;;
    test) printf 'TEST\ttest message from ups-notify.sh' ;;
    *) return 1 ;;
  esac
}

# $1 upsc output, $2 variable; prints its value if it is a number.
ups_number() {
  sed -n "s/^$2: \([0-9][0-9.]*\)$/\1/p" <<<"$1" | head -1
}

# $1 upsc timeout; prints ", charge N %, runtime M min" for what is known.
battery_state() {
  local vars charge runtime state=""
  vars=$(timeout "$1" upsc "$UPS" 2>/dev/null) || return 0
  charge=$(ups_number "$vars" battery.charge)
  runtime=$(ups_number "$vars" battery.runtime)
  [[ -n "$charge" ]] && state+=", charge ${charge%.*} %"
  [[ -n "$runtime" ]] && state+=", runtime $(( ${runtime%.*} / SECONDS_PER_MINUTE )) min"
  printf '%s' "$state"
}

# $1 message, $2 connect timeout, $3 total timeout.
post() {
  local text payload
  text=$(printf '%s' "$1" | tr -c "$MESSAGE_CHARS"'\n-' '?' | sed ':a;N;$!ba;s/\n/\\n/g')
  payload=$(printf '{"content":"%s","allowed_mentions":{"parse":[]}}' "$text")
  curl -fsS --connect-timeout "$2" --max-time "$3" -o /dev/null -H 'Content-Type: application/json' \
    --data-binary @- -K <(printf 'url = "%s"\n' "$webhook") <<<"$payload"
}

[[ $# -eq 1 ]] || { sed -n '2,8p' "$0" >&2; exit 2; }
event="$1"
description=$(describe "$event") || die "unknown event '$event'"
headline="${description%%$'\t'*}"
detail="${description#*$'\t'}"

[[ -r "$CONFIG_FILE" ]] || die "cannot read $CONFIG_FILE"
UPS=$(sed -n 's/^UPS=//p' "$CONFIG_FILE")
HOST_LABEL=$(sed -n 's/^HOST_LABEL=//p' "$CONFIG_FILE")
[[ "$UPS" =~ $UPS_PATTERN ]] || die "UPS in $CONFIG_FILE is not a NUT name (ups or ups@host)"
HOST_LABEL="${HOST_LABEL:-$(hostname -s)}"
[[ -r "$WEBHOOK_FILE" ]] || die "cannot read $WEBHOOK_FILE (owner nut, mode 0600)"
webhook=$(<"$WEBHOOK_FILE")
[[ "$webhook" =~ $WEBHOOK_PATTERN ]] || die "$WEBHOOK_FILE does not hold a Discord webhook URL"

if [[ "$event" == fsd || "$event" == shutdown ]]; then
  upsc_timeout=$UPSC_TIMEOUT_FAST_SECONDS
  connect_timeout=$CONNECT_TIMEOUT_FAST_SECONDS
  post_max=$POST_MAX_FAST_SECONDS
else
  upsc_timeout=$UPSC_TIMEOUT_SECONDS
  connect_timeout=$CONNECT_TIMEOUT_SECONDS
  post_max=$POST_MAX_SECONDS
fi

message="**$headline** ${UPS%%@*} on $HOST_LABEL$(battery_state "$upsc_timeout")"$'\n'"$detail"
if post "$message" "$connect_timeout" "$post_max"; then
  log "posted $event"
else
  die "could not post $event to Discord (curl exit $?)"
fi
