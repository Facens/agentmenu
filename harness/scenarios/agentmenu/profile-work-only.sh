#!/bin/bash
# HARNESS_STRANGER_ONLY: ticks a setup-card folder toggle and clicks Done by
# AXIdentifier, and screenshots the popover — screen-driving work this
# harness confines to the stranger tier (harness/README.md, "Only the
# stranger tier drives the screen").
#
# R9's single-account first run: the same vanilla machine
# vanilla-first-run.sh describes, plus one already-configured Claude Code
# account directory, ~/.claude-work/settings.json, carrying "model" and
# "advisorModel" (Resources/agents/claude-code.toml names these two exact
# keys as model.seed_from_settings / advisor.seed_from_settings).
# Detection.profiles (Sources/AgentMenu/Setup/Detection.swift) finds exactly
# one profile from it, "work", and AppEnvironment.seedIfMissing seeds the
# global default preset from that one account's own settings (R11: "start on
# the values already in use"). With one profile, the popover's account
# switcher stays hidden (`PopoverModel.showsProfileSwitch`, "R16: most
# machines have exactly one, and then there is nothing to ask"), so this run
# has nothing profile-specific left to click beyond the ordinary setup flow
# — it is the single-account control case profile-both.sh is compared
# against.
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:?profile-work-only.sh must be run by harness/run.sh, which exports HARNESS_DIR.}"
. "$HARNESS_DIR/lib/scenario.sh"
. "$HARNESS_DIR/lib/fixtures.sh"
. "$HARNESS_DIR/fixtures/agentmenu/_lib.sh"

BUNDLE_ID="$AGENTMENU_BUNDLE_ID"

if [ -z "${HARNESS_ASSET:-}" ]; then
    verdict fail "no --asset was given; the stranger tier installs the release zip, not a local build."
fi

step "fixture"
fixture agentmenu/first-run "$HARNESS_NONCE" --profile work:opus:sonnet

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
