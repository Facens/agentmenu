// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// Restore actions (U14): Reopen last closed, Reopen all, a click in History and
// the host-death offer, all through the one guard (KTD13).
//
// Pure, like `RestorePlanner`: it reads no registry, runs no tmux, opens no
// terminal and has no clock. The app asks it what a restore resolves to, which
// sessions are on offer, how to batch them and how to word the result, and does
// the launching itself.

// MARK: - What a restore starts from

/// Where a restore comes from.
public enum RestoreSource: Equatable {
    /// A session AgentMenu launched and that ended: the recorded launch says
    /// everything, and the transcript index may not even have been built.
    case recorded(RestorableSession)
    /// A click on a Closed row. `recorded` is what AgentMenu knows of it when it
    /// launched it, else nil (R30).
    case history(TranscriptEntry, recorded: RestorableSession?)

    public var sessionID: String {
        switch self {
        case .recorded(let session): return session.sessionID
        case .history(let entry, _): return entry.sessionId
        }
    }
}

/// A restore, decided: everything the owned launch path needs.
public struct RestoreLaunch: Equatable {
    public enum Origin: Equatable, Sendable {
        /// The preset AgentMenu launched the session with, re-passed whole
        /// (R26, KTD14).
        case recorded
        /// A session AgentMenu never launched: the account from the profile
        /// whose store holds the transcript, the rest from the folder's launch
        /// target, else the global default (R30).
        case history
    }

    public let origin: Origin
    public let sessionID: String
    /// The account.
    public let profile: Profile
    public let directory: String
    public let folder: FolderTarget?
    /// The merged, manifest-checked preset: the one the ledger row records, so
    /// the next restore of this session re-passes it in turn.
    public let resolved: ResolvedPreset
    public let agent: AgentManifest
    /// The terminal the window opens in: the recorded one when it is still
    /// usable, else the fallback the app chose (nil when none is usable).
    public let terminalID: String?
    /// The recorded terminal is not the one this restore uses.
    public let terminalChanged: Bool
    /// The hosted launch path (keep-running), else the plain one (R15, KTD14).
    public let wantsHost: Bool

    /// `--resume <id>` and the whole resolved preset, the profile's
    /// `CLAUDE_CONFIG_DIR`, and never `--session-id` (KTD14).
    public func command(binaryPath: String, launchID: String) throws -> LaunchCommand {
        try OwnedLauncher.command(
            agent: agent,
            resolved: resolved,
            profile: profile,
            directory: directory,
            binaryPath: binaryPath,
            kind: .restore(resumedSessionID: sessionID),
            launchID: launchID
        )
    }
}

// MARK: - What a restore did

/// How one session of a Reopen all went.
public enum RestoreItemOutcome: Equatable, Sendable {
    /// Launched, and the agent registered.
    case reopened
    /// The guard found it already running (live, detached and reattached, or
    /// held elsewhere): nothing to start, and no longer waiting to be reopened.
    case alreadyRunning
    /// Not brought back. `journal` is the closed vocabulary the journal records
    /// it with; `reason` is for the person, and may name a path.
    case failed(reason: String, journal: JournalData.RestoreOutcome)

    public var isSuccess: Bool {
        if case .failed = self { return false }
        return true
    }

    public var journal: JournalData.RestoreOutcome {
        switch self {
        case .reopened: return .launched
        case .alreadyRunning: return .alreadyRunning
        case .failed(_, let journal): return journal
        }
    }
}

public struct RestoreItemResult: Equatable, Sendable {
    public let sessionID: String
    public let name: String
    public let outcome: RestoreItemOutcome

    public init(sessionID: String, name: String, outcome: RestoreItemOutcome) {
        self.sessionID = sessionID
        self.name = name
        self.outcome = outcome
    }
}

/// What starting one item of a batch produced: nothing more to wait for, or a
/// launch whose registration is still to be awaited.
public enum RestoreStart<Started> {
    case finished(RestoreItemOutcome)
    case started(Started)
}

/// Whether a restore's launch has registered, from its ledger row.
public enum RestoreRegistration: Equatable, Sendable {
    case waiting
    case registered
    case failed(reason: String)
}

/// What is on offer right now: the pending set and the closed stack, without
/// the sessions whose restore is already starting.
public struct RestoreOffer: Equatable, Sendable {
    /// What Reopen all would bring back, in the order they ended.
    public var pending: [RestorableSession]
    /// The pending set's own cause, nil with no set.
    public var pendingCause: EndCause?
    public var pendingFormedAt: Date?
    /// What Reopen last closed would restore.
    public var lastClosed: RestorableSession?
    /// How many times Reopen last closed can be repeated.
    public var closedCount: Int

    public init(
        pending: [RestorableSession] = [],
        pendingCause: EndCause? = nil,
        pendingFormedAt: Date? = nil,
        lastClosed: RestorableSession? = nil,
        closedCount: Int = 0
    ) {
        self.pending = pending
        self.pendingCause = pendingCause
        self.pendingFormedAt = pendingFormedAt
        self.lastClosed = lastClosed
        self.closedCount = closedCount
    }

    public var pendingCount: Int { pending.count }
    public var pendingIDs: Set<String> { Set(pending.map(\.sessionID)) }
}

/// The banner above the tabs (U14, F2).
public struct RestoreBannerInfo: Equatable, Sendable {
    public let count: Int
    public let message: String
    /// The set it is about: a dismissal belongs to it, so a later set shows its
    /// own banner.
    public let formedAt: Date
}

/// The one notification that follows a host death (R34).
public struct HostDeathNotification: Equatable, Sendable {
    /// Fixed, so a second posting replaces the first rather than stacking.
    public static let identifier = "host-died"
    public static let kind = "host-died"
    public static let categoryIdentifier = "dev.facens.agentmenu.host-died"
    public static let reopenAllActionIdentifier = "dev.facens.agentmenu.host-died.reopen-all"
    public static let reopenAllTitle = "Reopen all"

    public let title: String
    public let body: String
    /// Read back on a click. `NotificationClick.resolve` takes it to the Sessions
    /// tab.
    public var userInfo: [String: String] { ["kind": Self.kind] }

    /// Nil when no session ended: there is nothing to offer.
    public static func make(for notice: HostDeathNotice) -> HostDeathNotification? {
        guard notice.count > 0 else { return nil }
        return HostDeathNotification(
            title: "\(RestoreActions.sessionCount(notice.count)) ended",
            body: "AgentMenu's session host stopped unexpectedly. Your sessions are saved; Reopen all brings them back."
        )
    }
}

// MARK: - The actions

public enum RestoreActions {
    /// Reopen all launches this many at a time, and waits for each batch to come
    /// up before the next (KTD14).
    public static let batchSize = 3
    /// How long a launch is given to register before the wait gives up: the
    /// ledger's own timeout, and a moment for the sweep that notices it.
    public static let settleTimeout: TimeInterval = LaunchLedger.startTimeout + 2

    // MARK: Composing a restore

    /// Resolves a restore, after the guard (KTD13): the account, folder, preset,
    /// terminal and launch path it runs with, or why it cannot.
    ///
    /// - Parameters:
    ///   - agent: the Claude Code manifest if it is usable, else nil.
    ///   - terminalFor: the terminal a launch with this preset would use. For a
    ///     recorded session it is asked with the recorded terminal alone: the
    ///     answer is that terminal when it is still usable, else the first usable
    ///     one (`AppEnvironment.terminalManifest(for:)`).
    public static func plan(
        source: RestoreSource,
        config: Config,
        agent: AgentManifest?,
        terminalFor: (Preset) -> String?,
        guardSnapshot: RestoreGuardSnapshot
    ) -> Result<RestoreLaunch, HistoryResumeRefusal> {
        switch source {
        case .history(let entry, nil):
            return HistoryResume.plan(
                entry: entry, config: config, agent: agent, terminalID: terminalFor, guardSnapshot: guardSnapshot
            ).map { plan in
                RestoreLaunch(
                    origin: .history,
                    sessionID: plan.sessionID,
                    profile: plan.profile,
                    directory: plan.directory,
                    folder: plan.folder,
                    resolved: plan.resolved,
                    agent: plan.agent,
                    terminalID: terminalFor(plan.folder?.preset ?? Preset()),
                    terminalChanged: false,
                    wantsHost: plan.resolved.keepRunning == true
                )
            }
        case .history(let entry, let recorded?):
            return planRecorded(
                recorded, entry: entry, config: config, agent: agent, terminalFor: terminalFor, guardSnapshot: guardSnapshot
            )
        case .recorded(let session):
            return planRecorded(
                session, entry: nil, config: config, agent: agent, terminalFor: terminalFor, guardSnapshot: guardSnapshot
            )
        }
    }

    private static func planRecorded(
        _ session: RestorableSession,
        entry: TranscriptEntry?,
        config: Config,
        agent: AgentManifest?,
        terminalFor: (Preset) -> String?,
        guardSnapshot: RestoreGuardSnapshot
    ) -> Result<RestoreLaunch, HistoryResumeRefusal> {
        if let refusal = HistoryResumeRefusal(decision: RestoreGuard.check(sessionID: session.sessionID, snapshot: guardSnapshot)) {
            return .failure(refusal)
        }
        if let entry, case .notRestorable(let reason) = entry.restorability {
            return .failure(.notRestorable(reason: reason))
        }
        let directory: String
        switch WorkingDirectoryRule.check(session.cwd) {
        case .success(let checked): directory = checked
        case .failure(let problem): return .failure(.notRestorable(reason: problem.reason))
        }
        guard let profile = recordedProfile(of: session, in: config) else {
            return .failure(.unknownProfile(id: session.profileID ?? "unknown"))
        }
        guard let agent, agent.id == RegistryReader.claudeAgentID else {
            return .failure(.agentUnavailable)
        }

        // The recorded preset is the only layer: it is what the launch ran
        // with, already merged, so nothing from today's configuration leaks in
        // (a model nobody passed stays unpassed). Keep-running is the recorded
        // value, else whether the launch ended up hosted.
        let keepRunning = session.preset.keepRunning ?? (session.hostSocket != nil)
        var recorded = session.preset
        recorded.agent = agent.id
        recorded.profile = profile.id
        recorded.keepRunning = keepRunning
        let terminal = terminalFor(Preset(terminal: session.terminalID))
        recorded.terminal = terminal ?? session.terminalID
        let resolved = PresetResolver.resolve(
            global: Preset(), folder: Preset(), oneShot: recorded, agent: agent, terminalID: terminal
        )
        return .success(RestoreLaunch(
            origin: .recorded,
            sessionID: session.sessionID,
            profile: profile,
            directory: directory,
            folder: nil,
            resolved: resolved,
            agent: agent,
            terminalID: terminal,
            terminalChanged: terminal != nil && terminal != session.terminalID,
            wantsHost: resolved.keepRunning == true
        ))
    }

    /// The account a session ran under: its recorded profile, else the profile
    /// that names the config directory it ran in.
    static func recordedProfile(of session: RestorableSession, in config: Config) -> Profile? {
        if let id = session.profileID, let profile = config.profile(id: id) { return profile }
        guard let directory = session.configDirectory else { return nil }
        let wanted = URL(fileURLWithPath: directory).standardizedFileURL.path
        return config.profiles.first { $0.expandedConfigDirectory.standardizedFileURL.path == wanted }
    }

    // MARK: What AgentMenu knows of a session

    /// The record of a session AgentMenu launched, from the pending set, the
    /// closed stack, else the ledger's latest row for it (the stack keeps 50 and
    /// the ledger 200 launches): what a click on its Closed row restores from
    /// (R26). Nil for a session AgentMenu never launched.
    public static func recordedSession(
        for sessionID: String, state: RestoreState, ledger: LaunchLedger
    ) -> RestorableSession? {
        if let session = state.pending?.sessions.first(where: { $0.sessionID == sessionID }) { return session }
        if let session = state.closed.first(where: { $0.sessionID == sessionID }) { return session }
        let row = ledger.rows
            .filter { $0.agentID == RegistryReader.claudeAgentID && RestorePlanner.resumableSessionID(of: $0) == sessionID }
            .max { ($0.endedAt ?? $0.startedAt) < ($1.endedAt ?? $1.startedAt) }
        guard let row else { return nil }
        return RestorableSession(
            row: row, sessionID: sessionID, endedAt: row.endedAt ?? row.startedAt, cause: row.endCause ?? .unexplained
        )
    }

    /// A session's name for a result strip: AgentMenu's rename, else the
    /// transcript's title when the index has it, else its folder.
    public static func displayName(of session: RestorableSession, entry: TranscriptEntry?, rename: String?) -> String {
        if let rename = rename.trimmedNonEmpty { return rename }
        if let entry { return entry.title().text }
        return SessionRowWording.folderName(session.cwd) ?? "Session"
    }

    // MARK: What is on offer

    /// The ids of restores whose launch is still waiting to register. A session
    /// in this set stays in the pending set and on the closed stack until it is
    /// live (the planner drops it then), so a restore that never comes up is not
    /// lost (R35), and is not offered a second time while it starts.
    public static func startingSessionIDs(in ledger: LaunchLedger) -> Set<String> {
        var ids = Set<String>()
        for row in ledger.rows where row.isActive && row.phase == .starting {
            ids.insert(row.pinnedOrResumedID)
        }
        return ids
    }

    public static func offer(state: RestoreState, starting: Set<String>) -> RestoreOffer {
        let pending = (state.pending?.sessions ?? []).filter { !starting.contains($0.sessionID) }
        let closed = state.closed.filter { !starting.contains($0.sessionID) }
        return RestoreOffer(
            pending: pending,
            pendingCause: pending.isEmpty ? nil : state.pending?.cause,
            pendingFormedAt: pending.isEmpty ? nil : state.pending?.formedAt,
            lastClosed: closed.first,
            closedCount: closed.count
        )
    }

    // MARK: The banner

    /// The post-restart banner: shown while sessions wait in the pending set that
    /// the user did not put there themselves, until they are reopened or the
    /// user dismisses it. A Quit all is the user's own act and has the header
    /// menu; the banner is for a restart, a crash or a host that died.
    public static func banner(offer: RestoreOffer, dismissedFormedAt: Date?) -> RestoreBannerInfo? {
        guard offer.pendingCount > 0, let cause = offer.pendingCause, let formed = offer.pendingFormedAt else { return nil }
        guard cause != .together, formed != dismissedFormedAt else { return nil }
        let count = sessionCount(offer.pendingCount)
        let message: String
        switch cause {
        case .powerOff: message = "\(count) \(offer.pendingCount == 1 ? "was" : "were") running when your Mac last shut down."
        case .hostDied: message = "\(count) ended when AgentMenu's session host stopped."
        default: message = "\(count) ended unexpectedly."
        }
        return RestoreBannerInfo(count: offer.pendingCount, message: message, formedAt: formed)
    }

    public static func sessionCount(_ count: Int) -> String {
        count == 1 ? "1 session" : "\(count) sessions"
    }

    // MARK: Batches and results

    /// Reopen all's batches: three, then the rest.
    public static func batches<Item>(_ items: [Item], size: Int = batchSize) -> [[Item]] {
        guard size > 0 else { return [items] }
        return stride(from: 0, to: items.count, by: size).map { Array(items[$0..<min($0 + size, items.count)]) }
    }

    /// Runs a Reopen all: in batches, each started in order (one terminal
    /// window at a time, since two osascript calls racing to open windows in a
    /// terminal that is not yet running make two), then every launch of the
    /// batch awaited before the next batch starts.
    ///
    /// Results come back in item order, one per item, whatever happened: a
    /// failure never stops the rest (R35).
    public static func run<Item, Started>(
        items: [Item],
        size: Int = batchSize,
        sessionID: (Item) -> String,
        name: (Item) -> String,
        start: (Item) async -> RestoreStart<Started>,
        settle: (Started) async -> RestoreItemOutcome
    ) async -> [RestoreItemResult] {
        var results: [RestoreItemResult] = []
        for batch in batches(items, size: size) {
            var waiting: [(item: Item, started: Started)] = []
            var batchResults: [String: RestoreItemOutcome] = [:]
            for item in batch {
                switch await start(item) {
                case .finished(let outcome): batchResults[sessionID(item)] = outcome
                case .started(let started): waiting.append((item, started))
                }
            }
            for entry in waiting {
                batchResults[sessionID(entry.item)] = await settle(entry.started)
            }
            for item in batch {
                results.append(RestoreItemResult(
                    sessionID: sessionID(item),
                    name: name(item),
                    outcome: batchResults[sessionID(item)]
                        ?? .failed(reason: "It could not be started.", journal: .failed)
                ))
            }
        }
        return results
    }

    /// The strip a Reopen all leaves: how many, and each failure with its reason
    /// (R35).
    public static func summary(of results: [RestoreItemResult]) -> ReopenAllSummary {
        ReopenAllSummary(
            total: results.count,
            failures: results.compactMap { result in
                if case .failed(let reason, _) = result.outcome {
                    return ReopenAllSummary.Failure(name: result.name, reason: reason)
                }
                return nil
            }
        )
    }

    /// What a Reopen all changes in the store (R24, R35): a restore was tried, so
    /// a later event no longer replaces what is left of the set; the sessions
    /// that are running again leave both lists; the ones that failed stay in
    /// both, for a later try.
    public static func apply(_ results: [RestoreItemResult], to state: inout RestoreState) {
        state.markPendingTouched()
        state.restored(Set(results.filter { $0.outcome.isSuccess }.map(\.sessionID)))
    }

    /// A refusal at the guard, as one session's result in a Reopen all. An
    /// owned session that is running with no window is not here: the app
    /// attaches a window to it (R27).
    public static func outcome(for refusal: HistoryResumeRefusal) -> RestoreItemOutcome {
        switch refusal {
        case .alreadyLive, .runningElsewhere, .runningDetached:
            return .alreadyRunning
        default:
            return .failed(reason: sentence(refusal.description), journal: JournalData.RestoreOutcome(refusal: refusal))
        }
    }

    /// The same, knowing the ledger: a restore that failed to start a moment ago
    /// is still counted as in flight for two minutes (the agent may only have
    /// been slow), and the answer to a retry in that window is the failure, not
    /// "already being resumed" (R35).
    public static func outcome(
        for refusal: HistoryResumeRefusal, sessionID: String, ledger: LaunchLedger
    ) -> RestoreItemOutcome {
        if case .launchInFlight = refusal, let reason = recentFailure(of: sessionID, in: ledger) {
            return .failed(reason: reason, journal: .alreadyRunning)
        }
        return outcome(for: refusal)
    }

    /// Why a retry is refused after a restore of this session failed to start, or
    /// nil when none did.
    public static func recentFailure(of sessionID: String, in ledger: LaunchLedger) -> String? {
        let failed = ledger.rows.contains { row in
            guard row.isActive, row.kind == .restore(resumedSessionID: sessionID) else { return false }
            if case .failed = row.phase { return true }
            return false
        }
        guard failed else { return nil }
        return "It failed to start a moment ago, and AgentMenu is still waiting in case it was only slow. "
            + "Try again in a couple of minutes."
    }

    /// "that session is already…" as a sentence for a strip.
    private static func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        let capitalised = first.uppercased() + text.dropFirst()
        return capitalised.hasSuffix(".") ? capitalised : capitalised + "."
    }

    // MARK: Registration

    /// Where a restore's launch is, from its ledger row: still waiting, up, or
    /// failed with why. A row that is gone, or ended before it registered, is a
    /// failure too.
    public static func registration(of row: LedgerRow?) -> RestoreRegistration {
        guard let row, !row.dismissed else {
            return .failed(reason: restoreFailure(LaunchLedger.sessionEndedReason))
        }
        switch row.phase {
        case .live:
            return .registered
        case .failed(let reason):
            return .failed(reason: restoreFailure(reason))
        case .starting:
            return row.endedAt != nil ? .failed(reason: restoreFailure(LaunchLedger.sessionEndedReason)) : .waiting
        }
    }

    /// The ledger's reason for a launch that never came up, as it reads for a
    /// restore: Claude Code prints "No conversation found" and exits, which
    /// nothing can read, so the reason says what that looks like (R35).
    public static func restoreFailure(_ ledgerReason: String) -> String {
        guard ledgerReason == LaunchLedger.timeoutReason || ledgerReason == LaunchLedger.sessionEndedReason else {
            return ledgerReason
        }
        return ledgerReason + " Claude Code may not have found that conversation to resume."
    }

    // MARK: The session host

    /// The host's recorded death may be forgotten once nothing is left to be
    /// explained by it: no hosted launch still running (it is about to end under
    /// a dead server) and none ended and waiting to be classified. Cleared
    /// earlier, a session still inside the planner's settle window would no
    /// longer read as host-died and would land on the closed stack (AE10).
    public static func mayClearHostRecord(ledger: LaunchLedger) -> Bool {
        !ledger.rows.contains { $0.isHosted && ($0.isActive || $0.awaitsClassification) }
    }
}
