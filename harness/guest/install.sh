#!/bin/bash
# Installs an app zip the way a stranger would: land it in ~/Downloads with
# the quarantine attribute a browser download carries, unzip it there, move
# the unzipped bundle to /Applications, then open it (KTD8). Never unzip in
# place and open straight from Downloads — that translocates the app to a
# random read-only path, and TCC grants and launch-at-login registration
# would not stick to a path that moves on every launch.
#
# Usage:
#   install.sh --zip <path> --app <AgentMenu|MeetingHop> [--no-quarantine] [--json]
#
# Without --json, progress is narrated on stdout as each step completes and
# the result object is the last line. With --json, stdout carries nothing
# but that one line, so a caller can parse it directly:
#   {"app":"/Applications/AgentMenu.app","quarantine":true,"bundle_id":"..."}
# --no-quarantine skips the com.apple.quarantine attribute, for a scenario
# that wants to compare against the quarantined path deliberately.
#
# PINNED 2026-09-19: the quarantine attribute's value below (flags 0083,
# agent "Safari") is a construction of the format LaunchServices writes for a
# Safari download, and it does raise the real thing. Verified on a clone of
# first-run-golden with the shipped AgentMenu v0.1.0 zip: macOS put up
# CoreServicesUIAgent's consent sheet: "AgentMenu" is an app downloaded from
# the Internet. Are you sure you want to open it?, over "Safari downloaded
# this file today". If a later macOS stops prompting, or prompts with
# different wording, start here.
#
# Exit codes: 0 installed, 2 usage error, 3 harness error (the zip is
# missing, nothing unzips to a usable bundle, or more than one does).
set -euo pipefail

ZIP=""
APP_NAME=""
QUARANTINE=1
JSON_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --zip) ZIP="$2"; shift 2 ;;
    --app) APP_NAME="$2"; shift 2 ;;
    --no-quarantine) QUARANTINE=0; shift ;;
    --json) JSON_ONLY=1; shift ;;
    # Bounded by the sentinel below, not by a line number: every edit to the
    # header above used to silently truncate or overrun this help text.
    -h|--help) sed -n '2,/^set -euo pipefail/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

log() {
  if [ "$JSON_ONLY" -eq 1 ]; then
    echo "$1" >&2
  else
    echo "$1"
  fi
}

if [ -z "$ZIP" ] || [ -z "$APP_NAME" ]; then
  echo "error: --zip and --app are required." >&2
  exit 2
fi
case "$APP_NAME" in
  AgentMenu|MeetingHop) ;;
  *) echo "error: --app must be AgentMenu or MeetingHop, got '$APP_NAME'." >&2; exit 2 ;;
esac
if [ ! -f "$ZIP" ]; then
  echo "error: zip not found at $ZIP." >&2
  exit 3
fi

DOWNLOADS="$HOME/Downloads"
mkdir -p "$DOWNLOADS"
DEST_ZIP="$DOWNLOADS/$(basename -- "$ZIP")"
cp -f -- "$ZIP" "$DEST_ZIP"
log "copied to $DEST_ZIP"

# The value LaunchServices writes for a browser download: hex flags,
# hex Unix timestamp, agent name, and a UUID event id. QTN_FLAG values here
# mark it as downloaded-from-internet, which is what makes Gatekeeper
# evaluate it at all (see the PINNED note above).
quarantine_value() {
  printf '0083;%08x;Safari;%s' "$(date +%s)" "$(uuidgen)"
}

if [ "$QUARANTINE" -eq 1 ]; then
  xattr -w com.apple.quarantine "$(quarantine_value)" "$DEST_ZIP" 2>/dev/null || true
  log "quarantine attribute set on the zip"
fi

UNZIP_DIR="$(mktemp -d "$DOWNLOADS/.harness-install-XXXXXX")"
cleanup() { rm -rf "$UNZIP_DIR"; }
trap cleanup EXIT

if ! ditto -x -k --rsrc -- "$DEST_ZIP" "$UNZIP_DIR" 2>/dev/null; then
  if ! unzip -q -o -- "$DEST_ZIP" -d "$UNZIP_DIR" 2>/dev/null; then
    echo "error: could not unzip $DEST_ZIP." >&2
    exit 3
  fi
fi
log "unzipped into $UNZIP_DIR"

# The zip may hold the bundle at its root or one level under a wrapper
# folder; either way there must be exactly one match named for this app.
APP_MATCHES=()
while IFS= read -r -d '' found; do
  APP_MATCHES+=("$found")
done < <(find "$UNZIP_DIR" -maxdepth 2 -iname "${APP_NAME}.app" -type d -print0)

if [ "${#APP_MATCHES[@]}" -eq 0 ]; then
  echo "error: no ${APP_NAME}.app found inside $ZIP." >&2
  exit 3
fi
if [ "${#APP_MATCHES[@]}" -gt 1 ]; then
  echo "error: more than one ${APP_NAME}.app found inside $ZIP: ${APP_MATCHES[*]}." >&2
  exit 3
fi
APP_BUNDLE="${APP_MATCHES[0]}"

# Quarantine belongs on the unzipped bundle too — ditto/unzip usually carry
# it over, but this makes it definite regardless of which tool did the work.
if [ "$QUARANTINE" -eq 1 ]; then
  xattr -w com.apple.quarantine "$(quarantine_value)" "$APP_BUNDLE" 2>/dev/null || true
else
  xattr -d com.apple.quarantine "$APP_BUNDLE" 2>/dev/null || true
fi

DEST_APP="/Applications/${APP_NAME}.app"
rm -rf "$DEST_APP"
mv -f "$APP_BUNDLE" "$DEST_APP"
log "moved to $DEST_APP"

INFO_PLIST="$(cd "$DEST_APP" && pwd)/Contents/Info.plist"
BUNDLE_ID="$(defaults read "$INFO_PLIST" CFBundleIdentifier 2>/dev/null || echo "")"

# Detached, and deliberately not waited on. `open` does not return while
# Gatekeeper's consent sheet is on screen, and the scenario answers that sheet
# in its NEXT step -- so waiting here deadlocks the run: install.sh waits for
# open, open waits for the dialog, and the dialog waits for a step that cannot
# start. Observed on the first real stranger run, which sat on the Gatekeeper
# sheet for 87 minutes with nothing to break the tie.
#
# The exit status of `open` is therefore not available to this script, and it
# would not mean much anyway: a quarantined first launch is decided by the
# user's answer, not by the spawn. Whether the app actually came up is proven
# downstream by the scenario (wait_for_status_item), which is where the
# evidence belongs.
nohup open "$DEST_APP" >/dev/null 2>&1 &
disown 2>/dev/null || true
log "asked LaunchServices to open $DEST_APP (not waited on: Gatekeeper's sheet blocks it)"

QUARANTINE_NOW="false"
if xattr -p com.apple.quarantine "$DEST_APP" >/dev/null 2>&1; then
  QUARANTINE_NOW="true"
fi

printf '{"app":"%s","quarantine":%s,"bundle_id":"%s"}\n' "$DEST_APP" "$QUARANTINE_NOW" "$BUNDLE_ID"
