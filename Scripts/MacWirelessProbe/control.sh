#!/bin/zsh
set -eu

usage() {
  echo "Usage: $0 RUN_DIR {status|list|events|discover|select N|pair|pair-geotag-subscription|disconnect|observe-saved|reconnect|reconnect-registration|wifi|quit}" >&2
  exit 2
}

(( $# >= 2 )) || usage
run="$1"
command="$2"
shift 2

while [[ "$run" == */ && "$run" != / ]]; do
  run="${run%/}"
done
[[ "$run" == /* && -d "$run" && ! -L "$run" ]] || usage
acl_listing="$(/bin/ls -ldeB "$run")"
if [[ "$(stat -f '%OLp:%u' "$run")" != "700:$(id -u)" || "$acl_listing" == *$'\n'* ]]; then
  echo "Use an owner-only run directory with mode 0700 and no ACL." >&2
  exit 1
fi

case "$command" in
  status|list)
    (( $# == 0 )) || usage
    exec cat "$run/status"
    ;;
  events)
    (( $# == 0 )) || usage
    exec cat "$run/events"
    ;;
  select)
    (( $# == 1 )) || usage
    case "$1" in
      ''|0*|*[!0-9]*) usage ;;
    esac
    command="select $1"
    ;;
  discover|pair|pair-geotag-subscription|disconnect|observe-saved|reconnect|reconnect-registration|wifi|quit)
    (( $# == 0 )) || usage
    ;;
  *) usage ;;
esac

if [[ ! -f "$run/status" ]] || grep -qx 'phase=stopped' "$run/status"; then
  echo "The probe is not running in this directory." >&2
  exit 1
fi

umask 077
pending="$(mktemp "$run/.command.XXXXXX")"
trap 'rm -f "$pending"' EXIT
printf '%s\n' "$command" > "$pending"
if [[ -d "$run/command" ]] || ! ln -h "$pending" "$run/command" 2>/dev/null; then
  echo "A command is awaiting pickup." >&2
  exit 1
fi
