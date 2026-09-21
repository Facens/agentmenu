#!/bin/bash
# HARNESS_STRANGER_ONLY: ticks a setup-card folder toggle and clicks Done by
# AXIdentifier, and screenshots the popover — screen-driving work this
# harness confines to the stranger tier (harness/README.md, "Only the
# stranger tier drives the screen").
#
# R9's single-account first run, the "personal" permutation of
# profile-work-only.sh: the same vanilla machine, with one already-configured
# Claude Code account directory named "personal" instead of "work" —
# Detection.profiles derives the account id from the directory suffix
# (~/.claude-personal), never from a label the fixture chooses, so this is a
# genuinely different code path (a different string sorts, is slugged, and
# is displayed) rather than a copy of the same scenario with a find-and-
# replaced name. Same single-account expectation as profile-work-only.sh:
# with one profile, `PopoverModel.showsProfileSwitch` stays false (R16) and
# there is nothing profile-specific to click.
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:?profile-personal-only.sh must be run by harness/run.sh, which exports HARNESS_DIR.}"
. "$HARNESS_DIR/lib/scenario.sh"
. "$HARNESS_DIR/lib/fixtures.sh"
. "$HARNESS_DIR/fixtures/agentmenu/_lib.sh"

BUNDLE_ID="$AGENTMENU_BUNDLE_ID"

if [ -z "${HARNESS_ASSET:-}" ]; then
    verdict fail "no --asset was given; the stranger tier installs the release zip, not a local build."
fi

step "fixture"
fixture agentmenu/first-run "$HARNESS_NONCE" --profile personal:fable:opus

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
expect_event "harness started" profile_count=1 > /dev/null

step "open popover"
open_status_item "$BUNDLE_ID"
expect_event "detecting finished" > /dev/null
shot "setup-card" > /dev/null

step "choose folder"
GUEST_HOME="$(fixtures_guest_home)"
FOLDER_HASH="$(fixtures_path_hash "$GUEST_HOME/$AGENTMENU_CHECKOUT_LEAF")"
click "$BUNDLE_ID" "setup.folder.$FOLDER_HASH.toggle"
log "ticked the suggested folder at \$HOME/$AGENTMENU_CHECKOUT_LEAF"

step "finish setup"
click "$BUNDLE_ID" "setup.done"
expect_event "setup finished" has_project_folder=true folder_count=2 > /dev/null
shot "launcher" > /dev/null

verdict pass
