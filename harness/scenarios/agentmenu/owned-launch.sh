#!/bin/bash
# HARNESS_STRANGER_ONLY: clicks a popover row's launch control by
# AXIdentifier, closes a Terminal.app window and screenshots it — screen-driving
# work this harness confines to the stranger tier (harness/README.md, "Only the
# stranger tier drives the screen").
#
# The hosted launch (session manager U11, KTD2, KTD16): with "keep running"
# on, AgentMenu does not type the agent's command into a terminal. It starts
# the session in its own bundled tmux server (the "session host", socket
# `<host dir>/s`), then opens a terminal window whose command only attaches to
# that session. Closing the window therefore detaches a client and nothing
# else: the session, and the agent in it, keep running. That is the property
# this scenario proves on a real machine, end to end.
#
# The fixture is `owned-session`: configured-terminal's twin with
# `keep_running = true`, so this scenario is launch-terminal's with the host
# turned on and the same click-free setup (no setup card, Terminal trusted,
# every first-run question already answered).
#
# WHAT IT CAN OBSERVE WITHOUT A LOGGED-IN CLAUDE. The guest's Claude Code is
# not signed in, so it never writes a registry file and the session never
# registers. Everything below is therefore read from the two things that are
# real regardless of an account: the app's own journal and the tmux server the
# app started, which the scenario asks directly with the helper copy the app
# installed next to its socket (`.../host/3.7c/tmux -S .../host/3.7c/s`) — only
# ever that one socket, so no other tmux is reached.
#   1. the app says the host created the session: `host launch`, with the
#      terminal and ok=true (the payload carries a hashed key, never a path or
#      an argv);
#   2. the hosted tmux session exists, and is named by exactly one lowercase
#      UUID (the launch id, which is also the agent's pinned session id);
#   3. a client is attached to it, and Terminal.app has a window: the window
#      Terminal opened is that attach client;
#   4. the window is closed the way a person would close it, and afterwards the
#      session is STILL there and no client is attached any more: the session
#      outlived its window, detached.
#
# WHAT IT CANNOT OBSERVE, and does not claim to: the Starting-to-Live
# registration (it needs a registry row, which needs a signed-in Claude), the
# status read from it, and the Detached marker on a Sessions row (a row only
# shows once the agent has registered). Those are covered at Kit level
# (SessionStore, SessionsPresentation and the launch ledger's tests).
#
# CLOSING THE WINDOW. The harness's public vocabulary has no verb for it, and
# Terminal's windows carry no AXIdentifier, so this runs one short AppleScript
# in the guest through the existing guest-exec path. It goes through System
# Events (the grant every other driver in harness/guest/ already relies on)
# and presses the window's own close button, rather than `tell application
# "Terminal"`: that would raise a first-ever Automation prompt for whichever
# process ssh started osascript under, and nothing here could answer it.
# Terminal does not ask before closing a window whose foreground process is
# named `tmux` (the attach client is installed under that name for exactly this
# reason), so no confirmation sheet is expected. If one appears anyway it is
# answered, bounded and optional; closing the window by killing the client
# still leaves the session running, so the assertions below hold either way.
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:?owned-launch.sh must be run by harness/run.sh, which exports HARNESS_DIR.}"
. "$HARNESS_DIR/lib/scenario.sh"
. "$HARNESS_DIR/lib/fixtures.sh"
. "$HARNESS_DIR/fixtures/agentmenu/_lib.sh"

BUNDLE_ID="$AGENTMENU_BUNDLE_ID"
FOLDER_ID="harness-checkout"

# The host directory the app uses with no override: bundle id, then the tmux
# version the bundle ships (SessionHostLocation.defaultHelperVersion). The
# `$HOME` stays literal here and is expanded by the guest's own shell, inside
# double quotes, because the path holds a space ("Application Support").
HOST_DIR='$HOME/Library/Application Support/'"$AGENTMENU_BUNDLE_ID"'/host/3.7c'

if [ -z "${HARNESS_ASSET:-}" ]; then
    verdict fail "no --asset was given; the stranger tier installs the release zip, not a local build."
fi

# host_tmux <tmux arguments, as one string>
#
# Runs the app's own helper copy against the app's own socket, in the guest,
# and prints what it says. Always ends the guest command with `true`: tmux
# exits non-zero when there is no server, and that has to read as "no
# sessions" for this scenario to fail on, not as a harness error.
host_tmux() {
    fixtures_guest_capture "$HARNESS_STEP_TIMEOUT" "\"$HOST_DIR/tmux\" -S \"$HOST_DIR/s\" $* 2>/dev/null; true"
}

# count_lines <text>: the number of non-empty lines.
count_lines() {
    printf '%s\n' "$1" | grep -c . || true
}

# wait_for_clients <count> <seconds>
#
# Polls the host's attached-client count until it is <count> or the time is
# up. Leaves the last count it read in $CLIENTS.
CLIENTS=-1
wait_for_clients() {
    local want="$1" bound="$2" deadline
    deadline=$((SECONDS + bound))
    while :; do
        CLIENTS="$(count_lines "$(host_tmux "list-clients -F '#{client_name}'")")"
        if [ "$CLIENTS" -eq "$want" ]; then
            return 0
        fi
        if [ "$SECONDS" -ge "$deadline" ]; then
            return 1
        fi
        sleep 1
    done
}

# One AppleScript, one `-e` per line, in the guest. Presses the close button
# of the front Terminal window, a few times so that every window goes, and
# never fails the guest command: whether it worked is read from the tmux
# client count afterwards, not from this.
CLOSE_TERMINAL_WINDOWS="osascript"
for line in \
    'tell application "System Events"' \
    'tell process "Terminal"' \
    'repeat 5 times' \
    'try' \
    'click (first button of window 1 whose subrole is "AXCloseButton")' \
    'end try' \
    'delay 0.5' \
    'end repeat' \
    'end tell' \
    'end tell'; do
    CLOSE_TERMINAL_WINDOWS="$CLOSE_TERMINAL_WINDOWS -e '$line'"
done

step "fixture"
fixture agentmenu/owned-session "$HARNESS_NONCE"

step "install"
INSTALL_JSON="$(install_app AgentMenu)"
log "installed: $(printf '%s' "$INSTALL_JSON" | jq -c '.')"

step "gatekeeper"
GATE_WAIT="$(dialog wait gatekeeper)"
if [ "$(printf '%s' "$GATE_WAIT" | jq -r '.present')" = "true" ]; then
    shot "gatekeeper-prompt" > /dev/null
    dialog answer gatekeeper allow > /dev/null
    log "gatekeeper prompted; answered allow (the dialog helper logs which button that pressed)"
else
    log "gatekeeper did not prompt (no quarantine attribute, or already cleared)"
fi
# Finder clears the quarantine flag when a person answers Open; `mv` from a
# shell does not, so without this the app keeps running translocated.
clear_quarantine AgentMenu

step "launch"
wait_for_status_item "$BUNDLE_ID" > /dev/null
journal_at "$BUNDLE_ID" "$AGENTMENU_JOURNAL_LEAF"

step "finder automation prompt"
# Answered before the terminal is ever asked for, for launch-terminal's
# reason: TCC shows one consent sheet at a time, AgentMenu asks Finder at
# launch, and the terminal's own prompt queues invisibly behind it. Bounded
# and optional — a machine that has already granted it raises nothing.
FINDER_MATCH='control finder'
FINDER_WAIT="$(dialog wait automation 30 --text "$FINDER_MATCH")"
if [ "$(printf '%s' "$FINDER_WAIT" | jq -r '.present')" = "true" ]; then
    dialog answer automation allow --text "$FINDER_MATCH" > /dev/null
    log "answered the Automation prompt for Finder, so the terminal's own can be raised"
else
    log "no Automation prompt for Finder appeared (already granted)"
fi

step "open popover"
open_status_item "$BUNDLE_ID"
ROW_HASH="$(fixtures_path_hash "$FOLDER_ID")"
shot "popover" > /dev/null

step "click launch"
click "$BUNDLE_ID" "popover.row.$ROW_HASH.launch"
expect_event "launch requested" target="folder:$FOLDER_ID" kind=agent > /dev/null

step "automation prompt"
# Named, not just "an automation prompt": see launch-terminal.sh for why the
# unnamed wait answers Finder's instead.
AUTOMATION_MATCH='control terminal'
AUTOMATION_WAIT="$(dialog wait automation --text "$AUTOMATION_MATCH")"
if [ "$(printf '%s' "$AUTOMATION_WAIT" | jq -r '.present')" = "true" ]; then
    shot "automation-prompt" > /dev/null
    dialog answer automation allow --text "$AUTOMATION_MATCH" > /dev/null
    log "the Automation prompt for Terminal.app was answered OK"
else
    log "no Automation prompt for the terminal appeared (already granted)"
fi

step "launch result"
RESULT_LINE="$(expect_event "launch result" target="folder:$FOLDER_ID")"
OK="$(printf '%s' "$RESULT_LINE" | jq -r '.data.ok')"
if [ "$OK" != "true" ]; then
    ERROR="$(printf '%s' "$RESULT_LINE" | jq -r '.data.error // "no error text"')"
    verdict fail "launch result reported failure: $ERROR"
fi
log "launch result: ok"

step "host launch"
# The app's own report that its host created the session. Read after the
# launch result, which is correct whichever order the app writes the two in:
# the journal is re-read whole on every poll, so a line already there is
# found. The key is a hash (never the launch id itself, a path or an argv);
# only its length is checked.
HOST_LINE="$(expect_event "host launch" terminal=terminal-app ok=true)"
HOST_KEY="$(printf '%s' "$HOST_LINE" | jq -r '.data.launch // empty')"
case "$HOST_KEY" in
    ????????????) ;;
    *) verdict fail "'host launch' carried no 12-character launch key (got '$HOST_KEY')." ;;
esac
log "the host created the session: launch key $HOST_KEY"

step "hosted session"
# The session the host created, named by the launch id: exactly one, and a
# lowercase UUID. Read from tmux itself, not inferred from the journal.
SESSIONS="$(host_tmux "list-sessions -F '#{session_name}'")"
if [ "$(count_lines "$SESSIONS")" -ne 1 ]; then
    verdict fail "expected exactly one hosted tmux session, found: '$SESSIONS'."
fi
SESSION_NAME="$(printf '%s' "$SESSIONS" | head -n 1)"
UUID_PATTERN='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
if ! [[ "$SESSION_NAME" =~ $UUID_PATTERN ]]; then
    verdict fail "the hosted session is not named by a lowercase UUID (got '$SESSION_NAME')."
fi
log "the hosted tmux session exists: $SESSION_NAME"

step "attached client"
# Terminal's window is the attach client. Polled, because the window opens a
# moment after the launch result.
if ! wait_for_clients 1 "$HARNESS_STEP_TIMEOUT"; then
    shot "no-attached-client" > /dev/null
    verdict fail "expected one client attached to the hosted session, found $CLIENTS."
fi
log "one client is attached to the session"

step "terminal window"
# Evidence for the screenshot, and a sanity check beside the attached client
# above (which is what proves the attach actually ran). scenario.sh's
# ax_window_count reports zero for anything it cannot read, so a failure here
# is "Terminal shows no window", never a harness error.
TERMINAL_WINDOWS="$(ax_window_count com.apple.Terminal)"
log "Terminal.app reports $TERMINAL_WINDOWS window(s)"
shot "terminal-window" > /dev/null
if [ "$TERMINAL_WINDOWS" -le 0 ]; then
    verdict fail "Terminal.app reports no window while a client is attached to the hosted session."
fi

step "close window"
fixtures_guest_capture "$HARNESS_STEP_TIMEOUT" "$CLOSE_TERMINAL_WINDOWS 2>&1; true" > /dev/null
# Closing a window that runs `tmux` is not expected to ask anything. If
# something did, answer it (bounded, optional) and let the client go.
if ! wait_for_clients 0 15; then
    SHEET_WAIT="$(dialog wait alert 5 --process Terminal)"
    if [ "$(printf '%s' "$SHEET_WAIT" | jq -r '.present')" = "true" ]; then
        shot "close-confirmation" > /dev/null
        dialog answer alert allow --process Terminal > /dev/null
        log "Terminal asked before closing the window; answered it"
    else
        log "no confirmation sheet appeared"
    fi
fi

step "detached"
# The client is gone because its window is gone...
if ! wait_for_clients 0 "$HARNESS_STEP_TIMEOUT"; then
    shot "still-attached" > /dev/null
    verdict fail "closing the Terminal window did not detach the client ($CLIENTS still attached)."
fi
log "no client is attached any more"
shot "window-closed" > /dev/null
log "Terminal.app reports $(ax_window_count com.apple.Terminal) window(s) after the close"

step "session survives"
# ...and the session is not. This is the whole point of the hosted launch:
# the agent keeps running with nothing attached to it.
SESSIONS_AFTER="$(host_tmux "list-sessions -F '#{session_name}'")"
if [ "$SESSIONS_AFTER" != "$SESSION_NAME" ]; then
    verdict fail "the hosted session did not survive its window: expected '$SESSION_NAME', found '$SESSIONS_AFTER'."
fi
log "the session $SESSION_NAME is still running, detached"

verdict pass
