// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// Restore classification (U13, KTD12): what each ended owned session becomes.
//
// Pure: it reads no registry, runs no tmux, opens no file and has no clock. The
// app hands it the ledger, the restore state and what it just observed (the
// host's status, the power-off notification, the boot id, which sessions never
// got a prompt, which are live), and gets back the state to keep and the
// decisions to record.

/// Everything the planner is told about the world, besides the ledger and the
/// state it classifies into.
public struct RestoreContext: Equatable, Sendable {
    public var now: Date
    /// The first look after AgentMenu started. Whatever ended unrecorded then
    /// ended while AgentMenu was not running: nothing saw it, so there is no
    /// settle window to wait out and nothing to explain it but the boot id.
    public var isRelaunchPass: Bool
    /// The session host as of this look (`SessionHost.status()`). Death is
    /// read from this and not from a snapshot: a snapshot is not taken when
    /// the server is down, which is exactly the case.
    public var hostStatus: HostStatus
    /// When `NSWorkspace.willPowerOffNotification` arrived, if it did.
    public var powerOffAt: Date?
    /// `BootID.current()`.
    public var currentBootID: String?
    /// Sessions known to have no user record in their transcript: resuming
    /// them fails, so they stay out of the pending set and the closed stack.
    public var neverPrompted: Set<String>
    /// Every session id live right now, in any profile. A session that is
    /// running is not closed, and not waiting to be reopened.
    public var liveSessionIDs: Set<String>

    public init(
        now: Date,
        isRelaunchPass: Bool = false,
        hostStatus: HostStatus = .neverStarted,
        powerOffAt: Date? = nil,
        currentBootID: String? = nil,
        neverPrompted: Set<String> = [],
        liveSessionIDs: Set<String> = []
    ) {
        self.now = now
        self.isRelaunchPass = isRelaunchPass
        self.hostStatus = hostStatus
        self.powerOffAt = powerOffAt
        self.currentBootID = currentBootID
        self.neverPrompted = neverPrompted
        self.liveSessionIDs = liveSessionIDs
    }
}

/// What one ended row became.
public struct RestoreClassification: Equatable, Sendable {
    public enum Destination: Equatable, Sendable {
        case pendingReopen
        case closedStack
        /// Kept out of both: never prompted, no id to resume, or already
        /// accounted for.
        case neither
    }

    public var launchID: String
    public var sessionID: String?
    public var destination: Destination
    /// The cause to record on the row when it has none; nil leaves the row's
    /// cause alone.
    public var cause: EndCause?
}

/// The decision to tell the user that the session host died (R34). U14 posts
/// it; the planner only says that the moment has come and how many sessions it
/// took with it.
public struct HostDeathNotice: Equatable, Sendable {
    public var count: Int
    public var sessionIDs: [String]

    public init(count: Int, sessionIDs: [String]) {
        self.count = count
        self.sessionIDs = sessionIDs
    }
}

/// What `RestorePlanner.plan` decided.
public struct RestorePlan: Equatable, Sendable {
    /// The restore state to keep.
    public var state: RestoreState
    /// One entry per ledger row decided this time. A row not listed is still
    /// inside its settle window.
    public var classifications: [RestoreClassification]
    /// Set when sessions went to the pending set because the host died, and
    /// that death has not been announced by an earlier call. Never set for a
    /// logout or shutdown (R34).
    public var hostDeathNotice: HostDeathNotice?

    /// Marks the decided rows as classified, and records a cause on the ones
    /// that carried none.
    public func apply(to ledger: inout LaunchLedger) {
        for classification in classifications {
            ledger.markClassified(launchID: classification.launchID, cause: classification.cause)
        }
    }
}

public enum RestorePlanner {
    /// How long a disappearance AgentMenu did not cause waits before it is
    /// classified: the 2-second sweep, so the host is checked at least once
    /// after the registry notices (AE10).
    public static let settleWindow: TimeInterval = 2
    /// Sessions of the same cause classified within this long of the last
    /// addition to a pending set are taken to be the same event, and are added
    /// to it, when their rows do not say when the cause was recorded. A Quit all
    /// ends its sessions up to `SessionQuitter.giveUpDelay` apart.
    ///
    /// Rows that do say (`causeRecordedAt`) are decided by it instead: they
    /// belong to the set if their cause was recorded before the set formed,
    /// which holds however long after, and across an AgentMenu restart, the
    /// rest of the event ends.
    public static let eventWindow: TimeInterval = 60
    /// A power-off notification explains endings from just before it (the
    /// settle window) to this long after it. Past that, the logout was
    /// cancelled.
    public static let powerOffWindow: TimeInterval = 120

    /// The id a restore of this row resumes (`LedgerRow.resumableSessionID`),
    /// or nil when it is not a session id.
    public static func resumableSessionID(of row: LedgerRow) -> String? {
        let id = row.resumableSessionID
        return SessionIdentifier.isValid(id) ? id : nil
    }

    /// The ended rows still to be classified.
    public static func candidates(in ledger: LaunchLedger) -> [LedgerRow] {
        ledger.rows.filter(\.awaitsClassification)
    }

    /// Classifies and applies, in one step on one value: the ledger rows are
    /// marked and the state replaced, so a caller writes both with one write.
    @discardableResult
    public static func classify(_ data: inout SessionStoreData, context: RestoreContext) -> RestorePlan {
        let result = plan(ledger: data.ledger, state: data.restore, context: context)
        result.apply(to: &data.ledger)
        data.restore = result.state
        return result
    }

    private enum Decision {
        case wait
        case neither
        case pending(EndCause)
        case closed(EndCause)
    }

    public static func plan(ledger: LaunchLedger, state: RestoreState, context: RestoreContext) -> RestorePlan {
        var next = state
        next.bootID = context.currentBootID ?? state.bootID

        // A store from before this unit has ended rows nobody classified, and
        // no boot id: they are history, not a set to reopen.
        let baseline = state.bootID == nil && context.currentBootID != nil
        let bootChanged = BootID.hasChanged(from: state.bootID, to: context.currentBootID)

        struct Decided {
            let row: LedgerRow
            let sessionID: String
            let endedAt: Date
            let decision: Decision
        }
        var recordedAt: [Date?] = []

        var classifications: [RestoreClassification] = []
        var decided: [Decided] = []

        let rows = candidates(in: ledger).sorted {
            ($0.endedAt ?? .distantPast, $0.launchID) < ($1.endedAt ?? .distantPast, $1.launchID)
        }
        for row in rows {
            let ended = row.endedAt ?? context.now
            guard !baseline,
                  let sessionID = resumableSessionID(of: row),
                  !context.neverPrompted.contains(sessionID)
            else {
                classifications.append(RestoreClassification(
                    launchID: row.launchID, sessionID: resumableSessionID(of: row), destination: .neither, cause: nil
                ))
                continue
            }
            let decision = decide(row, endedAt: ended, context: context, bootChanged: bootChanged)
            if case .wait = decision { continue }
            decided.append(Decided(row: row, sessionID: sessionID, endedAt: ended, decision: decision))
        }

        // Two rows of one session (a resume that ended again): the later one
        // is where the session is now.
        var latest: [String: Int] = [:]
        for (index, entry) in decided.enumerated() { latest[entry.sessionID] = index }

        var pendingBatch: [RestorableSession] = []
        var closedBatch: [RestorableSession] = []
        for (index, entry) in decided.enumerated() {
            var destination = RestoreClassification.Destination.neither
            var cause: EndCause?
            if latest[entry.sessionID] == index {
                switch entry.decision {
                case .pending(let why):
                    destination = .pendingReopen
                    cause = why
                    pendingBatch.append(RestorableSession(row: entry.row, sessionID: entry.sessionID, endedAt: entry.endedAt, cause: why))
                    recordedAt.append(entry.row.causeRecordedAt)
                case .closed(let why):
                    destination = .closedStack
                    cause = why
                    closedBatch.append(RestorableSession(row: entry.row, sessionID: entry.sessionID, endedAt: entry.endedAt, cause: why))
                case .wait, .neither:
                    break
                }
            }
            classifications.append(RestoreClassification(
                launchID: entry.row.launchID, sessionID: entry.sessionID, destination: destination, cause: cause
            ))
        }

        var notice: HostDeathNotice?

        if !pendingBatch.isEmpty {
            let batchCause = pendingBatch.map(\.cause).max { rank($0) < rank($1) } ?? .unexplained
            let existing = next.pending
            let continuesEvent = existing.map { set -> Bool in
                guard set.cause == batchCause else { return false }
                // Every session says when its cause was recorded: the event
                // is the one that formed the set if that was before it did.
                let stamps = recordedAt.compactMap { $0 }
                if stamps.count == recordedAt.count {
                    return stamps.allSatisfy { $0 <= set.formedAt }
                }
                return context.now.timeIntervalSince(set.updatedAt) <= eventWindow
            } ?? false

            if continuesEvent, var set = existing {
                set.sessions = merged(existing: set.sessions, adding: pendingBatch)
                set.updatedAt = context.now
                next.pending = set
            } else if let set = existing, set.touched {
                // The user has acted on what is left of it, and R35 keeps the
                // rest for a later try: a new event adds to it.
                next.pending = PendingReopenSet(
                    sessions: merged(existing: set.sessions, adding: pendingBatch),
                    formedAt: context.now, cause: batchCause, touched: true
                )
            } else {
                next.pending = PendingReopenSet(sessions: pendingBatch, formedAt: context.now, cause: batchCause)
            }

            let died = pendingBatch.filter { $0.cause == .hostDied }
            if !died.isEmpty, !continuesEvent {
                notice = HostDeathNotice(count: died.count, sessionIDs: died.map(\.sessionID))
            }
            let moved = Set(pendingBatch.map(\.sessionID))
            next.closed.removeAll { moved.contains($0.sessionID) }
        }

        if !closedBatch.isEmpty {
            let moved = Set(closedBatch.map(\.sessionID))
            if var set = next.pending {
                set.sessions.removeAll { moved.contains($0.sessionID) }
                next.pending = set.sessions.isEmpty ? nil : set
            }
            for session in closedBatch { next.pushClosed(session) }
        }

        // A session that is running is neither closed nor waiting to be
        // reopened: it was brought back some other way (R27).
        if !context.liveSessionIDs.isEmpty {
            next.closed.removeAll { context.liveSessionIDs.contains($0.sessionID) }
            if var set = next.pending {
                set.sessions.removeAll { context.liveSessionIDs.contains($0.sessionID) }
                next.pending = set.sessions.isEmpty ? nil : set
            }
        }

        return RestorePlan(state: next, classifications: classifications, hostDeathNotice: notice)
    }

    // MARK: - One row

    private static func decide(
        _ row: LedgerRow, endedAt: Date, context: RestoreContext, bootChanged: Bool
    ) -> Decision {
        // A power-off recorded for a logout somebody cancelled is taken back
        // while AgentMenu runs, but a restart of AgentMenu loses that, and the
        // cause outlives the logout it was recorded for. One recorded long
        // before the session ended explains nothing: the ending is read from
        // what is observed, like any other. A relaunch keeps it, since what
        // ended while AgentMenu was away has nothing else to go on.
        var recorded = row.endCause
        if recorded == .powerOff, !context.isRelaunchPass, let at = row.causeRecordedAt,
           endedAt > at.addingTimeInterval(powerOffWindow) {
            recorded = nil
        }
        // A cause AgentMenu recorded before the session ended is the user's
        // intent, and needs no settle window: AgentMenu caused this one.
        switch recorded {
        case .individual, .exited: return .closed(recorded ?? .exited)
        case .together, .powerOff, .hostDied, .unexplained: return .pending(recorded ?? .unexplained)
        case .none, .unrecognised: break
        }

        if context.isRelaunchPass {
            return .pending(bootChanged ? .powerOff : .unexplained)
        }
        // Nothing AgentMenu recorded explains it. Wait one settle window, so
        // the host is checked after the registry has noticed and the
        // notification, if it is coming, has come (AE10)...
        if context.now.timeIntervalSince(endedAt) < settleWindow { return .wait }
        // ...then read it from what is observed: the Mac going down, the host
        // dying, or, otherwise, the session simply ending.
        if let at = context.powerOffAt,
           endedAt >= at.addingTimeInterval(-settleWindow), endedAt <= at.addingTimeInterval(powerOffWindow) {
            return .pending(.powerOff)
        }
        if row.isHosted, context.hostStatus == .died {
            return .pending(.hostDied)
        }
        return .closed(.exited)
    }

    private static func merged(existing: [RestorableSession], adding batch: [RestorableSession]) -> [RestorableSession] {
        let incoming = Set(batch.map(\.sessionID))
        return existing.filter { !incoming.contains($0.sessionID) } + batch
    }

    /// Which cause names a set whose sessions ended for several.
    private static func rank(_ cause: EndCause) -> Int {
        switch cause {
        case .hostDied: return 4
        case .powerOff: return 3
        case .together: return 2
        default: return 1
        }
    }
}
