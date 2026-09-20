#!/bin/bash
# HARNESS_STRANGER_ONLY: clicks a popover row's launch control by
# AXIdentifier and screenshots Terminal.app's window — screen-driving work
# this harness confines to the stranger tier (harness/README.md, "Only the
# stranger tier drives the screen").
#
# R9's configured launch: a user who has already been through first run —
# firstRunCompleted true, one account, one project folder, Terminal.app
# trusted and enabled by a user overlay (agentmenu/configured-terminal's own
# header explains why the fixture seeds every one of these directly rather
# than clicking through setup and Settings first: it keeps this scenario
# about the launch itself). They open the menu-bar item, click the folder's
# launch control, macOS asks AgentMenu's first-ever permission to drive
# Terminal.app, and the row starts a real Claude Code session in a real
# Terminal window.
#
# Stated end state: `launch requested` fires with the working directory and
# no environment *values* (KTD3 — only variable names are ever journalled),
# then `launch result` reports whether the terminal actually took it. This
# scenario reads that field rather than assuming success (the plan's own
# Error test case: an Automation prompt answered Don't Allow reports
# `launch result` -1743 as a scenario fail, with the dialog screenshot
# already attached as the failing step's evidence) — R17 forbids asserting
# on the window's own title, so the proof that it names the right directory
# is the screenshot, never a match.
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:?launch-terminal.sh must be run by harness/run.sh, which exports HARNESS_DIR.}"
. "$HARNESS_DIR/lib/scenario.sh"
. "$HARNESS_DIR/lib/fixtures.sh"
. "$HARNESS_DIR/fixtures/agentmenu/_lib.sh"

BUNDLE_ID="$AGENTMENU_BUNDLE_ID"
FOLDER_ID="harness-checkout"
CLI_PATH="/Applications/AgentMenu.app/Contents/Resources/bin/agentmenu"

if [ -z "${HARNESS_ASSET:-}" ]; then
    verdict fail "no --asset was given; the stranger tier installs the release zip, not a local build."
fi

step "fixture"
fixture agentmenu/configured-terminal "$HARNESS_NONCE"

step "fixture check"
# The plan's own Fixture test case: the seeded config.toml, the user's
# terminal-app.toml overlay and its "trusted" bit have to already resolve
# Terminal.app to available before this scenario ever clicks anything — the
# same JSON shape `agentmenu dump-state` (Sources/AgentMenuCLI/DumpStateCommand.swift)
# prints for a harness comparison, read here directly rather than inferred
# from a click succeeding or failing.
DUMP_STATE="$(fixtures_guest_capture "$HARNESS_STEP_TIMEOUT" "$CLI_PATH dump-state")"
TERMINAL_AVAILABILITY="$(printf '%s' "$DUMP_STATE" | jq -r '.terminals[] | select(.id == "terminal-app") | .availability')"
if [ "$TERMINAL_AVAILABILITY" != "available" ]; then
    verdict fail "the fixture alone does not resolve terminal-app to available (dump-state says '$TERMINAL_AVAILABILITY'); see the failing step, no click was attempted."
fi
log "dump-state confirms terminal-app is available before any click"

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

step "launch"
wait_for_status_item "$BUNDLE_ID" > /dev/null
journal_at "$BUNDLE_ID" "$AGENTMENU_JOURNAL_LEAF"

step "open popover"
# firstRunCompleted and a real project folder are both already seeded, so
# SetupModel.isNeeded is false and the popover opens straight on the normal
# launcher rows — no setup card, no detection pass to wait on.
open_status_item "$BUNDLE_ID"
ROW_HASH="$(fixtures_path_hash "$FOLDER_ID")"
shot "popover" > /dev/null

step "click launch"
click "$BUNDLE_ID" "popover.row.$ROW_HASH.launch"
expect_event "launch requested" target="folder:$FOLDER_ID" kind=agent > /dev/null

step "automation prompt"
AUTOMATION_WAIT="$(dialog wait automation)"
if [ "$(printf '%s' "$AUTOMATION_WAIT" | jq -r '.present')" = "true" ]; then
    shot "automation-prompt" > /dev/null
    dialog answer automation allow > /dev/null
    log "the Automation prompt for Terminal.app was answered OK"
else
    log "no Automation prompt appeared (already granted)"
fi

step "launch result"
RESULT_LINE="$(expect_event "launch result" target="folder:$FOLDER_ID")"
OK="$(printf '%s' "$RESULT_LINE" | jq -r '.data.ok')"
if [ "$OK" != "true" ]; then
    ERROR="$(printf '%s' "$RESULT_LINE" | jq -r '.data.error // "no error text"')"
    verdict fail "launch result reported failure: $ERROR"
fi
log "launch result: ok"

step "terminal window"
if [ "$(ax_window_count com.apple.Terminal)" -gt 0 ]; then
    shot "terminal-window" > /dev/null
else
    log "Terminal.app reports no windows yet — capturing whatever is on screen anyway"
    shot "terminal-window" > /dev/null
fi

verdict pass
