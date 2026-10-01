// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

// The owned launch path (U11): the ledger row exists before any process runs,
// hosted launches go through the host and open the attach command, plain ones
// type the agent command and record no host, a host that cannot start falls
// back instead of losing the launch, and a terminal that cannot open does not
// leave an invisible agent behind. The host, the terminal and the clock are
// injected; no tmux runs and no terminal opens.

private let pinned = "5d1c7e0a-3b6e-4d7a-9c21-0e0b7a4d1f33"
private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// Runs an async body to completion from the synchronous test runner. The
/// body never needs the main actor.
private final class ResultBox<T>: @unchecked Sendable { var value: Result<T, Error>? }

private func blocking<T: Sendable>(_ body: @escaping @Sendable () async throws -> T) -> Result<T, Error> {
    let box = ResultBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
        do { box.value = .success(try await body()) } catch { box.value = .failure(error) }
        done.signal()
    }
    done.wait()
    return box.value ?? .failure(CancellationError())
}

/// Records every call, and what the ledger on disk held when it was made.
private final class FakeHost: SessionHosting, @unchecked Sendable {
    var socketPath = "/h/s"
    var failNewSession = false
    /// What `newSession` throws when `failNewSession` is set.
    var newSessionError: Error = SessionHostError.helperMissing("/nowhere")
    /// What the host answers when asked to make sure the session is gone.
    var absenceConfirmed = true
    private(set) var calls: [String] = []
    private(set) var absenceAskedAfter: [Error?] = []
    private(set) var ledgerAtNewSession: [LedgerRow] = []
    private(set) var launch: LaunchCommand?
    let storeURL: URL

    init(storeURL: URL) { self.storeURL = storeURL }

    func ensureHost() throws { calls.append("ensureHost") }

    func newSession(launchID: String, launch: LaunchCommand) throws {
        calls.append("newSession \(launchID)")
        self.launch = launch
        let reader = SessionStore(url: storeURL)
        _ = try? reader.load()
        ledgerAtNewSession = reader.ledger.rows
        if failNewSession { throw newSessionError }
    }

    func killSession(launchID: String) throws { calls.append("killSession \(launchID)") }

    func ensureSessionAbsent(launchID: String, after failure: Error?) -> Bool {
        calls.append("ensureSessionAbsent \(launchID)")
        absenceAskedAfter.append(failure)
        return absenceConfirmed
    }

    func attachLaunchCommand(launchID: String, workingDirectory: String) -> LaunchCommand {
        LaunchCommand(
            executable: "/h/tmux", arguments: ["-S", socketPath, "attach-session", "-t", launchID],
            environment: [:], workingDirectory: workingDirectory
        )
    }

    func snapshot() throws -> HostSnapshot { HostSnapshot() }
    func isServerAlive() -> Bool { false }
}

private final class OpenRecorder: @unchecked Sendable {
    private(set) var commands: [LaunchCommand] = []
    var error: Error?
    private(set) var ledgerAtOpen: [LedgerRow] = []
    let storeURL: URL

    init(storeURL: URL) { self.storeURL = storeURL }

    func open(_ command: LaunchCommand) async throws {
        commands.append(command)
        let reader = SessionStore(url: storeURL)
        _ = try? reader.load()
        ledgerAtOpen = reader.ledger.rows
        if let error { throw error }
    }
}

private func plan(hosted: Bool, kind: LedgerRow.Kind = .fresh, launchID: String = pinned) -> OwnedLaunchPlan {
    var arguments = ["--model", "opus"]
    switch kind {
    case .fresh: arguments = ["--session-id", launchID] + arguments
    case .restore(let id): arguments = ["--resume", id] + arguments
    }
    return OwnedLaunchPlan(
        launchID: launchID,
        kind: kind,
        profileID: "work",
        configDirectory: "/Users/x/.claude-work",
        preset: Preset(model: "opus", keepRunning: hosted),
        terminalID: "terminal-app",
        command: LaunchCommand(
            executable: "/usr/local/bin/claude", arguments: arguments,
            environment: ["CLAUDE_CONFIG_DIR": "/Users/x/.claude-work"],
            workingDirectory: "/Users/x/project"
        ),
        wantsHost: hosted
    )
}

private struct TerminalRefused: Error, CustomStringConvertible {
    var description: String { "the terminal refused" }
}

/// A host directory with the two helper copies already in place, so a real
/// `SessionHost` can run `ensureHost()` without a bundle.
private func realHost(_ base: TempDir, environment: [String: String], runner: @escaping SessionHost.Runner) -> SessionHost? {
    let helpers = base.url.appendingPathComponent("helpers", isDirectory: true)
    let directory = base.url.appendingPathComponent("h", isDirectory: true)
    do {
        try FileManager.default.createDirectory(at: helpers, withIntermediateDirectories: true)
        for name in HostHelperNames.all {
            let url = helpers.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    } catch { return nil }
    return SessionHost(
        location: SessionHostLocation(directory: directory),
        helpersDirectory: helpers,
        shell: "/bin/bash",
        baseEnvironment: environment,
        runner: runner,
        socketProbe: { _ in false }
    )
}

func runOwnedLauncherTests(_ t: TestRunner) {
    t.suite("OwnedLauncher")

    // MARK: Hosted: the Starting row is on disk before any process call

    do {
        let dir = TempDir("owned-hosted")
        defer { dir.cleanup() }
        let url = dir.url.appendingPathComponent("sessions.json")
        let store = SessionStore(url: url)
        let host = FakeHost(storeURL: url)
        let opener = OpenRecorder(storeURL: url)
        let launcher = OwnedLauncher(store: store, host: host, now: { t0 })

        let result = blocking { try await launcher.launch(plan(hosted: true)) { try await opener.open($0) } }
        guard case .success(let outcome) = result else { t.expect(false, "a hosted launch succeeds: \(result)"); return }

        t.expect(outcome.hosted, "keep-running on runs under the host")
        t.expect(outcome.recorded, "the row was recorded")
        t.expectEqual(host.ledgerAtNewSession.map(\.launchID), [pinned], "the ledger row is on disk before the host creates the session")
        t.expectEqual(host.ledgerAtNewSession.first?.phase, .starting, "…as Starting")
        t.expectEqual(host.ledgerAtNewSession.first?.hostSocket, "/h/s", "…with the host socket")
        t.expectEqual(host.ledgerAtNewSession.first?.startedAt, t0, "…and the time")
        t.expectEqual(opener.ledgerAtOpen.map(\.launchID), [pinned], "and before the terminal opens")
        t.expectEqual(host.calls, ["newSession \(pinned)"], "the host is asked once")
        t.expect(host.launch?.arguments.starts(with: ["--session-id", pinned]) == true, "the agent is pinned to the launch id inside the host")
        t.expectEqual(opener.commands.count, 1, "one terminal window")
        t.expectEqual(opener.commands.first?.executable, "/h/tmux", "the terminal runs the attach client, not the agent")
        t.expect(opener.commands.first?.arguments.contains("attach-session") == true, "…attaching")
        t.expect(opener.commands.first?.arguments.contains(pinned) == true, "…to the session named by the launch id")

        let row = SessionStore(url: url).ledgerFromDiskForTest().row(launchID: pinned)
        t.expectEqual(row?.cwd, "/Users/x/project", "the folder is recorded")
        t.expectEqual(row?.terminalID, "terminal-app", "the terminal is recorded")
        t.expectEqual(row?.profileID, "work", "the account is recorded")
        t.expectEqual(row?.preset.model, "opus", "the resolved preset is recorded")
        t.expectEqual(row?.kind, .fresh, "a fresh launch")
    }

    // MARK: Plain: a keep-running-off launch is recorded too, with no host

    do {
        let dir = TempDir("owned-plain")
        defer { dir.cleanup() }
        let url = dir.url.appendingPathComponent("sessions.json")
        let store = SessionStore(url: url)
        let host = FakeHost(storeURL: url)
        let opener = OpenRecorder(storeURL: url)
        let launcher = OwnedLauncher(store: store, host: host, now: { t0 })

        let result = blocking { try await launcher.launch(plan(hosted: false)) { try await opener.open($0) } }
        guard case .success(let outcome) = result else { t.expect(false, "a plain launch succeeds"); return }
        t.expect(!outcome.hosted, "keep-running off is a plain launch")
        t.expect(outcome.hostFailure == nil, "…which is not a failure")
        t.expect(host.calls.isEmpty, "the host is never asked")
        t.expectEqual(opener.commands.first?.executable, "/usr/local/bin/claude", "the agent command is what the terminal types")
        t.expect(opener.commands.first?.arguments.starts(with: ["--session-id", pinned]) == true, "…pinned to the launch id")
        let row = SessionStore(url: url).ledgerFromDiskForTest().row(launchID: pinned)
        t.expect(row != nil, "a plain launch writes a ledger row too")
        t.expect(row?.hostSocket == nil, "…with no host socket")
        t.expectEqual(opener.ledgerAtOpen.map(\.launchID), [pinned], "…before the terminal opens")

        // Matched by its pinned id, then recorded as ended once its file is gone.
        let live = LiveSession(
            key: LiveSessionKey(configDirectory: "/Users/x/.claude-work", pid: 600, procStart: 1_800_000_100),
            agentID: RegistryReader.claudeAgentID, agentDisplayName: "Claude Code",
            pid: 600, sessionId: pinned, cwd: "/Users/x/project", status: .working,
            startedAt: t0
        )
        try? store.updateLedger { ledger in
            _ = ledger.reconcile(LedgerObservation(live: [live], now: t0.addingTimeInterval(2), isSameProcessRunning: { _ in true }))
        }
        t.expectEqual(store.ledger.row(launchID: pinned)?.phase, .live, "matched by its pinned id")
        try? store.updateLedger { ledger in
            _ = ledger.reconcile(LedgerObservation(live: [], now: t0.addingTimeInterval(9), isSameProcessRunning: { _ in false }))
        }
        t.expectEqual(store.ledger.row(launchID: pinned)?.endedAt, t0.addingTimeInterval(9), "after its registry file is removed the ledger records the session as ended")
    }

    // MARK: A restore keeps its own launch id and is recorded as a restore

    do {
        let dir = TempDir("owned-restore")
        defer { dir.cleanup() }
        let url = dir.url.appendingPathComponent("sessions.json")
        let host = FakeHost(storeURL: url)
        let opener = OpenRecorder(storeURL: url)
        let launcher = OwnedLauncher(store: SessionStore(url: url), host: host, now: { t0 })
        let resumed = "0f0c6a52-2b1d-4a43-8d37-6a1b9d2c7e10"
        let launchID = LaunchLedger.newLaunchID()
        let result = blocking {
            try await launcher.launch(plan(hosted: true, kind: .restore(resumedSessionID: resumed), launchID: launchID)) {
                try await opener.open($0)
            }
        }
        guard case .success = result else { t.expect(false, "a restore succeeds"); return }
        let row = SessionStore(url: url).ledgerFromDiskForTest().row(launchID: launchID)
        t.expectEqual(row?.kind, .restore(resumedSessionID: resumed), "the row records what it resumed")
        t.expect(host.launch?.arguments.contains("--session-id") == false, "a restore never carries --session-id")
        t.expect(host.launch?.arguments.starts(with: ["--resume", resumed]) == true, "it resumes")
        t.expectEqual(host.calls, ["newSession \(launchID)"], "the tmux session is named by the launch id, not the resumed id")
    }

    // MARK: A host that cannot start falls back to a plain launch

    do {
        let dir = TempDir("owned-fallback")
        defer { dir.cleanup() }
        let url = dir.url.appendingPathComponent("sessions.json")
        let host = FakeHost(storeURL: url)
        host.failNewSession = true
        let opener = OpenRecorder(storeURL: url)
        let events = EventLog()
        let launcher = OwnedLauncher(
            store: SessionStore(url: url), host: host, now: { t0 },
            hostLaunched: { _, terminal, ok in events.record("host \(terminal) \(ok)") }
        )
        let result = blocking { try await launcher.launch(plan(hosted: true)) { try await opener.open($0) } }
        guard case .success(let outcome) = result else { t.expect(false, "a launch survives a host that will not start"); return }
        t.expect(!outcome.hosted, "it ran plainly")
        t.expect(outcome.hostFailure?.contains("helper") == true, "and says why")
        t.expectEqual(opener.commands.first?.executable, "/usr/local/bin/claude", "the terminal types the agent command")
        t.expect(host.calls.contains("ensureSessionAbsent \(pinned)"), "a half-created session is removed so it cannot collide")
        t.expectEqual(events.all, ["host terminal-app false"], "the journal hook hears that the host launch failed")
        t.expect(SessionStore(url: url).ledgerFromDiskForTest().row(launchID: pinned)?.hostSocket == nil, "and the row no longer claims a host")
    }

    // MARK: A host that timed out may still create the session: no plain launch beside it

    do {
        let dir = TempDir("owned-timeout-late")
        defer { dir.cleanup() }
        let url = dir.url.appendingPathComponent("sessions.json")
        let host = FakeHost(storeURL: url)
        host.failNewSession = true
        host.newSessionError = SessionHostError.commandFailed(
            command: "new-session", status: SessionHost.timedOutStatus, stderr: "timed out after 20 seconds"
        )
        // The session comes up late, so the host cannot say it is absent.
        host.absenceConfirmed = false
        let opener = OpenRecorder(storeURL: url)
        let events = EventLog()
        let launcher = OwnedLauncher(
            store: SessionStore(url: url), host: host, now: { t0 },
            hostLaunched: { _, terminal, ok in events.record("host \(terminal) \(ok)") }
        )
        let result = blocking { try await launcher.launch(plan(hosted: true)) { try await opener.open($0) } }
        if case .failure(let error) = result {
            t.expect(error is OwnedLaunchError, "the launch fails with the host's own refusal")
            t.expect((error as? OwnedLaunchError)?.errorDescription?.contains("timed out") == true, "and says what the host said")
        } else {
            t.expect(false, "a launch whose host session cannot be ruled out must not go ahead")
        }
        t.expect(opener.commands.isEmpty, "no terminal is opened: no plain launch on a session id the host may be running")
        t.expectEqual(host.calls, ["newSession \(pinned)", "ensureSessionAbsent \(pinned)"], "the host was asked once to make sure")
        t.expect(host.absenceAskedAfter.first.flatMap { $0 } as? SessionHostError != nil, "…and was told what failed")
        let row = SessionStore(url: url).ledgerFromDiskForTest().row(launchID: pinned)
        if case .failed(let reason)? = row?.phase {
            t.expect(reason.contains("timed out"), "the row is Failed, with the host's error")
        } else {
            t.expect(false, "the row is marked Failed to start")
        }
        t.expectEqual(row?.hostSocket, "/h/s", "it keeps its host, so a session that does come up is matched and followed")
        t.expectEqual(events.all, ["host terminal-app false"], "the journal hears that the host launch failed")
    }

    // MARK: A host that timed out and confirms nothing was created falls back

    do {
        let dir = TempDir("owned-timeout-absent")
        defer { dir.cleanup() }
        let url = dir.url.appendingPathComponent("sessions.json")
        let host = FakeHost(storeURL: url)
        host.failNewSession = true
        host.newSessionError = SessionHostError.commandFailed(
            command: "new-session", status: SessionHost.timedOutStatus, stderr: "timed out after 20 seconds"
        )
        host.absenceConfirmed = true
        let opener = OpenRecorder(storeURL: url)
        let launcher = OwnedLauncher(store: SessionStore(url: url), host: host, now: { t0 })
        let result = blocking { try await launcher.launch(plan(hosted: true)) { try await opener.open($0) } }
        guard case .success(let outcome) = result else { t.expect(false, "a confirmed-absent session lets the launch fall back"); return }
        t.expect(!outcome.hosted, "it ran plainly")
        t.expect(outcome.hostFailure?.contains("timed out") == true, "and says why")
        t.expectEqual(opener.commands.first?.executable, "/usr/local/bin/claude", "the terminal types the agent command")
        t.expect(SessionStore(url: url).ledgerFromDiskForTest().row(launchID: pinned)?.hostSocket == nil, "and the row no longer claims a host")
    }

    // MARK: A terminal that will not open, and a session that cannot be stopped

    do {
        let dir = TempDir("owned-terminal-unstoppable")
        defer { dir.cleanup() }
        let url = dir.url.appendingPathComponent("sessions.json")
        let host = FakeHost(storeURL: url)
        host.absenceConfirmed = false
        let opener = OpenRecorder(storeURL: url)
        opener.error = TerminalRefused()
        let launcher = OwnedLauncher(store: SessionStore(url: url), host: host, now: { t0 })
        _ = blocking { try await launcher.launch(plan(hosted: true)) { try await opener.open($0) } }
        if case .failed(let reason)? = SessionStore(url: url).ledgerFromDiskForTest().row(launchID: pinned)?.phase {
            t.expect(reason.contains("the terminal refused"), "the row still says the terminal could not open it")
            t.expect(reason.contains("may still be running"), "and that the session could not be stopped")
        } else {
            t.expect(false, "the row is marked Failed to start")
        }
    }

    // MARK: A terminal that cannot open does not leave an invisible agent

    do {
        let dir = TempDir("owned-terminal-fails")
        defer { dir.cleanup() }
        let url = dir.url.appendingPathComponent("sessions.json")
        let host = FakeHost(storeURL: url)
        let opener = OpenRecorder(storeURL: url)
        opener.error = TerminalRefused()
        let launcher = OwnedLauncher(store: SessionStore(url: url), host: host, now: { t0 })
        let result = blocking { try await launcher.launch(plan(hosted: true)) { try await opener.open($0) } }
        if case .failure(let error) = result {
            t.expect(error is TerminalRefused, "the terminal's own error reaches the caller")
        } else {
            t.expect(false, "a refused terminal fails the launch")
        }
        t.expect(host.calls.contains("ensureSessionAbsent \(pinned)"), "the hosted session is killed")
        if case .failed(let reason)? = SessionStore(url: url).ledgerFromDiskForTest().row(launchID: pinned)?.phase {
            t.expect(reason.contains("the terminal refused"), "the row says the terminal could not open it")
        } else {
            t.expect(false, "the row is marked Failed to start")
        }
    }

    // MARK: No host at all (the CLI, a build with no helper): plain, with the reason

    do {
        let dir = TempDir("owned-nohost")
        defer { dir.cleanup() }
        let url = dir.url.appendingPathComponent("sessions.json")
        let opener = OpenRecorder(storeURL: url)
        let launcher = OwnedLauncher(store: SessionStore(url: url), host: nil, now: { t0 })
        let result = blocking { try await launcher.launch(plan(hosted: true)) { try await opener.open($0) } }
        if case .success(let outcome) = result {
            t.expect(!outcome.hosted, "with no host the launch is plain")
            t.expect(outcome.hostFailure != nil, "and the outcome says the host was missing")
        } else {
            t.expect(false, "a launch does not need a host")
        }
    }

    // MARK: A store that refuses to write never blocks a launch

    do {
        let dir = TempDir("owned-refused")
        defer { dir.cleanup() }
        let url = dir.url.appendingPathComponent("sessions.json")
        try? Data("not json".utf8).write(to: url)
        let host = FakeHost(storeURL: url)
        let opener = OpenRecorder(storeURL: url)
        let launcher = OwnedLauncher(store: SessionStore(url: url), host: host, now: { t0 })
        let result = blocking { try await launcher.launch(plan(hosted: true)) { try await opener.open($0) } }
        if case .success(let outcome) = result {
            t.expect(!outcome.recorded, "the outcome says nothing was recorded")
            t.expect(outcome.hosted, "but the launch went ahead")
        } else {
            t.expect(false, "an unreadable store does not stop a launch")
        }
        t.expectEqual(try? Data(contentsOf: url), Data("not json".utf8), "and the file is left exactly as it was")
    }

    // MARK: Hosted environment (KTD18), through the real host controller

    do {
        let dir = TempDir("oe")
        defer { dir.cleanup() }
        let url = dir.url.appendingPathComponent("sessions.json")
        let calls = CallLog()
        let host = realHost(
            dir,
            environment: [
                "PATH": "/usr/bin:/bin", "HOME": "/Users/x",
                "CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDECODE": "1", "TMUX": "/tmp/tmux-501/default,1,0", "TMUX_PANE": "%1",
            ],
            runner: { executable, arguments, environment in
                calls.record(arguments: arguments, environment: environment)
                return HostRunResult()
            }
        )
        guard let host else { t.expect(false, "set up a host with helper copies"); return }
        let opener = OpenRecorder(storeURL: url)
        let launcher = OwnedLauncher(store: SessionStore(url: url), host: host, now: { t0 })
        var hostedPlan = plan(hosted: true)
        hostedPlan.command = LaunchCommand(
            executable: hostedPlan.command.executable, arguments: hostedPlan.command.arguments,
            environment: hostedPlan.command.environment.merging(["CLAUDE_CODE_CHILD_SESSION": "1", "CLAUDECODE": "1"]) { $1 },
            workingDirectory: hostedPlan.command.workingDirectory
        )
        let finalPlan = hostedPlan
        let result = blocking { try await launcher.launch(finalPlan) { try await opener.open($0) } }
        guard case .success = result else { t.expect(false, "the hosted launch through the real controller succeeds: \(result)"); return }

        guard let newSession = calls.all.first(where: { $0.arguments.contains("new-session") }) else {
            t.expect(false, "the host ran new-session")
            return
        }
        for name in ["CLAUDE_CODE_CHILD_SESSION", "CLAUDECODE", "TMUX", "TMUX_PANE"] {
            t.expect(newSession.environment[name] == nil, "\(name) is removed from the environment the host runs with")
            t.expect(!newSession.arguments.contains { $0.hasPrefix("\(name)=") }, "\(name) is not passed to the session with -e")
        }
        t.expect(newSession.arguments.contains("CLAUDE_CONFIG_DIR=/Users/x/.claude-work"), "the account still reaches the session through -e")
        t.expect(newSession.arguments.contains(pinned), "the session is named by the launch id")
        t.expect(newSession.arguments.contains { $0.contains("--session-id") && $0.contains(pinned) }, "and the agent inside it is pinned to that id")
        t.expect(newSession.arguments.contains("-S"), "every host call carries -S")
        t.expect(opener.commands.first?.arguments.contains("attach-session") == true, "the terminal attaches")
    }
}

private final class EventLog: @unchecked Sendable {
    private(set) var all: [String] = []
    func record(_ line: String) { all.append(line) }
}

private final class CallLog: @unchecked Sendable {
    struct Call { let arguments: [String]; let environment: [String: String] }
    private(set) var all: [Call] = []
    func record(arguments: [String], environment: [String: String]) {
        all.append(Call(arguments: arguments, environment: environment))
    }
}

private extension SessionStore {
    func ledgerFromDiskForTest() -> LaunchLedger {
        _ = try? load()
        return ledger
    }
}
