// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

// The transcript index: names and the Closed (history) list, built from the
// first and last 64 KB of each Claude Code transcript (R3, R28-R30). Every
// fixture is synthetic and lives in a temp directory; nothing here reads a
// real profile.

// MARK: - Fixed clock

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

/// 2026-09-30 12:00 UTC.
private let now: Date = {
    var parts = DateComponents()
    parts.year = 2026; parts.month = 9; parts.day = 30; parts.hour = 12
    parts.timeZone = TimeZone(identifier: "UTC")
    return utc.date(from: parts)!
}()

private func ago(days: Double = 0, hours: Double = 0) -> Date {
    now.addingTimeInterval(-(days * 86_400 + hours * 3_600))
}

// MARK: - Fixture builders

private func json(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

/// A `user` record, with the keys the real ones carry. `content` is a String or
/// an array of content blocks.
private func user(
    _ session: String,
    cwd: String? = "/work/invoices",
    entrypoint: String? = "cli",
    content: Any = "hello there",
    extra: [String: Any] = [:]
) -> String {
    var record: [String: Any] = [
        "type": "user", "sessionId": session, "isSidechain": false,
        "message": ["role": "user", "content": content],
        "uuid": UUID().uuidString, "timestamp": "2026-09-30T10:00:00.000Z", "version": "2.1.285",
        "gitBranch": "main", "userType": "external",
    ]
    if let cwd { record["cwd"] = cwd }
    if let entrypoint { record["entrypoint"] = entrypoint }
    for (key, value) in extra { record[key] = value }
    return json(record)
}

private func aiTitle(_ title: String) -> String { json(["type": "ai-title", "aiTitle": title, "sessionId": "x"]) }
private func customTitle(_ title: String) -> String { json(["type": "custom-title", "customTitle": title, "sessionId": "x"]) }
private func agentName(_ name: String) -> String { json(["type": "agent-name", "agentName": name, "sessionId": "x"]) }
private func summary(_ text: String) -> String { json(["type": "summary", "summary": text, "leafUuid": "x"]) }

private func assistant(_ text: String) -> String {
    json(["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": text]]]])
}

/// Assistant lines of about 1 KB each, until they total at least `bytes`.
private func filler(_ bytes: Int) -> [String] {
    var lines: [String] = []
    var total = 0
    let line = assistant(String(repeating: "x", count: 1_000))
    while total < bytes {
        lines.append(line)
        total += line.utf8.count + 1
    }
    return lines
}

private struct Store {
    let root: TempDir
    var profile: TranscriptProfile { TranscriptProfile(id: "personal", directory: root.url) }

    init(_ label: String) { root = TempDir(label) }

    /// Writes `<root>/projects/<project>/<session>.jsonl` and stamps its mtime.
    @discardableResult
    func write(
        _ session: String,
        lines: [String],
        project: String = "-work-invoices",
        modified: Date = ago(hours: 1),
        trailingNewline: Bool = true
    ) -> URL {
        let relative = "projects/\(project)/\(session).jsonl"
        let text = lines.joined(separator: "\n") + (trailingNewline ? "\n" : "")
        try? root.write(text, to: relative)
        let url = root.url.appendingPathComponent(relative)
        touch(url, modified)
        return url
    }

    func touch(_ url: URL, _ date: Date) {
        try? FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }
}

/// Counts every read the index makes and passes it through to the real reader.
private final class SpyReader: TranscriptChunkReader {
    struct Call: Equatable { let name: String; let offset: UInt64; let length: Int }
    var calls: [Call] = []
    private let real = FileChunkReader()

    func read(url: URL, offset: UInt64, length: Int) throws -> Data {
        calls.append(Call(name: url.lastPathComponent, offset: offset, length: length))
        return try real.read(url: url, offset: offset, length: length)
    }

    func calls(for session: String) -> [Call] { calls.filter { $0.name == "\(session).jsonl" } }
}

private func entry(_ store: Store, _ session: String, index: TranscriptIndex = TranscriptIndex()) -> TranscriptEntry? {
    index.scan(profiles: [store.profile], now: now).first { $0.sessionId == session }
}

private func closed(
    _ store: Store,
    live: Set<String> = [],
    owned: Set<String> = [],
    renames: [String: String] = [:],
    search: String? = nil,
    index: TranscriptIndex = TranscriptIndex()
) -> [ClosedSection] {
    ClosedSessionList.build(
        entries: index.scan(profiles: [store.profile], now: now),
        live: live, owned: owned, renames: renames,
        search: search, now: now, calendar: utc
    )
}

private func ids(_ sections: [ClosedSection]) -> [String] {
    sections.flatMap { $0.rows }.flatMap { row -> [String] in
        switch row {
        case .session(let session): return [session.id]
        case .fold(let fold): return fold.sessions.map(\.id)
        }
    }
}

// MARK: - Suite

func runTranscriptIndexTests(_ t: TestRunner) {
    t.suite("TranscriptIndex")

    // MARK: Titles

    ({
        let store = Store("ti-last-ai-title")
        defer { store.root.cleanup() }
        store.write("s1", lines: [
            user("s1"), aiTitle("First guess"), assistant("ok"), aiTitle("Second guess"),
            assistant("more"), aiTitle("Final title"),
        ])
        let found = entry(store, "s1")
        t.expectEqual(found?.aiTitle, "Final title", "the last of several ai-title records wins")
        t.expectEqual(found?.title().text, "Final title", "the ai-title is the name")
        t.expectEqual(found?.title().source, .aiTitle, "and is reported as one")
    })()

    ({
        let store = Store("ti-precedence")
        defer { store.root.cleanup() }
        store.write("ai", lines: [user("ai"), aiTitle("AI")])
        store.write("custom", lines: [user("custom"), aiTitle("AI"), customTitle("Renamed in CLI")])
        store.write("agent", lines: [user("agent"), aiTitle("AI"), customTitle("Custom"), agentName("Agent")])
        store.write("summary", lines: [user("summary"), summary("Old summary")])
        store.write("summary-vs-prompt", lines: [user("summary-vs-prompt", content: "the prompt"), summary("Beats prompt")])
        let index = TranscriptIndex()
        let byId = Dictionary(uniqueKeysWithValues: index.scan(profiles: [store.profile], now: now).map { ($0.sessionId, $0) })

        t.expectEqual(byId["custom"]?.title().text, "Renamed in CLI", "custom-title beats ai-title")
        t.expectEqual(byId["custom"]?.title().source, .customTitle, "custom-title source")
        t.expectEqual(byId["agent"]?.title().text, "Agent", "agent-name beats custom-title and ai-title")
        t.expectEqual(byId["agent"]?.title().source, .agentName, "agent-name source")
        t.expectEqual(byId["summary"]?.title().text, "Old summary", "a summary record names a session with nothing else")
        t.expectEqual(byId["summary-vs-prompt"]?.title().text, "Beats prompt", "summary beats the first prompt")

        t.expectEqual(byId["agent"]?.title(rename: "Mine").text, "Mine", "an AgentMenu rename beats agent-name")
        t.expectEqual(byId["custom"]?.title(rename: "Mine").source, .rename, "rename source")
        t.expectEqual(byId["ai"]?.title(rename: "  ").text, "AI", "a blank rename is ignored")
    })()

    ({
        let store = Store("ti-prompt-fallback")
        defer { store.root.cleanup() }
        store.write("text", lines: [user("text", content: "Fix the flaky login test\nand then the rest")])
        store.write("blocks", lines: [user("blocks", content: [["type": "text", "text": "From a block"]])])
        store.write("tool", lines: [
            user("tool", content: [["type": "tool_result", "tool_use_id": "t1", "content": "output"]]),
            user("tool", content: "The real first prompt"),
        ])
        store.write("meta", lines: [
            user("meta", content: "Caveat: generated by the CLI", extra: ["isMeta": true]),
            user("meta", content: "<local-command-stdout>ok</local-command-stdout>"),
            user("meta", content: "What the human typed"),
        ])
        store.write("skill", lines: [user("skill", content: "/collect-invoices")])
        store.write("skill-args", lines: [user("skill-args", content: "/review-pr 1234")])
        store.write("wrapped", lines: [user("wrapped", content:
            "<command-message>compound-engineering:ce-plan</command-message>\n<command-name>/compound-engineering:ce-plan</command-name>\n<command-args>plan the thing</command-args>")])
        store.write("clear-first", lines: [
            user("clear-first", content: "<command-name>/clear</command-name>\n<command-message>clear</command-message>\n<command-args></command-args>"),
            user("clear-first", content: "After the clear"),
        ])
        store.write("path", lines: [user("path", content: "/Users/me/project has a bug")])
        store.write("long", lines: [user("long", content: String(repeating: "word ", count: 100))])
        store.write("nothing", lines: [assistant("hi")])
        let index = TranscriptIndex()
        let byId = Dictionary(uniqueKeysWithValues: index.scan(profiles: [store.profile], now: now).map { ($0.sessionId, $0) })

        t.expectEqual(byId["text"]?.title().text, "Fix the flaky login test", "no title: the first line of the first prompt")
        t.expectEqual(byId["text"]?.title().source, .firstPrompt, "first-prompt source")
        t.expectEqual(byId["blocks"]?.title().text, "From a block", "content given as blocks is read")
        t.expectEqual(byId["tool"]?.title().text, "The real first prompt", "a tool_result-only user record is not a prompt")
        t.expectEqual(byId["meta"]?.title().text, "What the human typed", "meta and local-command records are not prompts")
        t.expectEqual(byId["skill"]?.title().text, "/collect-invoices", "a prompt starting with / names the skill")
        t.expectEqual(byId["skill"]?.title().source, .skill, "skill source")
        t.expectEqual(byId["skill"]?.skill, SkillInvocation(name: "collect-invoices", arguments: ""), "a bare skill is recorded")
        t.expectEqual(byId["skill"]?.skill?.isBare, true, "no arguments means bare")
        t.expectEqual(byId["skill-args"]?.skill, SkillInvocation(name: "review-pr", arguments: "1234"), "arguments are split off")
        t.expectEqual(byId["skill-args"]?.skill?.isBare, false, "a skill with arguments is not bare")
        t.expectEqual(byId["wrapped"]?.title().text, "/compound-engineering:ce-plan", "the CLI's command wrapper names the skill, namespace kept")
        t.expectEqual(byId["wrapped"]?.skill?.arguments, "plan the thing", "wrapper arguments are read")
        t.expectEqual(byId["clear-first"]?.title().text, "After the clear", "a leading /clear does not name the session")
        t.expect(byId["path"]?.skill == nil, "a prompt that starts with a file path is not a skill")
        t.expectEqual(byId["path"]?.title().source, .firstPrompt, "it is a plain prompt")
        t.expectEqual(byId["long"]?.title().text.count, SessionTitles.maxPromptLength, "a long prompt is capped to one row")
        t.expect(byId["long"]?.title().text.hasSuffix("…") == true, "and says so")
        t.expectEqual(byId["nothing"]?.title().text, "nothing", "no title and no prompt: the id prefix")
        t.expectEqual(byId["nothing"]?.title().source, .sessionIdPrefix, "id prefix source")
    })()

    ({
        let title = SessionTitles.resolve(sessionId: "0123456789abcdef")
        t.expectEqual(title.text, "01234567", "the id prefix is eight characters")
    })()

    // MARK: Reading

    ({
        let store = Store("ti-tail-window")
        defer { store.root.cleanup() }
        let head = [user("inside")] + filler(3_000_000)
        store.write("inside", lines: head + [aiTitle("Found in the tail")] + filler(60_000))
        store.write("outside", lines: [user("outside", content: "prompt only")] + filler(3_000_000)
            + [aiTitle("Too early to see")] + filler(70_000))
        let spy = SpyReader()
        let index = TranscriptIndex(reader: spy)
        let byId = Dictionary(uniqueKeysWithValues: index.scan(profiles: [store.profile], now: now).map { ($0.sessionId, $0) })

        t.expectEqual(byId["inside"]?.aiTitle, "Found in the tail", "a title just inside the last 64 KB of a ~3 MB file is found")
        t.expectEqual(byId["outside"]?.aiTitle, nil, "a title before the last 64 KB is out of reach by design")
        t.expectEqual(byId["outside"]?.title().text, "prompt only", "and the name falls back")
        t.expectEqual(byId["inside"]?.restorability, .restorable, "the head still supplies cwd")

        let calls = spy.calls(for: "inside")
        let size = byId["inside"]?.size ?? 0
        t.expectEqual(calls.count, 2, "a large file is read as head and tail only")
        t.expectEqual(calls.first, SpyReader.Call(name: "inside.jsonl", offset: 0, length: 65_536), "the head is the first 64 KB")
        t.expectEqual(calls.last, SpyReader.Call(name: "inside.jsonl", offset: UInt64(size) - 65_536, length: 65_536), "the tail is the last 64 KB")
        t.expect(size > 3_000_000, "the fixture really is about 3 MB")
    })()

    ({
        let store = Store("ti-read-once")
        defer { store.root.cleanup() }
        store.write("small", lines: [user("small"), aiTitle("Small one")])
        store.write("medium", lines: [user("medium")] + filler(100_000) + [aiTitle("Medium one")])
        let spy = SpyReader()
        let index = TranscriptIndex(reader: spy)
        let byId = Dictionary(uniqueKeysWithValues: index.scan(profiles: [store.profile], now: now).map { ($0.sessionId, $0) })

        t.expectEqual(spy.calls(for: "small").count, 1, "a file under 64 KB is read once")
        t.expectEqual(spy.calls(for: "medium").count, 1, "so is one under 128 KB: the two chunks would overlap")
        t.expectEqual(byId["small"]?.aiTitle, "Small one", "and its title is found")
        t.expectEqual(byId["medium"]?.aiTitle, "Medium one", "including from a whole-file read")
    })()

    ({
        let store = Store("ti-truncated")
        defer { store.root.cleanup() }
        // The last line is cut off mid-record, as a write in progress leaves it.
        store.write("cut", lines: [user("cut"), aiTitle("Complete title"), "{\"type\":\"ai-title\",\"aiTitle\":\"Half writ"],
                    trailingNewline: false)
        store.write("garbage", lines: [user("garbage"), "not json at all", aiTitle("After garbage"), "{\"broken\":", "[1,2]"])
        // A large file whose tail chunk begins inside a line.
        let big = [user("big")] + filler(300_000) + [aiTitle("Survives the cut chunk")] + filler(20_000)
            + ["{\"type\":\"ai-title\",\"aiTitle\":\"Half"]
        store.write("big", lines: big, trailingNewline: false)
        let index = TranscriptIndex()
        let byId = Dictionary(uniqueKeysWithValues: index.scan(profiles: [store.profile], now: now).map { ($0.sessionId, $0) })

        t.expectEqual(byId["cut"]?.aiTitle, "Complete title", "a truncated last line is ignored, the last whole record stands")
        t.expectEqual(byId["garbage"]?.aiTitle, "After garbage", "invalid lines are skipped, not fatal")
        t.expectEqual(byId["garbage"]?.restorability, .restorable, "and the file still parses")
        t.expectEqual(byId["big"]?.aiTitle, "Survives the cut chunk", "a partial first line in the tail chunk and a cut last line are both tolerated")
    })()

    ({
        let store = Store("ti-restorable")
        defer { store.root.cleanup() }
        store.write("no-user", lines: [assistant("hello"), aiTitle("A title but no user turn")])
        store.write("empty", lines: [])
        store.write("no-cwd", lines: [user("no-cwd", cwd: nil)])
        store.write("fine", lines: [user("fine")])
        let index = TranscriptIndex()
        let byId = Dictionary(uniqueKeysWithValues: index.scan(profiles: [store.profile], now: now).map { ($0.sessionId, $0) })

        if case .notRestorable(let reason)? = byId["no-user"]?.restorability {
            t.expect(!reason.isEmpty, "a transcript with no user record says why it cannot be restored")
        } else {
            t.expect(false, "a transcript with no user record is not restorable")
        }
        t.expect(byId["no-user"] != nil, "but it is still listed")
        t.expectEqual(byId["no-user"]?.title().text, "A title but no user turn", "and still named")
        t.expect(byId["empty"] != nil && byId["empty"]?.restorability != .restorable, "an empty file is listed, not restorable")
        if case .notRestorable? = byId["no-cwd"]?.restorability {
            t.expect(true, "a transcript with no cwd is not restorable")
        } else {
            t.expect(false, "a transcript with no cwd is not restorable")
        }
        t.expectEqual(byId["fine"]?.restorability, .restorable, "a normal transcript is restorable")
        t.expectEqual(
            byId["no-cwd"]?.restorability, .notRestorable(reason: WorkingDirectoryRule.missingReason),
            "a missing cwd uses the shared reason"
        )

        let sections = closed(store)
        t.expect(ids(sections).contains("no-user"), "the Closed list carries the not-restorable row")
    })()

    // A cwd is typed into a terminal: control bytes and relative paths are refused (the shared rule).
    ({
        let store = Store("ti-cwd-rule")
        defer { store.root.cleanup() }
        store.write("ctrl-c", lines: [user("ctrl-c", cwd: "/work/a\u{03}b")])
        store.write("newline", lines: [user("newline", cwd: "/work/a\nrm -rf ~")])
        store.write("escape", lines: [user("escape", cwd: "/work/\u{1B}[2Jx")])
        store.write("relative", lines: [user("relative", cwd: "work/invoices")])
        store.write("empty-cwd", lines: [user("empty-cwd", cwd: "")])
        store.write("fine", lines: [user("fine", cwd: "/work/with space/it's")])
        let byId = Dictionary(uniqueKeysWithValues: TranscriptIndex().scan(profiles: [store.profile], now: now).map { ($0.sessionId, $0) })
        for id in ["ctrl-c", "newline", "escape", "relative"] {
            t.expectEqual(
                byId[id]?.restorability, .notRestorable(reason: WorkingDirectoryRule.unsafeReason),
                "\(id): a cwd that cannot be typed into a terminal is not restorable, with the shared reason"
            )
        }
        t.expectEqual(byId["empty-cwd"]?.restorability, .notRestorable(reason: WorkingDirectoryRule.missingReason), "an empty cwd is missing")
        t.expectEqual(byId["fine"]?.restorability, .restorable, "spaces and quotes are the quoting's job, not refused")
        t.expect(ids(closed(store)).contains("ctrl-c"), "the refused row is still listed")

        t.expectEqual(WorkingDirectoryRule.check("/a/b"), .success("/a/b"), "an absolute path passes")
        t.expectEqual(WorkingDirectoryRule.check(nil), .failure(.init(reason: WorkingDirectoryRule.missingReason)), "nil is missing")
        t.expectEqual(WorkingDirectoryRule.check("/a\u{7F}"), .failure(.init(reason: WorkingDirectoryRule.unsafeReason)), "DEL is a control character")
        t.expectEqual(WorkingDirectoryRule.check("/a\tb"), .failure(.init(reason: WorkingDirectoryRule.unsafeReason)), "a tab is a control character")
    })()

    ({
        let store = Store("ti-identity")
        defer { store.root.cleanup() }
        // The directory name is lossy (`-` for every non-alphanumeric); the cwd
        // inside the file is the truth, spaces and hyphens included.
        store.write("cwd", lines: [user("cwd", cwd: "/Users/me/my-app v2")], project: "-Users-me-my-app-v2")
        let found = entry(store, "cwd")
        t.expectEqual(found?.cwd, "/Users/me/my-app v2", "cwd comes from inside the file, not the directory name")
        t.expectEqual(found?.folderName, "my-app v2", "folder name is the last component")
        t.expectEqual(found?.entrypoint, "cli", "entrypoint is read")
        t.expectEqual(found?.version, "2.1.285", "version is read")
        t.expectEqual(found?.profileID, "personal", "each entry records its profile (R30)")
        t.expectEqual(found?.configDirectory, store.root.url, "and its config directory")
        t.expectEqual(found?.transcriptURL.lastPathComponent, "cwd.jsonl", "and its transcript")
    })()

    ({
        let one = Store("ti-two-profiles-a")
        let two = Store("ti-two-profiles-b")
        defer { one.root.cleanup(); two.root.cleanup() }
        one.write("in-one", lines: [user("in-one")])
        two.write("in-two", lines: [user("in-two")])
        // A subagent transcript beside the sessions, and one nested deeper.
        one.write("agent-abc123", lines: [user("agent-abc123", extra: ["isSidechain": true])])
        one.write("nested", lines: [user("nested")], project: "-work-invoices/sess/subagents")
        let profiles = [
            TranscriptProfile(id: "work", directory: one.root.url),
            TranscriptProfile(id: "personal", directory: two.root.url),
            TranscriptProfile(id: "work-again", directory: one.root.url),
        ]
        let found = TranscriptIndex().scan(profiles: profiles, now: now)
        t.expectEqual(found.map(\.sessionId).sorted(), ["in-one", "in-two"], "every profile's store is read; sub-agent files are not sessions")
        t.expectEqual(found.first { $0.sessionId == "in-one" }?.profileID, "work", "the store's own profile is recorded")
        t.expectEqual(found.first { $0.sessionId == "in-two" }?.profileID, "personal", "each store keeps its own profile")
        t.expectEqual(TranscriptIndex().scan(profiles: [TranscriptProfile(id: "gone", directory: one.root.url.appendingPathComponent("nope"))], now: now).count,
                      0, "a profile with no projects directory yields nothing")
    })()

    // MARK: Closed list

    ({
        let store = Store("ti-live")
        defer { store.root.cleanup() }
        store.write("a", lines: [user("a")])
        store.write("b", lines: [user("b")])
        let index = TranscriptIndex()
        t.expectEqual(Set(ids(closed(store, live: ["a"], index: index))), ["b"], "AE3: a live session is not in Closed")
        t.expectEqual(Set(ids(closed(store, live: [], index: index))), ["a", "b"], "AE3: once it leaves the live set it appears")
        // R27: the app passes the reader's full live-id set (hidden hosts, parked rows) and the
        // in-flight resumes as `live`. `TranscriptEntry` cannot be built here, so this checks the
        // exclusion by set, not from the registry fixture (RegistryReaderTests covers the set).
        t.expectEqual(
            Set(ids(closed(store, live: Set(["b"]), index: index))), ["a"],
            "R27: an id that is live but not displayed, or in flight, is not in Closed"
        )
    })()

    ({
        let store = Store("ti-entrypoints")
        defer { store.root.cleanup() }
        store.write("cli", lines: [user("cli", entrypoint: "cli")])
        store.write("sdk", lines: [user("sdk", entrypoint: "sdk-cli")])
        store.write("vscode", lines: [user("vscode", entrypoint: "claude-vscode")])
        store.write("desktop", lines: [user("desktop", entrypoint: "claude-desktop")])
        store.write("old", lines: [user("old", entrypoint: nil)])
        t.expectEqual(Set(ids(closed(store))), ["cli", "old"], "sdk-cli, IDE and desktop transcripts are excluded; a transcript from before the field is kept")
    })()

    ({
        let store = Store("ti-retention")
        defer { store.root.cleanup() }
        store.write("fresh", lines: [user("fresh")], modified: ago(days: 29))
        store.write("stale", lines: [user("stale")], modified: ago(days: 31))
        t.expectEqual(Set(ids(closed(store))), ["fresh"], "files older than the 30-day default are excluded")
        let short = TranscriptIndex(retention: 7 * 86_400)
        store.write("week", lines: [user("week")], modified: ago(days: 8))
        t.expectEqual(Set(ids(closed(store, index: short))), [], "retention is injectable")
        let long = TranscriptIndex(retention: 60 * 86_400)
        t.expectEqual(Set(ids(closed(store, index: long))), ["fresh", "stale", "week"], "a longer retention brings them back")
        // Out-of-window files are not read at all.
        let spy = SpyReader()
        _ = TranscriptIndex(reader: spy).scan(profiles: [store.profile], now: now)
        t.expectEqual(spy.calls(for: "stale").count, 0, "an expired file is never opened")
    })()

    ({
        let store = Store("ti-search")
        defer { store.root.cleanup() }
        store.write("a", lines: [user("a", cwd: "/work/quarterly-report"), aiTitle("Reconcile payroll")], project: "-a")
        store.write("b", lines: [user("b", cwd: "/work/website"), aiTitle("Quarterly numbers")], project: "-b")
        store.write("c", lines: [user("c", cwd: "/work/other"), aiTitle("Something else")], project: "-c")
        t.expectEqual(Set(ids(closed(store, search: "quarterly-rep"))), ["a"], "search matches part of a folder name")
        t.expectEqual(Set(ids(closed(store, search: "payr"))), ["a"], "search matches part of a title")
        t.expectEqual(Set(ids(closed(store, search: "QUARTERLY"))), ["a", "b"], "case-insensitively, across name and folder")
        t.expectEqual(Set(ids(closed(store, search: "quarterly website"))), ["b"], "every word must match somewhere")
        t.expectEqual(Set(ids(closed(store, search: "   "))), ["a", "b", "c"], "a blank search shows everything")
        t.expectEqual(Set(ids(closed(store, search: "zzz"))), [], "no match, no rows")
        t.expectEqual(Set(ids(closed(store, renames: ["c": "Payroll rerun"], search: "payroll"))), ["a", "c"], "search sees an AgentMenu rename")
    })()

    ({
        let store = Store("ti-sections")
        defer { store.root.cleanup() }
        store.write("today-early", lines: [user("today-early")], modified: ago(hours: 11))   // 01:00 today
        store.write("today-late", lines: [user("today-late")], modified: ago(hours: 1))
        store.write("yesterday", lines: [user("yesterday")], modified: ago(hours: 13))      // 23:00 yesterday
        store.write("y-early", lines: [user("y-early")], modified: ago(hours: 35))          // 01:00 yesterday
        store.write("edge-week", lines: [user("edge-week")], modified: ago(hours: 179))     // 01:00 on the 23rd: the window's first day
        store.write("edge-older", lines: [user("edge-older")], modified: ago(hours: 181))   // 23:00 on the 22nd: just outside
        store.write("three-days", lines: [user("three-days")], modified: ago(days: 3))
        store.write("two-weeks", lines: [user("two-weeks")], modified: ago(days: 14))
        store.write("month", lines: [user("month")], modified: ago(days: 28))
        let sections = closed(store)
        func members(_ section: RecencySection) -> [String] {
            ids(sections.filter { $0.section == section })
        }
        t.expectEqual(sections.map(\.section), [.today, .yesterday, .last7Days, .older], "sections come in recency order")
        t.expectEqual(members(.today), ["today-late", "today-early"], "Today, newest first")
        t.expectEqual(members(.yesterday), ["yesterday", "y-early"], "Yesterday spans the calendar day")
        t.expectEqual(members(.last7Days), ["three-days", "edge-week"], "Last 7 days is two to seven days ago")
        t.expectEqual(members(.older), ["edge-older", "two-weeks", "month"], "the rest is older")
        t.expectEqual(sections.map(\.section.title), ["Today", "Yesterday", "Last 7 days", "Older"], "section titles")

        let onlyToday = closed(store, search: "zzz")
        t.expect(onlyToday.isEmpty, "empty sections are dropped")
        t.expectEqual(RecencySection.section(for: now.addingTimeInterval(3600), now: now, calendar: utc), .today, "a future mtime counts as today")
    })()

    // MARK: Folding

    ({
        let store = Store("ti-fold")
        defer { store.root.cleanup() }
        for n in 1...5 {
            store.write("run\(n)", lines: [user("run\(n)", cwd: "/work/invoices", content: "/collect-invoices"), aiTitle("Invoices batch \(n)")],
                        modified: ago(hours: Double(n)))
        }
        store.write("owned", lines: [user("owned", cwd: "/work/invoices", content: "/collect-invoices")], modified: ago(hours: 0.5))
        store.write("elsewhere", lines: [user("elsewhere", cwd: "/work/other", content: "/collect-invoices")], modified: ago(hours: 6))
        store.write("with-args", lines: [user("with-args", cwd: "/work/invoices", content: "/collect-invoices --dry-run")], modified: ago(hours: 7))
        store.write("plain", lines: [user("plain", cwd: "/work/invoices", content: "help me")], modified: ago(hours: 8))
        let index = TranscriptIndex()

        let sections = closed(store, owned: ["owned"], index: index)
        t.expectEqual(sections.count, 1, "all of it is Today")
        let rows = sections.first?.rows ?? []
        let folds = rows.compactMap { row -> SkillFold? in if case .fold(let f) = row { return f } else { return nil } }
        let plain = rows.compactMap { row -> String? in if case .session(let s) = row { return s.id } else { return nil } }

        t.expectEqual(folds.count, 1, "the five unowned runs in one folder fold into one row")
        t.expectEqual(folds.first?.count, 5, "with a count")
        t.expectEqual(folds.first?.skill, "collect-invoices", "for the skill")
        t.expectEqual(folds.first?.cwd, "/work/invoices", "and the folder")
        t.expectEqual(folds.first?.sessions.map(\.id), ["run1", "run2", "run3", "run4", "run5"], "the fold lists its runs newest first")
        t.expect(plain.contains("owned"), "an owned run of the same skill stays separate")
        t.expect(plain.contains("elsewhere"), "the same skill in another folder is not folded in (and one run alone does not fold)")
        t.expect(plain.contains("with-args"), "a run with arguments does not fold")
        t.expect(plain.contains("plain"), "a plain session does not fold")
        t.expectEqual(rows.first.map { $0.id }, "owned", "rows stay in recency order")
        t.expectEqual(rows.count, 5, "one fold plus owned, elsewhere, with-args and plain")
        if case .fold? = rows.dropFirst().first { t.expect(true, "the fold sits at its newest run's place") } else { t.expect(false, "the fold sits at its newest run's place") }

        // Searching finds each run one by one, by title, and does not fold.
        let byTitle = closed(store, owned: ["owned"], search: "Invoices batch 3", index: index)
        t.expectEqual(ids(byTitle), ["run3"], "searching a run's title finds that run")
        let byFolder = closed(store, owned: ["owned"], search: "invoices", index: index)
        let folded = byFolder.flatMap(\.rows).contains { if case .fold = $0 { return true } else { return false } }
        t.expect(!folded, "while a search is active nothing is folded")
        for n in 1...5 {
            t.expect(ids(byFolder).contains("run\(n)"), "search still finds run\(n) individually")
        }

        // Folding is per section: the same skill on another day is its own fold.
        store.write("old1", lines: [user("old1", cwd: "/work/invoices", content: "/collect-invoices")], modified: ago(days: 25))
        store.write("old2", lines: [user("old2", cwd: "/work/invoices", content: "/collect-invoices")], modified: ago(days: 26))
        let across = closed(store, owned: ["owned"], index: index)
        t.expectEqual(across.count, 2, "runs on another day land in their own section")
        let olderFolds = across.last?.rows.compactMap { row -> SkillFold? in if case .fold(let f) = row { return f } else { return nil } } ?? []
        t.expectEqual(olderFolds.first?.count, 2, "and fold there on their own")
    })()

    // MARK: Cache

    ({
        let store = Store("ti-cache")
        defer { store.root.cleanup() }
        let url = store.write("c", lines: [user("c"), aiTitle("Original")], modified: ago(hours: 2))
        let spy = SpyReader()
        let index = TranscriptIndex(reader: spy)

        _ = index.scan(profiles: [store.profile], now: now)
        t.expectEqual(spy.calls(for: "c").count, 1, "the first scan reads the file")
        _ = index.scan(profiles: [store.profile], now: now)
        _ = index.scan(profiles: [store.profile], now: now)
        t.expectEqual(spy.calls(for: "c").count, 1, "an unchanged file (same size and mtime) is served from the cache")

        // Same size, new mtime.
        store.touch(url, ago(hours: 1))
        let touched = index.scan(profiles: [store.profile], now: now)
        t.expectEqual(spy.calls(for: "c").count, 2, "a changed mtime forces a re-read")
        t.expectEqual(touched.first?.aiTitle, "Original", "with the same content")

        // New size, mtime put back to what it was.
        let before = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
        if let handle = try? FileHandle(forWritingTo: url) {
            _ = try? handle.seekToEnd()
            handle.write(Data((aiTitle("Renamed later") + "\n").utf8))
            try? handle.close()
        }
        if let before { store.touch(url, before) }
        let grown = index.scan(profiles: [store.profile], now: now)
        t.expectEqual(spy.calls(for: "c").count, 3, "a changed size forces a re-read")
        t.expectEqual(grown.first?.aiTitle, "Renamed later", "and the new title shows")

        // The cache is by facts, not by profile: a renamed profile does not re-read.
        let renamed = TranscriptProfile(id: "renamed", directory: store.root.url)
        t.expectEqual(index.scan(profiles: [renamed], now: now).first?.profileID, "renamed", "a profile's identity is never stale")
        t.expectEqual(spy.calls(for: "c").count, 3, "and costs no re-read")

        // A deleted file drops out and comes back as a fresh read.
        try? FileManager.default.removeItem(at: url)
        t.expectEqual(index.scan(profiles: [store.profile], now: now).count, 0, "a deleted transcript is gone")
    })()

    // MARK: Whether a session was ever prompted (U13)

    ({
        let store = Store("ti-prompt-state")
        defer { store.root.cleanup() }
        let prompted = "0b6f3a52-7c1e-4d0a-9a43-5f1e2c7d8b90"
        let silent = "5d2c9e14-31aa-4b7e-8c60-9a1f3b2d4e77"
        let absent = "7a9e1c33-62d4-4f08-b1a5-3c4d5e6f7a88"
        store.write(prompted, lines: [user(prompted), assistant("hi")])
        store.write(silent, lines: [aiTitle("Nothing yet")])
        store.write("00000000-0000-4000-8000-000000000000", lines: [user("x")], project: "-other")
        let index = TranscriptIndex()
        let places = [URL(fileURLWithPath: store.root.url.path + "/nowhere"), store.root.url]

        t.expectEqual(index.promptState(ofSession: prompted, in: places), .prompted, "a transcript with a user record is prompted")
        t.expectEqual(index.promptState(ofSession: silent, in: places), .neverPrompted, "a transcript with no user record is never prompted")
        t.expectEqual(index.promptState(ofSession: absent, in: places), .neverPrompted, "no transcript at all: the agent writes it with the first prompt")
        t.expectEqual(index.promptState(ofSession: prompted, in: [URL(fileURLWithPath: store.root.url.path + "/nowhere")]), .unknown, "no store to look in is unknown, never a reason to drop a session")
        t.expectEqual(index.promptState(ofSession: prompted, in: []), .unknown, "no directories is unknown")
        t.expectEqual(index.promptState(ofSession: "../../etc/passwd", in: places), .unknown, "something that is not a session id is not looked up")
    })()
}
