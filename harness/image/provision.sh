#!/bin/bash
# Provisions a running golden-image guest over SSH: this is stage 3 of
# harness/image/build.sh, run after vanilla-tahoe.pkr.hcl (stage 1, Setup
# Assistant automation and Gatekeeper left on) and disable-sip.pkr.hcl
# (stage 2, SIP off). It is not a Packer template, because TCC writes and
# the rest of what follows need a live, booted, non-recovery macOS -- the
# exact state the guest is in once stage 2 has halted and build.sh has
# booted it again.
#
# What this script does, in order (Unit U1 / KTD1):
#   1. Waits for the guest's SSH to answer.
#   2. Copies harness/image/tcc-seed.sh to the guest and runs it as root, so
#      the driver's Accessibility, Screen Recording, PostEvent and Apple
#      Events grants exist without any interactive prompt (never for the app
#      under test -- see tcc-seed.sh's own header and R4).
#   3. Runs `automationmodetool enable-automationmode-without-authentication`
#      so System Events stops asking for authorization on every osascript
#      call.
#   4. Pins the locale to en-US and turns on the 24-hour clock, so dialog
#      text and timestamps are predictable across rebuilds.
#   5. Disables Software Update's automatic checks and installs (screen lock
#      is already off: vanilla-tahoe.pkr.hcl's `sysadminctl -screenLock off`,
#      kept verbatim in the fork, already covers it -- see README.md).
#   6. Installs Claude Code with the official installer and writes
#      DISABLE_AUTOUPDATER=1 into both ~/.zprofile (interactive Terminal.app
#      sessions) and ~/.zshenv (non-interactive `ssh host 'claude ...'`,
#      which is how later harness units drive it), so a stranger run never
#      fights an autoupdate mid-scenario.
#   7. Reads back the guest's macOS build and the installed Claude Code
#      version, and writes /etc/first-run-golden.json with those plus the
#      host-known build inputs this script was given -- so a change in any
#      input is visible in every report (R5) -- including `manual_steps`, a
#      string naming the one click R5 allows a person to make (Terms and
#      Conditions, when build.sh ran with --terms manual), empty otherwise.
#
# The guest keeps Tart's default NAT networking throughout (no port
# forwarding, no bridging is ever configured here or anywhere else in this
# recipe); see README.md for that constraint and for excluding the Tart
# image store from backups.
#
# Authentication: the guest has no SSH key set up, only the admin/admin
# password (KTD1's own account). Every ssh/scp call in this script goes
# through expect, which answers both ssh's own password prompt and
# automationmodetool's differently-worded one
# ("Enter the password for user 'admin':", no literal "password:" substring)
# non-interactively. Every remote command is passed to ssh/scp as a single,
# already-quoted bash string (never split across ssh's trailing argv) so
# that multi-line remote scripts and embedded quotes survive the two hops
# (bash on the host -> Tcl inside expect -> the ssh/scp argv) intact; this
# was verified against fixtures before being trusted here, not assumed.
#
# Usage:
#   provision.sh --host <ip-or-hostname> --ipsw-sha256 <hex> \
#     --tart-version <string> --template-commit <sha> --build-id <string> \
#     --authorized-key <harness_key.pub> [--terms-mode click|voiceover|manual]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELF_DIR="$ROOT/harness/image"

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
fi

GUEST_HOST=""
IPSW_SHA256=""
TART_VERSION=""
TEMPLATE_COMMIT=""
BUILD_ID=""
TERMS_MODE="click"

while [ $# -gt 0 ]; do
    case "$1" in
        --host) GUEST_HOST="$2"; shift 2 ;;
        --ipsw-sha256) IPSW_SHA256="$2"; shift 2 ;;
        --tart-version) TART_VERSION="$2"; shift 2 ;;
        --template-commit) TEMPLATE_COMMIT="$2"; shift 2 ;;
        --build-id) BUILD_ID="$2"; shift 2 ;;
        --terms-mode) TERMS_MODE="$2"; shift 2 ;;
        --authorized-key) AUTHORIZED_KEY="$2"; shift 2 ;;
        -h|--help) sed -n '2,55p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "error: unknown argument: $1." >&2; exit 2 ;;
    esac
done

# The harness reaches the guest with `ssh -o BatchMode=yes` (harness/lib/vm.sh),
# which never types a password, so the image has to carry a public key the
# host holds the private half of. build.sh generates a passphrase-less
# harness key and passes its .pub here; this script installs it and then
# proves a BatchMode login with the matching private key works before it
# calls the image done.
AUTHORIZED_KEY="${AUTHORIZED_KEY:-}"
[ -n "$AUTHORIZED_KEY" ] || { echo "error: --authorized-key <file.pub> is required." >&2; exit 2; }
[ -f "$AUTHORIZED_KEY" ] || { echo "error: --authorized-key $AUTHORIZED_KEY does not exist." >&2; exit 2; }
PRIVATE_KEY="${AUTHORIZED_KEY%.pub}"
[ -f "$PRIVATE_KEY" ] || { echo "error: the private key $PRIVATE_KEY beside $AUTHORIZED_KEY does not exist; the BatchMode check needs it." >&2; exit 2; }

# R5 allows exactly one documented manual step in the recipe, the Terms and
# Conditions click in build.sh's manual mode, and asks that the build record
# it. This is that record: a string, empty when the build was unattended, so
# every report that reads the image's inputs carries it.
case "$TERMS_MODE" in
    click|voiceover) MANUAL_STEPS="" ;;
    manual) MANUAL_STEPS="Terms and Conditions: Agree, then Agree in the sheet, clicked by the maintainer in the packer window" ;;
    *) echo "error: --terms-mode must be click, voiceover or manual, not '$TERMS_MODE'." >&2; exit 2 ;;
esac

for name_value in "--host:$GUEST_HOST" "--ipsw-sha256:$IPSW_SHA256" "--tart-version:$TART_VERSION" "--template-commit:$TEMPLATE_COMMIT" "--build-id:$BUILD_ID"; do
    flag="${name_value%%:*}"
    value="${name_value#*:}"
    [ -n "$value" ] || { echo "error: $flag is required." >&2; exit 2; }
done

for tool in ssh scp expect; do
    command -v "$tool" >/dev/null 2>&1 || { echo "error: $tool not found on this host." >&2; exit 3; }
done
[ -f "$SELF_DIR/tcc-seed.sh" ] || { echo "error: $SELF_DIR/tcc-seed.sh not found." >&2; exit 3; }

EXPECT_TIMEOUT=180
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=20 -o ServerAliveInterval=15 -o ServerAliveCountMax=4)

# Spawns "$@" (an ssh or scp invocation) through expect, answering both the
# SSH login password prompt and automationmodetool's differently-worded one,
# and exits with the spawned process's real exit status. Output is visible
# live (log_user 1): several of the steps below (the Claude Code install,
# TCC seeding) are slow enough that the maintainer watching build.sh's
# console should see progress, not silence.
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

# Same transport, but silent (log_user 0) and prints only what the spawned
# process wrote after the last password prompt was answered, trimmed of
# carriage returns and blank lines, keeping the last non-blank line. Callers
# must append `2>/dev/null` to their remote command themselves so stray
# remote stderr (there should be none, but this is a build recipe, not a
# guarantee) never lands in a value this script trusts.
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

ssh_guest() {
    run_over_ssh ssh "${SSH_OPTS[@]}" "admin@$GUEST_HOST" "$1"
}

ssh_guest_capture() {
    run_over_ssh_capture ssh "${SSH_OPTS[@]}" "admin@$GUEST_HOST" "$1 2>/dev/null"
}

scp_to_guest() {
    run_over_ssh scp "${SSH_OPTS[@]}" "$1" "admin@$GUEST_HOST:$2"
}

echo "provision.sh: waiting for SSH on $GUEST_HOST..."
attempt=0
until ssh_guest "true"; do
    attempt=$((attempt + 1))
    [ "$attempt" -lt 30 ] || { echo "error: guest at $GUEST_HOST never became reachable over SSH." >&2; exit 3; }
    sleep 5
done
echo "provision.sh: SSH is up (took $attempt retries)"

echo "provision.sh: installing the harness public key for BatchMode logins..."
pubkey_b64="$(base64 < "$AUTHORIZED_KEY" | tr -d '\n')"
ssh_guest "mkdir -p ~/.ssh && chmod 700 ~/.ssh && printf '%s' '$pubkey_b64' | base64 -d >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys" \
    || { echo "error: could not install the harness public key on the guest." >&2; exit 3; }
if ssh -i "$PRIVATE_KEY" -o BatchMode=yes -o IdentitiesOnly=yes "${SSH_OPTS[@]}" "admin@$GUEST_HOST" true 2>/dev/null; then
    echo "provision.sh: BatchMode login with $PRIVATE_KEY works"
else
    echo "error: a BatchMode ssh login with $PRIVATE_KEY was refused after installing $AUTHORIZED_KEY; the harness could not reach this image." >&2
    exit 3
fi

# Stage 2 (disable-sip.pkr.hcl) reports success whatever csrutil did, so the
# only place its outcome is checked is here, before anything that needs SIP
# off: root cannot open TCC.db with SIP on, and the seeding below would fail
# with a far less useful "authorization denied".
sip_status="$(ssh_guest_capture "csrutil status")" || sip_status=""
case "$sip_status" in
    *disabled*) echo "provision.sh: SIP is off ($sip_status)" ;;
    *) echo "error: the guest reports '$sip_status'; stage 2 (disable-sip.pkr.hcl) did not turn SIP off. Watch it with 'tart run <build-vm> --recovery' or its packer log, then rebuild." >&2; exit 3 ;;
esac

echo "provision.sh: seeding TCC grants for the driver (never the app under test)..."
scp_to_guest "$SELF_DIR/tcc-seed.sh" "/tmp/tcc-seed.sh" || { echo "error: could not copy tcc-seed.sh to the guest." >&2; exit 3; }
ssh_guest "chmod 755 /tmp/tcc-seed.sh && sudo /tmp/tcc-seed.sh && sudo rm -f /tmp/tcc-seed.sh" \
    || { echo "error: tcc-seed.sh failed on the guest; see its own output above for which check failed. The manual VNC grant in README.md is the fallback." >&2; exit 3; }

echo "provision.sh: enabling Automation Mode without an authorization prompt..."
ssh_guest "automationmodetool enable-automationmode-without-authentication" \
    || { echo "error: automationmodetool did not report success on the guest." >&2; exit 3; }

echo "provision.sh: pinning locale to en-US and the 24-hour clock..."
ssh_guest "defaults write NSGlobalDomain AppleLocale -string en_US && defaults write NSGlobalDomain AppleLanguages -array en-US && defaults write NSGlobalDomain AppleICUForce24HourTime -bool true && defaults -currentHost write NSGlobalDomain AppleICUForce24HourTime -bool true" \
    || { echo "error: could not set locale/clock defaults on the guest." >&2; exit 3; }

echo "provision.sh: disabling Software Update's automatic checks and installs..."
ssh_guest "sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticCheckEnabled -bool false && sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticDownload -bool false && sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate AutomaticallyInstallMacOSUpdates -bool false && sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate CriticalUpdateInstall -bool false && sudo defaults write /Library/Preferences/com.apple.SoftwareUpdate ConfigDataInstall -bool false && sudo softwareupdate --schedule off" \
    || { echo "error: could not disable Software Update on the guest." >&2; exit 3; }

echo "provision.sh: installing Claude Code (official installer; the download took five minutes over Tart's NAT on 2026-09-19, so this step gets twenty)..."
EXPECT_TIMEOUT=1200 ssh_guest "curl -fsSL https://claude.ai/install.sh | bash" \
    || { echo "error: the Claude Code installer failed on the guest." >&2; exit 3; }
# ~/.zprofile so an interactive Terminal.app login shell sees it, and
# ~/.zshenv too: a non-interactive `ssh host 'cmd'` (which is how every later
# harness unit drives `claude` from the host) sources only ~/.zshenv, never
# ~/.zprofile -- the same fact this script's own ssh_guest_capture already
# had to work around by using claude's full path instead of relying on PATH
# from a login shell.
ssh_guest "grep -q DISABLE_AUTOUPDATER ~/.zprofile 2>/dev/null || echo 'export DISABLE_AUTOUPDATER=1' >> ~/.zprofile; grep -q DISABLE_AUTOUPDATER ~/.zshenv 2>/dev/null || echo 'export DISABLE_AUTOUPDATER=1' >> ~/.zshenv" \
    || { echo "error: could not write DISABLE_AUTOUPDATER=1 into the guest's shell startup files." >&2; exit 3; }

claude_version="$(ssh_guest_capture "test -x ~/.local/bin/claude && ~/.local/bin/claude --version")" \
    || { echo "error: could not read claude --version from the guest after install." >&2; exit 3; }
[ -n "$claude_version" ] || { echo "error: claude --version produced no output on the guest." >&2; exit 3; }
echo "provision.sh: Claude Code installed, version: $claude_version"

macos_product_version="$(ssh_guest_capture "sw_vers -productVersion")" \
    || { echo "error: could not read sw_vers -productVersion from the guest." >&2; exit 3; }
macos_build="$(ssh_guest_capture "sw_vers -buildVersion")" \
    || { echo "error: could not read sw_vers -buildVersion from the guest." >&2; exit 3; }
[ -n "$macos_product_version" ] && [ -n "$macos_build" ] \
    || { echo "error: sw_vers produced no output on the guest." >&2; exit 3; }

build_date="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

echo "provision.sh: writing /etc/first-run-golden.json..."
json="$(jq -n \
    --argjson schema_version 1 \
    --arg image_name "first-run-golden" \
    --arg build_id "$BUILD_ID" \
    --arg macos_product_version "$macos_product_version" \
    --arg macos_build "$macos_build" \
    --arg ipsw_sha256 "$IPSW_SHA256" \
    --arg tart_version "$TART_VERSION" \
    --arg template_commit "$TEMPLATE_COMMIT" \
    --arg claude_code_version "$claude_version" \
    --arg build_date "$build_date" \
    --arg manual_steps "$MANUAL_STEPS" \
    '{schema_version: $schema_version, image_name: $image_name, build_id: $build_id, macos_product_version: $macos_product_version, macos_build: $macos_build, ipsw_sha256: $ipsw_sha256, tart_version: $tart_version, template_commit: $template_commit, claude_code_version: $claude_code_version, build_date: $build_date, manual_steps: $manual_steps}')" \
    || { echo "error: jq could not build the /etc/first-run-golden.json payload." >&2; exit 3; }

# Sent as base64 so the JSON's own quoting never has to survive the bash ->
# Tcl -> remote-shell round trip described above.
json_b64="$(printf '%s' "$json" | base64)"
ssh_guest "printf '%s' '$json_b64' | base64 -d | sudo tee /etc/first-run-golden.json >/dev/null && sudo chmod 0644 /etc/first-run-golden.json" \
    || { echo "error: could not write /etc/first-run-golden.json on the guest." >&2; exit 3; }

echo "provision.sh: ok"
echo "$json"
