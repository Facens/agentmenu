#!/bin/bash
# The report compiler: folds one or more run directories' own report.json
# and journal.ndjson into a gate-level report.json, and builds the redacted
# report.public.json a release carries.
#
#   harness/lib/report.sh compile --run-dir <dir> [--out <path>]
#   harness/lib/report.sh fold --out <path> --run-dir <dir> [--run-dir <dir>]...
#                               [--tag <tag>] [--app <app>] [--nonce <hex>]
#                               [--asset-sha256 <hash>] [--preview true|false]
#                               [--findings-file <path>]
#   harness/lib/report.sh public --report <path> --out <path>
#                                [--findings-file <path>]
#   harness/lib/report.sh decide --report <path>
#
# WHAT THIS DOES NOT DO: it never recomputes a single run's own verdict.
# `harness/run.sh`'s supervisor is the one process that ever holds the
# scenario's real exit code, and its own `finalize()` already writes
# `verdict`, `outcome_kind`, `steps[]` and `findings[]` into that run's
# report.json before this file is ever consulted — see lib/common.sh's own
# note on why the `run_report_*` and `report_*` namespaces are kept apart.
# `compile` and `fold` treat a run's report.json as authoritative for those
# fields and add exactly two things no single run's own report can assert
# about itself: that the app's own journal, not just `run.sh`'s bookkeeping,
# echoes the same run nonce (`nonce_ok`), and whether that run's fixture
# echo (the journal's first line, "harness started") was produced under
# `--verbose` — plus, at `fold` time, whether a *set* of runs together cover
# what a gate promised (exact scenario coverage is `harness/gate.sh`'s own
# job, once it can see this compiled report — see that file).
#
# `decide` is the "report-only decidability" contract: given *only* a
# compiled report.json (or a report.public.json, which carries a subset of
# the same two fields), it reproduces the verdict without opening a
# screenshot or a journal.
#
# Usable two ways, deliberately: sourced (it defines `report_*` and
# `_report_*` functions and returns 0, exactly like lib/common.sh), for a
# caller that wants the functions directly, or executed, as the small CLI
# above — `harness/gate.sh` uses it the second way, as an ordinary
# subprocess, specifically so a `fold`/`public` call that ends in `exit`
# never tears down the calling script.
#
# Exit codes, from the CLI: 0 pass, 1 scenario fail, 2 usage error, 3
# harness error (matches harness/README.md's taxonomy everywhere else under
# harness/). `compile` and `fold` mirror the verdict they compute; `decide`
# mirrors the verdict already in the report it read; `public` is a build
# step and exits 3 on any redaction failure, 0 on success.
#
# THIS FILE IS SHARED (harness/SHARED.sha256, harness/README.md's "Shared
# files" section): byte identical in both repositories, once the manifest
# that lists it is regenerated (out of this unit's scope — see the unit's
# own report). It carries no app-specific knowledge — no bundle id, no
# scenario name, no finding code — only the shape every run's report.json
# and journal.ndjson already share.
set -euo pipefail

if [ "${BASH_SOURCE[0]}" != "${0}" ]; then
    if [ -n "${HARNESS_REPORT_SH:-}" ]; then
        return 0
    fi
    HARNESS_REPORT_SH=1
fi

REPORT_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$REPORT_LIB_DIR/common.sh"

# The default location of the checked-in finding list, next to this file's
# own harness/lib/ — harness/findings.txt in both repositories. Overridable
# so a test never has to seed the real one.
_report_default_findings_file() {
    printf '%s/../findings.txt' "$REPORT_LIB_DIR"
}

# ---------------------------------------------------------------------------
# Reading one run.

# Prints one run directory's derived JSON object. Trusts that run's own
# report.json for `verdict`/`outcome_kind`/`findings` (see this file's
# header); computes `nonce_ok` by comparing it against the journal's own
# first line, and `verbose` by reading that same line's fixture echo.
_report_read_run() {
    local dir="$1" report journal
    report="$dir/report.json"
    journal="$dir/journal.ndjson"
    if [ ! -f "$report" ]; then
        die 3 "no report.json in $dir; that run never produced one."
    fi

    local scenario run_id verdict outcome status exit_code findings_json image_json nonce asset_sha256
    scenario="$(jq -r '.scenario // empty' "$report")"
    run_id="$(jq -r '.run_id // empty' "$report")"
    verdict="$(jq -r '.verdict // empty' "$report")"
    outcome="$(jq -r '.outcome_kind // empty' "$report")"
    status="$(jq -r '.status // empty' "$report")"
    exit_code="$(jq -r '.exit_code // empty' "$report")"
    findings_json="$(jq -c '.findings // []' "$report")"
    nonce="$(jq -r '.nonce // empty' "$report")"
    asset_sha256="$(jq -r '.asset_sha256 // empty' "$report")"
    image_json="$(jq -c '.image // null' "$report")"

    local journal_nonce="" verbose="false"
    if [ -s "$journal" ]; then
        journal_nonce="$(head -n 1 "$journal" | jq -r '.nonce // empty' 2>/dev/null || true)"
        verbose="$(head -n 1 "$journal" | jq -r '(.data.verbose // false) | tostring' 2>/dev/null || echo false)"
    fi

    local nonce_ok=true
    if [ -z "$nonce" ] || [ -z "$journal_nonce" ] || [ "$journal_nonce" != "$nonce" ]; then
        nonce_ok=false
    fi

    local complete=true
    if [ "$status" != "finished" ] || [ -z "$exit_code" ]; then
        complete=false
    fi

    jq -n \
        --arg scenario "$scenario" --arg run_id "$run_id" --arg run_dir "$dir" \
        --arg verdict "$verdict" --arg outcome "$outcome" --argjson findings "$findings_json" \
        --arg nonce "$nonce" --argjson nonce_ok "$nonce_ok" --arg asset_sha256 "$asset_sha256" \
        --argjson image "$image_json" --argjson verbose "$verbose" --argjson complete "$complete" \
        --arg screenshots_dir "$dir/screenshots" \
        '{
            scenario: $scenario,
            run_id: $run_id,
            run_dir: $run_dir,
            verdict: (if $verdict == "" then null else $verdict end),
            outcome_kind: (if $outcome == "" then null else $outcome end),
            findings: $findings,
            nonce: (if $nonce == "" then null else $nonce end),
            nonce_ok: $nonce_ok,
            asset_sha256: (if $asset_sha256 == "" then null else $asset_sha256 end),
            image: $image,
            verbose: $verbose,
            complete: $complete,
            screenshots_dir: $screenshots_dir
        }'
}

# The exit code a single compiled run mirrors: any harness-level doubt
# (nonce mismatch, an unfinished run, no outcome at all, or the run's own
# outcome_kind already saying harness_error) always wins over the run's own
# verdict — a scenario fail is only ever reported once the harness is sure
# it really was one.
_report_exit_for_run() {
    local obj="$1" nonce_ok complete outcome verdict
    nonce_ok="$(printf '%s' "$obj" | jq -r '.nonce_ok')"
    complete="$(printf '%s' "$obj" | jq -r '.complete')"
    outcome="$(printf '%s' "$obj" | jq -r '.outcome_kind // empty')"
    verdict="$(printf '%s' "$obj" | jq -r '.verdict // empty')"
    if [ "$nonce_ok" != "true" ] || [ "$complete" != "true" ] || [ "$outcome" = "harness_error" ] || [ -z "$outcome" ]; then
        echo 3
        return
    fi
    case "$verdict" in
        pass) echo 0 ;;
        fail) echo 1 ;;
        *) echo 3 ;;
    esac
}

# ---------------------------------------------------------------------------
# compile --run-dir <dir> [--out <path>]

cmd_report_compile() {
    local run_dir="" out=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --run-dir) run_dir="${2:?--run-dir needs a value.}"; shift 2 ;;
            --out) out="${2:?--out needs a value.}"; shift 2 ;;
            -h|--help) report_usage; exit 0 ;;
            *) echo "error: unknown argument: $1." >&2; exit 2 ;;
        esac
    done
    [ -n "$run_dir" ] || die 2 "compile requires --run-dir."
    [ -d "$run_dir" ] || die 2 "'$run_dir' is not a directory."

    local obj
    obj="$(_report_read_run "$run_dir")"
    if [ -n "$out" ]; then
        mkdir -p "$(dirname "$out")"
        printf '%s\n' "$obj" | jq '.' > "$out"
    else
        printf '%s\n' "$obj"
    fi
    exit "$(_report_exit_for_run "$obj")"
}

# ---------------------------------------------------------------------------
# fold --out <path> --run-dir <dir> [--run-dir <dir>]... [--tag] [--app]
#      [--nonce] [--asset-sha256] [--preview true|false] [--findings-file]

cmd_report_fold() {
    local out="" tag="unknown" app="unknown" want_nonce="" want_asset="" preview="false" findings_file=""
    local run_dirs=()
    while [ $# -gt 0 ]; do
        case "$1" in
            --out) out="${2:?--out needs a value.}"; shift 2 ;;
            --run-dir) run_dirs+=("${2:?--run-dir needs a value.}"); shift 2 ;;
            --tag) tag="${2:?--tag needs a value.}"; shift 2 ;;
            --app) app="${2:?--app needs a value.}"; shift 2 ;;
            --nonce) want_nonce="${2:?--nonce needs a value.}"; shift 2 ;;
            --asset-sha256) want_asset="${2:?--asset-sha256 needs a value.}"; shift 2 ;;
            --preview) preview="${2:?--preview needs a value.}"; shift 2 ;;
            --findings-file) findings_file="${2:?--findings-file needs a value.}"; shift 2 ;;
            -h|--help) report_usage; exit 0 ;;
            *) echo "error: unknown argument: $1." >&2; exit 2 ;;
        esac
    done
    [ -n "$out" ] || die 2 "fold requires --out."
    [ "${#run_dirs[@]}" -gt 0 ] || die 2 "fold requires at least one --run-dir."
    [ -n "$findings_file" ] || findings_file="$(_report_default_findings_file)"

    local items="[]" d obj
    for d in "${run_dirs[@]}"; do
        [ -d "$d" ] || die 2 "'$d' is not a directory."
        obj="$(_report_read_run "$d")"
        items="$(printf '%s' "$items" | jq --argjson o "$obj" '. + [$o]')"
    done

    local all_findings
    all_findings="$(printf '%s' "$items" | jq -c '[.[].findings[]] | unique | sort')"
    if [ -f "$findings_file" ]; then
        local code
        for code in $(printf '%s' "$all_findings" | jq -r '.[]'); do
            if ! grep -qE "^${code}([^A-Za-z0-9_.-]|\$)" "$findings_file"; then
                die 3 "finding '$code' is not listed in $findings_file; a compiled report may never carry an unlisted code."
            fi
        done
    else
        warn "$findings_file does not exist; findings are not being checked against a list."
    fi

    local nonce_ok=true asset_ok=true complete=true
    local distinct_nonces nonce_count
    distinct_nonces="$(printf '%s' "$items" | jq -c '[.[].nonce] | unique')"
    nonce_count="$(printf '%s' "$distinct_nonces" | jq 'length')"
    if [ "$nonce_count" -ne 1 ]; then nonce_ok=false; fi
    if [ "$nonce_count" -eq 1 ] && [ -n "$want_nonce" ]; then
        [ "$(printf '%s' "$distinct_nonces" | jq -r '.[0] // empty')" = "$want_nonce" ] || nonce_ok=false
    fi
    if printf '%s' "$items" | jq -e 'any(.[]; .nonce_ok != true)' > /dev/null; then
        nonce_ok=false
    fi

    local distinct_assets asset_count
    distinct_assets="$(printf '%s' "$items" | jq -c '[.[].asset_sha256] | unique')"
    asset_count="$(printf '%s' "$distinct_assets" | jq 'length')"
    if [ "$asset_count" -ne 1 ]; then asset_ok=false; fi
    if [ "$asset_count" -eq 1 ] && [ -n "$want_asset" ]; then
        [ "$(printf '%s' "$distinct_assets" | jq -r '.[0] // empty')" = "$want_asset" ] || asset_ok=false
    fi

    if printf '%s' "$items" | jq -e 'any(.[]; .complete != true)' > /dev/null; then
        complete=false
    fi

    local any_harness_error=false all_pass=true
    if printf '%s' "$items" | jq -e 'any(.[]; .outcome_kind == "harness_error" or .outcome_kind == null)' > /dev/null; then
        any_harness_error=true
    fi
    if ! printf '%s' "$items" | jq -e 'all(.[]; .verdict == "pass")' > /dev/null; then
        all_pass=false
    fi

    local verdict outcome
    if [ "$nonce_ok" != "true" ] || [ "$asset_ok" != "true" ] || [ "$complete" != "true" ] || [ "$any_harness_error" = "true" ]; then
        verdict="error"; outcome="harness_error"
    elif [ "$all_pass" = "true" ]; then
        verdict="pass"; outcome="pass"
    else
        verdict="fail"; outcome="scenario_fail"
    fi

    local overall_verbose=false
    if printf '%s' "$items" | jq -e 'any(.[]; .verbose == true)' > /dev/null; then
        overall_verbose=true
    fi

    local scenarios image screenshots gate_run_id preview_bool
    scenarios="$(printf '%s' "$items" | jq -c '[.[] | {name: .scenario, run_id: .run_id, verdict: .verdict, outcome_kind: .outcome_kind, findings: .findings}] | sort_by(.name)')"
    image="$(printf '%s' "$items" | jq -c '[.[].image] | map(select(. != null)) | .[0] // null')"
    screenshots="$(printf '%s' "$items" | jq -c '[.[] | {scenario: .scenario, dir: .screenshots_dir}]')"
    gate_run_id="$(new_run_id gate "$app" "$tag")"
    case "$preview" in
        true) preview_bool=true ;;
        *) preview_bool=false ;;
    esac

    local report_json
    report_json="$(jq -n \
        --arg run_id "$gate_run_id" --arg tag "$tag" --arg app "$app" \
        --arg nonce "$want_nonce" --arg asset_sha256 "$want_asset" \
        --argjson preview "$preview_bool" --arg verdict "$verdict" --arg outcome "$outcome" \
        --argjson scenarios "$scenarios" --argjson findings "$all_findings" \
        --argjson image "$image" --argjson verbose "$overall_verbose" --argjson complete "$complete" \
        --argjson nonce_ok "$nonce_ok" --argjson asset_ok "$asset_ok" --argjson screenshots "$screenshots" \
        --arg compiled_at "$(now_iso)" \
        '{
            run_id: $run_id, tag: $tag, app: $app,
            nonce: (if $nonce == "" then null else $nonce end),
            asset_sha256: (if $asset_sha256 == "" then null else $asset_sha256 end),
            preview: $preview, verdict: $verdict, outcome_kind: $outcome,
            scenarios: $scenarios, findings: $findings, image: $image,
            verbose: $verbose, complete: $complete, nonce_ok: $nonce_ok, asset_ok: $asset_ok,
            screenshots: $screenshots, compiled_at: $compiled_at
        }')"

    mkdir -p "$(dirname "$out")"
    printf '%s\n' "$report_json" | jq '.' > "$out"

    case "$verdict" in
        pass) exit 0 ;;
        fail) exit 1 ;;
        *) exit 3 ;;
    esac
}

# ---------------------------------------------------------------------------
# decide --report <path>
#
# Reads exactly one file. No journal, no screenshots, no run directory.

cmd_report_decide() {
    local report=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --report) report="${2:?--report needs a value.}"; shift 2 ;;
            -h|--help) report_usage; exit 0 ;;
            *) echo "error: unknown argument: $1." >&2; exit 2 ;;
        esac
    done
    [ -n "$report" ] || die 2 "decide requires --report."
    [ -f "$report" ] || die 2 "'$report' does not exist."

    local verdict outcome
    verdict="$(jq -r '.verdict // empty' "$report")"
    outcome="$(jq -r '.outcome_kind // empty' "$report")"
    printf 'verdict: %s\n' "${verdict:-unknown}"
    printf 'outcome_kind: %s\n' "${outcome:-unknown}"
    case "$verdict" in
        pass) exit 0 ;;
        fail) exit 1 ;;
        *) exit 3 ;;
    esac
}

# ---------------------------------------------------------------------------
# public --report <path> --out <path> [--findings-file <path>]
#
# Builds report.public.json by naming every key explicitly — never by
# deleting keys from the private report — so a field nobody reviewed cannot
# reach it by simply being added upstream. The field set is exactly:
# verdict, findings, asset_sha256, image, scenarios (names only), run_id.

cmd_report_public() {
    local report="" out="" findings_file=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --report) report="${2:?--report needs a value.}"; shift 2 ;;
            --out) out="${2:?--out needs a value.}"; shift 2 ;;
            --findings-file) findings_file="${2:?--findings-file needs a value.}"; shift 2 ;;
            -h|--help) report_usage; exit 0 ;;
            *) echo "error: unknown argument: $1." >&2; exit 2 ;;
        esac
    done
    [ -n "$report" ] || die 2 "public requires --report."
    [ -n "$out" ] || die 2 "public requires --out."
    [ -f "$report" ] || die 2 "'$report' does not exist."
    [ -n "$findings_file" ] || findings_file="$(_report_default_findings_file)"

    # A named allowlist of /etc/first-run-golden.json's own scalar fields
    # (harness/image/README.md's own table) — never the whole object, so an
    # unreviewed key added there cannot reach the public asset by default.
    local image_allow='["schema_version","image_name","build_id","macos_product_version","macos_build","ipsw_sha256","tart_version","template_commit","claude_code_version","build_date","manual_steps"]'

    local public_json
    public_json="$(jq -n --slurpfile src "$report" --argjson allow "$image_allow" '
        $src[0] as $r
        | {
            verdict: $r.verdict,
            findings: ($r.findings // []),
            asset_sha256: $r.asset_sha256,
            image: (
                ($r.image // {}) as $img
                | reduce $allow[] as $k ({};
                    if ($img | type) == "object" and ($img | has($k))
                       and (($img[$k] | type) as $t | $t == "string" or $t == "number" or $t == "boolean")
                    then . + {($k): $img[$k]}
                    else . end)
            ),
            scenarios: ([($r.scenarios // [])[].name]),
            run_id: $r.run_id
          }
    ')"

    local code
    for code in $(printf '%s' "$public_json" | jq -r '.findings[]'); do
        case "$code" in
            *[!A-Za-z0-9_.-]*) die 3 "finding '$code' is not a bare code; refusing to publish." ;;
        esac
        if [ -f "$findings_file" ] && ! grep -qE "^${code}([^A-Za-z0-9_.-]|\$)" "$findings_file"; then
            die 3 "finding '$code' is not listed in $findings_file; refusing to publish."
        fi
    done

    if printf '%s' "$public_json" | jq -e '[.. | strings] | any(test("/"))' > /dev/null; then
        die 3 "the public report would carry a value containing '/' — a path or a host detail; refusing to publish."
    fi

    local keys expected
    keys="$(printf '%s' "$public_json" | jq -c 'keys | sort')"
    expected='["asset_sha256","findings","image","run_id","scenarios","verdict"]'
    if [ "$keys" != "$expected" ]; then
        die 3 "report.public.json would carry $keys, not the documented field set $expected."
    fi

    mkdir -p "$(dirname "$out")"
    printf '%s\n' "$public_json" | jq '.' > "$out"
}

# ---------------------------------------------------------------------------
# Direct invocation only. Sourced, this file stops above and defines
# functions alone (see the guard at the top).

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    report_usage() {
        sed -n '2,53p' "$0" | sed 's/^# \{0,1\}//'
    }
    require_cmd jq

    COMMAND="${1:-}"
    if [ $# -gt 0 ]; then shift; fi
    case "$COMMAND" in
        compile) cmd_report_compile "$@" ;;
        fold)    cmd_report_fold "$@" ;;
        decide)  cmd_report_decide "$@" ;;
        public)  cmd_report_public "$@" ;;
        -h|--help) report_usage; exit 0 ;;
        "") report_usage >&2; exit 2 ;;
        *) echo "error: unknown command: $COMMAND." >&2; exit 2 ;;
    esac
fi
