#!/bin/bash
# Host-side helpers a scenario sources to build and check the fixtures it
# names through `fixture <name> [args...]` (harness/lib/scenario.sh) — never
# the fixture mechanism itself, which scenario.sh already owns end to end
# (it refuses an unknown name before the guest is ever touched, and runs
# `harness/fixtures/<name>/apply.sh` there). What lives here instead is the
# small, genuinely app-agnostic arithmetic a scenario needs around that call:
# reaching the guest for a one-shot answer, and reproducing the one hash
# both apps' AXIdentifier builders use so a scenario can predict an
# identifier from what its own fixture wrote, instead of reading one back
# off the screen (R17 forbids that).
#
# THIS FILE IS SHARED (harness/SHARED.sha256, harness/README.md's "Shared
# files" section): byte identical in both repositories. It knows no bundle
# id, no config-file schema, no profile layout — nothing that differs
# between the two apps. Every app-specific fixture belongs under
# harness/fixtures/<app>/ instead, which is not shared; AgentMenu's own
# guest-side plumbing lives at harness/fixtures/agentmenu/_lib.sh.
#
# IMPORTANT: harness/run.sh's copy_in_guest_tree only ever stages
# harness/guest/ and harness/fixtures/ into the guest (see its own comment,
# "the harness tree goes to ~/.harness/"); harness/lib/ never reaches the
# guest, on the stranger tier, at all. So this file is sourced by a
# *scenario* (which always runs on the host, per harness/README.md's
# "Writing a scenario" section), never by a fixture's own apply.sh, which
# has to be self-contained to work identically over ssh and over the
# app-fresh tier's local transport. A scenario sources this the same way it
# sources scenario.sh itself: `. "$HARNESS_DIR/lib/fixtures.sh"`.
set -euo pipefail

if [ -n "${HARNESS_FIXTURES_SH:-}" ]; then
    return 0
fi
HARNESS_FIXTURES_SH=1

# ---------------------------------------------------------------------------
# fixtures_guest_capture <timeout-seconds> <command...>
#
# Runs `command` in the guest (through the same indirectable guest_run
# lib/vm.sh already provides — ssh on the stranger tier, a local shell
# wherever HARNESS_GUEST_TRANSPORT=local), bounded, and prints its stdout.
# Never drives the screen — it only ever reaches a CLI or a shell builtin in
# the guest (a scenario's own `agentmenu dump-state` check, or resolving the
# guest's real $HOME below), so unlike scenario.sh's click/shot/dialog it is
# not refused on the app-fresh tier.
#
# A nonzero exit in the guest is a harness error, exactly as scenario.sh's
# own helpers treat an unreachable guest or a misused driver: this prints
# what failed and exits 3. Callers use it exactly the way scenario.sh's own
# doc header (fact 2) asks any helper meant to be captured to be used —
# `out="$(fixtures_guest_capture ...)"`, never bare — so that exit lands as
# a subshell's own status. A scenario always runs under `set -euo pipefail`
# (this file's own style rule), and bash's own assignment form,
# `x="$(cmd)"`, is one of the few compound forms `errexit` still fires on
# when `cmd` fails — so a caller that does not itself branch on the result
# still gets the whole scenario torn down with exit 3, never silently
# continuing on empty output.
fixtures_guest_capture() {
    local bound="${1:?fixtures_guest_capture requires a timeout in seconds.}"
    shift
    if [ $# -eq 0 ]; then
        echo "error: fixtures_guest_capture requires a command." >&2
        exit 3
    fi
    local out rc=0
    if out="$(bounded_run "$bound" guest_run "$HARNESS_GUEST_IP" "$*")"; then
        rc=0
    else
        rc=$?
    fi
    if [ "$rc" -ne 0 ]; then
        echo "error: fixtures_guest_capture: '$*' failed in the guest (exit $rc)." >&2
        exit 3
    fi
    printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# fixtures_guest_home
#
# The guest's own real, absolute $HOME — resolved in the guest, never
# assumed on the host (HARNESS_GUEST_USER's default, "admin", names the
# account, not its home directory, and the app-fresh tier's "guest" is
# whatever machine this is running on, real home included). A scenario needs
# this to turn an abbreviated, tilde-led display path
# (`Sources/AgentMenu/Support/PathDisplay.swift`'s `abbreviated`, which is
# what a suggested-folder toggle's own AXIdentifier hashes) back into the
# expanded absolute path the app itself hashes it from.
fixtures_guest_home() {
    fixtures_guest_capture "$HARNESS_STEP_TIMEOUT" 'printf "%s" "$HOME"'
}

# ---------------------------------------------------------------------------
# fixtures_path_hash <value>
#
# The 12-hex-character SHA-256 prefix both apps' AXIdentifier builders use
# to keep a path — or anything else user-supplied — out of an
# AXIdentifier un-hashed
# (`Sources/AgentMenuKit/Support/AccessibilityID.swift`'s `pathHash`: "SHA-256,
# hex, truncated to 12 characters"). Pure string arithmetic, no I/O, so it
# never touches the guest and never needs `~` expanded here — the one place
# that matters (a folder's abbreviated display path, which *does* start with
# `~`) is on the caller: `pathHash` itself only ever expands a leading `~`
# on its own input before hashing it, so a scenario that wants to match it
# has to hand this function the already-expanded value, exactly the way
# `AccessibilityID.pathHash` receives it in-process.
fixtures_path_hash() {
    local value="${1:?fixtures_path_hash requires a value to hash.}"
    printf '%s' "$value" | shasum -a 256 | cut -c1-12
}
