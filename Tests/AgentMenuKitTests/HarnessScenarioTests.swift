// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// U4 / R14, R15, R17, R18, KTD6, KTD8: harness/lib/scenario.sh is the
/// scenario vocabulary (fixture, step, click, expect_event, shot, finding,
/// plus dialog and verdict) both apps' smoke scenarios are built from. This
/// suite drives its real helpers directly — sourced from a small driver
/// script written into a TempDir per test, never through harness/run.sh —
/// with guest_run redirected to a local shell (HARNESS_GUEST_TRANSPORT=local,
/// which harness/lib/vm.sh already supports) and osascript, screencapture and
/// sips stubbed on PATH, the same idiom HarnessScriptTests.swift uses for
/// tart.
///
/// $HARNESS_DIR points at THIS checkout's real harness/ directory, not a
/// copy: shot() and expect_event() shell out to the real guest/shot.sh and
/// guest/wait.sh, and the whole point is to exercise the real scenario.sh
/// sourcing them for real, rather than a hand-rolled stand-in. Only the
/// run-scoped state a real run would put under dist/harness/<run-id>/ —
/// HARNESS_STEPS, HARNESS_FINDINGS, HARNESS_SHOT_DIR, HARNESS_JOURNAL,
/// HARNESS_EVIDENCE — lives in a TempDir per test.
///
/// install_app/stage_asset's SUCCESS path is not exercised here, for the
/// same reason HarnessGuestTests.swift never runs install.sh for real: its
/// job ends in `mv` into the real /Applications and a real `open`, which no
/// automated suite may risk on the machine it happens to run on. Its
/// argument-validation path — an unrecognized app name, refused before the
/// guest is ever touched — is exercised instead; the success path (staging
/// an asset, calling install.sh, reading its JSON back) was checked by hand
/// against a stubbed install.sh in a scratch rig instead — see this unit's
/// own report for that transcript, not reproduced here as an automated test
/// for the reason above.
///
/// This suite fails loudly, never skips, when a file it needs is missing —
/// including MeetingHop's smoke.sh, found as the sibling checkout
/// ../meetinghop next to this repository (the same layout
/// packaging/publish-public.sh already assumes for the public/private
/// split), because U4 promises both apps' scenarios are covered here.
func runHarnessScenarioTests(_ t: TestRunner) {
    t.suite("HarnessScenario")

    let root = repositoryRoot()
    let scenarioLib = root.appendingPathComponent("harness/lib/scenario.sh").path
    guard FileManager.default.fileExists(atPath: scenarioLib) else {
        t.expect(false, "harness/lib/scenario.sh is missing at \(scenarioLib) — this suite fails rather than skipping")
        return
    }
    guard toolOnPath("jq") != nil else {
        t.expect(false, "jq is not on PATH — scenario.sh's step/finding bookkeeping needs it")
        return
    }

    hs_testSyntaxAndSmokeFiles(t, root)
    hs_testQuoting(t, root)
    hs_testStepAndShot(t, root)
    hs_testFinding(t, root)
    hs_testClickKindBranching(t, root)
    hs_testDialog(t, root)
    hs_testExpectEvent(t, root)
    hs_testExpectEventOmitsShotDirOnAppFresh(t, root)
    hs_testFixtureRefusal(t, root)
    hs_testVerdict(t, root)
    hs_testInstallAppValidation(t, root)
    hs_testAppFreshScreenRefusals(t, root)
    hs_testAppFreshJournalHelpersStillWork(t, root)
}

// MARK: - scenario.sh parses; both smoke scenarios exist, parse, are
// executable, and never call expect_event (v0.1.0 ships no journal hook —
// both are black box).

private func hs_testSyntaxAndSmokeFiles(_ t: TestRunner, _ root: URL) {
    let scenarioLib = root.appendingPathComponent("harness/lib/scenario.sh").path
    let parsed = runProcess("/bin/bash", ["-n", scenarioLib])
    t.expectEqual(parsed.status, 0, "harness/lib/scenario.sh parses — \(parsed.stderr)")
    t.expect(FileManager.default.isExecutableFile(atPath: scenarioLib), "harness/lib/scenario.sh is executable")

    // The MeetingHop half of this check reads the sibling checkout, which only
    // a developer machine has: CI clones one repository, so ../meetinghop can
    // never exist there and asserting it would fail every run for a reason no
    // one can fix in this repository. Absent and NOT in CI is still a failure
    // — that is a machine where the sibling is supposed to be, and skipping
    // there would quietly drop half the coverage. harness/sync-check.sh is
    // what compares the two checkouts when both are present.
    let meetinghopRoot = root.deletingLastPathComponent().appendingPathComponent("meetinghop")
    let inCI = ProcessInfo.processInfo.environment["CI"] != nil
        || ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil
    guard FileManager.default.fileExists(atPath: meetinghopRoot.path) else {
        t.expect(inCI, "the sibling checkout ../meetinghop (next to this repository) is missing at \(meetinghopRoot.path) — U4 needs it to check MeetingHop's smoke scenario; this fails rather than skipping that half of the coverage")
        if !inCI { return }
        hs_checkSmokeFile(t, "AgentMenu", root.appendingPathComponent("harness/scenarios/agentmenu/smoke.sh").path)
        return
    }

    let smokeFiles = [
        ("AgentMenu", root.appendingPathComponent("harness/scenarios/agentmenu/smoke.sh").path),
        ("MeetingHop", meetinghopRoot.appendingPathComponent("harness/scenarios/meetinghop/smoke.sh").path),
    ]
    for (app, path) in smokeFiles {
        hs_checkSmokeFile(t, app, path)
    }
}

/// One smoke scenario's file-level checks: it exists, is executable, parses,
/// and never calls expect_event. Shared so the CI path above, which can only
/// reach AgentMenu's copy, applies exactly the same checks to it as the
/// two-checkout path does.
private func hs_checkSmokeFile(_ t: TestRunner, _ app: String, _ path: String) {
    guard FileManager.default.isExecutableFile(atPath: path) else {
        t.expect(false, "\(app)'s smoke.sh is missing or not executable at \(path)")
        return
    }
    let syntax = runProcess("/bin/bash", ["-n", path])
    t.expectEqual(syntax.status, 0, "\(app)'s smoke.sh parses — \(syntax.stderr)")
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else {
        t.expect(false, "read \(app)'s smoke.sh at \(path)")
        return
    }
    t.expect(
        !hs_callsExpectEvent(content),
        "\(app)'s smoke.sh never CALLS expect_event — v0.1.0 has no journal hook, both scenarios are black box (the word may still appear in a comment explaining that, which this check accounts for)"
    )
}

/// True when `content` contains an actual `expect_event` invocation on a
/// non-comment line — never a plain substring search, which would also
/// match this very file's own explanatory comment ("... never calls
/// expect_event ...") in both smoke.sh headers.
private func hs_callsExpectEvent(_ content: String) -> Bool {
    for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.isEmpty || line.hasPrefix("#") { continue }
        if line.range(of: #"(^|[;&|(]|\s)expect_event(\s|$)"#, options: .regularExpression) != nil {
            return true
        }
    }
    return false
}

// MARK: - _scenario_quote round-trips through eval, including the one
// input (an embedded single quote) that is easy to get wrong — this file's
// own header notes a form that looked equivalent and silently was not.

private func hs_testQuoting(_ t: TestRunner, _ root: URL) {
    guard let rig = hs_makeRig("hs-quoting", root, t) else { return }
    defer { rig.dir.cleanup() }

    let cases = ["simple", "it's a test", "a \"double\" quote", "50% done", "setup shown", "a\\backslash"]
    for value in cases {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let body = """
        q="$(_scenario_quote "\(escaped)")"
        eval "printf '%s' $q"
        """
        let result = hs_runDriver(rig, body)
        t.expectEqual(result.status, 0, "_scenario_quote roundtrips '\(value)' without error — \(result.stderr)")
        t.expectEqual(result.stdout, value, "the quoted-then-eval'd value comes back unchanged — got '\(result.stdout)'")
    }
}

// MARK: - step + shot write the contract's steps.ndjson line shape, shot
// attaches to the open step, and verdict pass closes it "ok" carrying the
// last screenshot.

private func hs_testStepAndShot(_ t: TestRunner, _ root: URL) {
    guard let rig = hs_makeRig("hs-step-shot", root, t) else { return }
    defer { rig.dir.cleanup() }

    let result = hs_runDriver(rig, #"""
    step "install"
    p="$(shot "one")"
    printf '%s\n' "$p"
    verdict pass
    """#)
    t.expectEqual(result.status, 0, "step + shot + verdict pass exits 0 — \(result.stderr)")
    let shotPath = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    t.expect(shotPath.hasSuffix("001-one.png"), "shot prints the host path of the capture, numbered from 1 — got '\(shotPath)'")
    t.expect(FileManager.default.fileExists(atPath: shotPath), "the screenshot file actually landed at the printed path")

    let steps = hs_stepLines(rig)
    t.expect(steps.count >= 2, "at least the step-open and the shot-updated lines were written — got \(steps.count)")
    guard let last = steps.last else {
        t.expect(false, "steps.ndjson has a last line")
        return
    }
    t.expectEqual(last["step"] as? String, "install", "the closing line still names the step that was open")
    t.expectEqual(last["status"] as? String, "ok", "verdict pass closed it \"ok\"")
    t.expectEqual(last["screenshot"] as? String, shotPath, "the closing line carries the screenshot shot() just took, not \"none\"")
}

// MARK: - finding

private func hs_testFinding(_ t: TestRunner, _ root: URL) {
    guard let rig = hs_makeRig("hs-finding", root, t) else { return }
    defer { rig.dir.cleanup() }

    // No harness/findings.txt exists in this checkout (U11 has not landed
    // it yet) — any code is accepted.
    let ok = hs_runDriver(rig, #"finding "no-calendar-accounts""#)
    t.expectEqual(ok.status, 0, "finding accepts any code while harness/findings.txt does not exist — \(ok.stderr)")
    t.expectEqual(hs_findingsList(rig), ["no-calendar-accounts"], "the code was appended to HARNESS_FINDINGS")

    // With a findings.txt present (HARNESS_DIR overridden to a scratch
    // directory carrying only that file — finding() never touches guest/,
    // so nothing else needs to be there), an unlisted code is refused as a
    // harness error, and a listed one still works.
    let scratchHarness = rig.dir.path("scratch-harness")
    try? FileManager.default.createDirectory(atPath: scratchHarness, withIntermediateDirectories: true)
    try? "no-calendar-accounts: no calendar accounts are configured\n"
        .write(toFile: "\(scratchHarness)/findings.txt", atomically: true, encoding: .utf8)

    let refused = hs_runDriver(rig, #"finding "totally-bogus-code""#, extraEnv: ["HARNESS_DIR": scratchHarness])
    t.expectEqual(refused.status, 3, "an unlisted code is a harness error once findings.txt exists — \(refused.stderr)")
    t.expect(refused.stderr.contains("totally-bogus-code"), "the refusal names the bad code — got \(refused.stderr)")

    let accepted = hs_runDriver(rig, #"finding "no-calendar-accounts""#, extraEnv: ["HARNESS_DIR": scratchHarness])
    t.expectEqual(accepted.status, 0, "a code that IS listed in findings.txt is still accepted — \(accepted.stderr)")
}

// MARK: - click branches on ax.applescript's "kind", never osascript's own
// exit status.

private func hs_testClickKindBranching(_ t: TestRunner, _ root: URL) {
    guard let rig = hs_makeRig("hs-click", root, t, stepTimeout: 5) else { return }
    defer { rig.dir.cleanup() }

    let happy = hs_runDriver(rig, #"""
    step "clicking"
    click "com.example.app" "ax.thing"
    verdict pass
    """#)
    t.expectEqual(happy.status, 0, "a click with no \"kind\" in the response passes the scenario — \(happy.stderr)")

    let notFound = hs_runDriver(rig, #"""
    step "clicking"
    click "com.example.app" "bogus"
    """#, extraEnv: ["HS_AX_KIND": "notfound"])
    t.expectEqual(notFound.status, 1, "a \"notfound\" kind fails the scenario (exit 1), not a harness error — \(notFound.stderr)")
    if let last = hs_stepLines(rig).last {
        t.expectEqual(last["step"] as? String, "clicking", "the failing step is named in steps.ndjson")
        t.expectEqual(last["status"] as? String, "fail", "and recorded failed")
    } else {
        t.expect(false, "steps.ndjson has a line after the notfound click")
    }

    let driverErr = hs_runDriver(rig, #"""
    step "clicking"
    click "com.example.app" "bogus"
    """#, extraEnv: ["HS_AX_KIND": "driver"])
    t.expectEqual(driverErr.status, 3, "a \"driver\" kind is a harness error (exit 3), not a scenario fail — \(driverErr.stderr)")
}

// MARK: - dialog wraps wait/answer, branches the same way, records
// evidence, and clamps its own [timeout] to $HARNESS_STEP_TIMEOUT.

private func hs_testDialog(_ t: TestRunner, _ root: URL) {
    guard let rig = hs_makeRig("hs-dialog", root, t, stepTimeout: 5) else { return }
    defer { rig.dir.cleanup() }

    let notPresent = hs_runDriver(rig, #"""
    w="$(dialog wait gatekeeper)"
    printf '%s\n' "$w"
    """#, extraEnv: ["HS_DIALOG_PRESENT": "false"])
    t.expectEqual(notPresent.status, 0, "a dialog that never appears is not itself a failure — the scenario decides what it means — \(notPresent.stderr)")
    t.expect(notPresent.stdout.contains("\"present\":false"), "the raw present:false JSON is handed back — got \(notPresent.stdout)")

    let answered = hs_runDriver(rig, #"""
    dialog wait gatekeeper > /dev/null
    a="$(dialog answer gatekeeper allow)"
    printf '%s\n' "$a"
    """#, extraEnv: ["HS_DIALOG_PRESENT": "true"])
    t.expectEqual(answered.status, 0, "answering a present dialog succeeds — \(answered.stderr)")
    t.expect(answered.stdout.contains("\"answered\":\"allow\""), "the answer JSON is handed back — got \(answered.stdout)")
    let evidence = (try? String(contentsOfFile: rig.environment["HARNESS_EVIDENCE"]!, encoding: .utf8)) ?? ""
    t.expect(evidence.contains("CoreServicesUIAgent"), "a successful answer is recorded to HARNESS_EVIDENCE directly (not via the guest-side --evidence flag) — got: \(evidence)")

    let driverError = hs_runDriver(rig, #"dialog answer gatekeeper allow"#, extraEnv: ["HS_DIALOG_KIND": "driver"])
    t.expectEqual(driverError.status, 3, "a \"driver\"-kind response from dialogs.applescript's answer is a harness error — \(driverError.stderr)")

    let logPath = rig.dir.path("timeout.log")
    FileManager.default.createFile(atPath: logPath, contents: Data())
    let clamp = hs_runDriver(rig, #"dialog wait gatekeeper 999 > /dev/null"#, extraEnv: ["HS_DIALOG_PRESENT": "false", "HS_TIMEOUT_LOG": logPath])
    t.expectEqual(clamp.status, 0, "the clamp check itself runs cleanly — \(clamp.stderr)")
    let loggedTimeout = (try? String(contentsOfFile: logPath, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    t.expectEqual(loggedTimeout, "5", "dialog wait's [timeout] is capped at $HARNESS_STEP_TIMEOUT (5) even when 999 is asked for — got '\(loggedTimeout)'")
}

// MARK: - expect_event matches a real line via the real guest/wait.sh, and
// fails (not errors) at its own bound.

private func hs_testExpectEvent(_ t: TestRunner, _ root: URL) {
    guard let rig = hs_makeRig("hs-expect-event", root, t, stepTimeout: 3) else { return }
    defer { rig.dir.cleanup() }
    let journalPath = rig.environment["HARNESS_JOURNAL"]!

    // KTD3 puts the journal inside the app's own harness directory, not in
    // the harness's run directory, so expect_event refuses to guess.
    let unset = hs_runDriver(rig, #"expect_event "setup shown""#)
    t.expectEqual(unset.status, 3, "expect_event with no journal path is a harness error, not a silent wrong path — \(unset.stderr)")
    t.expect(unset.stderr.contains("journal_at"), "and the refusal names journal_at — got: \(unset.stderr)")

    let composed = hs_runDriver(rig, #"""
    HARNESS_GUEST_TRANSPORT=ssh journal_at dev.facens.agentmenu run.ndjson
    printf '%s\n' "$HARNESS_GUEST_JOURNAL"
    """#)
    t.expectEqual(
        composed.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
        "~/Library/Application Support/dev.facens.agentmenu/harness/run.ndjson",
        "journal_at composes KTD3's path from the bundle id and the leaf name"
    )
    for bad in ["dev.facens.agentmenu ../x", "dev/facens run.ndjson", "dev.facens.agentmenu a/b"] {
        let refused = hs_runDriver(rig, "journal_at \(bad)")
        t.expectEqual(refused.status, 3, "journal_at refuses '\(bad)' rather than composing a path out of it")
    }

    try? "{\"seq\":1,\"event\":\"setup shown\",\"data\":{}}\n".write(toFile: journalPath, atomically: true, encoding: .utf8)
    let matched = hs_runDriver(rig, #"""
    HARNESS_GUEST_JOURNAL="$HARNESS_JOURNAL"
    out="$(expect_event "setup shown")"
    printf '%s\n' "$out"
    """#)
    t.expectEqual(matched.status, 0, "expect_event returns 0 on a matching journal line — \(matched.stderr)")
    t.expect(matched.stdout.contains("\"event\":\"setup shown\""), "the matching line is printed — got \(matched.stdout)")

    FileManager.default.createFile(atPath: journalPath, contents: Data())
    let timedOut = hs_runDriver(rig, #"""
    HARNESS_GUEST_JOURNAL="$HARNESS_JOURNAL"
    step "waiting"
    expect_event "never happens"
    """#)
    t.expectEqual(timedOut.status, 1, "expect_event fails the scenario (exit 1) at its bound, never a harness error — \(timedOut.stderr)")
    if let last = hs_stepLines(rig).last {
        t.expectEqual(last["step"] as? String, "waiting", "the failing step is named")
        t.expectEqual(last["status"] as? String, "fail", "and recorded failed")
    } else {
        t.expect(false, "steps.ndjson has a line after the expect_event timeout")
    }
}

// MARK: - fixture refuses an unknown name on the host, before the guest is
// ever touched.

private func hs_testFixtureRefusal(_ t: TestRunner, _ root: URL) {
    guard let rig = hs_makeRig("hs-fixture", root, t) else { return }
    defer { rig.dir.cleanup() }
    // harness/fixtures/ does not exist in this checkout (U9/U10's job).
    let result = hs_runDriver(rig, #"fixture "nope""#)
    t.expectEqual(result.status, 3, "an unknown fixture name is a harness error — \(result.stderr)")
    t.expect(result.stderr.contains("nope"), "the refusal names the unknown fixture — got \(result.stderr)")
}

// MARK: - verdict fail propagates the right exit code; an unrecognized
// outcome is a harness error, not silently accepted.

private func hs_testVerdict(_ t: TestRunner, _ root: URL) {
    guard let rig = hs_makeRig("hs-verdict", root, t) else { return }
    defer { rig.dir.cleanup() }

    let fail = hs_runDriver(rig, #"""
    step "checking"
    verdict fail "gatekeeper refused"
    """#)
    t.expectEqual(fail.status, 1, "verdict fail exits 1 — \(fail.stderr)")
    t.expect(fail.stderr.contains("gatekeeper refused"), "the reason is logged — got \(fail.stderr)")
    if let last = hs_stepLines(rig).last {
        t.expectEqual(last["status"] as? String, "fail", "verdict fail records the open step failed")
    } else {
        t.expect(false, "steps.ndjson has a line after verdict fail")
    }

    let badOutcome = hs_runDriver(rig, #"verdict maybe"#)
    t.expectEqual(badOutcome.status, 3, "an outcome that is neither pass nor fail is a harness error — \(badOutcome.stderr)")
}

// MARK: - install_app validates its app name before the guest is touched
// at all; its success path is not exercised here (see this file's header).

private func hs_testInstallAppValidation(_ t: TestRunner, _ root: URL) {
    guard let rig = hs_makeRig("hs-install-app", root, t) else { return }
    defer { rig.dir.cleanup() }
    let result = hs_runDriver(rig, #"install_app "NotARealApp""#)
    t.expectEqual(result.status, 3, "an unrecognized app name is refused before install.sh is ever reached — \(result.stderr)")
    t.expect(result.stderr.contains("NotARealApp"), "the refusal names the bad value — got \(result.stderr)")
}

// MARK: - expect_event omits --shot-dir on the app-fresh tier, so
// wait.sh's own diagnostic capture on timeout never fires there — pinned
// against the off-tier behaviour, which still takes one.

private func hs_testExpectEventOmitsShotDirOnAppFresh(_ t: TestRunner, _ root: URL) {
    guard let rig = hs_makeRig("hs-expect-event-appfresh-shotdir", root, t, stepTimeout: 2) else { return }
    defer { rig.dir.cleanup() }
    let shotDir = rig.environment["HARNESS_SHOT_DIR"]!
    let journalPath = rig.environment["HARNESS_JOURNAL"]!

    let timedOutDefault = hs_runDriver(rig, #"""
    HARNESS_GUEST_JOURNAL="$HARNESS_JOURNAL"
    step "waiting"
    expect_event "never happens"
    """#)
    t.expectEqual(timedOutDefault.status, 1, "expect_event still fails the scenario at its bound off the app-fresh tier — \(timedOutDefault.stderr)")
    let defaultShots = (try? FileManager.default.contentsOfDirectory(atPath: shotDir)) ?? []
    t.expect(defaultShots.contains { $0.hasSuffix("wait-timeout.png") }, "off the app-fresh tier, wait.sh still takes its own diagnostic screenshot on timeout — got \(defaultShots)")

    FileManager.default.createFile(atPath: journalPath, contents: Data())
    for name in defaultShots {
        try? FileManager.default.removeItem(atPath: "\(shotDir)/\(name)")
    }

    let timedOutAppFresh = hs_runDriver(rig, #"""
    HARNESS_GUEST_JOURNAL="$HARNESS_JOURNAL"
    step "waiting"
    expect_event "never happens"
    """#, extraEnv: ["HARNESS_TIER": "app-fresh"])
    t.expectEqual(timedOutAppFresh.status, 1, "expect_event still fails the scenario at its bound on the app-fresh tier — \(timedOutAppFresh.stderr)")
    let appFreshShots = (try? FileManager.default.contentsOfDirectory(atPath: shotDir)) ?? []
    t.expect(!appFreshShots.contains { $0.hasSuffix("wait-timeout.png") }, "on the app-fresh tier, expect_event passes no --shot-dir, so wait.sh takes no diagnostic screenshot — got \(appFreshShots)")
}

// MARK: - The app-fresh tier shares the maintainer's own screen: every
// helper that clicks, screenshots or waits on a window refuses (exit 2)
// rather than running or silently no-opping, naming both itself and the
// tier. This is the boundary the plan's tier decision settled after an
// app-fresh probe once launched isolated AgentMenu instances and pressed
// a live status item while the maintainer was away.

private func hs_testAppFreshScreenRefusals(_ t: TestRunner, _ root: URL) {
    guard let rig = hs_makeRig("hs-appfresh-screen-refusals", root, t, stepTimeout: 5) else { return }
    defer { rig.dir.cleanup() }
    let shotDir = rig.environment["HARNESS_SHOT_DIR"]!
    let appFresh = ["HARNESS_TIER": "app-fresh"]

    let refusals: [(helper: String, body: String)] = [
        ("shot", #"shot "one""#),
        ("click", #"click "com.example.app" "ax.thing""#),
        ("open_status_item", #"open_status_item "com.example.app""#),
        ("wait_for_status_item", #"wait_for_status_item "com.example.app""#),
        ("ax_window_count", #"ax_window_count "com.example.app""#),
        ("dialog", #"dialog wait gatekeeper"#),
        ("dialog", #"dialog answer gatekeeper allow"#),
        ("dialog", #"dialog probe"#),
    ]
    for (helper, body) in refusals {
        let result = hs_runDriver(rig, body, extraEnv: appFresh)
        t.expectEqual(result.status, 2, "\(helper) refuses on the app-fresh tier (\(body)) — \(result.stderr)")
        t.expect(result.stderr.contains(helper), "the refusal names the helper (\(helper)) — got \(result.stderr)")
        t.expect(result.stderr.contains("app-fresh"), "the refusal names the tier — got \(result.stderr)")
    }

    let shots = (try? FileManager.default.contentsOfDirectory(atPath: shotDir)) ?? []
    t.expect(shots.isEmpty, "not one of the refused helpers actually captured anything — got \(shots)")
    t.expect(hs_stepLines(rig).isEmpty, "none of the refusals opened or closed a step — they are usage errors, not scenario steps")

    // The refusal must not become a silent no-op when a caller reaches it
    // through command substitution used as a condition — `if [
    // "$(ax_window_count "$B")" -gt 0 ]`, exactly how
    // harness/scenarios/agentmenu/smoke.sh calls it. That puts the
    // refusal inside a subshell, where a bare `exit` would only end the
    // subshell (this file's header, fact 2), and an `if` suppresses
    // errexit entirely — without _scenario_refuse_screen's own subshell
    // handling, the scenario would see an empty string and quietly take
    // its false branch and keep going. It must not: the whole scenario
    // dies instead, by signal rather than a clean exit 2 — see
    // _scenario_refuse_screen's own comment for why that trade is made
    // only on this exceptional path.
    let substitutionForm = hs_runDriver(rig, #"""
    if [ "$(ax_window_count "com.example.app")" -gt 0 ]; then
        echo TOOK-TRUE-BRANCH
    else
        echo TOOK-FALSE-BRANCH
    fi
    echo STILL-RUNNING
    """#, extraEnv: appFresh)
    t.expect(substitutionForm.status != 0 && substitutionForm.status != 1, "the whole scenario dies rather than continuing past a refusal reached through command substitution — got exit \(substitutionForm.status), stdout \(substitutionForm.stdout)")
    t.expect(!substitutionForm.stdout.contains("STILL-RUNNING"), "nothing after the refused call ran — got stdout \(substitutionForm.stdout)")
    t.expect(!substitutionForm.stdout.contains("TOOK-TRUE-BRANCH") && !substitutionForm.stdout.contains("TOOK-FALSE-BRANCH"), "the if/else that would otherwise have silently swallowed an empty result never got to run — got stdout \(substitutionForm.stdout)")
    t.expect(substitutionForm.stderr.contains("ax_window_count") && substitutionForm.stderr.contains("app-fresh"), "the refusal message still names the helper and the tier — got \(substitutionForm.stderr)")

    // Off this tier (HARNESS_TIER unset, as every other test in this file
    // leaves it, or explicitly "stranger"), the same calls behave exactly
    // as before — the boundary is exactly HARNESS_TIER=app-fresh, never
    // "any tier value" and never HARNESS_GUEST_TRANSPORT=local (which
    // this whole rig always uses, on every test in this file).
    for tier in ["stranger", ""] {
        let env: [String: String] = tier.isEmpty ? [:] : ["HARNESS_TIER": tier]
        let result = hs_runDriver(rig, #"""
        step "clicking"
        click "com.example.app" "ax.thing"
        verdict pass
        """#, extraEnv: env)
        t.expectEqual(result.status, 0, "click still works with HARNESS_TIER=\(tier.isEmpty ? "(unset)" : tier) — \(result.stderr)")
    }
}

// MARK: - The journal and file-system helpers are unaffected by the
// app-fresh tier: only screen-driving helpers refuse.

private func hs_testAppFreshJournalHelpersStillWork(_ t: TestRunner, _ root: URL) {
    guard let rig = hs_makeRig("hs-appfresh-journal-helpers", root, t, stepTimeout: 3) else { return }
    defer { rig.dir.cleanup() }
    let appFresh = ["HARNESS_TIER": "app-fresh"]
    let journalPath = rig.environment["HARNESS_JOURNAL"]!

    let ok = hs_runDriver(rig, #"""
    step "install"
    finding "no-calendar-accounts"
    verdict pass
    """#, extraEnv: appFresh)
    t.expectEqual(ok.status, 0, "step, finding and verdict pass all still work on the app-fresh tier — \(ok.stderr)")
    t.expectEqual(hs_findingsList(rig), ["no-calendar-accounts"], "finding still records its code")
    if let last = hs_stepLines(rig).last {
        t.expectEqual(last["status"] as? String, "ok", "verdict pass still closes the open step \"ok\" on this tier")
    } else {
        t.expect(false, "steps.ndjson has a line after verdict pass")
    }

    let fixtureRefused = hs_runDriver(rig, #"fixture "nope""#, extraEnv: appFresh)
    t.expectEqual(fixtureRefused.status, 3, "fixture's own unknown-name refusal is unaffected by the tier — \(fixtureRefused.stderr)")

    try? "{\"seq\":1,\"event\":\"setup shown\",\"data\":{}}\n".write(toFile: journalPath, atomically: true, encoding: .utf8)
    let matched = hs_runDriver(rig, #"""
    HARNESS_GUEST_JOURNAL="$HARNESS_JOURNAL"
    out="$(expect_event "setup shown")"
    printf '%s\n' "$out"
    """#, extraEnv: appFresh)
    t.expectEqual(matched.status, 0, "expect_event still matches on the app-fresh tier — \(matched.stderr)")
    t.expect(matched.stdout.contains("\"event\":\"setup shown\""), "the matching line is printed — got \(matched.stdout)")
}

// MARK: - The rig: a real $HARNESS_DIR (this checkout's own harness/), a
// TempDir for run-scoped state, and osascript/screencapture/sips stubbed
// on PATH.

private struct HSRig {
    let dir: TempDir
    let harnessDir: String
    let environment: [String: String]
}

private func hs_makeRig(_ label: String, _ root: URL, _ t: TestRunner, stepTimeout: Int = 5) -> HSRig? {
    let dir = TempDir(label)
    do {
        for (name, body) in [
            ("bin/osascript", hs_osascriptStub),
            ("bin/screencapture", hs_screencaptureStub),
            ("bin/sips", hs_sipsStub),
        ] {
            try dir.write(body + "\n", to: name)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path(name))
        }
        try FileManager.default.createDirectory(atPath: dir.path("rundir/screenshots"), withIntermediateDirectories: true)
        for file in ["steps.ndjson", "findings.list", "journal.ndjson", "evidence.ndjson"] {
            FileManager.default.createFile(atPath: dir.path("rundir/\(file)"), contents: Data())
        }
    } catch {
        t.expect(false, "built the scenario stub rig: \(error)")
        dir.cleanup()
        return nil
    }

    let harnessDir = root.appendingPathComponent("harness").path
    let existingPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
    let environment: [String: String] = [
        "HARNESS_DIR": harnessDir,
        "HARNESS_GUEST_TRANSPORT": "local",
        "HARNESS_GUEST_IP": "local",
        "HARNESS_GUEST_USER": "nobody",
        "HARNESS_GUEST_HOME": ".harness",
        "HARNESS_SHOT_DIR": dir.path("rundir/screenshots"),
        "HARNESS_STEPS": dir.path("rundir/steps.ndjson"),
        "HARNESS_FINDINGS": dir.path("rundir/findings.list"),
        "HARNESS_JOURNAL": dir.path("rundir/journal.ndjson"),
        "HARNESS_EVIDENCE": dir.path("rundir/evidence.ndjson"),
        "HARNESS_STEP_TIMEOUT": "\(stepTimeout)",
        "PATH": dir.path("bin") + ":" + existingPath,
    ]
    return HSRig(dir: dir, harnessDir: harnessDir, environment: environment)
}

/// Writes `body` into a small driver script that sources the real
/// scenario.sh and runs it, then returns the result. `body` is trusted
/// scenario.sh-flavoured bash written by this file's own tests, not
/// external input, so it is interpolated directly — the one value that
/// does need escaping (the real harness directory's path) goes through
/// ShellQuoting.
private func hs_runDriver(_ rig: HSRig, _ body: String, extraEnv: [String: String] = [:]) -> CLIResult {
    let driverPath = rig.dir.path("driver.sh")
    let script = """
    #!/bin/bash
    set -euo pipefail
    . \(ShellQuoting.singleQuoted(rig.harnessDir))/lib/scenario.sh
    \(body)
    """
    do {
        try script.write(toFile: driverPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: driverPath)
    } catch {
        return CLIResult(status: -1, stdout: "", stderr: "could not write the driver script: \(error)")
    }
    var environment = rig.environment
    for (key, value) in extraEnv { environment[key] = value }
    return runProcess("/bin/bash", [driverPath], environment: environment)
}

private func hs_stepLines(_ rig: HSRig) -> [[String: Any]] {
    guard let path = rig.environment["HARNESS_STEPS"],
          let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return content.split(separator: "\n").compactMap { line -> [String: Any]? in
        guard let data = String(line).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}

private func hs_findingsList(_ rig: HSRig) -> [String] {
    guard let path = rig.environment["HARNESS_FINDINGS"],
          let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return content.split(separator: "\n").map(String.init)
}

// MARK: - Stubs
//
// osascript's stub switches on its own $1 (the script path — ax.applescript
// or dialogs.applescript, matched by suffix since guest_run passes a real,
// if fake, guest-side path) and $2 (the verb), and answers with canned JSON
// exactly like the real files would (see both files' own headers on why
// osascript itself always exits 0 and JSON's "kind" is the real signal).
// HS_AX_KIND / HS_DIALOG_KIND, when set, make every ax/dialogs verb return
// that "kind" as an error instead, so a test can drive the notfound/driver
// branches without a live accessibility query. HS_DIALOG_PRESENT controls
// whether "wait" reports a dialog on screen. HS_TIMEOUT_LOG, when set,
// records "wait"'s own timeout argument, so a test can assert on it (the
// dialog() clamp).
private let hs_osascriptStub = #"""
#!/bin/bash
path="$1"
verb="$2"
case "$path" in
  *ax.applescript)
    if [ -n "${HS_AX_KIND:-}" ]; then
      echo '{"error":"stub error","kind":"'"${HS_AX_KIND}"'"}'
      exit 0
    fi
    case "$verb" in
      click) echo '{"clicked":true,"identifier":"stub"}' ;;
      statusclick) echo '{"clicked":true,"idiom":"app-menu-bar-2"}' ;;
      statusitem) echo '{"found":true,"idiom":"app-menu-bar-2"}' ;;
      windows) echo '{"windows":[]}' ;;
      read) echo '{"value":"x","title":"x"}' ;;
      find) echo '{"found":true,"role":"x","title":"x"}' ;;
      *) echo '{"error":"unhandled stub verb","kind":"driver"}' ;;
    esac
    ;;
  *dialogs.applescript)
    case "$verb" in
      wait)
        if [ -n "${HS_TIMEOUT_LOG:-}" ]; then
          echo "$4" >> "$HS_TIMEOUT_LOG"
        fi
        if [ "${HS_DIALOG_PRESENT:-false}" = "true" ]; then
          echo '{"present":true,"process":"CoreServicesUIAgent","title":"X.app","buttons":["Open","Move to Trash"]}'
        else
          echo '{"present":false,"process":null,"title":null,"buttons":[]}'
        fi
        ;;
      answer)
        if [ -n "${HS_DIALOG_KIND:-}" ]; then
          echo '{"error":"stub error","kind":"'"${HS_DIALOG_KIND}"'"}'
        else
          choice="$4"
          echo '{"answered":"'"$choice"'","process":"CoreServicesUIAgent","title":"X.app","button":"Open"}'
        fi
        ;;
      probe) echo '{"dialogs":[]}' ;;
      *) echo '{"error":"unhandled stub verb","kind":"driver"}' ;;
    esac
    ;;
  *) echo '{"error":"unknown script","kind":"driver"}' ;;
esac
exit 0
"""#

/// Ignores what it was asked to capture and writes plain bytes over the
/// script's own 5000-byte floor to its last argument — shot.sh's variance
/// check runs against sips' (also stubbed) reported properties, not the
/// actual pixels, so this never needs to be a real, decodable image.
private let hs_screencaptureStub = #"""
#!/bin/bash
dest="${@: -1}"
head -c 8000 /dev/urandom > "$dest"
"""#

/// Fixed properties matching what the real screencapture stub above
/// writes (8000 bytes at 46x46x3x8 gives a compressed/raw ratio comfortably
/// over shot.sh's default floor), so shot.sh's own variance check passes
/// without a real, decodable PNG on disk.
private let hs_sipsStub = #"""
#!/bin/bash
echo 'pixelWidth: 46'
echo 'pixelHeight: 46'
echo 'samplesPerPixel: 3'
echo 'bitsPerSample: 8'
"""#
