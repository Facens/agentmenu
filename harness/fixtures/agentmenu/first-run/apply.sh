#!/bin/bash
# fixture agentmenu/first-run <nonce> [--no-agent] [--profile <id>:<model>:<advisorModel>]...
#
# The baseline every truly-vanilla scenario builds on: turns the harness
# taps on and plants one suggested project folder — nothing else. No config.toml is
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
#
# The first --profile also removes `~/.claude`, and that is not tidying:
# `Detection.profiles` matches `.claude` itself as well as `.claude-*`, and
# the golden image always has one, because `harness/image/provision.sh`
# installs Claude Code (`curl -fsSL https://claude.ai/install.sh | bash`)
# and the installer creates it. Measured on the 20260921063507 image, in
# the v0.2.0-beta.2 gate's own journals: with `--profile work` alone the
# app journalled `profile_count: 2` — `default` at `/Users/admin/.claude`
# beside `work` — and with two `--profile` flags, 3. So a scenario that
# names its accounts and leaves `~/.claude` standing is not describing the
# machine it thinks it is. Worse than the count: `.claude` sorts first, so
# `AppEnvironment.seedIfMissing` hands `Detection.seedPreset` a settings
# file with no `model` key in it and R11's "start on the values already in
# use" never happens — the one thing --profile exists to set up. Naming a
# profile therefore means "these are the accounts on this machine", which
# is an ordinary shape: someone who runs Claude Code out of
# `~/.claude-work` and has never used the default account.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

NONCE="${1:?the first-run fixture requires the run nonce as its first argument.}"
shift

fx_activate_harness_taps "$NONCE"
fx_git_checkout "$HOME/$AGENTMENU_CHECKOUT_LEAF"

while [ $# -gt 0 ]; do
    case "$1" in
        --no-agent)
            rm -f "$HOME/.local/bin/claude"
            shift
            ;;
        --profile)
            spec="${2:?--profile requires <id>:<model>:<advisorModel>.}"
            # Once, before the first named account is planted: see the
            # header. Guarded, and not defensively: `rm -rf "$HOME/.claude"`
            # run against the maintainer's own login home would delete their
            # real Claude Code configuration, and the only thing standing
            # between this line and that machine is a HARNESS_STRANGER_ONLY
            # comment on the scenario — which the fixture runs *before* any
            # helper that enforces it. Two ways to be somewhere it is safe,
            # and the removal needs one of them: the disposable guest, which
            # carries /etc/first-run-golden.json and nothing else does
            # (harness/image/provision.sh writes it); or a $HOME that is not
            # this user's login home at all, which is how the unit rig runs
            # this same file against a temporary directory
            # (Tests/AgentMenuKitTests/HarnessFixtureTests.swift).
            if [ -z "${named_profiles:-}" ]; then
                named_profiles=1
                login_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | sed 's/^NFSHomeDirectory: //')"
                if [ ! -f /etc/first-run-golden.json ] && [ "$HOME" = "$login_home" ]; then
                    echo "error: first-run fixture: --profile removes \$HOME/.claude, and \$HOME is this user's own login home on a machine that is not a first-run-golden guest. Refusing." >&2
                    exit 2
                fi
                rm -rf "$HOME/.claude"
            fi
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
