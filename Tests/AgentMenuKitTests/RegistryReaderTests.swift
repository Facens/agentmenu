// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

// U2 — the session registry reader, status mapping, process scan and
// terminal identification. Every fixture lives in a temp directory: nothing
// here reads a real `~/.claude*/sessions`, and no test signals a process it
// did not spawn. Most cases run against an injected process table so the
// pids are ours to invent; the few that need the kernel's own answer use this
// runner's pid (alive, with its real start time) or a child that has exited
// (dead).

/// 2026-09-30 07:30:23 UTC — the `procStart` of the real file this suite's
/// shape was taken from.
private let t0: TimeInterval = 1_790_753_423

// MARK: - Fakes and builders

/// A process table the test builds by hand.
private final class FakeProcessTable: ProcessTable {
    var entries: [Int32: ProcessEntry] = [:]
    var directories: [Int32: String] = [:]

    func add(
        _ pid: Int32,
        parent: Int32 = 1,
        path: String? = nil,
        name: String = "claude",
        start: TimeInterval = t0,
        tty: String? = "ttys004",
        cwd: String? = nil
    ) {
        entries[pid] = ProcessEntry(pid: pid, parentPid: parent, path: path, name: name, startTime: start, tty: tty)
        directories[pid] = cwd
    }

    func die(_ pid: Int32) { entries[pid] = nil }

    func allPids() -> [Int32] { Array(entries.keys) }
    func entry(for pid: Int32) -> ProcessEntry? { entries[pid] }
    func isAlive(_ pid: Int32) -> Bool { entries[pid] != nil }
    func workingDirectory(of pid: Int32) -> String? { directories[pid] ?? nil }
}

/// A watcher that only does what the test tells it to.
private final class FakeWatcher: FileWatching {
    final class Handle: WatchHandle {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    private(set) var armed: [(path: String, handle: Handle, handler: (FileEvents) -> Void)] = []

    func watch(_ url: URL, handler: @escaping (FileEvents) -> Void) -> WatchHandle? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let handle = Handle()
        armed.append((url.path, handle, handler))
        return handle
    }

    /// Watches on `path` that have not been cancelled.
    func live(_ path: String) -> Int {
        armed.filter { $0.path == path && !$0.handle.cancelled }.count
    }

    func fire(_ path: String, _ events: FileEvents = .write) {
        for watch in armed where watch.path == path && !watch.handle.cancelled {
            watch.handler(events)
        }
    }
}

/// `ps -o lstart` as Claude Code writes it: UTC, with a single-digit day
/// padded by a space.
private func lstart(_ epoch: TimeInterval) -> String {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    let date = Date(timeIntervalSince1970: epoch)
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .weekday], from: date)
    let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
    let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return String(
        format: "%@ %@ %2d %02d:%02d:%02d %d",
        days[parts.weekday! - 1], months[parts.month! - 1], parts.day!,
        parts.hour!, parts.minute!, parts.second!, parts.year!
    )
}

private func registryJSON(
    pid: Int32,
    procStart: String? = lstart(t0),
    sessionId: String? = nil,
    status: String? = "idle",
    waitingFor: String? = nil,
    entrypoint: String? = "cli",
    kind: String? = "interactive",
    extra: [String: Any] = [:]
) -> String {
    var object: [String: Any] = [
        "pid": Int(pid),
        "sessionId": sessionId ?? "sid-\(pid)",
        "cwd": "/Users/x/dev/proj",
        "startedAt": Int((t0 + 1) * 1000) + 644,
        "version": "2.1.285",
        "peerProtocol": 1,
        "peerFeatures": ["notify_idle"],
        "pidDomain": "darwin",
        "messagingSocketPath": "/tmp/cc-socks/\(pid).sock",
        "name": "some-name",
        "nameSource": "derived",
        "updatedAt": Int(t0 * 1000) + 5_000,
        "statusUpdatedAt": Int(t0 * 1000) + 4_000,
    ]
    if let procStart { object["procStart"] = procStart }
    if let status { object["status"] = status }
    if let waitingFor { object["waitingFor"] = waitingFor }
    if let entrypoint { object["entrypoint"] = entrypoint }
    if let kind { object["kind"] = kind }
    for (key, value) in extra { object[key] = value }
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    return String(decoding: data, as: UTF8.self)
}

/// A config directory with a `sessions/` directory inside a `TempDir`.
private struct Profiles {
    let root: TempDir
    init(_ label: String = "registry") { root = TempDir(label) }

    func directory(_ name: String = "claude") -> URL { root.url.appendingPathComponent(name) }

    func profile(_ name: String = "claude", id: String? = nil) -> RegistryProfile {
        RegistryProfile(id: id ?? name, name: name.capitalized, directory: directory(name))
    }

    @discardableResult
    func write(_ json: String, pid: Int32, in name: String = "claude") -> String {
        let relative = "\(name)/sessions/\(pid).json"
        try? root.write(json, to: relative)
        return root.path(relative)
    }

    func cleanup() { root.cleanup() }
}

private func bundledTerminals() -> [TerminalManifest] {
    let directory = repositoryRoot().appendingPathComponent("Resources/terminals")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.sorted() ?? []
    return names.filter { $0.hasSuffix(".toml") }.compactMap { name in
        let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
        return text.flatMap { try? TerminalManifest.parse($0, origin: .bundled) }
    }
}

/// The bundle ids of the apps the fake chains walk through.
private let fakeBundleIDs: [String: String] = [
    "/Applications/iTerm.app": "com.googlecode.iterm2",
    "/System/Applications/Utilities/Terminal.app": "com.apple.Terminal",
    "/Applications/Visual Studio Code.app": "com.microsoft.VSCode",
]

private func makeResolver() -> TerminalHostResolver {
    TerminalHostResolver(terminals: bundledTerminals(), bundleIdentifier: { fakeBundleIDs[$0] })
}

private func makeReader(
    _ profiles: [RegistryProfile],
    table: ProcessTable,
    targets: [AgentScanTarget] = []
) -> RegistryReader {
    RegistryReader(
        profiles: profiles,
        scanTargets: targets,
        processTable: table,
        terminalResolver: makeResolver()
    )
}

/// Directory listing plus every file's bytes and modification time — what
/// "the reader never writes" is checked against.
private func fingerprint(_ url: URL) -> [String] {
    let manager = FileManager.default
    guard let walker = manager.enumerator(atPath: url.path) else { return [] }
    var lines: [String] = []
    for case let relative as String in walker {
        let full = url.appendingPathComponent(relative).path
        let attributes = try? manager.attributesOfItem(atPath: full)
        let modified = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let data = manager.contents(atPath: full).map { $0.base64EncodedString() } ?? "<dir>"
        lines.append("\(relative)|\(modified)|\(data)")
    }
    return lines.sorted()
}

func runRegistryReaderTests(_ t: TestRunner) {
    t.suite("RegistryReader")

    statusMappingTests(t)
    happyPathTests(t)
    livenessTests(t)
    procStartTests(t)
    filterTests(t)
    liveSessionIDTests(t)
    toleranceTests(t)
    inPlaceRewriteTests(t)
    monitorTests(t)
    realWatcherTests(t)
    scanTests(t)
    profileTests(t)
    terminalTests(t)
    readOnlyTests(t)
}

// MARK: - Status mapping

private func statusMappingTests(_ t: TestRunner) {
    let map = SessionStatusMapping.map

    t.expectEqual(map("busy", nil), MappedStatus(status: .working), "busy is Working")
    t.expectEqual(map("idle", nil), MappedStatus(status: .yourTurn), "idle is Your turn")
    t.expectEqual(
        map("shell", nil), MappedStatus(status: .yourTurn, backgroundTaskRunning: true),
        "shell is Your turn with the background-task hint"
    )
    t.expectEqual(map("idle", nil).backgroundTaskRunning, false, "idle carries no background-task hint")

    for reason in ["permission prompt", "input needed", "sandbox request", "worker request", "goal proposal"] {
        t.expectEqual(map("waiting", reason).status, .needsYou, "waiting/\(reason) is Needs you")
    }
    t.expectEqual(map("waiting", "dialog open").status, .yourTurn, "waiting/dialog open is Your turn")

    // R11: a reason this table has never seen is never Needs you, and a
    // waiting with no reason is not either.
    t.expectEqual(map("waiting", "plan review").status, .unknown, "waiting with an unknown reason is Unknown")
    t.expectEqual(map("waiting", nil).status, .unknown, "waiting with no reason is Unknown")
    t.expectEqual(map("waiting", "Permission Prompt").status, .unknown, "matching is exact, not case-folded")

    t.expectEqual(map(nil, nil).status, .unknown, "no status is Unknown")
    t.expectEqual(map("sleeping", nil).status, .unknown, "an unknown status is Unknown")
    t.expectEqual(map("busy", "permission prompt").status, .working, "waitingFor is ignored unless waiting")
    for status in ["idle", "busy", "shell", "bogus"] {
        t.expect(
            map(status, "permission prompt").status != .needsYou,
            "\(status) with a stale waitingFor is never Needs you"
        )
    }
}

// MARK: - Happy path

private func happyPathTests(_ t: TestRunner) {
    let fixture = Profiles("registry-happy")
    defer { fixture.cleanup() }
    let table = FakeProcessTable()
    for pid: Int32 in [201, 202, 203] { table.add(pid, cwd: nil) }
    fixture.write(registryJSON(pid: 201, status: "busy"), pid: 201)
    fixture.write(registryJSON(pid: 202, status: "idle"), pid: 202)
    fixture.write(registryJSON(pid: 203, status: "waiting", waitingFor: "permission prompt"), pid: 203)

    let reader = makeReader([fixture.profile()], table: table)
    let sessions = reader.refresh()
    let byPid = Dictionary(uniqueKeysWithValues: sessions.map { ($0.pid, $0) })
    t.expectEqual(sessions.count, 3, "three live files give three sessions")
    t.expectEqual(byPid[201]?.status, .working, "busy file is Working")
    t.expectEqual(byPid[202]?.status, .yourTurn, "idle file is Your turn")
    t.expectEqual(byPid[203]?.status, .needsYou, "waiting/permission prompt file is Needs you")
    t.expectEqual(byPid[203]?.waitingFor, "permission prompt", "raw waitingFor is kept")

    if let row = byPid[201] {
        t.expectEqual(row.agentID, "claude-code", "row is a Claude Code row")
        t.expect(row.isClaudeCode, "isClaudeCode")
        t.expectEqual(row.sessionId, "sid-201", "session id")
        t.expectEqual(row.cwd, "/Users/x/dev/proj", "cwd")
        t.expectEqual(row.registryName, "some-name", "registry name")
        t.expectEqual(row.kind, "interactive", "kind")
        t.expectEqual(row.entrypoint, "cli", "entrypoint")
        t.expectEqual(row.version, "2.1.285", "version")
        t.expectEqual(row.tty, "ttys004", "tty comes from the process")
        t.expectEqual(row.profileID, "claude", "profile id")
        t.expectEqual(row.profileName, "Claude", "profile name")
        t.expectEqual(row.configDirectory?.path, fixture.directory().standardizedFileURL.path, "config directory")
        t.expectEqual(row.startedAt.timeIntervalSince1970, t0 + 1.644, "age is taken from the registry's startedAt")
        t.expectEqual(row.updatedAt?.timeIntervalSince1970, t0 + 5, "updatedAt")
        t.expectEqual(row.statusUpdatedAt?.timeIntervalSince1970, t0 + 4, "statusUpdatedAt")
        t.expectEqual(row.key, LiveSessionKey(configDirectory: row.configDirectory?.path, pid: 201, procStart: Int(t0)), "key is (dir, pid, procStart)")
        t.expectEqual(row.tmux, nil, "no tmux field is nil")
    }

    let files = reader.registryFiles.map(\.lastPathComponent).sorted()
    t.expectEqual(files, ["201.json", "202.json", "203.json"], "registryFiles lists what a per-file watch needs")

    // shell -> Your turn with the hint, end to end.
    fixture.write(registryJSON(pid: 202, status: "shell"), pid: 202)
    if let shell = reader.refresh().first(where: { $0.pid == 202 }) {
        t.expectEqual(shell.status, .yourTurn, "shell file is Your turn")
        t.expect(shell.backgroundTaskRunning, "shell file carries the background-task hint")
    } else {
        t.expect(false, "shell session missing")
    }

    // The tmux field is passed through as a hint.
    fixture.write(registryJSON(pid: 202, status: "idle", extra: ["tmux": "/tmp/tmux-501/default,1,0"]), pid: 202)
    t.expectEqual(reader.refresh().first(where: { $0.pid == 202 })?.tmux, "/tmp/tmux-501/default,1,0", "tmux hint passes through")

    // A profile with no sessions directory yields nothing and does not crash.
    let empty = makeReader([RegistryProfile(id: "x", name: "X", directory: fixture.directory("absent"))], table: table)
    t.expectEqual(empty.refresh().count, 0, "a profile with no sessions directory has no sessions")
}

// MARK: - Liveness (real kernel answers)

private func livenessTests(_ t: TestRunner) {
    let fixture = Profiles("registry-liveness")
    defer { fixture.cleanup() }
    let real = LibprocProcessTable()

    let me = getpid()
    guard let mine = real.entry(for: me) else {
        t.expect(false, "libproc describes this process")
        return
    }
    t.expectEqual(mine.startTime, TimeInterval(Int(mine.startTime)), "kernel start time is whole seconds")
    t.expectEqual(mine.parentPid, getppid(), "libproc reports this process's parent")
    t.expect(!(mine.path ?? "").isEmpty, "libproc reports this process's executable path")
    t.expect(real.isAlive(me), "this process is alive")

    // Every ancestor up to launchd must be describable, including the ones
    // other users own: Terminal.app and iTerm2 run their shells under
    // /usr/bin/login, which is root's, and a lookup that is refused for
    // another user's process would end the terminal walk right there and
    // label every real row "Other terminal".
    var ancestor = mine.parentPid
    var walked = 0
    var chainOK = true
    while ancestor > 1, walked < 64 {
        guard let step = real.entry(for: ancestor) else {
            t.expect(false, "ancestor pid \(ancestor) of this process has no entry (chain: \(walked) steps up)")
            chainOK = false
            break
        }
        ancestor = step.parentPid
        walked += 1
    }
    if chainOK { t.expect(walked > 0, "this process has at least one ancestor above launchd") }
    if let launchd = real.entry(for: 1) {
        t.expectEqual(launchd.parentPid, 0, "launchd (root's) is describable too")
        t.expectEqual(launchd.path, "/sbin/launchd", "and so is its path")
    } else {
        t.expect(false, "pid 1 has no entry")
    }
    t.expect(!real.isAlive(0), "pid 0 is not a session")

    // A child that has exited: its pid names nothing now.
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    var deadPid: Int32 = 0
    do {
        try child.run()
        deadPid = child.processIdentifier
        child.waitUntilExit()
    } catch {
        t.expect(false, "could not spawn /usr/bin/true: \(error)")
        return
    }
    t.expect(!real.isAlive(deadPid), "an exited child's pid is not alive")

    let startString = lstart(mine.startTime)
    fixture.write(registryJSON(pid: me, procStart: startString, status: "busy"), pid: me)
    fixture.write(registryJSON(pid: deadPid, procStart: startString, status: "busy"), pid: deadPid)

    let reader = RegistryReader(
        profiles: [fixture.profile()],
        processTable: real,
        terminalResolver: makeResolver()
    )
    var sessions = reader.refresh()
    t.expectEqual(sessions.map(\.pid), [me], "the live pid is listed and the dead pid's file is dropped")
    t.expectEqual(sessions.first?.status, .working, "the live row keeps its status")
    t.expectEqual(sessions.first?.key.procStart, Int(mine.startTime), "key carries the process start")
    t.expect(
        FileManager.default.fileExists(atPath: fixture.root.path("claude/sessions/\(deadPid).json")),
        "the dead pid's file is left alone, only unreported"
    )

    // A reused pid: alive, but the file describes a process that started an hour earlier.
    fixture.write(registryJSON(pid: me, procStart: lstart(mine.startTime - 3600), status: "busy"), pid: me)
    sessions = reader.refresh()
    t.expectEqual(sessions.count, 0, "an alive pid whose procStart differs is dropped")

    // Off by one second is the same process (lstart truncates, the clocks are read apart)...
    fixture.write(registryJSON(pid: me, procStart: lstart(mine.startTime - 1), status: "busy"), pid: me)
    t.expectEqual(reader.refresh().count, 1, "a one-second difference is tolerated")
    // ...two seconds is not.
    fixture.write(registryJSON(pid: me, procStart: lstart(mine.startTime + 2), status: "busy"), pid: me)
    t.expectEqual(reader.refresh().count, 0, "a two-second difference is not")

    // A file with no procStart cannot be checked, so it is not reported.
    fixture.write(registryJSON(pid: me, procStart: nil, status: "busy"), pid: me)
    t.expectEqual(reader.refresh().count, 0, "a file without procStart is not reported")
    fixture.write(registryJSON(pid: me, procStart: "not a date", status: "busy"), pid: me)
    t.expectEqual(reader.refresh().count, 0, "a file with an unparseable procStart is not reported")

    // The whole thing checked against what `ps` itself prints for this process, in UTC.
    let ps = runProcess("/bin/ps", ["-o", "lstart=", "-p", "\(me)"], environment: ["TZ": "UTC"])
    let printed = ps.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    t.expect(ProcStart.matches(printed, kernelStart: mine.startTime), "ps -o lstart (TZ=UTC) \"\(printed)\" matches libproc's start time")
}

// MARK: - procStart

private func procStartTests(_ t: TestRunner) {
    t.expectEqual(ProcStart.parse("Wed Sep 30 07:30:23 2026"), t0, "the observed procStart parses to its UTC instant")
    t.expectEqual(ProcStart.parse("Thu Sep  3 07:30:23 2026"), 1_788_420_623, "a space-padded day parses")
    t.expectEqual(ProcStart.parse("Thu Sep 3 07:30:23 2026"), 1_788_420_623, "an unpadded day parses too")
    t.expectEqual(ProcStart.parse("Thu Sep  3 07:30:23 2026"), ProcStart.parse("Thu Sep 03 07:30:23 2026"), "padding does not change the instant")
    t.expectEqual(ProcStart.parse("  Wed Sep 30 07:30:23 2026  "), t0, "surrounding whitespace is ignored")
    for bad in ["", "garbage", "Wed Sep 30 07:30 2026", "Wed Xyz 30 07:30:23 2026", "Wed Sep 32 07:30:23 2026",
                "Wed Sep 30 25:30:23 2026", "Wed Sep 30 07:30:23", "2026-09-30T07:30:23Z"] {
        t.expectEqual(ProcStart.parse(bad), nil, "\"\(bad)\" is not an lstart")
    }

    // A local time zone must not move the instant: the string is UTC by
    // contract, so parsing it under Kolkata, Los Angeles and Auckland gives
    // the same answer.
    let saved = NSTimeZone.default
    defer { NSTimeZone.default = saved }
    for name in ["Asia/Kolkata", "America/Los_Angeles", "Pacific/Auckland"] {
        guard let zone = TimeZone(identifier: name) else { continue }
        NSTimeZone.default = zone
        t.expectEqual(ProcStart.parse("Wed Sep 30 07:30:23 2026"), t0, "parse is independent of the local zone (\(name))")
        t.expect(ProcStart.matches("Wed Sep 30 07:30:23 2026", kernelStart: t0), "matches under \(name)")
        t.expect(!ProcStart.matches("Wed Sep 30 07:30:23 2026", kernelStart: t0 + 3600), "an hour off does not match under \(name)")
    }
    // Across a DST change in the local zone.
    if let zone = TimeZone(identifier: "America/New_York") {
        NSTimeZone.default = zone
        t.expectEqual(ProcStart.parse("Sun Mar  8 07:00:00 2026"), 1_772_953_200, "a UTC instant on a US DST-change day")
    }
}

// MARK: - Which rows count

private func filterTests(_ t: TestRunner) {
    let fixture = Profiles("registry-filter")
    defer { fixture.cleanup() }
    let table = FakeProcessTable()
    for pid: Int32 in 301...310 { table.add(pid) }

    fixture.write(registryJSON(pid: 301), pid: 301)
    fixture.write(registryJSON(pid: 302, entrypoint: "sdk-cli"), pid: 302)
    fixture.write(registryJSON(pid: 303, entrypoint: "claude-vscode"), pid: 303)
    fixture.write(registryJSON(pid: 304, entrypoint: "claude-desktop"), pid: 304)
    fixture.write(registryJSON(pid: 305, kind: "bg"), pid: 305)
    fixture.write(registryJSON(pid: 306, extra: ["spare": true]), pid: 306)
    fixture.write(registryJSON(pid: 307, extra: ["parkedJobId": "job-1"]), pid: 307)
    fixture.write(registryJSON(pid: 308, kind: "daemon"), pid: 308)
    fixture.write(registryJSON(pid: 309, entrypoint: nil), pid: 309)
    fixture.write(registryJSON(pid: 310, extra: ["spare": false]), pid: 310)

    let sessions = makeReader([fixture.profile()], table: table).refresh()
    t.expectEqual(sessions.map(\.pid).sorted(), [301, 305, 310], "only cli interactive/bg rows that are neither spare nor parked count")
    t.expectEqual(sessions.first(where: { $0.pid == 305 })?.kind, "bg", "a bg row is kept as bg")

    // Two live processes that share one session id are two rows, with distinct keys.
    let shared = Profiles("registry-shared-id")
    defer { shared.cleanup() }
    let sharedTable = FakeProcessTable()
    sharedTable.add(401)
    sharedTable.add(402, start: t0 + 100)
    shared.write(registryJSON(pid: 401, sessionId: "same-id"), pid: 401)
    shared.write(registryJSON(pid: 402, procStart: lstart(t0 + 100), sessionId: "same-id"), pid: 402)
    let both = makeReader([shared.profile()], table: sharedTable).refresh()
    t.expectEqual(both.count, 2, "two live pids sharing a sessionId are two records")
    t.expectEqual(Set(both.map(\.key)).count, 2, "with two distinct keys")
    t.expectEqual(both.map(\.sessionId), ["same-id", "same-id"], "both carry the shared id")

    // Two profiles naming one directory read it once; the first listed owns the rows.
    let dup = Profiles("registry-dup")
    defer { dup.cleanup() }
    let dupTable = FakeProcessTable()
    dupTable.add(501)
    dup.write(registryJSON(pid: 501), pid: 501)
    let first = RegistryProfile(id: "a", name: "A", directory: dup.directory())
    let second = RegistryProfile(id: "b", name: "B", directory: dup.directory())
    let deduped = makeReader([first, second], table: dupTable).refresh()
    t.expectEqual(deduped.count, 1, "two profiles sharing a directory list each session once")
    t.expectEqual(deduped.first?.profileID, "a", "attributed to the first profile listed")
}

// MARK: - Tolerant decoding

private func toleranceTests(_ t: TestRunner) {
    let fixture = Profiles("registry-tolerance")
    defer { fixture.cleanup() }
    let table = FakeProcessTable()
    for pid: Int32 in 601...610 { table.add(pid) }

    fixture.write(
        registryJSON(pid: 601, status: "quantum", extra: ["brandNewField": ["nested": 1], "peerFeatures": 7]),
        pid: 601
    )
    fixture.write(registryJSON(pid: 602, status: nil), pid: 602)
    fixture.write("{ this is not json", pid: 603)
    fixture.write(registryJSON(pid: 604, status: "busy"), pid: 604)
    fixture.write("[1,2,3]", pid: 605)
    fixture.write("{\"sessionId\":\"no-pid\"}", pid: 606)
    // A `.key` file sits beside the sessions and is not one.
    try? fixture.root.write(registryJSON(pid: 607, status: "busy"), to: "claude/sessions/607.f58c9aeef28548743ffb8631626409be.key")
    try? fixture.root.write(registryJSON(pid: 608, status: "busy"), to: "claude/sessions/notes.json")
    // A file whose name and pid disagree was not written by the registry's writer.
    fixture.write(registryJSON(pid: 609, status: "busy"), pid: 610)
    // A JSON boolean is not a pid.
    fixture.write("{\"pid\":true,\"entrypoint\":\"cli\",\"kind\":\"interactive\"}", pid: 1)

    let reader = makeReader([fixture.profile()], table: table)
    let sessions = reader.refresh()
    let byPid = Dictionary(uniqueKeysWithValues: sessions.map { ($0.pid, $0) })
    t.expectEqual(byPid[601]?.status, .unknown, "an unknown status value is Unknown, not an error")
    t.expect(byPid[601] != nil, "unknown extra fields are ignored")
    t.expectEqual(byPid[602]?.status, .unknown, "a missing status is Unknown")
    t.expectEqual(byPid[604]?.status, .working, "a good file is unaffected by the malformed ones around it")
    t.expectEqual(sessions.map(\.pid).sorted(), [601, 602, 604], "malformed and misnamed files are skipped without affecting others")
    t.expect(byPid[607] == nil && byPid[608] == nil, ".key and non-pid files are ignored")
    t.expect(
        !reader.registryFiles.contains(where: { $0.lastPathComponent.hasSuffix(".key") || $0.lastPathComponent == "notes.json" }),
        "registryFiles never includes .key or non-pid files"
    )
}

// MARK: - In-place rewrites

private func inPlaceRewriteTests(_ t: TestRunner) {
    let fixture = Profiles("registry-rewrite")
    defer { fixture.cleanup() }
    let table = FakeProcessTable()
    table.add(701)
    let path = fixture.write(registryJSON(pid: 701, status: "waiting", waitingFor: "permission prompt"), pid: 701)
    let reader = makeReader([fixture.profile()], table: table)

    t.expectEqual(reader.refresh().first?.status, .needsYou, "starts as Needs you")

    // Read mid-write: empty, then truncated. The last good record stands.
    try? "".write(toFile: path, atomically: false, encoding: .utf8)
    t.expectEqual(reader.refresh().first?.status, .needsYou, "an empty file with a live pid keeps the previous status")
    let full = registryJSON(pid: 701, status: "busy")
    try? String(full.prefix(full.count / 2)).write(toFile: path, atomically: false, encoding: .utf8)
    let kept = reader.refresh()
    t.expectEqual(kept.count, 1, "a truncated file with a live pid keeps its row")
    t.expectEqual(kept.first?.status, .needsYou, "and its previous status")
    t.expectEqual(kept.first?.registryName, "some-name", "and its previous fields")

    // The write completes: the new status is read.
    try? full.write(toFile: path, atomically: false, encoding: .utf8)
    t.expectEqual(reader.refresh().first?.status, .working, "the completed write is picked up")

    // A kept record still needs its process: it dies, the row goes even with the file unreadable.
    try? "".write(toFile: path, atomically: false, encoding: .utf8)
    table.die(701)
    t.expectEqual(reader.refresh().count, 0, "a kept record is dropped when its process is gone")

    // The process is back under the same pid and start (a test artefact, but proves the record survives): still there.
    table.add(701)
    t.expectEqual(reader.refresh().first?.status, .working, "the kept record is reported again while the file remains")

    // File removed: the row and its cache go; a new file at the same path is read fresh.
    try? FileManager.default.removeItem(atPath: path)
    t.expectEqual(reader.refresh().count, 0, "a removed file drops its row")
    try? "".write(toFile: path, atomically: false, encoding: .utf8)
    t.expectEqual(reader.refresh().count, 0, "a new empty file at the same path does not resurrect the old record")
}

// MARK: - Live ids the display filter drops (R27)

private func liveSessionIDTests(_ t: TestRunner) {
    let fixture = Profiles("registry-live-ids")
    defer { fixture.cleanup() }
    let table = FakeProcessTable()
    for pid: Int32 in 351...357 { table.add(pid) }
    table.add(358, start: t0 + 500) // a pid its file does not match

    fixture.write(registryJSON(pid: 351, sessionId: "shown"), pid: 351)
    let hiddenID = "9e8d7c6b-5a49-4382-9170-6f5e4d3c2b1a"
    fixture.write(registryJSON(pid: 352, sessionId: hiddenID, entrypoint: "claude-vscode"), pid: 352)
    fixture.write(registryJSON(pid: 353, sessionId: "spare", extra: ["spare": true]), pid: 353)
    fixture.write(registryJSON(pid: 354, sessionId: "parked", extra: ["parkedJobId": "job-1"]), pid: 354)
    fixture.write(registryJSON(pid: 355, sessionId: "desktop", entrypoint: "claude-desktop"), pid: 355)
    fixture.write(registryJSON(pid: 356, sessionId: "dead-file"), pid: 356)
    table.die(356)
    fixture.write(registryJSON(pid: 357, sessionId: "no-id", extra: ["sessionId": ""]), pid: 357)
    fixture.write(registryJSON(pid: 358, sessionId: "reused-pid"), pid: 358)

    let reader = makeReader([fixture.profile()], table: table)
    t.expectEqual(reader.liveSessionIDs, [], "nothing is known before the first refresh")
    let sessions = reader.refresh()
    t.expectEqual(sessions.map(\.sessionId), ["shown", ""], "only the cli rows are displayed (one of them with an empty id)")
    t.expectEqual(
        reader.liveSessionIDs, ["shown", hiddenID, "spare", "parked", "desktop"],
        "every row that passes liveness is a live id, whatever the display filter does with it; a dead pid, a reused pid and an empty id are not"
    )

    // The hidden id is held by no displayed row, yet the guard refuses it once the reader's
    // full set is in the snapshot, and only then.
    t.expect(!sessions.contains { $0.sessionId == hiddenID }, "the IDE-hosted session is not displayed")
    t.expectEqual(
        RestoreGuard.check(sessionID: hiddenID, snapshot: RestoreGuardSnapshot(liveSessions: sessions)), .allow,
        "from the displayed rows alone the guard is blind to it (the gap R27 closes)"
    )
    t.expectEqual(
        RestoreGuard.check(
            sessionID: hiddenID,
            snapshot: RestoreGuardSnapshot(liveSessions: sessions, otherLiveSessionIDs: reader.liveSessionIDs)
        ),
        .refuse(.runningElsewhere),
        "with the reader's live ids it is refused"
    )

    table.die(352)
    _ = reader.refresh()
    t.expect(!reader.liveSessionIDs.contains(hiddenID), "a host whose process has gone stops holding its session")

    // The monitor carries the ids, and announces a change in them that the list does not show.
    let watchers = FakeWatcher()
    let monitor = RegistryMonitor(reader: reader, watcher: watchers) { _ in }
    var idDeliveries: [Set<String>] = []
    monitor.onLiveSessionIDsChange = { idDeliveries.append($0) }
    monitor.start()
    t.expectEqual(idDeliveries.count, 1, "start announces the ids once")
    t.expectEqual(monitor.liveSessionIDs, reader.liveSessionIDs, "the monitor exposes them")
    table.add(359)
    fixture.write(registryJSON(pid: 359, sessionId: "vscode-again", entrypoint: "claude-vscode"), pid: 359)
    monitor.sweep()
    t.expectEqual(monitor.sessions.map(\.sessionId), ["shown", ""], "the displayed list did not change")
    t.expectEqual(idDeliveries.count, 2, "but the live ids did, and were announced")
    t.expect(monitor.liveSessionIDs.contains("vscode-again"), "including the new hidden row")
    monitor.sweep()
    t.expectEqual(idDeliveries.count, 2, "a sweep that changes nothing announces nothing")
    monitor.stop()
}

// MARK: - Monitor, with an injected watcher

private func monitorTests(_ t: TestRunner) {
    let fixture = Profiles("registry-monitor")
    defer { fixture.cleanup() }
    let table = FakeProcessTable()
    table.add(801)
    let sessionsDirectory = fixture.root.path("claude/sessions")
    let file = fixture.write(registryJSON(pid: 801, status: "idle"), pid: 801)
    let reader = makeReader([fixture.profile()], table: table)
    let watcher = FakeWatcher()
    var deliveries: [[LiveSession]] = []
    let monitor = RegistryMonitor(reader: reader, watcher: watcher) { deliveries.append($0) }

    monitor.start()
    t.expectEqual(deliveries.count, 1, "start delivers once")
    t.expectEqual(monitor.sessions.first?.status, .yourTurn, "the initial state is read")
    t.expectEqual(watcher.live(sessionsDirectory), 1, "the sessions directory is watched")
    t.expectEqual(watcher.live(file), 1, "the session file is watched")

    // An in-place status change: no directory event, only the file's own.
    try? registryJSON(pid: 801, status: "waiting", waitingFor: "input needed").write(toFile: file, atomically: false, encoding: .utf8)
    watcher.fire(file, .write)
    t.expectEqual(monitor.sessions.first?.status, .needsYou, "an in-place write is picked up through the file watch alone")
    t.expectEqual(deliveries.count, 2, "and delivered")

    // An event that changes nothing does not deliver.
    watcher.fire(file, .write)
    t.expectEqual(deliveries.count, 2, "an event with no visible change delivers nothing")

    // A second session appears: the directory watch sees it and a file watch is armed on it.
    table.add(802)
    let second = fixture.write(registryJSON(pid: 802, status: "busy"), pid: 802)
    watcher.fire(sessionsDirectory, .write)
    t.expectEqual(monitor.sessions.map(\.pid), [801, 802], "a new file is picked up through the directory watch")
    t.expectEqual(watcher.live(second), 1, "and gets its own file watch")

    // The file is replaced by rename: the old vnode's watch is dropped and a fresh one armed.
    let replacement = registryJSON(pid: 801, status: "busy")
    try? FileManager.default.removeItem(atPath: file)
    try? replacement.write(toFile: file, atomically: true, encoding: .utf8)
    watcher.fire(file, .rename)
    t.expectEqual(watcher.live(file), 1, "a renamed-over file is re-armed once, not twice")
    t.expectEqual(watcher.armed.filter { $0.path == file }.count, 2, "the old watch was cancelled and a new one armed")
    t.expectEqual(monitor.sessions.first(where: { $0.pid == 801 })?.status, .working, "the replacement's content is read")

    // A file removed: its row and its watch go.
    try? FileManager.default.removeItem(atPath: second)
    watcher.fire(sessionsDirectory, .write)
    t.expectEqual(monitor.sessions.map(\.pid), [801], "a removed file drops its row")
    t.expectEqual(watcher.live(second), 0, "and its watch")

    // A process that died without its file going away is caught by the sweep, not by any watch.
    table.die(801)
    monitor.sweep()
    t.expectEqual(monitor.sessions.count, 0, "sweep drops a session whose process is gone")
    t.expectEqual(deliveries.last?.count, 0, "and delivers that")

    monitor.stop()
    let armedAtStop = watcher.armed.count
    monitor.sweep()
    t.expectEqual(watcher.armed.count, armedAtStop, "a stopped monitor arms nothing")
    t.expectEqual(watcher.live(sessionsDirectory), 0, "stop cancels the directory watch")

    // No sessions directory yet: the profile directory is watched until it appears.
    let fresh = Profiles("registry-monitor-fresh")
    defer { fresh.cleanup() }
    try? FileManager.default.createDirectory(at: fresh.directory(), withIntermediateDirectories: true)
    let freshWatcher = FakeWatcher()
    let freshTable = FakeProcessTable()
    freshTable.add(901)
    let freshMonitor = RegistryMonitor(
        reader: makeReader([fresh.profile()], table: freshTable), watcher: freshWatcher
    ) { _ in }
    freshMonitor.start()
    t.expectEqual(freshWatcher.live(fresh.directory().path), 1, "with no sessions directory the profile directory is watched")
    let firstFile = fresh.write(registryJSON(pid: 901), pid: 901)
    freshWatcher.fire(fresh.directory().path, .write)
    t.expectEqual(freshMonitor.sessions.map(\.pid), [901], "the first session ever is picked up")
    t.expectEqual(freshWatcher.live(fresh.directory().path), 0, "the profile-directory watch is swapped out")
    t.expectEqual(freshWatcher.live(fresh.root.path("claude/sessions")), 1, "for one on sessions/")
    t.expectEqual(freshWatcher.live(firstFile), 1, "and the file is watched")
    freshMonitor.stop()
}

// MARK: - Real vnode watcher

private func realWatcherTests(_ t: TestRunner) {
    let fixture = Profiles("registry-vnode")
    defer { fixture.cleanup() }
    let table = FakeProcessTable()
    table.add(1001)
    table.add(1002)
    let file = fixture.write(registryJSON(pid: 1001, status: "idle"), pid: 1001)

    let queue = DispatchQueue(label: "registry-tests.vnode")
    let reader = makeReader([fixture.profile()], table: table)
    let lock = NSLock()
    var latest: [LiveSession] = []
    var seen = DispatchSemaphore(value: 0)
    let monitor = RegistryMonitor(reader: reader, watcher: VnodeWatcher(queue: queue)) { sessions in
        lock.lock()
        latest = sessions
        lock.unlock()
        seen.signal()
    }
    queue.sync { monitor.start() }
    _ = seen.wait(timeout: .now() + 2)

    func current() -> [LiveSession] { lock.lock(); defer { lock.unlock() }; return latest }
    func waitFor(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    // The point of the per-file watch: a rewrite in place, which touches no directory entry.
    let handle = FileHandle(forWritingAtPath: file)
    let rewritten = registryJSON(pid: 1001, status: "busy")
    handle?.truncateFile(atOffset: 0)
    handle?.write(Data(rewritten.utf8))
    try? handle?.close()
    t.expect(waitFor { current().first?.status == .working }, "a real in-place rewrite is seen by the per-file vnode watch")

    // A new file appears.
    fixture.write(registryJSON(pid: 1002, status: "idle"), pid: 1002)
    t.expect(waitFor { current().count == 2 }, "a real new file is seen by the directory vnode watch")

    // And the new file's own in-place rewrite is seen, i.e. it was armed.
    let second = FileHandle(forWritingAtPath: fixture.root.path("claude/sessions/1002.json"))
    second?.truncateFile(atOffset: 0)
    second?.write(Data(registryJSON(pid: 1002, status: "waiting", waitingFor: "sandbox request").utf8))
    try? second?.close()
    t.expect(
        waitFor { current().first(where: { $0.pid == 1002 })?.status == .needsYou },
        "a file that appeared after start is watched too"
    )

    queue.sync { monitor.stop() }
    seen = DispatchSemaphore(value: 0)
}

// MARK: - Other agents (AE6)

private func scanTests(_ t: TestRunner) {
    let table = FakeProcessTable()
    table.add(2001, parent: 1, path: "/opt/homebrew/bin/codex", name: "codex", start: t0 + 50, tty: "ttys007", cwd: "/Users/x/dev/other")
    // A helper of the same agent on the same tty is not a second session.
    table.add(2002, parent: 2001, path: "/opt/homebrew/bin/codex", name: "codex", start: t0 + 51, tty: "ttys007")
    // The same binary with no terminal: a daemon or a desktop host, not a terminal session.
    table.add(2003, parent: 1, path: "/opt/homebrew/bin/codex", name: "codex", start: t0 + 52, tty: nil)
    // Matched on the kernel name when the path differs.
    table.add(2004, parent: 1, path: "/usr/local/lib/x/entry", name: "opencode", start: t0 + 53, tty: "ttys008")
    // Not an agent we look for.
    table.add(2005, parent: 1, path: "/bin/zsh", name: "zsh", tty: "ttys007")
    // A Claude process is the registry's business, not the scan's.
    table.add(2006, parent: 1, path: "/Users/x/.local/share/claude/versions/2.1.285", name: "claude", tty: "ttys009")

    let codex = AgentScanTarget(agentID: "codex", displayName: "Codex", binary: "codex")
    let opencode = AgentScanTarget(agentID: "opencode", displayName: "OpenCode", binary: "opencode")
    let reader = makeReader([], table: table, targets: [codex, opencode])
    let sessions = reader.refresh()

    t.expectEqual(sessions.map(\.pid), [2001, 2004], "the scan finds the agents by binary or kernel name, once each, in a terminal")
    t.expect(sessions.allSatisfy { $0.status == .unknown }, "AE6: a scanned agent's status is Unknown")
    t.expect(sessions.allSatisfy { $0.status != .needsYou }, "AE6: a scanned agent is never Needs you")
    t.expect(sessions.allSatisfy { !$0.isClaudeCode }, "scanned rows are not Claude Code rows")
    if let row = sessions.first {
        t.expectEqual(row.agentID, "codex", "agent id")
        t.expectEqual(row.agentDisplayName, "Codex", "agent display name")
        t.expectEqual(row.cwd, "/Users/x/dev/other", "folder comes from the process's cwd")
        t.expectEqual(row.tty, "ttys007", "tty")
        t.expectEqual(row.startedAt.timeIntervalSince1970, t0 + 50, "age is the process start")
        t.expectEqual(row.key, LiveSessionKey(configDirectory: nil, pid: 2001, procStart: Int(t0) + 50), "key has no config directory")
        t.expectEqual(row.configDirectory, nil, "no config directory")
        t.expectEqual(row.sessionId, nil, "no session id")
        t.expect(!row.backgroundTaskRunning, "no background-task hint")
    }

    // It goes away when the process does.
    table.die(2001)
    table.die(2002)
    t.expectEqual(reader.refresh().map(\.pid), [2004], "a scanned agent is gone when its process is")

    // With nothing to look for the scan is off.
    t.expectEqual(makeReader([], table: table, targets: []).refresh().count, 0, "no scan targets, no scanned rows")

    // Targets come from enabled manifests, minus Claude Code.
    let manifests = ["claude-code", "codex", "opencode"].compactMap { name -> AgentManifest? in
        let url = repositoryRoot().appendingPathComponent("Resources/agents/\(name).toml")
        return (try? String(contentsOf: url, encoding: .utf8)).flatMap { try? AgentManifest.parse($0, origin: .bundled) }
    }
    t.expectEqual(manifests.count, 3, "the three bundled agent manifests parse")
    let enabled = manifests.filter(\.enabled).map(\.id)
    let targets = AgentScanTarget.targets(from: manifests)
    t.expect(!targets.contains(where: { $0.agentID == "claude-code" }), "Claude Code is never a scan target")
    t.expectEqual(Set(targets.map(\.agentID)), Set(enabled).subtracting(["claude-code"]), "targets are the enabled manifests other than Claude Code")
    if let disabled = manifests.first(where: { !$0.enabled && $0.id != "claude-code" }) {
        t.expect(!targets.contains(where: { $0.agentID == disabled.id }), "a disabled agent is not scanned")
        t.expect(AgentScanTarget.targets(from: [disabled]).isEmpty, "a lone disabled manifest yields no targets")
    }
    if let stub = manifests.first(where: { $0.id == "codex" }) {
        t.expectEqual(
            AgentScanTarget.targets(from: [stub]).isEmpty, !stub.enabled,
            "targets follow the manifest's enabled flag"
        )
    }

    // The real table: this process is findable by its own kernel name, and the scan never reports a
    // process that has no terminal, so what comes back depends on how the suite was launched.
    let real = LibprocProcessTable()
    if let mine = real.entry(for: getpid()) {
        let self_ = AgentScanTarget(agentID: "self", displayName: "Self", binary: mine.name)
        let found = ProcessScan.scan(targets: [self_], in: real)
        t.expect(found.allSatisfy { $0.entry.tty != nil }, "the real scan only reports processes with a terminal")
        if mine.tty != nil {
            t.expect(found.contains(where: { $0.entry.pid == getpid() }), "the real scan finds this process by name when it has a terminal")
        }
        t.expect(real.allPids().contains(getpid()), "proc_listallpids includes this process")
    }
}

// MARK: - Profile directories

private func profileTests(_ t: TestRunner) {
    let root = TempDir("registry-profile-root")
    defer { root.cleanup() }

    let tilde = RegistryProfile(profile: Profile(id: "work", name: "Work", configDirectory: "~/.claude-work"), profileRoot: root.url)
    t.expectEqual(tilde.directory.path, root.url.appendingPathComponent(".claude-work").path, "a ~ profile resolves under the override root")
    t.expectEqual(tilde.sessionsDirectory.lastPathComponent, "sessions", "the registry is <config dir>/sessions")

    let absolute = RegistryProfile(profile: Profile(id: "abs", name: "Abs", configDirectory: "/opt/elsewhere/cfg"), profileRoot: root.url)
    t.expectEqual(absolute.directory.path, "/opt/elsewhere/cfg", "an absolute directory ignores the override root")

    let home = NSHomeDirectory()
    let real = RegistryProfile(profile: Profile(id: "p", name: "P", configDirectory: "~/.claude-personal"), profileRoot: nil)
    t.expectEqual(real.directory.path, "\(home)/.claude-personal", "without a root, ~ is the real home")

    // End to end: files under the root are what the reader lists.
    try? root.write(registryJSON(pid: 1101, status: "busy"), to: ".claude-work/sessions/1101.json")
    let table = FakeProcessTable()
    table.add(1101)
    let sessions = makeReader([tilde], table: table).refresh()
    t.expectEqual(sessions.map(\.pid), [1101], "the reader reads the profile under the override root")
    t.expectEqual(sessions.first?.profileID, "work", "and attributes it to that profile")
}

// MARK: - Terminal identification

private func terminalTests(_ t: TestRunner) {
    let resolver = makeResolver()
    let table = FakeProcessTable()

    // Terminal.app: claude -> zsh -> login -> Terminal.
    table.add(3010, parent: 1, path: "/System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal", name: "Terminal", tty: nil)
    table.add(3011, parent: 3010, path: "/usr/bin/login", name: "login", tty: "ttys001")
    table.add(3012, parent: 3011, path: "/bin/zsh", name: "zsh", tty: "ttys001")
    table.add(3013, parent: 3012, path: "/Users/x/.local/share/claude/versions/2.1.285", name: "claude", tty: "ttys001")
    t.expectEqual(resolver.identify(pid: 3013, in: table), TerminalIdentity(id: "terminal-app", displayName: "Terminal"), "a chain reaching Terminal.app is labelled Terminal")

    // iTerm2: claude -> zsh -> login -> iTermServer (a server process inside the bundle).
    table.add(3020, parent: 1, path: "/Applications/iTerm.app/Contents/MacOS/iTerm2", name: "iTerm2", tty: nil)
    table.add(3021, parent: 3020, path: "/Applications/iTerm.app/Contents/MacOS/iTermServer-3.6.0", name: "iTermServer-3.6.0", tty: nil)
    table.add(3022, parent: 3021, path: "/usr/bin/login", name: "login", tty: "ttys002")
    table.add(3023, parent: 3022, path: "/bin/zsh", name: "zsh", tty: "ttys002")
    table.add(3024, parent: 3023, path: "/opt/claude", name: "claude", tty: "ttys002")
    t.expectEqual(resolver.identify(pid: 3024, in: table), TerminalIdentity(id: "iterm2", displayName: "iTerm2"), "a chain reaching iTerm's server process is labelled iTerm2")

    // The server process alone, detached from iTerm2 itself (iTerm re-parents its servers to launchd).
    table.add(3030, parent: 1, path: "/Applications/iTerm.app/Contents/MacOS/iTermServer-3.6.0", name: "iTermServer-3.6.0", tty: nil)
    table.add(3031, parent: 3030, path: "/bin/zsh", name: "zsh", tty: "ttys003")
    table.add(3032, parent: 3031, path: "/opt/claude", name: "claude", tty: "ttys003")
    t.expectEqual(resolver.identify(pid: 3032, in: table).id, "iterm2", "an iTermServer re-parented to launchd still identifies iTerm2")

    // iTerm2's session servers live outside the bundle, in the user's
    // Application Support, and after iTerm restarts they hang off launchd.
    let outside = TerminalHostResolver(
        terminals: bundledTerminals(), bundleIdentifier: { fakeBundleIDs[$0] }, homeDirectory: "/Users/x"
    )
    table.add(3035, parent: 1, path: "/Users/x/Library/Application Support/iTerm2/iTermServer-3.6.0", name: "iTermServer-3.6.0", tty: nil)
    table.add(3036, parent: 3035, path: "/usr/bin/login", name: "login", tty: "ttys006")
    table.add(3037, parent: 3036, path: "/bin/zsh", name: "zsh", tty: "ttys006")
    table.add(3038, parent: 3037, path: "/opt/claude", name: "claude", tty: "ttys006")
    t.expectEqual(outside.identify(pid: 3038, in: table), TerminalIdentity(id: "iterm2", displayName: "iTerm2"), "an iTermServer outside the bundle, re-parented to launchd, is iTerm2")
    t.expectEqual(resolver.identify(pid: 3038, in: table), .other, "...and only for the home directory it was told about")
    table.add(3045, parent: 1, path: "/Users/x/Library/Application Support/iTerm2/SomethingElse", name: "SomethingElse", tty: nil)
    table.add(3046, parent: 3045, path: "/opt/claude", name: "claude", tty: "ttys007")
    t.expectEqual(outside.identify(pid: 3046, in: table), .other, "a different executable in that directory is not a session server")
    table.add(3047, parent: 1, path: "/Users/x/Downloads/iTermServer-3.6.0", name: "iTermServer-3.6.0", tty: nil)
    table.add(3048, parent: 3047, path: "/opt/claude", name: "claude", tty: "ttys008")
    t.expectEqual(outside.identify(pid: 3048, in: table), .other, "an iTermServer anywhere else is not iTerm's")
    let withoutITerm = TerminalHostResolver(
        terminals: bundledTerminals().filter { $0.id != "iterm2" }, bundleIdentifier: { fakeBundleIDs[$0] }, homeDirectory: "/Users/x"
    )
    t.expectEqual(withoutITerm.identify(pid: 3038, in: table), .other, "with no iterm2 manifest the path pattern names nothing")

    // Neither: a chain under an unrelated app, and a chain that ends at launchd.
    table.add(3040, parent: 1, path: "/Applications/Visual Studio Code.app/Contents/MacOS/Electron", name: "Electron", tty: nil)
    table.add(3041, parent: 3040, path: "/bin/zsh", name: "zsh", tty: "ttys004")
    table.add(3042, parent: 3041, path: "/opt/claude", name: "claude", tty: "ttys004")
    t.expectEqual(resolver.identify(pid: 3042, in: table), .other, "a chain reaching an app that is not a terminal is Other terminal")
    table.add(3050, parent: 1, path: "/opt/claude", name: "claude", tty: "ttys005")
    t.expectEqual(resolver.identify(pid: 3050, in: table), .other, "a chain that ends at launchd is Other terminal")
    t.expectEqual(TerminalIdentity.other.displayName, "Other terminal", "the label")
    t.expect(TerminalIdentity.other.id == nil, "Other terminal is not a known terminal")
    t.expectEqual(resolver.identify(pid: 99_999, in: table), .other, "an unknown pid is Other terminal")

    // A parent loop or a self-parent must not hang the sweep.
    table.add(3060, parent: 3061, path: "/bin/zsh", name: "zsh")
    table.add(3061, parent: 3060, path: "/bin/zsh", name: "zsh")
    table.add(3062, parent: 3062, path: "/bin/zsh", name: "zsh")
    t.expectEqual(resolver.identify(pid: 3060, in: table), .other, "a parent cycle terminates")
    t.expectEqual(resolver.identify(pid: 3062, in: table), .other, "a self-parent terminates")

    // An argv terminal has no bundle id in its manifest: it is matched by its binary.
    table.add(3070, parent: 1, path: "/Applications/Ghostty.app/Contents/MacOS/ghostty", name: "ghostty", tty: nil)
    table.add(3071, parent: 3070, path: "/bin/zsh", name: "zsh", tty: "ttys006")
    table.add(3072, parent: 3071, path: "/opt/claude", name: "claude", tty: "ttys006")
    t.expectEqual(resolver.identify(pid: 3072, in: table).id, "ghostty", "an argv terminal is identified by its binary name")

    // Through the reader: the terminal lands on the row.
    let fixture = Profiles("registry-terminal")
    defer { fixture.cleanup() }
    fixture.write(registryJSON(pid: 3013), pid: 3013)
    fixture.write(registryJSON(pid: 3024), pid: 3024)
    fixture.write(registryJSON(pid: 3042), pid: 3042)
    let rows = makeReader([fixture.profile()], table: table).refresh()
    let labels = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0.terminal.displayName) })
    t.expectEqual(labels[3013], "Terminal", "row: Terminal")
    t.expectEqual(labels[3024], "iTerm2", "row: iTerm2")
    t.expectEqual(labels[3042], "Other terminal", "row: Other terminal")

    // The default bundle-id reader: a real Info.plist, found by path, needing no AppKit.
    let apps = TempDir("registry-apps")
    defer { apps.cleanup() }
    let plist: [String: Any] = ["CFBundleIdentifier": "com.googlecode.iterm2", "CFBundleName": "iTerm2"]
    if let data = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
        let infoPath = apps.path("iTerm.app/Contents/Info.plist")
        try? FileManager.default.createDirectory(atPath: (infoPath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: infoPath))
    }
    t.expectEqual(TerminalHostResolver.readBundleIdentifier(apps.path("iTerm.app")), "com.googlecode.iterm2", "the bundle id is read from Info.plist")
    t.expectEqual(TerminalHostResolver.readBundleIdentifier(apps.path("Missing.app")), nil, "a missing app has no bundle id")
    let realResolver = TerminalHostResolver(terminals: bundledTerminals())
    let onDisk = FakeProcessTable()
    onDisk.add(3080, parent: 1, path: apps.path("iTerm.app/Contents/MacOS/iTermServer-3.6.0"), name: "iTermServer", tty: nil)
    onDisk.add(3081, parent: 3080, path: "/bin/zsh", name: "zsh", tty: "ttys010")
    onDisk.add(3082, parent: 3081, path: "/opt/claude", name: "claude", tty: "ttys010")
    t.expectEqual(realResolver.identify(pid: 3082, in: onDisk).id, "iterm2", "the default resolver identifies a bundle by its real Info.plist")

    // The live table, whatever launched this run: if an ancestor is an
    // executable inside Terminal.app or iTerm.app the label must say so —
    // through `login`, which is root's — and if not, the answer is only that
    // it is not a crash.
    let liveTable = LibprocProcessTable()
    var liveAncestor = liveTable.entry(for: getpid())?.parentPid ?? 0
    var expected: String?
    var hops = 0
    while liveAncestor > 1, hops < 64, expected == nil {
        let path = liveTable.entry(for: liveAncestor)?.path ?? ""
        if path.hasPrefix("/System/Applications/Utilities/Terminal.app/") { expected = "terminal-app" }
        if path.contains("/iTerm.app/") { expected = "iterm2" }
        liveAncestor = liveTable.entry(for: liveAncestor)?.parentPid ?? 0
        hops += 1
    }
    let liveLabel = realResolver.identify(pid: getpid(), in: liveTable)
    if let expected {
        t.expectEqual(liveLabel.id, expected, "this run's real ancestry reaches a known terminal and is labelled with it")
    } else {
        t.expect(true, "this run has no Terminal.app or iTerm ancestor; label is \(liveLabel.displayName)")
    }

    if FileManager.default.fileExists(atPath: "/System/Applications/Utilities/Terminal.app/Contents/Info.plist") {
        t.expectEqual(
            TerminalHostResolver.readBundleIdentifier("/System/Applications/Utilities/Terminal.app"),
            "com.apple.Terminal", "the real Terminal.app's bundle id matches its manifest"
        )
    }
}

// MARK: - Read-only

private func readOnlyTests(_ t: TestRunner) {
    let fixture = Profiles("registry-readonly")
    defer { fixture.cleanup() }
    let table = FakeProcessTable()
    table.add(4001)
    fixture.write(registryJSON(pid: 4001, status: "busy"), pid: 4001)
    fixture.write("{ half", pid: 4002)
    try? fixture.root.write("key material", to: "claude/sessions/4001.abcdef.key")
    try? fixture.root.write("{}", to: "claude/settings.json")

    let before = fingerprint(fixture.directory())
    // Let a timestamp granularity difference show if anything is touched.
    Thread.sleep(forTimeInterval: 0.05)
    let reader = makeReader([fixture.profile()], table: table)
    for _ in 0..<3 { reader.refresh() }
    let after = fingerprint(fixture.directory())
    t.expectEqual(before, after, "refreshing never creates, modifies, touches or removes anything under a profile directory")

    let monitor = RegistryMonitor(reader: reader, watcher: FakeWatcher()) { _ in }
    monitor.start()
    monitor.sweep()
    monitor.stop()
    t.expectEqual(before, fingerprint(fixture.directory()), "nor does the monitor")
}
