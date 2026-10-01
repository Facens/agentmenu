// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// The decisions the Sessions tab makes that are not drawing: what the popover
// opens on, when the sweep runs, what the menu-bar badge says, how a status is
// worded, what the header menu offers. Kept here, without SwiftUI or AppKit,
// so each one is a function a test can call instead of a behaviour someone has
// to open the popover to see (U5).

// MARK: - What the popover opens on

/// The popover's two tabs. The raw value is the tab chip's id.
public enum PopoverTab: String, Equatable, Sendable {
    case launch
    case sessions

    /// KTD16: the popover always opens on Launch. Nothing persists the last
    /// tab, so this is the only place the answer lives.
    public static let onOpen: PopoverTab = .launch
}

/// Live or Closed, inside the Sessions tab. The raw value is the toggle
/// chip's id.
public enum SessionsMode: String, Equatable, Sendable {
    case live
    case closed
}

/// The Sessions tab's own selections, and what a fresh open puts them back to.
///
/// The pill goes back to All on every open (R6) so the badge's source is
/// always on screen: a pill left on one account would hide the Needs-you
/// session the badge is counting behind another. The search box is cleared
/// for the same reason a tab is not remembered — an open is a fresh look.
public struct SessionsViewState: Equatable, Sendable {
    public var mode: SessionsMode
    public var pill: AccountPill
    public var search: String

    public init(mode: SessionsMode = .live, pill: AccountPill = .all, search: String = "") {
        self.mode = mode
        self.pill = pill
        self.search = search
    }

    public static let onOpen = SessionsViewState()

    /// Puts every selection back to what an open shows.
    public mutating func reopen() { self = .onOpen }
}

extension AccountPill {
    /// Whether a session attributed to `profileID` is shown under this pill.
    /// `All` shows everything, including an agent with no profile; a profile
    /// pill shows only that profile's.
    public func includes(profileID: String?) -> Bool {
        switch self {
        case .all: return true
        case .profile(let id): return profileID == id
        }
    }
}

// MARK: - When the sweep runs

/// KTD9: the 2-second sweep exists to catch a process that died without its
/// registry file being removed, and to re-read statuses the file watches
/// missed. It has nothing to catch while nothing is listed, so it runs only
/// while at least one session is. The count is the whole live list, not the
/// rows under the selected pill — the badge is computed from every account.
public enum SweepPolicy {
    public static let interval: TimeInterval = 2

    public static func isActive(listedSessions: Int) -> Bool { listedSessions > 0 }
}

// MARK: - The menu-bar badge

/// What the menu bar says about sessions waiting on the user (R7).
public enum SessionBadge {
    /// Needs-you sessions across every account, whichever pill is selected.
    /// The same number `SessionSnapshot.build(...).badgeCount` reports, without
    /// building the snapshot: the badge has to stay right while the popover is
    /// closed, which is most of the time.
    public static func count(live: [LiveSession]) -> Int {
        var seen = Set<LiveSessionKey>()
        var waiting = 0
        for session in live where seen.insert(session.key).inserted && session.status == .needsYou {
            waiting += 1
        }
        return waiting
    }

    /// The number beside the glyph; nil at zero, so the title is exactly what
    /// it was before sessions existed.
    public static func text(count: Int) -> String? {
        guard count > 0 else { return nil }
        return count > 99 ? "99+" : String(count)
    }

    public static func tooltip(count: Int) -> String? {
        guard count > 0 else { return nil }
        return count == 1 ? "1 session needs you" : "\(count) sessions need you"
    }
}

// MARK: - Wording a row

extension SessionStatus {
    /// What the row says. Text as well as a symbol and a colour, so the status
    /// is never carried by colour alone.
    public var label: String {
        switch self {
        case .working: return "Working"
        case .needsYou: return "Needs you"
        case .yourTurn: return "Your turn"
        // R11: no usable signal is shown as running, never as a guess.
        case .unknown: return "Running"
        }
    }

    /// An SF Symbol name; a different shape per status, so two statuses are
    /// told apart without seeing their colour.
    public var symbolName: String {
        switch self {
        case .working: return "arrow.triangle.2.circlepath"
        case .needsYou: return "exclamationmark.bubble.fill"
        case .yourTurn: return "checkmark.circle"
        case .unknown: return "circle.dotted"
        }
    }
}

public enum SessionRowWording {
    /// The marker beside the status of an owned session with no window on
    /// screen (R9). Nothing to show for a window that is attached.
    public static let detachedLabel = "Detached"

    public static let quittingLabel = "Quitting"

    /// What the row states about the session's liveness and work. An agent
    /// with no registry has no status to report, only that it is alive (R2).
    public static func statusText(for session: LiveSession) -> String {
        session.isClaudeCode ? session.status.label : "Running"
    }

    /// The folder's last component, for a row's second line. The group header
    /// already names the folder in full; the row repeats only enough to
    /// identify it inside the Needs-you group, where folders mix.
    public static func folderName(_ path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }
}

// MARK: - The header menu

/// One item of the Sessions header menu: Quit all, Reopen all, Reopen last
/// closed.
public struct SessionsHeaderMenuItem: Equatable, Identifiable {
    public enum Kind: Equatable, Hashable { case quitAll, reopenAll, reopenLastClosed }

    public let kind: Kind
    public let title: String
    public let count: Int
    /// nil when the item can be used; otherwise why it cannot, for the help
    /// tag. An item with no reason is enabled.
    public let disabledReason: String?

    public var id: Kind { kind }
    public var isEnabled: Bool { disabledReason == nil }
}

public enum SessionsHeaderMenu {
    /// The three items with their counts. Each is disabled, with a reason,
    /// when its count is zero.
    public static func items(
        quitAllCount: Int,
        reopenAllCount: Int,
        reopenLastClosedCount: Int
    ) -> [SessionsHeaderMenuItem] {
        func reason(_ count: Int, empty: String) -> String? {
            count == 0 ? empty : nil
        }
        return [
            SessionsHeaderMenuItem(
                kind: .quitAll,
                title: "Quit all (\(quitAllCount))",
                count: quitAllCount,
                disabledReason: reason(quitAllCount, empty: "No sessions started by AgentMenu are running.")
            ),
            SessionsHeaderMenuItem(
                kind: .reopenAll,
                title: "Reopen all (\(reopenAllCount))",
                count: reopenAllCount,
                disabledReason: reason(reopenAllCount, empty: "No sessions are waiting to be reopened.")
            ),
            SessionsHeaderMenuItem(
                kind: .reopenLastClosed,
                title: "Reopen last closed (\(reopenLastClosedCount))",
                count: reopenLastClosedCount,
                disabledReason: reason(reopenLastClosedCount, empty: "No closed session to reopen.")
            ),
        ]
    }
}

// MARK: - Reopen all's result

/// The strip at the top of the list after a Reopen all (R36): how it went, and
/// each failure with its reason.
public struct ReopenAllSummary: Equatable {
    public struct Failure: Equatable, Identifiable {
        public let name: String
        public let reason: String
        public var id: String { name + "\u{0}" + reason }

        public init(name: String, reason: String) {
            self.name = name
            self.reason = reason
        }
    }

    public let total: Int
    public let failures: [Failure]

    public init(total: Int, failures: [Failure]) {
        self.total = total
        self.failures = failures
    }

    public var reopened: Int { max(0, total - failures.count) }

    public var headline: String {
        if failures.isEmpty { return total == 1 ? "Reopened 1 session" : "Reopened \(total) sessions" }
        return "Reopened \(reopened) of \(total); \(failures.count) failed"
    }
}

// MARK: - Rows with no registry record yet

/// An owned launch that has no live row yet, or one that never got one.
/// Nothing creates these in M1 — owned launches arrive in U14 — so the view
/// support exists and renders them, and no data path feeds it.
public struct PendingLaunch: Equatable, Identifiable {
    public enum Phase: Equatable {
        /// Launched, not yet registered: shown in its folder group with a
        /// progress indicator and only Quit (R36).
        case starting
        /// Did not come up: stays, with why, and offers Retry and Dismiss.
        case failedToStart(reason: String)
    }

    public let id: String
    public let title: String
    /// Normalised, as `SessionRow.folderPath`, so it lands in the same group.
    public let folderPath: String?
    public let profileID: String?
    public let phase: Phase

    public init(id: String, title: String, folderPath: String?, profileID: String?, phase: Phase) {
        self.id = id
        self.title = title
        self.folderPath = folderPath
        self.profileID = profileID
        self.phase = phase
    }
}
