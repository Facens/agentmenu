#!/bin/bash
# fixture agentmenu/first-run <nonce> [--no-agent] [--profile <id>:<model>:<advisorModel>]...
#
# The baseline every truly-vanilla scenario builds on: turns the journal on
# and plants one suggested project folder — nothing else. No config.toml is
# written; `AppEnvironment.seedIfMissing()` (Sources/AgentMenu/AppEnvironment.swift)
# only runs when there is none, and that automatic seeding — the agent whose
# binary resolves, the terminal that is installed, the profiles whose
# directories exist — is exactly the machinery vanilla-first-run,
# no-agent.sh and the profile-* scenarios each mean to exercise, not
# preempt by writing a config.toml of their own.
#
# --no-agent removes the golden image's own stand-in `claude` binary
# (harness/image/provision.sh checks for one at this exact path while
# building first-run-golden) so Detection.binaries finds nothing — the
# fixture no-agent.sh names.
#
# --profile <id>:<model>:<advisorModel> plants `~/.claude-<id>/settings.json`
# carrying both keys, so `Detection.profiles` (Detection.swift) finds a
# profile named <id> and, for whichever one sorts first, `Detection.seedPreset`
# reads `model`/`advisorModel` straight out of it — the exact two keys
# `Resources/agents/claude-code.toml` names as `model.seed_from_settings` and
# `advisor.seed_from_settings`. Repeatable, so profile-both.sh passes it
# twice for two separate accounts.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

NONCE="${1:?the first-run fixture requires the run nonce as its first argument.}"
shift

fx_activate_journal "$NONCE"
fx_git_checkout "$HOME/$AGENTMENU_CHECKOUT_LEAF"

while [ $# -gt 0 ]; do
    case "$1" in
        --no-agent)
            rm -f "$HOME/.local/bin/claude"
            shift
            ;;
        --profile)
            spec="${2:?--profile requires <id>:<model>:<advisorModel>.}"
            id="${spec%%:*}"
            rest="${spec#*:}"
            model="${rest%%:*}"
            advisor="${rest#*:}"
            if [ -z "$id" ] || [ "$id" = "$spec" ] || [ "$rest" = "$model" ]; then
                echo "error: first-run fixture: --profile wants <id>:<model>:<advisorModel>, got '$spec'." >&2
                exit 2
            fi
            profile_dir="$HOME/.claude-$id"
            mkdir -p "$profile_dir"
            cat > "$profile_dir/settings.json" <<EOF
{
  "model": "$model",
  "advisorModel": "$advisor"
}
EOF
            shift 2
            ;;
        *)
            echo "error: first-run fixture: unknown argument '$1'." >&2
            exit 2
            ;;
    esac
done
