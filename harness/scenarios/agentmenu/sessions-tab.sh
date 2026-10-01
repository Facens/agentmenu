#!/bin/bash
# HARNESS_STRANGER_ONLY: opens the popover, switches to the Sessions tab and
# clicks a live row by AXIdentifier — screen-driving work this harness
# confines to the stranger tier (harness/README.md, "Only the stranger tier
# drives the screen").
#
# The session manager's first screen (U5): a user who already has a Claude
# Code session running somewhere opens the menu-bar item, sees Launch (the
# popover always opens on it, KTD16), switches to Sessions, and finds that
# session listed — in the Needs-you group, because it is waiting on a
# permission prompt.
#
# THE SESSION IS NOT A REAL CLAUDE CODE. The guest has none, and a real one
# would need an account, a network and a model. What the app actually reads
# is a registry file and a process table, and both can be made real without
# Claude Code: `_plant-session.sh` (beside this scenario's fixtures, run in the
# guest) starts an idle `sleep` and writes
# `~/.claude-work/sessions/<pid>.json` for it, with `procStart` taken from
# `ps -o lstart=` under TZ=UTC (the spelling `RegistryReader` compares), so
# the reader's liveness check (KTD7) passes for the same reason it would for
# a real session. Nothing about the row is faked inside the app: it goes
# through the same reader, snapshot and view as any other.
#
# The row's identifier is not predicted here. Its key is a hash of (config
# directory, pid, process start) and the pid is only known to the guest, so
# the scenario takes the key from the `session seen` journal event instead —
# which carries the very hash the row's identifier is built from
# (`AccessibilityID.Popover.Sessions.liveRowKey`) — and builds the identifier
# from that.
#
# What the scenario asserts, and what it observes each through:
#   - the app found the session, as Needs you: `session seen`, from the raw
#     live list (before any grouping or badge work);
#   - the menu-bar badge drew it: `badge changed count=1`, which
#     `StatusItemController` journals from the badge it actually built;
#   - the Needs-you group is on screen: its heading carries
#     `popover.sessions.group.needsYou`. Only that group has an identifier
#     (every other group is a folder, and a folder's name is a path), and this
#     is the only session, so the row below cannot be in a folder group: a
#     waiting row is listed once, under Needs you, and nowhere else. The
#     harness's accessibility driver can list identifiers but nothing in its
#     public vocabulary compares their positions, so "the row sits under the
#     heading" is this argument plus the layout's unit test, not a
#     containment query;
#   - a click on the row runs the real focus (U6): `SessionsModel.focus` ->
#     `focusLive`, which journals `focus result`. The planted `sleep` was
#     started over ssh without a pty, so it has no controlling terminal and
#     the only honest answer is `outcome=unavailable reason=noTTY`; a focus
#     that "worked" on it would be a bug. No terminal is asked anything.
#
# The fixture is `configured-terminal`, for the same reasons launch-terminal
# uses it: a configured user (one account, `work`, at `~/.claude-work`, and one
# launch folder), no setup card, and keep-running pinned off. The session's
# working directory is that launch folder, which keeps it out of any "other
# folders" heading should it ever stop waiting.
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:?sessions-tab.sh must be run by harness/run.sh, which exports HARNESS_DIR.}"
. "$HARNESS_DIR/lib/scenario.sh"
. "$HARNESS_DIR/lib/fixtures.sh"
. "$HARNESS_DIR/fixtures/agentmenu/_lib.sh"

BUNDLE_ID="$AGENTMENU_BUNDLE_ID"
# A lowercase UUID: the only spelling a session id may have.
SESSION_ID="5d1c7e0a-3b6e-4d7a-9c21-0e0b7a4d1f33"
PLANT="~/$HARNESS_GUEST_HOME/fixtures/agentmenu/_plant-session.sh"

if [ -z "${HARNESS_ASSET:-}" ]; then
    verdict fail "no --asset was given; the stranger tier installs the release zip, not a local build."
fi

step "fixture"
fixture agentmenu/configured-terminal "$HARNESS_NONCE"

step "live session"
# After the fixture (it writes the profile directory) and before the app is
# installed, so the first thing the app ever reads is a running session.
# The launch folder's name carries an apostrophe (see _lib.sh), so it is
# single-quoted for the guest's shell the way scenario.sh's own
# `_scenario_quote` does it: each ' becomes '\''.
# (The substitution has to stay unquoted on the right-hand side, as there.)
CWD_LEAF_QUOTED=${AGENTMENU_HARD_PATH_LEAF//\'/\'\\\'\'}
CWD_LEAF_QUOTED="'$CWD_LEAF_QUOTED'"
SESSION_PID="$(fixtures_guest_capture "$HARNESS_STEP_TIMEOUT" "bash $PLANT '$SESSION_ID' .claude-work $CWD_LEAF_QUOTED")"
case "$SESSION_PID" in
    ''|*[!0-9]*) verdict fail "the guest did not report a pid for the planted session (got '$SESSION_PID')." ;;
esac
log "planted a live session: pid $SESSION_PID in ~/.claude-work"

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
# Answered before the popover opens, for launch-terminal's reason: TCC shows
# one consent sheet at a time, AgentMenu asks Finder at launch, and a sheet
# left on screen covers the popover in this scenario's own screenshots.
# Bounded and optional — a machine that has already granted it raises nothing.
FINDER_MATCH='control finder'
FINDER_WAIT="$(dialog wait automation 30 --text "$FINDER_MATCH")"
if [ "$(printf '%s' "$FINDER_WAIT" | jq -r '.present')" = "true" ]; then
    dialog answer automation allow --text "$FINDER_MATCH" > /dev/null
    log "answered the Automation prompt for Finder, so it is not sitting over the popover"
else
    log "no Automation prompt for Finder appeared (already granted)"
fi

step "session seen"
# The app's own report that it found the session, with the hashed key the
# row's identifier carries. `status=needsYou` is the registry's `waiting` /
# `permission prompt` read through the status mapping.
SEEN_LINE="$(expect_event "session seen" agent=claude-code profile=work status=needsYou)"
ROW_KEY="$(printf '%s' "$SEEN_LINE" | jq -r '.data.key // empty')"
case "$ROW_KEY" in
    ????????????) ;;
    *) verdict fail "'session seen' carried no 12-character row key (got '$ROW_KEY')." ;;
esac
log "the app saw the session: row key $ROW_KEY"

step "badge"
# The item the user looks at while in another window. `count=1` is the one
# waiting session; the first reading (0, nothing listed yet) may come before
# it, and this waits for the line that says 1.
expect_event "badge changed" count=1 > /dev/null

step "open popover"
open_status_item "$BUNDLE_ID"
shot "popover-launch" > /dev/null

step "sessions tab"
click "$BUNDLE_ID" "popover.tab.sessions"

step "needs-you group"
# The heading of the group a waiting session belongs in. Waited for, not
# pressed: it is text.
agentmenu_wait_for_identifier "$BUNDLE_ID" "popover.sessions.group.needsYou"

step "live row"
# `click` waits, bounded, for the identifier to exist before pressing it, so
# this is also the assertion that the row is on screen.
click "$BUNDLE_ID" "popover.sessions.live.$ROW_KEY.row"
shot "sessions-live" > /dev/null

step "focus"
# The click's own outcome, for this row: nothing to bring forward, because
# the session has no terminal.
expect_event "focus result" key="$ROW_KEY" outcome=unavailable reason=noTTY ok=false > /dev/null

step "cleanup"
# Best effort: the guest is discarded with the process in it, but a run that
# is pointed at a machine it does not discard should not leave one behind.
fixtures_guest_capture "$HARNESS_STEP_TIMEOUT" "kill $SESSION_PID 2>/dev/null || true" > /dev/null

verdict pass
