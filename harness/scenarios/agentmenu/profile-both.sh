#!/bin/bash
# HARNESS_STRANGER_ONLY: ticks a setup-card folder toggle, clicks Done and
# the popover's account switcher segments, all by AXIdentifier, and
# screenshots the popover — screen-driving work this harness confines to
# the stranger tier (harness/README.md, "Only the stranger tier drives the
# screen").
#
# R9's two-account first run: the same vanilla machine, with two
# already-configured Claude Code account directories, ~/.claude-work and
# ~/.claude-personal, each carrying its own "model"/"advisorModel"
# (Detection.profiles finds both; AppEnvironment.seedIfMissing seeds the
# global default from whichever sorts first, "personal"). With two
# profiles, `PopoverModel.showsProfileSwitch` is true and PopoverView draws
# a segmented control, one AXIdentifier per account
# (AccessibilityID.Popover.profile(_:), Sources/AgentMenuKit/Support/AccessibilityID.swift)
# — the one control this whole R9 suite has that a single-account machine
# never shows at all.
#
# Edge case (AE3): this run proves both accounts show up as two separate,
# independently addressable rows in that switcher — never asserting their
# displayed names (R17 forbids that), only that "work" and "personal" are
# each their own clickable control rather than one collapsed into the
# other.
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:?profile-both.sh must be run by harness/run.sh, which exports HARNESS_DIR.}"
. "$HARNESS_DIR/lib/scenario.sh"
. "$HARNESS_DIR/lib/fixtures.sh"
. "$HARNESS_DIR/fixtures/agentmenu/_lib.sh"

BUNDLE_ID="$AGENTMENU_BUNDLE_ID"

if [ -z "${HARNESS_ASSET:-}" ]; then
    verdict fail "no --asset was given; the stranger tier installs the release zip, not a local build."
fi

step "fixture"
fixture agentmenu/first-run "$HARNESS_NONCE" --profile work:opus:sonnet --profile personal:fable:opus

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
expect_event "harness started" profile_count=2 > /dev/null

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

step "account switcher"
click "$BUNDLE_ID" "popover.profile.work"
click "$BUNDLE_ID" "popover.profile.personal"
shot "account-switcher" > /dev/null
log "both work and personal are separately addressable rows in the switcher"

verdict pass
