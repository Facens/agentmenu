#!/bin/bash
# Builds the first-run-golden Tart image (Unit U1 / KTD1): a vanilla macOS
# desktop with Gatekeeper on, SIP off, the harness driver's TCC grants
# seeded, Claude Code installed and not logged in, Terminal.app as the only
# terminal. See README.md for the full recipe, prerequisites, and what to do
# when a stage fails.
#
# Four stages, run in order:
#   0. Install: `tart create --from-ipsw` into first-run-base, a macOS that
#      has never booted past the start of Setup Assistant. Done once and
#      kept; the IPSW's SHA-256 and the Tart version are recorded beside it
#      under the image cache, so later builds neither re-download nor re-hash
#      tens of gigabytes. --rebuild-base makes it again; --base <vm> uses
#      some other local VM in its place (for iterating on the template).
#   1. Setup Assistant (Packer, harness/image/vanilla-tahoe.pkr.hcl): clones
#      the base into first-run-golden-<build-id> and drives Setup Assistant
#      screen by screen with the plugin's OCR waits and clicks; admin/admin,
#      auto-login, Remote Login, Gatekeeper left on. --terms picks how the
#      Terms and Conditions screen is passed (click, voiceover, manual). The
#      plugin's OCR waits never time out on their own, so both packer stages
#      run under two bounds: a stall cap (HARNESS_IMAGE_STALL_CAP seconds of
#      guest activity with the same label on screen, default 300, 1800 for
#      --terms manual) and a wall-clock cap (HARNESS_IMAGE_STAGE_CAP, default
#      3600). On expiry this script stops the guest, which makes packer fail
#      rather than be cancelled, and `-on-error=abort` keeps the plugin's
#      cleanup from deleting the per-build VM. The last screen packer was
#      looking for is printed from its log.
#   2. SIP off (Packer, harness/image/disable-sip.pkr.hcl): recovery-mode
#      `csrutil disable`, its three prompts answered; provision.sh checks
#      `csrutil status` in the booted guest, since packer cannot.
#   3. harness/image/provision.sh (plain SSH, not Packer): the harness ssh
#      key installed and proven (the harness logs in with BatchMode=yes; the
#      key is generated once beside the image cache), TCC seeding,
#      Automation Mode, locale/clock, Software Update off, Claude Code
#      installed, /etc/first-run-golden.json written (including
#      `manual_steps`, which names the Terms click when --terms manual ran).
# and a final `tart clone first-run-golden-<build-id> first-run-golden`,
# after which harness/image/verify.sh runs against a throwaway clone of the
# result (skip with --skip-verify).
#
# The per-build VM (first-run-golden-<build-id>) is kept, not deleted, after
# a successful build -- it is the actual build output; "first-run-golden" is
# a clone of it kept as the stable name later units and verify.sh clone from
# for each test run (a golden image is never run directly). An existing
# first-run-golden is refused without --force, and even with --force it is
# only deleted immediately before the final clone, after every stage has
# succeeded -- never up front, so a broken stage never costs you the working
# image you already had.
#
# Usage:
#   build.sh [--force] [--ipsw <url-or-local-path>] [--base <vm>] [--rebuild-base]
#            [--terms click|voiceover|manual] [--skip-verify]
#
# --force         replace an existing first-run-golden once the new build
#                 succeeds (the per-build VM it was cloned from is never
#                 touched by this).
# --ipsw PATH     build first-run-base from this IPSW instead of the URL
#                 recorded in vanilla-tahoe.pkr.hcl's ipsw_path variable.
# --base VM       clone stage 1 from this local VM instead of first-run-base
#                 (it must be an install that has never booted past the start
#                 of Setup Assistant). No IPSW hash is recorded for it; the
#                 image says so. Not for the golden image you keep.
# --rebuild-base  delete and re-create first-run-base from the IPSW.
# --terms MODE    how Terms and Conditions is passed: click (default),
#                 voiceover, or manual (you click Agree twice in the packer
#                 window; the build records that it happened).
# --skip-verify   do not run verify.sh at the end.
#
# Exit codes: 0 success, 2 bad arguments or first-run-golden already exists
# without --force, 3 the tooling broke or a stage failed. This script's last
# action is running verify.sh (unless --skip-verify), so it can also exit 1
# if a check on the freshly built image failed -- read verify.sh's own
# output in that case, the image built but something in it isn't right.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELF_DIR="$ROOT/harness/image"

usage() { sed -n '2,73p' "$0" | sed 's/^# \{0,1\}//'; }

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    usage
    exit 0
fi

FORCE=0
IPSW_OVERRIDE=""
BASE_OVERRIDE=""
REBUILD_BASE=0
TERMS_MODE="click"
SKIP_VERIFY=0

while [ $# -gt 0 ]; do
    case "$1" in
        --force) FORCE=1; shift ;;
        --ipsw|--base|--terms)
            [ $# -ge 2 ] || { echo "error: $1 needs a value." >&2; exit 2; }
            case "$1" in
                --ipsw) IPSW_OVERRIDE="$2" ;;
                --base) BASE_OVERRIDE="$2" ;;
                --terms) TERMS_MODE="$2" ;;
            esac
            shift 2 ;;
        --rebuild-base) REBUILD_BASE=1; shift ;;
        --skip-verify) SKIP_VERIFY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "error: unknown argument: $1." >&2; exit 2 ;;
    esac
done

case "$TERMS_MODE" in
    click|voiceover|manual) ;;
    *) echo "error: --terms must be click, voiceover or manual, not '$TERMS_MODE'." >&2; exit 2 ;;
esac
if [ -n "$BASE_OVERRIDE" ] && [ "$REBUILD_BASE" -eq 1 ]; then
    echo "error: --base and --rebuild-base contradict each other: --base skips the install stage." >&2
    exit 2
fi
case "$BASE_OVERRIDE" in
    *[!A-Za-z0-9._-]*) echo "error: --base must be a plain Tart VM name, not '$BASE_OVERRIDE'." >&2; exit 2 ;;
esac

# This unit's deliverable is the recipe, not an executed build: tart and
# packer are not expected to be on the machine that wrote this script, only
# on the machine that runs it. Check everything up front so a missing tool
# fails immediately with a fix, not partway through a multi-hour build.
MISSING=""
for tool in tart packer curl shasum jq expect ssh scp; do
    command -v "$tool" >/dev/null 2>&1 || MISSING="$MISSING $tool"
done
if [ -n "$MISSING" ]; then
    echo "error: missing required tool(s):$MISSING." >&2
    echo "Install with:" >&2
    case "$MISSING" in *tart*) echo "  brew install openai/tools/tart" >&2 ;; esac
    case "$MISSING" in *packer*) echo "  brew install hashicorp/tap/packer" >&2 ;; esac
    case "$MISSING" in *expect*) echo "  expect ships with macOS; if missing, install Xcode Command Line Tools (xcode-select --install)" >&2 ;; esac
    case "$MISSING" in *jq*) echo "  brew install jq" >&2 ;; esac
    exit 3
fi

for f in vanilla-tahoe.pkr.hcl disable-sip.pkr.hcl provision.sh tcc-seed.sh verify.sh; do
    [ -f "$SELF_DIR/$f" ] || { echo "error: $SELF_DIR/$f is missing." >&2; exit 3; }
done

IMAGE_NAME="first-run-golden"
BASE_NAME="first-run-base"
TART_HOME="${TART_HOME:-$HOME/.tart}"
CACHE_DIR="$TART_HOME/harness-image-cache"
BASE_SIDECAR="$CACHE_DIR/$BASE_NAME.json"

# Two bounds on stage 1. The plugin's <wait 'text'> and <click 'text'> loop
# until the text shows up and never give up on their own, so:
#   - HARNESS_IMAGE_STALL_CAP: how long packer may keep looking for the SAME
#     label while its log is still growing (the guest is alive, the screen
#     is not the one expected). Measured in five-second ticks during which
#     the log grew, so a host that went to sleep mid-build does not count
#     its nap as a stall. Default 300; 1800 in manual mode, which waits for
#     a person at Terms and Conditions.
#   - HARNESS_IMAGE_STAGE_CAP: the wall clock for the whole stage, sleep
#     included, as the last resort. Default 3600.
if [ -n "${HARNESS_IMAGE_STALL_CAP:-}" ]; then
    STALL_CAP="$HARNESS_IMAGE_STALL_CAP"
elif [ "$TERMS_MODE" = "manual" ]; then
    STALL_CAP=1800
else
    STALL_CAP=300
fi
STAGE_CAP="${HARNESS_IMAGE_STAGE_CAP:-3600}"
for pair in "HARNESS_IMAGE_STALL_CAP:$STALL_CAP" "HARNESS_IMAGE_STAGE_CAP:$STAGE_CAP"; do
    case "${pair#*:}" in
        ''|*[!0-9]*) echo "error: ${pair%%:*} must be a number of seconds, not '${pair#*:}'." >&2; exit 2 ;;
    esac
done

# The commit this fork's vanilla-tahoe.pkr.hcl and disable-sip.pkr.hcl were
# taken from (cirruslabs/macos-image-templates); see each file's own header
# for what was changed and why. Recorded here, not re-derived, because it is
# a fact about this checkout's history, not something readable from the
# built image.
TEMPLATE_COMMIT="106c086ffa78a0701dd3301646d9a9be71fe7baf"

# PIN_ME: after your first successful build, set this to the exact output of
# `tart --version` so a later Tart upgrade becomes a visible warning instead
# of a silent change to what "first-run-golden" was built with. Until you
# set it, build.sh only records the live version into the report and the
# image's own /etc/first-run-golden.json; it does not block on it.
TART_VERSION_PIN="PIN_ME"

TART_VERSION="$(tart --version 2>/dev/null)" || { echo "error: tart --version failed." >&2; exit 3; }
if [ "$TART_VERSION_PIN" != "PIN_ME" ] && [ "$TART_VERSION_PIN" != "$TART_VERSION" ]; then
    echo "warning: installed Tart is '$TART_VERSION', but TART_VERSION_PIN in this script says '$TART_VERSION_PIN'. Rebuilding with a different Tart version is usually fine -- update the pin once you've reviewed the result." >&2
fi

vm_exists() { tart list --quiet --source local 2>/dev/null | grep -qx "$1"; }

# Only refuse here; the actual delete happens right before the final `tart
# clone`, after every stage has succeeded. Deleting the maintainer's working
# image up front, before stage 1's scripted UI click-through has even
# started, would trade a known-good hour-long build for nothing the moment
# that click-through breaks (README.md: "What to do when a stage fails" says
# this is the most likely failure).
if vm_exists "$IMAGE_NAME"; then
    if [ "$FORCE" -ne 1 ]; then
        echo "error: '$IMAGE_NAME' already exists. Re-run with --force to replace it." >&2
        exit 2
    fi
    echo "build.sh: --force given; '$IMAGE_NAME' will be replaced once the new build succeeds."
fi

BUILD_ID="$(date -u +%Y%m%d%H%M%S)"
BUILD_VM="$IMAGE_NAME-$BUILD_ID"
if vm_exists "$BUILD_VM"; then
    echo "error: '$BUILD_VM' already exists (a build already ran this second); re-run." >&2
    exit 3
fi

mkdir -p "$CACHE_DIR"
LOG_DIR="$CACHE_DIR/logs/$BUILD_ID"
mkdir -p "$LOG_DIR"

# The harness reaches a clone with `ssh -o BatchMode=yes` (harness/lib/vm.sh),
# so the image must carry a public key whose private half this host holds.
# A dedicated, passphrase-less key lives beside the image cache; vm.sh offers
# it by default when it exists, and provision.sh installs it and proves a
# BatchMode login with it before the image is called done. It is generated
# once and reused by every build, so a rebuilt image keeps working with the
# same harness checkout.
HARNESS_SSH_KEY="$CACHE_DIR/harness_ed25519"
if [ ! -f "$HARNESS_SSH_KEY" ] || [ ! -f "$HARNESS_SSH_KEY.pub" ]; then
    echo "build.sh: generating the harness ssh key at $HARNESS_SSH_KEY"
    rm -f "$HARNESS_SSH_KEY" "$HARNESS_SSH_KEY.pub"
    ssh-keygen -q -t ed25519 -N '' -C first-run-harness -f "$HARNESS_SSH_KEY" \
        || { echo "error: ssh-keygen could not create $HARNESS_SSH_KEY." >&2; exit 3; }
fi

# ---------------------------------------------------------------------------
# Stage 0: the base install.
#
# The IPSW's own SHA-256 is never hardcoded: it is computed from whatever
# bytes were actually installed from, so a change in the URL's target (Apple
# rotating a build) shows up in /etc/first-run-golden.json rather than being
# silently assumed away. It is computed once, when the base is made, and
# read back from the sidecar afterwards.
# ---------------------------------------------------------------------------

if [ -n "$BASE_OVERRIDE" ]; then
    vm_exists "$BASE_OVERRIDE" || { echo "error: --base '$BASE_OVERRIDE' is not a local Tart VM." >&2; exit 2; }
    BASE_VM="$BASE_OVERRIDE"
    IPSW_SHA256="unrecorded (stage 1 cloned '$BASE_OVERRIDE', not $BASE_NAME)"
    echo "build.sh: stage 0/3 -- skipped, cloning from '$BASE_VM' (no IPSW hash will be recorded for this image)"
else
    BASE_VM="$BASE_NAME"
    if [ "$REBUILD_BASE" -eq 1 ] && vm_exists "$BASE_NAME"; then
        echo "build.sh: --rebuild-base given; deleting '$BASE_NAME'..."
        tart delete "$BASE_NAME" || { echo "error: could not delete '$BASE_NAME'." >&2; exit 3; }
        rm -f "$BASE_SIDECAR"
    fi
    if vm_exists "$BASE_NAME" && [ -f "$BASE_SIDECAR" ]; then
        IPSW_SHA256="$(jq -r '.ipsw_sha256 // empty' "$BASE_SIDECAR")"
        [ -n "$IPSW_SHA256" ] || { echo "error: $BASE_SIDECAR carries no ipsw_sha256; pass --rebuild-base." >&2; exit 3; }
        echo "build.sh: stage 0/3 -- reusing '$BASE_NAME' (IPSW SHA-256 $IPSW_SHA256, recorded $(jq -r '.created_at' "$BASE_SIDECAR"))"
    else
        if vm_exists "$BASE_NAME"; then
            echo "error: '$BASE_NAME' exists but $BASE_SIDECAR does not, so its IPSW is unknown; pass --rebuild-base (or --base $BASE_NAME to use it without a recorded hash)." >&2
            exit 3
        fi
        if [ -n "$IPSW_OVERRIDE" ]; then
            IPSW_URL_OR_PATH="$IPSW_OVERRIDE"
        else
            IPSW_URL_OR_PATH="$(sed -n '/variable "ipsw_path"/,/^}/p' "$SELF_DIR/vanilla-tahoe.pkr.hcl" | sed -n 's/.*default *= *"\(.*\)".*/\1/p')"
            [ -n "$IPSW_URL_OR_PATH" ] || { echo "error: could not read the default ipsw_path out of vanilla-tahoe.pkr.hcl; pass --ipsw explicitly." >&2; exit 3; }
        fi
        case "$IPSW_URL_OR_PATH" in
            http://*|https://*)
                IPSW_PATH="$CACHE_DIR/$(basename "$IPSW_URL_OR_PATH")"
                if [ ! -f "$IPSW_PATH" ]; then
                    echo "build.sh: downloading IPSW to $IPSW_PATH (this is tens of gigabytes; expect it to take a while)..."
                    curl -fL --progress-bar -o "$IPSW_PATH.partial" "$IPSW_URL_OR_PATH" \
                        || { rm -f "$IPSW_PATH.partial"; echo "error: IPSW download failed." >&2; exit 3; }
                    mv "$IPSW_PATH.partial" "$IPSW_PATH"
                else
                    echo "build.sh: reusing cached IPSW at $IPSW_PATH (delete it to force a re-download)"
                fi
                ;;
            *)
                IPSW_PATH="$IPSW_URL_OR_PATH"
                [ -f "$IPSW_PATH" ] || { echo "error: --ipsw path does not exist: $IPSW_PATH." >&2; exit 2; }
                ;;
        esac
        echo "build.sh: hashing the IPSW (SHA-256 of a multi-gigabyte file; this takes a minute or two)..."
        IPSW_SHA256="$(shasum -a 256 "$IPSW_PATH" | awk '{print $1}')"
        [ -n "$IPSW_SHA256" ] || { echo "error: shasum produced no output for $IPSW_PATH." >&2; exit 3; }
        echo "build.sh: IPSW SHA-256: $IPSW_SHA256"
        # The template's disk_size_gb is 50; the base must match it so the
        # clone needs no resize.
        echo "build.sh: stage 0/3 -- tart create --from-ipsw into '$BASE_NAME' (a macOS install; expect roughly 5-15 minutes)"
        tart create "$BASE_NAME" --from-ipsw "$IPSW_PATH" --disk-size 50 \
            || { echo "error: tart create failed for '$BASE_NAME'." >&2; exit 3; }
        jq -n --arg ipsw_sha256 "$IPSW_SHA256" --arg ipsw_path "$IPSW_PATH" --arg tart_version "$TART_VERSION" \
            --arg created_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '{ipsw_sha256: $ipsw_sha256, ipsw_path: $ipsw_path, tart_version: $tart_version, created_at: $created_at}' \
            > "$BASE_SIDECAR" || { echo "error: could not write $BASE_SIDECAR." >&2; exit 3; }
        echo "build.sh: '$BASE_NAME' created; its inputs are recorded in $BASE_SIDECAR"
    fi
fi

# ---------------------------------------------------------------------------
# The packer stages, each under a cap.
# ---------------------------------------------------------------------------

RUN_PID=""
CAP_PID=""
TAIL_PID=""
cleanup() {
    if [ -n "$CAP_PID" ] && kill -0 "$CAP_PID" 2>/dev/null; then
        kill "$CAP_PID" 2>/dev/null || true
    fi
    if [ -n "$TAIL_PID" ] && kill -0 "$TAIL_PID" 2>/dev/null; then
        kill "$TAIL_PID" 2>/dev/null || true
    fi
    if [ -n "$RUN_PID" ] && kill -0 "$RUN_PID" 2>/dev/null; then
        tart stop "$BUILD_VM" >/dev/null 2>&1 || kill "$RUN_PID" 2>/dev/null || true
        wait "$RUN_PID" 2>/dev/null || true
    fi
}
trap cleanup EXIT

# caffeinate keeps the host from idling to sleep for the length of a packer
# stage: the first real build lost fifteen minutes to the Mac sleeping with
# Setup Assistant half-way through.
KEEP_AWAKE=""
command -v caffeinate >/dev/null 2>&1 && KEEP_AWAKE="caffeinate -dis"

# The last label packer was looking for on screen, from the logs given.
last_looked_for() {
    grep -o "Looking for '[^']*'" "$@" 2>/dev/null | tail -n1 | sed "s/.*Looking for //"
}

# run_packer_stage <label> <template> <log-basename> <stall-cap> <stage-cap> [packer args...]
#
# Runs one packer template against the build VM under two bounds, streaming
# its console to the terminal and to $LOG_DIR/<log-basename>.out, and its
# full log (PACKER_LOG=1, where the tart plugin's own "Looking for '...'" and
# "Clicking at '...'" lines land; the console never carries them) to
# $LOG_DIR/<log-basename>.log.
#
# -on-error=abort: the tart plugin's cleanup step deletes the VM on a halted
# or cancelled build, and the VM is the one thing worth keeping when a stage
# stalls. On expiry the guest is stopped, which breaks packer's VNC session:
# the boot step then fails instead of being cancelled, so abort keeps the VM.
#
# The bounds are measured in five-second ticks during which packer's log
# grew, not with one long sleep: `sleep` does not advance while the host is
# asleep, and the first real build's 900-second cap was still pending after
# thirty minutes for that reason. A stall is the same label for <stall-cap>
# seconds of guest activity; <stage-cap> is the wall clock, sleep included.
run_packer_stage() {
    local label="$1" template="$2" base="$3" stall_cap="$4" stage_cap="$5"
    shift 5
    local out="$LOG_DIR/$base.out" log="$LOG_DIR/$base.log" marker="$LOG_DIR/$base.capped"

    packer init "$template" \
        || { echo "error: packer init failed for $(basename "$template")." >&2; return 3; }

    : > "$out"
    PACKER_LOG=1 PACKER_LOG_PATH="$log" $KEEP_AWAKE packer build -on-error=abort "$@" "$template" >"$out" 2>&1 &
    local packer_pid=$!
    # Live progress for whoever is watching; packer itself writes to the file
    # so that $packer_pid is packer's own pid and the cap can reach it.
    tail -n +1 -f "$out" &
    TAIL_PID=$!
    (
        started="$(date +%s)"
        last_label=""
        last_size=0
        active_ticks=0
        reason=""
        while kill -0 "$packer_pid" 2>/dev/null; do
            sleep 5
            size="$(stat -f %z "$log" 2>/dev/null || echo 0)"
            current="$(grep -o "Looking for '[^']*'" "$log" 2>/dev/null | tail -n1)"
            if [ "$current" != "$last_label" ]; then
                last_label="$current"
                active_ticks=0
            elif [ "$size" != "$last_size" ]; then
                active_ticks=$((active_ticks + 1))
            fi
            last_size="$size"
            if [ $((active_ticks * 5)) -ge "$stall_cap" ]; then
                reason="stalled: packer kept looking for the same label for ${stall_cap}s of guest activity"
            elif [ $(( $(date +%s) - started )) -ge "$stage_cap" ]; then
                reason="the ${stage_cap}s stage cap ran out"
            fi
            if [ -n "$reason" ]; then
                printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$reason" > "$marker"
                tart stop "$BUILD_VM" >/dev/null 2>&1 || true
                sleep 20
                kill -TERM "$packer_pid" 2>/dev/null || true
                break
            fi
        done
    ) &
    CAP_PID=$!
    set +e
    wait "$packer_pid"
    local status=$?
    set -e
    kill "$CAP_PID" 2>/dev/null || true
    wait "$CAP_PID" 2>/dev/null || true
    CAP_PID=""
    sleep 1
    kill "$TAIL_PID" 2>/dev/null || true
    wait "$TAIL_PID" 2>/dev/null || true
    TAIL_PID=""

    if [ -f "$marker" ]; then
        tart stop "$BUILD_VM" >/dev/null 2>&1 || true
        echo "error: stage $label was stopped ($(cut -d' ' -f2- "$marker")) while packer was still looking for $(last_looked_for "$log" "$out" || echo '(nothing logged)') on screen." >&2
        echo "The build VM '$BUILD_VM' was stopped and kept: 'tart run $BUILD_VM' shows the screen it stalled on. Logs: $out and $log." >&2
        return 3
    fi
    if [ "$status" -ne 0 ]; then
        tart stop "$BUILD_VM" >/dev/null 2>&1 || true
        echo "error: stage $label failed (exit $status); the last label packer looked for was $(last_looked_for "$log" "$out" || echo '(nothing logged)')." >&2
        echo "The build VM '$BUILD_VM' was kept if packer got as far as creating it: 'tart run $BUILD_VM' (no --no-graphics) opens a window on it. Logs: $out and $log." >&2
        return 3
    fi
    return 0
}

echo "build.sh: stage 1/3 -- vanilla-tahoe.pkr.hcl (Setup Assistant, terms_mode=$TERMS_MODE, stall cap ${STALL_CAP}s, stage cap ${STAGE_CAP}s; expect a few minutes, and keep this Mac awake)"
if [ "$TERMS_MODE" = "manual" ]; then
    echo "build.sh: MANUAL TERMS: when the packer window shows Terms and Conditions, click Agree, then Agree again in the sheet. packer waits for the screen after it."
fi
run_packer_stage "1 (vanilla-tahoe.pkr.hcl)" "$SELF_DIR/vanilla-tahoe.pkr.hcl" stage1-packer "$STALL_CAP" "$STAGE_CAP" \
    -var "vm_name=$BUILD_VM" -var "vm_base_name=$BASE_VM" -var "terms_mode=$TERMS_MODE" \
    || exit 3

# Stage 2 answers csrutil's three prompts in Recovery; whether SIP actually
# went off is checked by provision.sh in the booted guest, since packer
# reports this stage as successful whatever csrutil did.
echo "build.sh: stage 2/3 -- disable-sip.pkr.hcl (recovery-mode csrutil disable; expect roughly 2-4 minutes)"
run_packer_stage "2 (disable-sip.pkr.hcl)" "$SELF_DIR/disable-sip.pkr.hcl" stage2-packer 300 900 \
    -var "vm_name=$BUILD_VM" \
    || exit 3

# ---------------------------------------------------------------------------
# Stage 3: provisioning over SSH.
# ---------------------------------------------------------------------------

echo "build.sh: stage 3/3 -- provision.sh over SSH (TCC seeding, Automation Mode, Claude Code install; expect roughly 5-10 minutes)"
RUN_LOG="$LOG_DIR/stage3-tart-run.log"
tart run "$BUILD_VM" --no-graphics >"$RUN_LOG" 2>&1 &
RUN_PID=$!

GUEST_IP="$(tart ip "$BUILD_VM" --wait 180)" \
    || { echo "error: '$BUILD_VM' never acquired an IP address; see $RUN_LOG." >&2; exit 3; }
echo "build.sh: guest is up at $GUEST_IP"

if "$SELF_DIR/provision.sh" --host "$GUEST_IP" --ipsw-sha256 "$IPSW_SHA256" --tart-version "$TART_VERSION" --template-commit "$TEMPLATE_COMMIT" --build-id "$BUILD_ID" --terms-mode "$TERMS_MODE" --authorized-key "$HARNESS_SSH_KEY.pub"; then
    PROVISION_OK=1
else
    PROVISION_OK=0
fi

# Shut the guest down from inside, and wait for the VM process to exit on
# its own. `tart stop` only waits 30 seconds for a graceful shutdown before
# terminating the VM, and a macOS shutdown with a logged-in session takes
# longer than that: the first full build lost the whole of provisioning's
# writes that way (the Claude Code install, /etc/first-run-golden.json and
# ~/.zshenv were gone from the image, with only their directories left).
echo "build.sh: shutting the guest down from inside..."
ssh -i "$HARNESS_SSH_KEY" -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=20 \
    "admin@$GUEST_IP" 'sync; sudo shutdown -h now' >/dev/null 2>&1 || true
waited=0
while kill -0 "$RUN_PID" 2>/dev/null && [ "$waited" -lt 300 ]; do
    sleep 5
    waited=$((waited + 5))
done
if kill -0 "$RUN_PID" 2>/dev/null; then
    echo "warning: the guest did not shut down by itself within ${waited}s; asking Tart to stop it (up to 120s more)." >&2
    tart stop "$BUILD_VM" --timeout 120 >/dev/null 2>&1 || true
fi
wait "$RUN_PID" 2>/dev/null || true
RUN_PID=""

if [ "$PROVISION_OK" -ne 1 ]; then
    echo "error: provisioning failed (see the output above for which step). The build VM '$BUILD_VM' was left stopped, not deleted, for inspection; delete it with 'tart delete $BUILD_VM' once you're done." >&2
    exit 3
fi

# Every stage succeeded: only now is it safe to replace an existing
# first-run-golden. `tart clone` refuses if the target name already exists,
# so the old one has to go first -- but not a moment before this.
if [ "$FORCE" -eq 1 ] && vm_exists "$IMAGE_NAME"; then
    echo "build.sh: deleting the previous '$IMAGE_NAME'..."
    tart delete "$IMAGE_NAME" || { echo "error: could not delete the existing '$IMAGE_NAME'; '$BUILD_VM' is the good new build, clone it by hand once this is sorted out." >&2; exit 3; }
fi

echo "build.sh: cloning $BUILD_VM -> $IMAGE_NAME"
tart clone "$BUILD_VM" "$IMAGE_NAME" \
    || { echo "error: 'tart clone $BUILD_VM $IMAGE_NAME' failed. '$BUILD_VM' is the good new build; clone it by hand once this is sorted out ('tart clone $BUILD_VM $IMAGE_NAME')." >&2; exit 3; }
# `tart list` did not show the clone for a moment after `tart clone`
# returned, and verify.sh refused to start (observed 2026-09-19); wait for
# it before handing over.
waited=0
until vm_exists "$IMAGE_NAME" || [ "$waited" -ge 60 ]; do
    sleep 2
    waited=$((waited + 2))
done
vm_exists "$IMAGE_NAME" || { echo "error: '$IMAGE_NAME' is not listed by tart ${waited}s after the clone returned." >&2; exit 3; }

# Best-effort host-side mitigation for the image being a pre-authorized,
# SIP-off macOS with a known password (see README.md): keep Tart's VM store
# out of Time Machine. This cannot reach an arbitrary cloud-sync folder
# (Dropbox, iCloud Drive), so README.md also tells the maintainer to keep
# ~/.tart outside any synced folder by hand.
if command -v tmutil >/dev/null 2>&1; then
    tmutil addexclusion -p "$TART_HOME" >/dev/null 2>&1 \
        && echo "build.sh: excluded $TART_HOME from Time Machine" \
        || echo "warning: could not add a Time Machine exclusion for $TART_HOME; add one by hand (see README.md)." >&2
fi

echo "build.sh: ok -- $IMAGE_NAME built from $BUILD_VM (terms_mode=$TERMS_MODE)"

if [ "$SKIP_VERIFY" -ne 1 ]; then
    echo "build.sh: running verify.sh against a fresh clone..."
    "$SELF_DIR/verify.sh"
else
    echo "build.sh: --skip-verify given; run harness/image/verify.sh yourself before trusting this image."
fi
