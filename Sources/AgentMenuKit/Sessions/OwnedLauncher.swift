// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Everything the owned launch path needs to know about one launch (U11).
public struct OwnedLaunchPlan: Sendable {
    public var launchID: String
    public var kind: LedgerRow.Kind
    public var agentID: String
    public var profileID: String?
    /// The config directory the launch runs under, as the command spells it.
    public var configDirectory: String?
    /// The resolved preset, kept in the ledger so a restore can re-pass all
    /// of it (KTD14).
    public var preset: Preset
    public var terminalID: String
    /// The agent command (`--session-id` for a fresh launch, `--resume` for a
    /// restore).
    public var command: LaunchCommand
    /// The resolved keep-running value is on (R15).
    public var wantsHost: Bool

    public init(
        launchID: String,
        kind: LedgerRow.Kind,
        agentID: String = RegistryReader.claudeAgentID,
        profileID: String?,
        configDirectory: String?,
        preset: Preset,
        terminalID: String,
        command: LaunchCommand,
        wantsHost: Bool
    ) {
        self.launchID = launchID
        self.kind = kind
        self.agentID = agentID
        self.profileID = profileID
        self.configDirectory = configDirectory
        self.preset = preset
        self.terminalID = terminalID
        self.command = command
        self.wantsHost = wantsHost
    }
}

/// Why a launch did not go ahead, besides what the terminal itself says.
public enum OwnedLaunchError: Error, Equatable, LocalizedError {
    /// The host failed to create the session and could not confirm that none
    /// is left (a command that timed out may still be creating it). Starting
    /// the agent plainly now could put two processes on one session id.
    case hostSessionUnconfirmed(String)

    public var errorDescription: String? {
        switch self {
        case .hostSessionUnconfirmed(let reason):
            return "The session host did not answer in time (\(reason)), so the session was not started. Try again in a moment."
        }
    }
}

/// How a launch went, for the caller that journals and reports it.
public struct OwnedLaunchOutcome: Equatable, Sendable {
    public let launchID: String
    /// The agent runs under the session host, and the terminal holds an
    /// attach client.
    public let hosted: Bool
    /// Why a launch that wanted the host ran plainly instead; nil when it was
    /// hosted or did not want to be.
    public let hostFailure: String?
    /// The ledger row was written. False when the store refused (a file this
    /// build cannot read or write): the launch itself still goes ahead.
    public let recorded: Bool
}

/// Every Claude Code launch AgentMenu makes, owned from the first moment
/// (U11, R15, R16, R22, KTD3, KTD14).
///
/// The sequence, and why it is in this order:
///
/// 1. **The ledger row, first** — Starting, durable on disk — before any
///    process runs, so a crash at any later point leaves a record of the
///    launch (R22) rather than a session AgentMenu never heard of.
/// 2. **Hosted** (keep-running on): the host creates the session, named by
///    the launch id, with the scrubbed environment (KTD18); then the terminal
///    is opened on the attach command. **Plain**: the terminal is opened on
///    the agent command, exactly as before, and no host socket is recorded.
/// 3. A host that cannot start does not stop the launch: it falls back to a
///    plain one, says why in the outcome (and the journal), and the row
///    records no host. Losing detach is better than losing the launch, and
///    the outcome keeps it from being silent. The fallback only runs once the
///    host has confirmed that no session of that name exists (a command that
///    timed out may still be creating one); otherwise the row is marked Failed
///    and the launch throws.
/// 4. A terminal that cannot be opened after the host created the session
///    kills that session — nobody is told "failed" while an agent keeps
///    running unseen — and marks the row Failed with the terminal's error,
///    adding that the session may still be running when the host could not
///    confirm it stopped.
///
/// The store, host, clock and terminal are injected; nothing here runs tmux
/// or opens a terminal by itself.
public final class OwnedLauncher: @unchecked Sendable {
    /// Opens a terminal window on a command: the manifest's launch path.
    public typealias Open = @Sendable (LaunchCommand) async throws -> Void

    private let store: SessionStore
    private let host: SessionHosting?
    private let now: @Sendable () -> Date
    private let hostLaunched: @Sendable (_ launchID: String, _ terminalID: String, _ ok: Bool) -> Void
    private let ledgerWritten: @Sendable () -> Void

    /// - Parameters:
    ///   - hostLaunched: told whether the host created the session, right
    ///     after it was asked and before the terminal is opened (the `host
    ///     launch` journal event).
    ///   - ledgerWritten: told after each change to the ledger, so the
    ///     Sessions list shows Starting without waiting for the terminal.
    public init(
        store: SessionStore,
        host: SessionHosting?,
        now: @escaping @Sendable () -> Date = { Date() },
        hostLaunched: @escaping @Sendable (_ launchID: String, _ terminalID: String, _ ok: Bool) -> Void = { _, _, _ in },
        ledgerWritten: @escaping @Sendable () -> Void = {}
    ) {
        self.store = store
        self.host = host
        self.now = now
        self.hostLaunched = hostLaunched
        self.ledgerWritten = ledgerWritten
    }

    /// The agent command for a launch: a fresh one is pinned to `launchID`
    /// (`--session-id`), a restore resumes (`--resume`) and never carries it
    /// (KTD14). The one place the two are told apart.
    public static func command(
        agent: AgentManifest,
        resolved: ResolvedPreset,
        profile: Profile?,
        directory: String,
        binaryPath: String,
        kind: LedgerRow.Kind,
        launchID: String
    ) throws -> LaunchCommand {
        switch kind {
        case .fresh:
            return try CommandBuilder.build(
                agent: agent, resolved: resolved, profile: profile, directory: directory,
                binaryPath: binaryPath, sessionID: launchID
            )
        case .restore(let resumedSessionID):
            return try CommandBuilder.build(
                agent: agent, resolved: resolved, profile: profile, directory: directory,
                binaryPath: binaryPath, resumeSessionID: resumedSessionID
            )
        }
    }

    public func launch(_ plan: OwnedLaunchPlan, open: Open) async throws -> OwnedLaunchOutcome {
        var hosted = false
        var hostFailure: String?
        let activeHost = plan.wantsHost ? host : nil
        if plan.wantsHost, activeHost == nil { hostFailure = "The session host is not available." }

        let row = LedgerRow(
            launchID: plan.launchID,
            kind: plan.kind,
            agentID: plan.agentID,
            profileID: plan.profileID,
            configDirectory: plan.configDirectory,
            cwd: plan.command.workingDirectory,
            preset: plan.preset,
            terminalID: plan.terminalID,
            hostSocket: activeHost?.socketPath,
            startedAt: now()
        )
        let recorded = record { $0.begin(row, now: self.now()) }

        var toOpen = plan.command
        if let activeHost {
            do {
                try activeHost.newSession(launchID: plan.launchID, launch: plan.command)
                hostLaunched(plan.launchID, plan.terminalID, true)
                hosted = true
                toOpen = activeHost.attachLaunchCommand(
                    launchID: plan.launchID, workingDirectory: plan.command.workingDirectory
                )
            } catch {
                hostLaunched(plan.launchID, plan.terminalID, false)
                let reason = Self.describe(error)
                hostFailure = reason
                // A session the host half-created, or one a timed-out command
                // is still creating, must not meet the plain launch of the
                // same id: two processes on one session id corrupt its
                // transcript. The plain launch only goes ahead once the host
                // has confirmed that no session of that name is left.
                guard activeHost.ensureSessionAbsent(launchID: plan.launchID, after: error) else {
                    // The row keeps its host, so a session that does come up
                    // is still matched by its pane and followed.
                    let failed = "The session host could not confirm that the session is not running (\(reason)), so none was started."
                    _ = record { $0.update(launchID: plan.launchID) { $0.phase = .failed(reason: failed) } }
                    throw OwnedLaunchError.hostSessionUnconfirmed(reason)
                }
                _ = record { $0.update(launchID: plan.launchID) { $0.hostSocket = nil } }
            }
        }

        do {
            try await open(toOpen)
        } catch {
            var reason = "The terminal could not open the session: \(Self.describe(error))"
            if hosted, activeHost?.ensureSessionAbsent(launchID: plan.launchID, after: nil) != true {
                // Nobody is told "failed" while an agent may keep running
                // unseen without being told that too. The row keeps its host,
                // so the session is still matched and followed if it is.
                reason += " The session it started could not be stopped and may still be running."
            }
            _ = record { $0.update(launchID: plan.launchID) { $0.phase = .failed(reason: reason) } }
            throw error
        }
        return OwnedLaunchOutcome(launchID: plan.launchID, hosted: hosted, hostFailure: hostFailure, recorded: recorded)
    }

    private func record(_ change: (inout LaunchLedger) -> Void) -> Bool {
        defer { ledgerWritten() }
        do {
            try store.updateLedger(change)
            return true
        } catch {
            return false
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
