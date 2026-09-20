#!/bin/bash
# Watchdogs for the first-run harness: per-step, per-scenario and per-run.
#
# Sourced, never executed. A watchdog is a background shell that sleeps for a
# bound and then terminates its target, leaving a marker file behind so the
# supervisor can tell "the scenario failed" from "the scenario never
# returned". Watchdogs nest: start the run's before the scenario's and the
# scenario's before a step's, and stop them in the reverse order — the stack
# here is last-in, first-out, which is the order a run naturally unwinds in.
#
# The target is a PID, or a negative PID for a whole process group. The
# scenario is group-killed (it has children: ssh, osascript, screencapture),
# the supervisor never is — group-killing the supervisor would signal the
# watchdog itself and race the orderly teardown its own trap performs.
set -euo pipefail

if [ -n "${HARNESS_WATCHDOG_SH:-}" ]; then
    return 0
fi
HARNESS_WATCHDOG_SH=1

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

HARNESS_WATCHDOG_PIDS=""
HARNESS_WATCHDOG_LABELS=""
# How long a terminated target has to run its own trap before SIGKILL.
HARNESS_WATCHDOG_GRACE="${HARNESS_WATCHDOG_GRACE:-10}"

watchdog_marker_dir() {
    printf '%s' "${HARNESS_RUN_DIR:-${TMPDIR:-/tmp}}"
}

# True when the watchdog with this label fired during this run.
watchdog_fired() {
    [ -f "$(watchdog_marker_dir)/watchdog-$1.fired" ]
}

# True when any watchdog fired, whatever it was labelled. The run and the
# scenario have fixed labels; a step's is the step's own name, so asking about
# labels one by one would miss it.
watchdog_any_fired() {
    local marker
    for marker in "$(watchdog_marker_dir)"/watchdog-*.fired; do
        if [ -f "$marker" ]; then return 0; fi
    done
    return 1
}

# watchdog_start <seconds> <pid|-pgid> <label>
#
# The bound is a DEADLINE compared against the clock, not one long `sleep`.
# `sleep` does not advance while the host is asleep, and a MacBook lid-down or
# idle mid-run is the normal case, not the exception: the first real stranger
# run took 87 minutes of wall clock across 43 host sleep/wake cycles, and
# neither the 1800s scenario watchdog nor the 3600s run watchdog ever fired --
# their `sleep` calls were still counting. A run with no working bound is the
# one thing KTD6's detach-and-poll cannot tolerate, because nothing else is
# watching.
#
# harness/image/build.sh:352-356 already learned this for the packer stages and
# says so in its own comment; this is the same lesson in the place every
# scenario depends on. Short naps in a loop wake often enough that the clock
# comparison catches up the moment the host does.
watchdog_start() {
    local seconds="$1" target="$2" label="$3" marker
    marker="$(watchdog_marker_dir)/watchdog-$label.fired"
    rm -f "$marker"
    (
        local deadline
        deadline=$(( $(date +%s) + seconds ))
        while [ "$(date +%s)" -lt "$deadline" ]; do
            kill -0 "$target" 2>/dev/null || exit 0
            sleep 5
        done
        if kill -0 "$target" 2>/dev/null; then
            printf '%s watchdog %s fired after %ss on %s\n' "$(now_iso)" "$label" "$seconds" "$target" > "$marker"
            kill -TERM "$target" 2>/dev/null || true
            sleep "$HARNESS_WATCHDOG_GRACE"
            kill -KILL "$target" 2>/dev/null || true
        fi
    ) &
    HARNESS_WATCHDOG_PIDS="$! $HARNESS_WATCHDOG_PIDS"
    HARNESS_WATCHDOG_LABELS="$label $HARNESS_WATCHDOG_LABELS"
    return 0
}

# Stops the most recently started watchdog. Its marker file stays: whether it
# fired is a fact about the run, and the supervisor reads it after the fact.
watchdog_stop() {
    local pid rest
    [ -n "$HARNESS_WATCHDOG_PIDS" ] || return 0
    pid="${HARNESS_WATCHDOG_PIDS%% *}"
    rest="${HARNESS_WATCHDOG_PIDS#* }"
    if [ "$rest" = "$HARNESS_WATCHDOG_PIDS" ]; then rest=""; fi
    HARNESS_WATCHDOG_PIDS="$rest"
    rest="${HARNESS_WATCHDOG_LABELS#* }"
    if [ "$rest" = "$HARNESS_WATCHDOG_LABELS" ]; then rest=""; fi
    HARNESS_WATCHDOG_LABELS="$rest"
    kill -TERM "$pid" 2>/dev/null || true
    return 0
}

watchdog_stop_all() {
    while [ -n "$HARNESS_WATCHDOG_PIDS" ]; do
        watchdog_stop
    done
    return 0
}
