#!/bin/bash
# fixture agentmenu/needs-login-prompt <nonce>
#
# An existing install: `first_run_completed = true`, and no
# `launch_at_login_asked` key at all — the exact shape a real config.toml
# written before this question existed actually has. Exists to exercise
# `LaunchAtLoginPrompt.presentIfNeeded`
# (Sources/AgentMenu/Support/LaunchAtLoginPrompt.swift), the alert path a
# fresh install never reaches (that one answers inside the setup card
# instead) and that `agentmenu/configured-profile` and
# `agentmenu/configured-terminal` now deliberately avoid (see their own
# comments on `launch_at_login_asked = true`) — this is the one fixture
# whose whole job is to leave the question unanswered, so
# launch-at-login-prompt.sh has something to answer.
#
# Nothing else is planted: this scenario never opens Settings or the
# popover's folder rows, only waits for the alert `AppDelegate.
# applicationDidFinishLaunching` raises straight after the status item goes
# up, so no profile, folder or agent is needed for it to reach that point.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

NONCE="${1:?the needs-login-prompt fixture requires the run nonce as its first argument.}"

fx_activate_harness_taps "$NONCE"

mkdir -p "$HOME/.config/agentmenu"
cat > "$HOME/.config/agentmenu/config.toml" <<'EOF'
schema = 1
first_run_completed = true
EOF
