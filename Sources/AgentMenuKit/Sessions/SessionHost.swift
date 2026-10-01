// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Where the host lives

/// The host directory and everything inside it (KTD4).
///
/// The directory is `~/Library/Application Support/<bundle id>/host/<tmux
/// version>/`, next to the harness directory. The bundle id keeps a release
/// and a beta build apart; the version keeps a Sparkle update that replaces
/// the app bundle from stranding running sessions with a client of a
/// different protocol. It holds the helper copies, the generated tmux config,
/// the socket (`s`) and the death-record file. The socket is never in `/tmp`,
/// which macOS cleans after three days.
///
/// A Unix socket path is limited to 104 bytes including the terminating NUL,
/// so a long home directory would make the primary location unusable. The
/// fallback is `/Users/Shared/.agentmenu-<uid>/<8 hex digits of a hash of the
/// bundle id>/<tmux version>/`: persistent (not cleaned), writable by every
/// user, short whatever the home is, and still per user and per bundle id.
/// `SessionHost.ensureHost()` refuses a directory the current user does not
/// own, along with each directory it creates below `/Users/Shared`, so another
/// account cannot pre-create one.
public struct SessionHostLocation: Equatable, Sendable {
    /// `sockaddr_un.sun_path` is 104 bytes and the last is the NUL.
    public static let maximumSocketPathBytes = 103
    public static let socketFileName = "s"
    public static let stateFileName = "host-state"
    /// The tmux version the bundle ships (KTD2). Part of the directory name,
    /// so bumping the helper starts a fresh host instead of replacing the
    /// binary under a running server.
    public static let defaultHelperVersion = "3.7c"

    public let directory: URL
    /// True when the home-relative location was too long for a socket and the
    /// shared fallback was used.
    public let usesFallback: Bool

    public init(directory: URL, usesFallback: Bool = false) {
        self.directory = directory
        self.usesFallback = usesFallback
    }

    public var socket: URL { directory.appendingPathComponent(Self.socketFileName) }
    public var config: URL { directory.appendingPathComponent(HostConfig.fileName) }
    public var stateFile: URL { directory.appendingPathComponent(Self.stateFileName) }
    public func helper(named name: String) -> URL { directory.appendingPathComponent(name) }
    public var serverHelper: URL { helper(named: HostHelperNames.server) }
    public var clientHelper: URL { helper(named: HostHelperNames.client) }

    /// Whether the socket path fits `sockaddr_un`.
    public var socketPathFits: Bool {
        socket.path.utf8.count <= Self.maximumSocketPathBytes
    }

    /// Where the host lives for this build.
    ///
    /// - Parameter override: `Overrides.sessionHostDirectory`. Used exactly as
    ///   given — the harness and the tests pick it, and it must be short
    ///   enough; no fallback is substituted for a path someone chose.
    public static func resolve(
        override: URL? = nil,
        bundleIdentifier: String?,
        helperVersion: String = defaultHelperVersion,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        userID: UInt32 = UInt32(getuid())
    ) throws -> SessionHostLocation {
        if let override {
            let location = SessionHostLocation(directory: override)
            guard location.socketPathFits else {
                throw SessionHostError.socketPathTooLong(location.socket.path, location.socket.path.utf8.count)
            }
            return location
        }
        let identifier = bundleIdentifier.flatMap { $0.isEmpty ? nil : $0 } ?? SessionStore.fallbackBundleIdentifier
        let primary = SessionHostLocation(
            directory: home
                .appendingPathComponent("Library/Application Support", isDirectory: true)
                .appendingPathComponent(identifier, isDirectory: true)
                .appendingPathComponent("host", isDirectory: true)
                .appendingPathComponent(helperVersion, isDirectory: true)
        )
        if primary.socketPathFits { return primary }

        let fallback = SessionHostLocation(
            directory: URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
                .appendingPathComponent(".agentmenu-\(userID)", isDirectory: true)
                .appendingPathComponent(shortHash(identifier), isDirectory: true)
                .appendingPathComponent(helperVersion, isDirectory: true),
            usesFallback: true
        )
        guard fallback.socketPathFits else {
            throw SessionHostError.socketPathTooLong(fallback.socket.path, fallback.socket.path.utf8.count)
        }
        return fallback
    }

    /// Eight lowercase hex digits of FNV-1a over the identifier: a stable,
    /// dependency-free stand-in for the bundle id in a path that has to stay
    /// short. Not a security measure.
    static func shortHash(_ text: String) -> String {
        var hash: UInt32 = 2_166_136_261
        for byte in text.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 8 - hex.count) + hex
    }
}

// MARK: - Errors

public enum SessionHostError: Error, Equatable, CustomStringConvertible {
    case helperMissing(String)
    case socketPathTooLong(String, Int)
    case directoryNotOwned(String)
    case invalidLaunchID(String)
    case invalidEnvironmentName(String)
    case emptyCommand
    case serverNotRunning
    case commandFailed(command: String, status: Int32, stderr: String)

    public var description: String {
        switch self {
        case .helperMissing(let path):
            return "The session host helper is missing at \(path)."
        case .socketPathTooLong(let path, let bytes):
            return "The session host socket path is \(bytes) bytes, over the \(SessionHostLocation.maximumSocketPathBytes)-byte limit: \(path)"
        case .directoryNotOwned(let path):
            return "The session host directory is not owned by this user: \(path)"
        case .invalidLaunchID(let id):
            return "\"\(id)\" is not a usable session name (letters, digits, - and _ only)."
        case .invalidEnvironmentName(let name):
            return "\"\(name)\" is not a valid environment variable name."
        case .emptyCommand:
            return "There is no command to run in the session."
        case .serverNotRunning:
            return "The session host is not running."
        case .commandFailed(let command, let status, let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "The session host command `\(command)` failed (\(status))" + (detail.isEmpty ? "." : ": \(detail)")
        }
    }
}

// MARK: - Snapshot

/// A pane in the host: its tty, the session it belongs to, and whether its
/// command has exited.
public struct HostPane: Equatable, Sendable {
    /// Device name without `/dev/` (`ttys012`), the form `LiveSession.tty` has.
    public let tty: String
    public let pid: Int32?
    public let isDead: Bool
    public let sessionName: String

    public init(tty: String, pid: Int32?, isDead: Bool, sessionName: String) {
        self.tty = tty
        self.pid = pid
        self.isDead = isDead
        self.sessionName = sessionName
    }
}

/// A terminal attached to the host: the tab's tty and the session it shows.
public struct HostClient: Equatable, Sendable {
    /// Device name without `/dev/`.
    public let tty: String
    public let pid: Int32?
    public let sessionName: String

    public init(tty: String, pid: Int32?, sessionName: String) {
        self.tty = tty
        self.pid = pid
        self.sessionName = sessionName
    }
}

/// What the host holds at one moment: pane tty to session to client tty.
public struct HostSnapshot: Equatable, Sendable {
    public let panes: [HostPane]
    public let clients: [HostClient]

    public init(panes: [HostPane] = [], clients: [HostClient] = []) {
        self.panes = panes
        self.clients = clients
    }

    /// `ttys004` for `ttys004` or `/dev/ttys004`; nil for an empty string.
    /// The registry and the process table say `ttys004`, tmux says
    /// `/dev/ttys004`; everything here settles on the first.
    public static func normalizedTTY(_ tty: String?) -> String? {
        guard var name = tty?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if name.hasPrefix("/dev/") { name.removeFirst("/dev/".count) }
        return name.isEmpty ? nil : name
    }

    // MARK: Formats and parsing

    /// `|` separates fields: tmux may rewrite control characters in format
    /// output, and a session name is the last field so one containing the
    /// separator still survives.
    public static let paneFormat = "#{pane_tty}|#{pane_pid}|#{pane_dead}|#{session_name}"
    public static let clientFormat = "#{client_tty}|#{client_pid}|#{session_name}"

    /// Tolerant: a line that does not have its fields is dropped rather than
    /// failing the whole snapshot.
    public static func parsePanes(_ output: String) -> [HostPane] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "|", maxSplits: 3, omittingEmptySubsequences: false)
            guard fields.count == 4,
                  let tty = normalizedTTY(String(fields[0])),
                  !fields[3].isEmpty
            else { return nil }
            return HostPane(
                tty: tty,
                pid: Int32(fields[1]),
                isDead: fields[2] == "1",
                sessionName: String(fields[3])
            )
        }
    }

    public static func parseClients(_ output: String) -> [HostClient] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3,
                  let tty = normalizedTTY(String(fields[0])),
                  !fields[2].isEmpty
            else { return nil }
            return HostClient(tty: tty, pid: Int32(fields[1]), sessionName: String(fields[2]))
        }
    }

    // MARK: Questions

    /// Every session that has a pane, in first-seen order.
    public var sessionNames: [String] {
        var seen = Set<String>()
        return panes.map(\.sessionName).filter { seen.insert($0).inserted }
    }

    public func clientTTYs(for sessionName: String) -> [String] {
        clients.filter { $0.sessionName == sessionName }.map(\.tty)
    }

    /// The tty of a terminal showing the session, if any. A session shown by
    /// several (the user attached twice) answers the first; a window that was
    /// closed leaves none.
    public func clientTTY(for sessionName: String) -> String? {
        clientTTYs(for: sessionName).first
    }

    /// True for a session that exists and has no client attached: the
    /// Detached marker (R16). False for a session that is attached or that
    /// the host does not hold.
    public func isDetached(_ sessionName: String) -> Bool {
        sessionNames.contains(sessionName) && clientTTYs(for: sessionName).isEmpty
    }

    public var detachedSessions: [String] {
        sessionNames.filter { isDetached($0) }
    }

    /// The session whose live pane has this tty. Accepts either tty spelling.
    public func sessionName(forPaneTTY tty: String?) -> String? {
        guard let tty = Self.normalizedTTY(tty) else { return nil }
        return panes.first { !$0.isDead && $0.tty == tty }?.sessionName
    }

    /// The pure join (KTD7's pane-tty match): each registry row whose process
    /// has the tty of a live pane, mapped to the session that pane is in.
    /// Rows without a tty, or on one the host does not own, are absent.
    public func launchIDs(for sessions: [LiveSession]) -> [LiveSessionKey: String] {
        var result: [LiveSessionKey: String] = [:]
        for session in sessions {
            if let name = sessionName(forPaneTTY: session.tty) { result[session.key] = name }
        }
        return result
    }
}

// MARK: - Status

/// What the host's recorded history and its socket say together (R16, KTD5).
public enum HostStatus: Equatable, Sendable {
    /// No server was ever started from this directory.
    case neverStarted
    /// A server answers. Having no sessions is not a state of its own: with
    /// `exit-empty off` the server outlives its last session.
    case running
    /// No server answers, and AgentMenu recorded a `kill-server` first.
    case stoppedByAgentMenu
    /// No server answers although one was started and no kill was recorded:
    /// a crash, an OOM kill, a reboot. U14 turns this into the restore flow.
    case died

    public var isAbnormalDeath: Bool { self == .died }
}

// MARK: - Running processes

public struct HostRunResult: Equatable, Sendable {
    public var status: Int32
    public var stdout: String
    public var stderr: String

    public init(status: Int32 = 0, stdout: String = "", stderr: String = "") {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

// MARK: - The controller

/// Kit-level control of AgentMenu's own tmux server (KTD3, KTD4, KTD5, KTD18).
///
/// AgentMenu starts the server and every owned session itself; a terminal tab
/// only attaches. Every command carries `-S <host dir>/s` and `-f <host
/// dir>/tmux.conf`, so the user's own tmux (its default socket, its
/// `~/.tmux.conf`) is neither read nor disturbed (R17), and two different host
/// directories never share a server.
///
/// Process calls go through an injected `Runner` and the liveness check
/// through an injected `SocketProbe`, so tests supply both and no tmux is run.
/// Safe to call from any thread.
public final class SessionHost: @unchecked Sendable {
    /// Runs `executable` with `arguments` and exactly `environment` as its
    /// environment (not merged with the process's own), and returns what it
    /// printed. A non-zero status is a result, not a throw; a throw means the
    /// process could not be run at all.
    public typealias Runner = (_ executable: String, _ arguments: [String], _ environment: [String: String]) throws -> HostRunResult
    /// Whether something accepts connections on the socket.
    public typealias SocketProbe = (_ socket: URL) -> Bool

    /// Removed from the environment AgentMenu gives its server and every
    /// `new-session` (KTD18): a session that inherits
    /// `CLAUDE_CODE_CHILD_SESSION` neither registers nor persists, and the
    /// other three would make the agent believe it runs inside a tmux or a
    /// Claude Code session AgentMenu is not part of.
    public static let scrubbedEnvironmentNames = ["CLAUDE_CODE_CHILD_SESSION", "CLAUDECODE", "TMUX", "TMUX_PANE"]

    /// The shell that wraps an agent when `$SHELL` is unset.
    public static let fallbackShell = "/bin/zsh"

    public let location: SessionHostLocation
    /// `Contents/Helpers` of the running bundle; nil when there is none (the
    /// CLI), in which case the helper copies must already be in place.
    public let helpersDirectory: URL?

    private let shell: String
    private let baseEnvironment: [String: String]
    private let runner: Runner
    private let probe: SocketProbe
    private let lock = NSLock()
    private var contentsVerified = false

    public init(
        location: SessionHostLocation,
        helpersDirectory: URL?,
        shell: String? = ProcessInfo.processInfo.environment["SHELL"],
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
        runner: @escaping Runner = SessionHost.systemRunner(),
        socketProbe: @escaping SocketProbe = SessionHost.connectProbe
    ) {
        self.location = location
        self.helpersDirectory = helpersDirectory
        self.shell = Self.resolvedShell(shell)
        self.baseEnvironment = baseEnvironment
        self.runner = runner
        self.probe = socketProbe
    }

    /// The bundle's helper directory: `<app>/Contents/Helpers`.
    public static func bundledHelpersDirectory(bundleURL: URL) -> URL {
        bundleURL.appendingPathComponent("Contents/Helpers", isDirectory: true)
    }

    // MARK: Pure command building

    /// An absolute `$SHELL`, or `/bin/zsh`. A relative or empty value is not
    /// something to hand to tmux as an executable.
    static func resolvedShell(_ shell: String?) -> String {
        guard let shell, shell.hasPrefix("/") else { return fallbackShell }
        return shell
    }

    /// Letters, digits, `-` and `_`: what a launch id (a UUID) is made of.
    /// tmux rewrites `.` and `:` in a session name, and a name starting with
    /// `-` would read as a flag.
    static func isValidLaunchID(_ id: String) -> Bool {
        guard let first = id.unicodeScalars.first, first != "-", id.utf8.count <= 128 else { return false }
        return id.unicodeScalars.allSatisfy { scalar in
            scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "_")
        }
    }

    private static func isValidEnvironmentName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first,
              first.isASCII, CharacterSet.letters.contains(first) || first == "_"
        else { return false }
        return name.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_")
        }
    }

    /// `-S <socket> -f <config>` and then the tmux command. Every invocation
    /// is built here, so none can reach the default socket or the user's
    /// config.
    public func tmuxArguments(_ command: [String]) -> [String] {
        ["-S", location.socket.path, "-f", location.config.path] + command
    }

    /// The environment of every process AgentMenu starts for the host: the
    /// base environment minus the KTD18 names.
    public var serverEnvironment: [String: String] {
        baseEnvironment.filter { !Self.scrubbedEnvironmentNames.contains($0.key) }
    }

    /// `<shell> -l -i -c <command>` (KTD3): an interactive login shell, so
    /// the files a plain launch's shell sources (PATH, Homebrew, nvm,
    /// `SSH_AUTH_SOCK` often live only in `~/.zshrc`) are sourced here too.
    /// Passed to tmux as argv, not as one string, so tmux does not add a
    /// second shell of its own.
    public func wrappedCommand(_ command: String) -> [String] {
        [shell, "-l", "-i", "-c", command]
    }

    /// `new-session -d -s <id> -c <cwd> -e K=V … <shell> -l -i -c <command>`.
    /// `environment` is the session's own (for example `CLAUDE_CONFIG_DIR`),
    /// minus the KTD18 names, in a fixed order.
    public func newSessionArguments(
        launchID: String,
        command: String,
        environment: [String: String],
        cwd: String
    ) throws -> [String] {
        guard Self.isValidLaunchID(launchID) else { throw SessionHostError.invalidLaunchID(launchID) }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw SessionHostError.emptyCommand }
        var arguments = ["new-session", "-d", "-s", launchID]
        // tmux expands `-c` as a format (`#{…}`, `#(…)` runs a command), and a
        // folder name is the user's, not a template: `#` is doubled so it
        // reaches the shell as typed.
        if !cwd.isEmpty { arguments += ["-c", cwd.replacingOccurrences(of: "#", with: "##")] }
        for name in environment.keys.sorted() where !Self.scrubbedEnvironmentNames.contains(name) {
            guard Self.isValidEnvironmentName(name) else { throw SessionHostError.invalidEnvironmentName(name) }
            arguments += ["-e", "\(name)=\(environment[name]!)"]
        }
        return tmuxArguments(arguments + wrappedCommand(command))
    }

    /// The command line for a resolved launch: `exec '<binary>' '<arg>' …`.
    /// The working directory and environment travel separately (`-c`, `-e`),
    /// so neither is repeated here.
    public static func agentCommandLine(_ launch: LaunchCommand) -> String {
        "exec " + ([launch.executable] + launch.arguments).map(ShellQuoting.singleQuoted).joined(separator: " ")
    }

    /// The attach client's argv, run from the `tmux`-named copy (KTD2).
    public func attachArguments(launchID: String, style: HostAttachStyle = .plain) -> [String] {
        switch style {
        case .plain:
            return tmuxArguments(["attach-session", "-t", launchID])
        }
    }

    /// The attach command as one shell-quoted string for a terminal
    /// manifest's launch path, every token single-quoted the way
    /// `LaunchCommand.shellCommand` does. It does not change directory.
    public func attachCommand(launchID: String, style: HostAttachStyle = .plain) -> String {
        ([location.clientHelper.path] + attachArguments(launchID: launchID, style: style))
            .map(ShellQuoting.singleQuoted)
            .joined(separator: " ")
    }

    /// The attach client as a `LaunchCommand`, for the terminal manifests'
    /// launch path (`TerminalLauncher.open`): the `tmux`-named copy, no
    /// environment of its own, and the session's folder as its working
    /// directory (the shell command `cd`s there first, harmlessly).
    public func attachLaunchCommand(launchID: String, workingDirectory: String) -> LaunchCommand {
        LaunchCommand(
            executable: location.clientHelper.path,
            arguments: attachArguments(launchID: launchID),
            environment: [:],
            workingDirectory: workingDirectory
        )
    }

    /// The socket every command of this host carries.
    public var socketPath: String { location.socket.path }

    // MARK: Preparing the directory

    /// Creates the host directory, installs both helper copies and writes the
    /// config. Idempotent and cheap after the first call.
    ///
    /// A helper is replaced only when its bytes differ from the bundle's, and
    /// the server copy never while a server answers: a Sparkle update that
    /// ships a different tmux gets a new version directory, so a running
    /// server keeps the binary it started from.
    public func ensureHost() throws {
        lock.lock()
        defer { lock.unlock() }

        guard location.socketPathFits else {
            throw SessionHostError.socketPathTooLong(location.socket.path, location.socket.path.utf8.count)
        }
        let fm = FileManager.default
        try fm.createDirectory(
            at: location.directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        // The fallback lives in a world-writable directory, so every
        // directory this build owns on the way down — `.agentmenu-<uid>`,
        // the bundle hash and the version — must be this user's, or another
        // account could have pre-created one.
        var owned = [location.directory]
        if location.usesFallback {
            owned.append(location.directory.deletingLastPathComponent())
            owned.append(location.directory.deletingLastPathComponent().deletingLastPathComponent())
        }
        for directory in owned {
            let attributes = try fm.attributesOfItem(atPath: directory.path)
            if let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value, owner != UInt32(getuid()) {
                throw SessionHostError.directoryNotOwned(directory.path)
            }
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }

        for name in HostHelperNames.all {
            try installHelper(named: name, fileManager: fm)
        }
        contentsVerified = true

        let wanted = Data(HostConfig.contents.utf8)
        if (try? Data(contentsOf: location.config)) != wanted {
            try wanted.write(to: location.config, options: .atomic)
        }
    }

    private func installHelper(named name: String, fileManager fm: FileManager) throws {
        let destination = location.helper(named: name)
        guard let helpersDirectory else {
            // No bundle (the CLI): the copies are either there or the host
            // cannot start.
            guard fm.isExecutableFile(atPath: destination.path) else {
                throw SessionHostError.helperMissing(destination.path)
            }
            return
        }
        let source = helpersDirectory.appendingPathComponent(name)
        guard fm.fileExists(atPath: source.path) else { throw SessionHostError.helperMissing(source.path) }

        if fm.fileExists(atPath: destination.path) {
            let sourceSize = (try? fm.attributesOfItem(atPath: source.path))?[.size] as? NSNumber
            let destinationSize = (try? fm.attributesOfItem(atPath: destination.path))?[.size] as? NSNumber
            let same = sourceSize == destinationSize
                && (contentsVerified || fm.contentsEqual(atPath: source.path, andPath: destination.path))
            if same {
                if !fm.isExecutableFile(atPath: destination.path) {
                    try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: destination.path)
                }
                return
            }
            // Never replace the binary a running server executes.
            if name == HostHelperNames.server, probe(location.socket) { return }
        }

        let staging = location.directory.appendingPathComponent(".\(name).\(getpid()).new")
        try? fm.removeItem(at: staging)
        try fm.copyItem(at: source, to: staging)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
        // A copy of a quarantined download would be refused or prompted at
        // exec; the helper was already assessed with the app that carried it.
        _ = removexattr(staging.path, "com.apple.quarantine", 0)
        guard rename(staging.path, destination.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: staging)
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
    }

    // MARK: Running commands

    private func run(_ command: [String]) throws -> HostRunResult {
        try runner(location.serverHelper.path, tmuxArguments(command), serverEnvironment)
    }

    private func runChecked(_ command: [String]) throws -> HostRunResult {
        let result = try run(command)
        guard result.status == 0 else {
            throw SessionHostError.commandFailed(
                command: command.first ?? "", status: result.status, stderr: result.stderr
            )
        }
        return result
    }

    /// Starts the server without creating a session. With `exit-empty off` it
    /// stays up with none.
    public func startServer() throws {
        try ensureHost()
        _ = try runChecked(["start-server"])
        writeState(.running)
    }

    /// Creates a detached session (KTD3). Starts the server if it is not
    /// running, from the app-branded copy and the scrubbed environment.
    public func newSession(
        launchID: String,
        command: String,
        environment: [String: String],
        cwd: String
    ) throws {
        // Validate before touching the disk or the server.
        let arguments = try newSessionArguments(
            launchID: launchID, command: command, environment: environment, cwd: cwd
        )
        try ensureHost()
        let result = try runner(location.serverHelper.path, arguments, serverEnvironment)
        guard result.status == 0 else {
            throw SessionHostError.commandFailed(command: "new-session", status: result.status, stderr: result.stderr)
        }
        writeState(.running)
    }

    /// `newSession` for a resolved launch: its executable and arguments become
    /// the command, its environment the session's, its directory the cwd.
    public func newSession(launchID: String, launch: LaunchCommand) throws {
        try newSession(
            launchID: launchID,
            command: Self.agentCommandLine(launch),
            environment: launch.environment,
            cwd: launch.workingDirectory
        )
    }

    /// Kills one session. A session that is already gone is not an error.
    public func killSession(launchID: String) throws {
        guard Self.isValidLaunchID(launchID) else { throw SessionHostError.invalidLaunchID(launchID) }
        guard probe(location.socket) else { return }
        _ = try run(["kill-session", "-t", launchID])
    }

    /// The status `systemRunner` reports for a tmux command it gave up on after
    /// `exitTimeout`: the command may or may not have reached the server.
    public static let timedOutStatus: Int32 = -1

    /// Makes sure no session named `launchID` is left, and says whether that is
    /// certain. Only a `true` lets a caller start the same agent another way:
    /// a session this cannot rule out may yet be running it, and two processes
    /// on one session id corrupt its transcript.
    ///
    /// - Parameter failure: what `newSession` threw, or nil when the session
    ///   was created and is being taken back (a terminal that would not open).
    ///   An error from before tmux ran (a missing helper, a bad argument, a
    ///   process that could not be started) proves nothing was created. A
    ///   tmux command that failed or timed out proves nothing, so the server is
    ///   asked: `kill-session` either removes the session or says it cannot find
    ///   one, and anything else (a server that does not answer, a command that
    ///   timed out again) leaves it unconfirmed.
    public func ensureSessionAbsent(launchID: String, after failure: Error?) -> Bool {
        guard Self.isValidLaunchID(launchID) else { return true }
        var timedOut = false
        if let failure {
            guard case SessionHostError.commandFailed(_, let status, _) = failure else { return true }
            timedOut = status == Self.timedOutStatus
        }
        guard probe(location.socket) else {
            // Nothing answers. A tmux client that failed by itself left no
            // server to hold a session, and a server that is gone took its
            // sessions with it; one that was given up on may still be coming
            // up.
            return !timedOut
        }
        guard let result = try? run(["kill-session", "-t", launchID]) else { return false }
        if result.status == 0 { return true }
        return result.stderr.lowercased().contains("can't find session")
    }

    // MARK: Looking

    /// Pane tty to session, and client tty to session, now.
    ///
    /// Throws `serverNotRunning` when nothing answers on the socket, which a
    /// caller reads together with `status()` to tell a death from a host that
    /// was never started.
    public func snapshot() throws -> HostSnapshot {
        guard probe(location.socket) else { throw SessionHostError.serverNotRunning }
        let panes = try listing(["list-panes", "-a", "-F", HostSnapshot.paneFormat])
        let clients = try listing(["list-clients", "-F", HostSnapshot.clientFormat])
        return HostSnapshot(panes: HostSnapshot.parsePanes(panes), clients: HostSnapshot.parseClients(clients))
    }

    private func listing(_ command: [String]) throws -> String {
        let result = try run(command)
        if result.status == 0 { return result.stdout }
        // A live server with nothing in it can answer "no sessions" or "no
        // current …" with a failure status rather than an empty list.
        let message = result.stderr.lowercased()
        if probe(location.socket), message.contains("no sessions") || message.contains("no current") { return "" }
        if !probe(location.socket) { throw SessionHostError.serverNotRunning }
        throw SessionHostError.commandFailed(command: command[0], status: result.status, stderr: result.stderr)
    }

    /// Whether a server accepts connections on the socket. Does not start one.
    public func isServerAlive() -> Bool {
        probe(location.socket)
    }

    // MARK: Death

    private enum Recorded: String {
        case running
        case stopped
    }

    private func readState() -> Recorded? {
        guard let text = try? String(contentsOf: location.stateFile, encoding: .utf8) else { return nil }
        return Recorded(rawValue: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func writeState(_ state: Recorded) {
        // Best effort: a host whose directory cannot take a one-word file
        // could not have started either.
        try? Data((state.rawValue + "\n").utf8).write(to: location.stateFile, options: .atomic)
    }

    /// Whether the host is up, was stopped by AgentMenu, never started, or
    /// died (KTD5: with `exit-empty off`, a missing server is abnormal unless
    /// a `kill-server` was recorded first). Reads a file and probes a socket;
    /// no tmux runs.
    public func status() -> HostStatus {
        let recorded = readState()
        if probe(location.socket) { return .running }
        switch recorded {
        case .none: return .neverStarted
        case .stopped: return .stoppedByAgentMenu
        case .running: return .died
        }
    }

    /// Writes down that AgentMenu is about to stop the server, so its
    /// disappearance is not read as a death. Called before `kill-server`
    /// (`killServer()` does both), and persisted so a relaunch after a crash
    /// in between still knows.
    public func recordKillServer() {
        writeState(.stopped)
    }

    /// Forgets the record, so a `died` status is reported once: U14 calls this
    /// after it has handled the death.
    public func clearRecord() {
        try? FileManager.default.removeItem(at: location.stateFile)
    }

    /// Records the intent, then runs `kill-server`. Safe when no server runs.
    public func killServer() throws {
        recordKillServer()
        guard probe(location.socket) else { return }
        _ = try run(["kill-server"])
    }

    // MARK: Real process and socket

    /// Runs the process for real and waits for it. tmux daemonises its server
    /// and releases the pipes, so waiting for exit and then reading is safe.
    public static func systemRunner(exitTimeout: TimeInterval = 20.0) -> Runner {
        { executable, arguments, environment in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.environment = environment
            process.standardInput = FileHandle.nullDevice
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            try process.run()
            guard exited.wait(timeout: .now() + exitTimeout) == .success else {
                process.terminate()
                return HostRunResult(
                    status: SessionHost.timedOutStatus, stdout: "", stderr: "timed out after \(Int(exitTimeout)) seconds"
                )
            }
            let out = stdout.fileHandleForReading.readDataToEndOfFile()
            let err = stderr.fileHandleForReading.readDataToEndOfFile()
            return HostRunResult(
                status: process.terminationStatus,
                stdout: String(data: out, encoding: .utf8) ?? "",
                stderr: String(data: err, encoding: .utf8) ?? ""
            )
        }
    }

    /// A server is alive when something accepts a connection on its socket. A
    /// leftover socket file from a dead server refuses it.
    public static func connectProbe(_ socketURL: URL) -> Bool {
        let path = socketURL.path
        guard path.utf8.count <= SessionHostLocation.maximumSocketPathBytes else { return false }
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(descriptor, $0, length) }
        }
        return result == 0
    }
}


// MARK: - What the launch path needs of a host

/// The slice of `SessionHost` the owned launch path and the Sessions model
/// use, so a test substitutes a recording host and no tmux runs.
public protocol SessionHosting: AnyObject, Sendable {
    var socketPath: String { get }
    func ensureHost() throws
    func newSession(launchID: String, launch: LaunchCommand) throws
    func killSession(launchID: String) throws
    /// Removes the session and says whether it is certain none is left; see
    /// `SessionHost.ensureSessionAbsent`.
    func ensureSessionAbsent(launchID: String, after failure: Error?) -> Bool
    func attachLaunchCommand(launchID: String, workingDirectory: String) -> LaunchCommand
    func snapshot() throws -> HostSnapshot
    func isServerAlive() -> Bool
    /// Up, stopped by AgentMenu, never started, or died (`SessionHost.status`).
    func status() -> HostStatus
    /// Forgets the recorded state once a death has been handled, so it is not
    /// read again as a new one (U14). A host with no record has nothing to do.
    func clearRecord()
}

extension SessionHosting {
    /// A host with no record of its own reads as never started, which is
    /// never a death.
    public func status() -> HostStatus { .neverStarted }
    public func clearRecord() {}
}

extension SessionHost: SessionHosting {}
