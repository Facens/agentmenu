// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

// U7 — the rate-limit usage snapshot reader. The reader never computes
// usage; it only parses what a status-line script already wrote to
// `tb-rate-snapshot.json`, and refuses rather than guesses at an unknown
// shape (KTD7). See docs/research-notes.md "Usage readout" for the verified
// real file shape this is built against.

private let epoch = Date(timeIntervalSince1970: 1_788_945_600) // fixed "now" for determinism

private func writeSnapshot(_ dir: TempDir, name: String = "tb-rate-snapshot.json", _ json: String) throws {
    try dir.write(json, to: name)
}

func runUsageReaderTests(_ t: TestRunner) {
    t.suite("UsageReader")

    // MARK: - 1. Happy path: both windows present

    ({
        let dir = TempDir("usage-both-windows")
        defer { dir.cleanup() }
        let ts = epoch.addingTimeInterval(-30) // written 30s ago
        let json = """
        {"v":1,"ts":\(Int(ts.timeIntervalSince1970)),"suggest":null,
         "five_hour":{"used_percentage":13,"resets_at":\(Int(epoch.addingTimeInterval(3600).timeIntervalSince1970))},
         "seven_day":{"used_percentage":24,"resets_at":\(Int(epoch.addingTimeInterval(86400).timeIntervalSince1970))}}
        """
        try? writeSnapshot(dir, json)
        let reader = UsageReader()
        let reading = reader.read(at: dir.url.appendingPathComponent("tb-rate-snapshot.json"))
        guard case .available(let snapshot) = reading else {
            t.expect(false, "both-windows snapshot should be .available, got \(reading)")
            return
        }
        t.expectEqual(snapshot.windows.count, 2, "both windows present")
        t.expectEqual(snapshot.window(.fiveHour)?.usedPercentage, 13, "five_hour used_percentage")
        t.expectEqual(snapshot.window(.sevenDay)?.usedPercentage, 24, "seven_day used_percentage")
        t.expectEqual(snapshot.age(now: epoch), 30, "age derived from ts")
        t.expectEqual(snapshot.windows.map(\.kind), [.fiveHour, .sevenDay], "windows in UsageWindowKind order")
    })()

    // MARK: - 2. seven_day only (AE4)

    ({
        let dir = TempDir("usage-seven-day-only")
        defer { dir.cleanup() }
        let json = """
        {"v":1,"ts":\(Int(epoch.timeIntervalSince1970)),"suggest":null,
         "seven_day":{"used_percentage":24,"resets_at":\(Int(epoch.addingTimeInterval(86400).timeIntervalSince1970))}}
        """
        try? writeSnapshot(dir, json)
        let reader = UsageReader()
        let reading = reader.read(at: dir.url.appendingPathComponent("tb-rate-snapshot.json"))
        guard case .available(let snapshot) = reading else {
            t.expect(false, "seven_day-only snapshot should be .available, got \(reading)")
            return
        }
        t.expectEqual(snapshot.windows.count, 1, "AE4: exactly one window present")
        t.expect(snapshot.window(.fiveHour) == nil, "AE4: window(.fiveHour) is nil, not zero")
        t.expectEqual(snapshot.window(.sevenDay)?.usedPercentage, 24, "AE4: seven_day value preserved")
    })()

    // MARK: - 3. resets_at in the past -> rolledOver

    ({
        let dir = TempDir("usage-rolled-over")
        defer { dir.cleanup() }
        let json = """
        {"v":1,"ts":\(Int(epoch.timeIntervalSince1970)),
         "five_hour":{"used_percentage":90,"resets_at":\(Int(epoch.addingTimeInterval(-10).timeIntervalSince1970))}}
        """
        try? writeSnapshot(dir, json)
        let reader = UsageReader()
        guard case .available(let snapshot) = reader.read(at: dir.url.appendingPathComponent("tb-rate-snapshot.json")) else {
            t.expect(false, "rolled-over fixture should parse")
            return
        }
        let window = snapshot.window(.fiveHour)!
        let age = snapshot.age(now: epoch)
        t.expectEqual(window.state(now: epoch, age: age, staleAfter: 300), .rolledOver, "past resets_at -> rolledOver")
    })()

    // MARK: - 4. Written four hours ago -> stale, with that age (AE3)

    ({
        let dir = TempDir("usage-four-hours-stale")
        defer { dir.cleanup() }
        let writtenAt = epoch.addingTimeInterval(-4 * 3600)
        // resets_at kept comfortably in the future so rolledOver does not
        // shadow the stale classification this case is testing.
        let resetsAt = epoch.addingTimeInterval(10 * 3600)
        let json = """
        {"v":1,"ts":\(Int(writtenAt.timeIntervalSince1970)),
         "five_hour":{"used_percentage":80,"resets_at":\(Int(resetsAt.timeIntervalSince1970))},
         "seven_day":{"used_percentage":40,"resets_at":\(Int(resetsAt.timeIntervalSince1970))}}
        """
        try? writeSnapshot(dir, json)
        let reader = UsageReader()
        guard case .available(let snapshot) = reader.read(at: dir.url.appendingPathComponent("tb-rate-snapshot.json")) else {
            t.expect(false, "AE3 fixture should parse")
            return
        }
        let age = snapshot.age(now: epoch)
        t.expectEqual(age, 4 * 3600, "AE3: age is exactly 4 hours")
        for window in snapshot.windows {
            t.expectEqual(
                window.state(now: epoch, age: age, staleAfter: reader.staleAfter),
                .stale,
                "AE3: \(window.kind.rawValue) is stale, not current"
            )
        }
    })()

    // MARK: - 5. Missing file -> unavailable

    ({
        let dir = TempDir("usage-missing-file")
        defer { dir.cleanup() }
        let reader = UsageReader()
        let reading = reader.read(at: dir.url.appendingPathComponent("does-not-exist.json"))
        t.expectEqual(reading, .unavailable, "missing file is .unavailable")
    })()

    // MARK: - 6. Unknown v -> refused, reason names it

    ({
        let dir = TempDir("usage-unknown-version")
        defer { dir.cleanup() }
        let json = """
        {"v":2,"ts":\(Int(epoch.timeIntervalSince1970)),"five_hour":{"used_percentage":1,"resets_at":\(Int(epoch.addingTimeInterval(100).timeIntervalSince1970))}}
        """
        try? writeSnapshot(dir, json)
        let reader = UsageReader()
        let reading = reader.read(at: dir.url.appendingPathComponent("tb-rate-snapshot.json"))
        guard case .refused(let reason) = reading else {
            t.expect(false, "v:2 should be .refused, got \(reading)")
            return
        }
        t.expect(reason.contains("2"), "KTD7: refusal reason names the version found — got: \(reason)")
        t.expect(reason.contains("1"), "refusal reason names a supported version — got: \(reason)")
    })()

    // MARK: - 6b. v missing / v as a string -> refused (distinct failure modes)

    ({
        let dir = TempDir("usage-v-missing")
        defer { dir.cleanup() }
        try? writeSnapshot(dir, "{\"ts\":\(Int(epoch.timeIntervalSince1970))}")
        let reading = UsageReader().read(at: dir.url.appendingPathComponent("tb-rate-snapshot.json"))
        if case .refused = reading {
            t.expect(true, "missing v is refused")
        } else {
            t.expect(false, "missing v should be .refused, got \(reading)")
        }
    })()

    ({
        let dir = TempDir("usage-v-string")
        defer { dir.cleanup() }
        try? writeSnapshot(dir, "{\"v\":\"1\",\"ts\":\(Int(epoch.timeIntervalSince1970))}")
        let reading = UsageReader().read(at: dir.url.appendingPathComponent("tb-rate-snapshot.json"))
        if case .refused = reading {
            t.expect(true, "v as a string is refused")
        } else {
            t.expect(false, "v as a string should be .refused, got \(reading)")
        }
    })()

    // MARK: - 7. Malformed JSON, array root, truncated, empty file

    ({
        let dir = TempDir("usage-malformed")
        defer { dir.cleanup() }
        try? writeSnapshot(dir, "not json at all {{{")
        let reading = UsageReader().read(at: dir.url.appendingPathComponent("tb-rate-snapshot.json"))
        if case .refused = reading {
            t.expect(true, "malformed JSON is refused, not a crash")
        } else {
            t.expect(false, "malformed JSON should be .refused, got \(reading)")
        }
    })()

    ({
        let dir = TempDir("usage-array-root")
        defer { dir.cleanup() }
        try? writeSnapshot(dir, "[1,2,3]")
        let reading = UsageReader().read(at: dir.url.appendingPathComponent("tb-rate-snapshot.json"))
        if case .refused = reading {
            t.expect(true, "array root is refused")
        } else {
            t.expect(false, "array root should be .refused, got \(reading)")
        }
    })()

    ({
        let dir = TempDir("usage-truncated")
        defer { dir.cleanup() }
        try? writeSnapshot(dir, "{\"v\":1,\"ts\":178894560")
        let reading = UsageReader().read(at: dir.url.appendingPathComponent("tb-rate-snapshot.json"))
        if case .refused = reading {
            t.expect(true, "truncated JSON is refused, not a crash")
        } else {
            t.expect(false, "truncated JSON should be .refused, got \(reading)")
        }
    })()

    ({
        let dir = TempDir("usage-empty-file")
        defer { dir.cleanup() }
        try? writeSnapshot(dir, "")
        let reading = UsageReader().read(at: dir.url.appendingPathComponent("tb-rate-snapshot.json"))
        if case .refused = reading {
            t.expect(true, "empty file is refused, not a crash")
        } else {
            t.expect(false, "empty file should be .refused, got \(reading)")
        }
    })()

    // MARK: - 8. Fractional used_percentage parses; non-numeric refused naming the window

    ({
        let dir = TempDir("usage-fractional")
        defer { dir.cleanup() }
        let json = """
        {"v":1,"ts":\(Int(epoch.timeIntervalSince1970)),
         "seven_day":{"used_percentage":55.00000000000001,"resets_at":\(Int(epoch.addingTimeInterval(100).timeIntervalSince1970))}}
        """
        try? writeSnapshot(dir, json)
        let reading = UsageReader().read(at: dir.url.appendingPathComponent("tb-rate-snapshot.json"))
        guard case .available(let snapshot) = reading else {
            t.expect(false, "fractional used_percentage should parse, got \(reading)")
            return
        }
        t.expectEqual(snapshot.window(.sevenDay)?.usedPercentage, 55.00000000000001, "fractional percentage preserved exactly")
    })()

    ({
        let dir = TempDir("usage-non-numeric-percentage")
        defer { dir.cleanup() }
        let json = """
        {"v":1,"ts":\(Int(epoch.timeIntervalSince1970)),
         "five_hour":{"used_percentage":"a lot","resets_at":\(Int(epoch.addingTimeInterval(100).timeIntervalSince1970))}}
        """
        try? writeSnapshot(dir, json)
        let reading = UsageReader().read(at: dir.url.appendingPathComponent("tb-rate-snapshot.json"))
        guard case .refused(let reason) = reading else {
            t.expect(false, "non-numeric used_percentage should be .refused, got \(reading)")
            return
        }
        t.expect(reason.contains("five_hour"), "refusal names the offending window — got: \(reason)")
    })()

    // Darwin's JSONSerialization decodes `true`/`false` as NSNumber, and a
    // naive `as? Double` on that NSNumber silently succeeds as 1.0/0.0. Guard
    // against that trap specifically.
    ({
        let dir = TempDir("usage-boolean-percentage")
        defer { dir.cleanup() }
        let json = """
        {"v":1,"ts":\(Int(epoch.timeIntervalSince1970)),
         "five_hour":{"used_percentage":true,"resets_at":\(Int(epoch.addingTimeInterval(100).timeIntervalSince1970))}}
        """
        try? writeSnapshot(dir, json)
        let reading = UsageReader().read(at: dir.url.appendingPathComponent("tb-rate-snapshot.json"))
        if case .refused = reading {
            t.expect(true, "boolean used_percentage is refused, not silently coerced to 1.0")
        } else {
            t.expect(false, "boolean used_percentage should be .refused, got \(reading)")
        }
    })()

    // MARK: - 9. resolvePath substitution

    ({
        let plain = UsageReader.resolvePath(
            template: "{profile_dir}/tb-rate-snapshot.json",
            profileDirectory: URL(fileURLWithPath: "/Users/facens/.claude")
        )
        t.expectEqual(plain.path, "/Users/facens/.claude/tb-rate-snapshot.json", "resolvePath substitutes a plain path")

        let spaced = UsageReader.resolvePath(
            template: "{profile_dir}/tb-rate-snapshot.json",
            profileDirectory: URL(fileURLWithPath: "/Users/facens/My Profile")
        )
        t.expectEqual(spaced.path, "/Users/facens/My Profile/tb-rate-snapshot.json", "resolvePath substitutes a path containing a space")

        let untouched = UsageReader.resolvePath(
            template: "/etc/agentmenu/snapshot.json",
            profileDirectory: URL(fileURLWithPath: "/Users/facens/.claude")
        )
        t.expectEqual(untouched.path, "/etc/agentmenu/snapshot.json", "a template with no placeholder is left alone")
    })()

    // MARK: - read(template:profileDirectory:) end to end

    ({
        let dir = TempDir("usage-read-template")
        defer { dir.cleanup() }
        let json = """
        {"v":1,"ts":\(Int(epoch.timeIntervalSince1970)),
         "five_hour":{"used_percentage":5,"resets_at":\(Int(epoch.addingTimeInterval(100).timeIntervalSince1970))}}
        """
        try? writeSnapshot(dir, json)
        let reading = UsageReader().read(template: "{profile_dir}/tb-rate-snapshot.json", profileDirectory: dir.url)
        guard case .available(let snapshot) = reading else {
            t.expect(false, "read(template:profileDirectory:) should resolve and read the file, got \(reading)")
            return
        }
        t.expectEqual(snapshot.window(.fiveHour)?.usedPercentage, 5, "read(template:profileDirectory:) parses through the resolved path")
    })()

    // MARK: - 10. describeAge boundaries

    ({
        t.expectEqual(UsageSnapshot.describeAge(0), "just now", "describeAge: 0s")
        t.expectEqual(UsageSnapshot.describeAge(59), "just now", "describeAge: 59s")
        t.expectEqual(UsageSnapshot.describeAge(-100), "just now", "describeAge: negative age (clock skew) reads as just now")
        t.expectEqual(UsageSnapshot.describeAge(60), "1m ago", "describeAge: 60s boundary")
        t.expectEqual(UsageSnapshot.describeAge(4 * 60), "4m ago", "describeAge: 4m")
        t.expectEqual(UsageSnapshot.describeAge(3600), "1h ago", "describeAge: 3600s boundary")
        t.expectEqual(UsageSnapshot.describeAge(3 * 3600), "3h ago", "describeAge: 3h")
        t.expectEqual(UsageSnapshot.describeAge(86400), "1d ago", "describeAge: 86400s boundary")
        t.expectEqual(UsageSnapshot.describeAge(2 * 86400), "2d ago", "describeAge: 2d")
    })()

    // MARK: - Malformed window shapes: not an object, missing resets_at

    ({
        let dir = TempDir("usage-window-not-object")
        defer { dir.cleanup() }
        try? writeSnapshot(dir, "{\"v\":1,\"ts\":\(Int(epoch.timeIntervalSince1970)),\"five_hour\":5}")
        let reading = UsageReader().read(at: dir.url.appendingPathComponent("tb-rate-snapshot.json"))
        guard case .refused(let reason) = reading else {
            t.expect(false, "a window that isn't an object should be .refused, got \(reading)")
            return
        }
        t.expect(reason.contains("five_hour"), "refusal names the malformed window — got: \(reason)")
    })()

    ({
        let dir = TempDir("usage-window-missing-resets-at")
        defer { dir.cleanup() }
        try? writeSnapshot(dir, "{\"v\":1,\"ts\":\(Int(epoch.timeIntervalSince1970)),\"seven_day\":{\"used_percentage\":10}}")
        let reading = UsageReader().read(at: dir.url.appendingPathComponent("tb-rate-snapshot.json"))
        guard case .refused(let reason) = reading else {
            t.expect(false, "a window missing resets_at should be .refused, got \(reading)")
            return
        }
        t.expect(reason.contains("seven_day"), "refusal names the window missing resets_at — got: \(reason)")
    })()

    // MARK: - ts missing / non-numeric -> refused naming ts

    ({
        let dir = TempDir("usage-ts-missing")
        defer { dir.cleanup() }
        try? writeSnapshot(dir, "{\"v\":1}")
        let reading = UsageReader().read(at: dir.url.appendingPathComponent("tb-rate-snapshot.json"))
        guard case .refused(let reason) = reading else {
            t.expect(false, "missing ts should be .refused, got \(reading)")
            return
        }
        t.expect(reason.contains("ts"), "refusal names ts — got: \(reason)")
    })()

    ({
        let dir = TempDir("usage-ts-string")
        defer { dir.cleanup() }
        try? writeSnapshot(dir, "{\"v\":1,\"ts\":\"not a number\"}")
        let reading = UsageReader().read(at: dir.url.appendingPathComponent("tb-rate-snapshot.json"))
        if case .refused = reading {
            t.expect(true, "non-numeric ts is refused")
        } else {
            t.expect(false, "non-numeric ts should be .refused, got \(reading)")
        }
    })()

    // MARK: - suggest, and unknown extra/window keys are ignored, not refused

    ({
        let dir = TempDir("usage-suggest-and-unknown-keys")
        defer { dir.cleanup() }
        let json = """
        {"v":1,"ts":\(Int(epoch.timeIntervalSince1970)),"suggest":"take a break","some_future_field":42,
         "thirty_day":{"used_percentage":1,"resets_at":1},
         "five_hour":{"used_percentage":5,"resets_at":\(Int(epoch.addingTimeInterval(100).timeIntervalSince1970))}}
        """
        try? writeSnapshot(dir, json)
        let reading = UsageReader().read(at: dir.url.appendingPathComponent("tb-rate-snapshot.json"))
        guard case .available(let snapshot) = reading else {
            t.expect(false, "unknown extra keys and a non-null suggest should not cause a refusal, got \(reading)")
            return
        }
        t.expectEqual(snapshot.windows.count, 1, "unknown window key (thirty_day) is ignored, not surfaced")
        t.expectEqual(snapshot.window(.fiveHour)?.usedPercentage, 5, "known window still parses alongside unknown keys")
    })()

    // MARK: - A directory at the snapshot path does not crash the reader

    ({
        let dir = TempDir("usage-directory-at-path")
        defer { dir.cleanup() }
        let subdir = dir.url.appendingPathComponent("tb-rate-snapshot.json")
        try? FileManager.default.createDirectory(at: subdir, withIntermediateDirectories: true)
        let reading = UsageReader().read(at: subdir)
        // Deliberate choice: a directory at the snapshot path is treated the
        // same as "no snapshot file here" (R25) rather than as a refusal —
        // there is nothing wrong to explain, there simply is no file.
        t.expectEqual(reading, .unavailable, "a directory at the snapshot path reads as .unavailable, not a crash")
    })()

    // MARK: - 11. Real on-machine snapshots, best-effort
    //
    // A smoke check against whatever real snapshot files this machine
    // happens to have. Every assertion here must be able to fail (finding
    // #7): no `t.expect(true, …)` standing in for "didn't crash" on every
    // branch alike — the one claim that's actually true of a file that
    // exists is that reading it is never `.unavailable`, and on
    // `.available` its version is one this reader claims to support.

    for (label, path) in [
        ("work", NSHomeDirectory() + "/.claude/tb-rate-snapshot.json"),
        ("personal", NSHomeDirectory() + "/.claude-personal/tb-rate-snapshot.json"),
    ] {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("   (skip) \(label) snapshot not present at \(path)")
            continue
        }
        let reading = UsageReader().read(at: url)
        switch reading {
        case .available(let snapshot):
            t.expect(
                UsageReader.supportedVersions.contains(snapshot.version),
                "\(label) real snapshot's version (\(snapshot.version)) is one this reader claims to support"
            )
            let now = Date()
            let age = snapshot.age(now: now)
            let windowSummary = snapshot.windows.map { window -> String in
                let state = window.state(now: now, age: age, staleAfter: UsageReader.defaultStaleAfter)
                return "\(window.kind.rawValue)=\(window.usedPercentage)% (\(state))"
            }.joined(separator: ", ")
            print("   (info) \(label) snapshot: .available, age \(UsageSnapshot.describeAge(age)), windows: \(windowSummary)")
        case .refused(let reason):
            print("   (info) \(label) snapshot: .refused — \(reason)")
        case .unavailable:
            t.expect(false, "\(label) snapshot file exists at \(path) but read as .unavailable — should be .available or .refused")
        }
    }
}

func runUsageAlertTests(_ t: TestRunner) {
    t.suite("UsageAlert")

    let now = Date(timeIntervalSince1970: 1_000_000)
    let staleAfter: TimeInterval = 15 * 60

    func snapshot(_ windows: [UsageWindow], writtenAt: Date = Date(timeIntervalSince1970: 1_000_000)) -> UsageSnapshot {
        UsageSnapshot(version: 1, writtenAt: writtenAt, windows: windows)
    }
    func window(_ kind: UsageWindowKind, _ used: Double, resetsIn: TimeInterval = 3600) -> UsageWindow {
        UsageWindow(kind: kind, usedPercentage: used, resetsAt: now.addingTimeInterval(resetsIn))
    }

    // Below the first threshold there is nothing to report. A menu bar that
    // always has something to say is a menu bar nobody reads.
    do {
        let alert = UsageAlert.worst(in: snapshot([window(.fiveHour, 79.4), window(.sevenDay, 12)]), now: now, staleAfter: staleAfter)
        t.expect(alert == nil, "79% reports nothing")
    }

    // The thresholds themselves.
    do {
        t.expectEqual(UsageAlertLevel(usedPercentage: 79.9), .normal, "just under 80 is normal")
        t.expectEqual(UsageAlertLevel(usedPercentage: 80), .caution, "80 is caution")
        t.expectEqual(UsageAlertLevel(usedPercentage: 89.9), .caution, "just under 90 is still caution")
        t.expectEqual(UsageAlertLevel(usedPercentage: 90), .warning, "90 is warning")
        t.expectEqual(UsageAlertLevel(usedPercentage: 99.9), .warning, "just under 100 is still warning")
        t.expectEqual(UsageAlertLevel(usedPercentage: 100), .exhausted, "100 is exhausted")
        t.expectEqual(UsageAlertLevel(usedPercentage: 140), .exhausted, "past 100 stays exhausted")
    }

    // The worst window wins, whichever it is — the account is limited by the
    // one closest to its cap, not by the one that happens to be listed first.
    do {
        let alert = UsageAlert.worst(in: snapshot([window(.fiveHour, 30), window(.sevenDay, 94)]), now: now, staleAfter: staleAfter)
        t.expectEqual(alert?.kind, .sevenDay, "the weekly window is the one at 94%")
        t.expectEqual(alert?.level, .warning, "and it sets the level")
        t.expectEqual(alert?.badge, "94%", "the badge is the number")
    }

    // An exhausted window says so in words rather than as 100%.
    do {
        let alert = UsageAlert.worst(in: snapshot([window(.fiveHour, 100)]), now: now, staleAfter: staleAfter)
        t.expectEqual(alert?.level, .exhausted, "100% is exhausted")
        t.expectEqual(alert?.badge, "out", "the badge says out, not 100%")
    }

    // A window past its own reset is excluded. The counter has reset
    // server-side, so a stored 100% describes an instance that no longer
    // exists — a red badge for it would outlive the limit it reports (R24).
    do {
        let rolled = UsageWindow(kind: .fiveHour, usedPercentage: 100, resetsAt: now.addingTimeInterval(-60))
        let alert = UsageAlert.worst(in: snapshot([rolled, window(.sevenDay, 20)]), now: now, staleAfter: staleAfter)
        t.expect(alert == nil, "a rolled-over window raises no alarm")
    }

    // Staleness does not exclude: an old reading of 97% is still the last
    // thing known, and dropping it would replace it with silence. The age
    // travels with the alert so the caller can qualify it.
    do {
        let old = Date(timeIntervalSince1970: 1_000_000 - 3600)
        let alert = UsageAlert.worst(in: snapshot([window(.fiveHour, 97)], writtenAt: old), now: now, staleAfter: staleAfter)
        t.expectEqual(alert?.level, .warning, "a stale reading still reports")
        t.expectEqual(alert?.age, 3600, "and carries how old it is")
    }
}
