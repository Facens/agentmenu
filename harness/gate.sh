#!/bin/bash
# The release gate: runs the whole scenario set against a draft release's
# exact asset, attaches a redacted report, and stops. A maintainer publishes
# with a second command, after reviewing the screenshots this points at
# (KTD7).
#
#   harness/gate.sh run --app <agentmenu|meetinghop> --tag vX.Y.Z \
#                       --repo <owner>/<name> (--scenarios a,b,c | --scenarios-file <path>)
#   harness/gate.sh publish --tag vX.Y.Z --repo <owner>/<name>
#
# `run` refuses (exit 2) unless `--tag` names a draft release in `--repo`;
# downloads its zip and `.sha256`; refuses (exit 3) if the hash does not
# match; runs every named scenario on the stranger tier under one nonce,
# serially (the host allows at most two guests, and `run.sh` itself refuses
# a third); folds the results with `harness/lib/report.sh fold`; refuses
# (exit 3) a fold that is not nonce-matched, asset-matched and complete, one
# whose scenario list is not exactly what `--scenarios`/`--scenarios-file`
# named, or one produced under the verbose flag; on pass, builds
# report.public.json and uploads it to the release, and never publishes it.
# Any refusal from the first draft/hash checks never calls `gh release
# edit`; any refusal after a scenario has actually run writes a note into
# the draft's body, through `--notes-file`, naming the run id and nothing
# else — never a journal line, never an error message that could carry a
# path or a title.
#
# `publish` re-downloads the draft's current `.sha256`, looks for a local,
# complete, nonce-matched report for `--tag` keyed by that exact digest
# (`$HARNESS_DIST_ROOT/gate/<tag>/<sha256>/`), refuses (exit 3) if none
# exists or the digest has moved since the run that produced it, prints
# where its screenshots are for review, and runs
# `gh release edit --draft=false`. It never re-runs a scenario.
#
# `--scenarios`/`--scenarios-file` name the exact scenario set a passing
# gate must cover — this script assumes nothing about which scenarios an
# app has; the caller states it every time, because a report that silently
# covers fewer scenarios than the app ships is exactly the failure mode
# this gate exists to catch. `--scenarios-file` is a plain text file, one
# scenario name per line, '#' comments and blank lines ignored — the same
# convention as harness/findings.txt.
#
# Token: both commands read a fine-grained GitHub token scoped to the one
# repository (contents: write) from the login keychain — never the ambient
# `gh` session. One command puts it there, run once per repository:
#
#   security add-generic-password -a "<owner>/<name>" -s harness-gate-token -U -w
#
# (`-w` last is `security`'s own contract for being prompted rather than
# taking the secret as an argument; `-U` replaces an existing entry rather
# than refusing a duplicate). Every `gh` call in this script runs with
# `GH_TOKEN` set from that entry and `GH_CONFIG_DIR` pointed at a scratch
# directory made and removed within the one command, so the maintainer's own
# `gh auth login` session is never read or touched. Release text always goes
# through `--notes-file`, never `--notes` with anything this script computed.
#
# Environment:
#
#   HARNESS_DIST_ROOT  where run directories and gate reports live
#                       (default dist/harness, same as run.sh)
#   HARNESS_RUN_SH      the run.sh this gate drives (default harness/run.sh;
#                       a test points this at a stub)
#
# Exit codes, the same taxonomy as everywhere else under harness/: 0 pass,
# 1 scenario fail (a scenario in the set genuinely did not reach its end
# state, with everything else in order), 2 usage error (bad arguments, no
# draft release, no keychain token), 3 harness error (a hash mismatch, a
# nonce mismatch, incomplete scenario coverage, a verbose run, or anything
# `gh` itself could not do).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS_DIR="$ROOT/harness"

. "$HARNESS_DIR/lib/common.sh"

DIST_ROOT="${HARNESS_DIST_ROOT:-$ROOT/dist/harness}"
RUN_SH="${HARNESS_RUN_SH:-$HARNESS_DIR/run.sh}"
REPORT_SH="$HARNESS_DIR/lib/report.sh"
GATE_TOKEN_SERVICE="harness-gate-token"

usage() {
    sed -n '2,66p' "$0" | sed 's/^# \{0,1\}//'
}

# ---------------------------------------------------------------------------
# The keychain token and an isolated `gh`.

gate_read_token() {
    local repo="$1"
    security find-generic-password -a "$repo" -s "$GATE_TOKEN_SERVICE" -w 2>/dev/null || true
}

# Exported once per command, by the caller, after the token is confirmed
# present — never logged, never interpolated into a message.
gate_authorize() {
    local repo="$1" token
    token="$(gate_read_token "$repo")"
    if [ -z "$token" ]; then
        echo "error: no fine-grained token for '$repo' in the login keychain." >&2
        echo "Run once: security add-generic-password -a \"$repo\" -s \"$GATE_TOKEN_SERVICE\" -U -w" >&2
        exit 2
    fi
    local scratch
    scratch="$(mktemp -d "${TMPDIR:-/tmp}/harness-gate-gh.XXXXXX")"
    GATE_GH_SCRATCH="$scratch"
    export GH_TOKEN="$token"
    export GH_CONFIG_DIR="$scratch"
}

gate_deauthorize() {
    if [ -n "${GATE_GH_SCRATCH:-}" ]; then
        rm -rf "$GATE_GH_SCRATCH"
    fi
}

# Writes a note into the draft's body naming the run id only — never a
# journal line, a path or a scenario's own failure text — through
# --notes-file, per this file's own header. Best-effort: a note that could
# not be written does not change the exit code this refusal already carries.
gate_note_failure() {
    local tag="$1" repo="$2" run_id="$3" notes
    notes="$(mktemp "${TMPDIR:-/tmp}/harness-gate-notes.XXXXXX")"
    printf 'harness gate run %s did not pass. See that run'\''s own report for detail; nothing else about it is written here.\n' "$run_id" > "$notes"
    gh release edit "$tag" --repo "$repo" --notes-file "$notes" \
        || warn "could not write the failure note into the draft body for '$tag'."
    rm -f "$notes"
}

# ---------------------------------------------------------------------------
# The scenario list: --scenarios (comma-separated) and/or --scenarios-file
# (one name per line, '#' comments, blank lines ignored — findings.txt's own
# convention). At least one of the two is required; both may be given and
# are concatenated.

gate_read_scenarios() {
    local csv="$1" file="$2"
    local -a out=()
    if [ -n "$file" ]; then
        [ -f "$file" ] || die 2 "the scenarios file '$file' does not exist."
        local line stripped
        while IFS= read -r line || [ -n "$line" ]; do
            stripped="${line%%#*}"
            stripped="$(printf '%s' "$stripped" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            [ -n "$stripped" ] && out+=("$stripped")
        done < "$file"
    fi
    if [ -n "$csv" ]; then
        local piece oldifs="$IFS"
        IFS=','
        for piece in $csv; do
            piece="$(printf '%s' "$piece" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            [ -n "$piece" ] && out+=("$piece")
        done
        IFS="$oldifs"
    fi
    # Bash 3.2 (macOS's /bin/bash) treats expanding an empty array under
    # `set -u` as an unbound-variable error, not an empty list — verified by
    # hand — so an empty result is printed as nothing rather than expanded.
    if [ "${#out[@]}" -gt 0 ]; then
        printf '%s\n' "${out[@]}"
    fi
}

# ---------------------------------------------------------------------------
# run

cmd_run() {
    local app="" tag="" repo="" scenarios_csv="" scenarios_file=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --app|--tag|--repo|--scenarios|--scenarios-file)
                if [ $# -lt 2 ]; then die 2 "$1 needs a value."; fi
                case "$1" in
                    --app) app="$2" ;;
                    --tag) tag="$2" ;;
                    --repo) repo="$2" ;;
                    --scenarios) scenarios_csv="$2" ;;
                    --scenarios-file) scenarios_file="$2" ;;
                esac
                shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) echo "error: unknown argument: $1." >&2; exit 2 ;;
        esac
    done

    case "$app" in
        agentmenu|meetinghop) ;;
        "") die 2 "--app is required; it is agentmenu or meetinghop." ;;
        *) die 2 "unknown app '$app'; it is agentmenu or meetinghop." ;;
    esac
    [ -n "$tag" ] || die 2 "--tag is required, e.g. v0.1.1."
    case "$repo" in
        */*) ;;
        "") die 2 "--repo is required, e.g. Facens/agentmenu." ;;
        *) die 2 "--repo must be 'owner/name', got '$repo'." ;;
    esac
    if [ -z "$scenarios_csv" ] && [ -z "$scenarios_file" ]; then
        die 2 "--scenarios or --scenarios-file is required; name the exact scenario set this gate must cover."
    fi

    require_cmd gh jq shasum security
    [ -x "$RUN_SH" ] || die 3 "'$RUN_SH' is not executable; the gate needs run.sh to drive scenarios."
    [ -f "$REPORT_SH" ] || die 3 "'$REPORT_SH' is missing."

    local -a scenarios=()
    while IFS= read -r s; do
        [ -n "$s" ] && scenarios+=("$s")
    done < <(gate_read_scenarios "$scenarios_csv" "$scenarios_file")
    [ "${#scenarios[@]}" -gt 0 ] || die 2 "the scenario list is empty."

    gate_authorize "$repo"
    trap gate_deauthorize EXIT

    log "checking that $repo's $tag is a draft release"
    local is_draft
    if ! is_draft="$(gh release view "$tag" --repo "$repo" --json isDraft --jq '.isDraft' 2>/dev/null)"; then
        echo "error: could not read the release '$tag' in '$repo' — it may not exist, or the token cannot see it." >&2
        exit 2
    fi
    if [ "$is_draft" != "true" ]; then
        echo "error: the release '$tag' in '$repo' is not a draft; the gate only ever runs against a draft release." >&2
        exit 2
    fi

    local asset_names zip_name sha_name
    asset_names="$(gh release view "$tag" --repo "$repo" --json assets --jq '.assets[].name')" \
        || die 3 "could not list the assets on '$tag'."
    zip_name="$(printf '%s\n' "$asset_names" | grep -E '\.zip$' | head -n 1 || true)"
    sha_name="$(printf '%s\n' "$asset_names" | grep -E '\.sha256$' | head -n 1 || true)"
    if [ -z "$zip_name" ] || [ -z "$sha_name" ]; then
        die 3 "the draft '$tag' does not carry both a .zip and a .sha256 asset."
    fi

    local dl_dir
    dl_dir="$(mktemp -d "${TMPDIR:-/tmp}/harness-gate-asset.XXXXXX")"
    if ! gh release download "$tag" --repo "$repo" --dir "$dl_dir" \
            --pattern "$zip_name" --pattern "$sha_name" --clobber; then
        die 3 "could not download '$zip_name'/'$sha_name' from '$tag'."
    fi

    log "verifying the downloaded asset's hash"
    if ! ( cd "$dl_dir" && shasum -a 256 -c "$sha_name" > /dev/null ); then
        echo "error: '$zip_name' does not match the hash in '$sha_name'; refusing to run the gate against it." >&2
        exit 3
    fi
    local asset_sha256
    asset_sha256="$(awk '{print $1}' "$dl_dir/$sha_name" | tr 'A-F' 'a-f')"

    local nonce
    nonce="$(rand_hex 16)"
    log "running ${#scenarios[@]} scenario(s) against $zip_name under nonce $nonce"

    local -a run_dirs=()
    local s run_id
    for s in "${scenarios[@]}"; do
        log "start: $s"
        if ! run_id="$("$RUN_SH" start --app "$app" --tier stranger --scenario "$s" \
                --asset "$dl_dir/$zip_name" --nonce "$nonce")"; then
            die 3 "run.sh start failed for scenario '$s' — nothing ran yet, so no note was written."
        fi
        log "wait: $run_id"
        "$RUN_SH" wait "$run_id" || true
        run_dirs+=("$DIST_ROOT/$run_id")
    done

    local gate_dir="$DIST_ROOT/gate/$tag/$asset_sha256"
    mkdir -p "$gate_dir"
    local report_path="$gate_dir/report.json"

    local -a fold_args=(--out "$report_path" --tag "$tag" --app "$app" --nonce "$nonce"
        --asset-sha256 "$asset_sha256" --preview false)
    local d
    for d in "${run_dirs[@]}"; do fold_args+=(--run-dir "$d"); done

    local fold_rc=0
    "$REPORT_SH" fold "${fold_args[@]}" || fold_rc=$?

    local run_id_for_note
    run_id_for_note="$(jq -r '.run_id // "unknown"' "$report_path" 2>/dev/null || echo unknown)"

    if [ "$fold_rc" -ne 0 ]; then
        gate_note_failure "$tag" "$repo" "$run_id_for_note"
        echo "error: the gate did not pass — see $report_path." >&2
        exit "$fold_rc"
    fi

    # Exact scenario coverage and the verbose flag are gate.sh's own to
    # judge — report.sh fold already refused on nonce, asset and
    # completeness (see its own header for why it stops there).
    local got_scenarios want_sorted
    got_scenarios="$(jq -r '[.scenarios[].name] | sort | .[]' "$report_path")"
    want_sorted="$(printf '%s\n' "${scenarios[@]}" | sort)"
    if [ "$got_scenarios" != "$want_sorted" ]; then
        local missing
        missing="$(comm -23 <(printf '%s\n' "$want_sorted") <(printf '%s\n' "$got_scenarios") | tr '\n' ' ')"
        gate_note_failure "$tag" "$repo" "$run_id_for_note"
        echo "error: the compiled report is missing scenario(s): ${missing% }." >&2
        exit 3
    fi
    if [ "$(jq -r '.verbose' "$report_path")" = "true" ]; then
        gate_note_failure "$tag" "$repo" "$run_id_for_note"
        echo "error: this run's journal was produced under the verbose flag; the gate refuses to publish a report built from it." >&2
        exit 3
    fi

    local public_path="$gate_dir/report.public.json"
    if ! "$REPORT_SH" public --report "$report_path" --out "$public_path"; then
        gate_note_failure "$tag" "$repo" "$run_id_for_note"
        die 3 "could not build report.public.json from $report_path."
    fi

    if ! gh release upload "$tag" "$public_path" --repo "$repo" --clobber; then
        gate_note_failure "$tag" "$repo" "$run_id_for_note"
        die 3 "could not upload report.public.json to '$tag'."
    fi

    log "gate run passed: $report_path"
    printf '%s\n' "$report_path"
}

# ---------------------------------------------------------------------------
# publish

cmd_publish() {
    local tag="" repo=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --tag|--repo)
                if [ $# -lt 2 ]; then die 2 "$1 needs a value."; fi
                case "$1" in
                    --tag) tag="$2" ;;
                    --repo) repo="$2" ;;
                esac
                shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) echo "error: unknown argument: $1." >&2; exit 2 ;;
        esac
    done
    [ -n "$tag" ] || die 2 "--tag is required."
    case "$repo" in
        */*) ;;
        "") die 2 "--repo is required, e.g. Facens/agentmenu." ;;
        *) die 2 "--repo must be 'owner/name', got '$repo'." ;;
    esac

    require_cmd gh jq security

    gate_authorize "$repo"
    trap gate_deauthorize EXIT

    local is_draft
    if ! is_draft="$(gh release view "$tag" --repo "$repo" --json isDraft --jq '.isDraft' 2>/dev/null)"; then
        die 2 "could not read the release '$tag' in '$repo'."
    fi
    if [ "$is_draft" != "true" ]; then
        die 2 "'$tag' in '$repo' is not a draft; there is nothing to publish."
    fi

    local asset_names sha_name
    asset_names="$(gh release view "$tag" --repo "$repo" --json assets --jq '.assets[].name')" \
        || die 3 "could not list the assets on '$tag'."
    sha_name="$(printf '%s\n' "$asset_names" | grep -E '\.sha256$' | head -n 1 || true)"
    [ -n "$sha_name" ] || die 3 "'$tag' carries no .sha256 asset."

    local dl_dir
    dl_dir="$(mktemp -d "${TMPDIR:-/tmp}/harness-gate-publish.XXXXXX")"
    gh release download "$tag" --repo "$repo" --dir "$dl_dir" --pattern "$sha_name" --clobber \
        || die 3 "could not download '$sha_name' from '$tag'."
    local current_sha256
    current_sha256="$(awk '{print $1}' "$dl_dir/$sha_name" | tr 'A-F' 'a-f')"

    local gate_dir="$DIST_ROOT/gate/$tag/$current_sha256"
    local report_path="$gate_dir/report.json"
    if [ ! -f "$report_path" ]; then
        echo "error: no local report for '$tag' matches the draft's current asset digest $current_sha256." >&2
        echo "Run 'harness/gate.sh run --app <app> --tag $tag --repo $repo …' against this exact asset first." >&2
        exit 3
    fi

    local complete verdict nonce
    complete="$(jq -r '.complete' "$report_path")"
    verdict="$(jq -r '.verdict' "$report_path")"
    nonce="$(jq -r '.nonce // empty' "$report_path")"
    if [ "$complete" != "true" ] || [ "$verdict" != "pass" ] || [ -z "$nonce" ]; then
        echo "error: the local report for '$tag' at $current_sha256 is not a complete, nonce-matched, passing run." >&2
        exit 3
    fi

    log "screenshots for review:"
    jq -r '.screenshots[] | "  \(.scenario): \(.dir)"' "$report_path"

    if ! gh release edit "$tag" --repo "$repo" --draft=false; then
        die 3 "could not publish '$tag' in '$repo'."
    fi
    log "published $tag in $repo"
}

# ---------------------------------------------------------------------------

COMMAND="${1:-}"
if [ $# -gt 0 ]; then
    shift
fi
case "$COMMAND" in
    run)     cmd_run "$@" ;;
    publish) cmd_publish "$@" ;;
    -h|--help) usage; exit 0 ;;
    "")        usage >&2; exit 2 ;;
    *)         echo "unknown argument: $COMMAND" >&2; exit 2 ;;
esac
