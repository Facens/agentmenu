// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

/// What the kernel says about one process. Only the fields the session
/// reader needs; nothing here is a guess.
public struct ProcessEntry: Equatable, Sendable {
    public let pid: Int32
    public let parentPid: Int32
    /// Absolute path of the executable, when the kernel would give it.
    public let path: String?
    /// The kernel's short process name.
    public let name: String
    /// Kernel process start, whole seconds since the epoch. `procStart` in a
    /// registry file is checked against this, never against a string.
    public let startTime: TimeInterval
    /// Controlling terminal as its device name (`ttys004`, no `/dev/`), or
    /// nil for a process with none.
    public let tty: String?

    public init(
        pid: Int32,
        parentPid: Int32,
        path: String?,
        name: String,
        startTime: TimeInterval,
        tty: String?
    ) {
        self.pid = pid
        self.parentPid = parentPid
        self.path = path
        self.name = name
        self.startTime = startTime
        self.tty = tty
    }
}

/// The process-table lookups the session reader depends on, behind a
/// protocol so tests can hand it a table they built instead of the live one.
public protocol ProcessTable {
    func allPids() -> [Int32]
    /// nil when the process is gone or the kernel refuses to describe it.
    func entry(for pid: Int32) -> ProcessEntry?
    /// Whether `pid` names a running process. EPERM counts as alive: the
    /// process exists, it just is not ours to signal.
    func isAlive(_ pid: Int32) -> Bool
    func workingDirectory(of pid: Int32) -> String?
}

/// A process table that remembers what `entry(for:)` answered, for the length
/// of one refresh: the reader's liveness check, the process scan and every
/// terminal walk up a parent chain ask about the same pids, and each answer
/// is a sysctl plus two libproc calls. A miss (nil) is remembered too.
///
/// Built fresh for each refresh and dropped with it, so nothing is carried
/// from one sweep to the next; `isAlive` is never cached, because liveness is
/// exactly what a later sweep must ask again (KTD7). Not thread-safe: a
/// refresh runs on one queue.
final class CachingProcessTable: ProcessTable {
    private let base: ProcessTable
    private var entries: [Int32: ProcessEntry?] = [:]

    init(_ base: ProcessTable) {
        self.base = base
    }

    func allPids() -> [Int32] { base.allPids() }

    func entry(for pid: Int32) -> ProcessEntry? {
        if let cached = entries[pid] { return cached }
        let fetched = base.entry(for: pid)
        entries[pid] = .some(fetched)
        return fetched
    }

    func isAlive(_ pid: Int32) -> Bool { base.isAlive(pid) }

    func workingDirectory(of pid: Int32) -> String? { base.workingDirectory(of: pid) }
}

/// The live process table, through libproc.
public struct LibprocProcessTable: ProcessTable {
    public init() {}

    public func allPids() -> [Int32] {
        let size = proc_listallpids(nil, 0)
        guard size > 0 else { return [] }
        // Head-room: processes can start between the two calls.
        var pids = [Int32](repeating: 0, count: Int(size) + 32)
        let written = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listallpids(buffer.baseAddress, Int32(buffer.count * MemoryLayout<Int32>.stride))
        }
        guard written > 0 else { return [] }
        return pids.prefix(Int(written)).filter { $0 > 0 }
    }

    public func entry(for pid: Int32) -> ProcessEntry? {
        // sysctl, not `proc_pidinfo(PROC_PIDTBSDINFO)`: the latter refuses
        // any process another user owns, and a terminal's shell runs under
        // `/usr/bin/login`, which is root's. With that refusal the walk up
        // to the terminal would stop at `login` and every real row would be
        // labelled "Other terminal". `ps` reads the same table this way.
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &info, &length, nil, 0) == 0,
              length == MemoryLayout<kinfo_proc>.stride,
              info.kp_proc.p_pid == pid else { return nil }

        // `proc_pidpath` and `proc_name` are exempt from the same-user rule.
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let pathLength = proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count))
        let path = pathLength > 0 ? String(cString: pathBuffer) : nil

        var nameBuffer = [CChar](repeating: 0, count: 64)
        let nameLength = proc_name(pid, &nameBuffer, UInt32(nameBuffer.count))
        let name = nameLength > 0 ? String(cString: nameBuffer) : ""

        return ProcessEntry(
            pid: pid,
            parentPid: info.kp_eproc.e_ppid,
            path: path,
            name: name,
            startTime: TimeInterval(info.kp_proc.p_starttime.tv_sec),
            tty: Self.deviceName(info.kp_eproc.e_tdev)
        )
    }

    public func isAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    public func workingDirectory(of pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        let path = withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw -> String in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        return path.isEmpty ? nil : path
    }

    /// `ttys004` for the controlling terminal's device number; nil for
    /// "none" (`NODEV`, all bits set).
    static func deviceName(_ device: dev_t) -> String? {
        guard device != dev_t(-1) else { return nil }
        var buffer = [CChar](repeating: 0, count: 64)
        guard devname_r(device, S_IFCHR, &buffer, Int32(buffer.count)) != nil else {
            return nil
        }
        let name = String(cString: buffer)
        // devname_r answers "#C0x..." style placeholders for devices it has
        // no node for; only a real name is a tty.
        return name.isEmpty || name.hasPrefix("#") ? nil : name
    }
}

// MARK: - procStart

/// Claude Code's `procStart`, and the check that makes it worth having.
///
/// The registry stores the process start as `ps -o lstart` prints it, in UTC:
/// `Wed Sep 30 07:30:23 2026`, and `Thu Sep  3 07:30:23 2026` with the day
/// padded by a space. A pid alone proves nothing — Claude Code can crash and
/// leave its file behind, and macOS reuses pids — so a row counts only when
/// this instant matches the kernel's own start time for that pid (KTD7).
///
/// It is parsed to an instant and compared numerically, never as a string:
/// the string depends on the time zone `ps` ran under and on padding, the
/// instant does not.
public enum ProcStart {
    /// The two clocks are read a moment apart and `lstart` has one-second
    /// resolution, so a 1 s difference is the same process. A reused pid
    /// starts seconds or more after the one it replaced.
    public static let tolerance: TimeInterval = 1

    private static let months: [String: Int] = [
        "Jan": 1, "Feb": 2, "Mar": 3, "Apr": 4, "May": 5, "Jun": 6,
        "Jul": 7, "Aug": 8, "Sep": 9, "Oct": 10, "Nov": 11, "Dec": 12,
    ]

    /// Seconds since the epoch, or nil for anything that is not the
    /// `lstart` shape.
    public static func parse(_ text: String) -> TimeInterval? {
        // Splitting on runs of whitespace is what makes the space-padded day
        // parse: "Sep  3" is two spaces and a "3".
        let parts = text.split(whereSeparator: { $0 == " " || $0 == "\t" })
        guard parts.count == 5 else { return nil }
        guard let month = months[String(parts[1])],
              let day = Int(parts[2]),
              let year = Int(parts[4]) else { return nil }
        let clock = parts[3].split(separator: ":", omittingEmptySubsequences: false)
        guard clock.count == 3,
              let hour = Int(clock[0]), let minute = Int(clock[1]), let second = Int(clock[2]) else { return nil }
        guard (1...31).contains(day), (0...23).contains(hour),
              (0...59).contains(minute), (0...60).contains(second) else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        guard let date = calendar.date(from: components) else { return nil }
        return date.timeIntervalSince1970
    }

    /// Whether the registry's `procStart` names the same start instant as the
    /// kernel's. A missing or unparseable `procStart` never matches: without
    /// it there is nothing to tell this process from a stranger that reused
    /// the pid.
    public static func matches(_ procStart: String?, kernelStart: TimeInterval) -> Bool {
        guard let procStart, let parsed = parse(procStart) else { return false }
        return abs(parsed - kernelStart) <= tolerance
    }
}

// MARK: - Terminal identity

/// The terminal a session runs in, as the row shows it.
public struct TerminalIdentity: Equatable, Sendable {
    /// The terminal manifest's id, or nil when no known terminal hosts the
    /// process.
    public let id: String?
    public let displayName: String

    public init(id: String?, displayName: String) {
        self.id = id
        self.displayName = displayName
    }

    /// Unrecognised host. Focusing is hidden for it, and the row says why.
    public static let other = TerminalIdentity(id: nil, displayName: "Other terminal")
}

/// Finds the terminal hosting a process by walking its parent chain to an
/// executable inside a known terminal app.
///
/// The parent chain, not the tty or the environment, because it is what the
/// kernel maintains: Terminal.app runs its jobs under `login`, iTerm2 runs
/// them under `iTermServer` processes that live inside its own bundle, and
/// either way an ancestor's executable sits inside the terminal's `.app`. The
/// app is then identified the way the terminal manifests already identify it
/// — by bundle id, read from the app's `Info.plist` — so a new terminal
/// manifest is recognised without this file learning its name. An `argv`
/// terminal has no bundle id in its manifest, so it is matched by the
/// executable name its manifest declares.
///
/// **Session servers outside the bundle.** iTerm2 does not keep its
/// `iTermServer-<version>` processes inside `iTerm.app`: they are copied to
/// `~/Library/Application Support/iTerm2/`, and after iTerm restarts they are
/// re-parented to launchd and outlive it. A chain that ends at one of those
/// has no `.app` ancestor at all, so it would be labelled "Other terminal"
/// — and Other-terminal rows cannot be focused. `externalHostExecutables`
/// names them, by the owning terminal's bundle id, so the terminal is still
/// found through its manifest and the entry is inert when that manifest is
/// absent.
public final class TerminalHostResolver {
    /// An executable that hosts a terminal's sessions from outside its app
    /// bundle.
    public struct ExternalHostExecutable: Equatable, Sendable {
        /// The owning terminal, by the bundle id its manifest declares.
        public let bundleID: String
        /// Directory the executable lives in, relative to the home directory.
        public let directory: String
        /// The executable's file name starts with this.
        public let namePrefix: String

        public init(bundleID: String, directory: String, namePrefix: String) {
            self.bundleID = bundleID
            self.directory = directory
            self.namePrefix = namePrefix
        }
    }

    /// The known cases. Adding a terminal with the same habit is one line
    /// here.
    public static let externalHostExecutables: [ExternalHostExecutable] = [
        ExternalHostExecutable(
            bundleID: "com.googlecode.iterm2",
            directory: "Library/Application Support/iTerm2",
            namePrefix: "iTermServer"
        ),
    ]

    private struct Match {
        let id: String
        let displayName: String
    }

    private struct ExternalHost {
        /// Absolute directory with a trailing slash.
        let directory: String
        let namePrefix: String
        let match: Match
    }

    private let bundleIDs: [String: Match]
    private let binaries: [String: Match]
    private let externalHosts: [ExternalHost]
    private let bundleIdentifier: (String) -> String?
    private var bundleCache: [String: String?] = [:]

    /// Longest chain walked. Real chains are under ten; the cap and the
    /// visited set exist so a corrupt table cannot loop the sweep.
    private static let maxDepth = 64

    /// - Parameters:
    ///   - terminals: every terminal manifest, enabled or not — a running
    ///     iTerm2 is iTerm2 even when the user turned launching into it off.
    ///   - bundleIdentifier: the bundle id of the `.app` at a path; injected
    ///     so tests need no installed terminal.
    ///   - homeDirectory: what `externalHostExecutables` directories are
    ///     relative to; injected so a test does not depend on whose home it
    ///     runs in.
    public init(
        terminals: [TerminalManifest],
        bundleIdentifier: @escaping (String) -> String? = TerminalHostResolver.readBundleIdentifier,
        homeDirectory: String = NSHomeDirectory()
    ) {
        var bundleIDs: [String: Match] = [:]
        var binaries: [String: Match] = [:]
        for terminal in terminals {
            let match = Match(id: terminal.id, displayName: terminal.displayName)
            if let bundleID = terminal.bundleID { bundleIDs[bundleID] = bundleIDs[bundleID] ?? match }
            if let binary = terminal.binary { binaries[binary] = binaries[binary] ?? match }
        }
        self.bundleIDs = bundleIDs
        self.binaries = binaries
        let home = homeDirectory.hasSuffix("/") ? String(homeDirectory.dropLast()) : homeDirectory
        self.externalHosts = Self.externalHostExecutables.compactMap { entry in
            bundleIDs[entry.bundleID].map {
                ExternalHost(directory: home + "/" + entry.directory + "/", namePrefix: entry.namePrefix, match: $0)
            }
        }
        self.bundleIdentifier = bundleIdentifier
    }

    public func identify(pid: Int32, in table: ProcessTable) -> TerminalIdentity {
        var visited: Set<Int32> = [pid]
        var current = table.entry(for: pid)?.parentPid ?? 0
        var depth = 0
        while current > 1, depth < Self.maxDepth, visited.insert(current).inserted {
            guard let ancestor = table.entry(for: current) else { break }
            if let match = match(ancestor) {
                return TerminalIdentity(id: match.id, displayName: match.displayName)
            }
            current = ancestor.parentPid
            depth += 1
        }
        return .other
    }

    private func match(_ process: ProcessEntry) -> Match? {
        if let path = process.path {
            if let app = Self.outermostAppBundle(in: path),
               let bundleID = cachedBundleIdentifier(app),
               let match = bundleIDs[bundleID] {
                return match
            }
            let fileName = (path as NSString).lastPathComponent
            if let host = externalHosts.first(where: { path.hasPrefix($0.directory) && fileName.hasPrefix($0.namePrefix) }) {
                return host.match
            }
            if let match = binaries[fileName] { return match }
        }
        return binaries[process.name]
    }

    private func cachedBundleIdentifier(_ appPath: String) -> String? {
        if let cached = bundleCache[appPath] { return cached }
        let value = bundleIdentifier(appPath)
        bundleCache[appPath] = .some(value)
        return value
    }

    /// `/Applications/iTerm.app` for
    /// `/Applications/iTerm.app/Contents/MacOS/iTermServer-3.5.0`. The
    /// outermost bundle, so a helper app nested inside a terminal is still
    /// attributed to that terminal.
    static func outermostAppBundle(in path: String) -> String? {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard let index = components.firstIndex(where: { $0.hasSuffix(".app") }) else { return nil }
        return "/" + components[0...index].joined(separator: "/")
    }

    /// `CFBundleIdentifier` of the app at `appPath`, read straight from its
    /// `Info.plist` — Foundation only, so Kit stays free of AppKit.
    public static func readBundleIdentifier(_ appPath: String) -> String? {
        let plist = URL(fileURLWithPath: appPath).appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dictionary = object as? [String: Any] else { return nil }
        return dictionary["CFBundleIdentifier"] as? String
    }
}

// MARK: - Other agents

/// One agent the process scan looks for.
public struct AgentScanTarget: Equatable, Sendable {
    public let agentID: String
    public let displayName: String
    /// Executable name to look for, from the manifest's `binary`.
    public let binary: String

    public init(agentID: String, displayName: String, binary: String) {
        self.agentID = agentID
        self.displayName = displayName
        self.binary = binary
    }

    /// The scan targets for a set of agent manifests: every enabled agent
    /// except Claude Code. Claude Code is read from its registry, which knows
    /// its status; scanning for it too would list every session twice, once
    /// with a status and once without.
    ///
    /// `isEnabled` decides which agents count as on; it defaults to the
    /// manifest's own flag, and a caller that has the user's configuration
    /// passes the configured state instead.
    public static func targets(
        from manifests: [AgentManifest],
        isEnabled: (AgentManifest) -> Bool = { $0.enabled }
    ) -> [AgentScanTarget] {
        manifests
            .filter { isEnabled($0) && $0.id != RegistryReader.claudeAgentID }
            .map { AgentScanTarget(agentID: $0.id, displayName: $0.displayName, binary: $0.binary) }
    }
}

/// A running process that is one of the scanned agents.
public struct ScannedAgentProcess: Equatable, Sendable {
    public let target: AgentScanTarget
    public let entry: ProcessEntry
    public let workingDirectory: String?
}

/// Finds running processes of agents that keep no registry (AE6).
///
/// A process is matched by its executable's file name or, failing that, the
/// kernel's process name. An agent that is a script run by an interpreter
/// shows up under the interpreter's name (`node`) and is invisible to this
/// scan; that is a known limit, and the answer to it is a registry, not a
/// wider net that would list every `node` on the Mac.
///
/// Only processes with a controlling terminal count: an agent in a terminal
/// always has one, and one without is a daemon, an IDE's child or a
/// desktop-app host, which R1 leaves out. A process whose parent is the same
/// agent on the same terminal is that agent's own helper, not a second
/// session.
public enum ProcessScan {
    public static func scan(
        targets: [AgentScanTarget],
        in table: ProcessTable
    ) -> [ScannedAgentProcess] {
        guard !targets.isEmpty else { return [] }
        var byBinary: [String: AgentScanTarget] = [:]
        for target in targets { byBinary[target.binary] = byBinary[target.binary] ?? target }

        var matched: [Int32: (AgentScanTarget, ProcessEntry)] = [:]
        for pid in table.allPids() {
            guard let entry = table.entry(for: pid), entry.tty != nil else { continue }
            let fileName = entry.path.map { ($0 as NSString).lastPathComponent }
            guard let target = fileName.flatMap({ byBinary[$0] }) ?? byBinary[entry.name] else { continue }
            matched[pid] = (target, entry)
        }

        return matched.values
            .filter { target, entry in
                guard let parent = matched[entry.parentPid] else { return true }
                return !(parent.0.agentID == target.agentID && parent.1.tty == entry.tty)
            }
            .sorted { $0.1.pid < $1.1.pid }
            .map { target, entry in
                ScannedAgentProcess(
                    target: target,
                    entry: entry,
                    workingDirectory: table.workingDirectory(of: entry.pid)
                )
            }
    }
}
