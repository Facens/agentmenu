#!/bin/bash
# Compares this checkout's shared harness files with the other app's checkout.
#
#   harness/sync-check.sh [--other-dir DIR] [--require] [--list]
#
# KTD5 keeps the shared harness files byte-identical across the two
# repositories: harness/run.sh, harness/guest/ and harness/lib/ except
# appfresh.sh and snapshot.sh, which carry an app-specific launch block. Each
# repository's `make test` checks its own copies against harness/SHARED.sha256
# — that catches an edit that was not regenerated, where it was made. What a
# manifest cannot see is the other checkout: a file edited and regenerated in
# both places, differently, passes both suites and still drifts. That is what
# this compares, and why the release runbook runs it.
#
# The other checkout is found next to this one (agentmenu-dev, agentmenu,
# meetinghop-dev, meetinghop) unless --other-dir names it. Without it there is
# nothing to compare: the check says so and exits 0, or exits 2 under
# --require, which is how the runbook asks for the comparison to be real.
# --list prints the shared files and exits.
#
# Exit codes: 0 in sync (or nothing to compare), 1 drift, 2 usage error.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_DIR="$ROOT/harness"
MANIFEST="$HARNESS_DIR/SHARED.sha256"
OTHER=""
REQUIRE=0
LIST_ONLY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --other-dir)
            if [ $# -lt 2 ]; then echo "error: --other-dir needs a value." >&2; exit 2; fi
            OTHER="$2"; shift 2 ;;
        --require) REQUIRE=1; shift ;;
        --list)    LIST_ONLY=1; shift ;;
        -h|--help) sed -n '2,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

# The shared list comes from the manifest when there is one, so the manifest
# stays the single statement of what "shared" means, and from KTD5's rule
# before the manifest is first generated.
shared_files() {
    if [ -f "$MANIFEST" ]; then
        awk 'NF >= 2 { sub(/^\*/, "", $2); print $2 }' "$MANIFEST" | sort -u
        return 0
    fi
    cd "$ROOT"
    {
        [ -f harness/run.sh ] && echo harness/run.sh
        find harness/guest -type f 2>/dev/null || true
        find harness/lib -type f ! -name appfresh.sh ! -name snapshot.sh 2>/dev/null || true
    } | sed 's|^\./||' | sort -u
}

FILES="$(shared_files)"

if [ "$LIST_ONLY" -eq 1 ]; then
    printf '%s\n' "$FILES"
    exit 0
fi

if [ -z "$OTHER" ]; then
    PARENT="$(cd "$ROOT/.." && pwd)"
    for candidate in "$PARENT/agentmenu-dev" "$PARENT/agentmenu" "$PARENT/meetinghop-dev" "$PARENT/meetinghop"; do
        if [ "$candidate" = "$ROOT" ]; then continue; fi
        if [ -d "$candidate/harness" ]; then OTHER="$candidate"; break; fi
    done
fi

if [ -z "$OTHER" ] || [ ! -d "$OTHER/harness" ]; then
    if [ "$REQUIRE" -eq 1 ]; then
        echo "error: the other app's checkout was not found${OTHER:+ at $OTHER}." >&2
        echo "Clone it next to this one, or name it with --other-dir." >&2
        exit 2
    fi
    echo "shared-file sync check: the other app's checkout is not on this machine, so there is nothing to compare."
    echo "Pass --require in the release runbook, where the comparison has to be real."
    exit 0
fi
OTHER="$(cd "$OTHER" && pwd)"

echo "shared-file sync check"
echo "  this:  $ROOT"
echo "  other: $OTHER"

drift=0
count=0
while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    count=$((count + 1))
    if [ ! -f "$ROOT/$rel" ]; then
        echo "  ✗ $rel: missing here" >&2
        drift=$((drift + 1))
        continue
    fi
    if [ ! -f "$OTHER/$rel" ]; then
        echo "  ✗ $rel: missing in the other checkout" >&2
        drift=$((drift + 1))
        continue
    fi
    if ! cmp -s "$ROOT/$rel" "$OTHER/$rel"; then
        echo "  ✗ $rel: differs" >&2
        drift=$((drift + 1))
    fi
done <<EOF
$FILES
EOF

if [ "$count" -eq 0 ]; then
    echo "error: no shared files were found to compare." >&2
    echo "Generate harness/SHARED.sha256, or check that harness/ is populated." >&2
    exit 2
fi

if [ "$drift" -gt 0 ]; then
    echo "shared-file sync check: DRIFT ($drift of $count)" >&2
    echo "Copy the corrected file to both checkouts and regenerate harness/SHARED.sha256 in each." >&2
    exit 1
fi
echo "shared-file sync check: ok ($count files)"
