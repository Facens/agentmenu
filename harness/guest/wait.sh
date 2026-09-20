#!/bin/bash
# Polls the journal for an event, so a scenario never guesses how long
# something takes with a fixed sleep — it waits on the evidence the app
# itself writes (KTD3), bounded, with a screenshot on timeout so a failure
# carries what was on screen rather than nothing.
#
# Usage:
#   wait.sh --journal <path> --event <name> [--field <k>=<v>]... \
#           [--timeout <secs>] [--shot-dir <dir>]
#
# Matches the first NDJSON line in the journal whose "event" equals <name>
# and whose flattened "data" object satisfies every --field k=v (repeatable,
# all must match; a dotted key like "depth.level" addresses a nested field
# via jq's getpath, which is what "flattened" means here — no field means
# match on event name alone). The whole file is re-read each poll, which is
# the simplest correct way to handle a file that is being appended to
# concurrently by the app; a malformed trailing line (the app mid-write) is
# not fatal — jq still emits every complete object that came before it, so
# a match already on disk is still found, and the read is retried next poll
# once the write completes.
#
# Polls every 0.5s with a deadline computed once from the start (never a
# fixed sleep past the bound, never busy-spun). On timeout, if --shot-dir is
# given, takes a final screenshot via shot.sh and prints its path on
# stderr — on stdout only ever the matching line, so a caller can always
# treat stdout as "the line, or nothing".
#
# Exit codes: 0 matched (the line is on stdout), 1 timed out, 2 usage error,
# 3 the journal path is unreadable for a driver reason (its directory does
# not exist, or the path exists but is not a plain, readable file) — never
# "the file does not exist yet", which is the ordinary state before the app
# has started writing and is treated as "no match yet", not an error.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOURNAL=""
EVENT=""
TIMEOUT=30
SHOT_DIR=""
FIELD_KEYS=()
FIELD_VALS=()
POLL_INTERVAL=0.5

while [ $# -gt 0 ]; do
  case "$1" in
    --journal) JOURNAL="$2"; shift 2 ;;
    --event) EVENT="$2"; shift 2 ;;
    --field)
      spec="$2"
      case "$spec" in
        *=*)
          FIELD_KEYS+=("${spec%%=*}")
          FIELD_VALS+=("${spec#*=}")
          ;;
        *)
          echo "error: --field must be key=value, got '$spec'." >&2
          exit 2
          ;;
      esac
      shift 2
      ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --shot-dir) SHOT_DIR="$2"; shift 2 ;;
    -h|--help) sed -n '2,29p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [ -z "$JOURNAL" ] || [ -z "$EVENT" ]; then
  echo "error: --journal and --event are required." >&2
  exit 2
fi
case "$TIMEOUT" in ''|*[!0-9]*) echo "error: --timeout must be a non-negative integer." >&2; exit 2 ;; esac
if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required and was not found on PATH." >&2
  exit 3
fi

JOURNAL_DIR="$(dirname -- "$JOURNAL")"
if [ ! -d "$JOURNAL_DIR" ]; then
  echo "error: the journal's directory does not exist: $JOURNAL_DIR." >&2
  exit 3
fi
if [ -e "$JOURNAL" ] && { [ ! -f "$JOURNAL" ] || [ ! -r "$JOURNAL" ]; }; then
  echo "error: $JOURNAL exists but is not a readable regular file." >&2
  exit 3
fi

# Build the jq fields array once: [["k","v"], ...].
FIELDS_JSON="[]"
if [ "${#FIELD_KEYS[@]}" -gt 0 ]; then
  FIELDS_JSON="$(
    for i in "${!FIELD_KEYS[@]}"; do
      jq -n --arg k "${FIELD_KEYS[$i]}" --arg v "${FIELD_VALS[$i]}" '[$k, $v]'
    done | jq -s -c '.'
  )"
fi

JQ_FILTER='
  . as $line
  | select($line.event == $ev)
  | select(
      $fields
      | all(.[]; . as $kv
          | ($kv[0] | split(".")) as $path
          | (($line.data // {}) | getpath($path)) as $actual
          | ($actual != null and (($actual | tostring) == $kv[1]))
        )
    )
  | $line
'

match_now() {
  [ -f "$JOURNAL" ] || return 0
  jq -c --arg ev "$EVENT" --argjson fields "$FIELDS_JSON" "$JQ_FILTER" "$JOURNAL" 2>/dev/null | head -n 1
}

start_epoch=$(date +%s)
deadline_epoch=$((start_epoch + TIMEOUT))

while true; do
  match="$(match_now || true)"
  if [ -n "$match" ]; then
    echo "$match"
    exit 0
  fi
  now_epoch=$(date +%s)
  if [ "$now_epoch" -ge "$deadline_epoch" ]; then
    break
  fi
  sleep "$POLL_INTERVAL"
done

# Timed out: best-effort final screenshot, evidence rather than a hang.
if [ -n "$SHOT_DIR" ]; then
  shot_path=""
  if [ -x "$SCRIPT_DIR/shot.sh" ]; then
    shot_path="$("$SCRIPT_DIR/shot.sh" --dir "$SHOT_DIR" --label "wait-timeout" 2>/dev/null || true)"
  fi
  if [ -n "$shot_path" ]; then
    echo "$shot_path" >&2
  else
    echo "error: could not capture a final screenshot into $SHOT_DIR." >&2
  fi
fi
echo "error: timed out after ${TIMEOUT}s waiting for event '$EVENT' in $JOURNAL." >&2
exit 1
