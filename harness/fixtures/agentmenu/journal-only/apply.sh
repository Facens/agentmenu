#!/bin/bash
# fixture agentmenu/journal-only <nonce>
#
# Turns the journal hook on and plants nothing at all — the smallest
# fixture there is, and the only one whose entire purpose is the nonce.
#
# smoke.sh asserts nothing from the journal and is meant not to: it proves
# the shipped zip installs, clears Gatekeeper and puts a status item in the
# menu bar, by AX presence and screenshots (R15, R17). But `gate.sh` does
# not read a scenario's assertions, it reads its journal: `report.sh`'s
# per-run `nonce_ok` compares the run's nonce against the first line of the
# journal the app itself wrote (harness/lib/report.sh), and the whole gate
# is `error` unless every scenario in the set answers it. A scenario that
# never turns the hook on has no first line, so it can never prove the run
# it describes was this asset under this nonce — which is why MeetingHop's
# green gate covers five scenarios and leaves its own smoke out.
#
# So this fixture buys smoke.sh a nonce echo without giving it anything to
# assert on, and without making it a different scenario: the journal hook
# is a read-only state tap (KTD3, R13) — inert unless a defaults key names
# a file, and a failure to write it never changes what the app does — so
# turning it on adds an observation and no behaviour.
#
# Not a `--no-plant` flag on the first-run fixture: that one's whole job is
# the git checkout and the named accounts, and a flag that turns all of it
# off would be two fixtures wearing one name.
set -euo pipefail

. "$(dirname "${BASH_SOURCE[0]}")/../_lib.sh"

NONCE="${1:?the journal-only fixture requires the run nonce as its first argument.}"

fx_activate_harness_taps "$NONCE"
