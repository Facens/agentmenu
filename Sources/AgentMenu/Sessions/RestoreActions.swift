// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// A restore that has been launched: the ledger row it wrote, which is what a
/// Reopen all waits on to see the session come up.
struct RestoreStarted {
    let launchID: String
    let outcome: OwnedLaunchOutcome
}

extension AppEnvironment {
    /// Restores a session through the one guard and the owned launch path (KTD13,
    /// R31): a click on a Closed row, Reopen last closed and Reopen all all end
    /// here. What it launches is `RestoreActions`' decision, in Kit and tested:
    /// the recorded preset for a session AgentMenu launched, else the
    /// transcript's account with the folder's preset or the global default.
    ///
    /// The window opens in the recorded terminal when it is still usable, else
    /// in the first usable one; the launch path is the one the recorded
    /// keep-running value selects (hosted or plain); the command is
    /// `--resume <id>` with the whole preset and never `--session-id`
    /// (KTD14); and it gets a launch id of its own, which is only the tmux
    /// session name: the ledger row is matched by the resumed id.
    ///
    /// Throws a `HistoryResumeRefusal` when the guard or the plan refuses (the
    /// caller decides what each means: `alreadyLive` and `runningDetached` are a
    /// pointer to a session, not an error), and a `LaunchError` or the
    /// terminal's own error for what fails after.
    ///
    /// Claude Code is looked up by id and checked with `isUsable`, not resolved
    /// through `agentManifest(for:)`: that falls back to whichever agent is
    /// usable, and only Claude Code writes the transcripts a restore resumes.
    func restore(_ source: RestoreSource, guardSnapshot: RestoreGuardSnapshot) async throws -> RestoreStarted {
        let claude = registry.agent(id: RegistryReader.claudeAgentID).flatMap { isUsable($0) ? $0 : nil }
        let launch = try RestoreActions.plan(
            source: source,
            config: config,
            agent: claude,
            terminalFor: { self.terminalManifest(for: $0)?.id },
            guardSnapshot: guardSnapshot
        ).get()

        guard let terminalID = launch.terminalID, let terminal = registry.terminal(id: terminalID) else {
            throw LaunchError.terminalUnavailable(launch.terminalID ?? "none selected")
        }
        let binaryPath = try resolveOrReport(launch.agent.binary)
        let launchID = LaunchLedger.newLaunchID()
        let command = try launch.command(binaryPath: binaryPath, launchID: launchID)
        let plan = OwnedLaunchPlan(
            launchID: launchID,
            kind: .restore(resumedSessionID: launch.sessionID),
            profileID: launch.profile.id,
            configDirectory: launch.profile.expandedConfigDirectory.path,
            preset: launch.resolved.preset,
            terminalID: terminal.id,
            command: command,
            wantsHost: launch.wantsHost
        )
        let outcome = try await ownedLauncher.launch(plan) { [self] command in
            try await self.open(command, in: terminal)
        }
        if let failure = outcome.hostFailure {
            FileHandle.standardError.write(Data("agentmenu: restored without keep-running: \(failure)\n".utf8))
        }
        // A restore is a launch too: the first one asks (KTD15).
        notifier.requestAuthorizationIfNeeded()
        return RestoreStarted(launchID: launchID, outcome: outcome)
    }
}
