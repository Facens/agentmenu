// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// What the session store keeps for restore (KTD12): the pending reopen set, the
// closed stack and the boot id. The launch ledger and the live owned set (the
// ledger's live rows) are the other two halves, in `LaunchLedger`.

/// One ended owned session, with everything a restore needs to bring it back
/// and nothing it has to look up again: the ledger prunes its rows after 30
/// days or 200 launches, and a restore must not depend on them.
public struct RestorableSession: Equatable, Sendable, Identifiable {
    /// The session id a `--resume` uses: the latest id the agent had, which is
    /// what `/clear` leaves behind.
    public var sessionID: String
    public var id: String { sessionID }
    /// The tmux session name of the launch it ended in.
    public var launchID: String
    public var agentID: String
    public var profileID: String?
    public var configDirectory: String?
    public var cwd: String
    /// The preset the launch ran with, which a restore re-passes whole (KTD14).
    public var preset: Preset
    public var terminalID: String
    /// Set when it ran under the session host: the restore uses the hosted
    /// launch path again.
    public var hostSocket: String?
    public var endedAt: Date
    /// Why it ended, as classified.
    public var cause: EndCause

    public init(
        sessionID: String,
        launchID: String,
        agentID: String = RegistryReader.claudeAgentID,
        profileID: String? = nil,
        configDirectory: String? = nil,
        cwd: String,
        preset: Preset = Preset(),
        terminalID: String,
        hostSocket: String? = nil,
        endedAt: Date,
        cause: EndCause
    ) {
        self.sessionID = sessionID
        self.launchID = launchID
        self.agentID = agentID
        self.profileID = profileID
        self.configDirectory = configDirectory
        self.cwd = cwd
        self.preset = preset
        self.terminalID = terminalID
        self.hostSocket = hostSocket
        self.endedAt = endedAt
        self.cause = cause
    }

    init(row: LedgerRow, sessionID: String, endedAt: Date, cause: EndCause) {
        self.init(
            sessionID: sessionID,
            launchID: row.launchID,
            agentID: row.agentID,
            profileID: row.profileID,
            configDirectory: row.configDirectory,
            cwd: row.cwd,
            preset: row.preset,
            terminalID: row.terminalID,
            hostSocket: row.hostSocket,
            endedAt: endedAt,
            cause: cause
        )
    }
}

/// The owned sessions that were live when they last stopped together (R23):
/// what "Reopen all from last time" brings back.
public struct PendingReopenSet: Equatable, Sendable {
    /// In the order they ended.
    public var sessions: [RestorableSession]
    /// When the event that formed it was first classified.
    public var formedAt: Date
    /// When a session was last added to it.
    public var updatedAt: Date
    /// The strongest cause among its sessions.
    public var cause: EndCause
    /// A restore has taken something out of it (or tried to): the user has
    /// acted on it, and a later event no longer replaces it.
    public var touched: Bool

    public init(
        sessions: [RestorableSession],
        formedAt: Date,
        updatedAt: Date? = nil,
        cause: EndCause,
        touched: Bool = false
    ) {
        self.sessions = sessions
        self.formedAt = formedAt
        self.updatedAt = updatedAt ?? formedAt
        self.cause = cause
        self.touched = touched
    }

    public var sessionIDs: [String] { sessions.map(\.sessionID) }
}

/// The restore half of the store: the pending reopen set, the closed stack and
/// the boot id the last run saw.
public struct RestoreState: Equatable, Sendable {
    /// The most sessions the closed stack keeps; older ones are still in the
    /// Closed list, which is built from the agent's own transcripts.
    public static let maximumClosed = 50

    /// Nil when there is none. Never an empty set.
    public var pending: PendingReopenSet?
    /// Most recently closed first: the top of the stack is `closed[0]` (R24).
    public var closed: [RestorableSession]
    /// The boot the last run saw (`BootID.current()`); nil before the first.
    public var bootID: String?

    public init(pending: PendingReopenSet? = nil, closed: [RestorableSession] = [], bootID: String? = nil) {
        self.pending = pending
        self.closed = closed
        self.bootID = bootID
    }

    /// The size of the pending reopen set, for the header menu (U14).
    public var pendingCount: Int { pending?.sessions.count ?? 0 }
    /// The depth of the closed stack, for the header menu (U14).
    public var closedCount: Int { closed.count }
    /// What "Reopen last closed" restores.
    public var lastClosed: RestorableSession? { closed.first }

    public func contains(_ sessionID: String) -> Bool {
        closed.contains { $0.sessionID == sessionID } || pending?.sessions.contains { $0.sessionID == sessionID } == true
    }

    /// A restore brought these sessions back: they leave the pending set and
    /// the closed stack (R24). A session that could not be restored is simply
    /// not passed, and stays where it is for a later try (R35).
    public mutating func restored(_ sessionIDs: Set<String>) {
        guard !sessionIDs.isEmpty else { return }
        closed.removeAll { sessionIDs.contains($0.sessionID) }
        if var set = pending {
            let before = set.sessions.count
            set.sessions.removeAll { sessionIDs.contains($0.sessionID) }
            if set.sessions.count != before { set.touched = true }
            pending = set.sessions.isEmpty ? nil : set
        }
    }

    /// A restore of the pending set was tried: from now on a later event does
    /// not replace what is left of it, even if nothing came back.
    public mutating func markPendingTouched() {
        pending?.touched = true
    }

    /// Pushes a closed session on top, once: an earlier entry for the same
    /// session goes.
    mutating func pushClosed(_ session: RestorableSession) {
        closed.removeAll { $0.sessionID == session.sessionID }
        closed.insert(session, at: 0)
        if closed.count > Self.maximumClosed { closed.removeLast(closed.count - Self.maximumClosed) }
    }
}

// MARK: - Stored form

extension RestorableSession {
    func jsonObject() -> [String: Any] {
        var object: [String: Any] = [:]
        object["session_id"] = sessionID
        object["launch_id"] = launchID
        object["agent"] = agentID
        object["profile"] = profileID
        object["config_dir"] = configDirectory
        object["cwd"] = cwd
        object["preset"] = LedgerRow.encode(preset)
        object["terminal"] = terminalID
        object["host_socket"] = hostSocket
        object["ended_at"] = restoreMilliseconds(endedAt)
        object["cause"] = cause.rawValue
        return object.compactMapValues { $0 }
    }

    /// Nil for an entry this build cannot make sense of: skipped, not fatal.
    init?(json: [String: Any]) {
        guard let sessionID = json["session_id"] as? String, !sessionID.isEmpty,
              let launchID = json["launch_id"] as? String, !launchID.isEmpty,
              let cwd = json["cwd"] as? String,
              let terminal = json["terminal"] as? String,
              let ended = (json["ended_at"] as? NSNumber)?.intValue
        else { return nil }
        self.init(
            sessionID: sessionID,
            launchID: launchID,
            agentID: (json["agent"] as? String) ?? RegistryReader.claudeAgentID,
            profileID: json["profile"] as? String,
            configDirectory: json["config_dir"] as? String,
            cwd: cwd,
            preset: LedgerRow.decodePreset(json["preset"] as? [String: Any] ?? [:]),
            terminalID: terminal,
            hostSocket: json["host_socket"] as? String,
            endedAt: restoreDate(ended),
            cause: (json["cause"] as? String).map(EndCause.init(rawValue:)) ?? .unexplained
        )
    }
}

extension PendingReopenSet {
    func jsonObject() -> [String: Any] {
        [
            "sessions": sessions.map { $0.jsonObject() },
            "formed_at": restoreMilliseconds(formedAt),
            "updated_at": restoreMilliseconds(updatedAt),
            "cause": cause.rawValue,
            "touched": touched,
        ]
    }

    /// Nil when nothing readable is left in it.
    init?(json: [String: Any]) {
        let sessions = ((json["sessions"] as? [Any]) ?? []).compactMap {
            ($0 as? [String: Any]).flatMap(RestorableSession.init(json:))
        }
        guard !sessions.isEmpty else { return nil }
        let formed = (json["formed_at"] as? NSNumber).map { restoreDate($0.intValue) } ?? sessions[0].endedAt
        self.init(
            sessions: sessions,
            formedAt: formed,
            updatedAt: (json["updated_at"] as? NSNumber).map { restoreDate($0.intValue) } ?? formed,
            cause: (json["cause"] as? String).map(EndCause.init(rawValue:)) ?? .unexplained,
            touched: (json["touched"] as? NSNumber)?.boolValue ?? false
        )
    }
}

private func restoreMilliseconds(_ date: Date) -> Int { Int((date.timeIntervalSince1970 * 1000).rounded()) }
private func restoreDate(_ milliseconds: Int) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }
