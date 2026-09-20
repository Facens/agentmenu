#!/bin/bash
# Tart and guest-shell helpers for the first-run harness.
#
# Sourced, never executed. Two things live here: the handful of `tart`
# invocations the orchestrator makes (clone, boot, ip, delete, list), and the
# guest shell — `guest_run`, `guest_copy_in`, `guest_copy_out` — which the
# scenarios use to reach the guest.
#
# The guest shell is indirectable on purpose. On the stranger tier it is ssh
# and scp against the clone's IP; on the app-fresh tier the same guest scripts
# run locally, so HARNESS_GUEST_TRANSPORT=local turns every call into a local
# shell and a local copy, and the scenario does not change. The golden image
# is named by HARNESS_GOLDEN_IMAGE (default `first-run-golden`) and every
# clone this harness makes is prefixed `first-run-harness-`; that prefix is
# what `run.sh clean` sweeps and what the two-guest refusal uses to tell a
# harness clone from the maintainer's own VM.
set -euo pipefail

if [ -n "${HARNESS_VM_SH:-}" ]; then
    return 0
fi
HARNESS_VM_SH=1

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

HARNESS_CLONE_PREFIX="first-run-harness-"
HARNESS_GUEST_USER="${HARNESS_GUEST_USER:-admin}"
HARNESS_GUEST_TRANSPORT="${HARNESS_GUEST_TRANSPORT:-ssh}"
# `.harness` is relative to the guest user's home, so no script has to know
# the user name — KTD5's "~/.harness/guest/<name>".
HARNESS_GUEST_HOME="${HARNESS_GUEST_HOME:-.harness}"
HARNESS_VM_BOOT_PID="${HARNESS_VM_BOOT_PID:-}"

# ---------------------------------------------------------------------------
# tart
#
# `tart list` prints a header line and then one row per VM. The column layout
# read here is Source, Name, Disk, Size, State — name second, state last. That
# is UNVERIFIED against a real tart: tart is not installed on this machine and
# must not be, so every caller goes through this one function rather than
# parsing the table in three places. If the layout turns out to differ, this
# is the only thing to fix.

vm_list_rows() {
    tart list 2>/dev/null | awk 'NR == 1 && ($1 == "Source" || $1 == "NAME" || $1 == "Name") { next } NF >= 2 { print $2, $NF }'
}

vm_names_by_state() {
    local want="$1"
    vm_list_rows | awk -v want="$want" '$2 == want { print $1 }'
}

vm_running_count() {
    vm_names_by_state running | grep -c . || true
}

# Names of this harness's own clones, in any state or in the state given.
vm_harness_clones() {
    local want="${1:-}"
    if [ -n "$want" ]; then
        vm_names_by_state "$want"
    else
        vm_list_rows | awk '{ print $1 }'
    fi | grep "^${HARNESS_CLONE_PREFIX}" || true
}

vm_exists() {
    vm_list_rows | awk -v name="$1" '$1 == name { found = 1 } END { exit found ? 0 : 1 }'
}

vm_clone() {
    log "cloning $1 -> $2"
    tart clone "$1" "$2"
}

# Boots the clone in the background — `tart run` blocks for as long as the VM
# lives — and records the PID so vm_delete can take it down again.
vm_boot() {
    local name="$1"
    log "booting $name"
    tart run --no-graphics "$name" &
    HARNESS_VM_BOOT_PID=$!
    if [ -n "${HARNESS_RUN_DIR:-}" ]; then
        printf '%s\n' "$HARNESS_VM_BOOT_PID" > "$HARNESS_RUN_DIR/vm-boot.pid"
    fi
    return 0
}

# Polls `tart ip` until the guest has one, printing it. Never a fixed sleep.
vm_ip() {
    local name="$1" timeout="${2:-${HARNESS_IP_TIMEOUT:-180}}" waited=0 ip=""
    while [ "$waited" -lt "$timeout" ]; do
        ip="$(tart ip "$name" 2>/dev/null | tr -d '[:space:]' || true)"
        if [ -n "$ip" ]; then
            printf '%s' "$ip"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    warn "$name never reported an IP within ${timeout}s."
    return 1
}

vm_wait_ssh() {
    local ip="$1" timeout="${2:-${HARNESS_SSH_TIMEOUT:-300}}" waited=0
    while [ "$waited" -lt "$timeout" ]; do
        if guest_run "$ip" true >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    warn "$ip never accepted a guest shell within ${timeout}s."
    return 1
}

# Takes the clone down and removes it. Every step is bounded and none of them
# is allowed to fail the teardown: this runs from a trap, and a hang here
# would keep the run's exit code out of report.json.
vm_delete() {
    local name="$1"
    if [ -n "${HARNESS_VM_BOOT_PID:-}" ]; then
        kill -TERM "$HARNESS_VM_BOOT_PID" 2>/dev/null || true
    fi
    bounded_run 30 tart stop "$name" >/dev/null 2>&1 || true
    if [ -n "${HARNESS_VM_BOOT_PID:-}" ]; then
        kill -KILL "$HARNESS_VM_BOOT_PID" 2>/dev/null || true
        HARNESS_VM_BOOT_PID=""
    fi
    log "deleting $name"
    bounded_run 60 tart delete "$name" >/dev/null 2>&1 || warn "tart delete $name did not complete; 'run.sh clean' will sweep it."
    return 0
}

# ---------------------------------------------------------------------------
# The guest shell.

# Deliberately unquoted where it is used: these are separate ssh arguments.
HARNESS_SSH_KEY_DEFAULT="${TART_HOME:-$HOME/.tart}/harness-image-cache/harness_ed25519"
if [ -z "${HARNESS_SSH_OPTS:-}" ]; then
    HARNESS_SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10"
    # The key harness/image/build.sh generated and provision.sh installed in
    # the golden image; offered only when it exists, so a host with its own
    # arrangement (HARNESS_SSH_OPTS set, or a default key the image accepts)
    # is not disturbed. The path must not contain spaces: this string is
    # word-split on purpose where it is used.
    if [ -f "$HARNESS_SSH_KEY_DEFAULT" ]; then
        HARNESS_SSH_OPTS="$HARNESS_SSH_OPTS -i $HARNESS_SSH_KEY_DEFAULT -o IdentitiesOnly=yes"
    fi
fi

# Runs a command in the guest. The arguments are joined with spaces and
# interpreted by the guest's shell, exactly as `ssh host cmd` does, so a
# caller that needs a literal argument quotes it itself.
guest_run() {
    local ip="$1"
    shift
    if [ "$HARNESS_GUEST_TRANSPORT" = "local" ]; then
        bash -c "$*"
    else
        ssh $HARNESS_SSH_OPTS "${HARNESS_GUEST_USER}@${ip}" "$*"
    fi
}

# The remote half of an scp argument goes over the wire verbatim, so it is
# passed through unchanged -- no shell quoting.
#
# scp still splits its argument at the first colon, but since OpenSSH 9.0 it
# speaks the SFTP protocol, and the far side is sftp-server, not a shell:
# nothing there splits words, expands globs or strips quotes. A path with a
# space therefore needs no quoting, and quoting it makes the quote characters
# part of the name. `~/` is resolved by scp itself, and a relative path
# resolves against the login directory, so both forms work bare.
#
# Verified against a clone of first-run-golden on 2026-09-19, OpenSSH_10.3p1
# (the harness copy-in that found this, `scp -r harness/guest admin@ip:...`):
#
#   admin@ip:'.harness/'  ->  scp: dest open "'.harness/'": No such file
#   admin@ip:.harness/    ->  ok
#   admin@ip:~/'Library/Application Support/x/harness'
#                         ->  scp: dest open "'Library/Application Support/x/harness'"
#   admin@ip:~/Library/Application Support/x/harness
#                         ->  ok, both directions, and with -r
#
# The legacy behaviour this used to assume is still reachable with `scp -O`,
# which is deprecated; do not reintroduce quoting to suit it.
vm_remote_path() {
    printf '%s' "$1"
}

guest_copy_in() {
    local ip="$1" local_path="$2" remote_path="$3"
    if [ "$HARNESS_GUEST_TRANSPORT" = "local" ]; then
        mkdir -p "$(dirname "$remote_path")"
        cp -R "$local_path" "$remote_path"
    else
        scp -r $HARNESS_SSH_OPTS "$local_path" "${HARNESS_GUEST_USER}@${ip}:$(vm_remote_path "$remote_path")"
    fi
}

guest_copy_out() {
    local ip="$1" remote_path="$2" local_path="$3"
    if [ "$HARNESS_GUEST_TRANSPORT" = "local" ]; then
        mkdir -p "$(dirname "$local_path")"
        cp -R "$remote_path" "$local_path"
    else
        scp -r $HARNESS_SSH_OPTS "${HARNESS_GUEST_USER}@${ip}:$(vm_remote_path "$remote_path")" "$local_path"
    fi
}
