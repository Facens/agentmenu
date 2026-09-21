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

step "install"
INSTALL_JSON="$(install_app AgentMenu)"
log "installed: $(printf '%s' "$INSTALL_JSON" | jq -c '.')"

step "fixture check"
# The plan's own Fixture test case: the seeded config.toml, the user's
# terminal-app.toml overlay and its "trusted" bit have to already resolve
# Terminal.app to available before this scenario ever clicks anything — the
# same JSON shape `agentmenu dump-state` (Sources/AgentMenuCLI/DumpStateCommand.swift)
# prints for a harness comparison, read here directly rather than inferred
# from a click succeeding or failing.
#
# After `install` and not before it, because the binary this reads through
# ships *inside* the bundle: until install_app has moved AgentMenu.app to
# /Applications there is no $CLI_PATH, and asking for one turned every run
# of this scenario into a harness error rather than a fixture verdict
# ("zsh:1: no such file or directory: ...Contents/Resources/bin/agentmenu",
# exit 127, v0.2.0-beta.2 gate). It is still "before this scenario ever
# clicks anything", and still the fixture alone: install.sh has asked
# LaunchServices to open the app, but Gatekeeper's sheet is unanswered
# until the next step, so no AgentMenu code has run and nothing has been
# written over the config.toml the fixture planted.
DUMP_STATE="$(fixtures_guest_capture "$HARNESS_STEP_TIMEOUT" "$CLI_PATH dump-state")"
TERMINAL_AVAILABILITY="$(printf '%s' "$DUMP_STATE" | jq -r '.terminals[] | select(.id == "terminal-app") | .availability')"
if [ "$TERMINAL_AVAILABILITY" != "available" ]; then
    verdict fail "the fixture alone does not resolve terminal-app to available (dump-state says '$TERMINAL_AVAILABILITY'); see the failing step, no click was attempted."
fi
log "dump-state confirms terminal-app is available before any click"

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
# Answered here, before the terminal is ever asked for, because TCC shows a
# client one consent sheet at a time: AgentMenu asks Finder at launch
# (`FinderTarget.warmUp()`), and while that sheet is unanswered the
# terminal's own request queues behind it invisibly. Measured 2026-09-21:
# with Finder's left on screen, the terminal's prompt did not appear for
# 116s, and the scenario's wait for it read as a hang.
#
# Bounded at 30s and optional, not required: a machine that has already
# granted Finder control raises nothing here, and that is a legitimate pass
# — this step clears a prompt out of the way, it does not assert one.
FINDER_MATCH='control finder'
FINDER_WAIT="$(dialog wait automation 30 --text "$FINDER_MATCH")"
if [ "$(printf '%s' "$FINDER_WAIT" | jq -r '.present')" = "true" ]; then
    dialog answer automation allow --text "$FINDER_MATCH" > /dev/null
    log "answered the Automation prompt for Finder, so the terminal's own can be raised"
else
    log "no Automation prompt for Finder appeared (already granted)"
fi

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
# Named, not just "an automation prompt": AgentMenu raises two on a first
# run. `FinderTarget.warmUp()` asks for Finder at launch, and this click
# asks for the terminal, and "wants access to control" is true of both --
# so the unnamed wait answered whichever was on screen first, which was
# Finder's, and this scenario then failed on the app's own honest report
# that "the terminal did not answer within 120 seconds" (v0.2.0-beta.2,
# 2026-09-21). `--text` requires the sentence that names the target app;
# the quote glyphs around it are stripped on both sides, so this reads as
# it would be spoken.
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

step "terminal window"
if [ "$(ax_window_count com.apple.Terminal)" -gt 0 ]; then
    shot "terminal-window" > /dev/null
else
    log "Terminal.app reports no windows yet — capturing whatever is on screen anyway"
    shot "terminal-window" > /dev/null
fi

verdict pass
