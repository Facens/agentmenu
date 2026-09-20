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
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

NONCE="${1:?the configured-profile fixture requires the run nonce as its first argument.}"

fx_activate_journal "$NONCE"

mkdir -p "$HOME/.claude-work"
cat > "$HOME/.claude-work/settings.json" <<'EOF'
{}
EOF

mkdir -p "$HOME/.config/agentmenu"
cat > "$HOME/.config/agentmenu/config.toml" <<'EOF'
schema = 1
active_profile = "work"
first_run_completed = true

[[profiles]]
id = "work"
name = "Work"
config_dir = "~/.claude-work"
EOF
