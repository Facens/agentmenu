#!/bin/bash
# The app-fresh tier: a local Developer ID build of AgentMenu, launched
# against an isolated configuration root, proven never to have touched the
# maintainer's own state (R3, R8, AE8, AE11).
#
# THIS FILE IS APP-SPECIFIC (harness/SHARED.sha256, harness/README.md's
# "Shared files" section, excludes it and snapshot.sh by name): it is the
# one file in harness/lib/ allowed to know AgentMenu's bundle identifier
# (dev.facens.agentmenu), its harness launch argument (-AgentMenuHarness
# YES) and the five KTD4 override variables
# (Sources/AgentMenuKit/Config/Overrides.swift). MeetingHop's own copy
# carries the same shape under -MeetingHopDefaultsSuite /
# -MeetingHopHarnessDir.
#
# Sourced, never executed, from two places in harness/run.sh:
#   - prepare_app_fresh() calls appfresh_prepare, before run_scenario(), only
#     on the app-fresh tier.
#   - teardown() calls appfresh_teardown, on every exit, but only when this
#     file was sourced (it checks with `declare -F` first — a stranger-tier
#     run never sources this file at all).
#   - cmd_clean calls appfresh_clean unconditionally when this file exists in
#     the checkout, so a run a crash interrupted is still swept, the same way
#     an orphaned VM clone already is.
#
# ===== The isolated root =====
#
# One directory per run, from `mktemp -d`, removed on the way out — the bash
# equivalent of Tests/AgentMenuKitTests/Harness.swift's TempDir:
#
#   <tempdir>/config/config.toml   AGENTMENU_CONFIG
#   <tempdir>/manifests/           AGENTMENU_MANIFESTS_USER_ROOT
#   <tempdir>/profile/             AGENTMENU_PROFILE_ROOT
#   <tempdir>/harness/             AGENTMENU_HARNESS_DIR (the journal lands here)
#
# plus a per-run UserDefaults suite (AGENTMENU_DEFAULTS_SUITE), named
# dev.facens.agentmenu.harness.<run-id> — never dev.facens.agentmenu itself —
# carrying harnessJournal (Journal.journalKey) and harnessNonce
# (Journal.nonceKey). The app only reads any of this when it was ALSO
# launched with -AgentMenuHarness YES in the argument domain
# (Overrides.forGUI's gate); that flag lives only in this process's own argv,
# so it cannot itself reach a real launch (R3: "the same override mechanism
# must not let anything other than the harness redirect a real launch").
#
# Three breadcrumbs are written into the run directory before the thing they
# name exists — the same discipline provision_stranger uses for clone.name
# in run.sh: appfresh.tempdir, appfresh.suite, appfresh.pid. A crash between
# naming and creating leaves appfresh_clean something to correlate; a crash
# after still leaves it something to delete.
#
# On this tier the harness directory is relocated, so appfresh_prepare sets
# HARNESS_GUEST_JOURNAL itself rather than letting a scenario call
# harness/lib/scenario.sh's journal_at — that helper's own local-transport
# branch builds "$HOME/Library/Application Support/...", the maintainer's
# real $HOME, never the isolated root. A file-only AgentMenu scenario must
# not call journal_at on this tier.
#
# ===== Quitting =====
#
# By PID only, never `osascript -e 'tell application id "dev.facens.agentmenu"
# to quit'`: a local build carries the SAME bundle identifier as whatever the
# maintainer has installed for real, and "application id" is ambiguous about
# which running instance answers when two processes claim the same id. The
# one failure mode this file cannot risk is quitting the maintainer's own,
# currently running AgentMenu. SIGTERM, a bounded wait, then SIGKILL — see
# appfresh_quit. This trades away the graceful NSApplication.terminate() path
# (and whatever a debounced pending save would have flushed) for that safety;
# the isolated config it might have written the last of is deleted moments
# later regardless.
#
# ===== A snapshot mismatch's severity =====
#
# appfresh_teardown does not raise on a mismatch — its own return code only
# reaches a `warn` in run.sh's teardown(), which this file may not modify
# beyond that one guarded call. Instead it writes
# watchdog-appfresh-snapshot.fired into the run directory: the same marker
# name a fired watchdog leaves, in the same directory watchdog_any_fired
# already scans (harness/lib/watchdog.sh's watchdog_marker_dir is
# $HARNESS_RUN_DIR). finalize() — unmodified, and not a file this unit may
# touch — therefore maps the run to harness_error on its own, exactly as it
# already does for a real watchdog. That is the right severity: R3's
# invariant broke, which is not "the scenario failed" (verdict fail, the
# scenario may have reached its own end state just fine) and not quite "the
# harness could not tell" either, but it is squarely "this run cannot be
# certified" — the same thing harness_error already means.
set -euo pipefail

if [ -n "${HARNESS_APPFRESH_SH:-}" ]; then
    return 0
fi
HARNESS_APPFRESH_SH=1

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
. "$(dirname "${BASH_SOURCE[0]}")/snapshot.sh"

# Computed independently of run.sh's own $ROOT (kept if already set, e.g.
# when run.sh sourced this file) so this file is sourceable on its own, which
# its own tests do: lib/ -> harness/ -> repo root.
ROOT="${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

APPFRESH_BUNDLE_ID="dev.facens.agentmenu"
APPFRESH_LAUNCH_TIMEOUT="${HARNESS_APPFRESH_LAUNCH_TIMEOUT:-30}"

# ---------------------------------------------------------------------------
# The bundle: HARNESS_APPFRESH_APP if a caller supplied one directly (every
# test in this checkout does; so would a maintainer pointing at their own
# preview build), or packaging/bundle.sh's standard output location,
# (re)built when it looks stale.

appfresh_app_bundle() {
    if [ -n "${HARNESS_APPFRESH_APP:-}" ]; then
        printf '%s' "$HARNESS_APPFRESH_APP"
    else
        printf '%s/dist/AgentMenu.app' "$ROOT"
    fi
}

# True when the binary is missing, or something under Sources/, Package.swift
# or packaging/ is newer than it — the same "is there anything newer than the
# artifact" test a Makefile's own dependency rule would make.
appfresh_bundle_stale() {
    local binary="$1" newer
    [ -x "$binary" ] || return 0
    newer="$(find "$ROOT/Sources" "$ROOT/Package.swift" "$ROOT/packaging" -newer "$binary" -type f 2>/dev/null | head -n 1 || true)"
    [ -n "$newer" ]
}

# Never builds when HARNESS_APPFRESH_APP is set: a caller that supplied a
# bundle directly owns it, and this never rebuilds over it.
appfresh_ensure_bundle() {
    local app binary
    if [ -n "${HARNESS_APPFRESH_APP:-}" ]; then
        app="$(appfresh_app_bundle)"
        binary="$app/Contents/MacOS/AgentMenu"
        if [ -x "$binary" ]; then
            return 0
        fi
        warn "app-fresh: HARNESS_APPFRESH_APP is set but $binary is not executable."
        return 1
    fi

    app="$(appfresh_app_bundle)"
    binary="$app/Contents/MacOS/AgentMenu"
    if appfresh_bundle_stale "$binary"; then
        log "app-fresh: building AgentMenu (packaging/bundle.sh) — $binary is missing or stale."
        if ! VERSION="${HARNESS_APPFRESH_VERSION:-0.0.0-alpha}" DIST="$ROOT/dist" "$ROOT/packaging/bundle.sh"; then
            warn "app-fresh: packaging/bundle.sh failed."
            return 1
        fi
    fi
    if [ ! -x "$binary" ]; then
        warn "app-fresh: $binary is not executable after building."
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Readiness. The journal file appearing is the strongest signal this file has
# that the app got through Overrides.forGUI() and HarnessJournal.activate()
# — stronger than "the process forked", weaker than a scenario's own
# wait_for_status_item (harness/lib/scenario.sh), which is the scenario's
# job, not this file's, and is not called here.
appfresh_wait_for_journal() {
    local journal="$1" timeout="$2" pid="${3:-}"
    local deadline=$(( $(date +%s) + timeout ))
    while :; do
        if [ -s "$journal" ]; then
            return 0
        fi
        if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
            warn "app-fresh: the app process ($pid) exited before writing its journal."
            return 1
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            return 1
        fi
        sleep 0.2
    done
}

# ---------------------------------------------------------------------------
# Preferences directory, overridable so appfresh_clean's file-level cleanup
# is testable without touching the real one. `defaults` itself is never
# redirectable this way — it always resolves the real per-user domain
# regardless of any variable here — so this only ever affects the direct
# `rm -f` fallback for a plist `defaults delete` left behind, never the
# `defaults` calls themselves.
_appfresh_prefs_dir() {
    printf '%s' "${HARNESS_APPFRESH_PREFS_DIR:-$HOME/Library/Preferences}"
}

# ---------------------------------------------------------------------------
# Quit, by PID only. See this file's header for why AppleScript's
# "application id" is refused here.
appfresh_quit() {
    local pid="$1" waited=0
    kill -0 "$pid" 2>/dev/null || return 0
    kill -TERM "$pid" 2>/dev/null || true
    while [ "$waited" -lt 20 ]; do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.5
        waited=$((waited + 1))
    done
    warn "app-fresh: $pid did not exit after SIGTERM; sending SIGKILL."
    kill -KILL "$pid" 2>/dev/null || true
    sleep 0.3
    if kill -0 "$pid" 2>/dev/null; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# appfresh_prepare <run-dir>
#
# Everything run.sh's prepare_app_fresh() needs before run_scenario(): the
# before-snapshot, the build, the isolated root, the suite, the launch, and a
# bounded wait for the app to prove it is up. A non-zero return means no
# scenario should run at all; prepare_app_fresh() maps that to a harness
# error (3), the same taxonomy slot "the guest never came up" already uses on
# the stranger tier.
appfresh_prepare() {
    local run_dir="${1:?appfresh_prepare requires a run directory.}"
    export HARNESS_RUN_DIR="$run_dir"

    if ! snapshot_take "$run_dir/appfresh.snapshot.before"; then
        warn "app-fresh: could not take the before-snapshot."
        return 1
    fi

    if ! appfresh_ensure_bundle; then
        return 1
    fi
    local app binary
    app="$(appfresh_app_bundle)"
    binary="$app/Contents/MacOS/AgentMenu"

    local tmproot
    tmproot="$(mktemp -d "${TMPDIR:-/tmp}/agentmenu-appfresh.XXXXXX" 2>/dev/null || true)"
    if [ -z "$tmproot" ] || [ ! -d "$tmproot" ]; then
        warn "app-fresh: could not create the isolated root."
        return 1
    fi
    printf '%s\n' "$tmproot" > "$run_dir/appfresh.tempdir"

    if ! mkdir -p "$tmproot/config" "$tmproot/manifests" "$tmproot/profile" "$tmproot/harness"; then
        warn "app-fresh: could not create the isolated root's subdirectories."
        return 1
    fi

    local run_id suite leaf nonce
    run_id="$(basename "$run_dir")"
    suite="${APPFRESH_BUNDLE_ID}.harness.${run_id}"
    printf '%s\n' "$suite" > "$run_dir/appfresh.suite"
    leaf="journal.ndjson"
    nonce="$(run_report_field "$run_dir" .nonce)"

    if ! defaults write "$suite" harnessJournal -string "$leaf" > /dev/null 2>&1; then
        warn "app-fresh: could not seed the harness journal key in $suite."
        return 1
    fi
    if [ -n "$nonce" ]; then
        defaults write "$suite" harnessNonce -string "$nonce" > /dev/null 2>&1 || true
    fi

    export HARNESS_GUEST_JOURNAL="$tmproot/harness/$leaf"

    AGENTMENU_CONFIG="$tmproot/config/config.toml" \
    AGENTMENU_MANIFESTS_USER_ROOT="$tmproot/manifests" \
    AGENTMENU_PROFILE_ROOT="$tmproot/profile" \
    AGENTMENU_DEFAULTS_SUITE="$suite" \
    AGENTMENU_HARNESS_DIR="$tmproot/harness" \
        "$binary" -AgentMenuHarness YES > "$run_dir/appfresh.app.log" 2>&1 &
    local app_pid=$! app_token
    # PID plus its own start token, the same pairing common.sh's own
    # proc_matches/proc_start_token exist for: "the supervisor's PID can be
    # recycled while a run directory still names it" applies just as much to
    # this PID once a crashed run's breadcrumb sits around waiting for
    # appfresh_clean — teardown() only ever reads this within the same
    # process's own lifetime and is safe on the bare PID, but clean reads it
    # an unbounded time later, and a bare `kill -0`/`kill -TERM` there would
    # risk signaling some unrelated process that PID was recycled into.
    app_token="$(proc_start_token "$app_pid")"
    printf '%s\n%s\n' "$app_pid" "$app_token" > "$run_dir/appfresh.pid"

    if ! appfresh_wait_for_journal "$tmproot/harness/$leaf" "$APPFRESH_LAUNCH_TIMEOUT" "$app_pid"; then
        warn "app-fresh: AgentMenu did not confirm it was up within ${APPFRESH_LAUNCH_TIMEOUT}s."
        return 1
    fi
    log "app-fresh: AgentMenu is up (pid $app_pid, suite $suite)."
    return 0
}

# ---------------------------------------------------------------------------
# appfresh_teardown
#
# Called from run.sh's teardown() trap — see this file's header for why it
# cannot install its own EXIT trap instead, and for what a snapshot mismatch
# actually does (the watchdog marker, not this function's own return code).
# Reads $HARNESS_RUN_DIR, which appfresh_prepare exported and which
# cmd_supervise() exports before either tier is prepared.
appfresh_teardown() {
    local run_dir="${HARNESS_RUN_DIR:?appfresh_teardown needs HARNESS_RUN_DIR.}"
    local ok=0
    local pid suite tempdir

    if [ -f "$run_dir/appfresh.pid" ]; then
        pid="$(head -n 1 "$run_dir/appfresh.pid" 2>/dev/null || true)"
        if [ -n "$pid" ]; then
            if ! appfresh_quit "$pid"; then
                warn "app-fresh: could not confirm AgentMenu (pid $pid) quit."
                ok=1
            fi
        fi
    fi

    if [ -f "$run_dir/appfresh.suite" ]; then
        suite="$(head -n 1 "$run_dir/appfresh.suite" 2>/dev/null || true)"
        if [ -n "$suite" ]; then
            # `defaults delete` clears the keys but can leave an empty plist
            # on disk — verified by hand against a scratch domain
            # (2026-09-18): a 42-byte empty-dict file remained — so it is
            # removed directly too, or a plist per run id would accumulate in
            # Preferences forever.
            defaults delete "$suite" > /dev/null 2>&1 || true
            rm -f "$(_appfresh_prefs_dir)/$suite.plist"
        fi
    fi

    if snapshot_take "$run_dir/appfresh.snapshot.after"; then
        if [ -f "$run_dir/appfresh.snapshot.before" ]; then
            if ! snapshot_compare "$run_dir/appfresh.snapshot.before" "$run_dir/appfresh.snapshot.after"; then
                {
                    printf '%s app-fresh: the maintainer'"'"'s own state changed during this run:\n' "$(now_iso)"
                    snapshot_diff "$run_dir/appfresh.snapshot.before" "$run_dir/appfresh.snapshot.after"
                } > "$run_dir/watchdog-appfresh-snapshot.fired" 2>/dev/null || true
                warn "app-fresh: the maintainer's own state changed during this run — see watchdog-appfresh-snapshot.fired."
                ok=1
            fi
        fi
    else
        warn "app-fresh: could not take the after-snapshot; this run cannot prove R3."
        ok=1
    fi

    if [ -f "$run_dir/appfresh.tempdir" ]; then
        tempdir="$(head -n 1 "$run_dir/appfresh.tempdir" 2>/dev/null || true)"
        if [ -n "$tempdir" ] && [ -d "$tempdir" ]; then
            rm -rf "$tempdir"
        fi
    fi

    return "$ok"
}

# ---------------------------------------------------------------------------
# appfresh_clean <dist-root> [dry-run]
#
# Called from run.sh's cmd_clean whenever this file is in the checkout,
# regardless of tier or age: sweeps what a killed run's own appfresh_teardown
# never got to run, for every run directory whose supervisor is not alive. A
# leftover suite plist sits in ~/Library/Preferences, which the age-gated
# run-directory sweep next to this call never reaches, so this one is
# age-independent on purpose. Prints one line per item swept (or would
# sweep), in the same voice as the VM and run-directory loops beside it.
appfresh_clean() {
    local dist_root="${1:?appfresh_clean requires a dist root.}" dry_run="${2:-0}"
    [ -d "$dist_root" ] || return 0
    local dir
    for dir in "$dist_root"/*/; do
        dir="${dir%/}"
        [ -f "$dir/report.json" ] || continue
        if _appfresh_run_alive "$dir"; then
            continue
        fi
        _appfresh_clean_one "$dir" "$dry_run"
    done
    return 0
}

# A run's own liveness, reimplemented rather than reused from run.sh's own
# supervisor_alive: this file is sourced and tested standalone, and
# common.sh's proc_matches/run_report_field are all it needs to answer the
# same question.
_appfresh_run_alive() {
    local dir="$1" pid token
    pid="$(run_report_field "$dir" .supervisor_pid)"
    token="$(run_report_field "$dir" .supervisor_token)"
    proc_matches "$pid" "$token"
}

_appfresh_clean_one() {
    local dir="$1" dry_run="$2"
    local pid token suite plist tempdir

    if [ -f "$dir/appfresh.pid" ]; then
        pid="$(sed -n '1p' "$dir/appfresh.pid" 2>/dev/null || true)"
        token="$(sed -n '2p' "$dir/appfresh.pid" 2>/dev/null || true)"
        # proc_matches, not a bare kill -0: this breadcrumb can be an
        # unbounded time old by the time clean gets to it, and a PID alone
        # does not identify a process (common.sh's own words) — the same
        # reasoning that made cmd_start pair the supervisor's PID with its
        # start token in the first place.
        if proc_matches "$pid" "$token"; then
            if [ "$dry_run" -eq 1 ]; then
                echo "would stop orphaned app-fresh process $pid ($dir)"
            else
                echo "stopping orphaned app-fresh process $pid ($dir)"
                appfresh_quit "$pid" || true
            fi
        fi
    fi

    if [ -f "$dir/appfresh.suite" ]; then
        suite="$(head -n 1 "$dir/appfresh.suite" 2>/dev/null || true)"
        plist="$(_appfresh_prefs_dir)/$suite.plist"
        if [ -n "$suite" ] && [ -f "$plist" ]; then
            if [ "$dry_run" -eq 1 ]; then
                echo "would delete leftover suite $suite ($dir)"
            else
                echo "deleting leftover suite $suite ($dir)"
                defaults delete "$suite" > /dev/null 2>&1 || true
                rm -f "$plist"
            fi
        fi
    fi

    if [ -f "$dir/appfresh.tempdir" ]; then
        tempdir="$(head -n 1 "$dir/appfresh.tempdir" 2>/dev/null || true)"
        if [ -n "$tempdir" ] && [ -d "$tempdir" ]; then
            if [ "$dry_run" -eq 1 ]; then
                echo "would remove leftover app-fresh root $tempdir ($dir)"
            else
                echo "removing leftover app-fresh root $tempdir ($dir)"
                rm -rf "$tempdir"
            fi
        fi
    fi
    return 0
}
