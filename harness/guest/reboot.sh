#!/bin/bash
# Schedules a restart of the guest and returns immediately, so the host
# orchestrator can start polling for the guest to come back rather than
# blocking on a command that can never itself return cleanly — the SSH
# session carrying this command is what the reboot tears down.
#
# Usage:
#   reboot.sh
#
# Backgrounds `sudo shutdown -r now` and detaches it with `disown` before
# this script exits, so the reboot is already in flight by the time its own
# exit status is collected. The golden image's automation user is expected
# to hold passwordless sudo for exactly this command (KTD1); if it does
# not, the reboot silently never happens and the caller's own
# boot-and-rejoin poll is what times out — this script has already
# returned 0 by then and cannot detect that failure itself.
#
# Exit codes: 0 always (the scheduling step itself has nothing left to
# observe before returning), 2 usage error.
set -euo pipefail

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) sed -n '2,17p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

nohup sudo shutdown -r now >/dev/null 2>&1 &
disown
exit 0
