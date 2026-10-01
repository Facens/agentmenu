// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - A value the store keeps without understanding

/// A JSON value kept verbatim. A ledger row carries the fields a newer or
/// older build wrote that this one does not model, so rewriting the row here
/// does not drop them (the promise the store already makes for top-level
/// keys, applied one level down).
public enum StoredJSON: Equatable, Sendable {
    case null
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case string(String)
    case array([StoredJSON])
    case object([String: StoredJSON])

    init?(_ value: Any) {
        switch value {
        case is NSNull:
            self = .null
        case let string as String:
            self = .string(string)
        case let number as NSNumber:
            if isJSONBoolean(number) {
                self = .bool(number.boolValue)
            } else if number.doubleValue.truncatingRemainder(dividingBy: 1) == 0, abs(number.doubleValue) < 9e15 {
                self = .integer(number.intValue)
            } else {
                self = .number(number.doubleValue)
            }
        case let array as [Any]:
            self = .array(array.compactMap(StoredJSON.init))
        case let object as [String: Any]:
            self = .object(object.compactMapValues(StoredJSON.init))
        default:
            return nil
        }
    }

    var foundation: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let value): return value
        case .integer(let value): return value
        case .number(let value): return value
        case .string(let value): return value
        case .array(let values): return values.map(\.foundation)
        case .object(let values): return values.mapValues(\.foundation)
        }
    }
}

// MARK: - One launch

/// One launch AgentMenu made, from the click until the session it started is
/// gone (KTD12). The record U12 and U13 classify from.
///
/// **Identity (KTD7, KTD14).** `launchID` is a fresh lowercase UUID. For a
/// fresh launch it is also the session id the agent is pinned to
/// (`--session-id`), so the registry row that appears carries it. For a
/// restore it is only the tmux session name: the agent is resumed
/// (`--resume`, never `--session-id`), keeps the resumed id, and is matched by
/// that. Once matched the row is followed by (config directory, pid,
/// `procStart`) and never again by session id, which `/clear` changes in
/// place; `lastSessionID` records the latest id seen.
public struct LedgerRow: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        /// A new session, pinned to `launchID`.
        case fresh
        /// A resume of an existing session. Never carries `--session-id`.
        case restore(resumedSessionID: String)
    }

    public enum Phase: Equatable, Sendable {
        /// Launched, and no registry row has been matched yet (R36).
        case starting
        /// Matched: `pid`, `procStart` and the registry's config directory
        /// are set, and the row is followed by them.
        case live
        /// Not matched within `LaunchLedger.startTimeout`. Still matched
        /// later if the agent turns out only to have been slow.
        case failed(reason: String)
    }

    public var launchID: String
    public var id: String { launchID }
    public var kind: Kind
    public var agentID: String
    public var profileID: String?
    /// The config directory the launch ran under; replaced, once matched, by
    /// the directory of the registry the row was found in, which is half of
    /// its key.
    public var configDirectory: String?
    public var cwd: String
    /// The resolved preset, so a restore can re-pass the whole of it (KTD14).
    public var preset: Preset
    /// The terminal manifest id the window was opened in.
    public var terminalID: String
    /// The tmux socket the session runs under; nil for a plain launch, which
    /// records no host.
    public var hostSocket: String?
    public var startedAt: Date
    /// When an AgentMenu relaunch adopted this row because its tmux session
    /// was still alive: the start of its 15 seconds is then this, not
    /// `startedAt`, which the crash made meaningless.
    public var adoptedAt: Date?
    public var phase: Phase
    public var pid: Int32?
    public var procStart: Int?
    public var lastSessionID: String?
    /// Set when the session is gone, by `reconcile` alone.
    public var endedAt: Date?
    /// Why it ended, as far as AgentMenu knows. U12 records `individual` or
    /// `together` before it signals a quit, so the session may still be live
    /// with a cause set: the cause marks intent, `endedAt` marks the end. U13
    /// fills the rest and classifies.
    public var endCause: EndCause?
    /// When `endCause` was recorded, for a cause recorded before the session
    /// ended (a quit, the power-off notification). It tells which event a
    /// session belongs to when the rest of that event ends after AgentMenu was
    /// restarted (U13); nil for a cause that was classified, and for rows
    /// written before this field existed.
    public var causeRecordedAt: Date?
    /// The user dismissed a Failed-to-start row.
    public var dismissed: Bool
    /// U13 has decided what this ended row became (the pending reopen set, the
    /// closed stack, or neither), so no later sweep decides it again.
    public var classified: Bool
    /// Fields in the stored row this build does not model.
    var extra: [String: StoredJSON]

    public init(
        launchID: String,
        kind: Kind = .fresh,
        agentID: String = RegistryReader.claudeAgentID,
        profileID: String? = nil,
        configDirectory: String? = nil,
        cwd: String,
        preset: Preset = Preset(),
        terminalID: String,
        hostSocket: String? = nil,
        startedAt: Date,
        adoptedAt: Date? = nil,
        phase: Phase = .starting,
        pid: Int32? = nil,
        procStart: Int? = nil,
        lastSessionID: String? = nil,
        endedAt: Date? = nil,
        endCause: EndCause? = nil,
        causeRecordedAt: Date? = nil,
        dismissed: Bool = false,
        classified: Bool = false
    ) {
        self.launchID = launchID
        self.kind = kind
        self.agentID = agentID
        self.profileID = profileID
        self.configDirectory = configDirectory
        self.cwd = cwd
        self.preset = preset
        self.terminalID = terminalID
        self.hostSocket = hostSocket
        self.startedAt = startedAt
        self.adoptedAt = adoptedAt
        self.phase = phase
        self.pid = pid
        self.procStart = procStart
        self.lastSessionID = lastSessionID
        self.endedAt = endedAt
        self.endCause = endCause
        self.causeRecordedAt = causeRecordedAt
        self.dismissed = dismissed
        self.classified = classified
        self.extra = [:]
    }

    public var isHosted: Bool { hostSocket != nil }

    /// Not over, and not dismissed.
    public var isActive: Bool { endedAt == nil && !dismissed }

    /// Over, and not yet classified (U13).
    public var awaitsClassification: Bool { endedAt != nil && !dismissed && !classified }

    /// The registry key, once matched.
    public var liveKey: LiveSessionKey? {
        guard let pid, let procStart else { return nil }
        return LiveSessionKey(configDirectory: configDirectory, pid: pid, procStart: procStart)
    }

    /// The session id a restore of this launch resumes: the latest the agent
    /// had, else the one it was pinned or resumed to. Not checked to be a
    /// session id (`RestorePlanner.resumableSessionID(of:)` does that).
    public var resumableSessionID: String {
        lastSessionID ?? pinnedOrResumedID
    }

    /// The id a restore guard must treat as being started right now (R27).
    var pinnedOrResumedID: String {
        switch kind {
        case .fresh: return launchID
        case .restore(let id): return id
        }
    }

    /// The start of the clock the 15 seconds run on.
    var clockStart: Date { adoptedAt.map { max($0, startedAt) } ?? startedAt }
}

// MARK: - What reconcile reads

/// One look at the world, for `LaunchLedger.reconcile`.
public struct LedgerObservation {
    /// The registry's live rows (any agent; only Claude Code's are matched).
    public var live: [LiveSession]
    /// The host's panes and clients; nil when it was not asked or no server
    /// answers, which reads as "no information", never as "no sessions".
    public var host: HostSnapshot?
    public var now: Date
    /// Whether this exact process (pid and start time) is still running. A
    /// row that is missing from `live` ends only when this says no: a profile
    /// removed from Settings drops its registry from the list while its
    /// sessions go on.
    public var isSameProcessRunning: (LiveSessionKey) -> Bool

    public init(
        live: [LiveSession],
        host: HostSnapshot? = nil,
        now: Date,
        isSameProcessRunning: @escaping (LiveSessionKey) -> Bool
    ) {
        self.live = live
        self.host = host
        self.now = now
        self.isSameProcessRunning = isSameProcessRunning
    }
}

// MARK: - What the app knows about one owned row

/// What a click on an owned row needs (R8, R37): where the session runs, which
/// terminal holds its window, and whether any window does.
public struct OwnedSessionInfo: Equatable, Sendable {
    /// The tmux session it runs in; nil for a plain launch, which has none to
    /// attach to.
    public let launchID: String?
    /// The terminal manifest id the launch recorded; nil when ownership came
    /// from the pane alone and no ledger row is left.
    public let terminalID: String?
    public let cwd: String?
    /// Hosted, and no client is attached: the Detached marker (R9).
    public let isDetached: Bool
    /// The tty of the terminal tab showing the session, which is what a
    /// terminal knows the tab by (KTD10).
    public let clientTTY: String?

    public var isHosted: Bool { launchID != nil }

    public init(launchID: String?, terminalID: String?, cwd: String?, isDetached: Bool, clientTTY: String?) {
        self.launchID = launchID
        self.terminalID = terminalID
        self.cwd = cwd
        self.isDetached = isDetached
        self.clientTTY = clientTTY
    }
}

// MARK: - The ledger

/// Every launch AgentMenu made, and the pure rules that follow each one from
/// Starting to Live to ended (R22, R36, KTD7, KTD12).
///
/// A value over injected inputs: it reads no registry, runs no tmux and has no
/// clock. The app feeds it the live list, a host snapshot and the time; the
/// store persists it.
public struct LaunchLedger: Equatable, Sendable {
    /// How long a launch has to register before it is Failed to start (R36).
    public static let startTimeout: TimeInterval = 15
    /// A launch that was called failed can still turn out to have been only
    /// slow (a trust prompt, a cold login shell); it keeps being matched for
    /// this long after its clock started.
    public static let lateMatchWindow: TimeInterval = 120
    /// Ended and dismissed rows are kept this long for U13 to classify.
    public static let endedRetention: TimeInterval = 30 * 24 * 3600
    public static let maximumRows = 200

    public static let timeoutReason = "The agent did not start within 15 seconds."
    public static let sessionEndedReason = "The session ended before the agent registered."

    public private(set) var rows: [LedgerRow]

    public init(rows: [LedgerRow] = []) {
        self.rows = rows
    }

    public var isEmpty: Bool { rows.isEmpty }

    /// A fresh launch id: a lowercase hyphenated UUID, the only spelling
    /// `SessionIdentifier.isValid` and Claude Code's `--session-id` accept.
    public static func newLaunchID() -> String {
        UUID().uuidString.lowercased()
    }

    // MARK: Lookup

    public func row(launchID: String) -> LedgerRow? {
        rows.first { $0.launchID == launchID }
    }

    /// The active row following this registry row, or the active hosted row
    /// whose pane the host says it is in.
    public func row(for key: LiveSessionKey) -> LedgerRow? {
        rows.first { $0.isActive && $0.liveKey == key }
    }

    /// Rows with a tmux session that may still be running: the ones the host
    /// has to be asked about.
    public var hasActiveHostedRows: Bool {
        rows.contains { $0.isActive && $0.isHosted }
    }

    /// Ended rows U13 has not classified yet: the settle window is a wait on
    /// the clock, so something has to keep looking while one exists.
    public var hasRowsAwaitingClassification: Bool {
        rows.contains { $0.awaitsClassification }
    }

    /// Rows still waiting to register, which a timer has to keep evaluating
    /// although no registry file has changed: Starting ones, and Failed ones
    /// only while they can still be matched (`lateMatchWindow`). A failed row
    /// nobody dismissed must not keep a timer running for ever.
    public func hasRowsAwaitingRegistration(now: Date) -> Bool {
        rows.contains { row in
            guard row.isActive else { return false }
            switch row.phase {
            case .starting: return true
            case .failed: return now.timeIntervalSince(row.clockStart) <= Self.lateMatchWindow
            case .live: return false
            }
        }
    }

    // MARK: Changing

    /// Records a launch. A row with the same launch id (a restore that reuses
    /// one) is replaced.
    public mutating func begin(_ row: LedgerRow, now: Date) {
        rows.removeAll { $0.launchID == row.launchID }
        rows.append(row)
        prune(now: now)
    }

    public mutating func update(launchID: String, _ change: (inout LedgerRow) -> Void) {
        guard let index = rows.firstIndex(where: { $0.launchID == launchID }) else { return }
        change(&rows[index])
    }

    /// The user dismissed a Failed-to-start row (R36).
    public mutating func dismiss(launchID: String) {
        update(launchID: launchID) { $0.dismissed = true }
    }

    /// Records why the live row following `key` is about to end, before the
    /// signal that ends it is sent (KTD11), so the classification never has
    /// to guess. Only an active row takes a cause: one that has ended was
    /// classified from what was seen. `at` is when, for U13 to tell one event's
    /// sessions from another's. Returns the launch ids changed.
    @discardableResult
    public mutating func recordCause(_ cause: EndCause, for keys: [LiveSessionKey], at date: Date? = nil) -> [String] {
        let wanted = Set(keys)
        var changed: [String] = []
        for index in rows.indices {
            guard rows[index].isActive, rows[index].phase == .live,
                  let key = rows[index].liveKey, wanted.contains(key),
                  rows[index].endCause != cause
            else { continue }
            rows[index].endCause = cause
            rows[index].causeRecordedAt = date
            changed.append(rows[index].launchID)
        }
        return changed
    }

    /// Records `cause` for every live row that has none yet: the whole live
    /// owned set at once, for the power-off notification (KTD12). A row that
    /// already carries a cause keeps it: a quit in progress is the user's
    /// intent, and the Mac going down does not change it.
    @discardableResult
    public mutating func recordCauseForUnexplainedLiveRows(_ cause: EndCause, at date: Date? = nil) -> [String] {
        var changed: [String] = []
        for index in rows.indices where rows[index].isActive && rows[index].phase == .live && rows[index].endCause == nil {
            rows[index].endCause = cause
            rows[index].causeRecordedAt = date
            changed.append(rows[index].launchID)
        }
        return changed
    }

    /// Takes back every live row's `cause`, for a notification that was
    /// followed by no shutdown (a logout somebody cancelled).
    @discardableResult
    public mutating func clearCauseOnLiveRows(_ cause: EndCause) -> [String] {
        var changed: [String] = []
        for index in rows.indices where rows[index].isActive && rows[index].endCause == cause {
            rows[index].endCause = nil
            rows[index].causeRecordedAt = nil
            changed.append(rows[index].launchID)
        }
        return changed
    }

    /// Takes back the `individual` or `together` cause of a live row whose quit
    /// is over: recorded longer ago than `SessionQuitter` follows a quit
    /// (`olderThan`), and the process still running. The quitter forgets a quit
    /// when AgentMenu exits, so the cause it recorded would otherwise stay on a
    /// session that ignored the signal, and its later ending, an `/exit` or a
    /// closed window, would be read as the user's quit. A row that says nothing
    /// of when its cause was recorded is left alone. Returns the launch ids
    /// changed.
    ///
    /// Call it after `reconcile`, so a row still active is one whose process
    /// is running.
    @discardableResult
    public mutating func releaseStaleQuitCauses(
        now: Date, olderThan: TimeInterval = SessionQuitter.giveUpDelay
    ) -> [String] {
        var changed: [String] = []
        for index in rows.indices where rows[index].isActive && rows[index].phase == .live {
            guard rows[index].endCause == .individual || rows[index].endCause == .together,
                  let recorded = rows[index].causeRecordedAt,
                  now.timeIntervalSince(recorded) > olderThan
            else { continue }
            rows[index].endCause = nil
            rows[index].causeRecordedAt = nil
            changed.append(rows[index].launchID)
        }
        return changed
    }

    /// Takes back a cause recorded for a quit that did not end the session,
    /// when it is still the one recorded.
    public mutating func clearCause(_ cause: EndCause, for key: LiveSessionKey) {
        for index in rows.indices where rows[index].isActive && rows[index].liveKey == key && rows[index].endCause == cause {
            rows[index].endCause = nil
            rows[index].causeRecordedAt = nil
        }
    }

    /// Records what U13 decided for an ended row. `cause` fills the slot only
    /// when no cause was recorded before the end: a recorded intent
    /// (`individual`, `together`) is history and stays as it was.
    public mutating func markClassified(launchID: String, cause: EndCause?) {
        update(launchID: launchID) { row in
            row.classified = true
            if row.endCause == nil, let cause { row.endCause = cause }
        }
    }

    /// Drops dismissed rows and rows that ended long ago, and keeps the
    /// ledger from growing without bound.
    public mutating func prune(now: Date) {
        rows.removeAll { row in
            if row.dismissed, row.endedAt == nil { return true }
            if let ended = row.endedAt, now.timeIntervalSince(ended) > Self.endedRetention { return true }
            return false
        }
        if rows.count > Self.maximumRows {
            // Oldest ended rows first; an active row is never dropped here.
            let overflow = rows.count - Self.maximumRows
            let droppable = rows.enumerated()
                .filter { $0.element.endedAt != nil }
                .sorted { ($0.element.endedAt ?? .distantPast) < ($1.element.endedAt ?? .distantPast) }
                .prefix(overflow)
                .map(\.offset)
            let drop = Set(droppable)
            rows = rows.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        }
    }

    // MARK: Adoption (U11 step 7)

    /// After an AgentMenu crash or relaunch: a row still waiting to register
    /// whose tmux session has a live pane is adopted — kept, with its 15
    /// seconds starting now, and never relaunched. A launch that is gone from
    /// the host is left alone and fails on its own timer. Returns the launch
    /// ids adopted.
    @discardableResult
    public mutating func adopt(host: HostSnapshot?, now: Date) -> [String] {
        guard let host else { return [] }
        var adopted: [String] = []
        for index in rows.indices {
            let row = rows[index]
            guard row.isActive, row.isHosted else { continue }
            switch row.phase {
            case .live: continue
            case .starting, .failed: break
            }
            guard host.panes.contains(where: { $0.sessionName == row.launchID && !$0.isDead }) else { continue }
            rows[index].adoptedAt = now
            if case .failed = rows[index].phase { rows[index].phase = .starting }
            adopted.append(row.launchID)
        }
        return adopted
    }

    // MARK: Reconcile

    /// Matches waiting launches to registry rows, follows matched ones, fails
    /// the ones that never registered and ends the ones that are gone.
    /// Returns whether any row changed.
    ///
    /// - **Match (KTD7).** A fresh launch by its pinned session id; a restore
    ///   by its resumed id; either, when hosted, by tty — the process's tty is
    ///   a pane of that launch's tmux session. Id first, then tty. The
    ///   registry's own `tmux` field is never consulted. The config directory
    ///   is *not* compared: the launch spelled it one way and the reader
    ///   resolves it another (profile root, symlinks), and a pinned id is
    ///   unique anyway.
    /// - **Follow.** A matched row is found again by (config directory, pid,
    ///   `procStart`); `/clear` changes the session id, which only updates
    ///   `lastSessionID`.
    /// - **End.** A followed row that is no longer listed ends only when its
    ///   process is not running. Nothing is classified here (U13).
    /// - **Fail (R36).** Unmatched 15 seconds after its clock started: Failed
    ///   to start, with "the session ended before the agent registered" when
    ///   the host is known and holds no session of that name, else a
    ///   timeout.
    public mutating func reconcile(_ observation: LedgerObservation) -> Bool {
        let before = rows
        let now = observation.now
        let candidates = observation.live.filter(\.isClaudeCode)
        let listedKeys = Set(candidates.map(\.key))

        var claimed = Set(rows.compactMap { $0.isActive && $0.phase == .live ? $0.liveKey : nil })

        for index in rows.indices {
            guard rows[index].isActive else { continue }

            switch rows[index].phase {
            case .live:
                guard let key = rows[index].liveKey else { continue }
                if listedKeys.contains(key) {
                    if let session = candidates.first(where: { $0.key == key }),
                       let id = session.sessionId, !id.isEmpty, rows[index].lastSessionID != id {
                        rows[index].lastSessionID = id
                    }
                } else if !observation.isSameProcessRunning(key) {
                    rows[index].endedAt = now
                }

            case .starting, .failed:
                let row = rows[index]
                let age = now.timeIntervalSince(row.clockStart)
                // Past the window a failed row is matched by pane only: a
                // pinned or resumed id this long after the fact could as well
                // be the user resuming the session by hand.
                let withinWindow: Bool
                if case .failed = row.phase { withinWindow = age <= Self.lateMatchWindow } else { withinWindow = true }

                if let session = Self.match(
                    row, among: candidates, claimed: claimed, host: observation.host, withinWindow: withinWindow
                ) {
                    claimed.insert(session.key)
                    rows[index].phase = .live
                    rows[index].configDirectory = session.key.configDirectory ?? row.configDirectory
                    rows[index].pid = session.key.pid
                    rows[index].procStart = session.key.procStart
                    if let id = session.sessionId, !id.isEmpty { rows[index].lastSessionID = id }
                    continue
                }

                if case .starting = row.phase, age >= Self.startTimeout {
                    let vanished = row.isHosted
                        && observation.host.map { !$0.panes.contains { $0.sessionName == row.launchID && !$0.isDead } } == true
                    rows[index].phase = .failed(reason: vanished ? Self.sessionEndedReason : Self.timeoutReason)
                }
            }
        }
        return rows != before
    }

    private static func match(
        _ row: LedgerRow,
        among candidates: [LiveSession],
        claimed: Set<LiveSessionKey>,
        host: HostSnapshot?,
        withinWindow: Bool
    ) -> LiveSession? {
        let free = candidates.filter { !claimed.contains($0.key) }
        let wanted = row.pinnedOrResumedID
        if withinWindow, let byID = free.first(where: { $0.sessionId == wanted }) { return byID }
        // A pane belongs to a tmux session named by the launch id, so a tty
        // match cannot be a stranger: it holds however late the agent came.
        if row.isHosted, let host,
           let byTTY = free.first(where: { host.sessionName(forPaneTTY: $0.tty) == row.launchID }) {
            return byTTY
        }
        return nil
    }

    // MARK: What the rest of the app reads

    /// Ownership for the snapshot (R9, KTD7): every live row the ledger
    /// follows, and every row whose process sits in a pane of the host
    /// whatever the ledger says. Hosted and with no client attached is
    /// `.detached`; an owned session with no host information, or a plain one,
    /// is `.attached`.
    public func ownedAttachments(live: [LiveSession], host: HostSnapshot?) -> [LiveSessionKey: WindowAttachment] {
        var owned: [LiveSessionKey: WindowAttachment] = [:]
        let listed = Set(live.map(\.key))

        func attachment(hostedAs launchID: String?) -> WindowAttachment {
            guard let launchID, let host else { return .attached }
            return host.isDetached(launchID) ? .detached : .attached
        }

        for row in rows where row.isActive && row.phase == .live {
            guard let key = row.liveKey, listed.contains(key) else { continue }
            owned[key] = attachment(hostedAs: row.isHosted ? row.launchID : nil)
        }
        if let host {
            for (key, launchID) in host.launchIDs(for: live) where owned[key] == nil {
                owned[key] = attachment(hostedAs: launchID)
            }
        }
        return owned
    }

    /// The tmux session a live row runs in: from the ledger, else from its
    /// pane. Nil for a plain or unowned session.
    public func launchID(for session: LiveSession, host: HostSnapshot?) -> String? {
        if let row = row(for: session.key), row.isHosted { return row.launchID }
        return host?.sessionName(forPaneTTY: session.tty)
    }

    /// Whether the session is owned and, if so, how it is hosted: by the
    /// ledger row that follows it, or by the pane its process sits in (KTD7).
    /// Nil for a session AgentMenu did not launch.
    public func ownership(of session: LiveSession, host: HostSnapshot?) -> OwnedSessionInfo? {
        let row = row(for: session.key)
        let launchID = (row?.isHosted == true ? row?.launchID : nil)
            ?? host?.sessionName(forPaneTTY: session.tty)
        guard row != nil || launchID != nil else { return nil }
        return OwnedSessionInfo(
            launchID: launchID,
            terminalID: row?.terminalID,
            cwd: row?.cwd ?? session.cwd,
            isDetached: launchID.map { host?.isDetached($0) ?? false } ?? false,
            clientTTY: launchID.flatMap { host?.clientTTY(for: $0) }
        )
    }

    /// Launches with no live row yet, or that never got one (R36), as the
    /// Sessions list draws them.
    public func pendingLaunches() -> [PendingLaunch] {
        rows.compactMap { row in
            guard row.isActive else { return nil }
            let phase: PendingLaunch.Phase
            switch row.phase {
            case .live: return nil
            case .starting: phase = .starting
            case .failed(let reason): phase = .failedToStart(reason: reason)
            }
            return PendingLaunch(
                id: row.launchID,
                title: SessionRowWording.folderName(row.cwd) ?? "New session",
                folderPath: row.cwd.isEmpty ? nil : FolderTarget.normalize(row.cwd),
                profileID: row.profileID,
                phase: phase
            )
        }
    }

    /// Session ids the restore guard must treat as being started right now
    /// (KTD13): launches still waiting to register, and failed ones inside the
    /// late-match window, whose agent may yet appear.
    public func inFlightSessionIDs(now: Date) -> Set<String> {
        var ids = Set<String>()
        for row in rows where row.isActive {
            switch row.phase {
            case .live:
                continue
            case .starting:
                ids.insert(row.pinnedOrResumedID)
            case .failed:
                if now.timeIntervalSince(row.clockStart) <= Self.lateMatchWindow { ids.insert(row.pinnedOrResumedID) }
            }
        }
        return ids
    }

    /// The live owned set (R22): the rows whose agent is registered and
    /// running right now.
    public var liveOwnedRows: [LedgerRow] {
        rows.filter { $0.isActive && $0.phase == .live }
    }
}

// MARK: - Process liveness

/// Whether a registry row's process is still the process it was (KTD7): the
/// pid is running and its start time is the one recorded.
public enum ProcessLiveness {
    /// `kill(pid, 0)` and the kernel's start time against the key's, to the
    /// second. A pid the system has since handed to a stranger does not count.
    public static func isSameProcessRunning(_ key: LiveSessionKey, table: ProcessTable = LibprocProcessTable()) -> Bool {
        guard table.isAlive(key.pid) else { return false }
        guard let entry = table.entry(for: key.pid) else {
            // Alive but not describable (another user's process): not ours to
            // end the row over.
            return true
        }
        return abs(Int(entry.startTime) - key.procStart) <= 1
    }
}

// MARK: - Stored form

extension LedgerRow {
    private static let modeled: Set<String> = [
        "launch_id", "kind", "resumed_session_id", "agent", "profile", "config_dir", "cwd", "preset", "terminal",
        "host_socket", "started_at", "adopted_at", "phase", "failure", "pid", "proc_start", "last_session_id",
        "ended_at", "end_cause", "cause_recorded_at", "dismissed", "classified",
    ]

    private static func milliseconds(_ date: Date) -> Int { Int((date.timeIntervalSince1970 * 1000).rounded()) }
    private static func date(_ milliseconds: Int) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }

    /// The row as a JSON object. The fields this build does not model are
    /// written back as they were read.
    func jsonObject() -> [String: Any] {
        var object: [String: Any] = extra.mapValues(\.foundation)
        for key in Self.modeled { object[key] = nil }

        object["launch_id"] = launchID
        switch kind {
        case .fresh:
            object["kind"] = "fresh"
        case .restore(let id):
            object["kind"] = "restore"
            object["resumed_session_id"] = id
        }
        object["agent"] = agentID
        object["profile"] = profileID
        object["config_dir"] = configDirectory
        object["cwd"] = cwd
        object["preset"] = Self.encode(preset)
        object["terminal"] = terminalID
        object["host_socket"] = hostSocket
        object["started_at"] = Self.milliseconds(startedAt)
        object["adopted_at"] = adoptedAt.map(Self.milliseconds)
        switch phase {
        case .starting: object["phase"] = "starting"
        case .live: object["phase"] = "live"
        case .failed(let reason):
            object["phase"] = "failed"
            object["failure"] = reason
        }
        object["pid"] = pid.map { Int($0) }
        object["proc_start"] = procStart
        object["last_session_id"] = lastSessionID
        object["ended_at"] = endedAt.map(Self.milliseconds)
        object["end_cause"] = endCause?.rawValue
        object["cause_recorded_at"] = causeRecordedAt.map(Self.milliseconds)
        if dismissed { object["dismissed"] = true }
        if classified { object["classified"] = true }
        return object.compactMapValues { $0 }
    }

    /// Nil for a row this build cannot make sense of (no launch id, no
    /// folder, no terminal): it is skipped rather than failing the whole
    /// store, since a launch must never be blocked by an old row.
    init?(json: [String: Any]) {
        guard let launchID = json["launch_id"] as? String, !launchID.isEmpty,
              let cwd = json["cwd"] as? String,
              let terminal = json["terminal"] as? String,
              let started = (json["started_at"] as? NSNumber)?.intValue
        else { return nil }

        let kind: Kind
        if (json["kind"] as? String) == "restore", let resumed = json["resumed_session_id"] as? String, !resumed.isEmpty {
            kind = .restore(resumedSessionID: resumed)
        } else {
            kind = .fresh
        }
        let phase: Phase
        switch json["phase"] as? String {
        case "live": phase = .live
        case "failed": phase = .failed(reason: (json["failure"] as? String) ?? LaunchLedger.timeoutReason)
        default: phase = .starting
        }

        self.init(
            launchID: launchID,
            kind: kind,
            agentID: (json["agent"] as? String) ?? RegistryReader.claudeAgentID,
            profileID: json["profile"] as? String,
            configDirectory: json["config_dir"] as? String,
            cwd: cwd,
            preset: Self.decodePreset(json["preset"] as? [String: Any] ?? [:]),
            terminalID: terminal,
            hostSocket: json["host_socket"] as? String,
            startedAt: Self.date(started),
            adoptedAt: (json["adopted_at"] as? NSNumber).map { Self.date($0.intValue) },
            phase: phase,
            pid: (json["pid"] as? NSNumber).map { Int32(truncatingIfNeeded: $0.intValue) },
            procStart: (json["proc_start"] as? NSNumber)?.intValue,
            lastSessionID: json["last_session_id"] as? String,
            endedAt: (json["ended_at"] as? NSNumber).map { Self.date($0.intValue) },
            endCause: (json["end_cause"] as? String).map(EndCause.init(rawValue:)),
            causeRecordedAt: (json["cause_recorded_at"] as? NSNumber).map { Self.date($0.intValue) },
            dismissed: (json["dismissed"] as? NSNumber)?.boolValue ?? false,
            classified: (json["classified"] as? NSNumber)?.boolValue ?? false
        )
        var extra: [String: StoredJSON] = [:]
        for (key, value) in json where !Self.modeled.contains(key) {
            if let stored = StoredJSON(value) { extra[key] = stored }
        }
        self.extra = extra
    }

    static func encode(_ preset: Preset) -> [String: Any] {
        var object: [String: Any] = [:]
        object["agent"] = preset.agent
        object["terminal"] = preset.terminal
        object["profile"] = preset.profile
        object["model"] = preset.model
        object["effort"] = preset.effort
        object["permission_mode"] = preset.permissionMode
        switch preset.advisor {
        case .none: break
        case .some(.off): object["advisor"] = "off"
        case .some(.model(let model)): object["advisor_model"] = model
        }
        object["keep_running"] = preset.keepRunning
        return object.compactMapValues { $0 }
    }

    static func decodePreset(_ object: [String: Any]) -> Preset {
        var preset = Preset(
            agent: object["agent"] as? String,
            terminal: object["terminal"] as? String,
            profile: object["profile"] as? String,
            model: object["model"] as? String,
            effort: object["effort"] as? String,
            permissionMode: object["permission_mode"] as? String
        )
        if (object["advisor"] as? String) == "off" {
            preset.advisor = .off
        } else if let model = object["advisor_model"] as? String {
            preset.advisor = .model(model)
        }
        preset.keepRunning = (object["keep_running"] as? NSNumber).map(\.boolValue)
        return preset
    }
}
