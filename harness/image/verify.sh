#!/bin/bash
# Proves that a first-run-golden image (or whatever --image names) actually
# has what Unit U1 / KTD1 says it has: Gatekeeper on, the driver's TCC
# grants working, Claude Code installed, and no TCC row for either app under
# test. Never runs against the named image directly -- it clones it into a
# throwaway VM first (deleted on exit unless --keep), boots that, checks it
# over SSH, and discards it, so repeated runs never accumulate state on the
# image itself and "verify.sh passes on a fresh clone" is what actually ran,
# not an approximation of it.
#
# Every check here is functional (it does the thing and inspects the real
# result), never an inspection of build-time intent, per the plan's own risk
# note: TCC seeding may not take even when tcc-seed.sh reported success
# (Tahoe revalidates grants; the SSH client may be attributed differently
# than expected). If a grant check fails, README.md's diagnostic (a hand
# grant on a throwaway clone, never on the image) tells a seeding bug from a
# wrong client identity; the fix goes into tcc-seed.sh, then rebuild.
#
# Checks, each named in its own failure message:
#   1. spctl --status reports assessments enabled (Gatekeeper stayed on).
#   2. screencapture -x over SSH yields a real, non-blank PNG (Screen
#      Recording grant works) -- checked by a byte-size floor, the same
#      technique KTD2 specifies for the harness's own screenshot capture,
#      not by decoding pixels.
#   3. An osascript System Events query lists Finder's menu bar items with
#      no authorization prompt (Accessibility + Apple Events grants work).
#   4. claude --version runs (Claude Code is installed).
#   5. Neither TCC database (system or the admin user's) has a row for
#      dev.facens.agentmenu or dev.facens.meetinghop -- the app under test
#      is never seeded (R4).
#   6. The guest's IP is not on the same /24 as the host's own LAN address,
#      i.e. it came from Tart's internal NAT/DHCP, not a bridged interface.
#   7. A BatchMode ssh login with the harness key build.sh generated works
#      (the harness's own transport, harness/lib/vm.sh, never types a
#      password).
#
# Usage: verify.sh [--image NAME] [--keep]
#   --image NAME  clone this VM instead of first-run-golden.
#   --keep        don't delete the throwaway clone at the end (for
#                 debugging a failing check by hand, e.g. over VNC).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

SOURCE_IMAGE="first-run-golden"
KEEP=0

while [ $# -gt 0 ]; do
    case "$1" in
        --image) SOURCE_IMAGE="$2"; shift 2 ;;
        --keep) KEEP=1; shift ;;
        -h|--help) sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "error: unknown argument: $1." >&2; exit 2 ;;
    esac
done

for tool in tart ssh scp expect file route ipconfig; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool not found on this host." >&2; exit 3; }
done

if ! tart list --quiet --source local 2>/dev/null | grep -qx "$SOURCE_IMAGE"; then
    echo "error: no local VM named '$SOURCE_IMAGE'. Run build.sh first." >&2
    exit 3
fi

CLONE_VM="verify-$SOURCE_IMAGE-$$-$(date -u +%H%M%S)"
RUN_PID=""
cleanup() {
    if [ -n "$RUN_PID" ] && kill -0 "$RUN_PID" 2>/dev/null; then
        tart stop "$CLONE_VM" >/dev/null 2>&1 || kill "$RUN_PID" 2>/dev/null || true
        wait "$RUN_PID" 2>/dev/null || true
    fi
    if [ "$KEEP" -ne 1 ]; then
        tart delete "$CLONE_VM" >/dev/null 2>&1 || true
    else
        echo "verify.sh: --keep given, leaving '$CLONE_VM' running/stopped for inspection (tart delete it yourself when done)."
    fi
}
trap cleanup EXIT

echo "verify.sh: cloning $SOURCE_IMAGE -> $CLONE_VM"
tart clone "$SOURCE_IMAGE" "$CLONE_VM" || { echo "error: tart clone failed." >&2; exit 3; }

RUN_LOG="$(mktemp -t verify-tart-run)"
tart run "$CLONE_VM" --no-graphics >"$RUN_LOG" 2>&1 &
RUN_PID=$!

GUEST_IP="$(tart ip "$CLONE_VM" --wait 180)" || { echo "error: '$CLONE_VM' never acquired an IP address; see $RUN_LOG." >&2; exit 3; }
echo "verify.sh: guest is up at $GUEST_IP"

EXPECT_TIMEOUT=60
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)

# Same transport as provision.sh (see its header for why: multi-line remote
# commands and embedded quotes have to survive bash -> Tcl -> the ssh/scp
# argv intact, and the guest has no SSH key, only the admin/admin password).
run_over_ssh() {
    expect -f - "$EXPECT_TIMEOUT" "$@" <<'EXPECT_EOF'
set timeout [lindex $argv 0]
set spawnargs [lrange $argv 1 end]
log_user 1
spawn {*}$spawnargs
expect {
    -re {[Pp]assword[^\r\n]*:} { send "admin\r"; exp_continue }
    -re {[Cc]ontinue connecting} { send "yes\r"; exp_continue }
    timeout { puts stderr "run_over_ssh: timed out after ${timeout}s"; catch {close}; catch {wait}; exit 124 }
    eof
}
catch wait result
exit [lindex $result 3]
EXPECT_EOF
}

run_over_ssh_capture() {
    local raw
    raw="$(expect -f - "$EXPECT_TIMEOUT" "$@" <<'EXPECT_EOF'
set timeout [lindex $argv 0]
set spawnargs [lrange $argv 1 end]
log_user 0
spawn {*}$spawnargs
expect {
    -re {[Pp]assword[^\r\n]*:} { send "admin\r"; exp_continue }
    -re {[Cc]ontinue connecting} { send "yes\r"; exp_continue }
    timeout { puts stderr "run_over_ssh_capture: timed out after ${timeout}s"; catch {close}; catch {wait}; exit 124 }
    eof
}
puts -nonewline $expect_out(buffer)
catch wait result
exit [lindex $result 3]
EXPECT_EOF
)" || return $?
    printf '%s' "$raw" | tr -d '\r' | sed -e '/^[[:space:]]*$/d' | tail -n1
}

ssh_guest() { run_over_ssh ssh "${SSH_OPTS[@]}" "admin@$GUEST_IP" "$1"; }
ssh_guest_capture() { run_over_ssh_capture ssh "${SSH_OPTS[@]}" "admin@$GUEST_IP" "$1 2>/dev/null"; }
scp_from_guest() { run_over_ssh scp "${SSH_OPTS[@]}" "admin@$GUEST_IP:$1" "$2"; }

echo "verify.sh: waiting for SSH..."
attempt=0
until ssh_guest "true" >/dev/null 2>&1; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 30 ] || { echo "error: '$CLONE_VM' never became reachable over SSH; see $RUN_LOG." >&2; exit 3; }
    sleep 5
done

failures=0
skipped=0
checks=0
fail() { echo "  ✗ $1" >&2; failures=$((failures + 1)); checks=$((checks + 1)); }
ok() { echo "  ✓ $1"; checks=$((checks + 1)); }
# A check that could not run is not a check that passed. The summary used to
# print a fixed count whatever happened, so a skipped isolation check read as
# a clean bill of health on the one report a release gate trusts.
skip() { echo "  ? $1" >&2; skipped=$((skipped + 1)); }

echo "golden image check: $SOURCE_IMAGE (via $CLONE_VM at $GUEST_IP)"

# 1. Gatekeeper stayed on.
spctl_status="$(ssh_guest_capture "spctl --status")" || spctl_status=""
case "$spctl_status" in
    *"assessments enabled"*) ok "spctl --status: assessments enabled" ;;
    *) fail "spctl --status did not report assessments enabled (got: '${spctl_status:-no output}')" ;;
esac

# 2. Screen Recording grant works and the capture is not blank, by the same
# byte-size-floor technique KTD2 specifies (see this file's header).
shot_local="$(mktemp -t verify-screenshot)"
if ssh_guest "rm -f /tmp/verify-shot.png; screencapture -x /tmp/verify-shot.png" \
    && scp_from_guest "/tmp/verify-shot.png" "$shot_local" \
    && ssh_guest "rm -f /tmp/verify-shot.png"; then
    shot_size=$(( $(stat -f %z "$shot_local" 2>/dev/null || echo 0) ))
    shot_type="$(file -b "$shot_local" 2>/dev/null || echo "")"
    case "$shot_type" in
        PNG*)
            if [ "$shot_size" -ge 20000 ]; then
                ok "screencapture -x: $shot_size-byte PNG (>= 20000-byte floor)"
            else
                fail "screencapture -x produced a suspiciously small PNG ($shot_size bytes, floor is 20000) -- likely blank; Screen Recording may not have taken"
            fi
            ;;
        *) fail "screencapture -x did not produce a PNG (file reports: '$shot_type')" ;;
    esac
else
    fail "screencapture -x over SSH failed to run or the file could not be copied back"
fi

# 3. Accessibility + Apple Events grants work: a real System Events query,
# not an error or a hang waiting on a prompt.
menu_items="$(ssh_guest_capture 'osascript -e '"'"'tell application "System Events" to get name of every menu bar item of menu bar 1 of process "Finder"'"'"'')" || menu_items=""
menu_items_lower="$(printf '%s' "$menu_items" | tr '[:upper:]' '[:lower:]')"
case "$menu_items_lower" in
    ""|*error*|*"(-1743)"*|*"not allowed assistive"*|*"not authorized"*)
        fail "the System Events query returned no usable result (got: '${menu_items:-no output}'); Accessibility or Apple Events grant is not working" ;;
    *) ok "System Events lists Finder's menu bar: $menu_items" ;;
esac

# 4. Claude Code is installed.
claude_version="$(ssh_guest_capture "test -x ~/.local/bin/claude && ~/.local/bin/claude --version")" || claude_version=""
if [ -n "$claude_version" ]; then
    ok "claude --version: $claude_version"
else
    fail "claude --version produced no output (is Claude Code installed at ~/.local/bin/claude?)"
fi

# 4b. The build's own provenance record, and the autoupdater switch beside it.
# README.md told the maintainer verify.sh was what caught a missing
# /etc/first-run-golden.json; it never read the file at all. These are the two
# artefacts the forced-stop path at build.sh's shutdown step destroyed once
# already, which is exactly when a check that reads them earns its place.
# grep on the guest, not `cat` back to the host: ssh_guest_capture keeps only
# the LAST non-blank line (its own contract), and the manifest is pretty-printed
# JSON, so catting it here returned "}" and this check failed on a file that was
# perfectly fine. Counting the key in the guest keeps the answer one line.
manifest_keys="$(ssh_guest_capture "sudo grep -c '\"build_id\"' /etc/first-run-golden.json")" || manifest_keys=""
case "$manifest_keys" in
    ''|0) fail "/etc/first-run-golden.json is missing, unreadable, or carries no build_id -- provisioning's last write did not survive" ;;
    *) ok "/etc/first-run-golden.json is present and carries build_id" ;;
esac

autoupdater="$(ssh_guest_capture "grep -c DISABLE_AUTOUPDATER ~/.zshenv")" || autoupdater="0"
case "$autoupdater" in
    ''|0) fail "~/.zshenv carries no DISABLE_AUTOUPDATER; a stranger run would fight a Claude Code autoupdate mid-scenario" ;;
    *) ok "~/.zshenv sets DISABLE_AUTOUPDATER ($autoupdater line(s))" ;;
esac

# 4c. The driver can actually drive Calendar.app. Two grants, both needed, and
# the second only surfaces once the first is in place (see tcc-seed.sh). This
# is checked functionally rather than by reading the table, because a row that
# is present and a grant that works are different claims -- the whole reason
# every other check here does the thing rather than inspecting intent.
cal_names="$(ssh_guest_capture "osascript -e 'tell application \"Calendar\" to get name of every calendar'")" || cal_names=""
case "$cal_names" in
    ""|*error*|*"-1712"*|*"not allowed"*)
        fail "the driver cannot script Calendar.app (got: '${cal_names:-no output, which is what the -1712 timeout looks like}'); R10's calendar fixtures need kTCCServiceAppleEvents on com.apple.iCal AND kTCCServiceCalendarsFullAccess" ;;
    *) ok "Calendar.app answers the driver: $cal_names" ;;
esac

# 5. The app under test is never seeded (R4): no TCC row for either bundle
# id, in either database.
tcc_query="SELECT count(*) FROM access WHERE client='dev.facens.agentmenu' OR client='dev.facens.meetinghop';"
sys_count="$(ssh_guest_capture "sudo sqlite3 '/Library/Application Support/com.apple.TCC/TCC.db' \"$tcc_query\"")" || sys_count=""
user_count="$(ssh_guest_capture "sqlite3 ~/'Library/Application Support/com.apple.TCC/TCC.db' \"$tcc_query\"")" || user_count=""
if [ "$sys_count" = "0" ] && [ "$user_count" = "0" ]; then
    ok "no TCC row for dev.facens.agentmenu or dev.facens.meetinghop in either database"
else
    fail "found a TCC row for the app under test (system db count='${sys_count:-?}', user db count='${user_count:-?}'); the app must never be pre-granted (R4)"
fi

# 6. No bridged interface: the guest's address must not be on the host's own
# LAN subnet -- that would mean it is reachable from the network the host
# is on, defeating the isolation this recipe relies on (see README.md).
host_default_iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2; exit}')"
host_lan_ip="$(ipconfig getifaddr "$host_default_iface" 2>/dev/null || true)"
if [ -z "$host_lan_ip" ]; then
    skip "could not determine the host's own LAN address (no default route interface?); the bridged-interface check did not run -- confirm by hand." 
else
    guest_prefix="${GUEST_IP%.*}"
    host_prefix="${host_lan_ip%.*}"
    if [ "$guest_prefix" != "$host_prefix" ]; then
        ok "guest address $GUEST_IP is not on the host LAN's /24 ($host_lan_ip) -- NAT, not bridged"
    else
        fail "guest address $GUEST_IP shares the host LAN's /24 ($host_lan_ip) -- looks bridged, not NAT"
    fi
fi

# 7. The harness's own transport works: a BatchMode login with the key
# harness/image/build.sh generated and provision.sh installed (the harness
# never types a password; see harness/lib/vm.sh).
harness_key="${TART_HOME:-$HOME/.tart}/harness-image-cache/harness_ed25519"
if [ ! -f "$harness_key" ]; then
    fail "the harness ssh key $harness_key does not exist on this host; build.sh generates it, and vm.sh offers it by default"
elif ssh -i "$harness_key" -o BatchMode=yes -o IdentitiesOnly=yes "${SSH_OPTS[@]}" "admin@$GUEST_IP" true 2>/dev/null; then
    ok "BatchMode ssh login with $harness_key works"
else
    fail "a BatchMode ssh login with $harness_key was refused; the harness cannot reach this image without typing a password"
fi

if [ "$failures" -gt 0 ]; then
    echo "golden image check: FAIL ($failures of $((checks + skipped)))" >&2
    exit 1
fi
if [ "$skipped" -gt 0 ]; then
    echo "golden image check: $checks ok, $skipped could not run" >&2
    [ "${HARNESS_ALLOW_SKIPPED_CHECKS:-0}" = "1" ] || {
        echo "golden image check: FAIL -- a check did not run, and this image gates a release; set HARNESS_ALLOW_SKIPPED_CHECKS=1 to accept it anyway." >&2
        exit 1
    }
fi
echo "golden image check: ok ($checks checks)"
