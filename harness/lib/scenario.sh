#!/bin/bash
# The scenario library: `fixture`, `step`, `click`, `expect_event`, `shot`
# and `finding` — the vocabulary README.md's "Writing a scenario" section
# promises, plus `dialog` and `verdict` (also promised there) and a handful
# of small app-agnostic conveniences (`stage_asset`, `install_app`,
# `wait_for_status_item`, `open_status_item`, `ax_window_count`) that both
# apps' otherwise near-identical smoke scenarios would each have to write
# for themselves without this file.
#
# Sourced, never executed, by a scenario script at
# harness/scenarios/<app>/<name>.sh, itself run by run_scenario() in
# run.sh as `bash "$path" &`. Every helper below therefore runs in that
# same process, and `exit` from inside one of them really does end the
# scenario with the exit code run.sh's own taxonomy expects (0 pass, 1
# scenario fail, 3 harness error — see harness/README.md's Exit codes
# table). This file uses 2 in exactly one situation: a scenario calling a
# screen-driving helper on the app-fresh tier, which is the scenario
# author's own usage error, not a fact about whether the scenario reached
# its end state — see fact 3 below and _scenario_refuse_screen.
#
# THIS FILE IS SHARED (harness/SHARED.sha256, harness/README.md's "Shared
# files" section): byte identical in both repositories. It carries no
# app-specific logic whatsoever — no AgentMenu bundle id, no MeetingHop
# defaults key, nothing that differs between the two apps. Everything
# app-specific belongs in a scenario file instead, which is not shared.
#
# ===== Two facts this file is built around =====
#
# 1. `osascript` only ever exits 0 or 1, and on failure discards its own
#    script's stdout for a wrapper on stderr — so harness/guest/
#    ax.applescript and dialogs.applescript always exit 0 and always print
#    one JSON object, carrying an "error" and a "kind" of "usage",
#    "notfound" or "driver" when something went wrong (see either file's
#    own header for the full explanation). Every helper here that drives
#    one of them branches on that JSON "kind" field, in
#    _scenario_check_kind, never on osascript's own exit status. "notfound"
#    ends the scenario as a fail (exit 1): the target genuinely is not
#    there. "usage" and "driver" end it as a harness error (exit 3): the
#    driver was misused, or the guest could not answer at all — a
#    condition the scenario cannot tell from a real failure and must not
#    report as one. The five guest/*.sh scripts (install.sh, wait.sh,
#    shot.sh, reboot.sh, selfcheck.sh) are different: they use the real
#    0/1/2/3 taxonomy, and helpers that drive them branch on their actual
#    exit code instead.
#
# 2. A helper that fails mid-step has to end the scenario "with the step
#    named and the last screenshot attached" (U4's own approach note). Any
#    helper that wants to do that as a *best-effort* side step — taking one
#    more diagnostic screenshot on the way to failing, say — MUST capture
#    it through command substitution (`x="$(shot ...)"`), never call it
#    bare. `$(...)` runs in a subshell, so an `exit` a helper calls inside
#    it only ends that subshell; a bare call in the same process would take
#    the whole scenario down right there, before the real failure is even
#    reported. See wait_for_status_item's own diagnostic shot for the
#    idiom.
#
# 3. Only the stranger tier drives the screen. The app-fresh tier runs
#    inside the maintainer's own graphical session rather than a
#    disposable guest, so a click, a screenshot or a wait on a window is
#    visible to them and competes for their input right now — not a
#    theoretical risk: an app-fresh probe once launched isolated
#    AgentMenu instances and pressed a live status item while the
#    maintainer was away, and they came back to two menu-bar icons
#    clicking themselves. Every helper that reaches ax.applescript,
#    dialogs.applescript or guest/shot.sh therefore calls
#    _scenario_refuse_screen first and refuses (exit 2, fact 1 above)
#    rather than running anyway or silently no-opping — a scenario that
#    believes it clicked a control or took a screenshot and did not is
#    worse than one that stops outright. expect_event, fixture, finding,
#    step and verdict touch only the journal and the file system and are
#    unaffected.
#
# ===== Reaching the guest =====
#
# Every guest-side path is transport-aware (_scenario_guest_path): on the
# stranger tier it is a literal `~/$HARNESS_GUEST_HOME/...` for guest_run's
# shell to expand against the guest user's own home (guest_run's own doc
# comment: a caller quotes what needs quoting — this file never quotes a
# leading `~`, or the far shell would take it literally instead of
# expanding it), or the bare relative `$HARNESS_GUEST_HOME/...` scp itself
# resolves against the same home for guest_copy_in/guest_copy_out. On the
# app-fresh tier "the guest" is this same machine, so paths are real,
# absolute paths under $HARNESS_DIR or the run directory instead, and nothing
# is ever copied — mirroring exactly how run.sh's own `selfcheck` command
# already splits the same two cases for guest/selfcheck.sh.
set -euo pipefail

if [ -n "${HARNESS_SCENARIO_SH:-}" ]; then
    return 0
fi
HARNESS_SCENARIO_SH=1

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
. "$(dirname "${BASH_SOURCE[0]}")/vm.sh"

# ---------------------------------------------------------------------------
# Scenario state: what the current step is called, whether it is still
# open, and the last screenshot taken. This is deliberately NOT kept in
# plain shell variables — shot() and step() are meant to be called through
# command substitution for their return value (`p="$(shot "label")"`, the
# same idiom run.sh's own selfcheck command uses for guest_run's output),
# and `$(...)` always forks a subshell in bash: a variable assignment
# inside one never survives it. $HARNESS_STEPS does survive it (a write to
# a file is a real side effect, not shell state), and it is already the
# single source of truth README.md documents ("status reads the last line
# of that file to answer what it is doing now") — so every helper below
# derives current-step state by reading that file's last line instead of
# tracking a copy of it in memory that a subshell would silently discard.

_scenario_last_step_line() {
    tail -n 1 "$HARNESS_STEPS" 2>/dev/null || true
}

_scenario_current_step_name() {
    local line
    line="$(_scenario_last_step_line)"
    if [ -z "$line" ]; then
        printf '%s' "(no step)"
    else
        printf '%s' "$line" | jq -r '.step // "(no step)"'
    fi
}

_scenario_last_shot() {
    local line
    line="$(_scenario_last_step_line)"
    if [ -z "$line" ]; then
        printf '%s' "none"
    else
        printf '%s' "$line" | jq -r '.screenshot // "none"'
    fi
}

# True when the last line recorded is still "running" — i.e. a step is
# open and has not yet been closed "ok" or "fail".
_scenario_step_is_open() {
    local line status
    line="$(_scenario_last_step_line)"
    [ -z "$line" ] && return 1
    status="$(printf '%s' "$line" | jq -r '.status // empty' 2>/dev/null || true)"
    [ "$status" = "running" ]
}

# Slack added on top of a helper's own internal --timeout (guest/wait.sh's,
# dialogs.applescript wait's) before bounded_run wraps it, so the inner
# deadline always wins and returns its real exit code instead of being cut
# off by bounded_run's SIGTERM landing at the same instant.
_HARNESS_TIMEOUT_GRACE=5
# The bound on one poll attempt inside wait_for_status_item — deliberately
# much shorter than $HARNESS_STEP_TIMEOUT, which instead bounds the whole
# polling loop; see that function.
_HARNESS_PROBE_BOUND=5

# How long clear_quarantine waits for the app it just signalled to actually
# be gone, counted in 0.1s ticks. 15s: far more than a menu-bar app needs to
# exit (measured in tens of milliseconds) and far less than the step bound,
# so a genuine refusal to quit is reported as itself rather than as the next
# step's timeout. Event-driven -- the loop breaks the tick the process
# disappears -- so the number is a ceiling, never a cost.
_HARNESS_QUIT_TICKS=150

# ---------------------------------------------------------------------------
# Quoting and guest paths.

# POSIX single-quote wrapping: close the quote, backslash-escape a literal
# quote, reopen it. Portable to whatever shell is on the other end of
# guest_run (bash locally, the guest user's login shell over ssh), unlike
# bash's own `%q`, which can emit bash-only forms a remote non-bash shell
# will not parse the same way. NOTE: the substitution below must stay
# unquoted on the right-hand side of the assignment — wrapping it in
# double quotes changes how bash reads the escapes and silently produces
# the wrong string (verified by hand while writing this).
_scenario_quote() {
    local s=$1
    s=${s//\'/\'\\\'\'}
    printf "'%s'" "$s"
}

# Quotes a value for embedding in a guest_run command, unless it is a
# structural `~/...` path this file built itself — quoting that would stop
# the far shell from expanding the leading `~` at all.
_scenario_path_arg() {
    case "$1" in
        # A leading ~ must reach the guest shell unquoted or it expands to
        # nothing, but everything after it is an ordinary path that may hold
        # a space: "Library/Application Support" does.
        "~/"*) printf '~/%s' "$(_scenario_quote "${1#\~/}")" ;;
        *) _scenario_quote "$1" ;;
    esac
}

# The guest-side path for something under harness/ itself — a guest/
# driver script, or a fixture's own directory — in the two flavours the
# header above describes.
_scenario_guest_path() {
    local relative="$1"
    if [ "$HARNESS_GUEST_TRANSPORT" = "local" ]; then
        printf '%s/%s' "$HARNESS_DIR" "$relative"
    else
        printf '~/%s/%s' "$HARNESS_GUEST_HOME" "$relative"
    fi
}

# ---------------------------------------------------------------------------
# osascript, and the "kind" branch every AppleScript-driving helper shares.

_scenario_osascript() {
    local bound="$1" script_name="$2"
    shift 2
    local cmd="osascript $(_scenario_path_arg "$(_scenario_guest_path "guest/$script_name")")"
    local arg
    for arg in "$@"; do
        cmd="$cmd $(_scenario_quote "$arg")"
    done
    bounded_run "$bound" guest_run "$HARNESS_GUEST_IP" "$cmd"
}

_ax() { _scenario_osascript "$HARNESS_STEP_TIMEOUT" ax.applescript "$@"; }
_dialogs() { _scenario_osascript "$HARNESS_STEP_TIMEOUT" dialogs.applescript "$@"; }

# Branches on the JSON's own "kind" field (see this file's header, fact 1).
# No "kind" at all — including an empty string, which is what a totally
# unparseable response reduces to — is success and does nothing.
_scenario_check_kind() {
    local context="$1" json="$2" kind message
    kind="$(printf '%s' "$json" | jq -r '.kind // empty' 2>/dev/null || true)"
    [ -z "$kind" ] && return 0
    message="$(printf '%s' "$json" | jq -r '.error // "no message"' 2>/dev/null || echo "no message")"
    case "$kind" in
        notfound) _scenario_fail "$context: $message" ;;
        *) _scenario_harness_error "$context: $message" ;;
    esac
}

# Guards every screen-driving helper (see this file's header, fact 3): the
# app-fresh tier shares the maintainer's own display and input rather than
# a disposable guest, so it protects them from a scenario clicking a
# control, taking a screenshot or waiting on a window while they are
# sitting right there. A hard usage error (exit 2), never a scenario fail
# or a silent no-op — a scenario that believes it drove the screen and did
# not is worse than one that stops.
#
# A caller inside command substitution — `if [ "$(ax_window_count "$B")"
# -gt 0 ]`, exactly how harness/scenarios/agentmenu/smoke.sh calls it —
# puts this in a subshell (fact 2: `exit` only ends the subshell there),
# and an `if` condition suppresses errexit entirely, so without more the
# caller would see an empty string, the `[ -gt ]` would itself error to
# stderr, and the scenario would silently take the false branch and keep
# going — exactly the silent no-op this function exists to rule out.
# $BASH_SUBSHELL is nonzero in a subshell (this repo's real /bin/bash is
# 3.2, which has no $BASHPID to ask instead — read with :-0 so a shell
# that somehow lacks even that never turns this into an unbound-variable
# error instead of the refusal it is guarding), and $$ still names the
# top-level scenario process even from inside one — verified by hand:
# unlike the actual PID, bash never changes what $$ expands to inside a
# subshell — so a refusal reached from a subshell signals that process
# directly rather than trusting its own `exit` to be seen. The scenario
# then dies by SIGTERM rather than a clean exit 2; run.sh's own supervisor
# already maps any scenario exit that is not 0 or 1 to harness_error (3,
# see run.sh's own taxonomy), which is the right severity — stopping
# outright beats a scenario silently believing it drove the screen when it
# did not. The brief sleep only ever runs on this already-exceptional path
# and gives the signal a moment to land before the subshell would
# otherwise finish and hand its (empty) output back to a caller that
# suppressed the subshell's own exit status.
_scenario_refuse_screen() {
    local helper="$1"
    if [ "${HARNESS_TIER:-}" = "app-fresh" ]; then
        echo "error: $helper drives the screen and is refused on the app-fresh tier; only the stranger tier drives the screen." >&2
        if [ "${BASH_SUBSHELL:-0}" -gt 0 ]; then
            kill -TERM "$$" 2>/dev/null || true
            sleep 1
        fi
        exit 2
    fi
}

# ---------------------------------------------------------------------------
# Steps.

_scenario_emit_step() {
    local step="$1" status="$2" screenshot="$3"
    jq -nc --arg step "$step" --arg status "$status" --arg screenshot "$screenshot" --arg at "$(now_iso)" \
        '{step: $step, status: $status, screenshot: $screenshot, at: $at}' >> "$HARNESS_STEPS"
}

_scenario_close_open_step() {
    if _scenario_step_is_open; then
        _scenario_emit_step "$(_scenario_current_step_name)" "ok" "$(_scenario_last_shot)"
    fi
}

# Ends the scenario right now: the current step (or "(no step)", if none
# was ever opened) is written as failed with the last screenshot taken,
# whatever caused this is logged, and the process exits with the taxonomy
# code the caller chose. Nothing after this call ever runs.
_scenario_end() {
    local exit_code="$1" reason="$2" step_name shot
    step_name="$(_scenario_current_step_name)"
    shot="$(_scenario_last_shot)"
    warn "$step_name: $reason"
    _scenario_emit_step "$step_name" "fail" "$shot"
    exit "$exit_code"
}
_scenario_fail() { _scenario_end 1 "$1"; }
_scenario_harness_error() { _scenario_end 3 "$1"; }

# step <name>
#
# Opens a step: closes whatever step was open before (recorded "ok" — a
# helper that wanted it to end otherwise has already called _scenario_end,
# which itself already recorded "fail", and this line never runs), then
# records the new one into $HARNESS_STEPS in the contract's line shape,
# with status "running" and no screenshot yet. Subsequent shot calls
# attach to it by re-emitting this same step name with the new screenshot,
# so `status`'s "last line" always reflects what the scenario is looking
# at right now.
step() {
    local name="${1:?step requires a name.}"
    _scenario_close_open_step
    _scenario_emit_step "$name" "running" "none"
    log "step: $name"
}

# macOS 26 asks for ScreenCaptureKit's "bypass the system private window
# picker" consent the first time something captures the screen over SSH, even
# though kTCCServiceScreenCapture is already granted in the golden image. It is
# not a TCC access row, so the image cannot pre-grant it; it has to be answered
# on the running guest.
#
# Left on screen it does two kinds of damage, both seen on the first real runs:
# it sits in the middle of every screenshot a maintainer is supposed to review
# (R17, R18), and UserNotificationCenter owns it, so a later `dialog wait` for
# another TCC sheet could match it instead. The dialogs driver now tells the
# kinds apart by their text; this keeps it out of the screenshots.
#
# Checked before every capture rather than once per run: the prompt is raised
# BY capturing, so a single check at the start of the scenario runs before the
# thing that causes it and clears nothing. That is exactly what happened on the
# 2026-09-20 MeetingHop run, where the prompt still sat in the middle of the
# final screenshot.
#
# Best-effort by design: no prompt is the normal case once a guest has
# answered, and a failure here must never fail a scenario.
_scenario_clear_screenrecording() {
    [ "${HARNESS_TIER:-}" = "stranger" ] || return 0
    # Timeout 0, not a poll: the prompt this clears was raised by the PREVIOUS
    # capture and has been on screen through several ssh round trips since, so
    # one look settles it. A 3-second wait bought nothing and cost three
    # seconds on every screenshot that had nothing to clear, which is most of
    # them.
    local json present
    json="$(_dialogs wait screenrecording 0 2>/dev/null)" || return 0
    present="$(printf '%s' "$json" | jq -r '.present // empty' 2>/dev/null)"
    [ "$present" = "true" ] || return 0
    json="$(_dialogs answer screenrecording allow 2>/dev/null)" || return 0
    if [ "$(printf '%s' "$json" | jq -r 'has("answered")' 2>/dev/null)" = "true" ]; then
        _scenario_record_evidence "$json"
        log "cleared macOS's screen-recording approval prompt so it cannot obscure a screenshot or be mistaken for another dialog"
    fi
    return 0
}

# ---------------------------------------------------------------------------
# clear_quarantine <app-name>
#
# Removes com.apple.quarantine from /Applications/<app>.app and relaunches it.
# Call this once, right after the Gatekeeper sheet has been answered.
#
# This is not a shortcut past Gatekeeper -- it reproduces what answering it in
# Finder already does. When a person consents, LaunchServices clears the flag
# and the app runs from /Applications. Our install path does not get that:
# install.sh moves the bundle with `mv` from a shell, so after consent the
# xattr is still there (its flags change 0083 -> 00c3, recording the consent,
# but the attribute remains) and macOS keeps running the app TRANSLOCATED,
# from a randomised read-only /private/var/folders/.../AppTranslocation/ path.
#
# Measured on a clean clone, 2026-09-20: after answering Open, MeetingHop ran
# from AppTranslocation; clearing the xattr and relaunching moved it to
# /Applications. A translocated bundle has no stable identity for TCC, so a
# scenario that depends on any per-app permission is testing a state no real
# user is ever in.
#
# Three things happen here, in this order, and each one is waited for or
# checked rather than assumed. The first version of this helper was a single
# line -- `pkill; xattr -dr; nohup open &`, every failure swallowed by
# `2>/dev/null` and a trailing `|| true` -- and it was the most consequential
# race in the whole harness, because everything it does is a precondition for
# the scenario that follows and none of it was observed:
#
#   1. `pkill` only asks. It returns the instant the signal is delivered, not
#      when the process is gone, so `open` a few milliseconds later could
#      reach LaunchServices while the old instance was still terminating --
#      and LaunchServices answers "already running" by activating a process
#      that then dies, leaving nothing at all. `smoke` in the v0.2.0-beta.2
#      gate photographed exactly that: no status item, no dialog, no app,
#      120s of waiting, and the very same scenario against the very same
#      asset passed 23 minutes later.
#   2. `xattr -dr` can fail, and its failure was discarded. The relaunch then
#      trips Gatekeeper a second time, on a sheet no scenario answers --
#      because `dialog wait gatekeeper` has already run, once, before this.
#      `bridge-install` in that gate photographed that one: the second
#      "downloaded from the Internet" sheet still up at 120s.
#   3. `open`'s exit status was thrown away twice over, by the `&` and by the
#      `|| true`. The one command whose success the next step depends on was
#      the one command nobody looked at.
#
# So: signal, then poll until the process is actually gone (bounded, and it
# returns the moment it is, never a fixed sleep); clear the attribute and
# prove it is gone before relaunching, which is what makes a second
# Gatekeeper sheet impossible rather than merely unlikely; then `open` in the
# foreground -- safe precisely because the attribute is proven gone, so there
# is no sheet left to block it -- and read its status. Anything that did not
# come out right fails the scenario here, where the cause is named, instead
# of downstream as "the status item never appeared".
clear_quarantine() {
    local app_name="${1:?clear_quarantine requires the app name, e.g. MeetingHop.}"
    _scenario_refuse_screen "clear_quarantine"
    local app="/Applications/${app_name}.app"
    local quoted_name quoted_app
    quoted_name="$(_scenario_quote "$app_name")"
    quoted_app="$(_scenario_path_arg "$app")"

    # One round trip. Written for the guest's own login shell (zsh on the
    # stranger tier, bash locally), so: POSIX only, no arrays, no `local`.
    # The loop is bounded by a count of 0.1s ticks and breaks on the
    # condition, so a process that exits immediately costs one tick.
    local script
    script="pkill -x ${quoted_name} 2>/dev/null
n=0
while [ \$n -lt ${_HARNESS_QUIT_TICKS} ] && pgrep -x ${quoted_name} >/dev/null 2>&1; do
    sleep 0.1
    n=\$((n+1))
done
if pgrep -x ${quoted_name} >/dev/null 2>&1; then printf 'alive '; else printf 'gone '; fi
xattr -dr com.apple.quarantine ${quoted_app} 2>/dev/null
if xattr -p com.apple.quarantine ${quoted_app} >/dev/null 2>&1; then printf 'quarantined '; else printf 'clean '; fi
open ${quoted_app} >/dev/null 2>&1
printf '%s' \$?"

    local out rc=0
    if out="$(bounded_run "$HARNESS_STEP_TIMEOUT" guest_run "$HARNESS_GUEST_IP" "$script")"; then rc=0; else rc=$?; fi
    if [ "$rc" -ne 0 ]; then
        _scenario_harness_error "clear_quarantine: could not reach the guest to relaunch $app_name (exit $rc)."
    fi
    out="$(printf '%s' "$out" | tail -n 1 | tr -d '\r')"

    local quit_state attribute_state open_rc
    quit_state="$(printf '%s' "$out" | awk '{print $1}')"
    attribute_state="$(printf '%s' "$out" | awk '{print $2}')"
    open_rc="$(printf '%s' "$out" | awk '{print $3}')"

    case "$quit_state" in
        gone) ;;
        alive) _scenario_fail "clear_quarantine: $app_name was still running $((_HARNESS_QUIT_TICKS / 10))s after pkill, so the relaunch would have raced a process that is still exiting." ;;
        *) _scenario_harness_error "clear_quarantine: the guest answered '$out', which does not name whether $app_name quit." ;;
    esac
    case "$attribute_state" in
        clean) ;;
        quarantined) _scenario_fail "clear_quarantine: com.apple.quarantine is still on $app after xattr -dr, so the relaunch would raise a second Gatekeeper sheet that no scenario answers." ;;
        *) _scenario_harness_error "clear_quarantine: the guest answered '$out', which does not name the quarantine attribute's state." ;;
    esac
    case "$open_rc" in
        0) ;;
        ''|*[!0-9]*) _scenario_harness_error "clear_quarantine: the guest answered '$out', which does not name open's exit status." ;;
        *) _scenario_fail "clear_quarantine: \`open $app\` failed with exit $open_rc, so nothing was relaunched from /Applications." ;;
    esac

    log "cleared the quarantine attribute and relaunched $app_name from /Applications: $app_name quit, the attribute is gone, open returned 0 (Finder does all three on consent; a shell mv does not, and the app runs translocated until it happens)"
    return 0
}

# ---------------------------------------------------------------------------
# shot <label>
#
# Captures a screenshot via guest/shot.sh in the guest, brings it back to
# $HARNESS_SHOT_DIR (a no-op on the app-fresh tier, which points shot.sh at
# $HARNESS_SHOT_DIR directly — see this file's header), attaches it to the
# open step, and prints the resulting host path. A shot.sh exit 3 is a
# harness error, not evidence — its own contract — so this never reports a
# rejected capture as the scenario having merely failed to reach a state.
shot() {
    local label="${1:?shot requires a label.}"
    _scenario_refuse_screen "shot"
    _scenario_clear_screenrecording
    mkdir -p "$HARNESS_SHOT_DIR"
    local dest
    if [ "$HARNESS_GUEST_TRANSPORT" = "local" ]; then
        dest="$HARNESS_SHOT_DIR"
    else
        dest="~/$HARNESS_GUEST_HOME/shots"
    fi
    local cmd="bash $(_scenario_path_arg "$(_scenario_guest_path guest/shot.sh)") --dir $(_scenario_path_arg "$dest") --label $(_scenario_quote "$label")"
    local out rc=0
    if out="$(bounded_run "$HARNESS_STEP_TIMEOUT" guest_run "$HARNESS_GUEST_IP" "$cmd")"; then rc=0; else rc=$?; fi
    if [ "$rc" -eq 3 ]; then
        _scenario_harness_error "shot: the capture for '$label' failed validation in the guest — a shot.sh exit 3 is a harness error, not evidence."
    elif [ "$rc" -ne 0 ]; then
        _scenario_harness_error "shot: could not capture '$label' in the guest (exit $rc)."
    fi
    local guest_path host_path
    guest_path="$(printf '%s' "$out" | tail -n 1 | tr -d '\r')"
    if [ -z "$guest_path" ]; then
        _scenario_harness_error "shot: shot.sh printed no path for '$label'."
    fi
    if [ "$HARNESS_GUEST_TRANSPORT" = "local" ]; then
        host_path="$guest_path"
    else
        host_path="$HARNESS_SHOT_DIR/$(basename -- "$guest_path")"
        if ! guest_copy_out "$HARNESS_GUEST_IP" "$HARNESS_GUEST_HOME/shots/$(basename -- "$guest_path")" "$host_path"; then
            _scenario_harness_error "shot: could not copy '$label' back from the guest."
        fi
    fi
    if _scenario_step_is_open; then
        _scenario_emit_step "$(_scenario_current_step_name)" "running" "$host_path"
    fi
    printf '%s\n' "$host_path"
}

# ---------------------------------------------------------------------------
# click <bundle-id> <identifier> [--reopen]
#
# Drives ax.applescript's click verb, by AXIdentifier, never by coordinate
# or title (R15). --reopen clicks the status item first (ax.applescript's
# statusclick verb) to reopen a popover a foreground-stealing step in
# between may have closed, before the real click; a failure reopening is
# reported the same way a failure on the click itself would be.
# Waits, bounded, for an AXIdentifier to exist before anything clicks it.
#
# `ax.applescript`'s locate() is one snapshot of the accessibility tree, and
# a SwiftUI view is in that tree some time after it is on screen, not at the
# same instant. `vanilla-first-run` in the v0.2.0-beta.2 gate failed on
# `setup.folder.c6c8b54fe3ce.toggle` two seconds after `detecting finished`
# named that very folder and with the screenshot of the step showing the
# checkbox drawn -- while `no-agent`, which clicks the identical identifier
# computed the identical way, passed in the same batch. Nothing about the
# app or the identifier was wrong; the lookup was simply early, and had no
# second chance because click() asked once.
#
# `find` is the right verb to poll on: it answers `{"found":false}` rather
# than raising, so absence is a value here and only a driver failure is an
# error. Bounded by the step timeout, like every other wait in this file,
# and it returns the poll the element appears -- so the normal case pays one
# probe and a genuine absence still fails, loudly, with a screenshot.
_scenario_await_element() {
    local bundle="$1" identifier="$2"
    local deadline=$(( $(date +%s) + HARNESS_STEP_TIMEOUT ))
    local json found
    while :; do
        if json="$(_scenario_osascript "$_HARNESS_PROBE_BOUND" ax.applescript find "$bundle" "$identifier" 2>/dev/null)"; then
            _scenario_check_kind "looking for $identifier under $bundle" "$json"
            found="$(printf '%s' "$json" | jq -r '.found // false' 2>/dev/null || echo false)"
            if [ "$found" = "true" ]; then
                return 0
            fi
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            # Command substitution on purpose -- see this file's header,
            # fact 2.
            : "$(shot "element-timeout" 2>/dev/null)" || true
            _scenario_fail "no element with AXIdentifier $identifier appeared under $bundle within ${HARNESS_STEP_TIMEOUT}s."
        fi
        sleep 0.5
    done
}

click() {
    local bundle="${1:?click requires a bundle id.}" identifier="${2:?click requires an identifier.}" opt="${3:-}"
    _scenario_refuse_screen "click"
    if [ "$opt" = "--reopen" ]; then
        local reopen_json
        reopen_json="$(_ax statusclick "$bundle")" || _scenario_harness_error "click: could not reach the guest to reopen $bundle's popover."
        _scenario_check_kind "reopening $bundle's popover before clicking $identifier" "$reopen_json"
    fi
    # After the reopen, never before it: the popover the element lives in
    # may not exist until that click has landed.
    _scenario_await_element "$bundle" "$identifier"
    local json
    json="$(_ax click "$bundle" "$identifier")" || _scenario_harness_error "click: could not reach the guest to click $identifier on $bundle."
    _scenario_check_kind "clicking $identifier on $bundle" "$json"
    log "clicked $identifier on $bundle"
}

# open_status_item <bundle-id>
#
# Clicks the app's own status item (ax.applescript's statusclick verb),
# e.g. to open its menu before a screenshot shows what is in it. Same
# "kind" branch as click.
open_status_item() {
    local bundle="${1:?open_status_item requires a bundle id.}"
    _scenario_refuse_screen "open_status_item"
    local json
    json="$(_ax statusclick "$bundle")" || _scenario_harness_error "open_status_item: could not reach the guest to click $bundle's status item."
    _scenario_check_kind "opening $bundle's status item" "$json"
}

# wait_for_status_item <bundle-id>
#
# Polls ax.applescript's statusitem verb — which itself first proves the
# app's process is running at all (its processForBundle raises "kind":
# "driver" otherwise) — until it reports found:true or $HARNESS_STEP_TIMEOUT
# elapses. Prints the idiom ("app-menu-bar-2" or "systemuiserver") on
# success. Every "kind" seen while polling (including "driver" — the
# process is not up *yet*, which is exactly what this waits out) is treated
# as "not yet", never as an immediate harness error; only running out of
# the bound ends the scenario, as a fail — this is the one piece of
# "waiting" logic both smoke scenarios need that is not a journal event
# (v0.1.0 ships no journal hook), so it lives here rather than duplicated in
# both apps' otherwise identical scenarios. Bounded per attempt at
# $_HARNESS_PROBE_BOUND seconds, never past it, and the whole loop never
# past $HARNESS_STEP_TIMEOUT (R14).
wait_for_status_item() {
    local bundle="${1:?wait_for_status_item requires a bundle id.}"
    _scenario_refuse_screen "wait_for_status_item"
    local deadline=$(( $(date +%s) + HARNESS_STEP_TIMEOUT ))
    local json idiom
    while :; do
        if json="$(_scenario_osascript "$_HARNESS_PROBE_BOUND" ax.applescript statusitem "$bundle" 2>/dev/null)"; then
            idiom="$(printf '%s' "$json" | jq -r 'if has("kind") then empty else (.idiom // empty) end' 2>/dev/null || true)"
            if [ -n "$idiom" ]; then
                printf '%s\n' "$idiom"
                return 0
            fi
        fi
        if [ "$(date +%s)" -ge "$deadline" ]; then
            # Best effort, and captured through command substitution on
            # purpose (see this file's header, fact 2): a bare call would
            # let a harness error inside shot() call `exit` in THIS
            # process and pre-empt the real failure below; $(...) forks a
            # subshell, so that exit only ends the subshell, while the
            # screenshot it wrote to $HARNESS_STEPS on the way (a file
            # write survives the subshell exiting, unlike a variable
            # would) is still there for _scenario_fail to pick up below.
            : "$(shot "status-item-timeout" 2>/dev/null)" || true
            _scenario_fail "$bundle's status item never appeared within ${HARNESS_STEP_TIMEOUT}s."
        fi
        sleep 0.5
    done
}

# ax_window_count <bundle-id>
#
# A best-effort peek at how many windows the app currently has, e.g. to
# decide whether an optional setup card is worth a screenshot. Never fails
# the scenario: any "kind" in the response, or an unreachable guest, is
# reported as zero rather than treated as evidence of anything (R17: a
# black-box scenario never asserts on this, only screenshots what it
# finds).
ax_window_count() {
    local bundle="${1:?ax_window_count requires a bundle id.}"
    _scenario_refuse_screen "ax_window_count"
    local json count
    json="$(_scenario_osascript "$_HARNESS_PROBE_BOUND" ax.applescript windows "$bundle" 2>/dev/null || true)"
    count="$(printf '%s' "$json" | jq -r 'if has("kind") then 0 else ((.windows // []) | length) end' 2>/dev/null || echo 0)"
    printf '%s\n' "${count:-0}"
}

# ---------------------------------------------------------------------------
# dialog wait <kind> [timeout]
# dialog answer <kind> <allow|deny>
# dialog probe
#
# Wraps dialogs.applescript's own verbs for the system dialogs a scenario has
# to get past that are not app state (R15: Gatekeeper, Calendar, Automation,
# and macOS 26's screen-recording approval), plus its generic "alert" kind.
# `wait`'s own [timeout] is capped at $HARNESS_STEP_TIMEOUT — a scenario may
# ask for less, never more; R14's bound is the step's own, not a scenario
# author's to raise. A response of present:false is not itself a failure of
# any kind — a scenario decides what a dialog never showing up means (the U4
# edge case: no quarantine attribute, Gatekeeper does not prompt, and the
# scenario still passes) — so this only raises through _scenario_check_kind
# on a real "kind" in the response, exactly like click. A successful `answer`
# is also recorded to $HARNESS_EVIDENCE on the host directly, in the shape
# dialogs.applescript's own header documents for its (guest-side) --evidence
# flag, which this never passes — the JSON already back from `answer` carries
# the same fields, so there is nothing to copy out of the guest for this one.
# dialog wait   <kind> [timeout] [--text <substring>]
# dialog answer <kind> <allow|deny> [--text <substring>]
# dialog probe
#
# Anything after the positional arguments is passed through to
# dialogs.applescript untouched, which today means `--text <substring>`: an
# extra requirement on the dialog's own text, for a kind that can have two
# dialogs on screen at once. See that file's `extraTextSubstring`.
dialog() {
    local action="${1:?dialog requires wait, answer or probe.}"
    _scenario_refuse_screen "dialog"
    case "$action" in
        wait)
            local kind="${2:?dialog wait requires a kind.}" timeout
            shift 2
            # The timeout is optional and so is everything after it, so it is
            # recognised by shape: a bare number. Anything else -- a `--text`
            # flag, or nothing at all -- leaves the step bound in place.
            case "${1:-}" in
                ''|*[!0-9]*) timeout="$HARNESS_STEP_TIMEOUT" ;;
                *) timeout="$1"; shift ;;
            esac
            if [ "$timeout" -gt "$HARNESS_STEP_TIMEOUT" ] 2>/dev/null; then
                timeout="$HARNESS_STEP_TIMEOUT"
            fi
            local json
            json="$(_scenario_osascript "$((timeout + _HARNESS_TIMEOUT_GRACE))" dialogs.applescript wait "$kind" "$timeout" "$@")" \
                || _scenario_harness_error "dialog: could not reach the guest to wait for the $kind dialog."
            _scenario_check_kind "waiting for the $kind dialog" "$json"
            printf '%s\n' "$json"
            ;;
        answer)
            local kind="${2:?dialog answer requires a kind.}" choice="${3:?dialog answer requires allow or deny.}"
            case "$choice" in
                allow|deny) ;;
                *) _scenario_harness_error "dialog: answer's choice must be allow or deny, got '$choice'." ;;
            esac
            shift 3
            local json
            json="$(_dialogs answer "$kind" "$choice" "$@")" || _scenario_harness_error "dialog: could not reach the guest to answer the $kind dialog."
            _scenario_check_kind "answering the $kind dialog with $choice" "$json"
            _scenario_record_evidence "$json"
            # The authoritative record of what was actually pressed. A scenario
            # that narrates its own "was answered Open" is stating an intention;
            # this states the outcome, including when no button matched by name
            # and the position fallback guessed. That distinction is not
            # academic: on the non-notarized Gatekeeper sheet nothing matches
            # "open", and the guess landed on "Done" while the run logged
            # "answered Open" and carried on.
            local _btn _how
            _btn="$(printf '%s' "$json" | jq -r '.button // "?"' 2>/dev/null)"
            _how="$(printf '%s' "$json" | jq -r '.matched_by // "?"' 2>/dev/null)"
            if [ "$_how" = "position" ]; then
                log "$kind dialog: pressed \"$_btn\" for $choice — by POSITION, no button matched by name"
            else
                log "$kind dialog: pressed \"$_btn\" for $choice"
            fi
            printf '%s\n' "$json"
            ;;
        probe)
            local json
            json="$(_dialogs probe)" || _scenario_harness_error "dialog: could not reach the guest to probe for dialogs."
            printf '%s\n' "$json"
            ;;
        *)
            _scenario_harness_error "dialog: unknown action '$action' (wait, answer or probe)."
            ;;
    esac
}

_scenario_record_evidence() {
    local json="$1"
    jq -nc \
        --arg process "$(printf '%s' "$json" | jq -r '.process // ""')" \
        --arg title "$(printf '%s' "$json" | jq -r '.title // ""')" \
        --arg button "$(printf '%s' "$json" | jq -r '.button // ""')" \
        --arg t "$(now_iso)" \
        '{process: $process, window_title: $title, button: $button, t: $t}' >> "$HARNESS_EVIDENCE"
}

# ---------------------------------------------------------------------------
# expect_event <name> [field=value]...
#
# Waits on the app's own journal for the first line whose event matches
# <name> and (if given) whose data fields all match, by driving
# guest/wait.sh so there is exactly one implementation of that match, and
# pulls the journal back to the host (a no-op on the app-fresh tier, where
# it already lands at $HARNESS_JOURNAL directly) whether this call matched
# or not, so the host copy grows alongside the guest's over the scenario's
# life. Bounded by $HARNESS_STEP_TIMEOUT (R14). Note: wait.sh takes its own
# diagnostic screenshot on a timeout, but through --shot-dir directly, not
# through this file's shot() — so it lands on disk but is not what a
# failing step's "last screenshot" points at; that is still whatever the
# scenario's own last explicit shot() call captured, exactly as for every
# other helper here. On the app-fresh tier --shot-dir is left off the
# wait.sh command entirely (guest/wait.sh's own header: no --shot-dir
# means no screenshot, never an error) rather than pointed anywhere on
# this machine — this is the one screen-adjacent thing expect_event does,
# and fact 3 requires it be suppressed, not refused: expect_event itself
# is journal work a scenario may call on this tier, only the diagnostic
# capture inside it is screen work.
#
# The journal is not in the harness's own guest directory: KTD3 puts it
# inside the app's harness directory under Application Support, named by
# the leaf the harnessJournal default carries. A scenario says where with
# journal_at before its first expect_event, and a tier that relocates that
# directory sets HARNESS_GUEST_JOURNAL itself. Neither smoke scenario calls
# expect_event, because v0.1.0 ships no hook.
# journal_at <bundle-id> <leaf-name>
#
# Says where the app under test writes its journal, so expect_event and the
# copy back to the host both read one place. KTD3 fixes that place: the
# app's own harness directory under Application Support, holding a file
# named by the leaf the harnessJournal default carries, and a leaf name is
# all the app will accept. On a tier that relocates the harness directory,
# the tier sets HARNESS_GUEST_JOURNAL itself and a scenario need not call
# this at all.
journal_at() {
    local bundle="${1:?journal_at requires a bundle identifier.}"
    local leaf="${2:?journal_at requires a journal leaf name.}"
    case "$bundle" in
        *[!A-Za-z0-9._-]*|*..*|"") _scenario_harness_error "journal_at: '$bundle' is not a bundle identifier." ;;
    esac
    case "$leaf" in
        *[!A-Za-z0-9._-]*|*..*|"") _scenario_harness_error "journal_at: '$leaf' is not a leaf file name." ;;
    esac
    if [ "$HARNESS_GUEST_TRANSPORT" = "local" ]; then
        HARNESS_GUEST_JOURNAL="$HOME/Library/Application Support/$bundle/harness/$leaf"
    else
        HARNESS_GUEST_JOURNAL="~/Library/Application Support/$bundle/harness/$leaf"
    fi
    export HARNESS_GUEST_JOURNAL
    log "journal_at: $HARNESS_GUEST_JOURNAL"
}

# _scenario_wait_for_event <name> <timeout> [field=value]...
#
# The polling mechanics expect_event and confirm_dialog both need, factored
# out so there is exactly one place that drives guest/wait.sh: builds its
# command line, runs it bounded by <timeout> (a caller's own bound, not
# necessarily $HARNESS_STEP_TIMEOUT — confirm_dialog below uses a much
# shorter one per attempt), and pulls the journal back to the host whether
# it matched or not, so the host copy grows alongside the guest's
# regardless of which caller is asking. Returns wait.sh's own exit code
# (0 matched, printed on stdout; 1 timed out; 2 usage error; 3 the journal
# path is a driver problem) rather than deciding what it means — that is
# each caller's job: expect_event fails the scenario outright on anything
# but 0, confirm_dialog treats a 1 as "try clicking again."
_scenario_wait_for_event() {
    local name="${1:?_scenario_wait_for_event requires an event name.}"
    local timeout="${2:?_scenario_wait_for_event requires a timeout.}"
    shift 2
    local journal_arg
    if [ -n "${HARNESS_GUEST_JOURNAL:-}" ]; then
        journal_arg="$HARNESS_GUEST_JOURNAL"
    else
        _scenario_harness_error "_scenario_wait_for_event: no journal path is set; call journal_at <bundle-id> <leaf-name> first, or set HARNESS_GUEST_JOURNAL."
    fi
    local cmd="bash $(_scenario_path_arg "$(_scenario_guest_path guest/wait.sh)")"
    cmd="$cmd --journal $(_scenario_path_arg "$journal_arg")"
    cmd="$cmd --event $(_scenario_quote "$name")"
    cmd="$cmd --timeout $timeout"
    if [ "${HARNESS_TIER:-}" != "app-fresh" ]; then
        local shot_dir_arg
        if [ "$HARNESS_GUEST_TRANSPORT" = "local" ]; then
            shot_dir_arg="$HARNESS_SHOT_DIR"
        else
            shot_dir_arg="~/$HARNESS_GUEST_HOME/shots"
        fi
        cmd="$cmd --shot-dir $(_scenario_path_arg "$shot_dir_arg")"
    fi
    local kv
    for kv in "$@"; do
        case "$kv" in
            *=*) cmd="$cmd --field $(_scenario_quote "$kv")" ;;
            *) _scenario_harness_error "_scenario_wait_for_event: field arguments must be key=value, got '$kv'." ;;
        esac
    done

    local out rc=0
    if out="$(bounded_run "$((timeout + _HARNESS_TIMEOUT_GRACE))" guest_run "$HARNESS_GUEST_IP" "$cmd")"; then
        rc=0
    else
        rc=$?
    fi

    journal_fetch

    if [ "$rc" -eq 0 ]; then
        printf '%s\n' "$out"
    fi
    return "$rc"
}

# Copies the app's journal off the guest to $HARNESS_JOURNAL, where the run
# directory keeps it and the gate reads it. Best effort by design: a journal
# that cannot be fetched must not change a scenario's verdict (R13).
#
# Every `expect_event` calls this, which is why most scenarios never have to.
# A scenario that asserts nothing from the journal does: `smoke` turns the
# hook on, proves the status item by accessibility alone, and used to leave
# the guest with the only copy — so `report.sh` had no first line to read the
# nonce from and scored the whole gate `error` however the scenarios went.
# Naming the copy is better than a scenario acquiring one as a side effect of
# an assertion it does not want to make.
journal_fetch() {
    [ -n "${HARNESS_GUEST_JOURNAL:-}" ] || return 0
    if [ "$HARNESS_GUEST_TRANSPORT" != "local" ]; then
        guest_copy_out "$HARNESS_GUEST_IP" "$HARNESS_GUEST_JOURNAL" "$HARNESS_JOURNAL" 2>/dev/null || true
    elif [ "$HARNESS_GUEST_JOURNAL" != "$HARNESS_JOURNAL" ]; then
        cp "$HARNESS_GUEST_JOURNAL" "$HARNESS_JOURNAL" 2>/dev/null || true
    fi
    return 0
}

expect_event() {
    local name="${1:?expect_event requires an event name.}"
    shift || true
    local out rc=0
    if out="$(_scenario_wait_for_event "$name" "$HARNESS_STEP_TIMEOUT" "$@")"; then
        rc=0
    else
        rc=$?
    fi
    case "$rc" in
        0)
            log "expect_event: $name matched"
            printf '%s\n' "$out"
            ;;
        1)
            _scenario_fail "expect_event: '$name' did not appear within ${HARNESS_STEP_TIMEOUT}s."
            ;;
        *)
            _scenario_harness_error "expect_event: waiting for '$name' failed in the guest (exit $rc)."
            ;;
    esac
}

# ---------------------------------------------------------------------------
# confirm_dialog <kind> <allow|deny> <event> [field=value]...
#
# Answers a system dialog and does not call it answered until the app's own
# journal says so — a click succeeding and the state it was meant to
# produce actually landing turned out to be two different facts, not one.
#
# Measured directly (2026-09-21, diagnosed on a hand-driven probe of the
# exact install-then-relaunch sequence, never reproduced on demand — see
# docs/plans/2026-09-18-first-run-sandbox-harness-research-notes.md's dated
# addendum for the full evidence): EventKit/TCC resolve a calendar grant in
# 10-50ms once genuinely triggered; the translocated first launch never
# touches Calendar TCC at all, confirmed at the OS's own accounting, not
# just the app's; no crash, ever, in either instance; and yet
# dialogs.applescript occasionally reports a clean "Allow Full Access" (or
# "Don't Allow") click that the app's own journal never follows up on — 3
# times in 11 runs this unit saw, never once caught in the act despite
# instrumented, repeated attempts to catch it. Nothing about the delay is
# in the app, so widening a timeout would only make the same silent gap
# take longer to fail. The fix is the rule this whole file otherwise
# already follows for everything else a scenario waits on: assert the
# state the app reports, never the action the driver took.
#
# Each attempt: wait for the dialog (bounded by $HARNESS_CONFIRM_TIMEOUT,
# default 10s — short on purpose, comfortably above the 10-50ms this
# resolves in when it works, and never widened to paper over a real hang),
# click it if present (a dialog that never appears is not itself a failure
# here — see wait_for_status_item's own sibling scenarios, where "already
# granted, nothing to click" is a legitimate path; a caller that needs the
# dialog to have appeared, e.g. access-denied.sh, checks that itself before
# calling this), then wait the same short bound for <event> — every field
# matching — to appear in the journal. Up to three attempts total. Every
# attempt after the first is logged, at the supervisor level, before it
# runs, and a finding records exactly how many attempts a passing run
# needed (dialog-confirm-retry-2 / dialog-confirm-retry-3, harness/
# findings.txt) — a run that quietly needs three clicks routinely is a
# signal worth seeing, not a coincidence to average away. On the third
# miss, a probe of whatever dialogs.applescript can currently see is
# folded into the failure message alongside the attempt count, so a
# genuine hang still fails loudly and diagnosably rather than being
# retried into either a false pass or a generic timeout.
confirm_dialog() {
    local kind="${1:?confirm_dialog requires a dialog kind.}"
    local choice="${2:?confirm_dialog requires allow or deny.}"
    local event="${3:?confirm_dialog requires an event name.}"
    shift 3
    _scenario_refuse_screen "confirm_dialog"
    local timeout="${HARNESS_CONFIRM_TIMEOUT:-10}"
    local max_attempts=3
    local attempt wait_json out rc probe_json
    for attempt in 1 2 3; do
        wait_json="$(dialog wait "$kind" "$timeout")"
        if [ "$(printf '%s' "$wait_json" | jq -r '.present')" = "true" ]; then
            shot "${kind}-prompt" > /dev/null
            dialog answer "$kind" "$choice" > /dev/null
        else
            log "confirm_dialog: $kind did not prompt on attempt $attempt/$max_attempts"
        fi

        out=""
        rc=0
        if out="$(_scenario_wait_for_event "$event" "$timeout" "$@")"; then
            rc=0
        else
            rc=$?
        fi

        if [ "$rc" -eq 0 ]; then
            if [ "$attempt" -gt 1 ]; then
                log "confirm_dialog: $kind $choice confirmed by '$event' on attempt $attempt/$max_attempts"
                finding "dialog-confirm-retry-$attempt"
            fi
            printf '%s\n' "$out"
            return 0
        fi
        if [ "$rc" -ne 1 ]; then
            _scenario_harness_error "confirm_dialog: waiting for '$event' failed in the guest (exit $rc)."
        fi

        if [ "$attempt" -lt "$max_attempts" ]; then
            probe_json="$(dialog probe 2>/dev/null || echo '{}')"
            log "confirm_dialog: attempt $attempt/$max_attempts answered $kind $choice but '$event' did not appear within ${timeout}s — retrying; probe saw: $probe_json"
        fi
    done
    probe_json="$(dialog probe 2>/dev/null || echo '{}')"
    _scenario_fail "confirm_dialog: '$event' never appeared after $max_attempts attempts to answer $kind $choice; last probe saw: $probe_json"
}

# ---------------------------------------------------------------------------
# fixture <name> [args...]
#
# Applies a named fixture before the app launches, by running
# harness/fixtures/<name>/apply.sh in the guest — run.sh's own
# copy_in_guest_tree already stages harness/fixtures/ into the guest
# alongside guest/ when the directory exists (app-fresh already has it at
# its real path; nothing to stage). U9 and U10 write the actual fixtures;
# this is only the mechanism, plus a clear refusal — checked on the host
# first — when a scenario names one that is not there.
fixture() {
    local name="${1:?fixture requires a name.}"
    shift || true
    local host_fixture="$HARNESS_DIR/fixtures/$name"
    if [ ! -f "$host_fixture/apply.sh" ]; then
        _scenario_harness_error "fixture: unknown fixture '$name' — no $host_fixture/apply.sh in this checkout."
    fi
    local cmd="bash $(_scenario_path_arg "$(_scenario_guest_path "fixtures/$name/apply.sh")")"
    local arg
    for arg in "$@"; do
        cmd="$cmd $(_scenario_quote "$arg")"
    done
    local rc=0
    if bounded_run "$HARNESS_STEP_TIMEOUT" guest_run "$HARNESS_GUEST_IP" "$cmd"; then rc=0; else rc=$?; fi
    if [ "$rc" -ne 0 ]; then
        _scenario_harness_error "fixture: '$name' failed in the guest (exit $rc)."
    fi
    log "fixture applied: $name"
}

# ---------------------------------------------------------------------------
# stage_asset
#
# Copies $HARNESS_ASSET into the guest (a no-op on the app-fresh tier,
# where the guest and the host are the same machine) and prints the
# guest-side path install_app should hand install.sh. Bounded by
# $HARNESS_STEP_TIMEOUT — a zip is the one thing here big enough that this
# matters (R14).
stage_asset() {
    if [ -z "${HARNESS_ASSET:-}" ]; then
        _scenario_harness_error "stage_asset: no --asset was given for this run."
    fi
    if [ "$HARNESS_GUEST_TRANSPORT" = "local" ]; then
        printf '%s\n' "$HARNESS_ASSET"
        return 0
    fi
    local base
    base="$(basename -- "$HARNESS_ASSET")"
    if ! bounded_run "$HARNESS_STEP_TIMEOUT" guest_copy_in "$HARNESS_GUEST_IP" "$HARNESS_ASSET" "$HARNESS_GUEST_HOME/$base"; then
        _scenario_harness_error "stage_asset: could not copy $HARNESS_ASSET into the guest."
    fi
    printf '~/%s/%s\n' "$HARNESS_GUEST_HOME" "$base"
}

# install_app <AgentMenu|MeetingHop>
#
# Stages $HARNESS_ASSET into the guest and runs guest/install.sh there —
# the stranger-tier install path KTD8 describes: unzip in Downloads with
# the quarantine attribute, move to Applications, open. Prints install.sh's
# own JSON result on stdout. install.sh's exit code is the real taxonomy
# (2 usage, 3 harness error), not the AppleScript one, so this branches on
# it directly rather than through _scenario_check_kind.
install_app() {
    local app_name="${1:?install_app requires AgentMenu or MeetingHop.}"
    case "$app_name" in
        AgentMenu|MeetingHop) ;;
        *) _scenario_harness_error "install_app: app must be AgentMenu or MeetingHop, got '$app_name'." ;;
    esac
    local guest_zip
    guest_zip="$(stage_asset)"
    local cmd="bash $(_scenario_path_arg "$(_scenario_guest_path guest/install.sh)")"
    cmd="$cmd --zip $(_scenario_path_arg "$guest_zip") --app $(_scenario_quote "$app_name") --json"
    local out rc=0
    if out="$(bounded_run "$HARNESS_STEP_TIMEOUT" guest_run "$HARNESS_GUEST_IP" "$cmd")"; then rc=0; else rc=$?; fi
    case "$rc" in
        0) ;;
        2) _scenario_harness_error "install_app: install.sh usage error for $app_name (exit 2) — a scenario bug." ;;
        *) _scenario_harness_error "install_app: install.sh could not install $app_name (exit $rc)." ;;
    esac
    printf '%s\n' "$out" | tail -n 1
}

# ---------------------------------------------------------------------------
# finding <code>
#
# Appends a finding code to $HARNESS_FINDINGS. Findings are orthogonal to
# verdict (KTD6): a scenario can pass and still carry one. Each code has to
# come from harness/findings.txt's checked-in list — a code plus a fixed
# message — never free text, because the redacted public report is built
# from the codes alone and nothing unreviewed may reach it. That file is
# U11's own deliverable and does not exist in this checkout yet; until it
# does, any code is accepted, because there is nothing yet to check it
# against. Once it exists, a code that is not listed in it is refused as a
# scenario bug (a harness error), not silently written. The match is
# lenient about the line's own separator (whitespace, a colon, ...) since
# U11's exact format is not fixed yet either — a code has to start the
# line and be followed by something that is not more of the same code.
finding() {
    local code="${1:?finding requires a code.}"
    local findings_list="$HARNESS_DIR/findings.txt"
    if [ -f "$findings_list" ] && ! grep -qE "^${code}([^A-Za-z0-9_.-]|\$)" "$findings_list"; then
        _scenario_harness_error "finding: '$code' is not a known finding code (see harness/findings.txt)."
    fi
    printf '%s\n' "$code" >> "$HARNESS_FINDINGS"
    log "finding: $code"
}

# ---------------------------------------------------------------------------
# verdict pass
# verdict fail <reason>
#
# The scenario's stated end state. `pass` closes whatever step is still
# open as "ok" and exits 0; `fail` ends the scenario exactly like any other
# helper failure — the open step recorded "fail" with the last screenshot —
# and exits 1. Nothing after either call ever runs.
verdict() {
    local outcome="${1:?verdict requires pass or fail.}"
    case "$outcome" in
        pass)
            _scenario_close_open_step
            log "verdict: pass"
            exit 0
            ;;
        fail)
            _scenario_end 1 "verdict fail: ${2:-no reason given}"
            ;;
        *)
            _scenario_harness_error "verdict: must be 'pass' or 'fail', got '$outcome'."
            ;;
    esac
}
