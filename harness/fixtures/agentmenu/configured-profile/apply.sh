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

[[profiles]]
id = "work"
name = "Work"
config_dir = "~/.claude-work"
EOF
