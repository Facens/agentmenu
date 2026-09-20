// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// U3 / KTD2, KTD8: the in-guest driver library a scenario calls over SSH —
/// installing the app like a stranger, finding and clicking controls by
/// AXIdentifier, answering system dialogs, waiting on the journal, and
/// capturing validated screenshots.
///
/// Per U3's own test-scenario list, only wait.sh and shot.sh are exercised
/// end to end here; install.sh, reboot.sh, selfcheck.sh, and the two
/// AppleScript files are exercised only on paths that are safe to run for
/// real on the machine this suite happens to run on — argument validation,
/// and (for shot.sh's internal use and selfcheck.sh) a stubbed
/// `screencapture`/`osascript` on PATH so nothing here ever opens a real
/// window, activates a real app, touches System Events, writes to the real
/// `/Applications`, or reboots anything. Their remaining behavior — a real
/// install, a real click, a real permission grant — is verified on the
/// golden image, per U3's execution note; this suite says so rather than
/// pretending to cover it.
///
/// Unlike the rest of this test target, a missing or non-executable guest
/// script is a recorded failure here, not a silent skip: these seven files
/// are this unit's entire deliverable, and a suite that shrugs at one being
/// absent would never catch it left out of a commit.
func runHarnessGuestTests(_ t: TestRunner) {
    t.suite("HarnessGuest")

    let guestDir = repositoryRoot().appendingPathComponent("harness/guest")

    hg_testInstallShUsage(t, guestDir)
    hg_testWaitSh(t, guestDir)
    hg_testShotSh(t, guestDir)
    hg_testRebootSh(t, guestDir)
    hg_testSelfcheckSh(t, guestDir)
    hg_testAxAppleScriptUsage(t, guestDir)
    hg_testDialogsAppleScriptUsage(t, guestDir)
}

// MARK: - Shared helpers (hg_ prefixed: this file compiles into a shared
// test target alongside files other units are writing concurrently, and a
// bare `requireExecutable` or `writeStub` is exactly the kind of name
// likely to collide).

private func hg_requireExecutable(_ t: TestRunner, _ path: String, _ label: String) -> Bool {
    let ok = FileManager.default.isExecutableFile(atPath: path)
    t.expect(ok, "\(label) exists and is executable at \(path)")
    return ok
}

private func hg_requireReadable(_ t: TestRunner, _ path: String, _ label: String) -> Bool {
    let ok = FileManager.default.isReadableFile(atPath: path)
    t.expect(ok, "\(label) exists and is readable at \(path)")
    return ok
}

/// A PATH-only stub `screencapture` that ignores what it was asked to
/// capture and copies a prepared fixture to its own last argument instead.
/// Real `screencapture -x <path>` takes exactly that shape, so every real
/// caller here (shot.sh directly, and wait.sh/selfcheck.sh through it)
/// works unmodified against the stub — and the real screen is never
/// captured, which could otherwise prompt for a permission this machine
/// may not have granted the test process.
private func hg_writeScreencaptureStub(_ bin: TempDir, fixture: String, log: String) throws {
    let script = """
    #!/bin/bash
    printf 'screencapture %s\\n' "$*" >> \(ShellQuoting.singleQuoted(log))
    dest="${@: -1}"
    cp \(ShellQuoting.singleQuoted(fixture)) "$dest"
    """
    try bin.write(script, to: "bin/screencapture")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path("bin/screencapture"))
}

/// A PATH-only stub `osascript` that never touches System Events: it
/// switches on its own argv the way a fake CLI would, recognizing a plain
/// `-e '...'` probe, `ax.applescript <verb> ...`, and `dialogs.applescript
/// probe`, and answers each with a canned JSON response so selfcheck.sh's
/// own assembly logic can be proven without a live accessibility query.
private func hg_writeOsascriptStub(_ bin: TempDir, log: String, succeed: Bool, probeDialog: Bool = false) throws {
    let dialogsLine = probeDialog
        ? #"echo '{"dialogs":[{"process":"CoreServicesUIAgent","title":"AgentMenu.app","role":"AXWindow","buttons":["Open"]}]}'"#
        : #"echo '{"dialogs":[]}'"#
    let exitCode = succeed ? "0" : "1"
    let script = """
    #!/bin/bash
    printf 'osascript %s\\n' "$*" >> \(ShellQuoting.singleQuoted(log))
    case "$1" in
      -e) exit \(exitCode) ;;
      *ax.applescript)
        verb="$2"
        case "$verb" in
          statusitem) echo '{"found":true,"idiom":"app-menu-bar-2"}' ;;
          list-ids) echo '{"identifiers":["ax.one","ax.two"]}' ;;
          statusclick) echo '{"clicked":true,"idiom":"app-menu-bar-2"}' ;;
          windows) echo '{"windows":[{"name":"AgentMenu","role":"AXWindow"}]}' ;;
          *) echo '{"error":"unhandled stub verb","kind":"driver"}' ;;
        esac
        exit 0
        ;;
      *dialogs.applescript)
        \(dialogsLine)
        exit 0
        ;;
      *) exit 1 ;;
    esac
    """
    try bin.write(script, to: "bin/osascript")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: bin.path("bin/osascript"))
}

private func hg_pathWithStubs(_ bin: TempDir) -> String {
    bin.path("bin") + ":" + (ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin")
}

// Real, valid PNG fixtures, decoded once from a base64 literal rather than
// shelling out to anything at test time (per this unit's build instructions
// — never a live screencapture here).
//
// hg_noisePNGBase64 is a 46x46 random-noise PNG (6462 bytes, measured
// compressed/raw ratio ~1.02) that clears both shot.sh's default 5000-byte
// floor and its 0.01 variance floor — used everywhere a script under test
// needs a capture that PASSES validation.
//
// hg_solidPNGBase64 is a 300x300 solid-colour PNG (685 bytes, measured
// ratio ~0.0025) built the same way — used where a script needs a capture
// that FAILS the variance check specifically (with --min-bytes lowered out
// of the way, since 685 bytes alone would already fail the default byte
// floor and the test would not be proving what it claims to).
private let hg_noisePNGBase64 = "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"
private let hg_solidPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAASwAAAEsCAIAAAD2HxkiAAACdElEQVR42u3TMQ0AAAjAsPk3DRq4eJpUwZI1BTySAEwIJgRMCCYETAgmBEwIJgRMCCYETAgmBEwIJgRMCCYETAgmBEwIJgRMCCYETAgmBEwIJgRMCCYETAgmBEwIJgRMCCYETAgmBEwIJgRMCCYETAgmBEwIJgRMCCYETAgmBEwIJgRMCCYETAgmBEwIJgRMCCYETAgmBEwIJgRMCCYEE0oAJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEEwImBBMCJgQTAiYEE4IJAROCCQETggkBE4IJAROCCQETggkBE4IJAROCCQETggkBE4IJAROCCQETggkBE4IJAROCCQETggkBE4IJAROCCQETggkBE4IJAROCCQETggkBE4IJAROCCQETggkBE4IJAROCCQETggkBE4IJAROCCQETggkBE4IJAROCCQEJwIRgQsCEYELAhGBCwIRgQsCEYELAhGBCwIRgQsCEYELAhGBCwIRgQsCEYELAhGBCwIRgQsCEYELAhGBCwIRgQsCEYELAhGBCwIRgQsCEYELAhGBCwIRgQsCEYELAhGBCwIRgQsCEYELAhGBCwIRgQsCEYELAhGBCwIRgQsCEYEJAAjAhmBAwIZgQMCGYEDAhmBAwIZgQMCGYEDAhmBAwIZgQMCGYEDAhmBAwIZgQMCGYEDAhmBAwIZgQMCGYEDAhmBAwIZgQMCGYEDAhmBAwIZgQOFoBP0TzwHxI0wAAAABJRU5ErkJggg=="

private func hg_writeFixturePNG(_ dir: TempDir, base64: String, name: String) -> String {
    let path = dir.path(name)
    if let data = Data(base64Encoded: base64) {
        FileManager.default.createFile(atPath: path, contents: data)
    }
    return path
}

// MARK: - install.sh
//
// Only the usage-error paths are exercised: every real success path ends
// with `mv` into the real /Applications and a real `open`, which this suite
// must never do on the machine it happens to run on — it could delete a
// real installed app, or pop a "cannot be opened" dialog. The full pipeline
// (unzip, quarantine, move, `defaults read` for the bundle id, `open`) was
// verified by hand against a synthetic zip with a stubbed `open`, isolated
// under a fake $HOME and immediately cleaned up from /Applications
// afterward — see this unit's report for that transcript; it is not
// reproduced as an automated test for the reason above.

private func hg_testInstallShUsage(_ t: TestRunner, _ guestDir: URL) {
    let script = guestDir.appendingPathComponent("install.sh").path
    guard hg_requireExecutable(t, script, "harness/guest/install.sh") else { return }

    do {
        let result = runProcess(script, [])
        t.expectEqual(result.status, 2, "no arguments is a usage error")
        t.expect(result.stderr.contains("--zip and --app are required"), "stderr says what is missing")
    }
    do {
        let result = runProcess(script, ["--zip", "/tmp/agentmenu-harness-does-not-exist.zip", "--app", "AgentMenu"])
        t.expectEqual(result.status, 3, "a missing zip is a harness error, not a usage error")
    }
    do {
        let result = runProcess(script, ["--zip", "/tmp/x.zip", "--app", "NotARealApp"])
        t.expectEqual(result.status, 2, "an unrecognized --app value is a usage error")
        t.expect(result.stderr.contains("AgentMenu or MeetingHop"), "stderr names the two valid apps")
    }
    do {
        let result = runProcess(script, ["--bogus"])
        t.expectEqual(result.status, 2, "an unknown flag is a usage error")
    }
    do {
        let result = runProcess(script, ["-h"])
        t.expectEqual(result.status, 0, "-h exits 0")
        t.expect(result.stdout.contains("install.sh --zip"), "the usage line is printed")
    }
}

// MARK: - wait.sh

private func hg_testWaitSh(_ t: TestRunner, _ guestDir: URL) {
    let script = guestDir.appendingPathComponent("wait.sh").path
    guard hg_requireExecutable(t, script, "harness/guest/wait.sh") else { return }

    // Happy path: the event appears in a growing file partway through the
    // wait, and wait.sh returns as soon as it does, not at the bound.
    do {
        let dir = TempDir("wait-happy")
        defer { dir.cleanup() }
        let journalPath = dir.path("journal.ndjson")
        try? "{\"seq\":1,\"t\":\"x\",\"schema\":1,\"build\":\"0.1.0\",\"nonce\":\"n\",\"event\":\"detecting started\",\"data\":{}}\n"
            .write(toFile: journalPath, atomically: true, encoding: .utf8)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) {
            if let handle = FileHandle(forWritingAtPath: journalPath) {
                handle.seekToEndOfFile()
                handle.write(Data("{\"seq\":2,\"t\":\"x\",\"schema\":1,\"build\":\"0.1.0\",\"nonce\":\"n\",\"event\":\"setup shown\",\"data\":{}}\n".utf8))
                handle.closeFile()
            }
        }

        let started = Date()
        let result = runProcess(script, ["--journal", journalPath, "--event", "setup shown", "--timeout", "10"])
        let elapsed = Date().timeIntervalSince(started)
        t.expectEqual(result.status, 0, "returns 0 once the event line appears")
        t.expect(result.stdout.contains("\"event\":\"setup shown\""), "stdout carries the matching line — got \(result.stdout)")
        t.expect(elapsed < 5, "returned promptly once the event appeared, not at the 10s bound (took \(elapsed)s)")
    }

    // Edge: a field filter ignores an event of the right name but the
    // wrong field, and only matches once the right one is also present.
    do {
        let dir = TempDir("wait-field-filter")
        defer { dir.cleanup() }
        let journalPath = dir.path("journal.ndjson")
        try? "{\"seq\":1,\"t\":\"x\",\"schema\":1,\"build\":\"0.1.0\",\"nonce\":\"n\",\"event\":\"card shown\",\"data\":{\"kind\":\"wrong\"}}\n"
            .write(toFile: journalPath, atomically: true, encoding: .utf8)

        let timedOut = runProcess(script, ["--journal", journalPath, "--event", "card shown", "--field", "kind=zoom", "--timeout", "2"])
        t.expectEqual(timedOut.status, 1, "the wrong-field line alone does not satisfy the filter")

        var content = (try? String(contentsOfFile: journalPath, encoding: .utf8)) ?? ""
        content += "{\"seq\":2,\"t\":\"x\",\"schema\":1,\"build\":\"0.1.0\",\"nonce\":\"n\",\"event\":\"card shown\",\"data\":{\"kind\":\"zoom\"}}\n"
        try? content.write(toFile: journalPath, atomically: true, encoding: .utf8)

        let matched = runProcess(script, ["--journal", journalPath, "--event", "card shown", "--field", "kind=zoom", "--timeout", "2"])
        t.expectEqual(matched.status, 0, "the right-field line satisfies the filter")
        t.expect(matched.stdout.contains("\"kind\":\"zoom\""), "stdout carries the matching line, not the wrong one — got \(matched.stdout)")
    }

    // Error: a bound with no match ever appearing exits 1 and prints a
    // final screenshot path on stderr, with stdout left empty.
    do {
        let dir = TempDir("wait-timeout")
        defer { dir.cleanup() }
        let bin = TempDir("wait-timeout-bin")
        defer { bin.cleanup() }
        let fixture = hg_writeFixturePNG(dir, base64: hg_noisePNGBase64, name: "fixture.png")
        try? hg_writeScreencaptureStub(bin, fixture: fixture, log: dir.path("stub.log"))

        let shotDir = dir.path("shots")
        try? FileManager.default.createDirectory(atPath: shotDir, withIntermediateDirectories: true)

        let result = runProcess(
            script,
            ["--journal", dir.path("never-written.ndjson"), "--event", "never happens", "--timeout", "1", "--shot-dir", shotDir],
            environment: ["PATH": hg_pathWithStubs(bin)]
        )
        t.expectEqual(result.status, 1, "a bound with no match exits 1")
        t.expectEqual(result.stdout, "", "stdout stays empty on timeout — only ever the matching line, never a timeout notice")
        t.expect(result.stderr.contains(shotDir), "stderr names the final screenshot's directory — got \(result.stderr)")
        t.expect(result.stderr.contains(".png"), "stderr names a screenshot file")
        let shots = (try? FileManager.default.contentsOfDirectory(atPath: shotDir)) ?? []
        t.expect(shots.contains { $0.hasSuffix(".png") }, "a screenshot actually landed in --shot-dir")
    }

    // Error: the journal's own directory does not exist — a driver error,
    // reported immediately rather than waited out to the bound.
    do {
        let dir = TempDir("wait-driver-error")
        defer { dir.cleanup() }
        let started = Date()
        let result = runProcess(script, ["--journal", dir.path("nope/journal.ndjson"), "--event", "x", "--timeout", "20"])
        let elapsed = Date().timeIntervalSince(started)
        t.expectEqual(result.status, 3, "a journal whose directory does not exist is a driver error")
        t.expect(elapsed < 5, "the driver error is reported immediately, not waited out to the 20s bound (took \(elapsed)s)")
    }

    // Usage errors.
    do {
        let result = runProcess(script, ["--journal", "/tmp/x"])
        t.expectEqual(result.status, 2, "missing --event is a usage error")
    }
    do {
        let result = runProcess(script, ["--journal", "/tmp/x", "--event", "x", "--field", "no-equals-sign"])
        t.expectEqual(result.status, 2, "a --field without = is a usage error")
    }
}

// MARK: - shot.sh

private func hg_testShotSh(_ t: TestRunner, _ guestDir: URL) {
    let script = guestDir.appendingPathComponent("shot.sh").path
    guard hg_requireExecutable(t, script, "harness/guest/shot.sh") else { return }

    // Happy path: a stubbed screencapture producing a real, varied PNG
    // passes both checks; numbering starts at 001 in a fresh directory and
    // increments from there.
    do {
        let dir = TempDir("shot-happy")
        defer { dir.cleanup() }
        let bin = TempDir("shot-happy-bin")
        defer { bin.cleanup() }
        let fixture = hg_writeFixturePNG(dir, base64: hg_noisePNGBase64, name: "fixture.png")
        let log = dir.path("stub.log")
        try? hg_writeScreencaptureStub(bin, fixture: fixture, log: log)
        let shotsDir = dir.path("shots")

        let first = runProcess(script, ["--dir", shotsDir, "--label", "one"], environment: ["PATH": hg_pathWithStubs(bin)])
        t.expectEqual(first.status, 0, "a valid capture passes")
        t.expect(first.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("001-one.png"), "the first capture is numbered 001 — got \(first.stdout)")

        let second = runProcess(script, ["--dir", shotsDir, "--label", "two"], environment: ["PATH": hg_pathWithStubs(bin)])
        t.expectEqual(second.status, 0, "a second valid capture also passes")
        t.expect(second.stdout.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("002-two.png"), "the second capture is numbered 002 — got \(second.stdout)")

        let stubLog = (try? String(contentsOfFile: log, encoding: .utf8)) ?? ""
        t.expect(stubLog.contains("-x"), "the stub recorded screencapture's -x argument")
    }

    // Error: a zero-byte capture is rejected.
    do {
        let dir = TempDir("shot-zero")
        defer { dir.cleanup() }
        let bin = TempDir("shot-zero-bin")
        defer { bin.cleanup() }
        let fixture = dir.path("empty.png")
        FileManager.default.createFile(atPath: fixture, contents: Data())
        try? hg_writeScreencaptureStub(bin, fixture: fixture, log: dir.path("stub.log"))

        let result = runProcess(script, ["--dir", dir.path("shots"), "--label", "zero"], environment: ["PATH": hg_pathWithStubs(bin)])
        t.expectEqual(result.status, 3, "a zero-byte capture is a harness error")
        t.expect(result.stderr.contains("zero bytes"), "stderr says why — got \(result.stderr)")
    }

    // Error: a real single-colour PNG is rejected on near-zero variance —
    // proven with the real `sips` (not stubbed: sips is read-only image
    // introspection, safe to run for real, unlike screencapture) — with
    // --min-bytes lowered so the byte floor is not what actually fires.
    do {
        let dir = TempDir("shot-solid")
        defer { dir.cleanup() }
        let bin = TempDir("shot-solid-bin")
        defer { bin.cleanup() }
        let fixture = hg_writeFixturePNG(dir, base64: hg_solidPNGBase64, name: "solid.png")
        try? hg_writeScreencaptureStub(bin, fixture: fixture, log: dir.path("stub.log"))

        let result = runProcess(script, ["--dir", dir.path("shots"), "--label", "solid", "--min-bytes", "1"], environment: ["PATH": hg_pathWithStubs(bin)])
        t.expectEqual(result.status, 3, "a single-colour capture is rejected on variance even once the byte floor is out of the way")
        t.expect(result.stderr.contains("variance"), "stderr says why — got \(result.stderr)")
    }

    // The byte floor alone, independent of variance: the same solid-colour
    // fixture at the script's own default --min-bytes is exit 3 for the
    // size reason instead — proves the floor fires on its own.
    do {
        let dir = TempDir("shot-floor")
        defer { dir.cleanup() }
        let bin = TempDir("shot-floor-bin")
        defer { bin.cleanup() }
        let fixture = hg_writeFixturePNG(dir, base64: hg_solidPNGBase64, name: "solid.png")
        try? hg_writeScreencaptureStub(bin, fixture: fixture, log: dir.path("stub.log"))

        let result = runProcess(script, ["--dir", dir.path("shots"), "--label", "floor"], environment: ["PATH": hg_pathWithStubs(bin)])
        t.expectEqual(result.status, 3, "under the default byte floor is also exit 3")
        t.expect(result.stderr.contains("byte floor"), "stderr names the byte floor specifically — got \(result.stderr)")
    }

    // Usage errors.
    do {
        let result = runProcess(script, ["--dir", "/tmp"])
        t.expectEqual(result.status, 2, "missing --label is a usage error")
    }
    do {
        let result = runProcess(script, [])
        t.expectEqual(result.status, 2, "no arguments is a usage error")
    }
}

// MARK: - reboot.sh
//
// Only -h and an unknown argument are safe to exercise: reboot.sh's real
// job is `sudo shutdown -r now`, which this suite must never actually
// invoke on the machine it happens to run on.

private func hg_testRebootSh(_ t: TestRunner, _ guestDir: URL) {
    let script = guestDir.appendingPathComponent("reboot.sh").path
    guard hg_requireExecutable(t, script, "harness/guest/reboot.sh") else { return }

    do {
        let result = runProcess(script, ["-h"])
        t.expectEqual(result.status, 0, "-h exits 0")
        t.expect(result.stdout.contains("reboot.sh"), "the usage line is printed")
    }
    do {
        let result = runProcess(script, ["--bogus"])
        t.expectEqual(result.status, 2, "an unknown argument is a usage error")
    }
}

// MARK: - selfcheck.sh

private func hg_testSelfcheckSh(_ t: TestRunner, _ guestDir: URL) {
    let script = guestDir.appendingPathComponent("selfcheck.sh").path
    guard hg_requireExecutable(t, script, "harness/guest/selfcheck.sh") else { return }
    // selfcheck.sh shells out to these two by relative path; fail loudly
    // here too rather than let a missing one hide behind a confusing exit 3
    // from selfcheck.sh itself.
    _ = hg_requireReadable(t, guestDir.appendingPathComponent("ax.applescript").path, "harness/guest/ax.applescript")
    _ = hg_requireReadable(t, guestDir.appendingPathComponent("dialogs.applescript").path, "harness/guest/dialogs.applescript")

    do {
        let result = runProcess(script, ["--bogus"])
        t.expectEqual(result.status, 2, "an unknown argument is a usage error")
    }
    do {
        let result = runProcess(script, ["-h"])
        t.expectEqual(result.status, 0, "-h exits 0")
        t.expect(result.stdout.contains("selfcheck.sh"), "the usage line is printed")
    }

    // Full run, both `screencapture` and `osascript` stubbed so nothing
    // here touches the real screen or the real accessibility API — this
    // proves selfcheck.sh's own JSON assembly and control flow, not the
    // real grants (those are verified on the image, per U3's execution
    // note).
    do {
        let dir = TempDir("selfcheck-happy")
        defer { dir.cleanup() }
        let bin = TempDir("selfcheck-happy-bin")
        defer { bin.cleanup() }
        let fixture = hg_writeFixturePNG(dir, base64: hg_noisePNGBase64, name: "fixture.png")
        try? hg_writeScreencaptureStub(bin, fixture: fixture, log: dir.path("cap.log"))
        try? hg_writeOsascriptStub(bin, log: dir.path("osa.log"), succeed: true)

        let result = runProcess(
            script,
            ["--shot-dir", dir.path("shots"), "--list-ids", "dev.facens.agentmenu.test"],
            environment: ["PATH": hg_pathWithStubs(bin)]
        )
        t.expectEqual(result.status, 0, "both base grants answering cleanly exits 0")
        guard let json = try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8)) as? [String: Any] else {
            t.expect(false, "selfcheck.sh printed valid JSON — got \(result.stdout)")
            return
        }
        t.expectEqual(json["screencapture"] as? Bool, true, "screencapture reported true")
        t.expectEqual(json["system_events"] as? Bool, true, "system_events reported true")
        t.expectEqual(json["statusitem_idiom"] as? String, "app-menu-bar-2", "the stubbed idiom is passed through")
        t.expectEqual((json["identifiers"] as? [String])?.count, 2, "the stubbed identifier list is passed through")
        t.expectEqual(json["popover_survived"] as? Bool, true, "the popover is reported as having survived")
    }

    // U-defect-2: --list-ids also accepts "pid:<n>" and passes it through to
    // ax.applescript completely unchanged — selfcheck.sh does not parse or
    // rewrite it, ax.applescript's own argv validation is what accepts or
    // rejects the shape (proven for real, read-only, in
    // hg_testAxAppleScriptUsage above).
    do {
        let dir = TempDir("selfcheck-pid")
        defer { dir.cleanup() }
        let bin = TempDir("selfcheck-pid-bin")
        defer { bin.cleanup() }
        let fixture = hg_writeFixturePNG(dir, base64: hg_noisePNGBase64, name: "fixture.png")
        try? hg_writeScreencaptureStub(bin, fixture: fixture, log: dir.path("cap.log"))
        let osaLog = dir.path("osa.log")
        try? hg_writeOsascriptStub(bin, log: osaLog, succeed: true)

        let result = runProcess(
            script,
            ["--shot-dir", dir.path("shots"), "--list-ids", "pid:12345"],
            environment: ["PATH": hg_pathWithStubs(bin)]
        )
        t.expectEqual(result.status, 0, "a pid: target behaves exactly like a bundle id here")
        let log = (try? String(contentsOfFile: osaLog, encoding: .utf8)) ?? ""
        for verb in ["statusitem", "list-ids", "statusclick", "windows"] {
            t.expect(log.contains("\(verb) pid:12345"), "\(verb) was called with pid:12345 unchanged — got log: \(log)")
        }
    }

    // Without --list-ids, the app-specific fields come back null rather
    // than clicking or reading anything unrelated to fill them.
    do {
        let dir = TempDir("selfcheck-no-bundle")
        defer { dir.cleanup() }
        let bin = TempDir("selfcheck-no-bundle-bin")
        defer { bin.cleanup() }
        let fixture = hg_writeFixturePNG(dir, base64: hg_noisePNGBase64, name: "fixture.png")
        try? hg_writeScreencaptureStub(bin, fixture: fixture, log: dir.path("cap.log"))
        try? hg_writeOsascriptStub(bin, log: dir.path("osa.log"), succeed: true)

        let result = runProcess(script, ["--shot-dir", dir.path("shots")], environment: ["PATH": hg_pathWithStubs(bin)])
        t.expectEqual(result.status, 0, "exits 0 with no bundle id, just the base grants")
        let json = (try? JSONSerialization.jsonObject(with: Data(result.stdout.utf8))) as? [String: Any]
        t.expect(json?["statusitem_idiom"] is NSNull, "statusitem_idiom is null with no --list-ids")
        t.expect(json?["identifiers"] is NSNull, "identifiers is null with no --list-ids")
    }

    // A failed capture is exit 1 and, with --evidence given, records
    // whatever dialogs.applescript's probe found on screen — the likely
    // explanation for the failure.
    do {
        let dir = TempDir("selfcheck-fail")
        defer { dir.cleanup() }
        let bin = TempDir("selfcheck-fail-bin")
        defer { bin.cleanup() }
        let fixture = dir.path("empty.png")
        FileManager.default.createFile(atPath: fixture, contents: Data())
        try? hg_writeScreencaptureStub(bin, fixture: fixture, log: dir.path("cap.log"))
        try? hg_writeOsascriptStub(bin, log: dir.path("osa.log"), succeed: true, probeDialog: true)

        let evidencePath = dir.path("evidence.ndjson")
        let result = runProcess(
            script,
            ["--shot-dir", dir.path("shots"), "--evidence", evidencePath],
            environment: ["PATH": hg_pathWithStubs(bin)]
        )
        t.expectEqual(result.status, 1, "a failed base grant is exit 1")
        let evidence = (try? String(contentsOfFile: evidencePath, encoding: .utf8)) ?? ""
        t.expect(evidence.contains("CoreServicesUIAgent"), "the probed dialog's process was recorded to --evidence — got: \(evidence)")
    }
}

// MARK: - ax.applescript (argument validation only)
//
// Finding, clicking and reading a real control needs a live process under
// System Events, which this suite must not touch here — it could trigger
// an Accessibility permission prompt on whatever machine runs it, and the
// real target does not exist until an app under test is installed and
// running anyway. What IS real and safe: every verb validates its argv
// and returns its JSON before ever reaching "tell application System
// Events" (this file's own header explains why the exit code is always 0
// and the JSON's "kind" field is the real signal), and the file compiles.

private func hg_testAxAppleScriptUsage(_ t: TestRunner, _ guestDir: URL) {
    let script = guestDir.appendingPathComponent("ax.applescript").path
    guard hg_requireReadable(t, script, "harness/guest/ax.applescript") else { return }

    do {
        let result = runProcess("/usr/bin/osascript", [script])
        t.expectEqual(result.status, 0, "osascript itself always exits 0 for this file — see its header for why")
        t.expect(result.stdout.contains("\"kind\":\"usage\""), "no verb is a usage-kind JSON error — got \(result.stdout)")
    }
    do {
        let result = runProcess("/usr/bin/osascript", [script, "bogus-verb"])
        t.expect(result.stdout.contains("\"kind\":\"usage\""), "an unknown verb is a usage-kind JSON error")
        t.expect(result.stdout.contains("bogus-verb"), "the error names the unknown verb")
    }
    for verb in ["windows", "find", "click", "read", "statusitem", "statusclick", "list-ids"] {
        let result = runProcess("/usr/bin/osascript", [script, verb])
        t.expect(result.stdout.contains("\"kind\":\"usage\""), "\(verb) with no bundle id is a usage-kind JSON error — got \(result.stdout)")
    }
    do {
        let result = runProcess("/usr/bin/osascript", [script, "find", "com.example.app"])
        t.expect(result.stdout.contains("\"kind\":\"usage\""), "find with a bundle id but no identifier is a usage-kind JSON error")
    }

    // U-defect-2: every verb also accepts "pid:<n>" in place of a bundle id
    // — the only unambiguous way to say which of two same-bundle-id
    // processes to drive (the harness's own app-fresh instance beside the
    // maintainer's own installed AgentMenu). A malformed pid: is rejected
    // as argv shape, before "tell application System Events" — see this
    // file's own header on why that boundary matters — so these are as
    // safe to run for real as every other usage check above.
    for badPid in ["pid:", "pid:abc", "pid:12x3", "pid:-1", "pid:1.5"] {
        let result = runProcess("/usr/bin/osascript", [script, "list-ids", badPid])
        t.expect(result.stdout.contains("\"kind\":\"usage\""), "list-ids \(badPid) is a usage-kind JSON error — got \(result.stdout)")
        t.expect(result.stdout.contains(badPid), "the error names the malformed target — got \(result.stdout)")
    }
    do {
        // A well-shaped pid: that names no running process is a real
        // absence, not a driver error (U-defect-1's own fix) — read-only,
        // and 999999 is never a real pid, so this is safe to run for real.
        let result = runProcess("/usr/bin/osascript", [script, "list-ids", "pid:999999"])
        t.expect(result.stdout.contains("\"kind\":\"notfound\""), "a well-shaped pid: naming no running process is notfound, not driver — got \(result.stdout)")
    }

    // U-defect-3's fix touched locate (find/click/read's shared lookup) and
    // added statusBarWalk (list-ids and find/click/read's status-bar entry
    // point), both reached only after processForTarget's own existence
    // check — so every one of these verbs must still answer "notfound" for
    // a pid: naming no running process, exactly like list-ids above, and
    // never fall through to "kind":"driver" or hang waiting on a process
    // that was never there. This is read-only and needs no live app: the
    // "no such pid" answer comes from `count of (application processes
    // whose unix id is …)`, which this suite already runs for real above.
    for (verb, extraArgs) in [("windows", []), ("find", ["dummy.identifier"]), ("click", ["dummy.identifier"]), ("read", ["dummy.identifier"]), ("statusitem", []), ("statusclick", [])] {
        let result = runProcess("/usr/bin/osascript", [script, verb, "pid:999999"] + extraArgs)
        t.expect(result.stdout.contains("\"kind\":\"notfound\""), "\(verb) pid:999999 is notfound, not driver — got \(result.stdout)")
    }
    do {
        let out = NSTemporaryDirectory() + "ax-compile-check-\(UUID().uuidString).scpt"
        let compiled = runProcess("/usr/bin/osacompile", ["-o", out, script])
        defer { try? FileManager.default.removeItem(atPath: out) }
        t.expectEqual(compiled.status, 0, "the file compiles (syntax only — this does not run it): \(compiled.stderr)")
    }
}

// MARK: - dialogs.applescript (argument validation only)
//
// Locating and answering a real system dialog needs one actually on
// screen, which this suite cannot manufacture safely here — and every
// process name, title and button substring it would match on is UNPINNED
// pending the golden image's first boot (see the file's own header). What
// IS real and safe: argument validation ahead of any System Events access,
// and the file compiles.

private func hg_testDialogsAppleScriptUsage(_ t: TestRunner, _ guestDir: URL) {
    let script = guestDir.appendingPathComponent("dialogs.applescript").path
    guard hg_requireReadable(t, script, "harness/guest/dialogs.applescript") else { return }

    do {
        let result = runProcess("/usr/bin/osascript", [script])
        t.expect(result.stdout.contains("\"kind\":\"usage\""), "no verb is a usage-kind JSON error")
    }
    do {
        let result = runProcess("/usr/bin/osascript", [script, "bogus-verb"])
        t.expect(result.stdout.contains("\"kind\":\"usage\""), "an unknown verb is a usage-kind JSON error")
    }
    do {
        let result = runProcess("/usr/bin/osascript", [script, "wait"])
        t.expect(result.stdout.contains("\"kind\":\"usage\""), "wait with no kind/timeout is a usage-kind JSON error")
    }
    do {
        let result = runProcess("/usr/bin/osascript", [script, "wait", "nope", "5"])
        t.expect(result.stdout.contains("\"kind\":\"usage\""), "an unknown dialog kind is a usage-kind JSON error")
        t.expect(result.stdout.contains("nope"), "the error names the unknown kind")
    }
    do {
        let result = runProcess("/usr/bin/osascript", [script, "wait", "gatekeeper", "not-a-number"])
        t.expect(result.stdout.contains("\"kind\":\"usage\""), "a non-numeric timeout is a usage-kind JSON error")
    }
    do {
        let result = runProcess("/usr/bin/osascript", [script, "answer"])
        t.expect(result.stdout.contains("\"kind\":\"usage\""), "answer with no kind/choice is a usage-kind JSON error")
    }
    do {
        let result = runProcess("/usr/bin/osascript", [script, "answer", "gatekeeper", "maybe"])
        t.expect(result.stdout.contains("\"kind\":\"usage\""), "an unrecognized allow/deny choice is a usage-kind JSON error")
    }
    do {
        let result = runProcess("/usr/bin/osascript", [script, "answer", "gatekeeper", "allow", "trailing-garbage"])
        t.expect(result.stdout.contains("\"kind\":\"usage\""), "unrecognized trailing arguments are a usage-kind JSON error")
    }
    do {
        let out = NSTemporaryDirectory() + "dialogs-compile-check-\(UUID().uuidString).scpt"
        let compiled = runProcess("/usr/bin/osacompile", ["-o", out, script])
        defer { try? FileManager.default.removeItem(atPath: out) }
        t.expectEqual(compiled.status, 0, "the file compiles (syntax only — this does not run it): \(compiled.stderr)")
    }
}
