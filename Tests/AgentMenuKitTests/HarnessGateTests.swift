// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// U11: `harness/gate.sh`, driven as a real subprocess against a stub `gh`,
/// a stub `security` (the login keychain) and a stub `run.sh` on `PATH` —
/// the same idiom `HarnessScriptTests.swift` already uses for `tart`/`ssh`.
/// The real `gate.sh` is never told about a real GitHub release: every test
/// here replaces `security`, `gh` and `run.sh` before `gate.sh` ever sees
/// them, so this suite cannot reach a real keychain entry or a real
/// release, whatever it does.
///
/// `harness/lib/report.sh` is exercised for real (it is this unit's own
/// deliverable, not something to stub) — only the world outside this
/// checkout (`gh`, the keychain, the VM orchestrator) is faked.
func runHarnessGateTests(_ t: TestRunner) {
    t.suite("HarnessGate")

    let root = repositoryRoot()
    let gateSH = root.appendingPathComponent("harness/gate.sh").path
    guard FileManager.default.isExecutableFile(atPath: gateSH) else {
        t.expect(false, "harness/gate.sh is missing or not executable at \(gateSH) — this suite fails rather than skipping")
        return
    }

    let parsed = runProcess("/bin/bash", ["-n", gateSH])
    t.expectEqual(parsed.status, 0, "harness/gate.sh parses — \(parsed.stderr)")

    let help = runProcess(gateSH, ["--help"])
    t.expectEqual(help.status, 0, "gate.sh --help exits 0")
    for phrase in ["gate.sh run --app", "gate.sh publish --tag", "security add-generic-password"] {
        t.expect(help.stdout.contains(phrase), "gate.sh --help names '\(phrase)' — got: \(help.stdout.prefix(400))")
    }

    runGateTokenTests(t, root, gateSH)
    runGateRefusalTests(t, root, gateSH)
    runGateIntegrationTests(t, root, gateSH)
}

// MARK: - The rig: stub security, gh and run.sh on PATH

private struct GateRig {
    let dir: TempDir
    let gateScript: String
    let environment: [String: String]
    let distRoot: String
    let state: String
    let repo: String
}

private let gateSecurityStub = #"""
#!/bin/bash
STATE="${GATE_STUB_STATE:?}"
if [ "${1:-}" = "find-generic-password" ]; then
    if [ -f "$STATE/token" ]; then
        cat "$STATE/token"
        exit 0
    fi
    exit 44
fi
exit 1
"""#

/// A stub `gh` with just enough memory to answer `release view`, `download`,
/// `upload` and `edit` from a handful of files in `$GATE_STUB_STATE`:
/// `is_draft` ("true"/"false"), `asset_name`, `<asset_name>` and
/// `<asset_name>.sha256`. Every call is appended to `calls.log`, and the
/// environment each call actually saw is appended to `env.log`, so a test
/// can assert `GH_TOKEN`/`GH_CONFIG_DIR` without either ever pointing at
/// this machine's real ones.
private let gateGHStub = #"""
#!/bin/bash
STATE="${GATE_STUB_STATE:?}"
printf 'gh %s\n' "$*" >> "$STATE/calls.log"
printf 'GH_TOKEN=%s GH_CONFIG_DIR=%s\n' "${GH_TOKEN:-}" "${GH_CONFIG_DIR:-}" >> "$STATE/env.log"
ASSET_NAME="$(cat "$STATE/asset_name" 2>/dev/null || echo asset.zip)"
case "${1:-} ${2:-}" in
  "release view")
    if [[ "$*" == *"--json isDraft"* ]]; then
        cat "$STATE/is_draft" 2>/dev/null || echo false
    elif [[ "$*" == *"--json assets"* ]]; then
        printf '%s\n%s.sha256\n' "$ASSET_NAME" "$ASSET_NAME"
    fi
    ;;
  "release download")
    dir=""
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
        if [ "${args[$i]}" = "--dir" ]; then dir="${args[$((i + 1))]}"; fi
    done
    mkdir -p "$dir"
    [ -f "$STATE/$ASSET_NAME" ] && cp "$STATE/$ASSET_NAME" "$dir/"
    [ -f "$STATE/$ASSET_NAME.sha256" ] && cp "$STATE/$ASSET_NAME.sha256" "$dir/"
    ;;
  "release upload")
    args=("$@")
    for ((i = 0; i < ${#args[@]}; i++)); do
        case "${args[$i]}" in
            *.json) cp "${args[$i]}" "$STATE/uploaded-$(basename "${args[$i]}")" ;;
        esac
    done
    echo "uploaded" >> "$STATE/calls.log"
    ;;
  "release edit")
    if [[ "$*" == *"--draft=false"* ]]; then echo "published" >> "$STATE/calls.log"; fi
    ;;
esac
exit 0
"""#

/// A stub orchestrator standing in for `harness/run.sh`: `start` writes a
/// run directory shaped like a real one (report.json + a one-line journal)
/// and prints its run id; `wait` always exits 0. Behavior is steered by a
/// handful of env vars a test sets per call, so one stub covers the happy
/// path and every failure mode this suite needs:
///
///   GATE_STUB_FAIL_SCENARIO       that one scenario compiles to fail
///   GATE_STUB_RENAME_SCENARIO     "from:to" — the report names "to" instead
///                                 of the scenario actually asked for
///   GATE_STUB_NONCE_OVERRIDE      the journal echoes this nonce, not the
///                                 one --nonce actually passed
///   GATE_STUB_VERBOSE             "true" marks every run's fixture echo
///                                 verbose
private let gateRunSHStub = #"""
#!/bin/bash
set -euo pipefail
DIST="${HARNESS_DIST_ROOT:?}"
STATE="${GATE_STUB_STATE:?}"
printf 'run.sh %s\n' "$*" >> "$STATE/run-calls.log"
case "${1:-}" in
  start)
    shift
    scenario="" nonce="" asset=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --scenario) scenario="$2"; shift 2 ;;
            --nonce) nonce="$2"; shift 2 ;;
            --asset) asset="$2"; shift 2 ;;
            --app|--tier) shift 2 ;;
            *) shift ;;
        esac
    done
    rid="agentmenu-stranger-${scenario}-20260918T220000Z-$$"
    dir="$DIST/$rid"
    mkdir -p "$dir/screenshots"
    sha="$(shasum -a 256 "$asset" | awk '{print $1}')"

    report_scenario="$scenario"
    if [ -n "${GATE_STUB_RENAME_SCENARIO:-}" ]; then
        from="${GATE_STUB_RENAME_SCENARIO%%:*}"
        to="${GATE_STUB_RENAME_SCENARIO#*:}"
        [ "$scenario" = "$from" ] && report_scenario="$to"
    fi

    verdict="pass"; outcome="pass"; exit_code=0
    if [ "${GATE_STUB_FAIL_SCENARIO:-}" = "$scenario" ]; then
        verdict="fail"; outcome="scenario_fail"; exit_code=1
    fi

    jq -n --arg rid "$rid" --arg nonce "$nonce" --arg scenario "$report_scenario" \
        --arg sha "$sha" --arg verdict "$verdict" --arg outcome "$outcome" --argjson exit_code "$exit_code" \
        '{run_id:$rid,nonce:$nonce,scenario:$scenario,asset_sha256:$sha,status:"finished",verdict:$verdict,outcome_kind:$outcome,findings:[],exit_code:$exit_code}' \
        > "$dir/report.json"

    jnonce="$nonce"
    [ -n "${GATE_STUB_NONCE_OVERRIDE:-}" ] && jnonce="$GATE_STUB_NONCE_OVERRIDE"
    verbose="false"
    [ "${GATE_STUB_VERBOSE:-}" = "true" ] && verbose="true"
    # -c: journal.ndjson is one compact JSON object per line (the same
    # invariant Journal.swift's own writer keeps, sortedKeys aside) — a
    # pretty-printed object here would make report.sh's `head -n 1 |
    # jq -r '.nonce'` read a bare "{" and silently treat the nonce as
    # missing, which report.sh is right to then call a harness error.
    jq -nc --arg nonce "$jnonce" --argjson verbose "$verbose" \
        '{seq:1,schema:1,event:"harness started",data:{verbose:$verbose},nonce:$nonce}' \
        > "$dir/journal.ndjson"

    echo "$rid"
    ;;
  wait)
    exit 0
    ;;
  *)
    echo "run.sh stub: unknown command ${1:-}" >&2
    exit 2
    ;;
esac
"""#

private func makeGateRig(_ label: String, _ root: URL, _ t: TestRunner, isDraft: Bool = true) -> GateRig? {
    let dir = TempDir(label)
    do {
        for (name, body) in [
            ("bin/security", gateSecurityStub),
            ("bin/gh", gateGHStub),
            ("bin/run.sh", gateRunSHStub),
        ] {
            try dir.write(body + "\n", to: name)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path(name))
        }
        try FileManager.default.createDirectory(atPath: dir.path("dist"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: dir.path("state"), withIntermediateDirectories: true)
        try dir.write(isDraft ? "true" : "false", to: "state/is_draft")
        try dir.write("AgentMenu-0.1.1.zip", to: "state/asset_name")

        // A real (if fake) asset, with a real matching .sha256 — the
        // exact shape release.yml's own `shasum -a 256 "$NAME" | tee
        // "$NAME.sha256"` produces.
        try dir.write("fake zip contents\n", to: "state/AgentMenu-0.1.1.zip")
    } catch {
        t.expect(false, "built the gate stub rig: \(error)")
        dir.cleanup()
        return nil
    }
    let shaResult = runProcess("/usr/bin/shasum", ["-a", "256", dir.path("state/AgentMenu-0.1.1.zip")])
    let sha = shaResult.stdout.split(separator: " ").first.map(String.init) ?? ""
    try? "\(sha)  AgentMenu-0.1.1.zip\n".write(toFile: dir.path("state/AgentMenu-0.1.1.zip.sha256"), atomically: true, encoding: .utf8)
    try? "a-fine-grained-token\n".write(toFile: dir.path("state/token"), atomically: true, encoding: .utf8)

    let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    let environment = [
        "PATH": dir.path("bin") + ":" + existingPath,
        "GATE_STUB_STATE": dir.path("state"),
        "HARNESS_DIST_ROOT": dir.path("dist"),
        "HARNESS_RUN_SH": dir.path("bin/run.sh"),
        // Cleared, never inherited — a test asserting isolation would be
        // meaningless if the harness's own ambient value leaked through.
        "GH_TOKEN": "",
        "GH_CONFIG_DIR": "",
    ]
    return GateRig(
        dir: dir,
        gateScript: root.appendingPathComponent("harness/gate.sh").path,
        environment: environment,
        distRoot: dir.path("dist"),
        state: dir.path("state"),
        repo: "Facens/agentmenu"
    )
}

private func gateRun(_ rig: GateRig, _ arguments: [String], extra: [String: String] = [:]) -> CLIResult {
    var environment = rig.environment
    for (key, value) in extra { environment[key] = value }
    return runProcess(rig.gateScript, arguments, environment: environment)
}

private func gateCallLog(_ rig: GateRig) -> String {
    (try? String(contentsOfFile: "\(rig.state)/calls.log", encoding: .utf8)) ?? ""
}

private func gateEnvLog(_ rig: GateRig) -> String {
    (try? String(contentsOfFile: "\(rig.state)/env.log", encoding: .utf8)) ?? ""
}

/// A gate refusal names the report it refused; a failing assertion that
/// quotes only the refusal makes the reader go and look, and by then the
/// rig's TempDir is gone. This pulls the report's own text into the message
/// while it still exists.
private func gateReportBody(_ stderr: String) -> String {
    for line in stderr.split(separator: "\n").reversed() {
        guard line.contains("report.json"), let slash = line.firstIndex(of: "/") else { continue }
        var path = String(line[slash...])
        if let dot = path.range(of: "report.json") { path = String(path[..<dot.upperBound]) }
        if let text = try? String(contentsOfFile: path, encoding: .utf8) {
            return "report.json: \(text)"
        }
        return "(no report at \(path))"
    }
    return ""
}

private func gateRunCallLog(_ rig: GateRig) -> String {
    (try? String(contentsOfFile: "\(rig.state)/run-calls.log", encoding: .utf8)) ?? ""
}

private let agentMenuScenarios = [
    "vanilla-first-run", "launch-terminal", "no-agent", "profile-work-only",
    "profile-personal-only", "profile-both", "bridge-install",
]

// MARK: - Token

private func runGateTokenTests(_ t: TestRunner, _ root: URL, _ gateSH: String) {
    guard let rig = makeGateRig("gate-token", root, t) else { return }
    defer { rig.dir.cleanup() }
    try? FileManager.default.removeItem(atPath: "\(rig.state)/token")

    let result = gateRun(rig, ["run", "--app", "agentmenu", "--tag", "v0.1.1", "--repo", rig.repo,
                               "--scenarios", "vanilla-first-run"])
    t.expectEqual(result.status, 2, "no keychain token is a usage error — stderr: \(result.stderr)")
    t.expect(result.stderr.contains("security add-generic-password"), "the refusal quotes the one-time setup command — got: \(result.stderr)")
    t.expect(result.stderr.contains("harness-gate-token"), "the refusal names the service")
    t.expect(!gateCallLog(rig).contains("gh "), "no gh call is made before the token is confirmed present")
}

// MARK: - Refusals

private func runGateRefusalTests(_ t: TestRunner, _ root: URL, _ gateSH: String) {
    // Not a draft: exit 2, without downloading.
    do {
        guard let rig = makeGateRig("gate-not-draft", root, t, isDraft: false) else { return }
        defer { rig.dir.cleanup() }
        let result = gateRun(rig, ["run", "--app", "agentmenu", "--tag", "v0.1.1", "--repo", rig.repo,
                                    "--scenarios", "vanilla-first-run"])
        t.expectEqual(result.status, 2, "a non-draft release is a usage error — stderr: \(result.stderr)")
        t.expect(result.stderr.contains("draft"), "the refusal says why")
        t.expect(!gateCallLog(rig).contains("release download"), "nothing is downloaded before the draft check passes")
    }

    // Downloaded asset hash mismatch: exit 3, never calls gh release edit.
    do {
        guard let rig = makeGateRig("gate-hash-mismatch", root, t) else { return }
        defer { rig.dir.cleanup() }
        try? "0000000000000000000000000000000000000000000000000000000000000000  AgentMenu-0.1.1.zip\n"
            .write(toFile: "\(rig.state)/AgentMenu-0.1.1.zip.sha256", atomically: true, encoding: .utf8)
        let result = gateRun(rig, ["run", "--app", "agentmenu", "--tag", "v0.1.1", "--repo", rig.repo,
                                    "--scenarios", "vanilla-first-run"])
        t.expectEqual(result.status, 3, "a hash mismatch is a harness error — stderr: \(result.stderr)")
        t.expect(!gateCallLog(rig).contains("release edit"), "a hash mismatch never calls gh release edit")
        t.expect(gateRunCallLog(rig).isEmpty, "no scenario is ever started against a mismatched asset")
    }

    // A run's journal nonce differs from the nonce the gate generated: exit
    // 3, even though the asset hash matches (the run's own report.json
    // still carries the right asset_sha256 — only the journal is stale).
    do {
        guard let rig = makeGateRig("gate-nonce-mismatch", root, t) else { return }
        defer { rig.dir.cleanup() }
        let result = gateRun(rig, ["run", "--app", "agentmenu", "--tag", "v0.1.1", "--repo", rig.repo,
                                    "--scenarios", "vanilla-first-run"],
                              extra: ["GATE_STUB_NONCE_OVERRIDE": "a-stale-nonce-from-a-previous-run"])
        t.expectEqual(result.status, 3, "a journal/gate nonce mismatch is a harness error — stderr: \(result.stderr)")
        t.expect(gateCallLog(rig).contains("release edit"), "a post-run refusal writes a note into the draft")
        t.expect(gateCallLog(rig).contains("--notes-file"), "the note goes through --notes-file")
        t.expect(!gateCallLog(rig).contains("--notes ") , "never an inline --notes")
        t.expect(!gateCallLog(rig).contains("release upload"), "report.public.json is never uploaded on refusal")
    }

    // A report naming six of the seven AgentMenu scenarios is refused —
    // simulated here by asking for all seven while the stub silently
    // relabels one run's own scenario field, so the compiled report is one
    // name short of what was requested.
    do {
        guard let rig = makeGateRig("gate-short-scenario-list", root, t) else { return }
        defer { rig.dir.cleanup() }
        let result = gateRun(rig, ["run", "--app", "agentmenu", "--tag", "v0.1.1", "--repo", rig.repo,
                                    "--scenarios", agentMenuScenarios.joined(separator: ",")],
                              extra: ["GATE_STUB_RENAME_SCENARIO": "bridge-install:bridge-install-typo"])
        t.expectEqual(result.status, 3, "a short scenario list is a harness error — stderr: \(result.stderr)")
        t.expect(result.stderr.contains("bridge-install"), "the refusal names the missing scenario — got: \(result.stderr)")
        t.expect(gateCallLog(rig).contains("--notes-file"), "a note is written for this refusal too")
        t.expect(!gateCallLog(rig).contains("release upload"), "nothing is uploaded")
    }

    // A report whose fixture echo records the verbose flag is refused.
    do {
        guard let rig = makeGateRig("gate-verbose", root, t) else { return }
        defer { rig.dir.cleanup() }
        let result = gateRun(rig, ["run", "--app", "agentmenu", "--tag", "v0.1.1", "--repo", rig.repo,
                                    "--scenarios", "vanilla-first-run"],
                              extra: ["GATE_STUB_VERBOSE": "true"])
        t.expectEqual(result.status, 3, "a verbose run is refused — stderr: \(result.stderr)")
        t.expect(result.stderr.contains("verbose"), "the refusal says why")
        t.expect(!gateCallLog(rig).contains("release upload"), "a verbose run's report is never uploaded")
    }

    // A scenario that genuinely fails is reported as scenario_fail, not
    // masked as a harness error, and still writes the run-id-only note.
    do {
        guard let rig = makeGateRig("gate-scenario-fail", root, t) else { return }
        defer { rig.dir.cleanup() }
        let result = gateRun(rig, ["run", "--app", "agentmenu", "--tag", "v0.1.1", "--repo", rig.repo,
                                    "--scenarios", "vanilla-first-run,no-agent"],
                              extra: ["GATE_STUB_FAIL_SCENARIO": "no-agent"])
        t.expectEqual(result.status, 1, "a genuine scenario failure exits 1, not 3 — stderr: \(result.stderr)\n\(gateReportBody(result.stderr))")
        t.expect(gateCallLog(rig).contains("--notes-file"), "the failure note is still written")
    }
}

// MARK: - Integration: run then publish

private func runGateIntegrationTests(_ t: TestRunner, _ root: URL, _ gateSH: String) {
    do {
        guard let rig = makeGateRig("gate-integration", root, t) else { return }
        defer { rig.dir.cleanup() }

        let runResult = gateRun(rig, ["run", "--app", "agentmenu", "--tag", "v0.1.1", "--repo", rig.repo,
                                       "--scenarios", agentMenuScenarios.joined(separator: ",")])
        t.expectEqual(runResult.status, 0, "a full passing run exits 0 — stderr: \(runResult.stderr)\n\(gateReportBody(runResult.stderr))")

        let calls = gateCallLog(rig)
        t.expect(calls.contains("release upload"), "gate.sh run uploads report.public.json")
        t.expect(!calls.contains("--draft=false"), "gate.sh run never publishes")

        let env = gateEnvLog(rig)
        t.expect(env.contains("GH_TOKEN=a-fine-grained-token"), "gh saw the keychain token, not the ambient session")
        t.expect(env.contains("GH_CONFIG_DIR=/"), "gh ran with an isolated GH_CONFIG_DIR, not the maintainer's own")

        // Exactly one uploaded report.public.json, with the documented
        // field set and seven scenario names.
        let uploaded = (try? FileManager.default.contentsOfDirectory(atPath: rig.state))?
            .filter { $0.hasPrefix("uploaded-") } ?? []
        t.expectEqual(uploaded.count, 1, "exactly one report.public.json was uploaded")
        if let name = uploaded.first,
           let data = FileManager.default.contents(atPath: "\(rig.state)/\(name)"),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            t.expectEqual(obj["verdict"] as? String, "pass", "the uploaded report's verdict is pass")
            t.expectEqual((obj["scenarios"] as? [String])?.count, 7, "all seven scenarios are named")
        } else {
            t.expect(false, "could not read the uploaded report.public.json")
        }

        // publish now finds it, and calls gh release edit --draft=false
        // exactly once.
        let publishResult = gateRun(rig, ["publish", "--tag", "v0.1.1", "--repo", rig.repo])
        t.expectEqual(publishResult.status, 0, "publish succeeds against the run just made — stderr: \(publishResult.stderr)")
        let publishedCount = gateCallLog(rig).components(separatedBy: "published\n").count - 1
        t.expectEqual(publishedCount, 1, "gh release edit --draft=false was called exactly once")
        t.expect(publishResult.stdout.contains("vanilla-first-run"), "publish prints screenshot directories for review — got: \(publishResult.stdout)")
    }

    // gate.sh publish refuses, and never publishes, once the draft's asset
    // digest has moved past the local run's own asset_sha256.
    do {
        guard let rig = makeGateRig("gate-digest-moved", root, t) else { return }
        defer { rig.dir.cleanup() }

        let runResult = gateRun(rig, ["run", "--app", "agentmenu", "--tag", "v0.1.1", "--repo", rig.repo,
                                       "--scenarios", "vanilla-first-run"])
        t.expectEqual(runResult.status, 0, "the run passes — stderr: \(runResult.stderr)\n\(gateReportBody(runResult.stderr))")

        // The release is rebuilt: a new asset, a new .sha256, same tag.
        try? "a rebuilt asset with different bytes\n".write(toFile: "\(rig.state)/AgentMenu-0.1.1.zip", atomically: true, encoding: .utf8)
        let shaResult = runProcess("/usr/bin/shasum", ["-a", "256", "\(rig.state)/AgentMenu-0.1.1.zip"])
        let newSHA = shaResult.stdout.split(separator: " ").first.map(String.init) ?? ""
        try? "\(newSHA)  AgentMenu-0.1.1.zip\n".write(toFile: "\(rig.state)/AgentMenu-0.1.1.zip.sha256", atomically: true, encoding: .utf8)

        let publishResult = gateRun(rig, ["publish", "--tag", "v0.1.1", "--repo", rig.repo])
        t.expectEqual(publishResult.status, 3, "publish refuses once the digest has moved — stderr: \(publishResult.stderr)")
        t.expect(!gateCallLog(rig).contains("--draft=false"), "a moved digest never publishes")
    }
}
