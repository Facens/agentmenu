// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Why a history click produced no launch. Each case reads as a sentence the
/// Closed list can show on hover or in the launch error.
public enum HistoryResumeRefusal: Error, Equatable, Sendable, CustomStringConvertible {
    /// The restore guard refused: the id is not a session id.
    case invalidSessionID
    /// The restore guard refused: a live row already holds the session (R27).
    /// The caller focuses one of these rows instead of resuming.
    case alreadyLive(focus: [LiveSessionKey])
    /// The restore guard refused: a live process holds the session under a
    /// registry row that is not listed, so there is no row to focus.
    case runningElsewhere
    /// The restore guard refused: a resume of this session was typed a moment
    /// ago and its process has not registered yet.
    case launchInFlight
    /// The restore guard refused: AgentMenu is running the session in the
    /// background, with no window open. The caller attaches a window to its
    /// tmux session instead of resuming it (R27).
    case runningDetached(launchID: String)
    /// The transcript index marked the entry not restorable.
    case notRestorable(reason: String)
    /// The profile whose store holds the transcript is no longer configured,
    /// so there is no account to resume it under.
    case unknownProfile(id: String)
    /// Claude Code is not usable (missing, disabled or unconfirmed). Only it
    /// writes the transcripts the Closed list reads.
    case agentUnavailable

    /// What the restore guard's decision means to a caller: nil when it
    /// allows the restore. The one translation, so every entry point (a
    /// History click, Reopen all, Reopen last closed) reads the guard alike.
    public init?(decision: RestoreDecision) {
        switch decision {
        case .allow: return nil
        case .refuse(.invalidSessionID): self = .invalidSessionID
        case .refuse(.alreadyLive(let focus)): self = .alreadyLive(focus: focus)
        case .refuse(.runningElsewhere): self = .runningElsewhere
        case .refuse(.launchInFlight): self = .launchInFlight
        case .refuse(.reattach(let launchID)): self = .runningDetached(launchID: launchID)
        }
    }

    public var description: String {
        switch self {
        case .invalidSessionID:
            return "that is not a session id, so it cannot be resumed"
        case .alreadyLive:
            return "that session is already running"
        case .runningElsewhere:
            return "that session is already running elsewhere (in an IDE, the desktop app or a background job), so it cannot be resumed here"
        case .launchInFlight:
            return "that session is already being resumed"
        case .runningDetached:
            return "that session is already running in the background, with no window open"
        case .notRestorable(let reason):
            return reason
        case .unknownProfile(let id):
            return "the account '\(id)' that holds this session is no longer configured"
        case .agentUnavailable:
            return "Claude Code is not available, so this session cannot be resumed"
        }
    }
}

/// A resolved history resume: everything the launch path needs, decided.
public struct HistoryResumePlan: Equatable {
    public let sessionID: String
    /// The account: the profile whose store holds the transcript (R30).
    public let profile: Profile
    /// The transcript's working directory, as recorded.
    public let directory: String
    /// The launch target whose preset applies, when the directory is one.
    public let folder: FolderTarget?
    /// The merged, manifest-checked preset, resolved through `PresetResolver`
    /// exactly as a popover launch resolves it.
    public let resolved: ResolvedPreset
    public let agent: AgentManifest
}

/// R30: the preset of a closed session AgentMenu never launched, and the guard
/// check in front of every History click. `RestoreActions` (U14) composes it with
/// the recorded preset of a session AgentMenu did launch, and the app launches
/// both through the owned path (R31).
///
/// The account is always the profile whose store holds the transcript: the
/// session's history lives there, and `--resume` looks it up in the profile the
/// process runs under. The rest of the preset comes from the launch target on
/// the transcript's folder, else the global default, merged and checked by
/// `PresetResolver` like any launch. A session AgentMenu launched itself
/// restores from its recorded preset instead (`RestoreActions.plan`).
public enum HistoryResume {
    /// - Parameters:
    ///   - agent: the Claude Code manifest if it is usable, else nil. The app
    ///     asks its registry; the plan does not look it up.
    ///   - terminalID: the terminal a launch with this preset would use,
    ///     given the folder's preset layered with this resume's own
    ///     (`AppEnvironment.terminalManifest(for:)`, which falls back to the
    ///     first usable one). It only decides whether keep-running applies.
    ///   - guardSnapshot: what is live now. The guard runs here so no caller
    ///     of the history path can forget it (KTD13).
    public static func plan(
        entry: TranscriptEntry,
        config: Config,
        agent: AgentManifest?,
        terminalID: (Preset) -> String?,
        guardSnapshot: RestoreGuardSnapshot
    ) -> Result<HistoryResumePlan, HistoryResumeRefusal> {
        if let refusal = HistoryResumeRefusal(decision: RestoreGuard.check(sessionID: entry.sessionId, snapshot: guardSnapshot)) {
            return .failure(refusal)
        }

        if case .notRestorable(let reason) = entry.restorability {
            return .failure(.notRestorable(reason: reason))
        }
        let directory: String
        switch WorkingDirectoryRule.check(entry.cwd) {
        case .success(let checked): directory = checked
        case .failure(let problem): return .failure(.notRestorable(reason: problem.reason))
        }
        guard let profile = config.profile(id: entry.profileID) else {
            return .failure(.unknownProfile(id: entry.profileID))
        }
        guard let agent, agent.id == RegistryReader.claudeAgentID else {
            return .failure(.agentUnavailable)
        }

        let folder = launchTarget(forDirectory: directory, profileID: profile.id, in: config)

        // The resume's own layer: the account and the agent. It sits where a
        // one-shot override sits, above the folder's pin, because R30 says the
        // account comes from where the transcript is, not from the folder.
        let oneShot = Preset(agent: agent.id, profile: profile.id)
        let own = (folder?.preset ?? Preset()).overlaid(with: oneShot)
        let resolved = PresetResolver.resolve(
            global: config.defaults,
            folder: folder?.preset ?? Preset(),
            oneShot: oneShot,
            agent: agent,
            terminalID: terminalID(own)
        )
        return .success(HistoryResumePlan(
            sessionID: entry.sessionId,
            profile: profile,
            directory: directory,
            folder: folder,
            resolved: resolved,
            agent: agent
        ))
    }

    /// The launch target that names `directory`, after the same normalisation
    /// `Config.folder(forPath:)` uses. Several entries may name one folder (the
    /// same project on two accounts): the one pinned to the transcript's own
    /// account is the better match for a session that ran there, else the
    /// first, as everywhere else.
    static func launchTarget(forDirectory directory: String, profileID: String, in config: Config) -> FolderTarget? {
        let normalized = FolderTarget.normalize(directory)
        let matches = config.folders.filter { $0.normalizedPath == normalized }
        return matches.first { $0.preset.profile == profileID } ?? matches.first
    }
}
