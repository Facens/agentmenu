// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

/// One Claude Code config directory to read, already resolved.
///
/// The directory is resolved through `Overrides.resolveProfileDirectory`
/// exactly as the launch path resolves it, so under the first-run harness's
/// profile root the reader looks at the harness's directories and never the
/// maintainer's own.
public struct RegistryProfile: Equatable, Sendable {
    public let id: String
    public let name: String
    public let directory: URL

    public init(id: String, name: String, directory: URL) {
        self.id = id
        self.name = name
        self.directory = directory
    }

    public init(profile: Profile, profileRoot: URL?) {
        self.init(
            id: profile.id,
            name: profile.name,
            directory: Overrides.resolveProfileDirectory(profile.configDirectory, profileRoot: profileRoot)
        )
    }

    /// Where Claude Code keeps `<pid>.json`, one file per running process.
    public var sessionsDirectory: URL {
        directory.appendingPathComponent("sessions", isDirectory: true)
    }
}

/// The identity of a live row (KTD7): where it is registered, which process,
/// and which incarnation of that pid.
///
/// Never the session id. Two live processes can share one — a forked or
/// resumed session — and Claude Code changes the id in place on `/clear`, so
/// an id-keyed row would merge two sessions in one case and flicker into a
/// new row in the other.
public struct LiveSessionKey: Hashable, Sendable {
    /// The config directory whose registry holds the row; nil for an agent
    /// found by the process scan, which has no registry.
    public let configDirectory: String?
    public let pid: Int32
    /// The process start in whole epoch seconds. It is what tells a pid's
    /// current occupant from an earlier one that had the same number.
    public let procStart: Int

    public init(configDirectory: String?, pid: Int32, procStart: Int) {
        self.configDirectory = configDirectory
        self.pid = pid
        self.procStart = procStart
    }
}

/// A running agent session: everything a later unit needs to show a row, and
/// nothing it has to go back to a file for.
public struct LiveSession: Equatable, Sendable {
    public let key: LiveSessionKey
    /// `claude-code`, or the manifest id of a scanned agent.
    public let agentID: String
    public let agentDisplayName: String

    // Where it is registered. All nil for a scanned agent.
    public let profileID: String?
    public let profileName: String?
    public let configDirectory: URL?
    /// The registry file the row was read from.
    public let registryFile: URL?

    public let pid: Int32
    public let sessionId: String?
    public let cwd: String?
    /// `interactive` or `bg`; nil for a scanned agent.
    public let kind: String?
    /// `cli` for every Claude Code row; nil for a scanned agent.
    public let entrypoint: String?
    /// The name Claude Code derived or was given; nil when it has none.
    public let registryName: String?
    public let version: String?

    public let status: SessionStatus
    /// The registry's raw `waitingFor`, kept so a later unit can log or show
    /// the reason even for values the mapping treats as unknown.
    public let waitingFor: String?
    /// `shell`: idle at the prompt with a background task still running.
    public let backgroundTaskRunning: Bool

    public let tty: String?
    public let terminal: TerminalIdentity
    /// Claude Code's `tmux` field. A hint about how the session is hosted,
    /// never something to act on without a check.
    public let tmux: String?

    /// Session start, for the row's age.
    public let startedAt: Date
    public let updatedAt: Date?
    public let statusUpdatedAt: Date?

    public var isClaudeCode: Bool { agentID == RegistryReader.claudeAgentID }

    /// Public so the snapshot builder's tests, and any preview, can build a
    /// row without a registry directory and a process table behind it. The
    /// reader remains the only thing that builds one for real.
    public init(
        key: LiveSessionKey,
        agentID: String,
        agentDisplayName: String,
        profileID: String? = nil,
        profileName: String? = nil,
        configDirectory: URL? = nil,
        registryFile: URL? = nil,
        pid: Int32,
        sessionId: String? = nil,
        cwd: String? = nil,
        kind: String? = nil,
        entrypoint: String? = nil,
        registryName: String? = nil,
        version: String? = nil,
        status: SessionStatus,
        waitingFor: String? = nil,
        backgroundTaskRunning: Bool = false,
        tty: String? = nil,
        terminal: TerminalIdentity = .other,
        tmux: String? = nil,
        startedAt: Date,
        updatedAt: Date? = nil,
        statusUpdatedAt: Date? = nil
    ) {
        self.key = key
        self.agentID = agentID
        self.agentDisplayName = agentDisplayName
        self.profileID = profileID
        self.profileName = profileName
        self.configDirectory = configDirectory
        self.registryFile = registryFile
        self.pid = pid
        self.sessionId = sessionId
        self.cwd = cwd
        self.kind = kind
        self.entrypoint = entrypoint
        self.registryName = registryName
        self.version = version
        self.status = status
        self.waitingFor = waitingFor
        self.backgroundTaskRunning = backgroundTaskRunning
        self.tty = tty
        self.terminal = terminal
        self.tmux = tmux
        self.startedAt = startedAt
        self.updatedAt = updatedAt
        self.statusUpdatedAt = statusUpdatedAt
    }

    /// The same row with another terminal: a hosted session's process tree
    /// ends at tmux, so the reader labels it "Other terminal"; the ledger
    /// knows which terminal its window was opened in.
    public func replacingTerminal(_ terminal: TerminalIdentity) -> LiveSession {
        LiveSession(
            key: key, agentID: agentID, agentDisplayName: agentDisplayName,
            profileID: profileID, profileName: profileName,
            configDirectory: configDirectory, registryFile: registryFile,
            pid: pid, sessionId: sessionId, cwd: cwd, kind: kind, entrypoint: entrypoint,
            registryName: registryName, version: version,
            status: status, waitingFor: waitingFor, backgroundTaskRunning: backgroundTaskRunning,
            tty: tty, terminal: terminal, tmux: tmux,
            startedAt: startedAt, updatedAt: updatedAt, statusUpdatedAt: statusUpdatedAt
        )
    }
}

/// Reads every configured profile's Claude Code session registry, and scans
/// for other agents, into live `LiveSession`s.
///
/// **Read-only.** The reader never creates, writes, touches or deletes
/// anything under a profile directory. A file that is stale is left in place
/// and simply not reported.
///
/// **What counts as live (KTD7).** A row needs its pid to be running
/// (`kill(pid, 0)`, EPERM counting as alive) *and* the file's `procStart`
/// to equal the kernel's start time for that pid. The second half is what
/// rejects a file left by a crash and a pid the system has since handed to a
/// stranger. A file without a usable `procStart` cannot be checked, so it is
/// not reported.
///
/// **What counts as a session (KTD8).** `entrypoint == "cli"` and `kind` of
/// `interactive` or `bg`. SDK, IDE and desktop-app hosts write to the same
/// directory and are left out (R1), as are `spare` rows and rows parked under
/// a `parkedJobId`.
///
/// **Half-written files.** Claude Code rewrites a file in place, so a read
/// can land mid-write. A file that fails to parse keeps its last good record
/// for as long as the file exists and its process is alive; a row goes away
/// only when the file is removed or the process check fails. It is the
/// reverse of `UsageReader`, which reports a refusal, because a session that
/// blinked out of the list and back on every rewrite would be worse than a
/// status that is one write old.
///
/// The reader is stateful and single-threaded: call `refresh()` from one
/// queue. It is cheap — a directory listing and a few small reads per profile
/// — so the 2-second sweep and every watcher event use the same entry point.
public final class RegistryReader {
    public static let claudeAgentID = "claude-code"

    /// A registry file's decoded fields; the last good one is kept per path.
    private struct Record {
        let pid: Int32
        let sessionId: String?
        let cwd: String?
        let startedAt: Date?
        let procStart: String?
        let version: String?
        let kind: String?
        let entrypoint: String?
        let name: String?
        let status: String?
        let waitingFor: String?
        let tmux: String?
        let spare: Bool
        let parked: Bool
        let updatedAt: Date?
        let statusUpdatedAt: Date?
    }

    private struct Source {
        let profile: RegistryProfile
        let file: URL
    }

    private let profiles: [RegistryProfile]
    private let scanTargets: [AgentScanTarget]
    private let processTable: ProcessTable
    private let terminalResolver: TerminalHostResolver
    private let fileManager: FileManager
    private var lastGood: [String: Record] = [:]

    /// Registry files present at the last `refresh()` — what a per-file
    /// watch should be armed on.
    public private(set) var registryFiles: [URL] = []

    /// The session id of **every** registry row that passed liveness at the
    /// last `refresh()` (KTD7), whatever the display filter then did with it: an
    /// IDE or desktop host, a spare row, a row parked under a job. None of
    /// those is listed, but a transcript running under any of them is still a
    /// process writing it, so the restore guard and the Closed list read this
    /// set, not the displayed rows (R27, KTD13).
    public private(set) var liveSessionIDs: Set<String> = []

    /// - Parameters:
    ///   - profiles: config directories to read. Two profiles naming one
    ///     directory are read once and attributed to the one listed first.
    ///   - scanTargets: other agents to look for by process name; empty
    ///     turns the scan off.
    public init(
        profiles: [RegistryProfile],
        scanTargets: [AgentScanTarget] = [],
        processTable: ProcessTable = LibprocProcessTable(),
        terminalResolver: TerminalHostResolver,
        fileManager: FileManager = .default
    ) {
        var seen: Set<String> = []
        self.profiles = profiles.filter { seen.insert($0.directory.standardizedFileURL.path).inserted }
        self.scanTargets = scanTargets
        self.processTable = processTable
        self.terminalResolver = terminalResolver
        self.fileManager = fileManager
    }

    /// Each profile's `sessions/` directory, whether or not it exists yet.
    public var sessionsDirectories: [URL] { profiles.map(\.sessionsDirectory) }

    /// The profile directories themselves, for watching until `sessions/`
    /// appears.
    public var profileDirectories: [URL] { profiles.map(\.directory) }

    /// Re-reads every registry file, re-checks every process, and re-runs the
    /// scan. The one entry point for the 2-second sweep and for watcher
    /// events alike.
    @discardableResult
    public func refresh() -> [LiveSession] {
        let sources = listSources()
        registryFiles = sources.map(\.file)

        // A file that is gone is a session that is gone: drop its record so
        // a later file at the same path is read fresh.
        let present = Set(sources.map(\.file.path))
        for path in lastGood.keys where !present.contains(path) { lastGood[path] = nil }

        // One table for the whole refresh: a pid is looked up once, however
        // many rows and parent chains pass through it.
        let table = CachingProcessTable(processTable)
        var sessions: [LiveSession] = []
        var liveIDs: Set<String> = []
        for source in sources {
            if let record = read(source.file) { lastGood[source.file.path] = record }
            guard let record = lastGood[source.file.path],
                  let procStart = liveProcStart(of: record, table: table) else { continue }
            if let sessionId = record.sessionId, !sessionId.isEmpty { liveIDs.insert(sessionId) }
            guard let session = session(from: record, source: source, table: table, procStart: procStart) else { continue }
            sessions.append(session)
        }
        liveSessionIDs = liveIDs
        sessions.append(contentsOf: scannedSessions(table: table))
        return sessions.sorted {
            ($0.startedAt, $0.pid) < ($1.startedAt, $1.pid)
        }
    }

    // MARK: - Files

    private func listSources() -> [Source] {
        var sources: [Source] = []
        for profile in profiles {
            let names = (try? fileManager.contentsOfDirectory(atPath: profile.sessionsDirectory.path)) ?? []
            // `*.json` only, and only `<pid>.json`: the same directory holds
            // `<pid>.<hex>.key` files that are not sessions, and nothing
            // else in it is a registry shape this reader was written for.
            for name in names.sorted() where name.hasSuffix(".json") {
                let stem = String(name.dropLast(".json".count))
                guard Int32(stem) != nil else { continue }
                sources.append(Source(profile: profile, file: profile.sessionsDirectory.appendingPathComponent(name)))
            }
        }
        return sources
    }

    /// nil for anything that is not a complete, recognisable registry file —
    /// unreadable, empty, half-written, not an object, no pid — so the caller
    /// keeps the last good record instead.
    private func read(_ file: URL) -> Record? {
        guard let data = try? Data(contentsOf: file), !data.isEmpty,
              let json = try? JSONSerialization.jsonObject(with: data),
              let object = json as? [String: Any],
              let pidValue = Self.number(object["pid"]),
              pidValue.truncatingRemainder(dividingBy: 1) == 0,
              pidValue > 0, pidValue <= Double(Int32.max) else { return nil }
        let pid = Int32(pidValue)
        // The file's name is its pid. A file that says otherwise was not
        // written by the writer this reader knows.
        guard "\(pid).json" == file.lastPathComponent else { return nil }

        return Record(
            pid: pid,
            sessionId: Self.string(object["sessionId"]),
            cwd: Self.string(object["cwd"]),
            startedAt: Self.number(object["startedAt"]).map { Date(timeIntervalSince1970: $0 / 1000) },
            procStart: Self.string(object["procStart"]),
            version: Self.string(object["version"]),
            kind: Self.string(object["kind"]),
            entrypoint: Self.string(object["entrypoint"]),
            name: Self.string(object["name"]),
            status: Self.string(object["status"]),
            waitingFor: Self.string(object["waitingFor"]),
            tmux: Self.string(object["tmux"]),
            spare: Self.bool(object["spare"]) ?? false,
            parked: Self.string(object["parkedJobId"]) != nil,
            updatedAt: Self.number(object["updatedAt"]).map { Date(timeIntervalSince1970: $0 / 1000) },
            statusUpdatedAt: Self.number(object["statusUpdatedAt"]).map { Date(timeIntervalSince1970: $0 / 1000) }
        )
    }

    // MARK: - Claude Code rows

    /// Liveness (KTD7): the pid runs and is the process that wrote this. The
    /// file's parsed `procStart` when it does, nil when it does not. Applies to
    /// every row, displayed or not.
    private func liveProcStart(of record: Record, table: ProcessTable) -> TimeInterval? {
        guard table.isAlive(record.pid),
              let entry = table.entry(for: record.pid),
              ProcStart.matches(record.procStart, kernelStart: entry.startTime) else { return nil }
        return record.procStart.flatMap(ProcStart.parse)
    }

    private func session(from record: Record, source: Source, table: ProcessTable, procStart: TimeInterval) -> LiveSession? {
        // Which rows are sessions at all (KTD8).
        guard record.entrypoint == "cli",
              record.kind == "interactive" || record.kind == "bg",
              !record.spare, !record.parked,
              let entry = table.entry(for: record.pid) else { return nil }

        let mapped = SessionStatusMapping.map(status: record.status, waitingFor: record.waitingFor)
        let configDirectory = source.profile.directory.standardizedFileURL
        return LiveSession(
            key: LiveSessionKey(configDirectory: configDirectory.path, pid: record.pid, procStart: Int(procStart)),
            agentID: Self.claudeAgentID,
            agentDisplayName: "Claude Code",
            profileID: source.profile.id,
            profileName: source.profile.name,
            configDirectory: configDirectory,
            registryFile: source.file,
            pid: record.pid,
            sessionId: record.sessionId,
            cwd: record.cwd,
            kind: record.kind,
            entrypoint: record.entrypoint,
            registryName: record.name,
            version: record.version,
            status: mapped.status,
            waitingFor: record.waitingFor,
            backgroundTaskRunning: mapped.backgroundTaskRunning,
            tty: entry.tty,
            terminal: terminalResolver.identify(pid: record.pid, in: table),
            tmux: record.tmux,
            // The registry's own start when it has one; the kernel's when it
            // does not, so a row always has an age.
            startedAt: record.startedAt ?? Date(timeIntervalSince1970: procStart),
            updatedAt: record.updatedAt,
            statusUpdatedAt: record.statusUpdatedAt
        )
    }

    // MARK: - Other agents

    /// Agents with no registry. Their status is `unknown` by construction —
    /// nothing on the process says what the agent is doing — so they can
    /// never be Needs you (AE6, R11).
    private func scannedSessions(table: ProcessTable) -> [LiveSession] {
        ProcessScan.scan(targets: scanTargets, in: table).map { found in
            LiveSession(
                key: LiveSessionKey(configDirectory: nil, pid: found.entry.pid, procStart: Int(found.entry.startTime)),
                agentID: found.target.agentID,
                agentDisplayName: found.target.displayName,
                profileID: nil,
                profileName: nil,
                configDirectory: nil,
                registryFile: nil,
                pid: found.entry.pid,
                sessionId: nil,
                cwd: found.workingDirectory,
                kind: nil,
                entrypoint: nil,
                registryName: nil,
                version: nil,
                status: .unknown,
                waitingFor: nil,
                backgroundTaskRunning: false,
                tty: found.entry.tty,
                terminal: terminalResolver.identify(pid: found.entry.pid, in: table),
                tmux: nil,
                startedAt: Date(timeIntervalSince1970: found.entry.startTime),
                updatedAt: nil,
                statusUpdatedAt: nil
            )
        }
    }

    // MARK: - Tolerant field access

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    /// A JSON number; never a JSON boolean, which `NSNumber` would otherwise
    /// pass off as 0 or 1.
    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, !isJSONBoolean(number) else { return nil }
        return number.doubleValue
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, isJSONBoolean(number) else { return nil }
        return number.boolValue
    }
}
