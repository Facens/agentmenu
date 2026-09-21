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
VERSION="${VERSION:-0.0.0-alpha}"
CONFIG="${CONFIG:-release}"
DIST="${DIST:-$ROOT/dist}"
APP="$DIST/AgentMenu.app"

# R20 / KTD10 (as amended): three release channels share one version grammar —
# stable (MAJOR.MINOR.PATCH), beta (MAJOR.MINOR.PATCH-beta.N) and alpha
# (MAJOR.MINOR.PATCH-alpha), see packaging/version.sh for the table. The two
# Info.plist version keys can no longer share one placeholder, because
# Sparkle's comparator (SUStandardVersionComparator) stops reading at the
# first "-", so 0.2.0-beta.1 and 0.2.0 would tie and a beta install could
# never be offered the final. CFBundleShortVersionString stays the human
# string, as written; CFBundleVersion is derived — the same three components
# plus a fourth that breaks the tie and keeps the sequence monotonic. Both are
# validated and derived here, before anything is built, so a malformed
# version fails before it can stamp a build number no client could order.
source "$ROOT/packaging/version.sh"
CHANNEL="$(version_channel "$VERSION")" || exit 1
BUILD="$(version_build "$VERSION")" || exit 1

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

sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" "$ROOT/packaging/Info.plist" > "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# ---------------------------------------------------------------------------
# Sparkle (U10 / R12). The package dependency resolves an XCFramework into
# .build/artifacts; the framework itself has to be copied into the bundle and
# signed here, because SwiftPM has no notion of an app bundle.
#
# `ditto`, never `cp -R` (KTD13): the framework is a versioned bundle whose
# Versions/Current symlink `cp -R` would either follow or mangle, and a
# framework that has lost it does not load.
SPARKLE_SRC="$(find "$ROOT/.build/artifacts" -type d -name Sparkle.framework -path '*macos*' -print -quit 2>/dev/null || true)"
if [ -z "$SPARKLE_SRC" ]; then
    echo "error: Sparkle.framework not found under .build/artifacts — run 'swift package resolve' first" >&2
    exit 1
fi
FRAMEWORKS="$APP/Contents/Frameworks"
mkdir -p "$FRAMEWORKS"
rm -rf "$FRAMEWORKS/Sparkle.framework"
ditto "$SPARKLE_SRC" "$FRAMEWORKS/Sparkle.framework"

# KTD19 instantiated for a dependency we do not build: Sparkle ships
# universal, this app ships arm64, and a release asserts the app executable is
# arm64 exactly. Thinning here keeps the bundle one architecture throughout
# instead of carrying an x86_64 half no release will ever run, and costs
# nothing at signing time because every one of these is re-signed below
# anyway. A file that is already single-architecture is left alone.
while IFS= read -r macho; do
    case "$(file -b "$macho")" in
        *"universal binary"*)
            lipo -thin arm64 "$macho" -output "$macho.arm64" && mv -f "$macho.arm64" "$macho"
            ;;
    esac
done < <(find "$FRAMEWORKS/Sparkle.framework/Versions/B" -type f -exec sh -c 'case "$(file -b "$1")" in Mach-O*) echo "$1";; esac' _ {} \;)

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
#
# Sparkle first, and inside it deepest first: the XPC services and the two
# helper apps are code the framework contains, so a signature over the
# framework is only valid once they are final. Signing the framework through
# its Versions/B directory rather than the symlinked top level is what
# codesign expects of a versioned bundle; signing the top level seals the
# symlinks instead.
SPARKLE_VERSION_DIR="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
"${SIGN[@]}" "$SPARKLE_VERSION_DIR/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$SPARKLE_VERSION_DIR/XPCServices/Installer.xpc"
"${SIGN[@]}" "$SPARKLE_VERSION_DIR/Updater.app"
"${SIGN[@]}" "$SPARKLE_VERSION_DIR/Autoupdate"
"${SIGN[@]}" "$SPARKLE_VERSION_DIR"
# None of those carry entitlements. Sparkle ships Autoupdate with an
# application-identifier entitlement of its own and the rest with empty
# dictionaries; re-signing without an entitlements file drops them, which is
# right for a Developer ID app that is not sandboxed — the XPC services need
# sandbox entitlements only when the host app is sandboxed, and this one is
# not. verify-signing.sh asserts that shape rather than trusting this comment.
"${SIGN[@]}" --identifier dev.facens.agentmenu.cli "$APP/Contents/Resources/bin/agentmenu"
"${SIGN[@]}" --entitlements "$ROOT/packaging/AgentMenu.entitlements" "$APP"

# KTD16: the authority assertion where a Developer ID signed it, the
# consistency assertion everywhere else. Authority includes consistency.
case "$SIGN_ID" in
    "Developer ID Application:"*) "$ROOT/packaging/verify-signing.sh" authority "$APP" ;;
    *) "$ROOT/packaging/verify-signing.sh" consistency "$APP" ;;
esac

if [ "$SIGN_ID" = "-" ]; then
    echo "built $APP (version $VERSION, channel $CHANNEL, AD-HOC signed — not a release)"
else
    echo "built $APP (version $VERSION, channel $CHANNEL, signed by $SIGN_ID)"
fi
