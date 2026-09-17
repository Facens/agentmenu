#!/bin/bash
# Assembles AgentMenu.app from `swift build -c release` output. No Xcode: this
# script is the whole "packaging pipeline" R32 and KTD1 promise.
#
#   make bundle                      Developer ID signed when the certificate
#                                    is in the keychain, ad-hoc otherwise
#   AM_SIGN_ID="<identity>" make bundle   sign with another identity
#   AM_SIGN_ID=- make bundle              force the ad-hoc path
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${VERSION:-0.1.0}"
CONFIG="${CONFIG:-release}"
DIST="${DIST:-$ROOT/dist}"
APP="$DIST/AgentMenu.app"

# R20 / KTD10: one placeholder feeds both CFBundleShortVersionString and
# CFBundleVersion, so the version has to satisfy the stricter of the two —
# CFBundleVersion is what Sparkle orders updates by, numerically. Dotted digits
# only, validated before anything is built: there are no pre-release tags, so
# there is nothing to strip, and a malformed version fails here instead of
# stamping a build number no client could order.
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: VERSION must be MAJOR.MINOR.PATCH, digits only (got '$VERSION')" >&2
    exit 1
fi

cd "$ROOT"
swift build -c "$CONFIG" --product AgentMenu
swift build -c "$CONFIG" --product AgentMenuCLI

BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"

# KTD8: the app binary and the CLI never share a directory.
cp "$BIN_DIR/AgentMenu" "$APP/Contents/MacOS/AgentMenu"
cp "$BIN_DIR/AgentMenuCLI" "$APP/Contents/Resources/bin/agentmenu"

# Brand assets. The icon set is rendered from code (packaging/icon), so a
# clean checkout produces it rather than carrying binaries in git.
swift "$ROOT/packaging/icon/make-icons.swift"
cp "$ROOT/dist/icon/AgentMenu.icns" "$APP/Contents/Resources/AgentMenu.icns"
# Flat in Resources, not a subdirectory: that is where NSImage(named:) looks,
# and it is what picks the right @2x/@3x variant per display.
cp "$ROOT/dist/icon/menubar/"MenuBarIconTemplate*.png "$APP/Contents/Resources/"

cp -R "$ROOT/Resources/agents" "$APP/Contents/Resources/agents"
cp -R "$ROOT/Resources/terminals" "$APP/Contents/Resources/terminals"

sed "s/__VERSION__/$VERSION/g" "$ROOT/packaging/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ---------------------------------------------------------------------------
# Signing.
#
# R1 / KTD1: the release identity is the Developer ID, referenced here once.
# The team identifier is part of the designated requirement macOS keys the
# Automation grant to, so this line is not cheap to change once installs exist.
DEVELOPER_ID="Developer ID Application: Andrea Giannangelo (KSP2AAA5L2)"
SIGN_ID="${AM_SIGN_ID:-$DEVELOPER_ID}"

if [ "$SIGN_ID" != "-" ] && ! security find-identity -v -p codesigning 2>/dev/null | grep -qF "$SIGN_ID"; then
    if [ -n "${AM_SIGN_ID:-}" ]; then
        # An identity that was asked for by name must not degrade silently.
        echo "error: signing identity not in the keychain: $AM_SIGN_ID" >&2
        exit 1
    fi
    SIGN_ID="-"
fi

# Every signing call carries the same options: the hardened runtime (R2) and,
# with a real identity, a secure timestamp. Ad-hoc signatures cannot be
# timestamped, so that path says none rather than letting codesign skip it
# quietly.
SIGN=(codesign --force --options runtime --sign "$SIGN_ID")
if [ "$SIGN_ID" = "-" ]; then
    SIGN+=(--timestamp=none)
    # The path a fork's CI runner and an unprovisioned machine both take. It
    # produces a bundle that looks signed and is not: it runs here, fails
    # Gatekeeper anywhere else, cannot be notarized, and loses its Automation
    # grant on every rebuild. Say so where nobody can miss it.
    cat >&2 <<'BANNER'
==========================================================================
 AD-HOC SIGNED BUILD — not a release
 No Developer ID certificate in the keychain. This bundle runs on this
 machine only, will not pass Gatekeeper elsewhere, and cannot be notarized.
==========================================================================
BANNER
else
    SIGN+=(--timestamp)
    echo "signing with: $SIGN_ID"
fi

# KTD2 / R3: explicit and inside-out, never --deep (which skips
# Contents/Resources; verify-signing.sh tells the story). Nested code first,
# each with its own identifier; the app last, with the app's entitlements
# (R4). The CLI sends no Apple Events and gets no entitlements.
"${SIGN[@]}" --identifier dev.facens.agentmenu.cli "$APP/Contents/Resources/bin/agentmenu"
"${SIGN[@]}" --entitlements "$ROOT/packaging/AgentMenu.entitlements" "$APP"

# KTD16: the authority assertion where a Developer ID signed it, the
# consistency assertion everywhere else. Authority includes consistency.
case "$SIGN_ID" in
    "Developer ID Application:"*) "$ROOT/packaging/verify-signing.sh" authority "$APP" ;;
    *) "$ROOT/packaging/verify-signing.sh" consistency "$APP" ;;
esac

if [ "$SIGN_ID" = "-" ]; then
    echo "built $APP (version $VERSION, AD-HOC signed — not a release)"
else
    echo "built $APP (version $VERSION, signed by $SIGN_ID)"
fi
