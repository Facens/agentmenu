#!/bin/bash
# Shared helpers for the first-run harness: refusals, logging, JSON escaping,
# run identifiers, bounded waits, process liveness and the report file.
#
# This file is sourced, never executed, and it carries `set -euo pipefail` for
# the scripts that source it: a helper that fails stops the caller instead of
# letting a run continue against a half-provisioned guest.
#
# The exit-code taxonomy is the same everywhere under harness/:
#
#   0  pass          the scenario reached its stated end state
#   1  scenario fail  it did not
#   2  usage error   bad arguments, unknown run id, the host at its guest limit
#   3  harness error  the harness itself could not decide
#
# `die <code> <message>` is how a refusal leaves a script: a full lowercase
# sentence with its own final period, on stderr, remediation lines after it.
#
# The report helpers are named run_report_* rather than report_* on purpose:
# harness/lib/report.sh (U11) owns the report compiler and has to be able to
# define report_* names of its own without colliding with these.
set -euo pipefail

if [ -n "${HARNESS_COMMON_SH:-}" ]; then
    return 0
fi
HARNESS_COMMON_SH=1

# ---------------------------------------------------------------------------
# Refusals and logging. Everything goes to stderr; stdout belongs to the
# command's own output (a run id, a status, a JSON document).

die() {
    local code="$1"
    shift
    echo "error: $*" >&2
    exit "$code"
}

warn() {
    echo "warning: $*" >&2
}

log() {
    echo "[$(now_iso)] $*" >&2
}

now_iso() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# ---------------------------------------------------------------------------
# JSON. jq is the sanctioned tool (KTD5); nothing here hand-rolls a quote.

# Prints the JSON string literal for its argument, quotes included, so it can
# be interpolated straight into a JSON document.
json_escape() {
    jq -n --arg value "${1-}" '$value'
}

# ---------------------------------------------------------------------------
# Identity.

# The repository root, from this file's own location: lib/ -> harness/ -> root.
# In a subshell: a bare `repo_root` must not move its caller's directory.
repo_root() {
    ( cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd )
}

rand_hex() {
    od -An -tx1 -N"${1:-3}" /dev/urandom | tr -d ' \n'
}

# `<app>-<tier>-<scenario>-<UTC yyyymmddTHHMMSSZ>-<6 hex>`. The result has to
# match ^[A-Za-z0-9._-]{1,128}$ — it names a directory and a VM clone — so it
# is checked here rather than trusted from the caller's arguments.
new_run_id() {
    local id
    id="$1-$2-$3-$(date -u +%Y%m%dT%H%M%SZ)-$(rand_hex 3)"
    case "$id" in
        *[!A-Za-z0-9._-]*) die 2 "the run id '$id' has a character outside [A-Za-z0-9._-]." ;;
    esac
    if [ "${#id}" -gt 128 ]; then
        die 2 "the run id '$id' is longer than 128 characters."
    fi
    printf '%s' "$id"
}

require_cmd() {
    local name
    for name in "$@"; do
        command -v "$name" >/dev/null 2>&1 || die 3 "$name is not on PATH and the harness needs it."
    done
}

# ---------------------------------------------------------------------------
# Processes.
#
# A PID alone does not identify a process: the supervisor's PID can be
# recycled while a run directory still names it. Every liveness check is
# therefore PID plus a start token — the process's own start time, which a
# recycled PID cannot reproduce.

proc_start_token() {
    ps -p "$1" -o lstart= 2>/dev/null | sed 's/^[[:space:]]*//;s/[[:space:]]*$//'
}

# True when `pid` is alive and started at `token`. An empty token means the
# process was already gone when it was recorded, so it is never alive.
proc_matches() {
    local pid="${1:-}" token="${2:-}" current
    [ -n "$pid" ] && [ "$pid" != "null" ] && [ -n "$token" ] || return 1
    current="$(proc_start_token "$pid")"
    [ -n "$current" ] && [ "$current" = "$token" ]
}

# Runs a command with a deadline. macOS has no timeout(1), and an unbounded
# `tart delete` inside a teardown trap would hang the trap and keep the run's
# exit code out of report.json forever — so every teardown step goes through
# this. Returns the command's status, or 124 when the deadline killed it.
bounded_run() {
    local limit="$1"
    shift
    local pid rc=0 waited=0 ticks timed_out=0
    ticks=$((limit * 10))
    "$@" &
    pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        if [ "$waited" -ge "$ticks" ]; then
            timed_out=1
            kill -TERM "$pid" 2>/dev/null || true
            sleep 1
            kill -KILL "$pid" 2>/dev/null || true
            break
        fi
        sleep 0.1
        waited=$((waited + 1))
    done
    if wait "$pid"; then rc=0; else rc=$?; fi
    if [ "$timed_out" -eq 1 ]; then
        return 124
    fi
    return "$rc"
}

# ---------------------------------------------------------------------------
# The report file.
#
# One writer at a time, by discipline: `start` writes it before it forks the
# supervisor, the supervisor owns it from the moment `start.ok` appears, and
# `status`/`wait` only write it once the supervisor is provably gone. Every
# write lands in a temporary file in the same directory and is moved into
# place, so a reader never sees half a document.

run_report_write() {
    local dir="$1" body="$2" tmp
    tmp="$dir/.report.json.$$"
    printf '%s\n' "$body" | jq '.' > "$tmp" || die 3 "the report for $dir could not be written."
    mv -f "$tmp" "$dir/report.json"
}

# Shallow-merges a JSON object into the report.
run_report_merge() {
    local dir="$1" patch="$2" tmp
    tmp="$dir/.report.json.$$"
    jq --argjson patch "$patch" '. + $patch' "$dir/report.json" > "$tmp" \
        || die 3 "the report for $dir could not be updated."
    mv -f "$tmp" "$dir/report.json"
}

# Reads one field, by jq path. Prints the empty string when it is absent or
# null, so callers can test with [ -n ... ].
run_report_field() {
    local dir="$1" path="$2" value
    value="$(jq -r "$path // empty" "$dir/report.json" 2>/dev/null || true)"
    printf '%s' "$value"
}
