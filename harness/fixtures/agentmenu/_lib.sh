#!/bin/bash
# Guest-side plumbing every AgentMenu fixture's apply.sh shares: turning on
# the journal hook, and planting a synthetic git checkout for Detection to
# find. NOT harness/lib/fixtures.sh — that file is shared byte-for-byte with
# MeetingHop (harness/SHARED.sha256) and may carry no AgentMenu knowledge at
# all, while this one is free to, because it lives under harness/fixtures/,
# which is never shared and IS copied into the guest whole
# (harness/run.sh's copy_in_guest_tree copies harness/fixtures/ recursively,
# unlike harness/lib/, which never reaches the guest on the stranger tier —
# see harness/lib/fixtures.sh's own header). Every apply.sh sources this
# relative to its own location (`"$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"`),
# so it works identically whether it is running from this checkout directly
# (HARNESS_GUEST_TRANSPORT=local) or from the copy ssh landed at
# ~/.harness/fixtures/agentmenu/ on the stranger tier.
#
# Every value here is synthetic by construction: no path below ever spells
# the maintainer's own username or home directory, only $HOME as the guest
# itself resolves it at apply time. Tests/AgentMenuKitTests/HarnessFixtureTests.swift
# greps this whole tree for both and expects neither.
set -euo pipefail

AGENTMENU_BUNDLE_ID="dev.facens.agentmenu"

# The leaf name every AgentMenu fixture writes into the `harnessJournal`
# default (below) and every scenario passes to `journal_at` — one constant,
# so the two can never name two different files.
AGENTMENU_JOURNAL_LEAF="run.ndjson"

# The path every fixture plants a suggested project folder at, so a
# scenario that needs to tick it (Setup.folderToggle) can predict its
# AXIdentifier without reading the popover: `fixtures_path_hash
# "$(fixtures_guest_home)/dev/harness-project"`, mirroring exactly what
# `Sources/AgentMenu/Setup/Detection.swift`'s `projectFolders` finds under
# `~/dev` and `AccessibilityID.pathHash` then hashes.
AGENTMENU_CHECKOUT_LEAF="dev/harness-project"

# fx_activate_journal <nonce>
#
# KTD3/KTD4: on a real Finder launch (how harness/guest/install.sh's own
# `open` starts the app on the stranger tier — no `-AgentMenuHarness YES`
# argument ever reaches it, so `Overrides.forGUI()`'s isolation gate stays
# closed and every path resolves to its ordinary, non-isolated default,
# `Sources/AgentMenuKit/Config/Overrides.swift`), the journal hook itself is
# a *separate*, ungated mechanism: `HarnessJournal.activate` reads the
# `harnessJournal` key straight out of `UserDefaults.standard`
# (`Sources/AgentMenuKit/Harness/Journal.swift`), which is exactly the
# domain `defaults write` edits. Writing both keys here, before the app is
# ever installed or opened, is what turns the journal on for a scenario
# that never passes a launch argument at all — skip this and every
# `expect_event` in every scenario times out identically, for a reason
# none of them would explain.
fx_activate_journal() {
    local nonce="${1:?fx_activate_journal requires the run nonce.}"
    defaults write "$AGENTMENU_BUNDLE_ID" harnessJournal -string "$AGENTMENU_JOURNAL_LEAF"
    defaults write "$AGENTMENU_BUNDLE_ID" harnessNonce -string "$nonce"
}

# fx_git_checkout <dir>
#
# Makes `dir` look like a git checkout the way
# `Sources/AgentMenu/Setup/Detection.swift`'s `projectFolders` looks for
# one: "the folder this entry points at ... plus whatever Finder has in
# front" checks only `fileManager.fileExists(atPath: git.path)` for a `.git`
# entry one level under `~/dev` (among other roots) — it is never opened,
# never asked whether it is a real repository. A directory is enough; this
# adds a harmless placeholder file too, so a screenshot of the folder never
# reads as empty by accident.
fx_git_checkout() {
    local dir="${1:?fx_git_checkout requires a directory.}"
    mkdir -p "$dir/.git"
    printf 'synthetic checkout planted by the first-run harness fixture — never a real repository.\n' \
        > "$dir/README"
}
