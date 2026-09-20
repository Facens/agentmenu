#!/bin/bash
# The version grammar, shared by packaging/bundle.sh and the release workflow.
# Sourced, never executed: each function prints its answer on stdout and, for
# anything outside the grammar, says why on stderr and returns 1.
#
# One version string carries three release channels (R20, KTD10):
#
#   form              channel   CFBundleVersion   where it comes from
#   X.Y.Z             stable    X.Y.Z.100         tag vX.Y.Z; Sparkle's default channel
#   X.Y.Z-beta.N      beta      X.Y.Z.N           tag vX.Y.Z-beta.N, N in 1..99; Sparkle channel "beta"
#   X.Y.Z-alpha       alpha     X.Y.Z.0           local `make bundle` only; never tagged, never updated
#
# CFBundleShortVersionString is the string as written, for people to read.
# CFBundleVersion is what Sparkle orders updates by, and its comparator stops
# reading at the first "-" (SUStandardVersionComparator), so 0.2.0-beta.1 and
# 0.2.0 would tie and a beta install could never be offered the final. The
# fourth component breaks the tie, and its bounds keep the sequence monotonic:
# the alpha of a version sits below every beta of it, and every beta sits
# below the final. Across versions the first three components order as before.

version_channel() {
    local version="$1"
    if [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo stable
    elif [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-beta\.[1-9][0-9]?$ ]]; then
        echo beta
    elif [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+-alpha$ ]]; then
        echo alpha
    else
        echo "error: VERSION must be MAJOR.MINOR.PATCH, MAJOR.MINOR.PATCH-beta.N (N 1-99) or MAJOR.MINOR.PATCH-alpha, digits only (got '$version')" >&2
        return 1
    fi
}

version_build() {
    local version="$1" channel base
    channel="$(version_channel "$version")" || return 1
    base="${version%%-*}"
    case "$channel" in
        stable) echo "$base.100" ;;
        beta)   echo "$base.${version##*-beta.}" ;;
        alpha)  echo "$base.0" ;;
    esac
}
