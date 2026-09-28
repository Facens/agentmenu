#!/bin/bash
# HARNESS_STRANGER_ONLY: waits for AgentMenu's own "launch at login?" alert
# and answers it by process and text, never by AXIdentifier — screen-driving
# work this harness confines to the stranger tier (harness/README.md, "Only
# the stranger tier drives the screen").
#
# The plan's own ask: a scenario that proves the prompt appears at all, and
# that accepting it registers the login item. Covers the path a fresh
# install never takes — `LaunchAtLoginPrompt.presentIfNeeded`
# (Sources/AgentMenu/Support/LaunchAtLoginPrompt.swift), for an install
# whose config.toml already carried `first_run_completed = true` from
# before this question existed (`agentmenu/needs-login-prompt`'s own
# comment). A fresh first run's answer to the same question is the setup
# card's own checkbox instead — see vanilla-first-run.sh's "launch at
# login" step.
#
# This alert is answered exactly the way ProfilesPane.installBridge's
# confirmation alert already is in bridge-install.sh: `dialogs.applescript`'s
# `alert` kind makes no assumption about process, wording or title — an
# app's own alert has none of those fixed — so it falls back to the
# frontmost process's front window, which is wrong here twice over.
# AgentMenu raises this with `NSAlert.runModal()` without becoming the
# frontmost application (it is LSUIElement), so `--process` names it
# explicitly; and `--text` picks it out from whatever else might be on
# screen. Docs/releasing.md's own warning about this fallback — the
# UNNAMED case takes the LAST button, which was "Skip This Version" on
# Sparkle's four-button update window, not the affirmative one — is why
# `--process`/`--text` are never left out here: named, the match is by
# button title/position within THIS alert's own two buttons (Launch at
# Login, added first and default; Not Now, added second), the same
# Install/Cancel shape bridge-install.sh already proved answers `allow`
# correctly.
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:?launch-at-login-prompt.sh must be run by harness/run.sh, which exports HARNESS_DIR.}"
. "$HARNESS_DIR/lib/scenario.sh"
. "$HARNESS_DIR/lib/fixtures.sh"
. "$HARNESS_DIR/fixtures/agentmenu/_lib.sh"

BUNDLE_ID="$AGENTMENU_BUNDLE_ID"

if [ -z "${HARNESS_ASSET:-}" ]; then
    verdict fail "no --asset was given; the stranger tier installs the release zip, not a local build."
fi

step "fixture"
fixture agentmenu/needs-login-prompt "$HARNESS_NONCE"

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

step "login item prompt"
ALERT_PROCESS='AgentMenu'
ALERT_MATCH='login'
ALERT_WAIT="$(dialog wait alert 30 --process "$ALERT_PROCESS" --text "$ALERT_MATCH")"
if [ "$(printf '%s' "$ALERT_WAIT" | jq -r '.present')" != "true" ]; then
    verdict fail "the launch-at-login prompt never appeared for an existing install that had not been asked."
fi
shot "login-item-prompt" > /dev/null
# By identifier, never `dialog answer alert allow`. That helper matches the
# alert kind by no button name, so it falls back to position and presses
# the LAST button. The bridge-install alert lays Install and Cancel out side
# by side, where the last button is Install; this one stacks its two longer
# titles vertically, where the last button is Not Now. The first gate run
# (v0.2.2-beta.1) pressed exactly that and recorded enabled=false. The
# buttons carry AXIdentifiers, and an NSAlert is a window of the app's own
# process, so click reaches them the way it reaches every other control.
click "$BUNDLE_ID" "launchAtLoginPrompt.accept"
log "the launch-at-login prompt was answered Launch at Login"

step "asked and registered"
# `enabled` is read straight off `SMAppService.mainApp.status` by
# `LaunchAtLogin.isEnabled` at the moment the journal tap fires, not
# inferred from which button was clicked — the same "re-read, don't trust
# the click" rule `SettingsModel.launchAtLogin` already follows, so this is
# the app's own account of whether the login item actually registered, not
# a narration of the click.
RESULT_LINE="$(expect_event "launch at login asked" enabled=true)"
log "launch at login asked: $(printf '%s' "$RESULT_LINE" | jq -c '.data')"

verdict pass
