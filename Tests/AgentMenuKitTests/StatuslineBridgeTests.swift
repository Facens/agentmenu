// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

func runStatuslineBridgeTests(_ t: TestRunner) {
    t.suite("StatuslineBridge")

    runSnapshotTests(t)
    runThrottleTests(t)
    runHistoryTests(t)
    runBridgeScriptTests(t)
    runSettingsUpdateTests(t)
    runInstallStatuslineCLITests(t)
    runFailureModeTests(t)
    runArgv0ResolutionTests(t)
    runMissingBridgeScriptTests(t)
    runChainBackgroundingTests(t)
    runChainSigpipeTests(t)
}

/// Runs the CLI with a wall-clock cap, so a regression that makes the bridge
/// hang (findings #4, #5) fails this test instead of wedging `make test`
/// forever — this test target has no per-test timeout of its own.
///
/// Deliberately does NOT reuse `runCLI` (Harness.swift): same Pipe-based
/// stdout/stderr and background stdin write, just with the bound added. Real
/// pipes are the point, not a workaround — an earlier version of this
/// helper redirected the CLI's own stdout to a temp file, which turned out
/// to hide a real bug rather than exercise the fix for it: `runChain`
/// originally left the chained process's *stderr* inherited from the
/// bridge's own (uninherited-in-turn) stderr, so a backgrounding chain left
/// a grandchild holding that fd open — wedging this harness's stderr read
/// one level up from the bug the reviewer filed. Now that `runChain` gives
/// stderr the same temp-file treatment as stdout, real pipes here are
/// expected to return promptly — which is the actual claim finding #4
/// makes, so the test should exercise the real topology rather than dodge
/// it. Returns nil on timeout; the underlying subprocess is abandoned in
/// that case (acceptable on a failure path that should not occur once the
/// bridge is actually fixed).
private func runCLIBounded(
    _ binary: String, _ args: [String], env: [String: String] = [:], stdin: Data? = nil,
    timeout: TimeInterval = 10
) -> CLIResult? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: binary)
    process.arguments = args
    var environment = ProcessInfo.processInfo.environment
    for (key, value) in env { environment[key] = value }
    process.environment = environment

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    let stdinPipe = Pipe()
    process.standardInput = stdinPipe

    guard (try? process.run()) != nil else { return nil }

    let writer = stdinPipe.fileHandleForWriting
    DispatchQueue.global().async {
        if let stdin { try? writer.write(contentsOf: stdin) }
        try? writer.close()
    }

    let semaphore = DispatchSemaphore(value: 0)
    var outData = Data()
    var errData = Data()
    Thread.detachNewThread {
        // Sequential, like `runCLI`: stdout to EOF, then stderr to EOF, then
        // wait. If either read blocks on a grandchild still holding its
        // pipe open, this whole thread never signals — exactly what the
        // outer `semaphore.wait(timeout:)` below is there to catch.
        outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + timeout) == .success else {
        process.terminate()
        return nil
    }
    return CLIResult(
        status: process.terminationStatus,
        stdout: String(data: outData, encoding: .utf8) ?? "",
        stderr: String(data: errData, encoding: .utf8) ?? ""
    )
}

// MARK: - Fixtures

private func ratePayload(
    fiveHour: (used: Double, resetsAt: TimeInterval)? = nil,
    sevenDay: (used: Double, resetsAt: TimeInterval)? = nil,
    extraTopLevel: [String: Any] = [:]
) -> Data {
    var rateLimits: [String: Any] = [:]
    if let fiveHour {
        rateLimits["five_hour"] = ["used_percentage": fiveHour.used, "resets_at": Int(fiveHour.resetsAt)]
    }
    if let sevenDay {
        rateLimits["seven_day"] = ["used_percentage": sevenDay.used, "resets_at": Int(sevenDay.resetsAt)]
    }
    var object: [String: Any] = ["rate_limits": rateLimits]
    for (key, value) in extraTopLevel { object[key] = value }
    return try! JSONSerialization.data(withJSONObject: object) // fixture: shape is known to be valid
}

// MARK: - Snapshot (happy / edge / error / integration)

private func runSnapshotTests(_ t: TestRunner) {
    let now = Date(timeIntervalSince1970: 1_789_000_000)

    // Happy: both windows present.
    let both = ratePayload(
        fiveHour: (13, 1_788_951_000),
        sevenDay: (42, 1_789_500_000)
    )
    do {
    let data = t.attempt("snapshotJSON with both windows") {
        try snapshotOrThrow(StatuslineBridge.snapshotJSON(from: both, existing: nil, now: now))
    }
    if let data {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        t.expectEqual(object?["v"] as? Int, 1, "snapshot version")
        t.expectEqual(object?["ts"] as? Int, Int(now.timeIntervalSince1970), "snapshot ts is now, in epoch seconds")
        let fiveHour = object?["five_hour"] as? [String: Any]
        t.expectEqual(fiveHour?["used_percentage"] as? Int, 13, "five_hour used_percentage")
        t.expectEqual(fiveHour?["resets_at"] as? Int, 1_788_951_000, "five_hour resets_at")
        t.expect(object?["seven_day"] != nil, "seven_day window present")
    }
    }

    // Edge: seven_day only, and no snapshot to carry anything over from —
    // five_hour must be entirely absent, never a zero.
    let sevenOnly = ratePayload(sevenDay: (8, 1_789_900_000))
    if let data = StatuslineBridge.snapshotJSON(from: sevenOnly, existing: nil, now: now) {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        t.expect(object?["five_hour"] == nil, "five_hour is absent, not zero, when the payload doesn't carry it")
        t.expect(object?["seven_day"] != nil, "seven_day is present")
    } else {
        t.expect(false, "seven_day-only payload should still produce a snapshot")
    }

    // Error: no rate_limits object at all -> nil, nothing to write.
    let noRateLimits = try! JSONSerialization.data(withJSONObject: ["hello": "world"])
    t.expect(StatuslineBridge.snapshotJSON(from: noRateLimits, existing: nil, now: now) == nil, "no rate_limits object -> nil")

    // Error: rate_limits present but empty -> nil (no window to write).
    let emptyRateLimits = try! JSONSerialization.data(withJSONObject: ["rate_limits": [String: Any]()])
    t.expect(StatuslineBridge.snapshotJSON(from: emptyRateLimits, existing: nil, now: now) == nil, "empty rate_limits -> nil")

    // Error: not JSON at all.
    let garbage = Data("not json".utf8)
    t.expect(StatuslineBridge.snapshotJSON(from: garbage, existing: nil, now: now) == nil, "malformed stdin -> nil, not a crash")

    // Integration (scenario 10): round-trips through UsageReader exactly.
    let dir = TempDir("snapshot-roundtrip")
    defer { dir.cleanup() }
    let snapshotURL = URL(fileURLWithPath: dir.path("tb-rate-snapshot.json"))
    if let data = StatuslineBridge.snapshotJSON(from: both, existing: nil, now: now) {
        t.expectNoThrow("writing the snapshot") { try data.write(to: snapshotURL) }
        let reading = UsageReader().read(at: snapshotURL)
        if case .available(let snapshot) = reading {
            t.expectEqual(snapshot.version, 1, "round-tripped version")
            t.expectEqual(Int(snapshot.writtenAt.timeIntervalSince1970), Int(now.timeIntervalSince1970), "round-tripped ts")
            t.expectEqual(snapshot.windows.count, 2, "both windows round-trip")
            t.expectEqual(snapshot.window(.fiveHour)?.usedPercentage, 13, "five_hour used_percentage round-trips")
            t.expectEqual(snapshot.window(.sevenDay)?.usedPercentage, 42, "seven_day used_percentage round-trips")
        } else {
            t.expect(false, "UsageReader should read the snapshot StatuslineBridge wrote as .available, got \(reading)")
        }
    }

    // Scenario 11: seven_day-only payload round-trips to a file UsageReader
    // reads with only seven_day present.
    if let data = StatuslineBridge.snapshotJSON(from: sevenOnly, existing: nil, now: now) {
        let onlyURL = URL(fileURLWithPath: dir.path("seven-only.json"))
        t.expectNoThrow("writing the seven_day-only snapshot") { try data.write(to: onlyURL) }
        if case .available(let snapshot) = UsageReader().read(at: onlyURL) {
            t.expectEqual(snapshot.windows.count, 1, "exactly one window in the file")
            t.expect(snapshot.window(.fiveHour) == nil, "five_hour absent from the read-back snapshot")
            t.expectEqual(snapshot.window(.sevenDay)?.usedPercentage, 8, "seven_day present and correct")
        } else {
            t.expect(false, "seven_day-only snapshot should read back as .available")
        }
    }

    // A payload carrying one window does not erase the other.
    //
    // Every session of an account writes this one file, and an idle session
    // whose last server contact predates the current 5-hour window sends
    // `seven_day` alone. Rebuilding from that payload used to wipe
    // `five_hour` for the whole account — a weekly bar and no 5-hour bar,
    // for days, which is what sent us looking.
    do {
        // `both`'s five_hour resets before `now`; this one is still running,
        // which is the case a carry-over is about.
        let live = ratePayload(fiveHour: (13, 1_789_010_000), sevenDay: (42, 1_789_500_000))
        let previous = StatuslineBridge.snapshotJSON(from: live, existing: nil, now: now)
        let carried = StatuslineBridge.snapshotJSON(
            from: sevenOnly, existing: previous, now: now.addingTimeInterval(60)
        )
        if let carried, let object = (try? JSONSerialization.jsonObject(with: carried)) as? [String: Any] {
            let fiveHour = object["five_hour"] as? [String: Any]
            t.expectEqual(fiveHour?["used_percentage"] as? Int, 13, "five_hour is carried over from the previous snapshot")
            t.expectEqual(fiveHour?["resets_at"] as? Int, 1_789_010_000, "the carried five_hour keeps its own resets_at")
            t.expectEqual((object["seven_day"] as? [String: Any])?["used_percentage"] as? Int, 8, "seven_day is the new payload's")
            t.expectEqual(object["ts"] as? Int, Int(now.timeIntervalSince1970) + 60, "ts is this write's, not the carried window's")
        } else {
            t.expect(false, "a seven_day-only payload over an existing snapshot should still produce a snapshot")
        }

        // The same, the other way round: a five_hour-only payload keeps the
        // weekly window.
        let fiveOnly = ratePayload(fiveHour: (20, 1_789_950_000))
        let carriedWeek = StatuslineBridge.snapshotJSON(
            from: fiveOnly, existing: previous, now: now.addingTimeInterval(60)
        )
        if let carriedWeek, let object = (try? JSONSerialization.jsonObject(with: carriedWeek)) as? [String: Any] {
            t.expectEqual((object["seven_day"] as? [String: Any])?["used_percentage"] as? Int, 42, "seven_day is carried over")
            t.expectEqual((object["five_hour"] as? [String: Any])?["used_percentage"] as? Int, 20, "five_hour is the new payload's")
        } else {
            t.expect(false, "a five_hour-only payload over an existing snapshot should still produce a snapshot")
        }

        // A window that has already passed its own reset is not carried: it
        // describes a window instance that no longer exists.
        let stale = StatuslineBridge.snapshotJSON(
            from: sevenOnly, existing: previous, now: Date(timeIntervalSince1970: 1_789_010_001)
        )
        if let stale, let object = (try? JSONSerialization.jsonObject(with: stale)) as? [String: Any] {
            t.expect(object["five_hour"] == nil, "a five_hour past its resets_at is dropped rather than carried")
        } else {
            t.expect(false, "the stale-carry case should still produce a snapshot")
        }

        // A key this bridge does not own survives its write. The team
        // status-line script writes `suggest` into this same file and
        // `hooks/tokensave.sh` reads it; rebuilding the file from scratch
        // dropped it every time the bridge won the minute.
        let withSuggest = try! JSONSerialization.data(withJSONObject: [
            "v": 1, "ts": Int(now.timeIntervalSince1970), "suggest": "off",
            "five_hour": ["used_percentage": 13, "resets_at": 1_789_010_000],
            "seven_day": ["used_percentage": 42, "resets_at": 1_789_500_000],
        ])
        let preserved = StatuslineBridge.snapshotJSON(
            from: sevenOnly, existing: withSuggest, now: now.addingTimeInterval(60)
        )
        if let preserved, let object = (try? JSONSerialization.jsonObject(with: preserved)) as? [String: Any] {
            t.expectEqual(object["suggest"] as? String, "off", "a key the bridge does not own survives its write")
            t.expectEqual((object["five_hour"] as? [String: Any])?["used_percentage"] as? Int, 13, "and the carried window is still carried")
        } else {
            t.expect(false, "the unknown-key case should still produce a snapshot")
        }

        // A window past its reset that the payload does not carry is removed
        // rather than left behind looking current.
        let rolled = StatuslineBridge.snapshotJSON(
            from: sevenOnly, existing: withSuggest, now: Date(timeIntervalSince1970: 1_789_010_001)
        )
        if let rolled, let object = (try? JSONSerialization.jsonObject(with: rolled)) as? [String: Any] {
            t.expect(object["five_hour"] == nil, "a rolled-over window is dropped from the rewritten file")
            t.expectEqual(object["suggest"] as? String, "off", "dropping it does not take the unknown keys with it")
        } else {
            t.expect(false, "the rolled-over case should still produce a snapshot")
        }

        // The newer payload wins outright, even when its number is lower.
        // These windows roll, so usage inside one resets_at legitimately
        // falls as older usage ages out — 76 of 340 observations in the two
        // history files on the machine this was found on did exactly that.
        // Keeping the high-water mark would pin the readout there forever.
        let lower = ratePayload(fiveHour: (4, 1_789_010_000), sevenDay: (40, 1_789_500_000))
        let replaced = StatuslineBridge.snapshotJSON(
            from: lower, existing: previous, now: now.addingTimeInterval(60)
        )
        if let replaced, let object = (try? JSONSerialization.jsonObject(with: replaced)) as? [String: Any] {
            t.expectEqual(
                (object["five_hour"] as? [String: Any])?["used_percentage"] as? Int, 4,
                "a lower reading for the same window replaces the higher one — these windows roll"
            )
        } else {
            t.expect(false, "the lower-reading case should still produce a snapshot")
        }
    }
}

private func snapshotOrThrow(_ data: Data?) throws -> Data {
    guard let data else { throw CocoaError(.fileReadUnknown) }
    return data
}

// MARK: - Throttle (scenario 12)

private func runThrottleTests(_ t: TestRunner) {
    let base = Date(timeIntervalSince1970: 1_789_000_000)

    t.expect(StatuslineBridge.shouldWrite(existing: nil, now: base), "no existing snapshot -> write")

    let existing = StatuslineBridge.snapshotJSON(from: ratePayload(fiveHour: (10, 1_788_000_000)), existing: nil, now: base)!
    t.expect(
        !StatuslineBridge.shouldWrite(existing: existing, now: base.addingTimeInterval(30)),
        "an existing snapshot younger than 60s -> skip"
    )
    t.expect(
        StatuslineBridge.shouldWrite(existing: existing, now: base.addingTimeInterval(60)),
        "exactly 60s old -> write"
    )
    t.expect(
        StatuslineBridge.shouldWrite(existing: existing, now: base.addingTimeInterval(120)),
        "well past 60s -> write"
    )

    // A payload that knows a window the file does not writes immediately:
    // the throttle is there to stop pointless rewrites, not to keep new
    // information out. Without it the file belongs to whichever session
    // fires first after each 60-second boundary, and an idle one carrying
    // seven_day alone keeps five_hour out of it forever.
    let weekOnlyFile = StatuslineBridge.snapshotJSON(
        from: ratePayload(sevenDay: (3, 1_789_500_000)), existing: nil, now: base
    )!
    let withFiveHour = ratePayload(fiveHour: (7, 1_789_010_000), sevenDay: (3, 1_789_500_000))
    t.expect(
        StatuslineBridge.carriesNewWindow(stdin: withFiveHour, existing: weekOnlyFile, now: base),
        "a payload carrying a window the file lacks is new information"
    )
    t.expect(
        !StatuslineBridge.carriesNewWindow(
            stdin: ratePayload(sevenDay: (9, 1_789_500_000)), existing: weekOnlyFile, now: base
        ),
        "a payload carrying only what the file already has is not"
    )
    t.expect(
        StatuslineBridge.carriesNewWindow(
            stdin: withFiveHour, existing: weekOnlyFile, now: base.addingTimeInterval(30)
        ),
        "…and it does not have to wait out the throttle"
    )
    t.expect(
        !StatuslineBridge.carriesNewWindow(stdin: Data("not json".utf8), existing: weekOnlyFile, now: base),
        "an unreadable payload knows nothing new"
    )

    let corrupt = Data("not json at all".utf8)
    t.expect(StatuslineBridge.shouldWrite(existing: corrupt, now: base), "an unreadable existing file -> write rather than get stuck")

    // Finding #9: a `ts` from the future (clock correction, restored backup,
    // a file copied from a machine with a skewed clock) must not freeze the
    // throttle until real time catches up to it — a future timestamp is as
    // much a reason to write as a stale one, not a reason to wait longer.
    let futureExisting = StatuslineBridge.snapshotJSON(
        from: ratePayload(fiveHour: (10, 1_788_000_000)), existing: nil, now: base.addingTimeInterval(3600)
    )!
    t.expect(
        StatuslineBridge.shouldWrite(existing: futureExisting, now: base),
        "a snapshot timestamped an hour in the future does not permanently block the write"
    )
}

// MARK: - History (hourly rollup)

private func runHistoryTests(_ t: TestRunner) {
    // A fixed local-noon instant so the "same local hour" arithmetic in the
    // test doesn't depend on the machine's timezone crossing a boundary.
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    let hourStart = calendar.date(from: DateComponents(year: 2026, month: 6, day: 15, hour: 12, minute: 0, second: 0))!
    let firstObservation = hourStart.addingTimeInterval(5 * 60)
    let secondObservation = hourStart.addingTimeInterval(40 * 60)

    let firstPayload = ratePayload(fiveHour: (10, 1_800_000_000))
    guard let row1 = StatuslineBridge.historyRow(from: firstPayload, now: firstObservation) else {
        t.expect(false, "historyRow should produce a row for a payload with a window")
        return
    }
    t.expectEqual(row1.hourStart, hourStart, "the row is stamped to the start of the local hour, not the exact moment")

    // A fresh hour creates a row: [used, used, reset, reset].
    let firstText = StatuslineBridge.mergeHistory(existing: nil, row: row1, now: firstObservation)
    let historyAfterFirst = UsageHistory.parse(firstText, now: firstObservation)
    t.expectEqual(historyAfterFirst.rows.count, 1, "one row after the first observation")
    if let observation = historyAfterFirst.rows.first?.windows[.fiveHour] {
        t.expectEqual(observation.usedFirst, 10, "usedFirst on a fresh row")
        t.expectEqual(observation.usedLast, 10, "usedLast equals usedFirst on a fresh row")
        t.expectEqual(observation.resetFirst, observation.resetLast, "resetFirst equals resetLast on a fresh row")
    } else {
        t.expect(false, "expected a five_hour observation in the fresh row")
    }

    // A second observation in the same hour updates last-only, in place —
    // no second row appended.
    let secondPayload = ratePayload(fiveHour: (25, 1_800_003_600))
    guard let row2 = StatuslineBridge.historyRow(from: secondPayload, now: secondObservation) else {
        t.expect(false, "historyRow should produce a row for the second observation")
        return
    }
    let secondText = StatuslineBridge.mergeHistory(existing: firstText, row: row2, now: secondObservation)
    let historyAfterSecond = UsageHistory.parse(secondText, now: secondObservation)
    t.expectEqual(historyAfterSecond.rows.count, 1, "still one row — the second observation updates it, doesn't append")
    if let observation = historyAfterSecond.rows.first?.windows[.fiveHour] {
        t.expectEqual(observation.usedFirst, 10, "usedFirst is unchanged by the second observation")
        t.expectEqual(observation.usedLast, 25, "usedLast moves to the second observation's value")
        t.expectEqual(
            observation.resetFirst, Date(timeIntervalSince1970: 1_800_000_000),
            "resetFirst stays the first observation's reset"
        )
        t.expectEqual(
            observation.resetLast, Date(timeIntervalSince1970: 1_800_003_600),
            "a reset between two observations shows up as a changed resetLast"
        )
    } else {
        t.expect(false, "expected a five_hour observation after merging the second row")
    }

    // A window absent from a later payload stays exactly what it was —
    // never dropped, never zeroed.
    let bothPayload = ratePayload(fiveHour: (10, 1_800_000_000), sevenDay: (50, 1_802_000_000))
    let bothObservation = hourStart.addingTimeInterval(2 * 60)
    let rowBoth = StatuslineBridge.historyRow(from: bothPayload, now: bothObservation)!
    let textWithBoth = StatuslineBridge.mergeHistory(existing: nil, row: rowBoth, now: bothObservation)

    let fiveOnlyPayload = ratePayload(fiveHour: (11, 1_800_000_000))
    let laterObservation = hourStart.addingTimeInterval(10 * 60)
    let rowFiveOnly = StatuslineBridge.historyRow(from: fiveOnlyPayload, now: laterObservation)!
    let mergedText = StatuslineBridge.mergeHistory(existing: textWithBoth, row: rowFiveOnly, now: laterObservation)
    let mergedHistory = UsageHistory.parse(mergedText, now: laterObservation)
    if let windows = mergedHistory.rows.first?.windows {
        t.expectEqual(windows[.fiveHour]?.usedLast, 11, "five_hour updated by the later, five_hour-only observation")
        t.expectEqual(windows[.sevenDay]?.usedLast, 50, "seven_day untouched — absent from the later payload, not zeroed")
    } else {
        t.expect(false, "expected a merged row with both windows still present")
    }

    // Rows older than 28 days are pruned on write.
    let veryOld = hourStart.addingTimeInterval(-40 * 86_400)
    let oldRow = UsageHistoryRow(
        hourStart: veryOld,
        windows: [.fiveHour: WindowObservation(usedFirst: 1, usedLast: 1, resetFirst: veryOld, resetLast: veryOld)]
    )
    let oldLine = String(data: try! JSONSerialization.data(withJSONObject: [
        "h": Int(veryOld.timeIntervalSince1970),
        "five_hour": [1, 1, Int(veryOld.timeIntervalSince1970), Int(veryOld.timeIntervalSince1970)],
    ]), encoding: .utf8)!
    _ = oldRow // constructed for clarity; the raw line above is what mergeHistory actually reads back in
    let existingWithOldRow = oldLine + "\n"
    let prunedText = StatuslineBridge.mergeHistory(existing: existingWithOldRow, row: row1, now: firstObservation)
    let prunedHistory = UsageHistory.parse(prunedText, now: firstObservation.addingTimeInterval(1))
    t.expect(
        !prunedHistory.rows.contains(where: { $0.hourStart == veryOld }),
        "a row older than 28 days is dropped on write"
    )
    t.expect(
        prunedHistory.rows.contains(where: { $0.hourStart == hourStart }),
        "the current row survives pruning"
    )

    // Finding #6: `historyRow` must reject a JSON boolean exactly like
    // `snapshotJSON` does, not fold it in as `used = 1.0` against a
    // 1970 reset epoch — a divergence nothing downstream can catch, because
    // it would land straight in the permanent 28-day file and the learned
    // burn rate.
    let booleanPayload = try! JSONSerialization.data(withJSONObject: [
        "rate_limits": ["five_hour": ["used_percentage": true, "resets_at": 1_800_000_000]],
    ])
    t.expect(
        StatuslineBridge.historyRow(from: booleanPayload, now: firstObservation) == nil,
        "a boolean used_percentage yields no history row, just like it yields no snapshot window"
    )

    // Same guard on `resets_at`, and alongside a real window so the boolean
    // one is dropped rather than poisoning the whole payload.
    let mixedPayload = try! JSONSerialization.data(withJSONObject: [
        "rate_limits": [
            "five_hour": ["used_percentage": 10, "resets_at": 1_800_000_000],
            "seven_day": ["used_percentage": 5, "resets_at": false],
        ],
    ])
    if let row = StatuslineBridge.historyRow(from: mixedPayload, now: firstObservation) {
        t.expect(row.windows[.fiveHour] != nil, "the real window is still present")
        t.expect(row.windows[.sevenDay] == nil, "the boolean resets_at window is dropped, not folded in as epoch 0")
    } else {
        t.expect(false, "a payload with one valid window should still produce a row")
    }
}

// MARK: - Bridge script (happy / edge)

private func runBridgeScriptTests(_ t: TestRunner) {
    let script = StatuslineBridge.bridgeScript(
        cliPath: "/opt/agentmenu/bin/agentmenu",
        profileDirectory: "/Users/x/.claude",
        chain: "bash \"/Users/x/.claude/statusline.sh\""
    )
    t.expect(script.hasPrefix("#!/bin/bash\n"), "the script starts with a shebang")
    t.expect(script.contains("statusline-bridge"), "the script execs the hidden subcommand, not JSON parsing in shell")
    t.expect(script.contains("--profile-dir"), "the script passes --profile-dir")
    t.expect(script.contains("--chain"), "the script passes --chain")

    t.expect(StatuslineBridge.isBridgeCommand("\"/Users/x/.claude/agentmenu-statusline.sh\""), "a command naming the bridge script is recognised")
    t.expect(!StatuslineBridge.isBridgeCommand("bash \"/Users/x/.claude/statusline.sh\""), "an unrelated command is not mistaken for the bridge")

    // Round-trips a chain containing an embedded single quote through the
    // same escaping `bridgeScript` writes and `existingChain` reverses.
    let trickyChain = "bash \"/Users/x/it's a path/statusline.sh\""
    let trickyScript = StatuslineBridge.bridgeScript(cliPath: "/bin/agentmenu", profileDirectory: "/x", chain: trickyChain)
    t.expectEqual(StatuslineBridge.existingChain(inScript: trickyScript), trickyChain, "a chain with an embedded quote round-trips")

    let emptyChainScript = StatuslineBridge.bridgeScript(cliPath: "/bin/agentmenu", profileDirectory: "/x", chain: "")
    t.expectEqual(StatuslineBridge.existingChain(inScript: emptyChainScript), "", "no chain configured round-trips as an empty string, not nil")

    t.expect(StatuslineBridge.existingChain(inScript: "no --chain marker here") == nil, "a script without the marker yields nil")
}

// MARK: - settings.json update (happy / edge / error)

private func runSettingsUpdateTests(_ t: TestRunner) {
    let withExistingStatusLine = """
    {
      "env": {
        "OBSIDIAN_VAULT_PATH": "/x"
      },
      "model": "opus",
      "statusLine": {
        "type": "command",
        "command": "bash \\"/Users/x/.claude/statusline.sh\\"",
        "refreshInterval": 60
      },
      "theme": "light"
    }
    """

    do {
    let update = t.attempt("settingsUpdate chains to an existing non-bridge command") {
        try StatuslineBridge.settingsUpdate(
            original: withExistingStatusLine, scriptPath: "/x/.claude/agentmenu-statusline.sh",
            existingBridgeScriptContents: nil
        )
    }
    if let update {
        t.expectEqual(update.chain, "bash \"/Users/x/.claude/statusline.sh\"", "recovers the previously configured command as the chain")
        t.expect(!update.alreadyInstalled, "not already installed")

        // Scenario 13: every OTHER key survives byte-for-byte — not just
        // JSON-equal, but the literal substring, whitespace included.
        t.expect(update.text.contains("  \"env\": {\n    \"OBSIDIAN_VAULT_PATH\": \"/x\"\n  },"), "the env block's exact bytes survive")
        t.expect(update.text.contains("\"model\": \"opus\","), "the model key's exact bytes survive")
        t.expect(update.text.contains("\"theme\": \"light\""), "the theme key's exact bytes survive")

        // And it is valid JSON with the new statusLine command in it.
        let parsed = (try? JSONSerialization.jsonObject(with: Data(update.text.utf8))) as? [String: Any]
        let statusLine = parsed?["statusLine"] as? [String: Any]
        t.expect((statusLine?["command"] as? String)?.contains("agentmenu-statusline.sh") ?? false, "new statusLine.command points at the bridge script")
    }
    }

    // No statusLine configured at all: chain is empty, and a key is still
    // inserted into the object without disturbing the other keys.
    let withoutStatusLine = """
    {
      "model": "opus"
    }
    """
    do {
    let update = t.attempt("settingsUpdate with no existing status line") {
        try StatuslineBridge.settingsUpdate(
            original: withoutStatusLine, scriptPath: "/x/.claude/agentmenu-statusline.sh",
            existingBridgeScriptContents: nil
        )
    }
    if let update {
        t.expectEqual(update.chain, "", "nothing to chain to")
        let parsed = (try? JSONSerialization.jsonObject(with: Data(update.text.utf8))) as? [String: Any]
        t.expect(parsed?["statusLine"] != nil, "statusLine was inserted")
        t.expectEqual(parsed?["model"] as? String, "opus", "the pre-existing key survives the insert")
    }
    }

    // An empty object still gets the key inserted validly.
    do {
    let update = t.attempt("settingsUpdate on an empty settings file") {
        try StatuslineBridge.settingsUpdate(original: "{}", scriptPath: "/x/.claude/agentmenu-statusline.sh", existingBridgeScriptContents: nil)
    }
    if let update {
        let parsed = (try? JSONSerialization.jsonObject(with: Data(update.text.utf8))) as? [String: Any]
        t.expect(parsed?["statusLine"] != nil, "statusLine inserted into a previously-empty object")
    }
    }

    // Scenario 8 at the Kit level: a statusLine that already runs the bridge
    // recovers its existing chain instead of wrapping itself again.
    let bridgeScript = StatuslineBridge.bridgeScript(
        cliPath: "/x/agentmenu", profileDirectory: "/x/.claude", chain: "bash \"/x/.claude/original.sh\""
    )
    let alreadyBridged = """
    {
      "model": "opus",
      "statusLine": {
        "type": "command",
        "command": "\\"/x/.claude/agentmenu-statusline.sh\\""
      }
    }
    """
    do {
    let update = t.attempt("settingsUpdate recognises an already-installed bridge") {
        try StatuslineBridge.settingsUpdate(
            original: alreadyBridged, scriptPath: "/x/.claude/agentmenu-statusline.sh",
            existingBridgeScriptContents: bridgeScript
        )
    }
    if let update {
        t.expect(update.alreadyInstalled, "recognised as already installed")
        t.expectEqual(update.chain, "bash \"/x/.claude/original.sh\"", "recovers the chain from the existing script rather than nesting")
    }
    }

    // A profile whose settings name ANOTHER profile's bridge script. The
    // installed script resolves its profile from CLAUDE_CONFIG_DIR at run
    // time, so pointing at a sibling's copy works and is an easy state to
    // end up in — found on the maintainer's machine, where the personal
    // profile's settings named the work profile's script and every
    // `install-statusline --profile personal` refused. `bridgeScriptPath`
    // is what tells the installer which file actually holds the chain.
    do {
        let foreign = """
        {
          "statusLine": {
            "type": "command",
            "command": "\\"/x/.claude/agentmenu-statusline.sh\\""
          }
        }
        """
        t.expectEqual(
            StatuslineBridge.bridgeScriptPath(inCommand: "\"/x/.claude/agentmenu-statusline.sh\""),
            "/x/.claude/agentmenu-statusline.sh",
            "the script path is read out of a double-quoted command"
        )
        t.expectEqual(
            StatuslineBridge.bridgeScriptPath(inCommand: "bash '/x/.claude-personal/agentmenu-statusline.sh'"),
            "/x/.claude-personal/agentmenu-statusline.sh",
            "…and out of a single-quoted one with an interpreter in front"
        )
        t.expect(
            StatuslineBridge.bridgeScriptPath(inCommand: "bash \"/x/.claude/statusline-command.sh\"") == nil,
            "a command that runs no bridge script has no bridge script path"
        )

        // The chain comes from the script the command names — here the work
        // profile's — and the install proceeds instead of refusing.
        let update = t.attempt("settingsUpdate takes the chain from the foreign bridge script") {
            try StatuslineBridge.settingsUpdate(
                original: foreign,
                scriptPath: "/x/.claude-personal/agentmenu-statusline.sh",
                existingBridgeScriptContents: bridgeScript
            )
        }
        if let update {
            t.expect(update.alreadyInstalled, "a bridge at another path still counts as installed")
            t.expectEqual(update.chain, "bash \"/x/.claude/original.sh\"", "the chain is recovered from it")
            let parsed = (try? JSONSerialization.jsonObject(with: Data(update.text.utf8))) as? [String: Any]
            let command = (parsed?["statusLine"] as? [String: Any])?["command"] as? String
            t.expectEqual(
                command, "\"/x/.claude-personal/agentmenu-statusline.sh\"",
                "settings are repointed at this profile's own script"
            )
        }

        // And the refusal still stands when that script genuinely cannot be
        // read: the chain lives nowhere else, so it would be lost.
        t.expectThrows("an unreadable bridge script is still refused") {
            _ = try StatuslineBridge.settingsUpdate(
                original: foreign,
                scriptPath: "/x/.claude-personal/agentmenu-statusline.sh",
                existingBridgeScriptContents: nil
            )
        }
    }

    // Finding #8: a depth-1 string *value* equal to "statusLine" must not be
    // mistaken for the key — `matchesKey` used to accept the position on
    // seeing the closing quote alone, without checking a `:` follows. The
    // re-parse-and-diff guard already keeps this safe (it throws rather than
    // splicing in the wrong place), but the refusal was unexplainable; after
    // the fix the install just succeeds.
    let valueLooksLikeKey = """
    {
      "someKey": "statusLine",
      "model": "opus"
    }
    """
    t.expectNoThrow("a string value equal to \"statusLine\" is not mistaken for the key") {
        let update = try StatuslineBridge.settingsUpdate(
            original: valueLooksLikeKey, scriptPath: "/x/.claude/agentmenu-statusline.sh",
            existingBridgeScriptContents: nil
        )
        let parsed = (try? JSONSerialization.jsonObject(with: Data(update.text.utf8))) as? [String: Any]
        t.expectEqual(parsed?["someKey"] as? String, "statusLine", "the unrelated string value survives untouched")
        t.expectEqual(parsed?["model"] as? String, "opus", "the unrelated key survives")
        t.expect((parsed?["statusLine"] as? [String: Any]) != nil, "a real statusLine key was inserted")
    }

    // Error: malformed JSON is refused, not guessed at.
    t.expectThrows("settingsUpdate on malformed JSON throws") {
        try StatuslineBridge.settingsUpdate(original: "{ not json", scriptPath: "/x/s.sh", existingBridgeScriptContents: nil)
    }

    // Error: a JSON array at the root is not an object to add a key to.
    t.expectThrows("settingsUpdate on a non-object root throws") {
        try StatuslineBridge.settingsUpdate(original: "[1, 2, 3]", scriptPath: "/x/s.sh", existingBridgeScriptContents: nil)
    }
}

// MARK: - `agentmenu install-statusline` (integration: scenarios 7, 8, 9)

private func runInstallStatuslineCLITests(_ t: TestRunner) {
    guard let binary = agentMenuCLIBinary() else {
        print("   (skipped: .build/debug/AgentMenuCLI not built — run 'swift build' first)")
        return
    }

    let dir = TempDir("install-statusline-cli")
    defer { dir.cleanup() }

    let claudeDir = dir.path("claude")
    try? FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)

    // A real chained script: copies stdin to a file and prints a marker, so
    // the pass-through can be proven rather than assumed.
    let chainScriptPath = dir.path("original-statusline.sh")
    let chainStdinCapturePath = dir.path("chain-stdin-capture.json")
    let chainScript = """
    #!/bin/bash
    cat > \(ShellQuoting.singleQuoted(chainStdinCapturePath))
    echo "ORIGINAL-STATUSLINE-MARKER"
    """
    try? chainScript.write(toFile: chainScriptPath, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: chainScriptPath)

    let settingsPath = dir.path("claude/settings.json")
    let settingsText = """
    {
      "env": {
        "SOME_VAR": "kept"
      },
      "statusLine": {
        "type": "command",
        "command": "\\"\(chainScriptPath)\\"",
        "refreshInterval": 60
      },
      "otherSetting": 42
    }
    """
    try? settingsText.write(toFile: settingsPath, atomically: true, encoding: .utf8)

    let configPath = dir.path("config.toml")
    let configText = """
    schema = 1
    active_profile = "work"

    [[profiles]]
    id = "work"
    name = "Work"
    config_dir = "\(claudeDir)"
    """
    try? configText.write(toFile: configPath, atomically: true, encoding: .utf8)
    let env = ["AGENTMENU_CONFIG": configPath]

    // Scenario 9, "before": name the file and key, write nothing on dry-run.
    let listingBeforeDryRun = (try? FileManager.default.contentsOfDirectory(atPath: claudeDir))?.sorted() ?? []
    do {
    let dryRun = t.attempt("install-statusline --dry-run") {
        try runCLI(binary, ["install-statusline", "--dry-run"], env: env)
    }
    if let dryRun {
        t.expectEqual(dryRun.status, 0, "dry run exits 0")
        t.expect(dryRun.stdout.contains(settingsPath), "names the settings file before writing")
        t.expect(dryRun.stdout.contains("statusLine.command"), "names the key before writing")
        let listingAfterDryRun = (try? FileManager.default.contentsOfDirectory(atPath: claudeDir))?.sorted() ?? []
        t.expectEqual(listingAfterDryRun, listingBeforeDryRun, "a dry run creates nothing — not even the script")
        t.expectEqual(
            (try? String(contentsOfFile: settingsPath, encoding: .utf8)), settingsText,
            "a dry run does not touch settings.json either"
        )
    }
    }

    // Scenario 9, "after": the real install adds exactly one file.
    do {
    let install = t.attempt("install-statusline (real run)") {
        try runCLI(binary, ["install-statusline"], env: env)
    }
    if let install {
        t.expectEqual(install.status, 0, "install exits 0")
        let listingAfter = Set((try? FileManager.default.contentsOfDirectory(atPath: claudeDir)) ?? [])
        let added = listingAfter.subtracting(listingBeforeDryRun)
        t.expectEqual(added, [StatuslineBridge.scriptFilename], "exactly one new file appears: the bridge script")
    }
    }

    // Scenario 13: every other settings.json key survives.
    do {
    let newSettings = t.attempt("reading settings.json after install") {
        try String(contentsOfFile: settingsPath, encoding: .utf8)
    }
    if let newSettings {
        t.expect(newSettings.contains("\"SOME_VAR\": \"kept\""), "unrelated env key survives byte-for-byte")
        t.expect(newSettings.contains("\"otherSetting\": 42"), "unrelated top-level key survives byte-for-byte")
    }
    }

    // Scenario 7: the bridge script chains to the original command, which
    // still receives the same stdin.
    let scriptPath = dir.path("claude/\(StatuslineBridge.scriptFilename)")
    t.expect(FileManager.default.isExecutableFile(atPath: scriptPath), "the installed script is executable")

    let payload = ratePayload(fiveHour: (17, 1_820_000_000))
    do {
    let runResult = t.attempt("running the installed bridge script with a real payload") {
        try runScript(scriptPath, stdin: payload)
    }
    if let runResult {
        t.expect(runResult.stdout.contains("ORIGINAL-STATUSLINE-MARKER"), "the original status line's own stdout still appears")
        t.expectEqual(runResult.status, 0, "the chained script's exit status propagates")

        let captured = try? Data(contentsOf: URL(fileURLWithPath: chainStdinCapturePath))
        t.expect(captured == payload, "the original command receives exactly the same stdin bytes Claude Code sent")

        let snapshotURL = URL(fileURLWithPath: dir.path("claude/\(StatuslineBridge.snapshotFilename)"))
        if case .available(let snapshot) = UsageReader().read(at: snapshotURL) {
            t.expectEqual(snapshot.window(.fiveHour)?.usedPercentage, 17, "the bridge also wrote the snapshot alongside chaining")
        } else {
            t.expect(false, "expected the bridge to have written a readable snapshot")
        }
    }
    }

    // The bug this exists to prevent: two accounts can share one settings.json
    // (a symlink between profile directories is ordinary), so one status-line
    // command serves both. With the profile baked into the script, the second
    // account wrote its rate-limit data into the first account's directory and
    // the two accounts' usage merged into one history.
    do {
    let other = TempDir("bridge-other-profile")
    defer { other.cleanup() }
    let otherProfile = other.path("claude-personal")
    try? FileManager.default.createDirectory(atPath: otherProfile, withIntermediateDirectories: true)

    let crossing = t.attempt("running the installed script as another account") {
        try runScript(scriptPath, stdin: ratePayload(fiveHour: (61, 1_820_000_000)), configDir: otherProfile)
    }
    if crossing != nil {
        let theirs = URL(fileURLWithPath: otherProfile).appendingPathComponent(StatuslineBridge.snapshotFilename)
        if case .available(let snapshot) = UsageReader().read(at: theirs) {
            t.expectEqual(snapshot.window(.fiveHour)?.usedPercentage, 61,
                          "the session's own CLAUDE_CONFIG_DIR decides where its usage is written")
        } else {
            t.expect(false, "the other account's snapshot should have been written")
        }
        let installed = URL(fileURLWithPath: dir.path("claude/\(StatuslineBridge.snapshotFilename)"))
        if case .available(let snapshot) = UsageReader().read(at: installed) {
            t.expect(snapshot.window(.fiveHour)?.usedPercentage != 61,
                     "and never into the directory the script was installed for")
        }
    }
    }

    // Scenario 8: installing again does not nest the bridge inside itself.
    let scriptContentsAfterFirstInstall = (try? String(contentsOfFile: scriptPath, encoding: .utf8)) ?? ""

    do {
    let secondInstall = t.attempt("install-statusline a second time") {
        try runCLI(binary, ["install-statusline"], env: env)
    }
    if let secondInstall {
        t.expectEqual(secondInstall.status, 0, "second install exits 0")
        t.expect(secondInstall.stdout.contains("already runs the agentmenu bridge"), "reports that it recognised the existing bridge")

        let scriptContentsAfterSecondInstall = (try? String(contentsOfFile: scriptPath, encoding: .utf8)) ?? ""
        t.expectEqual(
            scriptContentsAfterSecondInstall, scriptContentsAfterFirstInstall,
            "the script is byte-identical after a second install — chaining to the recovered original, not to itself"
        )
        t.expect(
            scriptContentsAfterSecondInstall.contains(chainScriptPath),
            "the script still chains to the ORIGINAL command"
        )
        let ownFilenameOccurrences = scriptContentsAfterSecondInstall
            .components(separatedBy: StatuslineBridge.scriptFilename).count - 1
        t.expectEqual(ownFilenameOccurrences, 0, "the script never references its own filename — no nested self-invocation")

        // The chain still works after a second install.
        let runResult = t.attempt("running the bridge after a second install") {
            try runScript(scriptPath, stdin: payload)
        }
        if let runResult {
            t.expect(runResult.stdout.contains("ORIGINAL-STATUSLINE-MARKER"), "chaining still works after installing twice")
        }
    }
    }
}

/// Runs an installed bridge script.
///
/// `CLAUDE_CONFIG_DIR` is cleared unless the caller sets it: the script now
/// resolves the profile from that variable, so a test that inherited the
/// developer's own would write into their real agent directory — which is both
/// a corrupted test and a corrupted machine.
private func runScript(_ path: String, stdin: Data, configDir: String? = nil) throws -> CLIResult {
    // The helper merges overrides onto the real environment, so a key cannot be
    // removed — but the script uses `${CLAUDE_CONFIG_DIR:-…}`, which treats
    // empty exactly like unset. That is the fallback path this exercises.
    return try runCLI(path, [], env: ["CLAUDE_CONFIG_DIR": configDir ?? ""], stdin: stdin)
}

// MARK: - Failure modes: chain failure propagates, write failure is swallowed

private func runFailureModeTests(_ t: TestRunner) {
    guard let binary = agentMenuCLIBinary() else {
        print("   (skipped: .build/debug/AgentMenuCLI not built — run 'swift build' first)")
        return
    }

    let dir = TempDir("bridge-failure-modes")
    defer { dir.cleanup() }

    let payload = ratePayload(fiveHour: (5, 1_830_000_000))

    // A chain that fails propagates its exit status untouched.
    let profileDir = dir.path("profile")
    try? FileManager.default.createDirectory(atPath: profileDir, withIntermediateDirectories: true)
    let chainFailure = t.attempt("statusline-bridge propagates a chain's non-zero exit status") {
        try runCLI(binary, ["statusline-bridge", "--profile-dir", profileDir, "--chain", "exit 3"], stdin: payload)
    }
    if let chainFailure {
        t.expectEqual(chainFailure.status, 3, "the chain's own exit status propagates untouched, not swallowed to 0 or 1")
    }

    // A directory the bridge cannot write into must not take the chained
    // status line down with it — R47's "never fail the status line".
    let unwritableDir = dir.path("unwritable")
    try? FileManager.default.createDirectory(atPath: unwritableDir, withIntermediateDirectories: true)
    try? FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: unwritableDir)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: unwritableDir) }

    let markerScript = dir.path("marker.sh")
    try? "#!/bin/bash\necho MARKER-SURVIVES\n".write(toFile: markerScript, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: markerScript)

    let writeFailure = t.attempt("a snapshot write failure is swallowed — the chain's output still appears") {
        try runCLI(binary, ["statusline-bridge", "--profile-dir", unwritableDir, "--chain", markerScript], stdin: payload)
    }
    if let writeFailure {
        t.expectEqual(writeFailure.status, 0, "the chain still succeeded, so the bridge exits 0 despite the failed write")
        t.expect(writeFailure.stdout.contains("MARKER-SURVIVES"), "the chained command's stdout still appears")
        let snapshotInUnwritableDir = (unwritableDir as NSString).appendingPathComponent(StatuslineBridge.snapshotFilename)
        t.expect(
            !FileManager.default.fileExists(atPath: snapshotInUnwritableDir),
            "nothing was written to the unwritable directory — the failure was swallowed, not silently retried elsewhere"
        )
    }

    // MARK: The rest of the statusLine object is the user's

    // refreshInterval is a real key Claude Code writes, and rebuilding the
    // statusLine object from scratch quietly reset it — caught by installing
    // against a copy of a real settings file rather than a minimal fixture.
    let keepDir = TempDir("statusline-keeps-siblings")
    defer { keepDir.cleanup() }
    t.expectNoThrow("install preserves the other statusLine keys") {
        let settings = """
        {
          "model": "opus",
          "statusLine": {"type": "command", "command": "bash \\"/tmp/original.sh\\"", "refreshInterval": 60},
          "theme": "dark"
        }
        """
        try keepDir.write(settings, to: "settings.json")
        let url = keepDir.url.appendingPathComponent("settings.json")
        let updated = try StatuslineBridge.settingsUpdate(
            original: try String(contentsOf: url, encoding: .utf8),
            scriptPath: keepDir.path("agentmenu-statusline.sh"),
            existingBridgeScriptContents: nil
        )
        let object = try JSONSerialization.jsonObject(with: Data(updated.text.utf8)) as? [String: Any]
        let statusLine = object?["statusLine"] as? [String: Any]
        t.expectEqual(statusLine?["refreshInterval"] as? Int, 60, "refreshInterval survives the install")
        t.expectEqual(statusLine?["type"] as? String, "command", "type survives the install")
        t.expect((statusLine?["command"] as? String)?.contains("agentmenu-statusline.sh") == true,
                 "command now points at the bridge")
        t.expectEqual(object?["theme"] as? String, "dark", "unrelated keys are untouched")
    }

}

// MARK: - `install-statusline` resolves the running binary, not argv[0] (finding #2)

private func runArgv0ResolutionTests(_ t: TestRunner) {
    guard let cliBinaryPath = agentMenuCLIBinary() else {
        print("   (skipped: .build/debug/AgentMenuCLI not built — run 'swift build' first)")
        return
    }

    let dir = TempDir("install-statusline-argv0")
    defer { dir.cleanup() }

    // A bin directory on PATH holding only a bare-name symlink to the real
    // CLI — reproducing the documented Homebrew-cask install, where argv[0]
    // as the process sees it is the bare name "agentmenu", not a path.
    let binDir = dir.path("bin")
    try? FileManager.default.createDirectory(atPath: binDir, withIntermediateDirectories: true)
    let bareNamePath = (binDir as NSString).appendingPathComponent("agentmenu")
    try? FileManager.default.createSymbolicLink(atPath: bareNamePath, withDestinationPath: cliBinaryPath)

    let claudeDir = dir.path("claude")
    try? FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)
    let configPath = dir.path("config.toml")
    let configText = """
    schema = 1
    active_profile = "work"

    [[profiles]]
    id = "work"
    name = "Work"
    config_dir = "\(claudeDir)"
    """
    try? configText.write(toFile: configPath, atomically: true, encoding: .utf8)

    // A cwd that is NOT where the real binary lives: before the fix,
    // resolving argv[0] against the current directory would have produced
    // "<this dir>/agentmenu", which doesn't exist here either — proving the
    // resolution isn't accidentally right for the wrong reason.
    let emptyCwd = dir.path("empty-cwd")
    try? FileManager.default.createDirectory(atPath: emptyCwd, withIntermediateDirectories: true)

    // Run via a shell so it's the SHELL doing the PATH lookup and exec'ing
    // us by the bare name — exactly how a Homebrew-installed `agentmenu` on
    // a user's PATH gets invoked, and exactly what made argv[0] the bare
    // name rather than a path.
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", "agentmenu install-statusline"]
    process.currentDirectoryURL = URL(fileURLWithPath: emptyCwd)
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = binDir + ":" + (environment["PATH"] ?? "/usr/bin:/bin")
    environment["AGENTMENU_CONFIG"] = configPath
    process.environment = environment

    let stdoutPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardInput = Pipe()

    let semaphore = DispatchSemaphore(value: 0)
    var status: Int32?
    Thread.detachNewThread {
        do {
            try process.run()
            process.waitUntilExit()
            status = process.terminationStatus
        } catch {
            // status stays nil; reported as a failure below.
        }
        semaphore.signal()
    }
    guard semaphore.wait(timeout: .now() + 10) == .success else {
        t.expect(false, "install-statusline invoked by bare name via PATH did not return in time")
        return
    }
    let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

    t.expectEqual(status, 0, "install-statusline invoked by bare name (argv[0] with no '/') still succeeds — stdout: \(stdout)")

    let scriptPath = (claudeDir as NSString).appendingPathComponent(StatuslineBridge.scriptFilename)
    guard let scriptContents = try? String(contentsOfFile: scriptPath, encoding: .utf8) else {
        t.expect(false, "expected the bridge script to be written — stdout was: \(stdout)")
        return
    }
    guard let execRange = scriptContents.range(of: "exec '"),
          let endRange = scriptContents.range(of: "' statusline-bridge") else {
        t.expect(false, "could not find the exec target in the bridge script: \(scriptContents)")
        return
    }
    let execTarget = String(scriptContents[execRange.upperBound..<endRange.lowerBound])

    t.expect(execTarget.hasPrefix("/"), "the exec target is an absolute path, not one resolved against a cwd — got '\(execTarget)'")
    t.expect(
        FileManager.default.isExecutableFile(atPath: execTarget),
        "the script execs a path that actually exists and is executable — got '\(execTarget)'"
    )
}

// MARK: - Re-installing over a missing bridge script refuses rather than discards the chain (finding #3)

private func runMissingBridgeScriptTests(_ t: TestRunner) {
    guard let binary = agentMenuCLIBinary() else {
        print("   (skipped: .build/debug/AgentMenuCLI not built — run 'swift build' first)")
        return
    }

    let dir = TempDir("install-statusline-missing-script")
    defer { dir.cleanup() }
    let claudeDir = dir.path("claude")
    try? FileManager.default.createDirectory(atPath: claudeDir, withIntermediateDirectories: true)

    let originalScriptPath = dir.path("original-statusline.sh")
    try? "#!/bin/bash\necho ORIGINAL\n".write(toFile: originalScriptPath, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: originalScriptPath)

    let settingsPath = dir.path("claude/settings.json")
    let settingsText = """
    {
      "statusLine": {"type": "command", "command": "\\"\(originalScriptPath)\\"", "refreshInterval": 60}
    }
    """
    try? settingsText.write(toFile: settingsPath, atomically: true, encoding: .utf8)

    let configPath = dir.path("config.toml")
    let configText = """
    schema = 1
    active_profile = "work"

    [[profiles]]
    id = "work"
    name = "Work"
    config_dir = "\(claudeDir)"
    """
    try? configText.write(toFile: configPath, atomically: true, encoding: .utf8)
    let env = ["AGENTMENU_CONFIG": configPath]

    // First install: real chain recovered from the previous statusLine.
    guard let firstInstall = try? runCLI(binary, ["install-statusline"], env: env) else {
        t.expect(false, "first install-statusline should run")
        return
    }
    t.expectEqual(firstInstall.status, 0, "first install succeeds")

    let scriptPath = dir.path("claude/\(StatuslineBridge.scriptFilename)")
    t.expect(FileManager.default.fileExists(atPath: scriptPath), "the bridge script was written")
    let settingsAfterFirstInstall = (try? String(contentsOfFile: settingsPath, encoding: .utf8)) ?? ""

    // Simulate the script going missing (deleted, wiped, whatever) while
    // settings.json still points at it.
    try? FileManager.default.removeItem(atPath: scriptPath)

    guard let secondInstall = try? runCLI(binary, ["install-statusline"], env: env) else {
        t.expect(false, "second install-statusline should run")
        return
    }
    t.expect(
        secondInstall.status != 0,
        "install-statusline refuses (non-zero exit) rather than silently discarding the chain when the bridge script cannot be read"
    )
    t.expect(
        secondInstall.stdout.contains("could not be read") || secondInstall.stderr.contains("could not be read"),
        "the refusal names the situation — got stdout: \(secondInstall.stdout), stderr: \(secondInstall.stderr)"
    )
    t.expect(
        !FileManager.default.fileExists(atPath: scriptPath),
        "nothing was written in place of the missing script — no fresh bridge chaining to nothing"
    )
    t.expectEqual(
        (try? String(contentsOfFile: settingsPath, encoding: .utf8)) ?? "", settingsAfterFirstInstall,
        "settings.json is untouched by the refused install"
    )
}

// MARK: - A chain that backgrounds a process does not hang the bridge (finding #4)

private func runChainBackgroundingTests(_ t: TestRunner) {
    guard let binary = agentMenuCLIBinary() else {
        print("   (skipped: .build/debug/AgentMenuCLI not built — run 'swift build' first)")
        return
    }

    let dir = TempDir("bridge-chain-backgrounds")
    defer { dir.cleanup() }
    let profileDir = dir.path("profile")
    try? FileManager.default.createDirectory(atPath: profileDir, withIntermediateDirectories: true)
    let payload = ratePayload(fiveHour: (9, 1_840_000_000))

    guard let result = runCLIBounded(
        binary,
        ["statusline-bridge", "--profile-dir", profileDir, "--chain", "(sleep 30 &) ; echo quick-line"],
        stdin: payload,
        timeout: 10
    ) else {
        t.expect(false, "a chain that backgrounds a process must not hang the bridge (finding #4) — timed out")
        return
    }
    t.expectEqual(result.status, 0, "the bridge exits promptly once the chain itself has returned, without waiting on the grandchild")
    t.expect(result.stdout.contains("quick-line"), "the chain's own output is forwarded even though a detached grandchild still holds stdout open")
}

// MARK: - Large stdin plus a chain that ignores it does not SIGPIPE the bridge (finding #5)

private func runChainSigpipeTests(_ t: TestRunner) {
    guard let binary = agentMenuCLIBinary() else {
        print("   (skipped: .build/debug/AgentMenuCLI not built — run 'swift build' first)")
        return
    }

    let dir = TempDir("bridge-chain-sigpipe")
    defer { dir.cleanup() }
    let profileDir = dir.path("profile")
    try? FileManager.default.createDirectory(atPath: profileDir, withIntermediateDirectories: true)

    // A payload much larger than a pipe buffer (typically 64KB), paired with
    // a chain that never reads stdin — closing its read end almost
    // immediately, which is exactly the shape that raised SIGPIPE on the
    // background write before the fix.
    let bigStdin = Data(repeating: 0x41, count: 200_000)

    guard let result = runCLIBounded(
        binary,
        ["statusline-bridge", "--profile-dir", profileDir, "--chain", "echo hello-from-chain"],
        stdin: bigStdin,
        timeout: 10
    ) else {
        t.expect(false, "a large stdin write to a chain that ignores it must not hang the bridge — timed out")
        return
    }
    t.expectEqual(result.status, 0, "the bridge survives a SIGPIPE on the background stdin write and reports the chain's own exit status")
    t.expect(result.stdout.contains("hello-from-chain"), "the chain's output is still forwarded, not discarded by a killed process")

}
