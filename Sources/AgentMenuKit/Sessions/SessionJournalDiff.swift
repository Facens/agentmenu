// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What a new live list means for the journal (KTD16): which sessions just
/// appeared, and which changed status.
///
/// A pure diff over the last statuses seen, keyed by the row's own identity
/// (`LiveSessionKey`). The app keeps the returned map and hands it back next
/// time; only the observer that writes the journal runs this, so a normal
/// launch does none of the work.
public struct SessionJournalDiff: Equatable {
    public struct StatusChange: Equatable {
        public let session: LiveSession
        public let from: SessionStatus
    }

    /// Sessions with no earlier status: `session seen`.
    public let appeared: [LiveSession]
    /// Sessions whose status differs from the last one seen.
    public let changed: [StatusChange]
    /// The statuses now, to pass as `previous` next time. A session that has
    /// gone is dropped, so one that comes back under the same key is seen
    /// again.
    public let statuses: [LiveSessionKey: SessionStatus]

    public static func compare(
        previous: [LiveSessionKey: SessionStatus],
        current: [LiveSession]
    ) -> SessionJournalDiff {
        var appeared: [LiveSession] = []
        var changed: [StatusChange] = []
        var statuses: [LiveSessionKey: SessionStatus] = [:]
        for session in current where statuses[session.key] == nil {
            statuses[session.key] = session.status
            guard let before = previous[session.key] else {
                appeared.append(session)
                continue
            }
            if before != session.status {
                changed.append(StatusChange(session: session, from: before))
            }
        }
        return SessionJournalDiff(appeared: appeared, changed: changed, statuses: statuses)
    }
}

extension JournalData.RestoreOutcome {
    /// How a refused history resume is recorded. A closed set, so an error's
    /// own text — which can carry a path — never reaches the journal.
    public init(refusal: HistoryResumeRefusal) {
        switch refusal {
        case .invalidSessionID: self = .invalidSession
        case .alreadyLive: self = .focusedLive
        case .runningElsewhere, .launchInFlight, .runningDetached: self = .alreadyRunning
        case .notRestorable: self = .notRestorable
        case .unknownProfile: self = .unknownProfile
        case .agentUnavailable: self = .agentUnavailable
        }
    }
}
