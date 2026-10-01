#!/bin/bash
# fixture agentmenu/configured-profile <nonce>
#
# One configured account, firstRunCompleted already true, no folders and no
# agent at all — bridge-install.sh needs neither: `SettingsModel` selects
# `environment.config.profiles.first?.id` on construction
# (Sources/AgentMenu/Settings/SettingsModel.swift), so the Accounts pane's
# detail view — and the "Install status-line bridge…" button in it
# (Sources/AgentMenu/Settings/ProfilesPane.swift) — is showing the moment
# Settings opens, with no row to click first. The profile's own configuration
# directory is created (empty settings.json) because
# `AppEnvironment.installStatusLine` shells out to the bundled
# `agentmenu install-statusline` CLI, which writes the bridge script and
# rewrites `statusLine.command` inside it — the directory has to exist for
# either write to land.
#
# `launch_at_login_asked = true` is here for the same reason
# `first_run_completed = true` is: this fixture's whole point is a user who
# is already past every one-time question, so `LaunchAtLoginPrompt.
# presentIfNeeded` (Sources/AgentMenu/Support/LaunchAtLoginPrompt.swift)
# must not raise its alert on top of a scenario that has nothing to do with
# it — that alert blocks on `NSAlert.runModal()` until answered, and this
# scenario never answers it.
# `keep_running = false` (R15, KTD16): "keep running when window closes" is ON
# for any config that does not say otherwise, so every fixture that writes a
# config.toml pins it off. A scenario written before that field existed
# tests a plain launch, and must keep testing one once a hosted launch path
# exists — Tests/AgentMenuKitTests/HarnessFixtureTests.swift asserts every
# such fixture carries it.
# `notifications_asked = true` (KTD15, KTD16): AgentMenu asks macOS for
# notification permission on the first launch it makes or the first open of
# the Sessions tab, and that system prompt is one the shared dialog script
# cannot answer. Planting the key means no scenario meets it —
# Tests/AgentMenuKitTests/HarnessFixtureTests.swift asserts every fixture that
# writes a config.toml carries it.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

NONCE="${1:?the configured-profile fixture requires the run nonce as its first argument.}"

fx_activate_harness_taps "$NONCE"

mkdir -p "$HOME/.claude-work"
cat > "$HOME/.claude-work/settings.json" <<'EOF'
{}
EOF

mkdir -p "$HOME/.config/agentmenu"
cat > "$HOME/.config/agentmenu/config.toml" <<'EOF'
schema = 1
active_profile = "work"
first_run_completed = true
launch_at_login_asked = true
notifications_asked = true

[defaults]
keep_running = false

[[profiles]]
id = "work"
name = "Work"
config_dir = "~/.claude-work"
EOF
