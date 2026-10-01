#!/bin/bash
# fixture agentmenu/owned-session <nonce>
#
# configured-terminal's twin with ONE difference: `keep_running = true` in
# [defaults]. Every other fixture pins it off (R15, KTD16), so their launches
# stay plain terminal launches; this one turns the session host on, so the
# launch scenario owned-launch.sh exercises the hosted path: AgentMenu starts
# the session in its own bundled tmux server and opens a terminal window that
# only attaches to it. Everything else (profile, folder, binaries, terminal
# overlay, trust, the three *_asked flags) is copied from configured-terminal
# exactly, so a difference between the two scenarios is the host and nothing
# else.
#
# What follows is configured-terminal's own header, unchanged but for the
# keep_running paragraph.
#
# A configured user, not a first run: writes config.toml directly rather
# than letting `AppEnvironment.seedIfMissing()` build one, so
# launch-terminal.sh (and, here, owned-launch.sh) is click-free up to the
# launch itself (no setup card,
# because `firstRunCompleted = true` and a real project folder are both
# already there — `SetupModel.isNeeded`, Sources/AgentMenu/Setup/SetupModel.swift)
# and deterministic (no live detection to race).
#
# Ships three things a launch actually needs, none of them optional:
#   - `[binaries] claude` — a real, absolute path, because
#     `AppEnvironment.isUsable` requires `config.binaries[agent.binary]` to
#     already resolve (Sources/AgentMenu/AppEnvironment.swift); nothing
#     re-probes it for a config.toml that already exists.
#   - `[[profiles]]` — `Sources/AgentMenuKit/Launch/CommandBuilder.swift`
#     throws `profileRequired` for Claude Code's `profile_env` mechanism
#     when no `Profile` resolves, so a folder with no account behind it can
#     never actually launch.
#   - the user overlay `terminals/terminal-app.toml`, copied whole from
#     `Resources/terminals/terminal-app.toml` with `enabled` flipped to
#     `true` — `TerminalManifest.parse` requires `schema`, `id`,
#     `display_name`, `kind`, `bundle_id` and `applescript` all at once
#     (Sources/AgentMenuKit/Manifests/TerminalManifest.swift); a stub
#     carrying only `enabled = true` fails to parse, lands in
#     `ManifestRegistry.failures`, and leaves the *bundled* manifest (still
#     `enabled = false`) in charge instead.
#
# `terminalState.terminal-app.trusted = true` is config.toml's own job
# (R44: `ManifestRegistry.availability` checks trust on a user-origin
# manifest before it ever looks at `enabled`) — seeded directly here rather
# than clicked, exactly as the plan's Approach section asks: "the fixture
# seeds trust directly so the launch scenario stays click-free and
# deterministic."
#
# `launch_at_login_asked = true`, for the same click-free reason: without
# it `LaunchAtLoginPrompt.presentIfNeeded`
# (Sources/AgentMenu/Support/LaunchAtLoginPrompt.swift) raises its own
# alert on launch — before the click this scenario means to make — and
# blocks on `NSAlert.runModal()` until something answers it, which nothing
# here does.
# `keep_running = true` (R15, KTD16) — the one difference. "Keep running when
# window closes" is on for any config that does not say otherwise, and every
# other fixture pins it off so it keeps testing a plain launch. This is the
# named exception: Tests/AgentMenuKitTests/HarnessFixtureTests.swift asserts
# every config-writing fixture carries `keep_running = false` except this one,
# which must carry `true`. It is written explicitly rather than left to the
# default so the scenario does not change meaning if the default ever does.
# `notifications_asked = true` (KTD15, KTD16): AgentMenu asks macOS for
# notification permission on the first launch it makes or the first open of
# the Sessions tab, and that system prompt is one the shared dialog script
# cannot answer. Planting the key means no scenario meets it —
# Tests/AgentMenuKitTests/HarnessFixtureTests.swift asserts every fixture that
# writes a config.toml carries it.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

NONCE="${1:?the owned-session fixture requires the run nonce as its first argument.}"

fx_activate_harness_taps "$NONCE"
fx_git_checkout "$HOME/$AGENTMENU_CHECKOUT_LEAF"
# The folder this scenario actually launches in — see _lib.sh for why its
# name is shaped the way it is.
fx_git_checkout "$HOME/$AGENTMENU_HARD_PATH_LEAF"

mkdir -p "$HOME/.claude-work"
cat > "$HOME/.claude-work/settings.json" <<'EOF'
{
  "model": "opus"
}
EOF

mkdir -p "$HOME/.config/agentmenu/terminals"
cat > "$HOME/.config/agentmenu/terminals/terminal-app.toml" <<'EOF'
# User overlay for Terminal.app: the bundled manifest verbatim
# (Resources/terminals/terminal-app.toml) with `enabled` flipped to true —
# written by the first-run harness fixture, never by hand.
schema = 1
id = "terminal-app"
display_name = "Terminal"
kind = "applescript"
bundle_id = "com.apple.Terminal"
enabled = true
unverified = true
applescript = """
on run argv
  set cmd to item 1 of argv
  tell application "Terminal"
    activate
    do script cmd
  end tell
end run
"""
EOF

mkdir -p "$HOME/.config/agentmenu"
cat > "$HOME/.config/agentmenu/config.toml" <<EOF
schema = 1
active_profile = "work"
first_run_completed = true
launch_at_login_asked = true
notifications_asked = true

[defaults]
agent = "claude-code"
terminal = "terminal-app"
profile = "work"
keep_running = true

[[profiles]]
id = "work"
name = "Work"
config_dir = "~/.claude-work"

[[folders]]
id = "harness-checkout"
label = "Harness Project"
path = "~/$AGENTMENU_HARD_PATH_LEAF"

[binaries]
claude = "$HOME/.local/bin/claude"

[terminals.terminal-app]
trusted = true
EOF
