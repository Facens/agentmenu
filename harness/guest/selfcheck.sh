#!/bin/bash
# Proves the driver's own grants after a fresh boot, before any scenario
# trusts the guest to answer real clicks: a screenshot actually captures the
# screen (Screen Recording), and a System Events query actually answers
# (Accessibility) — both without a permission prompt appearing, which would
# mean a grant was not seeded into the golden image or did not survive the
# clone. Run at the start of every stranger run (U3 approach note).
#
# Usage:
#   selfcheck.sh [--shot-dir <dir>] [--list-ids <bundle-id|pid:n>] [--evidence <path>]
#
# --shot-dir names where the proof screenshot lands (default: a fresh
# mktemp -d, since this typically runs before a scenario's own run
# directory exists). --list-ids, given a bundle id or "pid:<n>" (U-defect-2:
# ax.applescript resolves either form; pid: names one running process
# unambiguously, which matters on the app-fresh tier, where the harness's
# own isolated instance and the maintainer's own installed copy can answer
# to the same bundle id at once — the caller, not this script, decides
# which form to pass), also asks ax.applescript for the status-item idiom
# (KTD2's deferred question: "menu bar 2" of the app's own process, or of
# SystemUIServer), the full identifier list, whether a click was actually
# delivered (reported as "automation" — Apple Events/PostEvent, a
# permission distinct from reading via Accessibility, per the driver rows
# KTD1 seeds for both), and whether the popover survived the
# foreground-stealing step in between (KTD2's "statusclick" note) — all
# four only mean something once an app under test is installed and
# running, so with no target given they come back null rather than
# clicking something unrelated to fill the field. --evidence, when given,
# receives one NDJSON line per dialog `probe` finds on screen if either
# base grant did not answer cleanly — the most likely explanation for a
# failed grant here is a prompt sitting on screen instead of an answer.
#
# Prints one JSON object on stdout:
#   {"screencapture":true,"system_events":true,"automation":true|false|null,
#    "statusitem_idiom":"app-menu-bar-2"|"systemuiserver"|null,
#    "identifiers":[...]|null,"popover_survived":true|false|null}
#
# Exit codes: 0 both base grants (screencapture, system_events) answered
# cleanly, 1 one did not, 2 usage error, 3 a dependency script (shot.sh or
# ax.applescript) is missing or not executable.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SHOT_DIR=""
TARGET=""
EVIDENCE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --shot-dir) SHOT_DIR="$2"; shift 2 ;;
    --list-ids) TARGET="$2"; shift 2 ;;
    --evidence) EVIDENCE="$2"; shift 2 ;;
    -h|--help) sed -n '2,36p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$SHOT_DIR" ]; then
  SHOT_DIR="$(mktemp -d)"
fi

SHOT_SCRIPT="$SCRIPT_DIR/shot.sh"
AX_SCRIPT="$SCRIPT_DIR/ax.applescript"
DIALOGS_SCRIPT="$SCRIPT_DIR/dialogs.applescript"
if [ ! -x "$SHOT_SCRIPT" ]; then
  echo "error: $SHOT_SCRIPT is missing or not executable." >&2
  exit 3
fi
if [ ! -f "$AX_SCRIPT" ]; then
  echo "error: $AX_SCRIPT is missing." >&2
  exit 3
fi

SCREENCAPTURE_OK="false"
if "$SHOT_SCRIPT" --dir "$SHOT_DIR" --label "selfcheck" >/dev/null 2>&1; then
  SCREENCAPTURE_OK="true"
fi

# A minimal, read-only System Events query — listing process names — proves
# Accessibility answers without asking again; it performs no action and
# clicks nothing, so unlike a click it carries no Apple-Events-authorization
# risk of its own (that distinction is what "automation" below checks).
SYSTEM_EVENTS_OK="false"
if osascript -e 'tell application "System Events" to get name of every process' >/dev/null 2>&1; then
  SYSTEM_EVENTS_OK="true"
fi

STATUSITEM_IDIOM="null"
IDENTIFIERS_JSON="null"
POPOVER_SURVIVED="null"
AUTOMATION_JSON="null"

if [ -n "$TARGET" ] && command -v jq >/dev/null 2>&1; then
  STATUS_RESULT="$(osascript "$AX_SCRIPT" statusitem "$TARGET" 2>/dev/null || echo '{}')"
  IDIOM="$(printf '%s' "$STATUS_RESULT" | jq -r '.idiom // empty' 2>/dev/null || true)"
  if [ -n "$IDIOM" ]; then
    STATUSITEM_IDIOM="\"$IDIOM\""
  fi

  IDS_RESULT="$(osascript "$AX_SCRIPT" list-ids "$TARGET" 2>/dev/null || echo '{}')"
  IDENTIFIERS_JSON="$(printf '%s' "$IDS_RESULT" | jq -c '.identifiers // []' 2>/dev/null || echo '[]')"

  # Open the popover, then do the same kind of foreground-stealing action a
  # real scenario step can cause (KTD2: an Automation prompt or Terminal
  # opening dismisses the popover because AgentMenu resigns active), then
  # check whether its window is still there.
  CLICK_RESULT="$(osascript "$AX_SCRIPT" statusclick "$TARGET" 2>/dev/null || echo '{}')"
  CLICKED="$(printf '%s' "$CLICK_RESULT" | jq -r '.clicked // false' 2>/dev/null || echo 'false')"
  CLICK_KIND="$(printf '%s' "$CLICK_RESULT" | jq -r '.kind // empty' 2>/dev/null || true)"
  if [ "$CLICK_KIND" = "driver" ]; then
    AUTOMATION_JSON="false"
  elif [ "$CLICKED" = "true" ]; then
    AUTOMATION_JSON="true"
  fi

  osascript -e 'tell application "System Events" to get name of every process' >/dev/null 2>&1 || true
  sleep 0.3

  WINDOWS_RESULT="$(osascript "$AX_SCRIPT" windows "$TARGET" 2>/dev/null || echo '{}')"
  WINDOW_COUNT="$(printf '%s' "$WINDOWS_RESULT" | jq '.windows // [] | length' 2>/dev/null || echo '0')"
  if [ "$CLICKED" = "true" ]; then
    if [ "${WINDOW_COUNT:-0}" -gt 0 ] 2>/dev/null; then
      POPOVER_SURVIVED="true"
    else
      POPOVER_SURVIVED="false"
    fi
  fi
fi

printf '{"screencapture":%s,"system_events":%s,"automation":%s,"statusitem_idiom":%s,"identifiers":%s,"popover_survived":%s}\n' \
  "$SCREENCAPTURE_OK" "$SYSTEM_EVENTS_OK" "$AUTOMATION_JSON" "$STATUSITEM_IDIOM" "$IDENTIFIERS_JSON" "$POPOVER_SURVIVED"

if [ "$SCREENCAPTURE_OK" != "true" ] || [ "$SYSTEM_EVENTS_OK" != "true" ]; then
  if [ -n "$EVIDENCE" ] && [ -f "$DIALOGS_SCRIPT" ]; then
    PROBE_RESULT="$(osascript "$DIALOGS_SCRIPT" probe 2>/dev/null || echo '{"dialogs":[]}')"
    if command -v jq >/dev/null 2>&1; then
      TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
      printf '%s\n' "$PROBE_RESULT" | jq -c --arg t "$TS" '.dialogs[] | {process, window_title: .title, t: $t, source: "selfcheck"}' >> "$EVIDENCE" 2>/dev/null || true
    fi
  fi
  exit 1
fi
exit 0
