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

# A second checkout whose name carries the two characters that break naive
# quoting: a space and an apostrophe. `docs/adding-a-terminal.md` step 2 asks
# for exactly this before a terminal manifest may claim `unverified = false`
# — "with a folder whose name contains a space and an apostrophe. That is the
# case that breaks naive quoting." The app single-quotes the directory into a
# shell command it hands the terminal (`CommandBuilder.singleQuoted`, which
# escapes an apostrophe as '\''), so this is the path that proves the
# escaping end to end rather than in a unit test.
#
# Synthetic, like every other path here: no maintainer username, no real home.
AGENTMENU_HARD_PATH_LEAF="dev/it's a project"

# fx_activate_harness_taps <nonce>
#
# Turns on both of the app's read-only harness taps, in the one domain a
# fixture can reach before the app has ever been launched. Called by every
# AgentMenu fixture, including the ones that plant nothing: a scenario that
# has one tap and not the other is a scenario whose result depends on what
# the window server happened to do, which is the whole point of not having
# to remember to call two functions.
#
# `harnessJournal` / `harnessNonce` — KTD3/KTD4: on a real Finder launch
# (how harness/guest/install.sh's own `open` starts the app on the stranger
# tier), the journal hook is a *separate*, ungated mechanism:
# `HarnessJournal.activate` reads the `harnessJournal` key straight out of
# `UserDefaults.standard` (`Sources/AgentMenuKit/Harness/Journal.swift`),
# which is exactly the domain `defaults write` edits. Writing both keys
# here, before the app is ever installed or opened, is what turns the
# journal on for a scenario that never passes a launch argument at all —
# skip this and every `expect_event` in every scenario times out
# identically, for a reason none of them would explain.
#
# `AgentMenuHarness` — the popover's dismissal. `StatusItemController`
# closes the popover on `NSApplication.didResignActiveNotification` unless
# this flag is set, and its own comment says why the flag exists: "Every
# accessibility query runs inside `tell application "System Events"`, which
# takes the active application away from this one — so the popover closed
# part-way through the driver's own walk of it." That fix was written for
# this tier and had never once run on it, because it was reached only
# through `-AgentMenuHarness YES` and `install.sh` opens the app with a
# bare `open`, which passes no arguments at all. `Overrides.forGUI` and
# `StatusItemController` both read the key from `UserDefaults.standard`,
# so `defaults write` sets it exactly as a launch argument would.
#
# Measured, 2026-09-21, `vanilla-first-run` against v0.2.0-beta.2: the
# setup card's folder toggle was on screen in the step's own screenshot and
# gone from the accessibility tree seconds later, with two stacked TCC
# sheets in front of it — AgentMenu's Automation prompt over a second
# privacy prompt — and the popover closed behind them. Nothing brings it
# back, so the run's remaining clicks had nothing to click. The scenario
# was not wrong about the identifier: `no-agent` clicked the identical one,
# computed identically, and passed in the same batch.
#
# Setting the key also opens `Overrides.forGUI`'s gate, and that is inert
# here on purpose: once open it reads the same five `AGENTMENU_*`
# environment variables `forCLI` reads, and a Finder launch has none of
# them, so every override resolves to nil and the app runs on its ordinary
# paths — which its own fixture echo then states, in `config` and
# `defaults_suite`, for anyone who wants to check rather than believe it.
fx_activate_harness_taps() {
    local nonce="${1:?fx_activate_harness_taps requires the run nonce.}"
    defaults write "$AGENTMENU_BUNDLE_ID" harnessJournal -string "$AGENTMENU_JOURNAL_LEAF"
    defaults write "$AGENTMENU_BUNDLE_ID" harnessNonce -string "$nonce"
    defaults write "$AGENTMENU_BUNDLE_ID" AgentMenuHarness -bool YES
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
