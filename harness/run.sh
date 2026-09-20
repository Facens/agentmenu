#!/bin/bash
# The first-run harness orchestrator: start a run, wait on it, ask what it is
# doing, prove the guest is usable, sweep what a crash left behind.
#
#   harness/run.sh start --app <agentmenu|meetinghop> --tier <stranger|app-fresh>
#                        --scenario <name> [--asset <zip>] [--nonce <hex>] [--verbose]
#   harness/run.sh wait <run-id> [--max-secs N]
#   harness/run.sh status <run-id> [--json]
#   harness/run.sh selfcheck --tier stranger [--list-ids <bundle-id|pid:n>]
#   harness/run.sh clean [--age-days N] [--dry-run]
#
# `start` validates its arguments, refuses when the host already runs two
# macOS guests, allocates a run id, writes dist/harness/<run-id>/report.json
# with status "running", and detaches a supervisor. Its only stdout is the run
# id. The supervisor clones the golden image, boots it, waits for a guest
# shell, hands off to the scenario and compiles the verdict; a trap deletes
# the clone on any exit, including the SIGTERM a watchdog sends it.
#
# Nothing here uses the `wait` builtin to learn the supervisor's exit status —
# the supervisor is not this process's child. The supervisor records its own
# PID and start time, writes its exit code into report.json before it goes,
# and `wait` mirrors that. A supervisor that vanished without writing one
# (SIGKILL, a host crash) is resolved to outcome_kind "harness_error" with
# stale: true rather than reported as running forever.
#
# Exit codes, everywhere under harness/:
#
#   0  pass            the scenario reached its stated end state
#   1  scenario fail   it did not
#   2  usage error     bad arguments, unknown run id, two guests already up
#   3  harness error   the harness could not decide: a watchdog fired, the
#                      guest never came up, the supervisor vanished
#
# `wait` mirrors the run's code. `wait --max-secs` expiring on a run that is
# still alive is a harness error (3), not a pass. `status` is a query: it
# exits 0 whenever it could report, and 2 on an unknown run id.
#
# `selfcheck --tier app-fresh` refuses (exit 2): the self-check proves
# screen grants by clicking the status item and taking a screenshot, which
# only the stranger tier is allowed to do — the app-fresh tier drives no
# screen at all (harness/lib/scenario.sh's own header, fact 3). The
# stranger tier's `selfcheck --tier stranger [--list-ids <bundle-id>]` is
# unchanged.
#
# Environment:
#
#   HARNESS_DIST_ROOT      where run directories live (default dist/harness)
#   HARNESS_SCENARIO_ROOT  where scenarios live (default harness/scenarios)
#   HARNESS_GOLDEN_IMAGE   the image to clone (default first-run-golden)
#   HARNESS_STEP_TIMEOUT, HARNESS_SCENARIO_TIMEOUT, HARNESS_RUN_TIMEOUT
#   HARNESS_IP_TIMEOUT, HARNESS_SSH_TIMEOUT, HARNESS_CLEAN_AGE_DAYS
#   HARNESS_GUEST_USER, HARNESS_GUEST_TRANSPORT, HARNESS_SSH_OPTS
#
# harness/README.md documents the run directory, the scenario contract and
# the shared-file manifest. `__supervise <run-dir>` is internal: `start` forks
# it and nothing else calls it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_DIR="$ROOT/harness"
SELF="$HARNESS_DIR/run.sh"

. "$HARNESS_DIR/lib/common.sh"
. "$HARNESS_DIR/lib/vm.sh"
. "$HARNESS_DIR/lib/watchdog.sh"

DIST_ROOT="${HARNESS_DIST_ROOT:-$ROOT/dist/harness}"
SCENARIO_ROOT="${HARNESS_SCENARIO_ROOT:-$HARNESS_DIR/scenarios}"
GOLDEN_IMAGE="${HARNESS_GOLDEN_IMAGE:-first-run-golden}"

STEP_TIMEOUT="${HARNESS_STEP_TIMEOUT:-120}"
SCENARIO_TIMEOUT="${HARNESS_SCENARIO_TIMEOUT:-1800}"
RUN_TIMEOUT="${HARNESS_RUN_TIMEOUT:-3600}"
IP_TIMEOUT="${HARNESS_IP_TIMEOUT:-180}"
SSH_TIMEOUT="${HARNESS_SSH_TIMEOUT:-300}"
CLEAN_AGE_DAYS="${HARNESS_CLEAN_AGE_DAYS:-14}"

usage() {
    sed -n '2,56p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# Shared checks

# A run id names a directory and a VM clone, so it is validated before it is
# ever joined to a path.
assert_run_id_shape() {
    local id="${1:-}"
    if [ -z "$id" ]; then
        die 2 "a run id is required."
    fi
    case "$id" in
        *[!A-Za-z0-9._-]*) die 2 "the run id '$id' has a character outside [A-Za-z0-9._-]." ;;
    esac
    if [ "${#id}" -gt 128 ]; then
        die 2 "the run id '$id' is longer than 128 characters."
    fi
}

resolve_run_dir() {
    local id="$1"
    assert_run_id_shape "$id"
    if [ ! -f "$DIST_ROOT/$id/report.json" ]; then
        die 2 "there is no run '$id' under $DIST_ROOT."
    fi
    printf '%s' "$DIST_ROOT/$id"
}

supervisor_alive() {
    local dir="$1" pid token
    pid="$(run_report_field "$dir" .supervisor_pid)"
    token="$(run_report_field "$dir" .supervisor_token)"
    proc_matches "$pid" "$token"
}

# Apple's Virtualization framework allows two concurrent macOS guests per
# host, so a third `start` would fail somewhere less legible than here. The
# count is every running VM whatever its name — the maintainer's own VMs take
# the same slots. Stopped harness clones take no slot: they are named, with a
# pointer to `clean`, and they never block.
assert_guest_capacity() {
    local running count stopped
    running="$(vm_names_by_state running)"
    count="$(printf '%s\n' "$running" | grep -c . || true)"
    stopped="$(vm_harness_clones stopped | tr '\n' ' ' | sed 's/ *$//')"
    if [ "$count" -ge 2 ]; then
        echo "error: two macOS guests are already running on this host, which is all the Virtualization framework allows." >&2
        echo "Running now: $(printf '%s\n' "$running" | tr '\n' ' ' | sed 's/ *$//')" >&2
        if [ -n "$stopped" ]; then
            echo "Stopped harness clones (these do not block a run): $stopped" >&2
            echo "Remove them with 'harness/run.sh clean'." >&2
        fi
        echo "Stop one guest and start again." >&2
        exit 2
    fi
    if [ -n "$stopped" ]; then
        warn "stopped harness clones are left over: $stopped — remove them with 'harness/run.sh clean'."
    fi
}

assert_golden_image() {
    if ! vm_exists "$GOLDEN_IMAGE"; then
        echo "error: the golden image '$GOLDEN_IMAGE' is not in 'tart list'." >&2
        echo "Build it with harness/image/build.sh, or point HARNESS_GOLDEN_IMAGE at another image." >&2
        exit 3
    fi
}

# ---------------------------------------------------------------------------
# start

cmd_start() {
    local app="" tier="stranger" scenario="" asset="" nonce="" verbose=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --app|--tier|--scenario|--asset|--nonce)
                if [ $# -lt 2 ]; then die 2 "$1 needs a value."; fi
                case "$1" in
                    --app) app="$2" ;;
                    --tier) tier="$2" ;;
                    --scenario) scenario="$2" ;;
                    --asset) asset="$2" ;;
                    --nonce) nonce="$2" ;;
                esac
                shift 2 ;;
            --verbose) verbose=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) echo "unknown argument: $1" >&2; exit 2 ;;
        esac
    done

    case "$app" in
        agentmenu|meetinghop) ;;
        "") die 2 "--app is required; it is agentmenu or meetinghop." ;;
        *) die 2 "unknown app '$app'; it is agentmenu or meetinghop." ;;
    esac
    case "$tier" in
        stranger|app-fresh) ;;
        *) die 2 "unknown tier '$tier'; it is stranger or app-fresh." ;;
    esac
    if [ -z "$scenario" ]; then
        die 2 "--scenario is required."
    fi
    case "$scenario" in
        *[!A-Za-z0-9._-]*) die 2 "the scenario name '$scenario' has a character outside [A-Za-z0-9._-]." ;;
    esac
    local scenario_path="$SCENARIO_ROOT/$app/$scenario.sh"
    if [ ! -f "$scenario_path" ]; then
        echo "error: there is no scenario '$scenario' for $app." >&2
        echo "Expected it at $scenario_path." >&2
        exit 2
    fi
    if [ "$tier" = "stranger" ]; then
        if [ -z "$asset" ]; then
            die 2 "--asset is required on the stranger tier; it is the zip the release workflow produced."
        fi
    fi
    # Both refusals below are app-agnostic (no bundle id, no app-specific
    # path) and belong here rather than in lib/appfresh.sh: a usage error has
    # to surface as exit 2 from this synchronous command, before a run
    # directory exists, and prepare_app_fresh() only ever runs later, inside
    # the detached supervisor, where the taxonomy has no way back to 2 (see
    # cmd_supervise's own scenario_rc mapping — anything but 0/1 there
    # becomes 3, never 2).
    if [ "$tier" = "app-fresh" ]; then
        if [ "$verbose" -eq 1 ]; then
            die 2 "--verbose is not accepted on the app-fresh tier; it always confines the journal to the standard fixture echo."
        fi
        if grep -q '^# HARNESS_STRANGER_ONLY' "$scenario_path" 2>/dev/null; then
            die 2 "the scenario '$scenario' is stranger-only (see $scenario_path) and cannot run on the app-fresh tier."
        fi
    fi
    if [ -n "$asset" ] && [ ! -r "$asset" ]; then
        die 2 "the asset '$asset' is not a readable file."
    fi
    if [ -z "$nonce" ]; then
        nonce="$(rand_hex 16)"
    fi
    case "$nonce" in
        *[!A-Za-z0-9._-]*) die 2 "the nonce has a character outside [A-Za-z0-9._-]." ;;
    esac

    require_cmd jq shasum
    if [ "$tier" = "stranger" ]; then
        require_cmd tart ssh scp
        assert_guest_capacity
        assert_golden_image
    fi

    # Everything above refuses before a run directory exists, so a usage
    # error leaves nothing behind under dist/harness/.
    local run_id run_dir asset_sha=""
    run_id="$(new_run_id "$app" "$tier" "$scenario")"
    run_dir="$DIST_ROOT/$run_id"
    mkdir -p "$run_dir/screenshots"
    : > "$run_dir/journal.ndjson"
    : > "$run_dir/evidence.ndjson"
    : > "$run_dir/steps.ndjson"
    : > "$run_dir/findings.list"
    : > "$run_dir/supervisor.log"
    if [ -n "$asset" ]; then
        asset_sha="$(shasum -a 256 "$asset" | awk '{ print $1 }')"
    fi

    run_report_write "$run_dir" "$(jq -n \
        --arg run_id "$run_id" --arg nonce "$nonce" --arg app "$app" --arg tier "$tier" \
        --arg scenario "$scenario" --arg scenario_path "$scenario_path" --arg asset "$asset" \
        --arg asset_sha256 "$asset_sha" --arg golden "$GOLDEN_IMAGE" --arg run_dir "$run_dir" \
        --arg started_at "$(now_iso)" '{
            run_id: $run_id,
            nonce: $nonce,
            app: $app,
            tier: $tier,
            scenario: $scenario,
            scenario_path: $scenario_path,
            asset: (if $asset == "" then null else $asset end),
            asset_sha256: (if $asset_sha256 == "" then null else $asset_sha256 end),
            golden_image: $golden,
            clone: null,
            image: null,
            status: "running",
            verdict: null,
            outcome_kind: null,
            stale: false,
            supervisor_pid: null,
            supervisor_token: null,
            findings: [],
            retries: 0,
            steps: [],
            started_at: $started_at,
            ended_at: null,
            exit_code: null,
            run_dir: $run_dir
        }')"

    # The handover. The supervisor blocks on start.ok, so the moment it
    # appears this process is done writing report.json and the supervisor owns
    # it — no window where both could write, and none where `status` cannot
    # resolve the supervisor because its PID has not been recorded yet.
    local sup_pid sup_token
    nohup bash "$SELF" __supervise "$run_dir" >> "$run_dir/supervisor.log" 2>&1 < /dev/null &
    sup_pid=$!
    sup_token="$(proc_start_token "$sup_pid")"
    printf '%s\n%s\n' "$sup_pid" "$sup_token" > "$run_dir/supervisor.pid"
    run_report_merge "$run_dir" "$(jq -n --arg pid "$sup_pid" --arg token "$sup_token" \
        '{supervisor_pid: ($pid | tonumber), supervisor_token: $token}')"
    : > "$run_dir/start.ok"

    printf '%s\n' "$run_id"
}

# ---------------------------------------------------------------------------
# The supervisor

RUN_DIR=""
RUN_ID=""
APP=""
TIER=""
SCENARIO=""
CLONE_NAME=""
GUEST_IP=""
SCENARIO_PID=""
RETRIES=0
INTERRUPTED=""
TEARDOWN_DONE=""
FINAL_EXIT=3

cmd_supervise() {
    local run_dir="${1:-}"
    if [ -z "$run_dir" ] || [ ! -f "$run_dir/report.json" ]; then
        die 3 "the supervisor needs a run directory that already carries a report."
    fi
    RUN_DIR="$run_dir"
    export HARNESS_RUN_DIR="$run_dir"

    # Wait for `start` to finish writing the report before touching it.
    local waited=0
    while [ ! -f "$run_dir/start.ok" ]; do
        if [ "$waited" -ge 300 ]; then
            die 3 "the supervisor never saw start.ok; the handover from 'start' did not complete."
        fi
        sleep 0.1
        waited=$((waited + 1))
    done

    RUN_ID="$(run_report_field "$RUN_DIR" .run_id)"
    APP="$(run_report_field "$RUN_DIR" .app)"
    TIER="$(run_report_field "$RUN_DIR" .tier)"
    SCENARIO="$(run_report_field "$RUN_DIR" .scenario)"

    trap 'on_signal INT' INT
    trap 'on_signal TERM' TERM
    trap 'on_signal HUP' HUP
    trap teardown EXIT

    # The run's own bound. It terminates the supervisor, not its process
    # group: the trap below is what tears the clone down, and group-killing
    # would signal the watchdog and race that teardown.
    watchdog_start "$RUN_TIMEOUT" "$$" run

    log "supervisor $$ for $RUN_ID ($APP/$TIER/$SCENARIO)"

    if [ "$TIER" = "stranger" ]; then
        if ! provision_stranger; then
            die 3 "the guest could not be provisioned after a retry."
        fi
        read_image_inputs
    else
        prepare_app_fresh
    fi

    local scenario_rc=0
    if run_scenario; then scenario_rc=0; else scenario_rc=$?; fi
    log "scenario returned $scenario_rc"

    case "$scenario_rc" in
        0) exit 0 ;;
        1) exit 1 ;;
        *) exit 3 ;;
    esac
}

on_signal() {
    INTERRUPTED="$1"
    log "supervisor received SIG$1"
    exit 3
}

# Runs on every exit, including the watchdog's SIGTERM and a Ctrl-C forwarded
# by `wait`. Idempotent: `exit` from inside a signal trap re-enters this.
teardown() {
    local rc=$?
    if [ -n "$TEARDOWN_DONE" ]; then
        exit "$rc"
    fi
    TEARDOWN_DONE=1
    trap - EXIT INT TERM HUP

    watchdog_stop_all
    if [ -n "$SCENARIO_PID" ]; then
        kill -TERM "-$SCENARIO_PID" 2>/dev/null || true
    fi
    if [ -n "$CLONE_NAME" ]; then
        bounded_run 120 vm_delete "$CLONE_NAME" \
            || warn "the clone $CLONE_NAME could not be deleted; 'harness/run.sh clean' will sweep it."
    fi
    # Only defined when lib/appfresh.sh was sourced (the app-fresh tier
    # only): quits the app, tears down its isolated root, and — on a
    # maintainer-state mismatch — leaves a watchdog-appfresh-snapshot.fired
    # marker that finalize() below picks up the same way it already does for
    # a real watchdog (see lib/appfresh.sh's own header for why the severity
    # is decided that way rather than by this function's return code).
    if declare -F appfresh_teardown > /dev/null 2>&1; then
        bounded_run 120 appfresh_teardown \
            || warn "app-fresh teardown did not complete; 'harness/run.sh clean' will sweep what is left."
    fi
    finalize "$rc"
    exit "$FINAL_EXIT"
}

# The verdict is a fact about the scenario; outcome_kind is a fact about the
# run. A watchdog that fired or a signal that arrived outranks whatever the
# scenario's exit status said, because neither means the scenario decided.
finalize() {
    local rc="$1" verdict outcome exit_code steps findings
    if watchdog_any_fired; then
        verdict="error"; outcome="harness_error"; exit_code=3
    elif [ -n "$INTERRUPTED" ]; then
        verdict="error"; outcome="harness_error"; exit_code=3
    else
        case "$rc" in
            0) verdict="pass"; outcome="pass"; exit_code=0 ;;
            1) verdict="fail"; outcome="scenario_fail"; exit_code=1 ;;
            *) verdict="error"; outcome="harness_error"; exit_code=3 ;;
        esac
    fi
    FINAL_EXIT="$exit_code"

    steps="$(jq -s '.' "$RUN_DIR/steps.ndjson" 2>/dev/null || echo '[]')"
    findings="$(jq -R -s 'split("\n") | map(select(length > 0)) | unique' "$RUN_DIR/findings.list" 2>/dev/null || echo '[]')"

    run_report_merge "$RUN_DIR" "$(jq -n \
        --arg verdict "$verdict" --arg outcome "$outcome" --arg ended_at "$(now_iso)" \
        --arg clone "$CLONE_NAME" --argjson exit_code "$exit_code" --argjson retries "$RETRIES" \
        --argjson steps "$steps" --argjson findings "$findings" '{
            status: "finished",
            verdict: $verdict,
            outcome_kind: $outcome,
            stale: false,
            exit_code: $exit_code,
            retries: $retries,
            steps: $steps,
            findings: $findings,
            clone: (if $clone == "" then null else $clone end),
            ended_at: $ended_at
        }')"
    log "$RUN_ID: $verdict ($outcome), exit $exit_code"
}

# Clone, boot, a guest shell and the guest tree copied in — the three steps
# KTD6 allows a retry for, retried once as a whole on a fresh clone.
provision_stranger() {
    local attempt=1
    CLONE_NAME="${HARNESS_CLONE_PREFIX}${RUN_ID}"
    while : ; do
        # Written before the clone exists: a crash between naming it and
        # creating it must still leave `clean` something to correlate.
        printf '%s\n' "$CLONE_NAME" > "$RUN_DIR/clone.name"
        run_report_merge "$RUN_DIR" "$(jq -n --arg clone "$CLONE_NAME" '{clone: $clone}')"
        if provision_attempt; then
            return 0
        fi
        if [ "$attempt" -ge 2 ]; then
            return 1
        fi
        warn "provisioning failed; retrying once on a fresh clone."
        vm_delete "$CLONE_NAME" || true
        attempt=$((attempt + 1))
        RETRIES=1
        run_report_merge "$RUN_DIR" '{"retries": 1}'
    done
}

provision_attempt() {
    vm_clone "$GOLDEN_IMAGE" "$CLONE_NAME" || return 1
    vm_boot "$CLONE_NAME" || return 1
    GUEST_IP="$(vm_ip "$CLONE_NAME" "$IP_TIMEOUT")" || return 1
    vm_wait_ssh "$GUEST_IP" "$SSH_TIMEOUT" || return 1
    copy_in_guest_tree || return 1
    return 0
}

# The harness tree goes to ~/.harness/ in the guest, so guest scripts live at
# ~/.harness/guest/<name> and never have to know the user name.
copy_in_guest_tree() {
    guest_run "$GUEST_IP" "mkdir -p ~/$HARNESS_GUEST_HOME/shots" || return 1
    if [ -d "$HARNESS_DIR/guest" ]; then
        guest_copy_in "$GUEST_IP" "$HARNESS_DIR/guest" "$HARNESS_GUEST_HOME/" || return 1
        guest_run "$GUEST_IP" "chmod -R u+rx ~/$HARNESS_GUEST_HOME/guest" || true
    else
        warn "harness/guest is not in this checkout; the scenario has no in-guest driver."
    fi
    if [ -d "$HARNESS_DIR/fixtures" ]; then
        guest_copy_in "$GUEST_IP" "$HARNESS_DIR/fixtures" "$HARNESS_GUEST_HOME/" || return 1
    fi
    return 0
}

# The image's build inputs, recorded by U1's recipe, so a change in any of
# them is visible in every report. Their absence is worth a warning, not a
# failed run.
read_image_inputs() {
    local json=""
    json="$(guest_run "$GUEST_IP" cat /etc/first-run-golden.json 2>/dev/null || true)"
    if [ -n "$json" ] && printf '%s' "$json" | jq -e . > /dev/null 2>&1; then
        run_report_merge "$RUN_DIR" "$(jq -n --argjson image "$json" '{image: $image}')"
    else
        warn "the guest did not report /etc/first-run-golden.json; the report records no image inputs."
    fi
}

prepare_app_fresh() {
    if [ ! -f "$HARNESS_DIR/lib/appfresh.sh" ]; then
        echo "error: the app-fresh tier needs harness/lib/appfresh.sh, which is not in this checkout." >&2
        echo "Run the stranger tier, or add the app-fresh library." >&2
        exit 3
    fi
    . "$HARNESS_DIR/lib/appfresh.sh"
    HARNESS_GUEST_TRANSPORT="local"
    GUEST_IP="local"
    appfresh_prepare "$RUN_DIR" || die 3 "the app-fresh root could not be prepared."
}

# The scenario is a separate process in its own process group, so the
# per-scenario watchdog can take down everything it spawned — ssh, osascript,
# screencapture — and not only the script itself.
run_scenario() {
    local path rc=0
    path="$(run_report_field "$RUN_DIR" .scenario_path)"
    if [ ! -f "$path" ]; then
        die 3 "the scenario $path disappeared between start and the run."
    fi

    export HARNESS_ROOT="$ROOT"
    export HARNESS_DIR
    export HARNESS_RUN_DIR="$RUN_DIR"
    export HARNESS_RUN_ID="$RUN_ID"
    export HARNESS_APP="$APP"
    export HARNESS_TIER="$TIER"
    export HARNESS_SCENARIO="$SCENARIO"
    export HARNESS_ASSET="$(run_report_field "$RUN_DIR" .asset)"
    export HARNESS_ASSET_SHA256="$(run_report_field "$RUN_DIR" .asset_sha256)"
    export HARNESS_NONCE="$(run_report_field "$RUN_DIR" .nonce)"
    export HARNESS_CLONE="$CLONE_NAME"
    export HARNESS_GUEST_IP="$GUEST_IP"
    export HARNESS_GUEST_USER HARNESS_GUEST_HOME HARNESS_GUEST_TRANSPORT
    export HARNESS_SHOT_DIR="$RUN_DIR/screenshots"
    export HARNESS_JOURNAL="$RUN_DIR/journal.ndjson"
    export HARNESS_EVIDENCE="$RUN_DIR/evidence.ndjson"
    export HARNESS_STEPS="$RUN_DIR/steps.ndjson"
    export HARNESS_FINDINGS="$RUN_DIR/findings.list"
    export HARNESS_STEP_TIMEOUT="$STEP_TIMEOUT"

    log "running scenario $path"
    set -m
    bash "$path" &
    SCENARIO_PID=$!
    set +m
    watchdog_start "$SCENARIO_TIMEOUT" "-$SCENARIO_PID" scenario
    if wait "$SCENARIO_PID"; then rc=0; else rc=$?; fi
    watchdog_stop
    SCENARIO_PID=""
    return "$rc"
}

# ---------------------------------------------------------------------------
# wait

cmd_wait() {
    local run_id="" max_secs=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --max-secs)
                if [ $# -lt 2 ]; then die 2 "--max-secs needs a value."; fi
                max_secs="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            -*) echo "unknown argument: $1" >&2; exit 2 ;;
            *)
                if [ -n "$run_id" ]; then echo "unknown argument: $1" >&2; exit 2; fi
                run_id="$1"; shift ;;
        esac
    done
    case "$max_secs" in
        ''|*[!0-9]*) die 2 "--max-secs takes a whole number of seconds." ;;
    esac

    local dir pid token ticks=0
    dir="$(resolve_run_dir "$run_id")"
    pid="$(run_report_field "$dir" .supervisor_pid)"
    token="$(run_report_field "$dir" .supervisor_token)"

    # Ctrl-C here tears the run down rather than leaving a clone behind.
    trap 'forward_signal_to_supervisor "$pid" "$token"' INT TERM

    while proc_matches "$pid" "$token"; do
        if [ "$max_secs" -gt 0 ] && [ "$ticks" -ge $((max_secs * 5)) ]; then
            echo "error: run $run_id was still going after ${max_secs}s." >&2
            echo "It is still running; ask 'harness/run.sh status $run_id' or wait again." >&2
            exit 3
        fi
        sleep 0.2
        ticks=$((ticks + 1))
    done
    trap - INT TERM

    report_outcome "$dir" "$run_id"
}

forward_signal_to_supervisor() {
    local pid="$1" token="$2"
    if proc_matches "$pid" "$token"; then
        warn "interrupted; asking supervisor $pid to tear the run down."
        kill -TERM "$pid" 2>/dev/null || true
    fi
    exit 3
}

# The supervisor is gone. Either it wrote its exit code before it went, or it
# never got the chance — which is what stale means.
report_outcome() {
    local dir="$1" run_id="$2" code verdict outcome
    code="$(run_report_field "$dir" .exit_code)"
    if [ -z "$code" ]; then
        resolve_stale "$dir"
        code=3
    fi
    verdict="$(run_report_field "$dir" .verdict)"
    outcome="$(run_report_field "$dir" .outcome_kind)"
    printf '%s: %s (%s) — %s/report.json\n' "$run_id" "${verdict:-unknown}" "${outcome:-unknown}" "$dir"
    exit "$code"
}

resolve_stale() {
    local dir="$1"
    run_report_merge "$dir" "$(jq -n --arg ended_at "$(now_iso)" '{
        status: "finished",
        stale: true,
        verdict: "error",
        outcome_kind: "harness_error",
        exit_code: 3,
        ended_at: $ended_at
    }')"
    warn "the supervisor for this run is gone and never recorded an exit code; resolved to harness_error."
}

# ---------------------------------------------------------------------------
# status

cmd_status() {
    local run_id="" as_json=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --json) as_json=1; shift ;;
            -h|--help) usage; exit 0 ;;
            -*) echo "unknown argument: $1" >&2; exit 2 ;;
            *)
                if [ -n "$run_id" ]; then echo "unknown argument: $1" >&2; exit 2; fi
                run_id="$1"; shift ;;
        esac
    done

    local dir step shot
    dir="$(resolve_run_dir "$run_id")"
    if ! supervisor_alive "$dir"; then
        if [ -z "$(run_report_field "$dir" .exit_code)" ]; then
            resolve_stale "$dir"
        fi
    fi

    if [ "$as_json" -eq 1 ]; then
        cat "$dir/report.json"
        exit 0
    fi

    step="$(tail -n 1 "$dir/steps.ndjson" 2>/dev/null | jq -r '.step // empty' 2>/dev/null || true)"
    shot="$(tail -n 1 "$dir/steps.ndjson" 2>/dev/null | jq -r '.screenshot // empty' 2>/dev/null || true)"
    if [ -z "$shot" ]; then
        shot="$(ls -t "$dir/screenshots" 2>/dev/null | head -n 1 || true)"
        if [ -n "$shot" ]; then
            shot="$dir/screenshots/$shot"
        fi
    fi

    printf 'run:        %s\n' "$run_id"
    printf 'status:     %s\n' "$(run_report_field "$dir" .status)"
    local verdict outcome
    verdict="$(run_report_field "$dir" .verdict)"
    outcome="$(run_report_field "$dir" .outcome_kind)"
    printf 'verdict:    %s\n' "${verdict:-(not decided yet)}"
    printf 'outcome:    %s\n' "${outcome:-(not decided yet)}"
    printf 'stale:      %s\n' "$(jq -r '.stale' "$dir/report.json")"
    printf 'retries:    %s\n' "$(jq -r '.retries' "$dir/report.json")"
    printf 'step:       %s\n' "${step:-(none recorded yet)}"
    printf 'screenshot: %s\n' "${shot:-(none yet)}"
    printf 'report:     %s\n' "$dir/report.json"
    exit 0
}

# ---------------------------------------------------------------------------
# clean

cmd_clean() {
    local age_days="$CLEAN_AGE_DAYS" dry_run=0
    while [ $# -gt 0 ]; do
        case "$1" in
            --age-days)
                if [ $# -lt 2 ]; then die 2 "--age-days needs a value."; fi
                age_days="$2"; shift 2 ;;
            --dry-run) dry_run=1; shift ;;
            -h|--help) usage; exit 0 ;;
            *) echo "unknown argument: $1" >&2; exit 2 ;;
        esac
    done
    case "$age_days" in
        ''|*[!0-9]*) die 2 "--age-days takes a whole number of days." ;;
    esac

    require_cmd jq
    local clone dir swept=0
    if command -v tart > /dev/null 2>&1; then
        for clone in $(vm_harness_clones); do
            if clone_is_held "$clone"; then
                echo "kept    $clone (a live run holds it)"
                continue
            fi
            if [ "$dry_run" -eq 1 ]; then
                echo "would delete $clone"
            else
                echo "deleting $clone"
                vm_delete "$clone"
            fi
            swept=$((swept + 1))
        done
    else
        warn "tart is not on PATH; only run directories were considered."
    fi

    if [ -d "$DIST_ROOT" ]; then
        for dir in $(find "$DIST_ROOT" -maxdepth 1 -mindepth 1 -type d -mtime +"$age_days" 2>/dev/null || true); do
            if supervisor_alive "$dir" 2>/dev/null; then
                echo "kept    $dir (its supervisor is still running)"
                continue
            fi
            if [ "$dry_run" -eq 1 ]; then
                echo "would remove $dir"
            else
                echo "removing $dir"
                rm -rf "$dir"
            fi
            swept=$((swept + 1))
        done
    fi

    # The app-fresh tier's own leftovers: a suite plist in
    # ~/Library/Preferences and an isolated-root TempDir, neither of which
    # the age-gated sweep above ever reaches (a plist is not a run
    # directory, and this must not wait out --age-days to give a
    # maintainer's Preferences folder back). Generic: sourced only if the
    # tier's own library is in this checkout, exactly like
    # prepare_app_fresh() already does.
    if [ -f "$HARNESS_DIR/lib/appfresh.sh" ]; then
        . "$HARNESS_DIR/lib/appfresh.sh"
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            echo "$line"
            swept=$((swept + 1))
        done < <(appfresh_clean "$DIST_ROOT" "$dry_run")
    fi

    echo "clean: $swept item(s)"
}

# A clone belongs to a run that is still going: its run directory names it and
# that run's supervisor is alive. Deleting it would kill a live run's guest.
clone_is_held() {
    local clone="$1" name_file
    for name_file in "$DIST_ROOT"/*/clone.name; do
        [ -f "$name_file" ] || continue
        if [ "$(cat "$name_file")" = "$clone" ]; then
            if supervisor_alive "$(dirname "$name_file")"; then
                return 0
            fi
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# selfcheck

cmd_selfcheck() {
    local tier="" list_ids=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --tier|--list-ids)
                if [ $# -lt 2 ]; then die 2 "$1 needs a value."; fi
                case "$1" in
                    --tier) tier="$2" ;;
                    --list-ids) list_ids="$2" ;;
                esac
                shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) echo "unknown argument: $1" >&2; exit 2 ;;
        esac
    done
    case "$tier" in
        stranger|app-fresh) ;;
        "") die 2 "--tier is required; it is stranger or app-fresh." ;;
        *) die 2 "unknown tier '$tier'; it is stranger or app-fresh." ;;
    esac

    # This self-check exists to prove screen grants: it clicks the app's
    # status item and takes a screenshot, so a maintainer can see screen
    # recording and accessibility are actually working. That is exactly
    # the "clicks, screenshots or waits on a window" the plan's tier
    # decision reserves for the stranger tier alone — the app-fresh tier
    # shares the maintainer's own display and drives no screen (see
    # harness/lib/scenario.sh's own header, fact 3). This used to launch
    # an isolated AgentMenu instance and press its status item to answer
    # the question on this tier too; that is the incident this refuses —
    # two menu-bar icons clicking themselves while the maintainer was away
    # — so the capability is gone here, not merely unused: nothing is
    # built, launched or probed before this refusal fires.
    if [ "$tier" = "app-fresh" ]; then
        echo "error: selfcheck proves screen grants by clicking the status item and taking a screenshot, which only the stranger tier is allowed to do; the app-fresh tier drives no screen." >&2
        exit 2
    fi

    require_cmd jq
    if [ ! -f "$HARNESS_DIR/guest/selfcheck.sh" ]; then
        echo "error: harness/guest/selfcheck.sh is not in this checkout." >&2
        echo "The in-guest driver library provides it." >&2
        exit 3
    fi

    TIER="$tier"
    RUN_ID="$(new_run_id selfcheck "$tier" guest)"
    RUN_DIR="$DIST_ROOT/$RUN_ID"
    mkdir -p "$RUN_DIR/screenshots"
    export HARNESS_RUN_DIR="$RUN_DIR"

    # A selfcheck is its own supervisor: it runs in the foreground, and it
    # records the same PID and start token a run does, so `clean` can tell
    # that the clone it is looking at belongs to a live selfcheck. The report
    # has to exist before provisioning, which merges the clone name into it.
    run_report_write "$RUN_DIR" "$(jq -n \
        --arg run_id "$RUN_ID" --arg tier "$tier" --arg golden "$GOLDEN_IMAGE" --arg run_dir "$RUN_DIR" \
        --arg started_at "$(now_iso)" --arg pid "$$" --arg token "$(proc_start_token $$)" '{
            run_id: $run_id,
            nonce: null,
            app: null,
            tier: $tier,
            scenario: "selfcheck",
            scenario_path: null,
            asset: null,
            asset_sha256: null,
            golden_image: $golden,
            clone: null,
            image: null,
            status: "running",
            verdict: null,
            outcome_kind: null,
            stale: false,
            supervisor_pid: ($pid | tonumber),
            supervisor_token: $token,
            findings: [],
            retries: 0,
            steps: [],
            started_at: $started_at,
            ended_at: null,
            exit_code: null,
            run_dir: $run_dir
        }')"
    trap selfcheck_teardown EXIT INT TERM HUP

    local out="" rc=0 arg=""
    if [ -n "$list_ids" ]; then
        arg=" --list-ids $list_ids"
    fi

    # Only the stranger tier ever reaches here — app-fresh already refused
    # above, before a run directory existed at all.
    require_cmd tart ssh scp
    assert_guest_capacity
    assert_golden_image
    if ! provision_stranger; then
        die 3 "the guest could not be provisioned after a retry."
    fi
    if out="$(guest_run "$GUEST_IP" "bash ~/$HARNESS_GUEST_HOME/guest/selfcheck.sh --shot-dir ~/$HARNESS_GUEST_HOME/shots$arg")"; then rc=0; else rc=$?; fi
    guest_copy_out "$GUEST_IP" "$HARNESS_GUEST_HOME/shots/." "$RUN_DIR/screenshots/" || true

    printf '%s\n' "$out"
    if printf '%s' "$out" | jq -e . > /dev/null 2>&1; then
        # These six keys are exactly what guest/selfcheck.sh prints — see
        # its own header. A "grants:" field never existed there; the run
        # summary used to ask for one anyway and always printed an empty
        # line (the real defect this replaces).
        #
        # "identifiers" is the one field guest/selfcheck.sh's own contract
        # lets this tell "never probed" (null, no target was given at all)
        # apart from "probed, found nothing" ([], a real finding once
        # --list-ids names something to probe) — so it is the
        # signal the other three lines key off of. automation,
        # statusitem_idiom and popover_survived collapse "not probed" and
        # "probed, inconclusive" onto the same null in guest/selfcheck.sh's
        # own JSON (e.g. a pid: target's statusclick coming back
        # "kind":"notfound" — U-defect-2's SystemUIServer refusal — still
        # leaves automation null, though a real probe ran). Once
        # identifiers is non-null, that null is honestly printed as-is
        # rather than mislabelled "not probed".
        printf 'grants:      screencapture=%s, system_events=%s\n' \
            "$(printf '%s' "$out" | jq -r '.screencapture')" \
            "$(printf '%s' "$out" | jq -r '.system_events')"
        if printf '%s' "$out" | jq -e '.identifiers == null' > /dev/null 2>&1; then
            printf 'automation:  not probed (no target given)\n'
            printf 'statusitem:  not probed (no target given)\n'
            printf 'identifiers: not probed (no target given)\n'
            printf 'popover:     not probed (no target given)\n'
        else
            printf 'automation:  %s\n' "$(printf '%s' "$out" | jq -r '.automation | tostring')"
            printf 'statusitem:  %s\n' "$(printf '%s' "$out" | jq -r '.statusitem_idiom // "null"')"
            printf 'identifiers: %s\n' "$(printf '%s' "$out" | jq -r '
                if (.identifiers | length) == 0 then "(none found)"
                else (.identifiers | join(", "))
                end')"
            printf 'popover:     %s\n' "$(printf '%s' "$out" | jq -r '.popover_survived | tostring')"
        fi
    else
        warn "harness/guest/selfcheck.sh did not print one JSON object."
    fi
    printf 'screenshots: %s\n' "$RUN_DIR/screenshots"
    exit "$rc"
}

selfcheck_teardown() {
    local rc=$?
    if [ -n "$TEARDOWN_DONE" ]; then
        exit "$rc"
    fi
    TEARDOWN_DONE=1
    trap - EXIT INT TERM HUP
    if [ -n "$CLONE_NAME" ]; then
        bounded_run 120 vm_delete "$CLONE_NAME" \
            || warn "the clone $CLONE_NAME could not be deleted; 'harness/run.sh clean' will sweep it."
    fi
    # No lib/appfresh.sh guard here (contrast run.sh's own teardown()
    # above, which a real app-fresh scenario run still uses): the
    # app-fresh tier now refuses before prepare_app_fresh ever sources
    # that file, so this trap only ever has a VM clone to sweep.
    if [ -n "$RUN_DIR" ] && [ -f "$RUN_DIR/report.json" ]; then
        local verdict outcome
        case "$rc" in
            0) verdict="pass"; outcome="pass" ;;
            1) verdict="fail"; outcome="scenario_fail" ;;
            *) verdict="error"; outcome="harness_error" ;;
        esac
        run_report_merge "$RUN_DIR" "$(jq -n \
            --arg verdict "$verdict" --arg outcome "$outcome" --arg ended_at "$(now_iso)" \
            --arg clone "$CLONE_NAME" --argjson exit_code "$rc" --argjson retries "$RETRIES" '{
                status: "finished",
                verdict: $verdict,
                outcome_kind: $outcome,
                stale: false,
                exit_code: $exit_code,
                retries: $retries,
                clone: (if $clone == "" then null else $clone end),
                ended_at: $ended_at
            }')" || true
    fi
    exit "$rc"
}

# ---------------------------------------------------------------------------

COMMAND="${1:-}"
if [ $# -gt 0 ]; then
    shift
fi
case "$COMMAND" in
    start)       cmd_start "$@" ;;
    wait)        cmd_wait "$@" ;;
    status)      cmd_status "$@" ;;
    selfcheck)   cmd_selfcheck "$@" ;;
    clean)       cmd_clean "$@" ;;
    __supervise) cmd_supervise "$@" ;;
    -h|--help)   usage; exit 0 ;;
    "")          usage >&2; exit 2 ;;
    *)           echo "unknown argument: $COMMAND" >&2; exit 2 ;;
esac
