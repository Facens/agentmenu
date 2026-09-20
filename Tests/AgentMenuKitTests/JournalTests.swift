// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

// U6 — the read-only state hook's journal (KTD3, R13, R16).
//
// Most of these cases are refusals rather than features. The key that turns
// the hook on can be set by any process running as the user, so "the writer
// declines and leaves no trace" is the behaviour under test: a journal that
// only ever appended what it was asked to would be a write primitive with a
// schema version. Each refusal here asserts the negative as well — that the
// file the key was aimed at is still exactly as it was.
//
// The app-side taps (Sources/AgentMenu/HarnessJournal.swift) are not covered:
// the suite links AgentMenuKit only. That is why every rule worth proving —
// the name check, the cleanup rule, the cap, the "names never values" payload
// — lives in the Kit rather than in the tap.

private let build = "1.2.3"

/// A defaults domain this test controls, holding `values`.
///
/// The volatile argument domain, not a named suite: a suite is a real file in
/// the user's own `~/Library/Preferences`, and neither
/// `removePersistentDomain(forName:)` nor `removeSuite(named:)` deletes it
/// (verified on macOS 26) — a case that ran on every `make test` would leave a
/// plist behind each time. The argument domain is in memory, is the first
/// domain `object(forKey:)` searches, and is where a value handed to a launch
/// would land anyway (KTD4), so the writer is exercised through exactly the
/// call it makes in the app.
private func harnessDefaults(_ values: [String: Any]) -> UserDefaults {
    let defaults = UserDefaults.standard
    defaults.setVolatileDomain(values, forName: UserDefaults.argumentDomain)
    return defaults
}

private func resetHarnessDefaults() {
    UserDefaults.standard.setVolatileDomain([:], forName: UserDefaults.argumentDomain)
}

private func journalLines(at url: URL) -> [[String: Any]] {
    guard let data = try? Data(contentsOf: url) else { return [] }
    return data.split(separator: 0x0A).compactMap {
        try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any]
    }
}

private func mode(of url: URL) -> Int? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? Int
}

func runJournalTests(_ t: TestRunner) {
    t.suite("Journal")

    // MARK: - 1. Happy path: three appended events, three lines

    ({
        let dir = TempDir("journal-happy")
        defer { dir.cleanup() }
        let harness = dir.url.appendingPathComponent("harness")
        let file = harness.appendingPathComponent("journal.ndjson")

        guard let journal = t.attempt("opening a journal in a fresh directory", {
            try Journal.open(directory: harness, name: "journal.ndjson", build: build, nonce: "abc123")
        }) else { return }

        journal.start(fixture: ["config": .string("/tmp/config.toml")])
        journal.append(.detectingStarted)
        journal.append(.detectingFinished, ["agents": .list([.string("claude-code")])])
        journal.append(.setupShown, ["needed": .boolean(true)])

        let lines = journalLines(at: file)
        t.expectEqual(lines.count, 4, "one line per event, the fixture echo first")
        t.expectEqual(lines.first?["event"] as? String, "harness started", "the first line is the fixture echo")

        let appended = Array(lines.dropFirst())
        t.expectEqual(appended.count, 3, "three appended events produce three lines")
        t.expectEqual(appended.compactMap { $0["seq"] as? Int }, [2, 3, 4], "seq increases by one per line")
        t.expectEqual(Set(appended.compactMap { $0["schema"] as? Int }), [Journal.schemaVersion], "one schema for the run")
        t.expect(appended.allSatisfy { $0["build"] as? String == build }, "every line carries the build")
        t.expect(appended.allSatisfy { $0["nonce"] as? String == "abc123" }, "every line carries the run nonce")
        t.expect(appended.allSatisfy { $0["t"] is String }, "every line is timestamped")
        t.expectEqual(
            (lines.first?["data"] as? [String: Any])?["boot"] as? Int, 1,
            "the first run of a journal is boot 1"
        )

        // The file is created inside the harness directory, at 0600, and the
        // directory itself is not readable by other users' processes.
        t.expectEqual(mode(of: file), 0o600, "the journal is created at mode 0600")
        t.expectEqual(mode(of: harness), 0o700, "the harness directory is created at mode 0700")

        let raw = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        t.expect(raw.hasSuffix("\n"), "every line, including the last, is terminated")
        t.expectEqual(raw.split(separator: "\n").count, 4, "one line per event and no stray newlines")
    })()

    // MARK: - 2. No key set: nothing is created at all (AE6)

    ({
        let dir = TempDir("journal-inert")
        defer { dir.cleanup() }
        let defaults = harnessDefaults([:])
        defer { resetHarnessDefaults() }
        let harness = dir.url.appendingPathComponent("harness")

        let activation = Journal.activate(defaults: defaults, directory: harness, build: build)
        guard case .inert = activation else {
            t.expect(false, "AE6: no key means inert, got \(activation)")
            return
        }
        t.expect(
            !FileManager.default.fileExists(atPath: harness.path),
            "AE6: a launch with no key does not even create the harness directory"
        )
    })()

    // MARK: - 3. A key that names a path is refused (AE11)

    ({
        let dir = TempDir("journal-refused")
        defer { dir.cleanup() }
        let harness = dir.url.appendingPathComponent("harness")
        let escape = dir.url.appendingPathComponent("escaped.ndjson")

        // The three shapes AE11 names, plus the two edges of the same rule.
        let refused = ["/tmp/x", "../x", "a/b", escape.path, "..", ".", "", "a/../b", "x\ny"]
        for name in refused {
            let defaults = harnessDefaults([Journal.journalKey: name])
            defer { resetHarnessDefaults() }
            let activation = Journal.activate(defaults: defaults, directory: harness, build: build)
            guard case .refused(let reason) = activation else {
                t.expect(false, "AE11: \(name.debugDescription) must be refused, got \(activation)")
                continue
            }
            t.expect(!reason.isEmpty, "AE11: the refusal of \(name.debugDescription) says why")
            t.expect(
                !reason.contains("\n"),
                "AE11: the refusal of \(name.debugDescription) is one line the app can log"
            )
        }

        t.expect(
            !FileManager.default.fileExists(atPath: escape.path),
            "AE11: no file is written outside the harness directory"
        )
        t.expect(
            !FileManager.default.fileExists(atPath: harness.path),
            "AE11: a refusal creates nothing at all, not even the harness directory"
        )
        t.expectEqual(
            (try? FileManager.default.contentsOfDirectory(atPath: dir.url.path))?.count, 0,
            "AE11: the refusal is the only trace"
        )
    })()

    // MARK: - 4. A value that is not a string is refused

    ({
        let dir = TempDir("journal-not-a-string")
        defer { dir.cleanup() }
        // `defaults write … -int 7`: a value that is not a file name at all.
        let defaults = harnessDefaults([Journal.journalKey: 7])
        defer { resetHarnessDefaults() }

        let activation = Journal.activate(
            defaults: defaults,
            directory: dir.url.appendingPathComponent("harness"),
            build: build
        )
        guard case .refused = activation else {
            t.expect(false, "a number written with `defaults write -int` is not a file name, got \(activation)")
            return
        }
    })()

    // MARK: - 5. A relaunch continues the journal (seq and boot)

    ({
        let dir = TempDir("journal-relaunch")
        defer { dir.cleanup() }
        let defaults = harnessDefaults([Journal.journalKey: "journal.ndjson"])
        defer { resetHarnessDefaults() }
        let harness = dir.url.appendingPathComponent("harness")
        let file = harness.appendingPathComponent("journal.ndjson")

        for run in 1...2 {
            let activation = Journal.activate(defaults: defaults, directory: harness, build: build)
            guard case .writing(let journal) = activation else {
                t.expect(false, "run \(run) should write, got \(activation)")
                return
            }
            t.expectEqual(journal.bootCount, run, "the boot counter counts launches")
            journal.start(fixture: ["run": .integer(run)])
            journal.append(.setupShown)
        }

        let lines = journalLines(at: file)
        t.expectEqual(lines.count, 4, "the second launch appends rather than replacing")
        t.expectEqual(lines.compactMap { $0["seq"] as? Int }, [1, 2, 3, 4], "seq continues across a relaunch")
        let started = lines.filter { $0["event"] as? String == "harness started" }
        t.expectEqual(started.count, 2, "each launch writes a fresh harness started")
        t.expectEqual(
            started.compactMap { ($0["data"] as? [String: Any])?["boot"] as? Int }, [1, 2],
            "the second harness started carries an incremented boot counter"
        )
    })()

    // MARK: - 6. A symlink at the journal path is refused, not followed

    ({
        let dir = TempDir("journal-symlink")
        defer { dir.cleanup() }
        let harness = dir.url.appendingPathComponent("harness")
        try? FileManager.default.createDirectory(at: harness, withIntermediateDirectories: true)
        let victim = dir.url.appendingPathComponent("victim.txt")
        FileManager.default.createFile(atPath: victim.path, contents: Data())
        let link = harness.appendingPathComponent("journal.ndjson")
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: victim)

        let defaults = harnessDefaults([Journal.journalKey: "journal.ndjson"])
        defer { resetHarnessDefaults() }

        let activation = Journal.activate(defaults: defaults, directory: harness, build: build)
        guard case .refused(let reason) = activation else {
            t.expect(false, "a symlink at the journal path must be refused, got \(activation)")
            return
        }
        t.expect(reason.contains("symlink"), "the refusal names the symlink — \(reason)")
        t.expectEqual(
            (try? Data(contentsOf: victim))?.count, 0,
            "the file the link pointed at was not written through"
        )
        t.expect(
            (try? FileManager.default.destinationOfSymbolicLink(atPath: link.path)) != nil,
            "the link itself is left where it was, to be refused again"
        )
    })()

    // MARK: - 7. Anything that is not a plain file this user owns is refused

    ({
        let dir = TempDir("journal-not-regular")
        defer { dir.cleanup() }
        let harness = dir.url.appendingPathComponent("harness")
        try? FileManager.default.createDirectory(
            at: harness.appendingPathComponent("journal.ndjson"),
            withIntermediateDirectories: true
        )

        t.expectThrows("a directory at the journal path is refused") {
            try Journal.open(directory: harness, name: "journal.ndjson", build: build)
        }

        // A second name for the same bytes is the one way a regular file this
        // user owns can still be a write primitive.
        let linked = TempDir("journal-hard-link")
        defer { linked.cleanup() }
        let second = linked.url.appendingPathComponent("harness")
        let file = second.appendingPathComponent("journal.ndjson")
        if let journal = t.attempt("opening a journal to hard-link", {
            try Journal.open(directory: second, name: "journal.ndjson", build: build)
        }) {
            journal.start(fixture: [:])
        }
        try? FileManager.default.linkItem(at: file, to: linked.url.appendingPathComponent("elsewhere.ndjson"))
        t.expectThrows("a journal with a second hard link is refused") {
            try Journal.open(directory: second, name: "journal.ndjson", build: build)
        }
    })()

    // MARK: - 8. An existing journal is reopened at 0600, never truncated

    ({
        let dir = TempDir("journal-mode")
        defer { dir.cleanup() }
        let harness = dir.url.appendingPathComponent("harness")
        let file = harness.appendingPathComponent("journal.ndjson")

        if let journal = t.attempt("opening the first time", {
            try Journal.open(directory: harness, name: "journal.ndjson", build: build)
        }) {
            journal.start(fixture: [:])
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o666], ofItemAtPath: file.path)

        if let journal = t.attempt("reopening a journal left group- and world-writable", {
            try Journal.open(directory: harness, name: "journal.ndjson", build: build)
        }) {
            journal.append(.setupShown)
        }
        t.expectEqual(mode(of: file), 0o600, "reopening restores the mode the contract promises")
        t.expectEqual(journalLines(at: file).count, 2, "reopening appends; it never truncates")
    })()

    // MARK: - 9. The cap drops the oldest lines, never the newest

    ({
        let dir = TempDir("journal-cap")
        defer { dir.cleanup() }
        let harness = dir.url.appendingPathComponent("harness")
        let file = harness.appendingPathComponent("journal.ndjson")
        let cap = 4096

        guard let journal = t.attempt("opening a capped journal", {
            try Journal.open(directory: harness, name: "journal.ndjson", build: build, maximumBytes: cap)
        }) else { return }

        journal.start(fixture: [:])
        for index in 1...200 {
            journal.append(.launchResult, ["index": .integer(index), "pad": .string(String(repeating: "x", count: 64))])
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? Int ?? 0
        t.expect(size <= cap, "the journal stops growing at the cap — \(size) bytes, cap \(cap)")

        let lines = journalLines(at: file)
        t.expect(lines.count > 1, "the cap keeps more than one line")
        let sequences = lines.compactMap { $0["seq"] as? Int }
        t.expectEqual(sequences.count, lines.count, "every retained line is whole and parses")
        t.expect(sequences.first ?? 0 > 1, "the oldest lines are the ones dropped")
        t.expectEqual(sequences.last, 201, "the newest line is always kept")
        t.expectEqual(sequences, Array(sequences.sorted()), "seq never rewinds when the file is trimmed")
        t.expectEqual(
            (lines.last?["data"] as? [String: Any])?["index"] as? Int, 200,
            "the last event written is the last event on disk"
        )
        let raw = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        t.expect(raw.hasSuffix("\n"), "a trimmed journal still ends on a line boundary")
        t.expect(!raw.hasPrefix("\n"), "a trimmed journal starts at a line boundary")
    })()

    // MARK: - 10. A launch with no key deletes the journal, and nothing else

    ({
        let dir = TempDir("journal-cleanup")
        defer { dir.cleanup() }
        let harness = dir.url.appendingPathComponent("harness")
        let file = harness.appendingPathComponent("journal.ndjson")

        if let journal = t.attempt("opening a journal to leave behind", {
            try Journal.open(directory: harness, name: "journal.ndjson", build: build)
        }) {
            journal.start(fixture: [:])
        }
        // The harness run directory holds its own evidence beside the journal
        // it collects; a cleanup that deleted everything here would destroy
        // the report of the very run that asked for the journal.
        let report = harness.appendingPathComponent("report.json")
        try? Data(#"{"verdict":"pass"}"#.utf8).write(to: report)
        let victim = dir.url.appendingPathComponent("victim.ndjson")
        try? Data("keep me\n".utf8).write(to: victim)
        try? FileManager.default.createSymbolicLink(
            at: harness.appendingPathComponent("elsewhere.ndjson"),
            withDestinationURL: victim
        )

        let defaults = harnessDefaults([:])
        defer { resetHarnessDefaults() }
        let activation = Journal.activate(defaults: defaults, directory: harness, build: build)
        guard case .inert = activation else {
            t.expect(false, "no key means inert, got \(activation)")
            return
        }

        t.expect(!FileManager.default.fileExists(atPath: file.path), "the journal left by a previous run is deleted")
        t.expect(FileManager.default.fileExists(atPath: report.path), "a file that is not a journal is left alone")
        t.expectEqual(
            (try? String(contentsOf: victim, encoding: .utf8)), "keep me\n",
            "a symlink in the directory is not followed and its target is untouched"
        )
    })()

    // MARK: - 11. A refusal deletes nothing (the refusal is the only trace)

    ({
        let dir = TempDir("journal-refusal-keeps")
        defer { dir.cleanup() }
        let harness = dir.url.appendingPathComponent("harness")
        let file = harness.appendingPathComponent("journal.ndjson")
        if let journal = t.attempt("opening a journal a later refusal must not touch", {
            try Journal.open(directory: harness, name: "journal.ndjson", build: build)
        }) {
            journal.start(fixture: [:])
        }

        let defaults = harnessDefaults([Journal.journalKey: "../x"])
        defer { resetHarnessDefaults() }
        _ = Journal.activate(defaults: defaults, directory: harness, build: build)

        t.expectEqual(journalLines(at: file).count, 1, "a refused key leaves an earlier journal exactly as it was")
    })()

    // MARK: - 12. An unwritable directory is reported, not crashed through

    ({
        let dir = TempDir("journal-unwritable")
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: dir.url.appendingPathComponent("harness").path
            )
            dir.cleanup()
        }
        let harness = dir.url.appendingPathComponent("harness")
        try? FileManager.default.createDirectory(at: harness, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: harness.path)

        let defaults = harnessDefaults([Journal.journalKey: "journal.ndjson"])
        defer { resetHarnessDefaults() }

        let activation = Journal.activate(defaults: defaults, directory: harness, build: build)
        guard case .refused(let reason) = activation else {
            t.expect(false, "a journal that cannot be created is refused, not fatal — got \(activation)")
            return
        }
        t.expect(!reason.isEmpty, "the refusal says why the file could not be created")
        t.expect(
            !FileManager.default.fileExists(atPath: harness.appendingPathComponent("journal.ndjson").path),
            "nothing is left behind when the file could not be created"
        )
    })()

    // MARK: - 13. `launch requested` carries variable names, never values

    ({
        let command = LaunchCommand(
            executable: "/opt/homebrew/bin/claude",
            arguments: ["--model", "opus"],
            environment: ["CLAUDE_CONFIG_DIR": "/Users/someone/.claude-work", "ANTHROPIC_API_KEY": "sk-secret"],
            workingDirectory: "/Users/someone/dev/project"
        )
        let data = JournalData.launchRequested(command: command)
        t.expectEqual(data["binary"], JournalValue.string("/opt/homebrew/bin/claude"), "the binary is the resolved absolute path")
        t.expectEqual(data["directory"], JournalValue.string("/Users/someone/dev/project"), "the working directory is recorded")
        t.expectEqual(
            data["env"],
            JournalValue.list([.string("ANTHROPIC_API_KEY"), .string("CLAUDE_CONFIG_DIR")]),
            "the names of the variables the command sets, sorted"
        )

        let dir = TempDir("journal-env-names")
        defer { dir.cleanup() }
        let harness = dir.url.appendingPathComponent("harness")
        guard let journal = t.attempt("opening a journal for a launch", {
            try Journal.open(directory: harness, name: "journal.ndjson", build: build)
        }) else { return }
        journal.append(.launchRequested, data)

        let raw = (try? String(contentsOf: harness.appendingPathComponent("journal.ndjson"), encoding: .utf8)) ?? ""
        t.expect(raw.contains("CLAUDE_CONFIG_DIR"), "the variable name is journalled")
        t.expect(!raw.contains(".claude-work"), "the value of CLAUDE_CONFIG_DIR is not")
        t.expect(!raw.contains("sk-secret"), "no environment value reaches the journal")
        t.expect(!raw.contains("--model"), "the argument vector is not journalled either")
    })()

    // MARK: - 14. One event is always one line

    ({
        let dir = TempDir("journal-ndjson")
        defer { dir.cleanup() }
        let harness = dir.url.appendingPathComponent("harness")
        let file = harness.appendingPathComponent("journal.ndjson")
        guard let journal = t.attempt("opening a journal for awkward values", {
            try Journal.open(directory: harness, name: "journal.ndjson", build: build)
        }) else { return }

        journal.append(.saveFailed, ["message": .string("could not save:\nline two\t\"quoted\"")])
        journal.append(.saveFailed, ["message": .string(String(repeating: "p", count: 4000))])

        let raw = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        t.expectEqual(raw.split(separator: "\n").count, 2, "a value carrying a newline stays on one line")
        let lines = journalLines(at: file)
        t.expectEqual(lines.count, 2, "both lines parse as JSON")
        let long = (lines.last?["data"] as? [String: Any])?["message"] as? String ?? ""
        t.expect(
            long.count <= JournalValue.maximumStringLength,
            "one unbounded value cannot evict the run's own history — \(long.count) characters"
        )
    })()

    // MARK: - 15. A line bigger than the cap itself still terminates

    ({
        let dir = TempDir("journal-tiny-cap")
        defer { dir.cleanup() }
        let harness = dir.url.appendingPathComponent("harness")
        let file = harness.appendingPathComponent("journal.ndjson")
        // Smaller than one line can possibly be, so every append has to trim
        // the whole file and still write. The trim walks line boundaries; a
        // cap it can never satisfy is where that walk would spin.
        guard let journal = t.attempt("opening a journal with an unsatisfiable cap", {
            try Journal.open(directory: harness, name: "journal.ndjson", build: build, maximumBytes: 64)
        }) else { return }

        journal.start(fixture: [:])
        journal.append(.setupShown)
        journal.append(.setupFinished)

        let lines = journalLines(at: file)
        t.expectEqual(lines.count, 1, "a cap no line can fit keeps exactly the newest line")
        t.expectEqual(lines.last?["event"] as? String, "setup finished", "and it is the last one written")
        t.expectEqual(lines.last?["seq"] as? Int, 3, "seq still counts every line that was written")
    })()

    // MARK: - 16. The name rule, both sides of it

    ({
        for name in ["journal.ndjson", ".journal", "a.b.c", "journal", String(repeating: "j", count: 255)] {
            t.expectNoThrow("\(name.prefix(16)) is a leaf file name") {
                try Journal.validate(name: name)
            }
        }
        for name in ["", ".", "..", "a/b", "/abs", "x..y", "a\nb", "a\u{0}b", String(repeating: "j", count: 256)] {
            t.expectThrows("\(name.debugDescription.prefix(20)) is refused") {
                try Journal.validate(name: name)
            }
        }
    })()
}
