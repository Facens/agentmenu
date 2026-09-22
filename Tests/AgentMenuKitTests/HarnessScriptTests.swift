// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// R1, R2, R14, R18 / KTD5, KTD6: `harness/run.sh` detaches a supervisor that
/// owns a VM clone and has to give it back — on a finished run, on a watchdog's
/// SIGTERM, on Ctrl-C, and, through `clean`, after a SIGKILL that ran no trap
/// at all. None of that is observable from the script's return value, which is
/// why every scenario here drives the real script with a stub `tart`, `ssh` and
/// `scp` on PATH and then reads what it left behind: `report.json`, the run
/// directory, and the log of every `tart` call the stub recorded.
///
/// The stubs live in a `TempDir` and `HARNESS_DIST_ROOT` points the run root at
/// the same place, so nothing here touches the repository's own `dist/`, and
/// `tart` itself is never installed — the point of a stub is that the VM path
/// is exercised on a machine that has no VMs.
///
/// This suite does not skip. The prebuilt-binary guards elsewhere in these
/// tests report "(skipped)" and pass when `.build/debug/AgentMenuCLI` is
/// absent; that is right for a binary a clean checkout has not built yet, and
/// wrong for a script that is committed. A missing `harness/run.sh`, or a
/// missing `harness/SHARED.sha256`, is a failure here.
func runHarnessScriptTests(_ t: TestRunner) {
    t.suite("HarnessScript")

    let root = repositoryRoot()
    let runScript = root.appendingPathComponent("harness/run.sh").path
    guard FileManager.default.isExecutableFile(atPath: runScript) else {
        t.expect(false, "harness/run.sh is missing or not executable at \(runScript) — this suite fails rather than skipping")
        return
    }
    guard toolOnPath("jq") != nil else {
        t.expect(false, "jq is not on PATH — the harness reports are compiled with it")
        return
    }

    runHarnessSyntaxTests(t, root)
    runHarnessStartValidationTests(t, root)
    runHarnessHappyPathTests(t, root)
    runHarnessScenarioFailureTests(t, root)
    runHarnessWatchdogTests(t, root)
    runHarnessRetryTests(t, root)
    runHarnessStaleSupervisorTests(t, root)
    runHarnessTwoGuestTests(t, root)
    runHarnessSelfcheckTests(t, root)
    runHarnessAppFreshTests(t, root)
    runHarnessSharedManifestTests(t, root)
    runHarnessSyncCheckTests(t, root)
}

// MARK: - The scripts parse, and the files the unit promises are there

private func runHarnessSyntaxTests(_ t: TestRunner, _ root: URL) {
    let scripts = [
        "harness/run.sh",
        "harness/sync-check.sh",
        "harness/lib/common.sh",
        "harness/lib/vm.sh",
        "harness/lib/watchdog.sh",
        "harness/lib/appfresh.sh",
        "harness/lib/snapshot.sh",
    ]
    for script in scripts {
        let path = root.appendingPathComponent(script).path
        guard FileManager.default.fileExists(atPath: path) else {
            t.expect(false, "\(script) is missing")
            continue
        }
        let parsed = runProcess("/bin/bash", ["-n", path])
        t.expectEqual(parsed.status, 0, "\(script) parses — \(parsed.stderr)")
    }
    t.expect(
        FileManager.default.fileExists(atPath: root.appendingPathComponent("harness/README.md").path),
        "harness/README.md documents the command surface and the scenario contract"
    )

    // The help text is the header comment, and `sed -n '2,NNp'` drifts silently
    // when the header grows. It is checked by content, not by line count.
    let help = runProcess(root.appendingPathComponent("harness/run.sh").path, ["--help"])
    t.expectEqual(help.status, 0, "run.sh --help exits 0")
    for phrase in ["start --app", "wait <run-id>", "status <run-id>", "selfcheck --tier", "clean ["] {
        t.expect(help.stdout.contains(phrase), "run.sh --help names '\(phrase)'")
    }
    t.expect(!help.stdout.contains("#!/bin/bash"), "the help text strips the comment markers rather than dumping the file")
}

// MARK: - Usage errors refuse before anything exists

private func runHarnessStartValidationTests(_ t: TestRunner, _ root: URL) {
    guard let rig = makeHarnessRig("harness-usage", root, t) else { return }
    defer { rig.dir.cleanup() }

    let refusals: [(String, [String], String)] = [
        ("an unknown app", ["start", "--app", "nope", "--tier", "stranger", "--scenario", "pass", "--asset", rig.assetPath], "unknown app"),
        ("a missing asset", ["start", "--app", "agentmenu", "--tier", "stranger", "--scenario", "pass", "--asset", rig.dir.path("absent.zip")], "not a readable file"),
        ("no asset at all", ["start", "--app", "agentmenu", "--tier", "stranger", "--scenario", "pass"], "--asset is required"),
        ("an unknown scenario", ["start", "--app", "agentmenu", "--tier", "stranger", "--scenario", "nosuch", "--asset", rig.assetPath], "no scenario 'nosuch'"),
        ("an unknown tier", ["start", "--app", "agentmenu", "--tier", "vm", "--scenario", "pass", "--asset", rig.assetPath], "unknown tier"),
        ("an unknown argument", ["start", "--app", "agentmenu", "--tier", "stranger", "--scenario", "pass", "--asset", rig.assetPath, "--bogus"], "unknown argument"),
        ("a flag with no value", ["start", "--app"], "needs a value"),
    ]
    for (what, args, expected) in refusals {
        let result = harnessRun(rig, args)
        t.expectEqual(result.status, 2, "\(what) is a usage error — stderr: \(result.stderr)")
        t.expect(result.stderr.contains(expected), "the refusal for \(what) says '\(expected)' — got: \(result.stderr)")
    }
    t.expectEqual(harnessRunDirectories(rig).count, 0, "a refused start writes nothing under the run root")
    t.expect(!harnessCallLog(rig).contains("tart clone"), "a refused start clones nothing")

    // Unknown run ids, and a run id that would escape the run root.
    for args in [["status", "no-such-run"], ["wait", "no-such-run"], ["status", "../escape"]] {
        let result = harnessRun(rig, args)
        t.expectEqual(result.status, 2, "'\(args.joined(separator: " "))' is a usage error — \(result.stderr)")
    }
}

// MARK: - Happy path

private func runHarnessHappyPathTests(_ t: TestRunner, _ root: URL) {
    guard let rig = makeHarnessRig("harness-pass", root, t) else { return }
    defer { rig.dir.cleanup() }

    let start = harnessRun(rig, ["start", "--app", "agentmenu", "--tier", "stranger", "--scenario", "pass", "--asset", rig.assetPath])
    t.expectEqual(start.status, 0, "start on a scenario that passes exits 0 — stderr: \(start.stderr)")
    let runID = start.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    t.expect(
        runID.range(of: "^agentmenu-stranger-pass-[0-9]{8}T[0-9]{6}Z-[0-9a-f]{6}$", options: .regularExpression) != nil,
        "stdout is the run id in the agreed shape — got '\(runID)'"
    )
    t.expect(start.stdout.split(separator: "\n").count == 1, "start prints the run id and nothing else on stdout")

    let waited = harnessRun(rig, ["wait", runID, "--max-secs", "90"])
    t.expectEqual(waited.status, 0, "wait mirrors the supervisor's 0 — stdout: \(waited.stdout) stderr: \(waited.stderr)")

    guard let report = harnessReport(rig, runID) else {
        t.expect(false, "the run wrote a report.json")
        return
    }
    t.expectEqual(report["verdict"] as? String, "pass", "verdict is pass")
    t.expectEqual(report["outcome_kind"] as? String, "pass", "outcome_kind is pass")
    t.expectEqual(report["status"] as? String, "finished", "status is finished")
    t.expectEqual(report["stale"] as? Bool, false, "a supervisor that exited normally is not stale")
    t.expectEqual(report["exit_code"] as? Int, 0, "the exit code is recorded in the report, not left to the wait builtin")
    t.expectEqual(report["retries"] as? Int, 0, "a run that worked first time records no retry")
    t.expectEqual(report["run_id"] as? String, runID, "the report carries its own run id")
    t.expect((report["supervisor_pid"] as? Int ?? 0) > 0, "the supervisor's PID is recorded")
    t.expect((report["supervisor_token"] as? String ?? "").isEmpty == false, "a start token is recorded alongside the PID")
    t.expect((report["nonce"] as? String ?? "").count >= 16, "the run carries a nonce for the journal to echo")
    t.expectEqual((report["asset_sha256"] as? String)?.count, 64, "the asset is hashed into the report")
    t.expectEqual((report["steps"] as? [Any])?.count, 2, "both of the scenario's steps reached steps[]")
    t.expectEqual(report["findings"] as? [String] ?? [], ["dialog-confirm-retry-2"], "a passing run still carries its finding")
    t.expectEqual(report["image"] as? [String: Any] != nil, true, "the golden image's build inputs are recorded")

    // Evidence the supervisor really drove the VM path, and gave the clone back.
    let calls = harnessCallLog(rig)
    let clone = "first-run-harness-\(runID)"
    t.expect(calls.contains("tart clone first-run-golden \(clone)"), "the supervisor cloned the golden image")
    t.expect(calls.contains("tart run --no-graphics \(clone)"), "it booted the clone with no graphics")
    t.expect(calls.contains("tart ip \(clone)"), "it polled for the guest's IP")
    t.expect(calls.contains("tart delete \(clone)"), "the trap deleted the clone")
    t.expectEqual(harnessVMs(rig), ["first-run-golden"], "nothing but the golden image is left behind")

    // The guest tree reached the guest, and the remote path went over the wire
    // the way sftp-server reads it: verbatim, unquoted. Quoting it is what
    // stopped every stranger run at copy-in before the scp stub checked.
    t.expect(calls.contains("admin@127.0.0.1:.harness/"), "the guest tree is copied in with a bare remote path — got: \(calls)")
    t.expect(
        calls.range(of: "admin@127\\.0\\.0\\.1:['\"]", options: .regularExpression) == nil,
        "no scp remote path is shell-quoted; the far side is sftp-server, which takes it verbatim"
    )

    for file in ["report.json", "journal.ndjson", "evidence.ndjson", "steps.ndjson", "supervisor.pid", "supervisor.log", "clone.name"] {
        t.expect(
            FileManager.default.fileExists(atPath: "\(rig.distRoot)/\(runID)/\(file)"),
            "the run directory carries \(file)"
        )
    }

    let status = harnessRun(rig, ["status", runID])
    t.expectEqual(status.status, 0, "status is a query and exits 0")
    t.expect(status.stdout.contains("verdict:    pass"), "status reports the verdict — got: \(status.stdout)")
    t.expect(status.stdout.contains("step:       setup card"), "status reports the last step it recorded")
    t.expect(status.stdout.contains("002-setup.png"), "status reports the last screenshot")

    let json = harnessRun(rig, ["status", runID, "--json"])
    t.expectEqual(json.status, 0, "status --json exits 0")
    t.expect(json.stdout.contains("\"verdict\""), "status --json prints the report")
}

// MARK: - A scenario that fails is a failed run, not a broken harness

private func runHarnessScenarioFailureTests(_ t: TestRunner, _ root: URL) {
    guard let rig = makeHarnessRig("harness-fail", root, t) else { return }
    defer { rig.dir.cleanup() }

    let start = harnessRun(rig, ["start", "--app", "agentmenu", "--tier", "stranger", "--scenario", "fail", "--asset", rig.assetPath])
    t.expectEqual(start.status, 0, "start succeeds even though the scenario will fail")
    let runID = start.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    let waited = harnessRun(rig, ["wait", runID, "--max-secs", "90"])
    t.expectEqual(waited.status, 1, "a scenario that exits 1 makes wait exit 1")

    let report = harnessReport(rig, runID)
    t.expectEqual(report?["verdict"] as? String, "fail", "verdict is fail")
    t.expectEqual(report?["outcome_kind"] as? String, "scenario_fail", "outcome_kind separates a failed scenario from a broken harness")
    t.expectEqual(report?["exit_code"] as? Int, 1, "the exit code is 1")
    t.expectEqual(report?["retries"] as? Int, 0, "a failed scenario is never retried")
    t.expectEqual(harnessCallLog(rig).components(separatedBy: "tart clone").count - 1, 1, "exactly one clone was made")
    t.expect(harnessCallLog(rig).contains("tart delete"), "the clone was still deleted")
}

// MARK: - The per-scenario watchdog

private func runHarnessWatchdogTests(_ t: TestRunner, _ root: URL) {
    guard let rig = makeHarnessRig("harness-watchdog", root, t, scenarioTimeout: 3) else { return }
    defer { rig.dir.cleanup() }

    let start = harnessRun(rig, ["start", "--app", "agentmenu", "--tier", "stranger", "--scenario", "hang", "--asset", rig.assetPath])
    t.expectEqual(start.status, 0, "start on a scenario that will hang exits 0")
    let runID = start.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    let began = Date()
    let waited = harnessRun(rig, ["wait", runID, "--max-secs", "90"])
    let elapsed = Date().timeIntervalSince(began)
    t.expectEqual(waited.status, 3, "a scenario killed by its watchdog is a harness error (3)")
    t.expect(elapsed < 60, "the watchdog killed it in about its bound, not the scenario's 120s sleep (took \(Int(elapsed))s)")

    let report = harnessReport(rig, runID)
    t.expectEqual(report?["outcome_kind"] as? String, "harness_error", "outcome_kind is harness_error")
    t.expectEqual(report?["verdict"] as? String, "error", "the verdict is error, not fail: the scenario never decided")
    t.expectEqual(report?["exit_code"] as? Int, 3, "the exit code is 3")
    t.expectEqual(report?["stale"] as? Bool, false, "the supervisor did run its trap, so the run is not stale")
    t.expect(
        FileManager.default.fileExists(atPath: "\(rig.distRoot)/\(runID)/watchdog-scenario.fired"),
        "the watchdog left the marker that tells a hang from a failure"
    )
    t.expect(harnessCallLog(rig).contains("tart delete first-run-harness-\(runID)"), "the trap deleted the clone after the watchdog fired")
    t.expectEqual(harnessVMs(rig), ["first-run-golden"], "no clone survives the watchdog")
}

// MARK: - Infrastructure retries, exactly once

private func runHarnessRetryTests(_ t: TestRunner, _ root: URL) {
    guard let rig = makeHarnessRig("harness-retry", root, t) else { return }
    defer { rig.dir.cleanup() }

    // The stub fails the first clone and succeeds on the second.
    FileManager.default.createFile(atPath: "\(rig.state)/clone-fail-once", contents: Data())

    let start = harnessRun(rig, ["start", "--app", "agentmenu", "--tier", "stranger", "--scenario", "pass", "--asset", rig.assetPath])
    t.expectEqual(start.status, 0, "start exits 0 even though the first clone will fail")
    let runID = start.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    let waited = harnessRun(rig, ["wait", runID, "--max-secs", "90"])
    t.expectEqual(waited.status, 0, "a clone that failed once and then worked still passes")

    let report = harnessReport(rig, runID)
    t.expectEqual(report?["retries"] as? Int, 1, "the retry is recorded in the report")
    t.expectEqual(report?["verdict"] as? String, "pass", "the verdict is unaffected by an infrastructure retry")
    t.expectEqual(harnessCallLog(rig).components(separatedBy: "tart clone").count - 1, 2, "the clone was attempted twice")
}

// MARK: - A supervisor that never ran its trap

private func runHarnessStaleSupervisorTests(_ t: TestRunner, _ root: URL) {
    // A SIGKILLed supervisor runs no trap, so its watchdogs and the scenario
    // outlive it — briefly: the orphaned watchdogs still reap the scenario at
    // their own bounds, which is why those bounds are short here rather than
    // left to linger after the suite has finished.
    guard let rig = makeHarnessRig("harness-stale", root, t, scenarioTimeout: 30, runTimeout: 60) else { return }
    defer { rig.dir.cleanup() }

    let start = harnessRun(rig, ["start", "--app", "agentmenu", "--tier", "stranger", "--scenario", "hang", "--asset", rig.assetPath])
    t.expectEqual(start.status, 0, "start exits 0")
    let runID = start.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let clone = "first-run-harness-\(runID)"

    // Wait until the clone actually exists, so what `clean` sweeps afterwards
    // is a clone no trap could have removed rather than one never created.
    let cloned = harnessWaitUntil(30) { FileManager.default.fileExists(atPath: "\(rig.state)/vms/\(clone)") }
    t.expect(cloned, "the supervisor got as far as cloning the golden image")

    guard let pidText = try? String(contentsOfFile: "\(rig.distRoot)/\(runID)/supervisor.pid", encoding: .utf8),
          let pid = pidText.split(separator: "\n").first.map(String.init) else {
        t.expect(false, "the run directory records the supervisor's PID")
        return
    }
    let killed = runProcess("/bin/kill", ["-9", pid])
    t.expectEqual(killed.status, 0, "SIGKILLed the supervisor — no trap can run")
    _ = harnessWaitUntil(10) { runProcess("/bin/kill", ["-0", pid]).status != 0 }

    let status = harnessRun(rig, ["status", runID])
    t.expectEqual(status.status, 0, "status still answers for a run whose supervisor is gone")
    t.expect(status.stdout.contains("harness_error"), "status resolves a vanished supervisor to harness_error — got: \(status.stdout)")
    t.expect(status.stdout.contains("stale:      true"), "status says the run is stale — got: \(status.stdout)")

    let report = harnessReport(rig, runID)
    t.expectEqual(report?["stale"] as? Bool, true, "the resolution is written into the report, not only printed")
    t.expectEqual(report?["outcome_kind"] as? String, "harness_error", "outcome_kind is harness_error")
    t.expectEqual(report?["exit_code"] as? Int, 3, "a stale run resolves to exit 3")

    let waited = harnessRun(rig, ["wait", runID, "--max-secs", "30"])
    t.expectEqual(waited.status, 3, "wait on a stale run mirrors 3 rather than blocking forever")

    // The clone the trap could not delete is what `clean` is for.
    t.expect(harnessVMs(rig).contains(clone), "the SIGKILL left the clone behind")
    let cleaned = harnessRun(rig, ["clean"])
    t.expectEqual(cleaned.status, 0, "clean exits 0 — \(cleaned.stderr)")
    t.expect(cleaned.stdout.contains(clone), "clean names the orphan it swept — got: \(cleaned.stdout)")
    t.expect(harnessCallLog(rig).contains("tart delete \(clone)"), "clean deleted the orphaned clone")
    t.expect(!harnessVMs(rig).contains(clone), "the orphan is gone")
    t.expect(harnessVMs(rig).contains("first-run-golden"), "clean leaves the golden image alone")
}

// MARK: - Two guests is the host's limit

private func runHarnessTwoGuestTests(_ t: TestRunner, _ root: URL) {
    guard let rig = makeHarnessRig("harness-two-guests", root, t) else { return }
    defer { rig.dir.cleanup() }

    // Two running VMs of any name — the maintainer's own take the same slots —
    // and two stopped harness clones, which take none.
    harnessSeedVM(rig, "maintainer-vm-1", state: "running")
    harnessSeedVM(rig, "maintainer-vm-2", state: "running")
    harnessSeedVM(rig, "first-run-harness-old-a", state: "stopped")
    harnessSeedVM(rig, "first-run-harness-old-b", state: "stopped")

    let refused = harnessRun(rig, ["start", "--app", "agentmenu", "--tier", "stranger", "--scenario", "pass", "--asset", rig.assetPath])
    t.expectEqual(refused.status, 2, "a third guest is refused as a usage error — stderr: \(refused.stderr)")
    t.expect(refused.stderr.contains("two macOS guests are already running"), "the refusal is the two-guest message")
    t.expect(refused.stderr.contains("maintainer-vm-1") && refused.stderr.contains("maintainer-vm-2"), "it names what is running")
    t.expect(refused.stderr.contains("first-run-harness-old-a") && refused.stderr.contains("first-run-harness-old-b"), "it names the stopped harness clones")
    t.expect(refused.stderr.contains("clean"), "it points at clean for the stopped clones")
    t.expect(!harnessCallLog(rig).contains("tart clone"), "the refusal clones nothing")
    t.expectEqual(harnessRunDirectories(rig).count, 0, "the refusal writes nothing under the run root")

    // With the running pair gone, the same two stopped clones do not block.
    harnessRemoveVM(rig, "maintainer-vm-1")
    harnessRemoveVM(rig, "maintainer-vm-2")
    let started = harnessRun(rig, ["start", "--app", "agentmenu", "--tier", "stranger", "--scenario", "pass", "--asset", rig.assetPath])
    t.expectEqual(started.status, 0, "stopped harness clones do not block a start — stderr: \(started.stderr)")
    t.expect(started.stderr.contains("first-run-harness-old-a"), "the start still names the stopped clones it saw")
    t.expect(started.stderr.contains("clean"), "and still points at clean")

    let runID = started.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let waited = harnessRun(rig, ["wait", runID, "--max-secs", "90"])
    t.expectEqual(waited.status, 0, "the run itself passes")
}

// MARK: - selfcheck

/// `selfcheck` is the fifth command of the unit and the Verification
/// Contract's done signal for the in-guest driver, but what it runs —
/// `harness/guest/selfcheck.sh` — belongs to another unit's file, this one
/// only orchestrates it. So the script is exercised against a copy of
/// `harness/` in a TempDir carrying a stand-in guest script: `run.sh`
/// resolves its own root from `BASH_SOURCE`, so the copy is a working
/// harness, and this suite proves run.sh's own orchestration (what it
/// passes to guest/selfcheck.sh and how it renders what comes back)
/// without needing a live AX probe for that — HarnessGuestTests.swift
/// exercises the real guest/selfcheck.sh and ax.applescript directly. The
/// stand-in's own JSON must still match guest/selfcheck.sh's real six-key
/// contract (its own header documents the shape): a stand-in that drifted
/// from it was U-defect-3 — this suite agreeing with the wrong side of the
/// contract while proving nothing about the real script.
private func runHarnessSelfcheckTests(_ t: TestRunner, _ root: URL) {
    guard let rig = makeHarnessRig("harness-selfcheck", root, t) else { return }
    defer { rig.dir.cleanup() }

    let copied = runProcess("/bin/cp", ["-R", root.appendingPathComponent("harness").path, rig.dir.path("harness")])
    guard copied.status == 0 else {
        t.expect(false, "copied harness/ into a scratch checkout: \(copied.stderr)")
        return
    }
    let script = rig.dir.path("harness/run.sh")

    // U-defect-3: the stand-in prints exactly the six keys the real
    // harness/guest/selfcheck.sh does (its own header documents the shape)
    // — {"ok":true,"grants":[...]} was itself the defect: run.sh's summary
    // agreed with the wrong side of the contract and the test proved
    // nothing about the real script. It also logs its own argv, so a test
    // here can check exactly which --list-ids value run.sh passed through,
    // without needing a live AX probe.
    let guestCallLog = rig.dir.path("guest-selfcheck-calls.log")
    let guestStub = """
    #!/bin/bash
    printf '%s\\n' "$*" >> "\(guestCallLog)"
    echo '{"screencapture":true,"system_events":true,"automation":true,"statusitem_idiom":"app-menu-bar-2","identifiers":["setup.card","setup.continue"],"popover_survived":true}'
    exit 0
    """
    do {
        try rig.dir.write(guestStub + "\n", to: "harness/guest/selfcheck.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.dir.path("harness/guest/selfcheck.sh"))
    } catch {
        t.expect(false, "wrote a stand-in guest selfcheck: \(error)")
        return
    }

    // The plan's tier decision: only the stranger tier drives the screen,
    // and this self-check exists to prove screen grants by clicking the
    // status item and taking a screenshot — so app-fresh refuses it
    // outright (exit 2), rather than the U-defect-4 launch-and-probe this
    // replaces (an isolated instance launched and its status item pressed
    // by pid — the very incident that made this a refusal: two menu-bar
    // icons clicking themselves while the maintainer was away).
    // appFreshStubBundle/appFreshFixtureHome are reused from the U13 tests
    // below not to prove a launch succeeds, but the opposite — that even
    // with a real bundle and a real fixture home sitting right there,
    // nothing gets built, launched or touched.
    guard let bundle = appFreshStubBundle(rig.dir, t) else { return }
    guard let home = appFreshFixtureHome(rig.dir, t) else { return }
    let appFreshEnv = [
        "HARNESS_APPFRESH_APP": bundle,
        "HARNESS_SNAPSHOT_HOME": home,
        "HARNESS_SNAPSHOT_DOMAIN": "com.appfresh.tests.selfcheck.\(UUID().uuidString)",
        "HARNESS_APPFRESH_LAUNCH_TIMEOUT": "15",
    ]

    let beforeAppFresh = Set(harnessRunDirectories(rig))
    let appFreshRefused = harnessRun(rig, ["selfcheck", "--tier", "app-fresh"], script: script, extraEnvironment: appFreshEnv)
    t.expectEqual(appFreshRefused.status, 2, "selfcheck on the app-fresh tier is a usage error — stdout: \(appFreshRefused.stdout) stderr: \(appFreshRefused.stderr)")
    t.expect(appFreshRefused.stderr.contains("app-fresh"), "the refusal names the tier — got: \(appFreshRefused.stderr)")
    t.expect(appFreshRefused.stderr.contains("screen"), "the refusal says this self-check drives the screen — got: \(appFreshRefused.stderr)")
    t.expectEqual(Set(harnessRunDirectories(rig)), beforeAppFresh, "the refusal wrote no run directory — nothing was built, launched or probed")
    t.expect(!harnessCallLog(rig).contains("tart"), "the refusal never touches tart")
    let callsAfterRefusal = (try? String(contentsOfFile: guestCallLog, encoding: .utf8)) ?? ""
    t.expect(callsAfterRefusal.isEmpty, "guest/selfcheck.sh was never called — got calls: \(callsAfterRefusal)")

    // --list-ids changes nothing: the refusal fires before it is even
    // looked at, exactly like the stranger-only-scenario and --verbose
    // refusals in runAppFreshRefusalTests below fire before a run
    // directory exists.
    let appFreshListIdsRefused = harnessRun(rig, ["selfcheck", "--tier", "app-fresh", "--list-ids", "dev.facens.agentmenu"], script: script, extraEnvironment: appFreshEnv)
    t.expectEqual(appFreshListIdsRefused.status, 2, "app-fresh still refuses with --list-ids given — stderr: \(appFreshListIdsRefused.stderr)")
    t.expectEqual(Set(harnessRunDirectories(rig)), beforeAppFresh, "still no run directory")

    // The stranger tier clones a guest for it and gives the clone back. It
    // never touches lib/appfresh.sh (only one instance ever exists there),
    // so it needs none of the app-fresh environment above.
    let stranger = harnessRun(rig, ["selfcheck", "--tier", "stranger"], script: script)
    t.expectEqual(stranger.status, 0, "selfcheck on the stranger tier exits 0 — \(stranger.stderr)")
    t.expect(stranger.stdout.contains("grants:      screencapture=true, system_events=true"), "the stranger tier's summary uses the same real shape — got: \(stranger.stdout)")
    t.expect(harnessCallLog(rig).contains("tart clone first-run-golden first-run-harness-selfcheck-stranger-"), "it cloned the golden image")
    t.expect(harnessCallLog(rig).contains("tart delete first-run-harness-selfcheck-stranger-"), "and deleted the clone on the way out")
    t.expectEqual(harnessVMs(rig), ["first-run-golden"], "no clone is left behind")

    // The stranger run leaves a finished report, not a half-written one —
    // `clean` and `status` read the same shape here as for a scenario run.
    // Both app-fresh refusals above wrote no run directory at all, so the
    // stranger tier is the only report to find.
    var reports = 0
    for runID in harnessRunDirectories(rig) {
        guard let report = harnessReport(rig, runID) else {
            t.expect(false, "selfcheck run \(runID) has a readable report.json")
            continue
        }
        reports += 1
        t.expectEqual(report["status"] as? String, "finished", "\(runID) is finished")
        t.expectEqual(report["verdict"] as? String, "pass", "\(runID) passed")
        t.expectEqual(report["exit_code"] as? Int, 0, "\(runID) records its exit code")
        t.expectEqual(report["scenario"] as? String, "selfcheck", "\(runID) records what it was")
        t.expect((report["supervisor_pid"] as? Int ?? 0) > 0, "\(runID) records its own PID, so clean can tell a live selfcheck's clone from an orphan")
    }
    t.expectEqual(reports, 1, "only the stranger selfcheck run wrote a report — both app-fresh refusals wrote none")

    let refused = harnessRun(rig, ["selfcheck", "--tier", "bogus"], script: script)
    t.expectEqual(refused.status, 2, "an unknown tier is a usage error")
}

// MARK: - U13: the app-fresh tier
//
// None of this launches the real AgentMenu binary or touches the
// maintainer's real ~/.config/agentmenu, ~/.claude*, or dev.facens.agentmenu
// — every run here points HARNESS_APPFRESH_APP at a bash stub standing in
// for the bundle (never harness/lib/appfresh.sh's own make-bundle path) and
// HARNESS_SNAPSHOT_HOME/HARNESS_SNAPSHOT_DOMAIN at fixtures this suite owns
// and removes. The one exception is read-only: snapshot.sh's own default
// domain name (never its content) is asserted to be dev.facens.agentmenu,
// see runAppFreshSnapshotUnitTests.
//
// harness/scenarios/ is off limits to this unit (it owns only
// harness/lib/appfresh.sh, harness/lib/snapshot.sh, the app-fresh switch in
// harness/run.sh, and this file), and only smoke.sh — a stranger-tier
// scenario — exists in this checkout. The plan's own "profile-both" happy
// path (U9, not yet built) is therefore not runnable here; these tests
// exercise the tier machinery itself with the rig's existing app-agnostic
// "pass" scenario stub instead, which already proves steps/findings flow
// through unchanged under HARNESS_GUEST_TRANSPORT=local.
private func runHarnessAppFreshTests(_ t: TestRunner, _ root: URL) {
    guard FileManager.default.fileExists(atPath: root.appendingPathComponent("harness/lib/appfresh.sh").path) else {
        t.expect(false, "harness/lib/appfresh.sh is missing — this suite fails rather than skipping")
        return
    }
    guard FileManager.default.fileExists(atPath: root.appendingPathComponent("harness/lib/snapshot.sh").path) else {
        t.expect(false, "harness/lib/snapshot.sh is missing — this suite fails rather than skipping")
        return
    }
    runAppFreshRefusalTests(t, root)
    runAppFreshSnapshotUnitTests(t, root)
    runAppFreshSnapshotExclusionTests(t, root)
    runAppFreshEnvironmentWiringTests(t, root)
    runAppFreshHappyPathTests(t, root)
    runAppFreshSnapshotMismatchTests(t, root)
    runAppFreshCleanTests(t, root)
}

// MARK: - Refusals before anything launches (AE11's own tier, exit 2)

private func runAppFreshRefusalTests(_ t: TestRunner, _ root: URL) {
    guard let rig = makeHarnessRig("appfresh-refusal", root, t) else { return }
    defer { rig.dir.cleanup() }

    let strangerOnly = """
    #!/bin/bash
    # HARNESS_STRANGER_ONLY: needs a real permission prompt; not simulable on app-fresh.
    set -euo pipefail
    exit 0
    """
    do {
        try rig.dir.write(strangerOnly + "\n", to: "scenarios/agentmenu/stranger-only.sh")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: rig.dir.path("scenarios/agentmenu/stranger-only.sh"))
    } catch {
        t.expect(false, "wrote a stranger-only scenario fixture: \(error)")
        return
    }

    let strangerRefused = appFreshRun(rig, ["start", "--app", "agentmenu", "--tier", "app-fresh", "--scenario", "stranger-only"])
    t.expectEqual(strangerRefused.status, 2, "a stranger-only scenario on app-fresh is a usage error — stderr: \(strangerRefused.stderr)")
    t.expect(strangerRefused.stderr.contains("stranger-only"), "the refusal calls the scenario stranger-only — got: \(strangerRefused.stderr)")
    t.expect(strangerRefused.stderr.contains("app-fresh"), "the refusal names the tier — got: \(strangerRefused.stderr)")

    let verboseRefused = appFreshRun(rig, ["start", "--app", "agentmenu", "--tier", "app-fresh", "--scenario", "pass", "--verbose"])
    t.expectEqual(verboseRefused.status, 2, "--verbose on app-fresh is a usage error — stderr: \(verboseRefused.stderr)")
    t.expect(verboseRefused.stderr.contains("--verbose"), "the refusal names --verbose — got: \(verboseRefused.stderr)")
    t.expect(verboseRefused.stderr.contains("app-fresh"), "the refusal names the tier — got: \(verboseRefused.stderr)")

    t.expectEqual(harnessRunDirectories(rig).count, 0, "both refusals leave nothing under the run root — before any app launches")
    t.expect(!harnessCallLog(rig).contains("tart"), "neither refusal touches tart")
}

// MARK: - the exclusion is narrow, recorded, and never hides an escape

private func runAppFreshSnapshotExclusionTests(_ t: TestRunner, _ root: URL) {
    let dir = TempDir("appfresh-snapshot-exclude")
    defer { dir.cleanup() }

    let commonScript = root.appendingPathComponent("harness/lib/common.sh").path
    let snapshotScript = root.appendingPathComponent("harness/lib/snapshot.sh").path
    do {
        try dir.write("role = \"maintainer\"\n", to: "home/.config/agentmenu/config.toml")
        try dir.write("{\"a\":1}\n", to: "home/.claude-personal/settings.json")
        try dir.write("first\n", to: "home/.claude-personal/projects/p/scratch.txt")
    } catch {
        t.expect(false, "wrote a fixture maintainer home: \(error)")
        return
    }

    let domain = "com.appfresh.tests.exclusion.\(UUID().uuidString)"
    let scratchGlob = dir.path("home/.claude-personal/projects/p/*")

    func take(_ name: String, excluding: String?) -> CLIResult {
        var env = ["HARNESS_SNAPSHOT_HOME": dir.path("home"), "HARNESS_SNAPSHOT_DOMAIN": domain]
        if let excluding { env["HARNESS_SNAPSHOT_EXCLUDE"] = excluding }
        let script = """
        set -euo pipefail
        . "\(commonScript)"
        . "\(snapshotScript)"
        snapshot_take "\(dir.path(name))"
        """
        return runProcess("/bin/bash", ["-c", script], environment: env)
    }
    func compare(_ a: String, _ b: String) -> CLIResult {
        let script = """
        set -euo pipefail
        . "\(commonScript)"
        . "\(snapshotScript)"
        snapshot_compare "\(dir.path(a))" "\(dir.path(b))"
        """
        return runProcess("/bin/bash", ["-c", script])
    }

    // Without an exclusion, churn the app did not cause still fails the run.
    // That is the default and it is the safe one.
    _ = take("plain-before.tsv", excluding: nil)
    try? "second\n".write(toFile: dir.path("home/.claude-personal/projects/p/scratch.txt"), atomically: true, encoding: .utf8)
    _ = take("plain-after.tsv", excluding: nil)
    t.expect(compare("plain-before.tsv", "plain-after.tsv").status != 0, "with no exclusion, any change under a Claude Code root fails the comparison")

    // With one, the named subtree is skipped and the snapshot says so.
    _ = take("before.tsv", excluding: scratchGlob)
    try? "third\n".write(toFile: dir.path("home/.claude-personal/projects/p/scratch.txt"), atomically: true, encoding: .utf8)
    _ = take("after.tsv", excluding: scratchGlob)
    t.expectEqual(compare("before.tsv", "after.tsv").status, 0, "an excluded subtree's churn no longer fails the comparison")

    let manifest = (try? String(contentsOfFile: dir.path("before.tsv"), encoding: .utf8)) ?? ""
    t.expect(manifest.contains("excluded\t\(scratchGlob)"), "the snapshot records the pattern, so nothing is dropped quietly — got: \(manifest)")
    t.expect(!manifest.contains("projects/p/scratch.txt"), "and the excluded file itself is absent from the manifest")
    t.expect(manifest.contains(".claude-personal/settings.json"), "a sibling the pattern does not cover is still checked")

    // The exclusion must not widen: a real escape elsewhere still fails.
    try? "escaped = true\n".write(toFile: dir.path("home/.config/agentmenu/config.toml"), atomically: true, encoding: .utf8)
    _ = take("escape.tsv", excluding: scratchGlob)
    t.expect(compare("before.tsv", "escape.tsv").status != 0, "a write to the maintainer's config still fails while an exclusion is active")
}

// MARK: - snapshot.sh on its own, against fixture directories

private func runAppFreshSnapshotUnitTests(_ t: TestRunner, _ root: URL) {
    let dir = TempDir("appfresh-snapshot-unit")
    defer { dir.cleanup() }

    let commonScript = root.appendingPathComponent("harness/lib/common.sh").path
    let snapshotScript = root.appendingPathComponent("harness/lib/snapshot.sh").path

    do {
        try dir.write("role = \"maintainer\"\n", to: "home/.config/agentmenu/config.toml")
        try dir.write("{\"a\":1}\n", to: "home/.claude/settings.json")
    } catch {
        t.expect(false, "wrote a fixture maintainer home: \(error)")
        return
    }

    let domain = "com.appfresh.tests.snapshot-unit.\(UUID().uuidString)"
    let env = ["HARNESS_SNAPSHOT_HOME": dir.path("home"), "HARNESS_SNAPSHOT_DOMAIN": domain]

    func takeSnapshot(_ outputName: String) -> CLIResult {
        let script = """
        set -euo pipefail
        . "\(commonScript)"
        . "\(snapshotScript)"
        snapshot_take "\(dir.path(outputName))"
        """
        return runProcess("/bin/bash", ["-c", script], environment: env)
    }

    let first = takeSnapshot("before.tsv")
    t.expectEqual(first.status, 0, "snapshot_take runs cleanly on a fixture home — \(first.stderr)")
    guard let before = try? String(contentsOfFile: dir.path("before.tsv"), encoding: .utf8) else {
        t.expect(false, "snapshot_take wrote a before file")
        return
    }
    t.expect(before.contains("config\t"), "the config/manifests root is labelled 'config'")
    t.expect(before.contains("claude\t"), "the Claude Code root is labelled 'claude'")
    t.expect(before.contains("domain\t\(domain)\t"), "the domain line carries the label 'domain'")
    for line in before.split(separator: "\n") {
        t.expectEqual(line.split(separator: "\t", omittingEmptySubsequences: false).count, 5, "every line is 5 tab-separated fields (label, path, size, mtime, hash) — got: \(line)")
    }
    // Every file is two rows, never merged into one (see _snapshot_tree's
    // own header for why): a regression that dropped either pass would
    // still leave every line above 5 fields wide, so that check alone
    // would not catch it — this checks both rows actually exist for the
    // same path.
    let configToml = "\(dir.path("home"))/.config/agentmenu/config.toml"
    t.expect(before.contains("config\t\(configToml)\t-\t-\t"), "the config file has its own content-hash row")
    t.expect(
        before.range(of: "config\t\(configToml)\t[0-9]+\t[0-9]+\t-", options: .regularExpression) != nil,
        "the config file also has its own size/mtime row, separately from the hash row"
    )

    let second = takeSnapshot("before2.tsv")
    t.expectEqual(second.status, 0, "a second snapshot_take also runs cleanly — \(second.stderr)")
    let compareScript = """
    set -euo pipefail
    . "\(commonScript)"
    . "\(snapshotScript)"
    if snapshot_compare "\(dir.path("before.tsv"))" "\(dir.path("before2.tsv"))"; then echo MATCH; else echo DIFFER; fi
    """
    let compared = runProcess("/bin/bash", ["-c", compareScript], environment: env)
    t.expect(compared.stdout.contains("MATCH"), "two snapshots of unchanged fixtures compare equal — got: \(compared.stdout)")

    // Decided (see snapshot.sh's own header): a rewrite with identical bytes
    // still counts, because it still shows up via mtime — R3 says "never
    // writes", not "never changes bytes".
    Thread.sleep(forTimeInterval: 1.1)
    do {
        try dir.write("role = \"maintainer\"\n", to: "home/.config/agentmenu/config.toml")
    } catch {
        t.expect(false, "rewrote the fixture with identical content: \(error)")
        return
    }
    let third = takeSnapshot("after.tsv")
    t.expectEqual(third.status, 0, "snapshot_take runs after the identical-content rewrite — \(third.stderr)")
    let rewriteCompareScript = """
    set -euo pipefail
    . "\(commonScript)"
    . "\(snapshotScript)"
    if snapshot_compare "\(dir.path("before.tsv"))" "\(dir.path("after.tsv"))"; then echo MATCH; else echo DIFFER; fi
    """
    let rewriteResult = runProcess("/bin/bash", ["-c", rewriteCompareScript], environment: env)
    t.expect(rewriteResult.stdout.contains("DIFFER"), "an identical-content rewrite still shows up, via mtime — got: \(rewriteResult.stdout)")
    let diffScript = """
    set -euo pipefail
    . "\(commonScript)"
    . "\(snapshotScript)"
    snapshot_diff "\(dir.path("before.tsv"))" "\(dir.path("after.tsv"))"
    """
    let diffOut = runProcess("/bin/bash", ["-c", diffScript], environment: env).stdout
    t.expect(diffOut.contains("config.toml"), "snapshot_diff names the path that differed — got: \(diffOut)")

    // The literal default: with no HARNESS_SNAPSHOT_DOMAIN override, the
    // domain snapshotted is dev.facens.agentmenu — read-only here, and only
    // the label is asserted, never its content, which belongs to whatever
    // the maintainer's own, possibly-running AgentMenu last wrote and is not
    // this suite's to depend on being stable across two calls.
    let defaultDomainResult = takeSnapshotWithHomeOnly(dir, commonScript: commonScript, snapshotScript: snapshotScript, outputName: "default-domain.tsv")
    t.expectEqual(defaultDomainResult.status, 0, "snapshot_take runs with no domain override — \(defaultDomainResult.stderr)")
    let defaultDomainSnapshot = (try? String(contentsOfFile: dir.path("default-domain.tsv"), encoding: .utf8)) ?? ""
    t.expect(defaultDomainSnapshot.contains("domain\tdev.facens.agentmenu\t"), "the default domain is dev.facens.agentmenu, matching AE8's own wording — got: \(defaultDomainSnapshot)")
}

private func takeSnapshotWithHomeOnly(_ dir: TempDir, commonScript: String, snapshotScript: String, outputName: String) -> CLIResult {
    let script = """
    set -euo pipefail
    . "\(commonScript)"
    . "\(snapshotScript)"
    snapshot_take "\(dir.path(outputName))"
    """
    return runProcess("/bin/bash", ["-c", script], environment: ["HARNESS_SNAPSHOT_HOME": dir.path("home")])
}

// MARK: - The environment actually reaching the app: -AgentMenuHarness YES
// and the isolated config path, not just "the run passed"

/// Drives appfresh_prepare and appfresh_teardown directly (not through
/// harness/run.sh start/wait) specifically so this can read the journal
/// line back *before* teardown deletes the isolated root — by the time
/// `wait` returns in the other tests here, that TempDir is already gone.
/// Without this, a run.sh happy path would keep passing even if
/// "-AgentMenuHarness YES" were deleted from appfresh.sh's launch line
/// entirely, since the stub ignores its own argv in every other test.
private func runAppFreshEnvironmentWiringTests(_ t: TestRunner, _ root: URL) {
    let dir = TempDir("appfresh-env-wiring")
    defer { dir.cleanup() }

    guard let bundle = appFreshStubBundle(dir, t) else { return }
    guard let home = appFreshFixtureHome(dir, t) else { return }

    do {
        try dir.write("{\"run_id\": \"env-wiring-test\", \"nonce\": \"deadbeef\"}\n", to: "rundir/report.json")
    } catch {
        t.expect(false, "wrote a fake run directory: \(error)")
        return
    }

    let commonScript = root.appendingPathComponent("harness/lib/common.sh").path
    let vmScript = root.appendingPathComponent("harness/lib/vm.sh").path
    let appfreshScript = root.appendingPathComponent("harness/lib/appfresh.sh").path
    let runDir = dir.path("rundir")

    let env = [
        "HARNESS_APPFRESH_APP": bundle,
        "HARNESS_SNAPSHOT_HOME": home,
        "HARNESS_SNAPSHOT_DOMAIN": "com.appfresh.tests.env-wiring.\(UUID().uuidString)",
        "HARNESS_APPFRESH_LAUNCH_TIMEOUT": "15",
    ]

    let prepareScript = """
    set -euo pipefail
    . "\(commonScript)"
    . "\(vmScript)"
    . "\(appfreshScript)"
    appfresh_prepare "\(runDir)"
    tempdir="$(cat "\(runDir)/appfresh.tempdir")"
    cat "$tempdir/harness/journal.ndjson"
    """
    let prepared = runProcess("/bin/bash", ["-c", prepareScript], environment: env)
    t.expectEqual(prepared.status, 0, "appfresh_prepare runs cleanly against a stub bundle — \(prepared.stderr)")

    let journalLine = prepared.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    if let data = journalLine.data(using: .utf8),
       let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
       let payload = object["data"] as? [String: Any] {
        let argv = payload["argv"] as? String ?? ""
        t.expect(argv.contains("-AgentMenuHarness YES"), "the app was launched with -AgentMenuHarness YES — got argv: '\(argv)'")
        let configPath = payload["config"] as? String ?? ""
        t.expect(!configPath.isEmpty, "the journal echoed a config path")
        t.expect(!configPath.hasPrefix(home), "the config path is never under the fixture 'maintainer' home — got: \(configPath)")
        t.expect(configPath.contains("agentmenu-appfresh."), "the config path is under the mktemp -d isolated root, not some other location — got: \(configPath)")
    } else {
        t.expect(false, "the stub wrote one parseable journal line — got: '\(journalLine)'")
    }

    // Teardown afterward, so this scratch run leaves nothing behind either.
    let teardownScript = """
    set -euo pipefail
    . "\(commonScript)"
    . "\(vmScript)"
    . "\(appfreshScript)"
    export HARNESS_RUN_DIR="\(runDir)"
    appfresh_teardown
    """
    let torn = runProcess("/bin/bash", ["-c", teardownScript], environment: env)
    t.expectEqual(torn.status, 0, "appfresh_teardown runs cleanly on this scratch run — \(torn.stderr)")
}

// MARK: - Happy path: prepare, launch, teardown, snapshots match (AE8)

private func runAppFreshHappyPathTests(_ t: TestRunner, _ root: URL) {
    guard let rig = makeHarnessRig("appfresh-happy", root, t) else { return }
    defer { rig.dir.cleanup() }
    guard let bundle = appFreshStubBundle(rig.dir, t) else { return }
    guard let home = appFreshFixtureHome(rig.dir, t) else { return }

    let env = [
        "HARNESS_APPFRESH_APP": bundle,
        "HARNESS_SNAPSHOT_HOME": home,
        "HARNESS_SNAPSHOT_DOMAIN": "com.appfresh.tests.happy.\(UUID().uuidString)",
        "HARNESS_APPFRESH_LAUNCH_TIMEOUT": "15",
    ]

    let start = appFreshRun(rig, ["start", "--app", "agentmenu", "--tier", "app-fresh", "--scenario", "pass"], extraEnvironment: env)
    t.expectEqual(start.status, 0, "start on app-fresh with a stub bundle exits 0 — stderr: \(start.stderr)")
    let runID = start.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    let waited = appFreshRun(rig, ["wait", runID, "--max-secs", "30"], extraEnvironment: env)
    t.expectEqual(waited.status, 0, "the run passes — stdout: \(waited.stdout) stderr: \(waited.stderr)")

    guard let report = harnessReport(rig, runID) else {
        t.expect(false, "the app-fresh run wrote a report.json")
        return
    }
    t.expectEqual(report["verdict"] as? String, "pass", "verdict is pass")
    t.expectEqual(report["outcome_kind"] as? String, "pass", "outcome_kind is pass")
    t.expectEqual(report["exit_code"] as? Int, 0, "exit code is 0")
    t.expectEqual(report["tier"] as? String, "app-fresh", "the report records the tier")
    t.expectEqual((report["steps"] as? [Any])?.count, 2, "the scenario's own steps still reach steps[] under local transport")

    let runDir = "\(rig.distRoot)/\(runID)"
    t.expect(!FileManager.default.fileExists(atPath: "\(runDir)/watchdog-appfresh-snapshot.fired"), "a clean run leaves no snapshot-mismatch marker")

    for file in ["appfresh.tempdir", "appfresh.suite", "appfresh.pid", "appfresh.snapshot.before", "appfresh.snapshot.after"] {
        t.expect(FileManager.default.fileExists(atPath: "\(runDir)/\(file)"), "the run directory carries \(file)")
    }

    // Before and after match byte for byte (AE8): the snapshot comparator
    // itself already proved this by not firing the marker above; this reads
    // the two files back independently as a second, direct check.
    if let before = try? String(contentsOfFile: "\(runDir)/appfresh.snapshot.before", encoding: .utf8),
       let after = try? String(contentsOfFile: "\(runDir)/appfresh.snapshot.after", encoding: .utf8) {
        t.expectEqual(before, after, "the before and after snapshots are byte-identical")
    } else {
        t.expect(false, "both snapshot files are readable")
    }

    // Teardown's own cleanup: the isolated root and the app process are
    // gone once the run has finished — `wait` does not return until the
    // supervisor's own teardown trap has already run.
    if let tempdirText = try? String(contentsOfFile: "\(runDir)/appfresh.tempdir", encoding: .utf8) {
        let path = tempdirText.trimmingCharacters(in: .whitespacesAndNewlines)
        t.expect(!FileManager.default.fileExists(atPath: path), "the isolated root was removed on teardown")
    } else {
        t.expect(false, "the run recorded its isolated root's path")
    }
    if let pidText = try? String(contentsOfFile: "\(runDir)/appfresh.pid", encoding: .utf8) {
        // appfresh.pid is PID then start token, one per line (the same
        // pairing common.sh's proc_matches needs) — only the first line
        // matters here.
        let pid = pidText.split(separator: "\n").first.map(String.init) ?? ""
        if !pid.isEmpty {
            t.expect(runProcess("/bin/kill", ["-0", pid]).status != 0, "the app process was quit on teardown")
        }
    }
    if let suiteText = try? String(contentsOfFile: "\(runDir)/appfresh.suite", encoding: .utf8) {
        let suite = suiteText.trimmingCharacters(in: .whitespacesAndNewlines)
        t.expect(suite != "dev.facens.agentmenu", "the isolated suite is never the real domain")
        t.expect(!FileManager.default.fileExists(atPath: "\(NSHomeDirectory())/Library/Preferences/\(suite).plist"), "the suite's plist was removed on teardown")
    }
}

// MARK: - A run that escapes the isolated root fails the whole run (AE8)

private func runAppFreshSnapshotMismatchTests(_ t: TestRunner, _ root: URL) {
    guard let rig = makeHarnessRig("appfresh-mismatch", root, t) else { return }
    defer { rig.dir.cleanup() }
    guard let bundle = appFreshStubBundle(rig.dir, t) else { return }
    guard let home = appFreshFixtureHome(rig.dir, t) else { return }

    let env = [
        "HARNESS_APPFRESH_APP": bundle,
        "HARNESS_SNAPSHOT_HOME": home,
        "HARNESS_SNAPSHOT_DOMAIN": "com.appfresh.tests.mismatch.\(UUID().uuidString)",
        "HARNESS_APPFRESH_LAUNCH_TIMEOUT": "15",
        // The stub writes here after it reports itself up — standing in for
        // "the app wrote outside the isolated roots".
        "HARNESS_APPFRESH_STUB_ESCAPE": "\(home)/.config/agentmenu/config.toml",
    ]

    let start = appFreshRun(rig, ["start", "--app", "agentmenu", "--tier", "app-fresh", "--scenario", "pass"], extraEnvironment: env)
    t.expectEqual(start.status, 0, "start exits 0 — the escape happens after launch, not at validation")
    let runID = start.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    let waited = appFreshRun(rig, ["wait", runID, "--max-secs", "30"], extraEnvironment: env)
    t.expectEqual(waited.status, 3, "a run that touched the maintainer's own state is a harness error — stdout: \(waited.stdout)")

    guard let report = harnessReport(rig, runID) else {
        t.expect(false, "the run wrote a report.json")
        return
    }
    t.expectEqual(report["verdict"] as? String, "error", "verdict is error, not fail: the scenario itself reached its own end state")
    t.expectEqual(report["outcome_kind"] as? String, "harness_error", "outcome_kind is harness_error, the same slot a fired watchdog uses")
    t.expectEqual(report["exit_code"] as? Int, 3, "exit code is 3")

    let marker = "\(rig.distRoot)/\(runID)/watchdog-appfresh-snapshot.fired"
    guard let contents = try? String(contentsOfFile: marker, encoding: .utf8) else {
        t.expect(false, "the mismatch left watchdog-appfresh-snapshot.fired — none found")
        return
    }
    t.expect(contents.contains("config.toml"), "the marker lists the differing path — got: \(contents)")

    // Teardown still ran despite the mismatch: the app was still quit.
    if let pidText = try? String(contentsOfFile: "\(rig.distRoot)/\(runID)/appfresh.pid", encoding: .utf8) {
        let pid = pidText.split(separator: "\n").first.map(String.init) ?? ""
        if !pid.isEmpty {
            t.expect(runProcess("/bin/kill", ["-0", pid]).status != 0, "the app process is still quit even when the snapshot mismatched")
        }
    }
}

// MARK: - `clean` gives back what a killed run left (a suite plist, a
// TempDir, an orphaned app process), independent of --age-days

private func runAppFreshCleanTests(_ t: TestRunner, _ root: URL) {
    guard let rig = makeHarnessRig("appfresh-clean", root, t) else { return }
    defer { rig.dir.cleanup() }

    let deadDir = "\(rig.distRoot)/dead-run"
    let aliveDir = "\(rig.distRoot)/alive-run"
    do {
        try FileManager.default.createDirectory(atPath: deadDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: aliveDir, withIntermediateDirectories: true)
    } catch {
        t.expect(false, "created fake run directories: \(error)")
        return
    }

    let orphan = Process()
    orphan.executableURL = URL(fileURLWithPath: "/bin/sleep")
    orphan.arguments = ["120"]
    do { try orphan.run() } catch {
        t.expect(false, "started a throwaway orphan process: \(error)")
        return
    }
    let orphanPID = orphan.processIdentifier
    // appfresh.pid is PID then start token (proc_matches, not a bare
    // kill -0 — see appfresh.sh's own _appfresh_clean_one for why a
    // breadcrumb this old cannot be trusted on the PID alone), so the
    // fixture has to carry a token that actually matches the orphan's real
    // start time or clean would correctly refuse to touch it.
    let orphanToken = runProcess("/bin/ps", ["-p", "\(orphanPID)", "-o", "lstart="]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)

    let deadTempdir = "\(deadDir)-tempdir"
    let suite = "dev.facens.agentmenu.harness.test-clean-\(UUID().uuidString.prefix(8))"
    do {
        try FileManager.default.createDirectory(atPath: deadTempdir, withIntermediateDirectories: true)
        let deadReport = "{\"supervisor_pid\": 999999, \"supervisor_token\": \"not-a-real-token\"}"
        try deadReport.write(toFile: "\(deadDir)/report.json", atomically: true, encoding: .utf8)
        try "\(orphanPID)\n\(orphanToken)\n".write(toFile: "\(deadDir)/appfresh.pid", atomically: true, encoding: .utf8)
        try "\(deadTempdir)\n".write(toFile: "\(deadDir)/appfresh.tempdir", atomically: true, encoding: .utf8)
        try "\(suite)\n".write(toFile: "\(deadDir)/appfresh.suite", atomically: true, encoding: .utf8)
    } catch {
        t.expect(false, "wrote the dead run's fixtures: \(error)")
        orphan.terminate()
        return
    }
    _ = runProcess("/usr/bin/defaults", ["write", suite, "harnessJournal", "-string", "journal.ndjson"])

    // An alive run: this process's own pid and start token, so
    // supervisor_alive reports it as live and clean must leave it alone.
    let myPID = ProcessInfo.processInfo.processIdentifier
    let lstart = runProcess("/bin/ps", ["-p", "\(myPID)", "-o", "lstart="]).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let aliveTempdir = "\(aliveDir)-tempdir-should-survive"
    do {
        try FileManager.default.createDirectory(atPath: aliveTempdir, withIntermediateDirectories: true)
        let reportJSON = "{\"supervisor_pid\": \(myPID), \"supervisor_token\": \"\(lstart)\"}"
        try reportJSON.write(toFile: "\(aliveDir)/report.json", atomically: true, encoding: .utf8)
        try "\(aliveTempdir)\n".write(toFile: "\(aliveDir)/appfresh.tempdir", atomically: true, encoding: .utf8)
    } catch {
        t.expect(false, "wrote the alive run's fixtures: \(error)")
        orphan.terminate()
        return
    }

    let dry = appFreshRun(rig, ["clean", "--dry-run"])
    t.expectEqual(dry.status, 0, "clean --dry-run exits 0 — \(dry.stderr)")
    t.expect(dry.stdout.contains("would stop orphaned app-fresh process \(orphanPID)"), "dry-run names the orphaned process — got: \(dry.stdout)")
    t.expect(dry.stdout.contains("would delete leftover suite \(suite)"), "dry-run names the leftover suite — got: \(dry.stdout)")
    t.expect(dry.stdout.contains("would remove leftover app-fresh root \(deadTempdir)"), "dry-run names the leftover root — got: \(dry.stdout)")
    t.expect(runProcess("/bin/kill", ["-0", "\(orphanPID)"]).status == 0, "a dry run does not touch the orphan process")
    t.expect(FileManager.default.fileExists(atPath: deadTempdir), "a dry run does not remove the isolated root")

    let real = appFreshRun(rig, ["clean"])
    t.expectEqual(real.status, 0, "clean exits 0 — \(real.stderr)")
    t.expect(runProcess("/bin/kill", ["-0", "\(orphanPID)"]).status != 0, "clean stopped the orphaned app process")
    t.expect(!FileManager.default.fileExists(atPath: deadTempdir), "clean removed the dead run's isolated root")
    t.expect(!FileManager.default.fileExists(atPath: "\(NSHomeDirectory())/Library/Preferences/\(suite).plist"), "clean removed the leftover suite plist")
    t.expect(FileManager.default.fileExists(atPath: aliveTempdir), "clean left the live run's isolated root alone")

    // Defensive: only fires if an assertion above returned early.
    _ = runProcess("/usr/bin/defaults", ["delete", suite])
    try? FileManager.default.removeItem(atPath: aliveTempdir)
    if runProcess("/bin/kill", ["-0", "\(orphanPID)"]).status == 0 {
        orphan.terminate()
    }
}

// MARK: - Shared fixtures: a stub bundle standing in for AgentMenu.app, and
// a fixture "maintainer" home appfresh's snapshot roots can be pointed at

/// Stands in for AgentMenu.app/Contents/MacOS/AgentMenu: reads back the
/// harnessJournal key the real Journal.activate reads (via the same
/// AGENTMENU_DEFAULTS_SUITE appfresh_prepare seeds), writes one line into
/// the isolated harness directory it was given — including its own argv and
/// the AGENTMENU_CONFIG path it was handed, so a test can check
/// -AgentMenuHarness YES actually arrived and the config path actually
/// lands under the isolated root rather than $HOME — then blocks until
/// SIGTERM. Enough to prove appfresh_prepare's environment wiring and
/// appfresh_quit's PID-based teardown without building or launching the
/// real Swift binary. HARNESS_APPFRESH_STUB_ESCAPE, when set, additionally
/// writes outside the isolated root — standing in for "the app wrote
/// outside the isolated roots".
private let appFreshStubApp = #"""
#!/bin/bash
trap 'exit 0' TERM
leaf="$(defaults read "$AGENTMENU_DEFAULTS_SUITE" harnessJournal 2>/dev/null)"
if [ -n "$leaf" ]; then
    mkdir -p "$AGENTMENU_HARNESS_DIR"
    printf '{"seq":1,"event":"harness started","data":{"config":"%s","argv":"%s"}}\n' "$AGENTMENU_CONFIG" "$*" >> "$AGENTMENU_HARNESS_DIR/$leaf"
fi
if [ -n "${HARNESS_APPFRESH_STUB_ESCAPE:-}" ]; then
    echo "escaped $(date)" >> "$HARNESS_APPFRESH_STUB_ESCAPE"
fi
while true; do sleep 1; done
"""#

private func appFreshStubBundle(_ dir: TempDir, _ t: TestRunner) -> String? {
    let relative = "appfresh-stub/AgentMenu.app/Contents/MacOS/AgentMenu"
    do {
        try dir.write(appFreshStubApp + "\n", to: relative)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path(relative))
    } catch {
        t.expect(false, "wrote the app-fresh stub bundle: \(error)")
        return nil
    }
    return dir.path("appfresh-stub/AgentMenu.app")
}

private func appFreshFixtureHome(_ dir: TempDir, _ t: TestRunner) -> String? {
    do {
        try dir.write("role = \"maintainer\"\n", to: "fixture-home/.config/agentmenu/config.toml")
        try dir.write("{\"setting\":\"real\"}\n", to: "fixture-home/.claude/settings.json")
    } catch {
        t.expect(false, "wrote a fixture maintainer home: \(error)")
        return nil
    }
    return dir.path("fixture-home")
}

/// Like harnessRun, but with extra environment merged over the rig's own —
/// the app-fresh tier needs HARNESS_APPFRESH_APP, HARNESS_SNAPSHOT_HOME and
/// HARNESS_SNAPSHOT_DOMAIN, none of which the VM-tier rig anticipates.
private func appFreshRun(_ rig: HarnessRig, _ arguments: [String], extraEnvironment: [String: String] = [:]) -> CLIResult {
    var environment = rig.environment
    for (key, value) in extraEnvironment { environment[key] = value }
    return runProcess(rig.runScript, arguments, in: rig.root, environment: environment)
}

// MARK: - The shared-file manifest (KTD5)

/// `harness/SHARED.sha256` is the checked-in statement that the shared harness
/// files are byte-identical in both repositories. Each repository's own suite
/// verifies its own copies, so an edit that was not regenerated fails where it
/// was made. A missing manifest is a failure, not a skip: without it this
/// repository could drift from the other one silently.
private func runHarnessSharedManifestTests(_ t: TestRunner, _ root: URL) {
    let manifestPath = root.appendingPathComponent("harness/SHARED.sha256").path
    guard let manifest = try? String(contentsOfFile: manifestPath, encoding: .utf8) else {
        t.expect(false, "harness/SHARED.sha256 is missing — regenerate it from the repository root: { echo harness/run.sh; find harness/guest -type f ! -name '.DS_Store'; find harness/lib -type f ! -name appfresh.sh ! -name snapshot.sh ! -name '.DS_Store'; } | LC_ALL=C sort | xargs shasum -a 256 > harness/SHARED.sha256")
        return
    }

    var listed: [String: String] = [:]
    for line in manifest.split(separator: "\n") {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else {
            t.expect(false, "every manifest line is '<sha256>  <path>' — got '\(line)'")
            continue
        }
        var path = parts[1]
        if path.hasPrefix("*") { path.removeFirst() }
        listed[path] = parts[0].lowercased()
    }
    t.expect(!listed.isEmpty, "the manifest lists at least one file")

    for (path, expected) in listed.sorted(by: { $0.key < $1.key }) {
        let absolute = root.appendingPathComponent(path).path
        guard FileManager.default.fileExists(atPath: absolute) else {
            t.expect(false, "the manifest lists \(path), which does not exist in this checkout")
            continue
        }
        let sum = runProcess("/usr/bin/shasum", ["-a", "256", absolute])
        let actual = sum.stdout.split(separator: " ").first.map(String.init)?.lowercased() ?? ""
        t.expectEqual(actual, expected, "\(path) matches the manifest — regenerate harness/SHARED.sha256 in both checkouts if the change was deliberate")
    }

    // And the other direction: a shared file that was added without being
    // added to the manifest would otherwise drift unnoticed.
    for path in harnessSharedFilePaths(root) {
        t.expect(listed[path] != nil, "\(path) is a shared file and is listed in harness/SHARED.sha256")
    }
    for excluded in ["harness/lib/appfresh.sh", "harness/lib/snapshot.sh"] {
        t.expect(listed[excluded] == nil, "\(excluded) carries an app-specific block and is not a shared file")
    }
}

/// KTD5's rule, applied to this checkout: `harness/run.sh`, `harness/guest/`,
/// and `harness/lib/` except the two app-specific files.
private func harnessSharedFilePaths(_ root: URL) -> [String] {
    var paths: [String] = []
    if FileManager.default.fileExists(atPath: root.appendingPathComponent("harness/run.sh").path) {
        paths.append("harness/run.sh")
    }
    for directory in ["harness/guest", "harness/lib"] {
        let base = root.appendingPathComponent(directory)
        guard let walker = FileManager.default.enumerator(atPath: base.path) else { continue }
        for case let entry as String in walker {
            let full = base.appendingPathComponent(entry)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: full.path, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            let name = (entry as NSString).lastPathComponent
            if name == ".DS_Store" || name == "appfresh.sh" || name == "snapshot.sh" { continue }
            paths.append("\(directory)/\(entry)")
        }
    }
    return paths.sorted()
}

// MARK: - sync-check compares the two checkouts

private func runHarnessSyncCheckTests(_ t: TestRunner, _ root: URL) {
    let script = root.appendingPathComponent("harness/sync-check.sh").path
    guard FileManager.default.isExecutableFile(atPath: script) else {
        t.expect(false, "harness/sync-check.sh is missing or not executable")
        return
    }

    let listed = runProcess(script, ["--list"], in: root)
    t.expectEqual(listed.status, 0, "sync-check --list exits 0")
    t.expect(listed.stdout.contains("harness/run.sh"), "the shared list names run.sh")
    t.expect(listed.stdout.contains("harness/lib/common.sh"), "the shared list names the libraries")
    t.expect(!listed.stdout.contains("harness/lib/appfresh.sh"), "the shared list excludes the app-specific library")

    let other = TempDir("harness-sync-other")
    defer { other.cleanup() }
    let copy = runProcess("/bin/cp", ["-R", root.appendingPathComponent("harness").path, other.path("harness")])
    guard copy.status == 0 else {
        t.expect(false, "copied harness/ into a scratch checkout: \(copy.stderr)")
        return
    }

    let matched = runProcess(script, ["--other-dir", other.url.path], in: root)
    t.expectEqual(matched.status, 0, "two identical checkouts are in sync — \(matched.stdout)\(matched.stderr)")
    t.expect(matched.stdout.contains("ok ("), "it says so")

    // One shared file edited on the other side, and one missing there.
    let drifted = other.path("harness/lib/vm.sh")
    if let existing = try? String(contentsOfFile: drifted, encoding: .utf8) {
        try? (existing + "\n# edited in the other checkout\n").write(toFile: drifted, atomically: true, encoding: .utf8)
    }
    try? FileManager.default.removeItem(atPath: other.path("harness/lib/watchdog.sh"))

    let drift = runProcess(script, ["--other-dir", other.url.path], in: root)
    t.expectEqual(drift.status, 1, "drift between the checkouts fails the check")
    t.expect(drift.stderr.contains("harness/lib/vm.sh"), "the failure names the file that differs")
    t.expect(drift.stderr.contains("harness/lib/watchdog.sh"), "and the one that is missing there")

    // No second checkout on this machine: a note and a pass, or a refusal
    // under --require, which is what the release runbook passes.
    let absent = TempDir("harness-sync-absent")
    defer { absent.cleanup() }
    let missing = absent.path("not-a-checkout")
    let skipped = runProcess(script, ["--other-dir", missing], in: root)
    t.expectEqual(skipped.status, 0, "a machine without the other checkout passes with a note")
    t.expect(skipped.stdout.contains("nothing to compare"), "and says what it did not do")
    let required = runProcess(script, ["--other-dir", missing, "--require"], in: root)
    t.expectEqual(required.status, 2, "--require turns the missing checkout into a refusal")
}

// MARK: - The rig: stub tart, ssh and scp on PATH, fake scenarios, a scratch run root

private struct HarnessRig {
    let dir: TempDir
    let root: URL
    let runScript: String
    let environment: [String: String]
    let distRoot: String
    let state: String
    let assetPath: String
}

/// A stub `tart` with just enough memory to be worth asserting against: it
/// keeps a file per VM under `vms/`, holding that VM's state, so `list`
/// reports what `clone`, `run`, `stop` and `delete` did, and every invocation
/// is appended to `calls.log`. `run` blocks while the VM is "running", the way
/// the real one does, and returns when the VM stops or is deleted.
private let harnessTartStub = #"""
#!/bin/bash
STATE="${TART_STUB_STATE:?}"
mkdir -p "$STATE/vms"
printf 'tart %s\n' "$*" >> "$STATE/calls.log"
cmd="${1:-}"; shift || true
case "$cmd" in
  list)
    echo "Source Name Disk Size State"
    for f in "$STATE"/vms/*; do
      [ -e "$f" ] || continue
      echo "local $(basename "$f") 50 20 $(cat "$f")"
    done
    ;;
  clone)
    if [ -f "$STATE/clone-fail-once" ]; then
      rm -f "$STATE/clone-fail-once"
      echo "tart: the clone failed (stub)" >&2
      exit 1
    fi
    echo stopped > "$STATE/vms/$2"
    ;;
  run)
    name=""
    for a in "$@"; do case "$a" in -*) ;; *) name="$a" ;; esac; done
    echo running > "$STATE/vms/$name"
    while [ -f "$STATE/vms/$name" ] && [ "$(cat "$STATE/vms/$name")" = "running" ]; do sleep 1; done
    exit 0
    ;;
  ip) echo "127.0.0.1" ;;
  stop) if [ -f "$STATE/vms/$1" ]; then echo stopped > "$STATE/vms/$1"; fi ;;
  delete) rm -f "$STATE/vms/$1" ;;
  *) echo "tart stub: unknown subcommand $cmd" >&2; exit 1 ;;
esac
"""#

/// The guest shell. It answers the one command the supervisor makes of it on
/// its own account — reading the image's build inputs — and records the rest.
private let harnessSSHStub = #"""
#!/bin/bash
printf 'ssh %s\n' "$*" >> "${TART_STUB_STATE:?}/calls.log"
case "$*" in
  *first-run-golden.json*) echo '{"macos_build":"25G123","tart":"2.37.0","stub":true}' ;;
  *selfcheck.sh*) echo '{"screencapture":true,"system_events":true,"automation":true,"statusitem_idiom":"app-menu-bar-2","identifiers":["setup.card","setup.continue"],"popover_survived":true}' ;;
esac
exit 0
"""#

/// Stands in for scp, and — unlike a stub that logs and exits 0 — for the far
/// side of it too. Since OpenSSH 9.0 that far side is sftp-server, not a
/// shell: it takes the remote path verbatim, so shell quoting becomes part of
/// the file name and the transfer fails. A stub that accepts anything let
/// exactly that ship (`scp: dest open "'.harness/'": No such file or
/// directory` on every stranger run, found by running the harness, not by the
/// suite), so this one refuses a quoted remote path the way a real guest does.
private let harnessSCPStub = #"""
#!/bin/bash
printf 'scp %s\n' "$*" >> "${TART_STUB_STATE:?}/calls.log"
for arg in "$@"; do
    case "$arg" in
        *@*:*)
            remote="${arg#*:}"
            case "$remote" in
                *\'*|*\"*)
                    echo "scp: dest open \"$remote\": No such file or directory" >&2
                    echo "scp stub: the remote path is passed to sftp-server verbatim; quoting it makes the quotes part of the name." >&2
                    exit 1 ;;
            esac
            ;;
    esac
done
exit 0
"""#

/// Three scenarios standing in for the real ones: one that reaches its end
/// state and reports a finding on the way, one that does not, one that never
/// returns.
private let harnessPassScenario = #"""
#!/bin/bash
set -euo pipefail
printf '{"step":"install","status":"ok","screenshot":"%s/001-install.png","at":"%s"}\n' \
    "$HARNESS_SHOT_DIR" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$HARNESS_STEPS"
printf '{"step":"setup card","status":"ok","screenshot":"%s/002-setup.png","at":"%s"}\n' \
    "$HARNESS_SHOT_DIR" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$HARNESS_STEPS"
echo "dialog-confirm-retry-2" >> "$HARNESS_FINDINGS"
exit 0
"""#

private let harnessFailScenario = #"""
#!/bin/bash
set -euo pipefail
printf '{"step":"setup card","status":"fail","screenshot":"none","at":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$HARNESS_STEPS"
exit 1
"""#

private let harnessHangScenario = #"""
#!/bin/bash
printf '{"step":"waiting on a control that never appears","status":"running","screenshot":"none","at":"%s"}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$HARNESS_STEPS"
sleep 120
"""#

private func makeHarnessRig(
    _ label: String,
    _ root: URL,
    _ t: TestRunner,
    scenarioTimeout: Int = 60,
    runTimeout: Int = 180
) -> HarnessRig? {
    let dir = TempDir(label)
    do {
        for (name, body) in [("bin/tart", harnessTartStub), ("bin/ssh", harnessSSHStub), ("bin/scp", harnessSCPStub)] {
            try dir.write(body + "\n", to: name)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path(name))
        }
        for (name, body) in [
            ("scenarios/agentmenu/pass.sh", harnessPassScenario),
            ("scenarios/agentmenu/fail.sh", harnessFailScenario),
            ("scenarios/agentmenu/hang.sh", harnessHangScenario),
        ] {
            try dir.write(body + "\n", to: name)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path(name))
        }
        try dir.write("not really a zip\n", to: "asset.zip")
        try dir.write("stopped\n", to: "state/vms/first-run-golden")
        try FileManager.default.createDirectory(atPath: dir.path("dist"), withIntermediateDirectories: true)
    } catch {
        t.expect(false, "built the harness stub rig: \(error)")
        dir.cleanup()
        return nil
    }

    let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    let environment = [
        "PATH": dir.path("bin") + ":" + existingPath,
        "TART_STUB_STATE": dir.path("state"),
        "HARNESS_DIST_ROOT": dir.path("dist"),
        "HARNESS_SCENARIO_ROOT": dir.path("scenarios"),
        "HARNESS_SCENARIO_TIMEOUT": "\(scenarioTimeout)",
        "HARNESS_RUN_TIMEOUT": "\(runTimeout)",
        "HARNESS_STEP_TIMEOUT": "30",
        "HARNESS_IP_TIMEOUT": "20",
        "HARNESS_SSH_TIMEOUT": "20",
        "HARNESS_WATCHDOG_GRACE": "2",
    ]
    return HarnessRig(
        dir: dir,
        root: root,
        runScript: root.appendingPathComponent("harness/run.sh").path,
        environment: environment,
        distRoot: dir.path("dist"),
        state: dir.path("state"),
        assetPath: dir.path("asset.zip")
    )
}

private func harnessRun(_ rig: HarnessRig, _ arguments: [String], script: String? = nil, extraEnvironment: [String: String] = [:]) -> CLIResult {
    var environment = rig.environment
    for (key, value) in extraEnvironment { environment[key] = value }
    return runProcess(script ?? rig.runScript, arguments, in: rig.root, environment: environment)
}

private func harnessCallLog(_ rig: HarnessRig) -> String {
    (try? String(contentsOfFile: "\(rig.state)/calls.log", encoding: .utf8)) ?? ""
}

private func harnessVMs(_ rig: HarnessRig) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: "\(rig.state)/vms")) ?? []).sorted()
}

private func harnessSeedVM(_ rig: HarnessRig, _ name: String, state: String) {
    try? "\(state)\n".write(toFile: "\(rig.state)/vms/\(name)", atomically: true, encoding: .utf8)
}

private func harnessRemoveVM(_ rig: HarnessRig, _ name: String) {
    try? FileManager.default.removeItem(atPath: "\(rig.state)/vms/\(name)")
}

private func harnessRunDirectories(_ rig: HarnessRig) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: rig.distRoot)) ?? []).sorted()
}

private func harnessReport(_ rig: HarnessRig, _ runID: String) -> [String: Any]? {
    guard let data = FileManager.default.contents(atPath: "\(rig.distRoot)/\(runID)/report.json"),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return nil
    }
    return object
}

/// Polls rather than sleeping a fixed amount: these scenarios race a detached
/// supervisor, and a fixed sleep is either slow or flaky.
private func harnessWaitUntil(_ seconds: Double, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.05)
    }
    return condition()
}
