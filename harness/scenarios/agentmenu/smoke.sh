#!/bin/bash
# HARNESS_STRANGER_ONLY: installs the app, answers Gatekeeper and clicks by identifier, which only the stranger tier may do.
# AgentMenu's stranger-tier smoke scenario — U4, Milestone A. Installs the
# shipped v0.1.0 zip like a stranger would (KTD8), clears Gatekeeper, and
# proves the menu-bar item appears, by screenshot and window listing only
# (R15, R17). Declares no fixtures.
#
# BLACK BOX ON PURPOSE: v0.1.0 has no journal hook, so this never calls
# expect_event — it proves the app is up by AX-level process/status-item
# presence (wait_for_status_item, which itself first proves the process is
# running at all) plus screenshots for a human reviewer (R18), never by
# reading or asserting on menu copy or layout (R17).
#
# Whether Gatekeeper prompted at all is recorded (a screenshot when it
# does, a log line either way), never asserted: a zip with no quarantine
# attribute is a legitimate pass with no prompt at all (U4's own edge test
# case), and a real Gatekeeper refusal is caught downstream instead, by
# wait_for_status_item simply timing out — the app never got permission to
# launch — which fails the scenario with the last screenshot taken
# attached, exactly as the plan's own error test case describes.
set -euo pipefail

HARNESS_DIR="${HARNESS_DIR:?smoke.sh must be run by harness/run.sh, which exports HARNESS_DIR.}"
. "$HARNESS_DIR/lib/scenario.sh"

BUNDLE_ID="dev.facens.agentmenu"

if [ -z "${HARNESS_ASSET:-}" ]; then
    verdict fail "no --asset was given; the stranger tier installs the v0.1.0 zip, not a local build."
fi

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
IDIOM="$(wait_for_status_item "$BUNDLE_ID")"
log "status item present, idiom: $IDIOM"
shot "menu-bar" > /dev/null

if [ "$(ax_window_count "$BUNDLE_ID")" -gt 0 ]; then
    shot "setup-card" > /dev/null
fi

verdict pass
