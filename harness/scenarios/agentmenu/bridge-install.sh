#!/bin/bash
# HARNESS_STRANGER_ONLY: clicks the popover's gear, a Settings tab and the
# bridge-install control by AXIdentifier, and answers a native alert —
# screen-driving work this harness confines to the stranger tier
# (harness/README.md, "Only the stranger tier drives the screen").
#
# R9's status-line bridge install: a configured user (one account,
# firstRunCompleted true — no folder or agent needed, this scenario never
# launches anything) opens Settings from the popover's gear, lands on the
# Accounts tab, and clicks "Install status-line bridge…" for the one
# account already selected (`SettingsModel` selects
# `config.profiles.first?.id` the moment it is constructed,
# Sources/AgentMenu/Settings/SettingsModel.swift, so there is no row to
# click first). ProfilesPane.swift's own `installBridge(index:)` raises a
# real native NSAlert naming the exact files it is about to write before it
# ever calls into the CLI (R47) — this scenario answers it, then reads what
# actually got written off the journal rather than assuming the two
# filenames the CLI happens to write today.
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:?bridge-install.sh must be run by harness/run.sh, which exports HARNESS_DIR.}"
. "$HARNESS_DIR/lib/scenario.sh"
. "$HARNESS_DIR/lib/fixtures.sh"
. "$HARNESS_DIR/fixtures/agentmenu/_lib.sh"

BUNDLE_ID="$AGENTMENU_BUNDLE_ID"

if [ -z "${HARNESS_ASSET:-}" ]; then
    verdict fail "no --asset was given; the stranger tier installs the release zip, not a local build."
fi

step "fixture"
fixture agentmenu/configured-profile "$HARNESS_NONCE"

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
# Cleared for the evidence, not for the verdict. This scenario proves the
# install by reading `bridge installed` out of the journal, so the sheet
# cannot change the result — but `docs/releasing.md`'s checklist asks a human
# to open this run's screenshots before the release is published, and in the
# v0.2.0-beta.3 gate `004-bridge-report.png` showed AgentMenu's Finder
# Automation prompt sitting over the bridge report it was taken to show.
# Evidence nobody can read is not evidence.
#
# Bounded and optional, the same shape launch-terminal uses: a machine that
# has already granted Finder control raises nothing here.
FINDER_MATCH='control finder'
FINDER_WAIT="$(dialog wait automation 30 --text "$FINDER_MATCH")"
if [ "$(printf '%s' "$FINDER_WAIT" | jq -r '.present')" = "true" ]; then
    dialog answer automation allow --text "$FINDER_MATCH" > /dev/null
    log "answered the Automation prompt for Finder, so it is not sitting over this run's screenshots"
else
    log "no Automation prompt for Finder appeared (already granted)"
fi

step "open settings"
open_status_item "$BUNDLE_ID"
click "$BUNDLE_ID" "popover.gear"

step "accounts tab"
click "$BUNDLE_ID" "settings.tab.accounts"
shot "accounts-pane" > /dev/null

step "install bridge"
click "$BUNDLE_ID" "settings.accounts.installBridge"

step "confirmation alert"
# Named twice over, by process and by text. The `alert` kind makes no
# assumption about process, wording or title -- an app's own alert has
# none that this driver could know -- so it falls back to the frontmost
# process's front window, and that is the wrong window here in two
# different ways: AgentMenu raises this one with `NSAlert.runModal()`
# without becoming the frontmost application (it is LSUIElement, and the
# click that raised it came through System Events), and AgentMenu's own
# front window is the Settings window the button lives in. Unnamed, the
# wait reported "never appeared" for 120s with the alert on screen
# (v0.2.0-beta.2 harness, 2026-09-21).
#
# The text is the alert's own first line (`ProfilesPane.installBridge`),
# and matching on it is what keeps this off the Settings window. R17
# forbids asserting on copy; this is not an assertion, it is an address —
# the scenario still proves the install happened by reading `bridge
# installed` out of the app's journal below.
ALERT_PROCESS='AgentMenu'
ALERT_MATCH='status-line bridge'
ALERT_WAIT="$(dialog wait alert --process "$ALERT_PROCESS" --text "$ALERT_MATCH")"
if [ "$(printf '%s' "$ALERT_WAIT" | jq -r '.present')" != "true" ]; then
    verdict fail "the status-line bridge's confirmation alert never appeared."
fi
shot "bridge-alert" > /dev/null
dialog answer alert allow --process "$ALERT_PROCESS" --text "$ALERT_MATCH" > /dev/null
log "the install confirmation alert was answered Install"

step "bridge installed"
RESULT_LINE="$(expect_event "bridge installed" ok=true)"
FILE_COUNT="$(printf '%s' "$RESULT_LINE" | jq -r '.data.file_count // 0')"
if [ "$FILE_COUNT" -lt 1 ]; then
    verdict fail "bridge installed reported ok=true but named $FILE_COUNT files — expected at least one."
fi
log "bridge installed named $FILE_COUNT file(s): $(printf '%s' "$RESULT_LINE" | jq -c '.data.files // []')"
shot "bridge-report" > /dev/null

verdict pass
