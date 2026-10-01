// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

// The session host controller (U9): command building, environment, parsing,
// death detection, the helper copy, and one integration case against a real
// tmux that skips itself when none is present. Everything except that case
// runs through a recording runner and a stubbed socket probe, so no tmux is
// started and nothing here can reach a tmux the maintainer runs.

private struct HostCall {
    let executable: String
    let arguments: [String]
    let environment: [String: String]
}

/// Records every call and answers from a closure.
private final class RecordingRunner: @unchecked Sendable {
    private(set) var calls: [HostCall] = []
    var respond: ([String]) -> HostRunResult = { _ in HostRunResult() }

    var runner: SessionHost.Runner {
        { [self] executable, arguments, environment in
            calls.append(HostCall(executable: executable, arguments: arguments, environment: environment))
            return respond(arguments)
        }
    }

    func reset() { calls.removeAll() }

    /// The tmux command with the leading `-S <s> -f <f>` removed.
    func commands() -> [[String]] { calls.map { Array($0.arguments.dropFirst(4)) } }
}

private final class FlagBox: @unchecked Sendable {
    var value: Bool
    init(_ value: Bool) { self.value = value }
}

/// A short temp directory: a socket path is limited to 103 bytes, and
/// `TempDir`'s labels plus a full UUID would crowd it.
private func shortTempDir() -> TempDir {
    let dir = TempDir("amh")
    return dir
}

private func shortHostDir(_ base: TempDir, _ name: String = "h") -> URL {
    base.url.appendingPathComponent(name, isDirectory: true)
}

private func makeHost(
    _ directory: URL,
    runner: RecordingRunner,
    alive: FlagBox = FlagBox(false),
    shell: String? = "/bin/bash",
    environment: [String: String] = ["PATH": "/usr/bin:/bin", "HOME": "/Users/test"],
    helpers: URL? = nil
) -> SessionHost {
    SessionHost(
        location: SessionHostLocation(directory: directory),
        helpersDirectory: helpers,
        shell: shell,
        baseEnvironment: environment,
        runner: runner.runner,
        socketProbe: { _ in alive.value }
    )
}

private func liveRow(pid: Int32, tty: String?) -> LiveSession {
    LiveSession(
        key: LiveSessionKey(configDirectory: "/profiles/work", pid: pid, procStart: 1_790_000_000 + Int(pid)),
        agentID: RegistryReader.claudeAgentID,
        agentDisplayName: "Claude Code",
        pid: pid,
        status: .yourTurn,
        tty: tty,
        startedAt: Date(timeIntervalSince1970: 1_790_000_000)
    )
}

/// Writes an executable file whose contents are `text`.
private func writeExecutable(_ text: String, to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(text.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

/// A tmux to run the integration case against: `AGENTMENU_TEST_TMUX`, the
/// binary U8's build leaves in `.build/tmux/<key>/tmux`, or a Homebrew one.
/// The case uses it only with `-S` and `-f` under a temp directory.
private func integrationTmux() -> String? {
    let fm = FileManager.default
    var candidates: [String] = []
    if let explicit = ProcessInfo.processInfo.environment["AGENTMENU_TEST_TMUX"], !explicit.isEmpty {
        candidates.append(explicit)
    }
    let cache = repositoryRoot().appendingPathComponent(".build/tmux", isDirectory: true)
    // Newest build first: the cache keeps an older key's binary after the
    // sources change, and the newest is the one `make bundle` would embed.
    let built = ((try? fm.contentsOfDirectory(atPath: cache.path)) ?? [])
        .map { cache.appendingPathComponent($0).appendingPathComponent("tmux").path }
        .filter { fm.isExecutableFile(atPath: $0) }
        .sorted {
            let first = (try? fm.attributesOfItem(atPath: $0))?[.modificationDate] as? Date ?? .distantPast
            let second = (try? fm.attributesOfItem(atPath: $1))?[.modificationDate] as? Date ?? .distantPast
            return first > second
        }
    candidates += built
    candidates += ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux"]
    return candidates.first { fm.isExecutableFile(atPath: $0) }
}

func runSessionHostTests(_ t: TestRunner) {
    t.suite("SessionHost")

    // MARK: Location (KTD4)

    do {
        let home = URL(fileURLWithPath: "/Users/someone", isDirectory: true)
        guard let release = t.attempt("the primary location resolves", {
            try SessionHostLocation.resolve(bundleIdentifier: "dev.facens.agentmenu", home: home, userID: 501)
        }), let beta = t.attempt("a beta bundle id resolves", {
            try SessionHostLocation.resolve(bundleIdentifier: "dev.facens.agentmenu.beta", home: home, userID: 501)
        }) else { return }
        t.expectEqual(
            release.directory.path,
            "/Users/someone/Library/Application Support/dev.facens.agentmenu/host/3.7c",
            "the host directory is Application Support / bundle id / host / tmux version"
        )
        t.expectEqual(release.socket.path, release.directory.path + "/s", "the socket is `s` inside the host directory")
        t.expect(!release.usesFallback, "a normal home uses the primary location")
        t.expect(release.socketPathFits, "the primary socket path fits sockaddr_un")
        t.expect(release.directory != beta.directory, "a release and a beta build get different host directories")
        t.expect(!release.directory.path.hasPrefix("/tmp") && !release.directory.path.hasPrefix("/private/tmp"), "the host is never under /tmp")
        let other = try? SessionHostLocation.resolve(
            bundleIdentifier: "dev.facens.agentmenu", helperVersion: "3.8a", home: home, userID: 501
        )
        t.expect(other?.directory != release.directory, "a different tmux version gets a different directory, so an update never strands a running server")
        let unnamed = try? SessionHostLocation.resolve(bundleIdentifier: nil, home: home, userID: 501)
        t.expectEqual(unnamed?.directory, release.directory, "no bundle id (the CLI) meets the app's directory")
    }

    do {
        let longHome = URL(fileURLWithPath: "/Users/" + String(repeating: "a-very-long-account-name-", count: 5), isDirectory: true)
        let first = try? SessionHostLocation.resolve(bundleIdentifier: "dev.facens.agentmenu", home: longHome, userID: 501)
        let second = try? SessionHostLocation.resolve(bundleIdentifier: "dev.facens.agentmenu.beta", home: longHome, userID: 501)
        t.expect(first?.usesFallback == true, "a home too long for a socket path falls back")
        t.expect((first?.socket.path.utf8.count ?? 999) < 104, "the fallback socket path is under 104 bytes")
        t.expectEqual(
            first?.directory.path.hasPrefix("/Users/Shared/.agentmenu-501/"), true,
            "the fallback is /Users/Shared/.agentmenu-<uid>/<bundle hash>/<version>, not /tmp"
        )
        t.expect(first?.directory != second?.directory, "the fallback is still per bundle id")
        t.expect(first?.directory.lastPathComponent == "3.7c", "the fallback is still per tmux version")
    }

    do {
        let override = URL(fileURLWithPath: "/tmp/h1", isDirectory: true)
        t.expectEqual(
            (try? SessionHostLocation.resolve(override: override, bundleIdentifier: "x"))?.directory, override,
            "an override directory is used exactly as given"
        )
        let long = URL(fileURLWithPath: "/tmp/" + String(repeating: "d", count: 120), isDirectory: true)
        t.expectThrows("an override too long for a socket is refused, not silently replaced") {
            try SessionHostLocation.resolve(override: long, bundleIdentifier: "x")
        }
    }

    // MARK: Commands always carry -S and -f, never the default socket

    do {
        let scratch = shortTempDir()
        defer { scratch.cleanup() }
        let dir = shortHostDir(scratch)
        let runner = RecordingRunner()
        let alive = FlagBox(true)
        let host = makeHost(dir, runner: runner, alive: alive)
        // ensureHost needs helpers on disk; pre-place both so no bundle is needed.
        for name in HostHelperNames.all { try? writeExecutable("#!/bin/sh\n", to: dir.appendingPathComponent(name)) }

        _ = try? host.snapshot()
        try? host.newSession(launchID: "abc-123", command: "exec claude", environment: [:], cwd: "/tmp")
        try? host.killSession(launchID: "abc-123")
        try? host.killServer()
        try? host.startServer()

        t.expect(runner.calls.count >= 5, "every operation ran a command (\(runner.calls.count))")
        let expectedPrefix = ["-S", dir.appendingPathComponent("s").path, "-f", dir.appendingPathComponent("tmux.conf").path]
        for call in runner.calls {
            t.expectEqual(Array(call.arguments.prefix(4)), expectedPrefix, "\(call.arguments.dropFirst(4).first ?? "?") carries -S <override dir>/s and -f <config>")
            t.expect(!call.arguments.contains("-L"), "no command names a socket by label")
            t.expectEqual(call.executable, dir.appendingPathComponent(HostHelperNames.server).path, "control commands run from the app-branded copy")
        }
        t.expectEqual(host.tmuxArguments(["list-sessions"]), expectedPrefix + ["list-sessions"], "tmuxArguments puts -S and -f first")
    }

    // MARK: Two override directories never share a server

    do {
        let scratch = shortTempDir()
        defer { scratch.cleanup() }
        let runnerA = RecordingRunner()
        let runnerB = RecordingRunner()
        let a = makeHost(shortHostDir(scratch, "a"), runner: runnerA)
        let b = makeHost(shortHostDir(scratch, "b"), runner: runnerB)
        t.expect(a.location.socket != b.location.socket, "two host directories have two sockets")
        t.expect(a.tmuxArguments(["x"]) != b.tmuxArguments(["x"]), "so their commands name different servers")
        t.expect(a.attachCommand(launchID: "s1") != b.attachCommand(launchID: "s1"), "and their attach commands do too")
    }

    // MARK: new-session: -e environment, scrubbing, the login-shell wrapper

    do {
        let scratch = shortTempDir()
        defer { scratch.cleanup() }
        let dir = shortHostDir(scratch)
        let runner = RecordingRunner()
        let base = [
            "PATH": "/usr/bin:/bin", "HOME": "/Users/test",
            "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDECODE": "1",
            "TMUX": "/private/tmp/tmux-501/default,1,0", "TMUX_PANE": "%3",
        ]
        let host = makeHost(dir, runner: runner, shell: "/bin/zsh", environment: base)
        for name in HostHelperNames.all { try? writeExecutable("#!/bin/sh\n", to: dir.appendingPathComponent(name)) }

        t.expectNoThrow("a session is created") {
            try host.newSession(
                launchID: "7a3f0c1e-1111-4222-8333-444455556666",
                command: "exec '/usr/local/bin/claude' '--session-id' 'x'",
                environment: [
                    "CLAUDE_CONFIG_DIR": "/Users/test/.claude-work",
                    "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDECODE": "1", "TMUX": "x", "TMUX_PANE": "%9",
                ],
                cwd: "/Users/test/project"
            )
        }
        guard let call = runner.calls.last else { t.expect(false, "new-session ran"); return }
        let args = call.arguments
        t.expect(args.contains("new-session") && args.contains("-d"), "new-session is detached")
        if let index = args.firstIndex(of: "-s") { t.expectEqual(args[index + 1], "7a3f0c1e-1111-4222-8333-444455556666", "the session is named by the launch id") }
        else { t.expect(false, "-s is present") }
        if let index = args.firstIndex(of: "-c") { t.expectEqual(args[index + 1], "/Users/test/project", "the working directory is -c") }
        else { t.expect(false, "-c is present") }

        var passed: [String] = []
        for (index, value) in args.enumerated() where value == "-e" && index + 1 < args.count { passed.append(args[index + 1]) }
        t.expectEqual(passed, ["CLAUDE_CONFIG_DIR=/Users/test/.claude-work"], "the profile's CLAUDE_CONFIG_DIR travels by -e, and nothing scrubbed does")
        for name in SessionHost.scrubbedEnvironmentNames {
            t.expect(!args.contains { $0.hasPrefix(name + "=") }, "\(name) is not passed to new-session")
            t.expect(call.environment[name] == nil, "\(name) is not in the environment the server is started with")
        }
        t.expectEqual(call.environment["PATH"], "/usr/bin:/bin", "the rest of the environment is kept")
        t.expectEqual(
            Array(args.suffix(5)),
            ["/bin/zsh", "-l", "-i", "-c", "exec '/usr/local/bin/claude' '--session-id' 'x'"],
            "the agent command is wrapped as an interactive login shell of $SHELL, as argv"
        )
        t.expectEqual(SessionHost.scrubbedEnvironmentNames.sorted(), ["CLAUDECODE", "CLAUDE_CODE_CHILD_SESSION", "TMUX", "TMUX_PANE"], "KTD18's four names")
    }

    do {
        let runner = RecordingRunner()
        let scratch = shortTempDir()
        defer { scratch.cleanup() }
        let dir = shortHostDir(scratch)
        let unset = makeHost(dir, runner: runner, shell: nil)
        t.expectEqual(unset.wrappedCommand("echo hi"), ["/bin/zsh", "-l", "-i", "-c", "echo hi"], "an unset $SHELL falls back to /bin/zsh")
        let empty = makeHost(dir, runner: runner, shell: "")
        t.expectEqual(empty.wrappedCommand("echo hi").first, "/bin/zsh", "an empty $SHELL falls back to /bin/zsh")
        let relative = makeHost(dir, runner: runner, shell: "zsh")
        t.expectEqual(relative.wrappedCommand("echo hi").first, "/bin/zsh", "a relative $SHELL is not trusted")
        let fish = makeHost(dir, runner: runner, shell: "/opt/homebrew/bin/fish")
        t.expectEqual(fish.wrappedCommand("echo hi").first, "/opt/homebrew/bin/fish", "the user's own shell is used")

        t.expectThrows("a launch id that could read as a flag is refused") {
            try unset.newSessionArguments(launchID: "-t", command: "x", environment: [:], cwd: "/")
        }
        t.expectThrows("a launch id with a dot or colon, which tmux would rewrite, is refused") {
            try unset.newSessionArguments(launchID: "a.b:c", command: "x", environment: [:], cwd: "/")
        }
        t.expectThrows("an invalid environment variable name is refused") {
            try unset.newSessionArguments(launchID: "ok", command: "x", environment: ["A=B": "1"], cwd: "/")
        }
        t.expectThrows("an empty command is refused") {
            try unset.newSessionArguments(launchID: "ok", command: "  ", environment: [:], cwd: "/")
        }
        t.expect(runner.calls.isEmpty, "none of that ran a process")

        let launch = LaunchCommand(
            executable: "/Users/test/.local/bin/claude", arguments: ["--session-id", "it's"],
            environment: ["CLAUDE_CONFIG_DIR": "/c"], workingDirectory: "/work"
        )
        t.expectEqual(
            SessionHost.agentCommandLine(launch),
            "exec '/Users/test/.local/bin/claude' '--session-id' 'it'\\''s'",
            "a resolved launch becomes an exec line, every token single-quoted"
        )
    }

    // MARK: The working directory is passed to tmux as typed, not as a format

    do {
        // tmux expands `-c` as a format: `#{…}` is a variable and `#(…)` runs a
        // command. A folder is the user's, so `#` is doubled.
        let scratch = shortTempDir()
        defer { scratch.cleanup() }
        let host = makeHost(shortHostDir(scratch), runner: RecordingRunner())
        func cwdArgument(_ cwd: String) -> String? {
            guard let args = try? host.newSessionArguments(launchID: "abc-123", command: "exec x", environment: [:], cwd: cwd),
                  let index = args.firstIndex(of: "-c")
            else { return nil }
            return args[index + 1]
        }
        t.expectEqual(
            cwdArgument("/Users/test/#{pane_pid}/#(touch pwned)/#"),
            "/Users/test/##{pane_pid}/##(touch pwned)/##",
            "a folder with #{ and #( reaches tmux with every # doubled"
        )
        t.expectEqual(cwdArgument("/Users/test/project"), "/Users/test/project", "an ordinary folder is untouched")
        t.expectEqual(cwdArgument("/Users/test/a b"), "/Users/test/a b", "spaces are not a format")
    }

    // MARK: A session is confirmed absent before the agent is started another way

    do {
        let scratch = shortTempDir()
        defer { scratch.cleanup() }
        let launch = "7a3f0c1e-1111-4222-8333-444455556666"
        let timedOut = SessionHostError.commandFailed(
            command: "new-session", status: SessionHost.timedOutStatus, stderr: "timed out after 20 seconds"
        )
        let refused = SessionHostError.commandFailed(command: "new-session", status: 1, stderr: "server exited unexpectedly")

        // An error from before tmux ran proves nothing was created.
        do {
            let runner = RecordingRunner()
            let host = makeHost(shortHostDir(scratch, "a"), runner: runner, alive: FlagBox(false))
            t.expect(host.ensureSessionAbsent(launchID: launch, after: SessionHostError.helperMissing("/x")), "a missing helper means nothing was created")
            t.expect(host.ensureSessionAbsent(launchID: launch, after: NSError(domain: NSPOSIXErrorDomain, code: 2)), "a process that could not be run created nothing")
            t.expect(runner.calls.isEmpty, "…and nothing is asked of the host")
        }
        // A timed-out command with no server answering is unknown, not absent.
        do {
            let runner = RecordingRunner()
            let host = makeHost(shortHostDir(scratch, "b"), runner: runner, alive: FlagBox(false))
            t.expect(!host.ensureSessionAbsent(launchID: launch, after: timedOut), "a timeout with no server answering may still be starting one")
            t.expect(host.ensureSessionAbsent(launchID: launch, after: refused), "a tmux client that failed by itself with no server answering left nothing")
            t.expect(host.ensureSessionAbsent(launchID: launch, after: nil), "a server that is gone took its session with it")
        }
        // A server that answers is asked, and its word decides.
        do {
            let runner = RecordingRunner()
            let host = makeHost(shortHostDir(scratch, "c"), runner: runner, alive: FlagBox(true))

            runner.respond = { _ in HostRunResult() }
            t.expect(host.ensureSessionAbsent(launchID: launch, after: timedOut), "a session that kill-session removed is gone")
            t.expectEqual(runner.commands().last, ["kill-session", "-t", launch], "the host is asked to remove it by name")

            runner.respond = { _ in HostRunResult(status: 1, stderr: "can't find session: \(launch)") }
            t.expect(host.ensureSessionAbsent(launchID: launch, after: timedOut), "a server that cannot find it confirms it is absent")

            runner.respond = { _ in HostRunResult(status: SessionHost.timedOutStatus, stderr: "timed out after 20 seconds") }
            t.expect(!host.ensureSessionAbsent(launchID: launch, after: timedOut), "a kill that times out too confirms nothing")

            runner.respond = { _ in HostRunResult(status: 1, stderr: "something else went wrong") }
            t.expect(!host.ensureSessionAbsent(launchID: launch, after: refused), "any other failure confirms nothing")
        }
    }

    // MARK: The packaging scripts and the code agree on what the host ships

    do {
        let root = repositoryRoot()

        // `packaging/bundle.sh` copies the helpers by name; the Swift side
        // installs and looks for the same two.
        let bundle = root.appendingPathComponent("packaging/bundle.sh")
        if let text = try? String(contentsOf: bundle, encoding: .utf8) {
            let declared = text.split(separator: "\n").lazy
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { $0.hasPrefix("HELPER_NAMES=(") }
            if let declared, let close = declared.firstIndex(of: ")") {
                let inside = declared[declared.index(declared.startIndex, offsetBy: "HELPER_NAMES=(".count)..<close]
                var names: [String] = []
                var current = ""
                var quoted = false
                for character in inside {
                    if character == "\"" {
                        if quoted { names.append(current); current = "" }
                        quoted.toggle()
                    } else if quoted {
                        current.append(character)
                    }
                }
                t.expect(!names.isEmpty, "HELPER_NAMES in packaging/bundle.sh was parsed")
                t.expectEqual(Set(names), Set(HostHelperNames.all), "bundle.sh ships exactly the helpers HostHelperNames installs")
                t.expectEqual(names.count, Set(names).count, "and lists none twice")
            } else {
                t.expect(false, "packaging/bundle.sh declares HELPER_NAMES=(...) on one line")
            }
        } else {
            t.expect(false, "packaging/bundle.sh is readable")
        }

        // The host directory is named by the tmux version the bundle ships, and
        // the pinned sources decide that version.
        let sources = root.appendingPathComponent("packaging/tmux/sources.sha256")
        if let text = try? String(contentsOf: sources, encoding: .utf8) {
            var versions: [String] = []
            for line in text.split(separator: "\n") where !line.hasPrefix("#") {
                let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
                guard fields.count >= 2, fields[1].hasPrefix("tmux-") else { continue }
                var version = String(fields[1].dropFirst("tmux-".count))
                for suffix in [".tar.gz", ".tar.xz", ".tar.bz2", ".tgz"] where version.hasSuffix(suffix) {
                    version.removeLast(suffix.count)
                }
                versions.append(version)
            }
            t.expectEqual(versions.count, 1, "packaging/tmux/sources.sha256 pins exactly one tmux source")
            t.expectEqual(
                versions.first, SessionHostLocation.defaultHelperVersion,
                "the host directory's version is the tmux version the bundle pins"
            )
        } else {
            t.expect(false, "packaging/tmux/sources.sha256 is readable")
        }
    }

    // MARK: Attach command

    do {
        let scratch = shortTempDir()
        defer { scratch.cleanup() }
        let dir = shortHostDir(scratch, "with space")
        let host = makeHost(dir, runner: RecordingRunner())
        let command = host.attachCommand(launchID: "abc-123")
        let sock = dir.appendingPathComponent("s").path
        let conf = dir.appendingPathComponent("tmux.conf").path
        t.expectEqual(
            command,
            "'\(dir.path)/tmux' '-S' '\(sock)' '-f' '\(conf)' 'attach-session' '-t' 'abc-123'",
            "attach is one single-quoted command: the tmux-named copy, -S, -f, attach-session -t <launch id>"
        )
        t.expect(command.contains("/tmux'"), "the client runs under the name tmux")
        t.expect(!command.contains(HostHelperNames.server), "the client does not run under the server's name")
        t.expectEqual(host.attachCommand(launchID: "abc-123", style: .plain), command, "plain is the default and only style")
    }

    // MARK: Parsing, detached, join

    do {
        let panes = HostSnapshot.parsePanes("""
        /dev/ttys012|4242|0|aaaa-1
        /dev/ttys013|4300|0|bbbb-2
        /dev/ttys014|4400|1|cccc-3
        garbage line
        |1|0|nameless-tty
        """)
        t.expectEqual(
            panes,
            [
                HostPane(tty: "ttys012", pid: 4242, isDead: false, sessionName: "aaaa-1"),
                HostPane(tty: "ttys013", pid: 4300, isDead: false, sessionName: "bbbb-2"),
                HostPane(tty: "ttys014", pid: 4400, isDead: true, sessionName: "cccc-3"),
            ],
            "list-panes output parses; malformed lines are dropped and the tty loses /dev/"
        )
        let clients = HostSnapshot.parseClients("/dev/ttys007|9001|aaaa-1\n/dev/ttys008|9002|aaaa-1\nbroken\n")
        t.expectEqual(
            clients,
            [HostClient(tty: "ttys007", pid: 9001, sessionName: "aaaa-1"), HostClient(tty: "ttys008", pid: 9002, sessionName: "aaaa-1")],
            "list-clients output parses"
        )
        let snapshot = HostSnapshot(panes: panes, clients: clients)
        t.expectEqual(snapshot.sessionNames, ["aaaa-1", "bbbb-2", "cccc-3"], "sessions in first-seen order")
        t.expectEqual(snapshot.clientTTYs(for: "aaaa-1"), ["ttys007", "ttys008"], "a session's client ttys")
        t.expectEqual(snapshot.clientTTY(for: "aaaa-1"), "ttys007", "the first client is the tab to focus")
        t.expect(!snapshot.isDetached("aaaa-1"), "a session with a client is attached")
        t.expect(snapshot.isDetached("bbbb-2"), "a session with no client is reported detached")
        t.expect(!snapshot.isDetached("missing"), "a session the host does not hold is not 'detached'")
        t.expectEqual(snapshot.detachedSessions, ["bbbb-2", "cccc-3"], "detachedSessions lists them")
        t.expectEqual(snapshot.clientTTY(for: "bbbb-2"), nil, "a detached session has no client tty")

        t.expectEqual(HostSnapshot.normalizedTTY("/dev/ttys004"), "ttys004", "tmux's /dev/ttys004 normalises")
        t.expectEqual(HostSnapshot.normalizedTTY("ttys004"), "ttys004", "the registry's ttys004 is already normal")
        t.expectEqual(HostSnapshot.normalizedTTY(" /dev/ttys004\n"), "ttys004", "whitespace is ignored")
        t.expectEqual(HostSnapshot.normalizedTTY(""), nil, "empty is no tty")

        // A session name that contains the separator survives, being last.
        t.expectEqual(HostSnapshot.parsePanes("/dev/ttys1|5|0|a|b").first?.sessionName, "a|b", "a separator inside the session name is kept")
        t.expect(HostSnapshot.parsePanes("").isEmpty && HostSnapshot.parseClients("").isEmpty, "empty output is an empty list")
    }

    do {
        let snapshot = HostSnapshot(
            panes: [
                HostPane(tty: "ttys012", pid: 1, isDead: false, sessionName: "aaaa-1"),
                HostPane(tty: "ttys013", pid: 2, isDead: true, sessionName: "dead-2"),
            ],
            clients: []
        )
        let hosted = liveRow(pid: 4242, tty: "ttys012")
        let slashForm = liveRow(pid: 4243, tty: "/dev/ttys012")
        let foreign = liveRow(pid: 5000, tty: "ttys099")
        let noTTY = liveRow(pid: 5001, tty: nil)
        let onDeadPane = liveRow(pid: 5002, tty: "ttys013")
        let joined = snapshot.launchIDs(for: [hosted, slashForm, foreign, noTTY, onDeadPane])
        t.expectEqual(joined[hosted.key], "aaaa-1", "a registry row whose tty is a pane's tty joins to that pane's session")
        t.expectEqual(joined[slashForm.key], "aaaa-1", "either tty spelling joins")
        t.expect(joined[foreign.key] == nil, "a row on a tty the host does not own does not join")
        t.expect(joined[noTTY.key] == nil, "a row with no tty does not join")
        t.expect(joined[onDeadPane.key] == nil, "a dead pane is not a live process to join")
        t.expectEqual(joined.count, 2, "only the two matching rows joined")
        t.expectEqual(snapshot.sessionName(forPaneTTY: "/dev/ttys012"), "aaaa-1", "lookup by raw tmux tty")
    }

    // MARK: snapshot() through the runner

    do {
        let scratch = shortTempDir()
        defer { scratch.cleanup() }
        let runner = RecordingRunner()
        let alive = FlagBox(true)
        runner.respond = { arguments in
            if arguments.contains("list-panes") { return HostRunResult(stdout: "/dev/ttys012|4242|0|aaaa-1\n") }
            if arguments.contains("list-clients") { return HostRunResult(stdout: "/dev/ttys007|9001|aaaa-1\n") }
            return HostRunResult()
        }
        let host = makeHost(shortHostDir(scratch), runner: runner, alive: alive)
        if let snapshot = t.attempt("snapshot reads panes and clients", { try host.snapshot() }) {
            t.expectEqual(snapshot.panes.count, 1, "one pane")
            t.expectEqual(snapshot.clientTTY(for: "aaaa-1"), "ttys007", "pane, session and client tty line up")
        }
        t.expectEqual(
            runner.commands(),
            [["list-panes", "-a", "-F", HostSnapshot.paneFormat], ["list-clients", "-F", HostSnapshot.clientFormat]],
            "snapshot asks list-panes -a -F and list-clients -F"
        )

        alive.value = false
        t.expectThrows("snapshot with no server throws instead of reporting an empty host") { try host.snapshot() }
    }

    // MARK: Death detection and kill-server recording

    do {
        let scratch = shortTempDir()
        defer { scratch.cleanup() }
        let dir = shortHostDir(scratch)
        let runner = RecordingRunner()
        let alive = FlagBox(false)
        let host = makeHost(dir, runner: runner, alive: alive)
        for name in HostHelperNames.all { try? writeExecutable("#!/bin/sh\n", to: dir.appendingPathComponent(name)) }

        t.expectEqual(host.status(), .neverStarted, "a directory nothing ever started a server in has not lost one")
        t.expect(!host.status().isAbnormalDeath, "never started is not a death")

        t.expectNoThrow("a session starts the server") {
            try host.newSession(launchID: "only-1", command: "exec sleep 1", environment: [:], cwd: "/tmp")
        }
        alive.value = true
        t.expectEqual(host.status(), .running, "a server that answers is running")

        // Ending the last session: the server stays, so nothing died.
        // Real tmux 3.7c: list-panes -a and list-clients fail like this on an empty server.
        runner.respond = { _ in HostRunResult(status: 1, stderr: "no current target\n") }
        if let snapshot = t.attempt("a live server with no sessions snapshots as empty", { try host.snapshot() }) {
            t.expect(snapshot.panes.isEmpty && snapshot.clients.isEmpty, "no panes, no clients")
        }
        t.expectEqual(host.status(), .running, "ending the last session leaves the server running")
        t.expect(!host.status().isAbnormalDeath, "and reports no host death")

        // The server vanishes with no kill recorded.
        alive.value = false
        t.expectEqual(host.status(), .died, "a vanished server with no recorded kill is an abnormal death")
        t.expect(host.status().isAbnormalDeath, "isAbnormalDeath says so")

        // The record outlives the process: a second controller on the same directory sees it.
        let relaunched = makeHost(dir, runner: RecordingRunner(), alive: alive)
        t.expectEqual(relaunched.status(), .died, "a relaunched AgentMenu still sees the death")
        relaunched.clearRecord()
        t.expectEqual(relaunched.status(), .neverStarted, "after the death is handled the record is gone")

        // A recorded kill-server is not a death.
        alive.value = true
        runner.respond = { _ in HostRunResult() }
        t.expectNoThrow("a session starts a server again") {
            try host.newSession(launchID: "again-1", command: "exec sleep 1", environment: [:], cwd: "/tmp")
        }
        runner.reset()
        t.expectNoThrow("killServer") { try host.killServer() }
        t.expectEqual(runner.commands().last ?? [], ["kill-server"], "kill-server ran")
        alive.value = false
        t.expectEqual(host.status(), .stoppedByAgentMenu, "a server gone after a recorded kill-server is a stop, not a death")
        t.expect(!host.status().isAbnormalDeath, "no abnormal death")

        // recordKillServer alone (the app records, then kills elsewhere).
        alive.value = true
        t.expectNoThrow("a session restarts the host") {
            try host.newSession(launchID: "third-1", command: "exec sleep 1", environment: [:], cwd: "/tmp")
        }
        host.recordKillServer()
        alive.value = false
        t.expectEqual(host.status(), .stoppedByAgentMenu, "recordKillServer is enough on its own")

        // Killing when nothing runs is not an error.
        let before = runner.calls.count
        t.expectNoThrow("kill-server with no server is a no-op") { try host.killServer() }
        t.expectEqual(runner.calls.count, before, "and it runs no command")
    }

    // MARK: The helper copy

    do {
        let scratch = shortTempDir()
        defer { scratch.cleanup() }
        let helpers = scratch.url.appendingPathComponent("Helpers", isDirectory: true)
        try? writeExecutable("#!/bin/sh\necho server v1\n", to: helpers.appendingPathComponent(HostHelperNames.server))
        try? writeExecutable("#!/bin/sh\necho client v1\n", to: helpers.appendingPathComponent(HostHelperNames.client))
        let dir = shortHostDir(scratch)
        let alive = FlagBox(false)
        let host = makeHost(dir, runner: RecordingRunner(), alive: alive, helpers: helpers)

        t.expectNoThrow("ensureHost installs the host") { try host.ensureHost() }
        let fm = FileManager.default
        for name in HostHelperNames.all {
            t.expect(fm.isExecutableFile(atPath: dir.appendingPathComponent(name).path), "\(name) is copied and executable")
        }
        t.expectEqual(
            try? Data(contentsOf: dir.appendingPathComponent(HostHelperNames.client)),
            try? Data(contentsOf: helpers.appendingPathComponent(HostHelperNames.client)),
            "the copy is byte-identical"
        )
        t.expectEqual(try? String(contentsOf: dir.appendingPathComponent("tmux.conf"), encoding: .utf8), HostConfig.contents, "the config is written")
        let mode = (try? fm.attributesOfItem(atPath: dir.path))?[.posixPermissions] as? NSNumber
        t.expectEqual(mode?.intValue, 0o700, "the host directory is private")

        // Idempotent: nothing left over from staging.
        t.expectNoThrow("ensureHost twice") { try host.ensureHost() }
        let listing = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        t.expectEqual(listing, ["AgentMenu Session Host", "tmux", "tmux.conf"], "no staging files are left behind")

        // A changed config is rewritten.
        try? "tampered\n".write(to: dir.appendingPathComponent("tmux.conf"), atomically: true, encoding: .utf8)
        t.expectNoThrow("ensureHost repairs the config") { try host.ensureHost() }
        t.expectEqual(try? String(contentsOf: dir.appendingPathComponent("tmux.conf"), encoding: .utf8), HostConfig.contents, "a tampered config is restored")

        // A different bundled helper replaces both copies while no server runs.
        try? writeExecutable("#!/bin/sh\necho server v2 longer\n", to: helpers.appendingPathComponent(HostHelperNames.server))
        try? writeExecutable("#!/bin/sh\necho client v2 longer\n", to: helpers.appendingPathComponent(HostHelperNames.client))
        let second = makeHost(dir, runner: RecordingRunner(), alive: alive, helpers: helpers)
        t.expectNoThrow("ensureHost after an update") { try second.ensureHost() }
        t.expectEqual(
            try? Data(contentsOf: dir.appendingPathComponent(HostHelperNames.server)),
            try? Data(contentsOf: helpers.appendingPathComponent(HostHelperNames.server)),
            "a changed helper is re-copied"
        )

        // While a server answers, its binary is never replaced; the client's may be.
        try? writeExecutable("#!/bin/sh\necho server v3 even longer\n", to: helpers.appendingPathComponent(HostHelperNames.server))
        try? writeExecutable("#!/bin/sh\necho client v3 even longer\n", to: helpers.appendingPathComponent(HostHelperNames.client))
        alive.value = true
        let third = makeHost(dir, runner: RecordingRunner(), alive: alive, helpers: helpers)
        t.expectNoThrow("ensureHost with a server running") { try third.ensureHost() }
        t.expect(
            (try? Data(contentsOf: dir.appendingPathComponent(HostHelperNames.server))) != (try? Data(contentsOf: helpers.appendingPathComponent(HostHelperNames.server))),
            "the server's binary is not replaced while the server runs"
        )
        t.expectEqual(
            try? Data(contentsOf: dir.appendingPathComponent(HostHelperNames.client)),
            try? Data(contentsOf: helpers.appendingPathComponent(HostHelperNames.client)),
            "the attach client's copy is refreshed"
        )

        // A bundle without the helper cannot start a host.
        let empty = scratch.url.appendingPathComponent("Empty", isDirectory: true)
        try? fm.createDirectory(at: empty, withIntermediateDirectories: true)
        let missing = makeHost(shortHostDir(scratch, "m"), runner: RecordingRunner(), helpers: empty)
        t.expectThrows("a missing helper is an error, not a silent no-host") { try missing.ensureHost() }
        t.expectThrows("newSession surfaces it too") {
            try missing.newSession(launchID: "x-1", command: "exec true", environment: [:], cwd: "/")
        }
    }

    // MARK: The generated config (KTD5)

    do {
        let config = HostConfig.contents
        let lines = config.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        let active = lines.filter { !$0.isEmpty && !$0.hasPrefix("#") }
        t.expect(!active.contains { $0.hasPrefix("bind-key") || $0.hasPrefix("bind ") || $0.hasPrefix("bind\t") }, "the config binds no key")
        t.expect(active.contains("set -g prefix None"), "prefix is None")
        t.expect(active.contains("set -g prefix2 None"), "prefix2 is None")
        t.expect(active.contains("unbind-key -a -T prefix"), "the prefix key table is emptied")
        t.expect(!active.contains { $0.contains("C-b") }, "nothing mentions Ctrl+B")
        t.expect(active.contains("set -g set-titles on"), "set-titles is on")
        t.expect(active.contains("set -g set-titles-string '#{pane_title}'"), "the title is the pane title, so the tab never says tmux")
        t.expect(active.contains("set -g status off"), "no status bar")
        t.expect(active.contains("set -g mouse on"), "mouse on")
        t.expect(active.contains("set -s escape-time 0"), "escape-time 0")
        t.expect(active.contains("set -g history-limit 50000"), "history 50000")
        t.expect(active.contains("set -s extended-keys on"), "extended keys on")
        t.expect(active.contains("set -g allow-passthrough on"), "passthrough on")
        t.expect(active.contains("set -s copy-command pbcopy"), "copy-command pbcopy")
        t.expect(active.contains("set -s focus-events on"), "focus events on")
        t.expect(active.contains("set -g default-terminal screen-256color"), "default-terminal screen-256color")
        t.expect(active.contains("set -g bell-action any"), "the bell is passed through")
        t.expect(active.contains("set -s exit-empty off"), "the server outlives its last session")
        t.expect(!active.contains { $0.hasPrefix("source") }, "the config sources nothing of the user's")
        t.expect(config.hasSuffix("\n"), "ends with a newline")
    }

    // MARK: Names live in one place

    do {
        t.expectEqual(HostHelperNames.server, "AgentMenu Session Host", "the server's name")
        t.expectEqual(HostHelperNames.client, "tmux", "the client's name")
        t.expectEqual(HostHelperNames.all, [HostHelperNames.server, HostHelperNames.client], "both, server first")
    }

    // MARK: Integration against a real tmux (skipped when none is present)

    if let tmux = integrationTmux() {
        let scratch = shortTempDir()
        defer { scratch.cleanup() }
        let helpers = scratch.url.appendingPathComponent("H", isDirectory: true)
        let dir = scratch.url.appendingPathComponent("host", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: helpers, withIntermediateDirectories: true)
        for name in HostHelperNames.all { try? fm.copyItem(atPath: tmux, toPath: helpers.appendingPathComponent(name).path) }

        let location = SessionHostLocation(directory: dir)
        if !location.socketPathFits {
            print("   (skipped: real tmux integration — temp path too long for a socket)")
        } else {
            let host = SessionHost(
                location: location, helpersDirectory: helpers, shell: "/bin/sh",
                baseEnvironment: ProcessInfo.processInfo.environment.merging(["TMUX": "/private/tmp/not-ours,1,0", "TMUX_PANE": "%7", "CLAUDECODE": "1", "CLAUDE_CODE_CHILD_SESSION": "1"]) { _, new in new }
            )
            defer { try? host.killServer() }
            let paneEnv = scratch.url.appendingPathComponent("pane-env")

            t.expectEqual(host.status(), .neverStarted, "integration: nothing runs before the first session")
            t.expectNoThrow("integration: a session running sleep is created") {
                try host.newSession(
                    launchID: "it-0001", command: "env > '\(paneEnv.path)'; exec sleep 300",
                    environment: ["CLAUDE_CONFIG_DIR": "/tmp/amh-profile"], cwd: NSTemporaryDirectory()
                )
            }
            t.expect(host.isServerAlive(), "integration: the server answers on the temp socket")
            t.expectEqual(host.status(), .running, "integration: status is running")
            if let snapshot = t.attempt("integration: snapshot", { try host.snapshot() }) {
                t.expectEqual(snapshot.sessionNames, ["it-0001"], "integration: the session is listed")
                t.expect(snapshot.panes.first.map { !$0.tty.isEmpty && !$0.isDead } ?? false, "integration: its pane has a live tty")
                t.expect(snapshot.isDetached("it-0001"), "integration: with no client attached it is detached")
            }

            // What the pane's process actually sees (the global environment is
            // what panes inherit, which `show-environment -t` does not show).
            var paneText = ""
            for _ in 0..<50 {
                paneText = (try? String(contentsOf: paneEnv, encoding: .utf8)) ?? ""
                if paneText.contains("CLAUDE_CONFIG_DIR=") { break }
                Thread.sleep(forTimeInterval: 0.1)
            }
            let paneLines = paneText.split(separator: "\n").map(String.init)
            t.expect(paneLines.contains("CLAUDE_CONFIG_DIR=/tmp/amh-profile"), "integration: the pane sees CLAUDE_CONFIG_DIR")
            t.expect(!paneLines.contains { $0.hasPrefix("CLAUDECODE=") }, "integration: CLAUDECODE did not reach the pane")
            t.expect(!paneLines.contains { $0.hasPrefix("CLAUDE_CODE_CHILD_SESSION=") }, "integration: CLAUDE_CODE_CHILD_SESSION did not reach the pane")
            t.expect(!paneLines.contains { $0.hasPrefix("TMUX=") && $0.contains("not-ours") }, "integration: the caller's TMUX did not reach the pane")
            t.expect(paneLines.contains { $0.hasPrefix("PATH=") }, "integration: the rest of the environment did")

            // The config took: no prefix, status off.
            let prefix = (try? SessionHost.systemRunner()(
                location.serverHelper.path, host.tmuxArguments(["show-options", "-gv", "prefix"]),
                ProcessInfo.processInfo.environment
            )) ?? HostRunResult(status: -1)
            t.expectEqual(prefix.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "None", "integration: the server runs with prefix None")

            // Ending the last session leaves the server running.
            t.expectNoThrow("integration: kill the only session") { try host.killSession(launchID: "it-0001") }
            Thread.sleep(forTimeInterval: 0.5)
            t.expect(host.isServerAlive(), "integration: ending the last session leaves the server running (exit-empty off)")
            if let empty = t.attempt("integration: an empty live host snapshots without throwing", { try host.snapshot() }) {
                t.expect(empty.panes.isEmpty && empty.clients.isEmpty, "integration: and the snapshot is empty")
            }
            t.expectEqual(host.status(), .running, "integration: and reports no death")

            // A server killed behind AgentMenu's back is a death.
            t.expectNoThrow("integration: a second session") {
                try host.newSession(launchID: "it-0002", command: "exec sleep 300", environment: [:], cwd: NSTemporaryDirectory())
            }
            _ = try? SessionHost.systemRunner()(
                location.serverHelper.path, host.tmuxArguments(["kill-server"]), ProcessInfo.processInfo.environment
            )
            Thread.sleep(forTimeInterval: 0.5)
            t.expect(!host.isServerAlive(), "integration: the server is gone")
            t.expectEqual(host.status(), .died, "integration: a server killed without a recorded kill-server is a death")
            t.expectThrows("integration: snapshot reports the missing server") { try host.snapshot() }

            // And a recorded kill is not.
            t.expectNoThrow("integration: restart") {
                try host.newSession(launchID: "it-0003", command: "exec sleep 300", environment: [:], cwd: NSTemporaryDirectory())
            }
            t.expectNoThrow("integration: killServer") { try host.killServer() }
            Thread.sleep(forTimeInterval: 0.5)
            t.expectEqual(host.status(), .stoppedByAgentMenu, "integration: a recorded kill-server is a stop, not a death")
        }
    } else {
        print("   (skipped: real tmux integration — no tmux found; set AGENTMENU_TEST_TMUX or build packaging/tmux/build.sh)")
    }
}
