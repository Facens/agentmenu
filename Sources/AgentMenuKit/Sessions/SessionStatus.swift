// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What a live session is doing, as far as anything on this Mac can tell (R9).
///
/// Four values and no more. "Detached" is deliberately not one of them: it
/// describes how an AgentMenu-owned session is hosted, not what the agent is
/// doing, so a detached session can still be Working or Needs you. Keeping the
/// two apart here is what lets a later unit carry the marker beside the status
/// instead of overwriting it.
public enum SessionStatus: String, Equatable, Sendable, CaseIterable {
    case working
    case needsYou
    case yourTurn
    /// No usable signal. Shown as running/gone only — never promoted to
    /// `needsYou` from a guess (R11).
    case unknown
}

/// A status together with the one extra fact `shell` carries.
public struct MappedStatus: Equatable, Sendable {
    public let status: SessionStatus
    /// True when the registry said `shell`: the agent is idle at its prompt
    /// while a background task it started is still running. It is a hint for
    /// the row, not a fifth status — the session is Your turn either way.
    public let backgroundTaskRunning: Bool

    public init(status: SessionStatus, backgroundTaskRunning: Bool = false) {
        self.status = status
        self.backgroundTaskRunning = backgroundTaskRunning
    }
}

/// Maps the two wire fields Claude Code writes into its registry (`status`
/// and `waitingFor`) to a `SessionStatus` (KTD8).
///
/// The literals below are the ones read out of Claude Code 2.1.285's binary,
/// not guessed from behaviour. Matching is exact and case-sensitive on
/// purpose: a spelling this table does not know is a signal this table was
/// not written for, and the answer to that is `unknown`, not a fuzzy match.
public enum SessionStatusMapping {
    /// `waitingFor` values that mean the agent is blocked on the user, each
    /// with the label a notification gives it. One table, so the set of
    /// reasons and their wording cannot drift apart.
    public static let needsYouLabels: [String: String] = [
        "permission prompt": "Permission prompt",
        "input needed": "Input needed",
        "sandbox request": "Sandbox request",
        "worker request": "Worker request",
        "goal proposal": "Goal proposal",
    ]

    /// `waitingFor` values that mean the agent is blocked on the user.
    public static let needsYouReasons: Set<String> = Set(needsYouLabels.keys)

    /// `waitingFor` value for an open dialog: the agent has stopped but
    /// nothing is asked of the user, so it never notifies.
    public static let dialogOpenReason = "dialog open"

    public static func map(status: String?, waitingFor: String?) -> MappedStatus {
        switch status {
        case "busy":
            // May persist while background subagents run; that is Claude
            // Code's own definition of busy, so it is Working here too.
            return MappedStatus(status: .working)
        case "waiting":
            if let waitingFor, needsYouReasons.contains(waitingFor) {
                return MappedStatus(status: .needsYou)
            }
            if waitingFor == dialogOpenReason {
                return MappedStatus(status: .yourTurn)
            }
            // `waiting` with a reason this table has never seen, or none at
            // all. R11 forbids Needs you from a guess, and Your turn would be
            // a guess too: it asserts the agent is sitting at its prompt,
            // which a later Claude Code adding a reason like "plan review"
            // may well not mean, and a later unit may notify on Your turn for
            // owned sessions. Unknown claims nothing, so it is the choice
            // that cannot be wrong in either direction.
            return MappedStatus(status: .unknown)
        case "idle":
            return MappedStatus(status: .yourTurn)
        case "shell":
            return MappedStatus(status: .yourTurn, backgroundTaskRunning: true)
        default:
            return MappedStatus(status: .unknown)
        }
    }
}
