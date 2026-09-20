#!/bin/bash
# HARNESS_STRANGER_ONLY: ticks a setup-card folder toggle and clicks Done by
# AXIdentifier, and screenshots the popover — screen-driving work this
# harness confines to the stranger tier (harness/README.md, "Only the
# stranger tier drives the screen").
#
# R9's no-agent first run: the same machine vanilla-first-run.sh describes,
# minus the golden image's own stand-in `claude` binary at
# ~/.local/bin/claude (harness/image/provision.sh checks for exactly that
# path while building first-run-golden). With it gone,
# Detection.binaries (Sources/AgentMenu/Setup/Detection.swift) resolves
# nothing, so the setup card's agents section renders empty — the toggle
# for Claude Code never appears at all (SetupCard.swift only ever lists
# `detectedAgents.filter(\.found)`) — and there is nothing agent-related to
# click. The folder step still applies (a folder is what unlocks Done, not
# an agent), so the run still reaches "setup finished," just with no agent
# it can launch. Stated end state: setup finishes with a project folder
# configured and no usable agent — recorded as a finding, not fixed here
# (R21).
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:?no-agent.sh must be run by harness/run.sh, which exports HARNESS_DIR.}"
. "$HARNESS_DIR/lib/scenario.sh"
. "$HARNESS_DIR/lib/fixtures.sh"
. "$HARNESS_DIR/fixtures/agentmenu/_lib.sh"

BUNDLE_ID="$AGENTMENU_BUNDLE_ID"

if [ -z "${HARNESS_ASSET:-}" ]; then
    verdict fail "no --asset was given; the stranger tier installs the release zip, not a local build."
fi

step "fixture"
fixture agentmenu/first-run "$HARNESS_NONCE" --no-agent

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
open_status_item "$BUNDLE_ID"
expect_event "detecting finished" found=0 > /dev/null
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

finding "no-usable-agent"

verdict pass
