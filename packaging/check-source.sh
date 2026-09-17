#!/bin/bash
# Source-tree assertions. CI runs this on every push and pull request; a
# contributor can run it by hand before opening one.
#
#   licence headers (R21)  every Swift file under Sources/ and Tests/ starts
#                          with the copyright line and carries exactly one
#                          SPDX identifier
#   Kit purity             AgentMenuKit imports no AppKit, SwiftUI or Sparkle,
#                          and the package manifest declares no Sparkle
#                          dependency on it — the manifest check fires before
#                          anyone has written the import, which an import grep
#                          alone cannot
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

failures=0
fail() { echo "  ✗ $1" >&2; failures=$((failures + 1)); }

echo "licence headers"
count=0
while IFS= read -r file; do
    count=$((count + 1))
    spdx="$(grep -c '^// SPDX-License-Identifier: GPL-3.0-or-later$' "$file" || true)"
    [ "$spdx" -eq 1 ] || fail "$file: $spdx SPDX lines, expected exactly 1"
    head -1 "$file" | grep -q '^// Copyright (c) [0-9]\{4\} Andrea Giannangelo$' \
        || fail "$file: does not start with the copyright line"
done < <(find Sources Tests -name '*.swift' | sort)
[ "$count" -gt 0 ] || fail "no Swift files found under Sources/ and Tests/"
echo "  $count Swift files checked"

echo "Kit purity: imports"
# Any spelling of the import: indented inside an #if, behind an attribute
# (@preconcurrency, @_exported), scoped (import class AppKit.NSImage), or
# through Cocoa, which re-exports AppKit.
if hits="$(grep -rlE '^[[:space:]]*(@[A-Za-z_]+[[:space:]]+)*import[[:space:]]+((class|struct|enum|protocol|func|var|let|typealias)[[:space:]]+)?(AppKit|Cocoa|SwiftUI|Sparkle)([.[:space:]]|$)' Sources/AgentMenuKit)"; then
    while IFS= read -r file; do fail "$file imports AppKit, Cocoa, SwiftUI or Sparkle"; done <<< "$hits"
fi

echo "Kit purity: manifest"
MANIFEST="$(mktemp)"
trap 'rm -f "$MANIFEST"' EXIT
if ! swift package dump-package > "$MANIFEST" 2>/dev/null; then
    fail "swift package dump-package failed; the manifest could not be inspected"
elif ! python3 - "$MANIFEST" <<'PY'
import json, sys
package = json.load(open(sys.argv[1]))
kit = next((t for t in package["targets"] if t["name"] == "AgentMenuKit"), None)
if kit is None:
    print("  no AgentMenuKit target in the manifest", file=sys.stderr)
    sys.exit(1)
names = []
for dep in kit.get("dependencies", []):
    for kind, value in dep.items():
        names.append(str(value[0]) if isinstance(value, list) else str(value))
bad = [n for n in names if "sparkle" in n.lower()]
if bad:
    print("  AgentMenuKit declares a Sparkle dependency: " + ", ".join(bad), file=sys.stderr)
    sys.exit(1)
PY
then
    fail "the manifest attaches Sparkle to AgentMenuKit"
fi

if [ "$failures" -gt 0 ]; then
    echo "source checks: FAIL ($failures)" >&2
    exit 1
fi
echo "source checks: ok"
