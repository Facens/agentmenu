#!/bin/bash
# HARNESS_STRANGER_ONLY: installs the app, answers Gatekeeper and clicks by identifier, which only the stranger tier may do.
# AgentMenu's stranger-tier smoke scenario — U4, Milestone A. Installs the
# shipped v0.1.0 zip like a stranger would (KTD8), clears Gatekeeper, and
# proves the menu-bar item appears, by screenshot and window listing only
# (R15, R17).
#
# BLACK BOX ON PURPOSE: this never calls expect_event — it proves the app
# is up by AX-level process/status-item presence (wait_for_status_item,
# which itself first proves the process is running at all) plus screenshots
# for a human reviewer (R18), never by reading or asserting on menu copy or
# layout (R17).
#
# It does apply one fixture, and only one: `agentmenu/journal-only`, which
# turns the read-only journal hook on and plants nothing. That is not an
# assertion and does not make this scenario grey: the gate reads a run's
# journal, not its assertions, and scores `nonce_ok` from the nonce the app
# echoes on its own first line (harness/lib/report.sh) — so a scenario with
# no journal cannot prove which asset it ran against, and every gate that
# includes it comes back `error` whatever the scenarios did. The v0.2.0-beta.2
# gate did exactly that. Until 0.2.0 there was nothing to turn on: v0.1.0
# shipped no journal hook at all, which is why this scenario declared no
# fixtures when it was written.
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
. "$HARNESS_DIR/lib/fixtures.sh"
. "$HARNESS_DIR/fixtures/agentmenu/_lib.sh"

BUNDLE_ID="$AGENTMENU_BUNDLE_ID"

if [ -z "${HARNESS_ASSET:-}" ]; then
    verdict fail "no --asset was given; the stranger tier installs the release zip, not a local build."
fi

step "fixture"
fixture agentmenu/journal-only "$HARNESS_NONCE"

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
IDIOM="$(wait_for_status_item "$BUNDLE_ID")"
# Names the file run.sh copies back off the guest at the end of the run.
# Nothing here reads it; the gate does, for the nonce echo the header
# explains.
journal_at "$BUNDLE_ID" "$AGENTMENU_JOURNAL_LEAF"
log "status item present, idiom: $IDIOM"
shot "menu-bar" > /dev/null

if [ "$(ax_window_count "$BUNDLE_ID")" -gt 0 ]; then
    shot "setup-card" > /dev/null
fi

# Nothing here reads it; the gate does. This scenario asserts nothing from
# the journal, so nothing else would ever fetch it — `expect_event` is what
# normally brings a copy back, and this scenario deliberately never calls
# one. See the header for what the gate needs it for.
journal_fetch

verdict pass
