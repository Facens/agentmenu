#!/bin/bash
# fixture agentmenu/configured-terminal <nonce>
#
# A configured user, not a first run: writes config.toml directly rather
# than letting `AppEnvironment.seedIfMissing()` build one, so
# launch-terminal.sh is click-free up to the launch itself (no setup card,
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
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

NONCE="${1:?the configured-terminal fixture requires the run nonce as its first argument.}"

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
    if (count of windows) = 0 then
      do script cmd
    else
      do script cmd in window 1
    end if
  end tell
end run
"""
EOF

mkdir -p "$HOME/.config/agentmenu"
cat > "$HOME/.config/agentmenu/config.toml" <<EOF
schema = 1
active_profile = "work"
first_run_completed = true

[defaults]
agent = "claude-code"
terminal = "terminal-app"
profile = "work"

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
