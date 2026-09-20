#!/bin/bash
# Hashes the maintainer's own state so the app-fresh tier can prove it never
# touched it (R3, AE8): the config/manifests root, the Claude Code
# directories, and AgentMenu's real defaults domain.
#
# THIS FILE IS APP-SPECIFIC (harness/SHARED.sha256, harness/README.md's
# "Shared files" section, excludes it by name alongside appfresh.sh): the
# domain name it defaults to is dev.facens.agentmenu. MeetingHop's own copy
# carries the same shape with dev.facens.meetinghop.
#
# Sourced, never executed, by harness/lib/appfresh.sh.
#
# ===== What gets hashed =====
#
#   config       $HARNESS_SNAPSHOT_HOME/.config/agentmenu/**       (config.toml
#                and the user manifests overlay — one root, per
#                ManifestRegistry.defaultUserRoot)
#   claude       $HARNESS_SNAPSHOT_HOME/.claude*  (files and directories —
#                wider than "directories": ~/.claude.json sits right next to
#                ~/.claude/ and is exactly the kind of file a misrouted
#                profile root would touch)
#   appsupport   $HARNESS_SNAPSHOT_HOME/Library/Application Support/<domain>
#                (bonus, beyond R3's literal list: the app's own real harness
#                directory, Journal.defaultDirectory's target — the place a
#                broken AGENTMENU_HARNESS_DIR override would surface)
#   domain       the live `defaults export <domain> -` reading
#
# Every file is two lines — label, path, size, mtime, "-" and label, path,
# "-", "-", content hash — so a rewrite that lands identical bytes still
# shows up via its mtime (decided: R3 says "never reads or writes", not
# "never changes bytes", and a real write syscall is the only thing that
# moves a regular file's mtime, unlike cfprefsd's own write-coalescing
# below). See _snapshot_tree's own header for why they are two lines, not
# one five-column line per file. A hash `shasum` could not compute is
# recorded as "unreadable" rather than skipped, so a permission problem on
# one path is visible without losing every other line.
#
# ===== The defaults domain, read stably =====
#
# `defaults export <domain> -` is the one stable read here: it is answered by
# cfprefsd from its live, in-memory state, not from the on-disk plist, which
# cfprefsd flushes on its own schedule. Verified by hand against a scratch
# domain (2026-09-18, this Mac): a `defaults write` was visible to
# `defaults read`/`export` immediately, before and after the on-disk file
# had a chance to reflect it, and two `defaults export -` calls back to back
# on an unmodified domain hashed identically — CFPropertyList's XML
# serialization is deterministic, not just typically stable. `defaults
# delete <domain>` was also confirmed to clear the keys but leave an empty
# plist file behind (harness/lib/appfresh.sh's teardown removes it
# directly). The on-disk plist's own size/mtime is therefore never part of
# the compared snapshot — a lazy flush of unchanged content would otherwise
# fail a clean run for no real reason.
#
# So: one "does this count as changed" decision, two different answers,
# both stated above rather than left for a reader to notice only in the
# code. A file's mtime only ever moves on a real write(2)/utimes(2), so it
# is compared; cfprefsd's own on-disk flush timing is unrelated to whether
# a write was accepted, so the plist's mtime is not.
set -euo pipefail

if [ -n "${HARNESS_SNAPSHOT_SH:-}" ]; then
    return 0
fi
HARNESS_SNAPSHOT_SH=1

. "$(dirname "${BASH_SOURCE[0]}")/common.sh"

_snapshot_home() { printf '%s' "${HARNESS_SNAPSHOT_HOME:-$HOME}"; }
_snapshot_domain_name() { printf '%s' "${HARNESS_SNAPSHOT_DOMAIN:-dev.facens.agentmenu}"; }

# Every file is two TSV lines, not one: a "meta" row (label, path, size,
# mtime, "-") and a "hash" row (label, path, "-", "-", sha256). Kept
# separate — never joined into one 5-column row per file — so the batched,
# whole-directory passes in _snapshot_tree never have to match a stat line
# to a shasum line by path text, which would need care around spaces.
# Splitting costs nothing a comparison cares about: a genuine content
# change shows up as a differing hash row, an identical-content rewrite
# still shows up as a differing meta row (R3 says "never writes", not
# "never changes bytes" — this unit's own decision, see this file's
# header), and either signal is exactly as attributable to its own path
# either way. `-1` for a size or mtime `stat` could not read, `unreadable`
# for a hash `shasum` could not compute — the row is still emitted rather
# than dropped.
_snapshot_meta_row() {
    local label="$1" path="$2" size mtime
    size="$(stat -f '%z' "$path" 2>/dev/null || echo -1)"
    mtime="$(stat -f '%m' "$path" 2>/dev/null || echo -1)"
    printf '%s\t%s\t%s\t%s\t-\n' "$label" "$path" "$size" "$mtime"
}

_snapshot_hash_row() {
    local label="$1" path="$2" hash
    hash="$(shasum -a 256 "$path" 2>/dev/null | awk '{print $1}' || true)"
    printf '%s\t%s\t-\t-\t%s\n' "$label" "$path" "${hash:-unreadable}"
}

_snapshot_hash_file() {
    local label="$1" path="$2"
    _snapshot_meta_row "$label" "$path"
    _snapshot_hash_row "$label" "$path"
}

# A file, a directory walked recursively, or nothing at all when `root`
# does not exist — a missing root is a valid state (a maintainer who has
# never run AgentMenu has no ~/.config/agentmenu yet), not a harness error.
#
# The directory case is batched: `find … -exec CMD {} +` hands each command
# as many paths as fit on one command line and repeats only as many times
# as ARG_MAX forces, instead of forking stat/stat/shasum/awk once per file.
# Measured by hand against this Mac's real ~/.claude and ~/.claude-personal
# (2026-09-18, ~62,300 files, this unit's own "claude" root): a
# one-process-per-file loop did not finish inside appfresh.sh's 120-second
# teardown bound at all; the batched metadata pass took about 5 seconds and
# the batched content-hash pass about 45, a full snapshot_take around 25s
# warm end to end. That gap — not tidiness — is why this is two
# `find -exec` pipelines instead of one `find | while read` loop.
#
# Fast enough is not the same as quiet: this Mac's ~/.claude-personal is
# where Claude Code itself is writing project and tool-result files as it
# runs, so a scenario driven by Claude Code can genuinely change that tree
# during the run's own before/after window, with the app never at fault.
# This file guesses nothing: a wrong guess about which subpaths are "safe"
# is exactly the kind of hole R3 exists to close, so by default that case
# still compares as changed, appfresh_teardown still writes
# watchdog-appfresh-snapshot.fired, and the run still reports
# harness_error. The diff is what tells the two apart.
#
# HARNESS_SNAPSHOT_EXCLUDE exists for the one case where the maintainer
# knows better: a colon-separated list of shell glob patterns, empty by
# default, matched against each absolute path. Nothing is dropped quietly —
# every pattern is written into the snapshot as an `excluded` line, so the
# manifest itself records which part of R3 was not checked and a report
# built from it can say so. Exclude the narrowest path that covers the
# churn, never a whole root: `~/.claude-personal` is a profile directory
# the app may legitimately write to, and excluding it would hide exactly
# the escape this check exists to catch.
# Whether a path is one the maintainer told this run not to check. Patterns
# are globs, so a trailing /* covers a subtree and a bare path covers one
# file.
_snapshot_excluded() {
    local path="$1" rest="${HARNESS_SNAPSHOT_EXCLUDE:-}" pattern
    [ -n "$rest" ] || return 1
    while [ -n "$rest" ]; do
        case "$rest" in
            *:*) pattern="${rest%%:*}"; rest="${rest#*:}" ;;
            *) pattern="$rest"; rest="" ;;
        esac
        [ -n "$pattern" ] || continue
        # shellcheck disable=SC2254 -- the pattern is meant to glob.
        case "$path" in
            $pattern) return 0 ;;
        esac
    done
    return 1
}

# The patterns themselves, recorded in the manifest so a snapshot is honest
# about what it did not look at.
_snapshot_exclusions() {
    local rest="${HARNESS_SNAPSHOT_EXCLUDE:-}" pattern
    while [ -n "$rest" ]; do
        case "$rest" in
            *:*) pattern="${rest%%:*}"; rest="${rest#*:}" ;;
            *) pattern="$rest"; rest="" ;;
        esac
        [ -n "$pattern" ] || continue
        printf 'excluded\t%s\t-\t-\t-\n' "$pattern"
    done
    return 0
}

_snapshot_tree() {
    local label="$1" root="$2"
    [ -e "$root" ] || return 0
    if [ -f "$root" ]; then
        _snapshot_excluded "$root" && return 0
        _snapshot_hash_file "$label" "$root"
        return 0
    fi
    [ -d "$root" ] || return 0

    local path size mtime line
    find "$root" -type f ! -name '.DS_Store' -exec stat -f $'%N\t%z\t%m' {} + 2>/dev/null \
        | while IFS=$'\t' read -r path size mtime; do
            _snapshot_excluded "$path" && continue
            printf '%s\t%s\t%s\t%s\t-\n' "$label" "$path" "$size" "$mtime"
        done
    # shasum's own text-mode format is "<hash>␠␠<path>" (verified by hand:
    # exactly two spaces, never one) — split on that rather than on
    # whitespace generally, which a path carrying a literal space would
    # break.
    find "$root" -type f ! -name '.DS_Store' -exec shasum -a 256 {} + 2>/dev/null \
        | while IFS= read -r line; do
            _snapshot_excluded "${line#*  }" && continue
            printf '%s\t%s\t-\t-\t%s\n' "$label" "${line#*  }" "${line%%  *}"
        done
    return 0
}

# Every ~/.claude* entry, file or directory — see this file's header for why
# "directories" alone is not enough.
_snapshot_claude_paths() {
    local home="$1" entry
    for entry in "$home"/.claude*; do
        [ -e "$entry" ] || continue
        _snapshot_tree "claude" "$entry"
    done
    return 0
}

_snapshot_domain_hash() {
    local domain="$1" hash
    hash="$(defaults export "$domain" - 2>/dev/null | shasum -a 256 | awk '{print $1}' || true)"
    printf 'domain\t%s\t-\t-\t%s\n' "$domain" "${hash:-unreadable}"
}

# snapshot_take <output-file>
#
# Writes a sorted, deterministic manifest to <output-file>. Sorted so two
# snapshots taken with directory entries walked in a different order still
# compare equal when nothing actually changed.
snapshot_take() {
    local out="${1:?snapshot_take requires an output file path.}"
    local home domain tmp
    home="$(_snapshot_home)"
    domain="$(_snapshot_domain_name)"
    tmp="${out}.tmp.$$"

    if ! {
        _snapshot_exclusions
        _snapshot_tree "config" "$home/.config/agentmenu"
        _snapshot_claude_paths "$home"
        _snapshot_tree "appsupport" "$home/Library/Application Support/$domain"
        _snapshot_domain_hash "$domain"
    } > "$tmp" 2>/dev/null; then
        warn "snapshot: could not write $tmp."
        rm -f "$tmp"
        return 1
    fi
    if ! LC_ALL=C sort -o "$tmp" "$tmp"; then
        warn "snapshot: could not sort $tmp."
        rm -f "$tmp"
        return 1
    fi
    if ! mv -f "$tmp" "$out"; then
        warn "snapshot: could not move $tmp into place at $out."
        return 1
    fi
    return 0
}

# snapshot_compare <before-file> <after-file>
#
# True when the two snapshots are identical.
snapshot_compare() {
    local before="$1" after="$2"
    diff -q "$before" "$after" > /dev/null 2>&1
}

# snapshot_diff <before-file> <after-file>
#
# The differing lines, unified-diff style — each line names its own label
# and path, so a mismatch is attributable without re-reading the snapshot
# files by hand. Never fails: a caller that already knows the snapshots
# differ wants the text, not another exit code to check.
snapshot_diff() {
    diff -u "$1" "$2" 2>&1 || true
}
