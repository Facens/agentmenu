// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// U11: `harness/lib/report.sh`, driven directly as a subprocess (its own
/// dual-mode CLI — see that file's header) against hand-built fixture run
/// directories. No VM, no `gh`, no `harness/gate.sh` — this suite proves the
/// compiler alone: folding a run's own `report.json` and `journal.ndjson`
/// into a derived summary (`compile`), combining several runs into one gate
/// report (`fold`), building the redacted public asset (`public`), and
/// reproducing a verdict from a compiled report alone (`decide`).
///
/// report.sh never recomputes a single run's verdict (harness/run.sh's own
/// supervisor already owns that — see report.sh's header); what these
/// fixtures vary is the two things only report.sh checks: whether the
/// journal's own first line echoes the run's nonce, and whether a run's own
/// report.json already says `outcome_kind: harness_error` because
/// `run.sh` decided a step failed for a driver reason.
func runHarnessReportTests(_ t: TestRunner) {
    t.suite("HarnessReport")

    let root = repositoryRoot()
    let reportSH = root.appendingPathComponent("harness/lib/report.sh").path
    guard FileManager.default.isExecutableFile(atPath: reportSH) else {
        t.expect(false, "harness/lib/report.sh is missing or not executable at \(reportSH) — this suite fails rather than skipping")
        return
    }
    let findingsTXT = root.appendingPathComponent("harness/findings.txt").path
    guard FileManager.default.fileExists(atPath: findingsTXT) else {
        t.expect(false, "harness/findings.txt is missing")
        return
    }

    let parsed = runProcess("/bin/bash", ["-n", reportSH])
    t.expectEqual(parsed.status, 0, "harness/lib/report.sh parses — \(parsed.stderr)")

    runReportCompileTests(t, root, reportSH)
    runReportFoldTests(t, root, reportSH, findingsTXT)
    runReportPublicTests(t, root, reportSH, findingsTXT)
    runReportDecideTests(t, root, reportSH)
}

// MARK: - Fixture builder

/// Writes a run directory shaped exactly like one `harness/run.sh` itself
/// would leave behind: `report.json` with the real field set (this file's
/// own `_report_read_run` trusts `verdict`/`outcome_kind`/`findings` from
/// it verbatim) and a one-line `journal.ndjson` whose `nonce` and
/// `data.verbose` are what `report.sh` cross-checks.
@discardableResult
private func writeReportFixtureRun(
    _ dir: TempDir,
    name: String,
    scenario: String,
    reportNonce: String?,
    journalNonce: String?,
    verdict: String,
    outcome: String,
    findings: [String],
    assetSHA256: String = "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
    status: String = "finished",
    exitCode: Int? = 0,
    verbose: Bool = false,
    image: [String: Any]? = nil,
    noJournal: Bool = false
) -> String {
    let runDir = dir.path(name)
    try? FileManager.default.createDirectory(atPath: "\(runDir)/screenshots", withIntermediateDirectories: true)

    var report: [String: Any] = [
        "run_id": name,
        "scenario": scenario,
        "asset_sha256": assetSHA256,
        "status": status,
        "verdict": verdict,
        "outcome_kind": outcome,
        "findings": findings,
    ]
    report["nonce"] = (reportNonce as Any?) ?? NSNull()
    if let exitCode { report["exit_code"] = exitCode } else { report["exit_code"] = NSNull() }
    if let image { report["image"] = image } else { report["image"] = NSNull() }

    if let data = try? JSONSerialization.data(withJSONObject: report) {
        try? data.write(to: URL(fileURLWithPath: "\(runDir)/report.json"))
    }

    if !noJournal {
        // Built as its own value rather than inline: the two branches of a
        // ternary infer different dictionary types, and the type checker
        // gives up inside a heterogeneous literal rather than saying so.
        var eventData: [String: Any] = ["boot": 1]
        if verbose { eventData["verbose"] = true }
        var line: [String: Any] = [
            "seq": 1, "t": "2026-09-18T21:00:00.000Z", "schema": 1, "build": "1",
            "event": "harness started",
            "data": eventData,
        ]
        line["nonce"] = (journalNonce as Any?) ?? NSNull()
        if let data = try? JSONSerialization.data(withJSONObject: line),
           let text = String(data: data, encoding: .utf8) {
            try? (text + "\n").write(toFile: "\(runDir)/journal.ndjson", atomically: true, encoding: .utf8)
        }
    }
    return runDir
}

private func reportRun(_ reportSH: String, _ args: [String]) -> CLIResult {
    runProcess(reportSH, args)
}

private func readJSON(_ path: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: path),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    return obj
}

// MARK: - compile

private func runReportCompileTests(_ t: TestRunner, _ root: URL, _ reportSH: String) {
    // Happy path, with all expected events met (the fixture's own report
    // already says so — see this file's header on what report.sh trusts):
    // compiles to verdict pass, findings [].
    do {
        let dir = TempDir("report-compile-pass")
        defer { dir.cleanup() }
        let run = writeReportFixtureRun(
            dir, name: "run1", scenario: "profile-work-only",
            reportNonce: "n1", journalNonce: "n1",
            verdict: "pass", outcome: "pass", findings: []
        )
        let result = reportRun(reportSH, ["compile", "--run-dir", run])
        t.expectEqual(result.status, 0, "a clean pass compiles to exit 0 — \(result.stderr)")
        guard let obj = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] else {
            t.expect(false, "compile printed a JSON object — got: \(result.stdout)")
            return
        }
        t.expectEqual(obj["verdict"] as? String, "pass", "verdict is pass")
        t.expectEqual((obj["findings"] as? [String])?.isEmpty, true, "findings is empty")
        t.expectEqual(obj["nonce_ok"] as? Bool, true, "the journal's nonce matched the report's")
    }

    // Happy path: the vanilla-first-run fixture (a configured folder, no
    // enabled terminal) compiles to pass with exactly one finding (AE2).
    do {
        let dir = TempDir("report-compile-vanilla")
        defer { dir.cleanup() }
        let run = writeReportFixtureRun(
            dir, name: "run-vanilla", scenario: "vanilla-first-run",
            reportNonce: "n2", journalNonce: "n2",
            verdict: "pass", outcome: "pass", findings: ["dialog-confirm-retry-2"]
        )
        let result = reportRun(reportSH, ["compile", "--run-dir", run])
        t.expectEqual(result.status, 0, "vanilla-first-run compiles to exit 0 — \(result.stderr)")
        guard let obj = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] else {
            t.expect(false, "compile printed a JSON object")
            return
        }
        t.expectEqual(obj["verdict"] as? String, "pass", "verdict is pass")
        t.expectEqual(obj["findings"] as? [String], ["dialog-confirm-retry-2"], "exactly one finding, dialog-confirm-retry-2")
    }

    // Edge: a journal missing the end-state event — here, the run's own
    // report.json already records the scenario as fail, since run.sh's own
    // finalize() is what observes a missing end state — compiles to fail.
    do {
        let dir = TempDir("report-compile-fail")
        defer { dir.cleanup() }
        let run = writeReportFixtureRun(
            dir, name: "run-fail", scenario: "launch-terminal",
            reportNonce: "n3", journalNonce: "n3",
            verdict: "fail", outcome: "scenario_fail", findings: [], exitCode: 1
        )
        let result = reportRun(reportSH, ["compile", "--run-dir", run])
        t.expectEqual(result.status, 1, "a missing end state compiles to exit 1 — \(result.stderr)")
        guard let obj = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] else {
            t.expect(false, "compile printed a JSON object")
            return
        }
        t.expectEqual(obj["verdict"] as? String, "fail", "verdict is fail")
    }

    // Error: a step marked driver failure (run.sh's own outcome_kind is
    // already harness_error) compiles to outcome_kind harness_error, exit 3.
    do {
        let dir = TempDir("report-compile-driver")
        defer { dir.cleanup() }
        let run = writeReportFixtureRun(
            dir, name: "run-driver", scenario: "bridge-install",
            reportNonce: "n4", journalNonce: "n4",
            verdict: "error", outcome: "harness_error", findings: [], exitCode: 3
        )
        let result = reportRun(reportSH, ["compile", "--run-dir", run])
        t.expectEqual(result.status, 3, "a driver failure compiles to exit 3 — \(result.stderr)")
        guard let obj = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] else {
            t.expect(false, "compile printed a JSON object")
            return
        }
        t.expectEqual(obj["outcome_kind"] as? String, "harness_error", "outcome_kind is harness_error")
    }

    // A run whose journal nonce differs from report.json's own nonce is a
    // harness-level doubt, exit 3, regardless of what the run's own verdict
    // says — this is the one thing report.sh checks that no single run's
    // own report.json can assert about itself.
    do {
        let dir = TempDir("report-compile-nonce")
        defer { dir.cleanup() }
        let run = writeReportFixtureRun(
            dir, name: "run-nonce", scenario: "no-agent",
            reportNonce: "expected", journalNonce: "stale-from-a-previous-run",
            verdict: "pass", outcome: "pass", findings: []
        )
        let result = reportRun(reportSH, ["compile", "--run-dir", run])
        t.expectEqual(result.status, 3, "a journal/report nonce mismatch is exit 3 even though verdict says pass")
    }

    // Usage: --run-dir is required, and an unknown directory refuses.
    do {
        let result = reportRun(reportSH, ["compile"])
        t.expectEqual(result.status, 2, "compile with no --run-dir is a usage error")
        let missing = reportRun(reportSH, ["compile", "--run-dir", "/no/such/directory"])
        t.expectEqual(missing.status, 2, "compile against a missing directory is a usage error")
    }
}

// MARK: - fold

private func runReportFoldTests(_ t: TestRunner, _ root: URL, _ reportSH: String, _ findingsTXT: String) {
    // Happy path: two passing runs under one nonce fold to an overall pass,
    // with the union of their findings and every requested scenario named.
    do {
        let dir = TempDir("report-fold-pass")
        defer { dir.cleanup() }
        let run1 = writeReportFixtureRun(
            dir, name: "r1", scenario: "vanilla-first-run", reportNonce: "N", journalNonce: "N",
            verdict: "pass", outcome: "pass", findings: ["dialog-confirm-retry-2"]
        )
        let run2 = writeReportFixtureRun(
            dir, name: "r2", scenario: "no-agent", reportNonce: "N", journalNonce: "N",
            verdict: "pass", outcome: "pass", findings: ["no-usable-agent"]
        )
        let out = dir.path("gate/report.json")
        let result = reportRun(reportSH, [
            "fold", "--out", out, "--tag", "v0.1.1", "--app", "agentmenu", "--nonce", "N",
            "--asset-sha256", "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
            "--findings-file", findingsTXT,
            "--run-dir", run1, "--run-dir", run2,
        ])
        t.expectEqual(result.status, 0, "two passing runs fold to exit 0 — \(result.stderr)")
        guard let obj = readJSON(out) else {
            t.expect(false, "fold wrote a report.json")
            return
        }
        t.expectEqual(obj["verdict"] as? String, "pass", "overall verdict is pass")
        t.expectEqual(obj["complete"] as? Bool, true, "overall complete")
        let findings = (obj["findings"] as? [String])?.sorted() ?? []
        t.expectEqual(findings, ["dialog-confirm-retry-2", "no-usable-agent"], "findings is the sorted union")
        let names = ((obj["scenarios"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.sorted()
        t.expectEqual(names, ["no-agent", "vanilla-first-run"], "both scenarios are named")
    }

    // Error: one run's outcome is harness_error — the fold is harness_error
    // too, never masked by the other run's pass.
    do {
        let dir = TempDir("report-fold-driver")
        defer { dir.cleanup() }
        let run1 = writeReportFixtureRun(
            dir, name: "r1", scenario: "vanilla-first-run", reportNonce: "N", journalNonce: "N",
            verdict: "pass", outcome: "pass", findings: []
        )
        let run2 = writeReportFixtureRun(
            dir, name: "r2", scenario: "bridge-install", reportNonce: "N", journalNonce: "N",
            verdict: "error", outcome: "harness_error", findings: [], exitCode: 3
        )
        let out = dir.path("gate/report.json")
        let result = reportRun(reportSH, [
            "fold", "--out", out, "--findings-file", findingsTXT,
            "--run-dir", run1, "--run-dir", run2,
        ])
        t.expectEqual(result.status, 3, "a harness_error constituent folds to exit 3")
        if let obj = readJSON(out) {
            t.expectEqual(obj["outcome_kind"] as? String, "harness_error", "the fold's own outcome_kind is harness_error")
        }
    }

    // A finding not listed in findings.txt refuses the fold outright — the
    // one thing that must never quietly reach a compiled report.
    do {
        let dir = TempDir("report-fold-unknown-finding")
        defer { dir.cleanup() }
        let run = writeReportFixtureRun(
            dir, name: "r1", scenario: "no-agent", reportNonce: "N", journalNonce: "N",
            verdict: "pass", outcome: "pass", findings: ["totally-made-up-code"]
        )
        let out = dir.path("gate/report.json")
        let result = reportRun(reportSH, [
            "fold", "--out", out, "--findings-file", findingsTXT, "--run-dir", run,
        ])
        t.expectEqual(result.status, 3, "an unlisted finding code refuses the fold — \(result.stderr)")
        t.expect(result.stderr.contains("totally-made-up-code"), "the refusal names the code")
        t.expect(!FileManager.default.fileExists(atPath: out), "no report.json is written on refusal")
    }

    // A run produced under the verbose fixture flag is carried through as
    // `verbose: true` at the fold level, for gate.sh to refuse on.
    do {
        let dir = TempDir("report-fold-verbose")
        defer { dir.cleanup() }
        let run = writeReportFixtureRun(
            dir, name: "r1", scenario: "no-agent", reportNonce: "N", journalNonce: "N",
            verdict: "pass", outcome: "pass", findings: [], verbose: true
        )
        let out = dir.path("gate/report.json")
        let result = reportRun(reportSH, ["fold", "--out", out, "--run-dir", run])
        t.expectEqual(result.status, 0, "a verbose run still folds to a pass verdict on its own")
        if let obj = readJSON(out) {
            t.expectEqual(obj["verbose"] as? Bool, true, "the fold surfaces the verbose flag")
        }
    }

    // Usage: fold needs --out and at least one --run-dir.
    do {
        let dir = TempDir("report-fold-usage")
        defer { dir.cleanup() }
        t.expectEqual(reportRun(reportSH, ["fold", "--run-dir", dir.path("x")]).status, 2, "fold with no --out is a usage error")
        t.expectEqual(reportRun(reportSH, ["fold", "--out", dir.path("o.json")]).status, 2, "fold with no --run-dir is a usage error")
    }
}

// MARK: - public

private func runReportPublicTests(_ t: TestRunner, _ root: URL, _ reportSH: String, _ findingsTXT: String) {
    // Redaction: report.public.json has exactly the documented field set,
    // every finding is a code present in findings.txt, and no value is
    // free text (checked here as "no value contains '/'", the one shape a
    // path or a host would take that a bare code or a hash never does).
    do {
        let dir = TempDir("report-public-fields")
        defer { dir.cleanup() }
        let run = writeReportFixtureRun(
            dir, name: "r1", scenario: "vanilla-first-run", reportNonce: "N", journalNonce: "N",
            verdict: "pass", outcome: "pass", findings: ["dialog-confirm-retry-2"],
            image: [
                "schema_version": 1, "image_name": "first-run-golden", "build_id": "20260918-1",
                "macos_product_version": "15.6", "macos_build": "25G123", "ipsw_sha256": "abcd",
                "tart_version": "2.37.0", "template_commit": "xyz", "claude_code_version": "1.2.3",
                "build_date": "2026-09-18T00:00:00Z",
                // A field that is not on the allowlist — proves the redaction
                // is a positive allowlist, not "everything except a blocklist".
                "host_note": "built on facens-macbook.local",
            ]
        )
        let folded = dir.path("gate/report.json")
        let foldResult = reportRun(reportSH, ["fold", "--out", folded, "--tag", "v0.1.1", "--app", "agentmenu", "--findings-file", findingsTXT, "--run-dir", run])
        t.expectEqual(foldResult.status, 0, "the fixture folds cleanly — \(foldResult.stderr)")

        let publicPath = dir.path("gate/report.public.json")
        let publicResult = reportRun(reportSH, ["public", "--report", folded, "--out", publicPath, "--findings-file", findingsTXT])
        t.expectEqual(publicResult.status, 0, "public succeeds on a clean fold — \(publicResult.stderr)")

        guard let obj = readJSON(publicPath) else {
            t.expect(false, "report.public.json was written")
            return
        }
        let keys = Set(obj.keys)
        let expectedKeys: Set<String> = ["verdict", "findings", "asset_sha256", "image", "scenarios", "run_id"]
        t.expectEqual(keys, expectedKeys, "the exact documented field set, nothing else")
        t.expect(!keys.contains("run_dir"), "no run_dir field")
        t.expect(!keys.contains("nonce"), "the nonce never reaches the public report")

        let findings = obj["findings"] as? [String] ?? []
        t.expectEqual(findings, ["dialog-confirm-retry-2"], "the finding code, and only the code")
        for code in findings {
            t.expect(FileManager.default.contents(atPath: findingsTXT).flatMap { String(data: $0, encoding: .utf8) }?.contains(code) == true, "'\(code)' is present in findings.txt")
        }

        let image = obj["image"] as? [String: Any] ?? [:]
        t.expect(image["host_note"] == nil, "a non-allowlisted image field (host_note) never reaches the public report")
        t.expectEqual(image["macos_build"] as? String, "25G123", "an allowlisted image field does reach it")

        let scenarios = obj["scenarios"] as? [String] ?? []
        t.expectEqual(scenarios, ["vanilla-first-run"], "scenarios is a bare list of names")

        // No value anywhere in the object contains '/', which is the one
        // shape a path or a hostname would take that nothing legitimate here
        // ever does.
        func collectStrings(_ value: Any) -> [String] {
            if let s = value as? String { return [s] }
            if let arr = value as? [Any] { return arr.flatMap(collectStrings) }
            if let dict = value as? [String: Any] { return dict.values.flatMap(collectStrings) }
            return []
        }
        let allStrings = collectStrings(obj)
        t.expect(!allStrings.contains(where: { $0.contains("/") }), "no string value in the public report contains '/'")
    }

    // Error (an N-1 negative case): a report naming six of AgentMenu's seven
    // shipped scenarios — public itself does not know the expected count
    // (that is harness/gate.sh's job, tested in HarnessGateTests.swift), but
    // it must faithfully carry whatever `scenarios` the fold gave it, never
    // padding a short list up to what the app ships nor silently hiding
    // that it is short — so a caller checking coverage against
    // report.public.json sees the true shortfall.
    do {
        let dir = TempDir("report-public-short-list")
        defer { dir.cleanup() }
        let liveSeven = ["vanilla-first-run", "launch-terminal", "no-agent", "profile-work-only",
                          "profile-personal-only", "profile-both", "bridge-install"]
        let sixOfSeven = liveSeven.filter { $0 != "bridge-install" } // one short, bridge-install dropped
        var runs: [String] = []
        for name in sixOfSeven {
            runs.append(writeReportFixtureRun(
                dir, name: "r-\(name)", scenario: name, reportNonce: "N", journalNonce: "N",
                verdict: "pass", outcome: "pass", findings: []
            ))
        }
        let folded = dir.path("gate/report.json")
        var foldArgs = ["fold", "--out", folded, "--findings-file", findingsTXT]
        for r in runs { foldArgs += ["--run-dir", r] }
        t.expectEqual(reportRun(reportSH, foldArgs).status, 0, "six passing runs still fold cleanly on their own")

        let publicPath = dir.path("gate/report.public.json")
        t.expectEqual(reportRun(reportSH, ["public", "--report", folded, "--out", publicPath]).status, 0, "public still succeeds")
        guard let obj = readJSON(publicPath) else { t.expect(false, "report.public.json was written"); return }
        let scenarios = obj["scenarios"] as? [String] ?? []
        t.expectEqual(scenarios.count, liveSeven.count - 1, "the public report honestly carries six names, not seven — coverage is gate.sh's own refusal")
        t.expect(!scenarios.contains("bridge-install"), "the dropped scenario is genuinely absent, not silently backfilled")
        t.expectEqual(Set(scenarios), Set(sixOfSeven), "the public report carries exactly the six it was given, nothing padded or substituted")
    }

    // Usage: public needs --report and --out; a missing report refuses.
    do {
        let dir = TempDir("report-public-usage")
        defer { dir.cleanup() }
        t.expectEqual(reportRun(reportSH, ["public", "--out", dir.path("o.json")]).status, 2, "public with no --report is a usage error")
        t.expectEqual(reportRun(reportSH, ["public", "--report", dir.path("nope.json"), "--out", dir.path("o.json")]).status, 2, "public against a missing report is a usage error")
    }
}

// MARK: - decide (report-only decidability)

private func runReportDecideTests(_ t: TestRunner, _ root: URL, _ reportSH: String) {
    // A check script reads report.json alone and reproduces the verdict —
    // proven here by deleting the run directories and screenshots entirely
    // before calling `decide`, leaving only the one compiled file on disk.
    do {
        let dir = TempDir("report-decide")
        defer { dir.cleanup() }
        let run = writeReportFixtureRun(
            dir, name: "r1", scenario: "vanilla-first-run", reportNonce: "N", journalNonce: "N",
            verdict: "pass", outcome: "pass", findings: ["dialog-confirm-retry-2"]
        )
        let folded = dir.path("gate/report.json")
        t.expectEqual(reportRun(reportSH, ["fold", "--out", folded, "--run-dir", run]).status, 0, "the fixture folds to a pass")

        // Only the compiled report survives; the run directory (journal,
        // steps, screenshots) is gone.
        try? FileManager.default.removeItem(atPath: run)
        t.expect(!FileManager.default.fileExists(atPath: run), "the run directory really is gone")

        let decided = reportRun(reportSH, ["decide", "--report", folded])
        t.expectEqual(decided.status, 0, "decide reproduces the pass verdict with no screenshots or journal on disk")
        t.expect(decided.stdout.contains("verdict: pass"), "decide prints the verdict — got: \(decided.stdout)")
    }

    do {
        let dir = TempDir("report-decide-fail")
        defer { dir.cleanup() }
        let run = writeReportFixtureRun(
            dir, name: "r1", scenario: "launch-terminal", reportNonce: "N", journalNonce: "N",
            verdict: "fail", outcome: "scenario_fail", findings: [], exitCode: 1
        )
        let folded = dir.path("gate/report.json")
        t.expectEqual(reportRun(reportSH, ["fold", "--out", folded, "--run-dir", run]).status, 1, "the fixture folds to a fail")
        t.expectEqual(reportRun(reportSH, ["decide", "--report", folded]).status, 1, "decide mirrors the fail")
    }

    // Usage.
    do {
        t.expectEqual(reportRun(reportSH, ["decide"]).status, 2, "decide with no --report is a usage error")
        t.expectEqual(reportRun(reportSH, ["decide", "--report", "/no/such/file.json"]).status, 2, "decide against a missing file is a usage error")
    }
}
