#!/bin/bash
# Signature assertions for a built AgentMenu.app. Two modes, per KTD16:
#
#   verify-signing.sh consistency <app>   runs anywhere, certificate or not
#   verify-signing.sh authority   <app>   runs only where the Developer ID exists
#
# `codesign --verify --strict --deep` is not one of these assertions. It
# reported the old, defectively signed bundle as valid — --deep never looked in
# Contents/Resources, so the CLI there stayed linker-signed — which is exactly
# the failure this script exists to catch. So every Mach-O in the bundle is
# found by its magic number rather than by where codesign expects code to be,
# and each one is inspected on its own.
#
# consistency: every Mach-O was signed by this pipeline (none is linker-signed),
#   all of them carry the same team identifier (all ad-hoc, or all one team),
#   every one requested the hardened runtime, and the Apple Events entitlement
#   is on the app and never on the nested CLI. A fork pull request has no
#   certificate, so this is what CI can honestly assert (R24).
# authority: consistency, plus every Mach-O reports Developer ID authority, the
#   expected team, a secure timestamp, and no ad-hoc flag (R6).
set -euo pipefail

MODE="${1:-}"
APP="${2:-}"
TEAM_ID="${AM_TEAM_ID:-KSP2AAA5L2}"
ENTITLEMENT="com.apple.security.automation.apple-events"

if [ "$MODE" != "consistency" ] && [ "$MODE" != "authority" ] || [ ! -d "$APP" ]; then
    echo "usage: $0 consistency|authority <path/to/AgentMenu.app>" >&2
    exit 2
fi

MAIN_EXECUTABLE="$APP/Contents/MacOS/$(defaults read "$(cd "$APP" && pwd)/Contents/Info.plist" CFBundleExecutable)"
CLI="$APP/Contents/Resources/bin/agentmenu"

failures=0
fail() { echo "  ✗ $1" >&2; failures=$((failures + 1)); }

# Every regular file that is a Mach-O, wherever it sits. Symlinks are skipped
# so a framework's Versions/Current farm is inspected once, through its target.
machos=()
while IFS= read -r -d '' path; do
    case "$(file -b "$path")" in Mach-O*) machos+=("$path") ;; esac
done < <(find "$APP" -type f -print0 | sort -z)

if [ "${#machos[@]}" -eq 0 ]; then
    echo "error: no Mach-O found under $APP" >&2
    exit 1
fi

# One codesign -dvvv per file, parsed into what the assertions read. codesign
# writes its report to stderr.
teams=()
echo "signature ${MODE} check: $APP"
for path in "${machos[@]}"; do
    report="$(codesign -dvvv "$path" 2>&1 || true)"
    team="$(printf '%s\n' "$report" | sed -n 's/^TeamIdentifier=//p' | head -1)"
    flags="$(printf '%s\n' "$report" | sed -n 's/^CodeDirectory .*flags=\([^ ]*\).*/\1/p' | head -1)"
    authority="$(printf '%s\n' "$report" | grep -c '^Authority=Developer ID Application:' || true)"
    timestamp="$(printf '%s\n' "$report" | grep -c '^Timestamp=' || true)"
    rel="${path#"$APP"/}"
    printf '  %-56s team=%-10s flags=%s\n' "$rel" "${team:-none}" "${flags:-none}"

    [ -n "$team" ] || fail "$rel: not signed at all"
    teams+=("${team:-none}")
    # Its own seal, not only the metadata the report prints: a nested binary
    # whose signature is broken but whose bytes the app happens to seal would
    # otherwise read as fine.
    codesign --verify --strict "$path" 2>/dev/null || fail "$rel: signature does not verify"

    case "$flags" in
        *linker-signed*) fail "$rel: linker-signed — this pipeline never signed it" ;;
    esac
    case "$flags" in
        *runtime*) ;;
        *) fail "$rel: hardened runtime not requested" ;;
    esac

    if [ "$MODE" = "authority" ]; then
        [ "$authority" -gt 0 ] || fail "$rel: no Developer ID Application authority"
        [ "$team" = "$TEAM_ID" ] || fail "$rel: team is '$team', expected $TEAM_ID"
        [ "$timestamp" -gt 0 ] || fail "$rel: no secure timestamp"
        case "$flags" in
            *adhoc*) fail "$rel: ad-hoc signed" ;;
        esac
    fi
done

# All Mach-Os share one team identifier: either every one is ad-hoc ("not
# set") or every one carries the same real identity. A mix is the nested
# binary somebody forgot.
distinct="$(printf '%s\n' "${teams[@]}" | sort -u | wc -l | tr -d ' ')"
if [ "$distinct" -ne 1 ]; then
    fail "mixed signing identities across the bundle: $(printf '%s\n' "${teams[@]}" | sort -u | tr '\n' ' ')"
fi

# Entitlements: on the app, never on the CLI (R4, R24).
app_entitlements="$(codesign -d --entitlements - --xml "$APP" 2>/dev/null || true)"
case "$app_entitlements" in
    *"$ENTITLEMENT"*) ;;
    *) fail "app lacks the $ENTITLEMENT entitlement" ;;
esac
if [ -f "$CLI" ]; then
    cli_entitlements="$(codesign -d --entitlements - --xml "$CLI" 2>/dev/null || true)"
    case "$cli_entitlements" in
        *"<key>"*) fail "nested CLI carries entitlements; it must carry none" ;;
    esac
fi

# The seal itself: resources, including the signed CLI, match what the app's
# signature covers. Not --deep — the nested code was inspected above.
if ! codesign --verify --strict --verbose=1 "$APP" 2>/dev/null; then
    fail "codesign --verify --strict failed on the app"
fi
[ -f "$MAIN_EXECUTABLE" ] || fail "main executable missing: $MAIN_EXECUTABLE"

if [ "$failures" -gt 0 ]; then
    echo "signature ${MODE} check: FAIL ($failures)" >&2
    exit 1
fi
echo "signature ${MODE} check: ok (${#machos[@]} Mach-O)"
