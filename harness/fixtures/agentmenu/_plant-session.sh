#!/bin/bash
# Guest-side helper, not a fixture: starts one real, idle process and writes
# the Claude Code registry file that describes it, so the Sessions tab has a
# live session to list without a real Claude Code being installed, signed in
# or billed in the guest.
#
#   _plant-session.sh <session-id> <config-dir-under-HOME> <cwd-under-HOME> [seconds]
#
# It lives beside `_lib.sh` rather than under a fixture directory on purpose:
# Tests/AgentMenuKitTests/HarnessFixtureTests.swift discovers every
# `<name>/apply.sh` and runs each one on whatever machine is running the test
# suite, and a fixture that starts a process would leave one behind there. A
# scenario runs this explicitly, in the guest, after its fixture has written
# the configuration; the guest is thrown away with the process in it.
#
# What makes the registry file believable to `RegistryReader` (KTD7, KTD8):
#   - `pid` is a process that is running, and the file is named `<pid>.json`;
#   - `procStart` is that process's start time as `ps -o lstart=` prints it
#     under TZ=UTC — the reader parses the string as UTC and compares the
#     instant, so a local-time spelling would be hours off and the row would
#     be rejected as a stranger that reused the pid;
#   - `entrypoint` is `cli` and `kind` is `interactive`, the two values that
#     make a row a session at all;
#   - `sessionId` is a lowercase UUID, the only spelling the restore guard and
#     a resume will accept (`SessionIdentifier`).
# Status is `waiting` for a `permission prompt`, which maps to Needs you, so
# the session shows up in the Needs-you group and the menu-bar badge.
#
# `seconds` is how long the process lives (default 3600, the length of a run
# with room to spare). The fixture test passes a short one, so a suite that
# is interrupted before it can kill the process leaves nothing behind for
# an hour.
#
# Prints the pid, and nothing else, on stdout. Every value is synthetic.
set -euo pipefail

SESSION_ID="${1:?_plant-session.sh requires a session id.}"
CONFIG_LEAF="${2:?_plant-session.sh requires the config directory, relative to HOME.}"
CWD_LEAF="${3:?_plant-session.sh requires the working directory, relative to HOME.}"
LIFETIME="${4:-3600}"

SESSIONS_DIR="$HOME/$CONFIG_LEAF/sessions"
mkdir -p "$SESSIONS_DIR"

# A process that stays alive for the length of a run and then goes away on its
# own. Every descriptor is redirected: over ssh the session does not end while
# a child still holds its stdout, and the caller would wait out its bound.
nohup sleep "$LIFETIME" < /dev/null > /dev/null 2>&1 &
PID=$!
disown "$PID" 2> /dev/null || true

# `lstart` is whole seconds, the kernel's start time is finer; the reader
# allows a second of difference for exactly that.
PROC_START="$(TZ=UTC LC_ALL=C ps -o lstart= -p "$PID" | sed -e 's/^ *//' -e 's/ *$//')"
if [ -z "$PROC_START" ]; then
    echo "error: the planted process $PID is already gone." >&2
    exit 1
fi

NOW_MS=$(( $(date +%s) * 1000 ))
TMP="$SESSIONS_DIR/.$PID.json.tmp"
# Written beside the real name and moved into place, so a reader never sees
# half a file — the app watches this directory.
cat > "$TMP" <<JSON
{
  "pid": $PID,
  "sessionId": "$SESSION_ID",
  "cwd": "$HOME/$CWD_LEAF",
  "startedAt": $NOW_MS,
  "procStart": "$PROC_START",
  "version": "2.1.285",
  "kind": "interactive",
  "entrypoint": "cli",
  "name": "Harness session",
  "status": "waiting",
  "waitingFor": "permission prompt",
  "updatedAt": $NOW_MS,
  "statusUpdatedAt": $NOW_MS
}
JSON
mv "$TMP" "$SESSIONS_DIR/$PID.json"

printf '%s\n' "$PID"
