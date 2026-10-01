// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// MARK: - Vocabulary

/// What macOS says about AgentMenu posting notifications (KTD15).
public enum NotificationAuthorization: Equatable, Sendable {
    /// Not asked yet, or not read yet. The planner holds a Needs-you episode
    /// rather than dropping it: the answer may be a moment away.
    case notDetermined
    case authorized
    /// Refused in the system prompt or turned off in System Settings. The
    /// planner keeps running, nothing is posted, and the Sessions tab and
    /// Settings say how to turn it back on.
    case denied
}

/// What a planned notification is about.
public enum NotificationKind: String, Equatable, Sendable {
    case needsYou = "needs-you"
    case yourTurn = "your-turn"
    /// One banner for several sessions that were already waiting when
    /// AgentMenu started.
    case needsYouSummary = "needs-you-summary"
}

/// The two switches the planner honours. Your turn exists in the planner from
/// M2, but nothing in the app turns it on until its Settings toggle lands.
public struct NotificationSettings: Equatable, Sendable {
    public var needsYou: Bool
    public var yourTurn: Bool

    public init(needsYou: Bool = true, yourTurn: Bool = false) {
        self.needsYou = needsYou
        self.yourTurn = yourTurn
    }
}

/// What a terminal said when asked which tab is on screen (KTD10's exception).
public enum FrontmostAnswer: Equatable, Sendable {
    /// Not the frontmost app, no way to ask, no Automation grant, or an answer
    /// that was not a tty. All of them mean "post": a missing banner is worse
    /// than a redundant one.
    case notFrontmost
    /// The terminal is frontmost and this is the tty of its selected tab.
    case selectedTTY(String)
}

/// A question for the app: "is this terminal frontmost, and which tab is on
/// screen?" The planner asks once per terminal per expiry and waits for the
/// answer on a later `evaluate`.
public struct FrontmostCheck: Equatable, Sendable {
    public let terminalID: String

    public init(terminalID: String) {
        self.terminalID = terminalID
    }
}

/// One notification to post, as plain values. The app turns it into a
/// `UNNotificationRequest`; nothing here knows about `UserNotifications`.
public struct PlannedNotification: Equatable, Sendable {
    /// `needs-you.<row key>.<episode>`: the notification key of KTD15 is (row
    /// key, waiting episode), and posting the same identifier twice replaces
    /// rather than stacks, which is the last line of defence against a double.
    public let identifier: String
    public let kind: NotificationKind
    /// The row keys (`AccessibilityID.Popover.Sessions.liveRowKey`) of the
    /// sessions it is about: one, or several for a summary. A hash, but one
    /// the app can map back to a `LiveSessionKey` it holds.
    public let rowTokens: [String]
    public let title: String
    public let body: String
    /// The folder, so macOS groups one project's banners together.
    public let threadID: String

    /// What the app puts in the request's `userInfo`, and reads back on click.
    public var userInfo: [String: String] {
        [Self.kindKey: kind.rawValue, Self.rowsKey: rowTokens.joined(separator: ",")]
    }

    static let kindKey = "kind"
    static let rowsKey = "rows"

    public init(identifier: String, kind: NotificationKind, rowTokens: [String], title: String, body: String, threadID: String) {
        self.identifier = identifier
        self.kind = kind
        self.rowTokens = rowTokens
        self.title = title
        self.body = body
        self.threadID = threadID
    }
}

/// A notification macOS still has on screen from an earlier run. Delivered
/// notifications outlive the app, so the first evaluation reconciles them.
public struct DeliveredNotification: Equatable, Sendable {
    public let identifier: String
    public let kind: NotificationKind
    public let rowTokens: [String]

    public init(identifier: String, kind: NotificationKind, rowTokens: [String]) {
        self.identifier = identifier
        self.kind = kind
        self.rowTokens = rowTokens
    }

    /// Reads back what `PlannedNotification.userInfo` wrote. Nil for a
    /// notification that did not come from this planner.
    public init?(identifier: String, userInfo: [String: String]) {
        guard let raw = userInfo[PlannedNotification.kindKey], let kind = NotificationKind(rawValue: raw) else { return nil }
        let rows = (userInfo[PlannedNotification.rowsKey] ?? "")
            .split(separator: ",", omittingEmptySubsequences: true)
            .map(String.init)
        self.init(identifier: identifier, kind: kind, rowTokens: rows)
    }
}

// MARK: - One evaluation

/// Everything the planner needs for one step. The clock is a value in it, so
/// a test drives time by hand and a run takes whatever `Date()` says.
public struct NotificationInput {
    public var now: Date
    public var live: [LiveSession]
    /// Sessions AgentMenu launched. Only they get a Your-turn notification:
    /// about forty automated sessions finish a day on the maintainer's Mac,
    /// and a banner for each would be noise. Empty until owned launches exist.
    public var owned: Set<LiveSessionKey>
    public var settings: NotificationSettings
    public var authorization: NotificationAuthorization
    /// Answers to the checks an earlier plan asked for, by terminal id. An
    /// answer is used by this evaluation and forgotten; nothing is cached, so
    /// "ask once" is the planner's own property and not the app's discipline.
    public var frontmost: [String: FrontmostAnswer]
    /// A row's name for the banner. Only called for a session that is about to
    /// be named in one.
    public var title: (LiveSession) -> String

    public init(
        now: Date,
        live: [LiveSession],
        owned: Set<LiveSessionKey> = [],
        settings: NotificationSettings = NotificationSettings(),
        authorization: NotificationAuthorization = .authorized,
        frontmost: [String: FrontmostAnswer] = [:],
        title: @escaping (LiveSession) -> String = NotificationText.defaultTitle
    ) {
        self.now = now
        self.live = live
        self.owned = owned
        self.settings = settings
        self.authorization = authorization
        self.frontmost = frontmost
        self.title = title
    }
}

/// What to do now.
public struct NotificationPlan: Equatable, Sendable {
    public var posts: [PlannedNotification] = []
    /// Identifiers to remove from Notification Center, delivered or pending.
    public var withdrawals: [String] = []
    /// Terminals to ask which tab is frontmost; answer on the next evaluate.
    public var frontmostChecks: [FrontmostCheck] = []
    /// When to evaluate again with nothing else having happened: the earliest
    /// hold-down still running. Nil when none is.
    public var nextDeadline: Date?

    public var isEmpty: Bool {
        posts.isEmpty && withdrawals.isEmpty && frontmostChecks.isEmpty
    }

    public init() {}
}

// MARK: - The planner

/// Decides when to notify and when to take a notification back (R32, R33).
///
/// A pure state machine: the same inputs in the same order give the same
/// plans, it reads no clock and no file, and it never talks to macOS. The app
/// feeds it each list the registry reports and each answer it got back, and
/// does what the plan says.
///
/// **Needs you (R32).** A session is in an *episode* from the evaluation that
/// first sees it in Needs you until the one that sees it anywhere else (or not
/// at all). The episode is per row key — pid and process start — so `/clear`
/// changing the session id does not start another. After the hold-down (three
/// seconds: a prompt answered at once never shows a banner) the planner asks
/// the app whether that session's tab is on screen, and posts unless it is. The
/// notification is withdrawn when the episode ends, and a new episode is a new
/// notification.
///
/// **Startup.** Sessions already in Needs you at the first evaluation are one
/// group: they post as a single summary, not one banner each. Banners a
/// previous run left on screen are reconciled against that same first list —
/// kept and adopted when their session is still waiting, withdrawn when not —
/// so a restart never posts a second banner for an episode already announced.
///
/// **Your turn (R33).** An owned session entering Your turn after a turn of at
/// least thirty seconds gets one notification. A turn runs from the first time
/// the planner sees the session working to the moment it stops; waiting for a
/// permission in the middle does not end it.
///
/// Unknown-status rows never notify: they are not in Needs you, and a guess
/// must not become a banner (R11).
public struct NotificationPlanner {
    public static let defaultHoldDown: TimeInterval = 3
    public static let defaultMinimumTurn: TimeInterval = 30

    public let holdDown: TimeInterval
    public let minimumTurn: TimeInterval

    private enum Phase: Equatable {
        /// Not in a Needs-you episode.
        case idle
        /// In one, and the hold-down is running or waiting for authorization.
        case holding(since: Date)
        /// Hold-down over; waiting for the terminal's answer.
        case awaitingFrontmost(terminalID: String)
        /// Hold-down and frontmost check passed, waiting for the startup
        /// group to be complete.
        case cleared
        /// Decided against: the tab was on screen, or notifications are off
        /// or denied. The episode never posts.
        case suppressed
        case posted(String)
        /// Covered by the startup summary.
        case summarised
    }

    private struct Track {
        var status: SessionStatus?
        var episode = 0
        var phase = Phase.idle
        var turnStart: Date?
        var turnCount = 0
        var yourTurnPosted: String?
    }

    private var tracks: [LiveSessionKey: Track] = [:]
    private var started = false
    private var seed: [DeliveredNotification] = []
    /// Sessions in Needs you at the first evaluation and not adopted from a
    /// delivered banner: posted together once all are decided.
    private var startupGroup: Set<LiveSessionKey> = []
    private var summary: (identifier: String, members: Set<LiveSessionKey>)?

    public init(holdDown: TimeInterval = NotificationPlanner.defaultHoldDown, minimumTurn: TimeInterval = NotificationPlanner.defaultMinimumTurn) {
        self.holdDown = holdDown
        self.minimumTurn = minimumTurn
    }

    /// Hands the planner what macOS still shows from an earlier run. Only
    /// read by the first `evaluate`, so call it before that.
    public mutating func seed(delivered: [DeliveredNotification]) {
        guard !started else { return }
        seed = delivered
    }

    public mutating func evaluate(_ input: NotificationInput) -> NotificationPlan {
        var plan = NotificationPlan()
        let now = input.now

        var seen = Set<LiveSessionKey>()
        let sessions = input.live.filter { seen.insert($0.key).inserted }
        let baseline = !started
        started = true

        // Sessions that went away: take back what they posted.
        for key in Array(tracks.keys) where !seen.contains(key) {
            if let track = tracks[key] {
                withdrawNeedsYou(of: track, into: &plan)
                if let id = track.yourTurnPosted { plan.withdrawals.append(id) }
            }
            startupGroup.remove(key)
            tracks[key] = nil
        }

        let adoption = baseline ? adopt(sessions: sessions, into: &plan) : Adoption()
        if baseline { seed = [] }

        for session in sessions {
            let key = session.key
            var track = tracks[key] ?? Track()
            let previous = track.status
            if tracks[key] == nil, let id = adoption.needsYou[key] {
                track.episode = 1
                track.phase = .posted(id)
            }
            if tracks[key] == nil, adoption.summaryMembers.contains(key) {
                track.episode = 1
                track.phase = .summarised
            }
            if tracks[key] == nil, let id = adoption.yourTurn[key] {
                track.yourTurnPosted = id
            }

            // A turn opens the first time the session is seen working. Its
            // own registry timestamp says when it really began when that is
            // earlier than this observation (an app started mid-turn).
            if session.status == .working, track.turnStart == nil {
                track.turnStart = min(now, session.statusUpdatedAt ?? now)
            }

            if session.status != .yourTurn, let id = track.yourTurnPosted {
                plan.withdrawals.append(id)
                track.yourTurnPosted = nil
            }

            if session.status == .needsYou {
                if track.phase == .idle {
                    track.episode += 1
                    track.phase = .holding(since: now)
                    if baseline { startupGroup.insert(key) }
                }
            } else {
                withdrawNeedsYou(of: track, into: &plan)
                track.phase = .idle
                startupGroup.remove(key)
            }

            if session.status == .yourTurn, previous != nil, previous != .yourTurn {
                if let start = track.turnStart,
                   now.timeIntervalSince(start) >= minimumTurn,
                   input.owned.contains(key),
                   input.settings.yourTurn,
                   input.authorization == .authorized {
                    track.turnCount += 1
                    let note = Self.yourTurnNote(for: session, turnCount: track.turnCount, length: now.timeIntervalSince(start), title: input.title(session))
                    plan.posts.append(note)
                    track.yourTurnPosted = note.identifier
                }
                track.turnStart = nil
            }

            track.status = session.status
            tracks[key] = track
        }

        resolveNeedsYou(sessions: sessions, input: input, into: &plan)
        emitStartupGroup(sessions: sessions, input: input, into: &plan)
        reconcileSummary(into: &plan)

        // The earliest hold-down still running.
        plan.nextDeadline = tracks.values.compactMap { track -> Date? in
            guard case .holding(let since) = track.phase else { return nil }
            let due = since.addingTimeInterval(holdDown)
            return due > now ? due : nil
        }.min()
        return plan
    }

    // MARK: Needs you

    /// Whether a Needs-you notification may be posted right now.
    private enum Gate { case open, closed, later }

    private func gate(_ input: NotificationInput) -> Gate {
        guard input.settings.needsYou else { return .closed }
        switch input.authorization {
        case .denied: return .closed
        case .notDetermined: return .later
        case .authorized: return .open
        }
    }

    /// The single place an episode moves from holding to a decision.
    private mutating func resolveNeedsYou(sessions: [LiveSession], input: NotificationInput, into plan: inout NotificationPlan) {
        let now = input.now
        let gate = gate(input)
        var asked = Set<String>()

        // The toggle turned off, or authorization withdrawn, takes back what
        // is showing. The episode stays decided: turning it on again in the
        // middle of one does not announce it after the fact.
        if gate == .closed {
            for (key, var track) in tracks {
                guard case .posted(let id) = track.phase, track.status == .needsYou else { continue }
                plan.withdrawals.append(id)
                track.phase = .suppressed
                tracks[key] = track
            }
            if let summary {
                plan.withdrawals.append(summary.identifier)
                for key in summary.members { tracks[key]?.phase = .suppressed }
                self.summary = nil
            }
        }

        for session in sessions {
            let key = session.key
            guard var track = tracks[key] else { continue }

            var freshExpiry = false
            switch track.phase {
            case .holding(let since):
                guard now.timeIntervalSince(since) >= holdDown else { continue }
                freshExpiry = true
            case .awaitingFrontmost:
                break
            default:
                continue
            }

            switch gate {
            case .closed:
                track.phase = .suppressed
            case .later:
                break
            case .open:
                // A session AgentMenu cannot place in a terminal, or that has
                // no tty, cannot be frontmost: nothing to ask.
                guard let terminalID = session.terminal.id, let tty = TerminalFocus.deviceForm(session.tty) else {
                    clear(session, &track, input: input, into: &plan)
                    break
                }
                if let answer = input.frontmost[terminalID] {
                    if case .selectedTTY(let front) = answer, TerminalFocus.deviceForm(front) == tty {
                        track.phase = .suppressed
                    } else {
                        clear(session, &track, input: input, into: &plan)
                    }
                } else {
                    track.phase = .awaitingFrontmost(terminalID: terminalID)
                    // Only a fresh hold-down expiry asks; a session already
                    // waiting on an answer is not asked about again.
                    if freshExpiry, asked.insert(terminalID).inserted {
                        plan.frontmostChecks.append(FrontmostCheck(terminalID: terminalID))
                    }
                }
            }
            tracks[key] = track
        }
    }

    /// Hold-down and frontmost check both passed: post now, or wait for the
    /// rest of the startup group.
    private mutating func clear(_ session: LiveSession, _ track: inout Track, input: NotificationInput, into plan: inout NotificationPlan) {
        if startupGroup.contains(session.key) {
            track.phase = .cleared
            return
        }
        let note = Self.needsYouNote(for: session, episode: track.episode, title: input.title(session))
        plan.posts.append(note)
        track.phase = .posted(note.identifier)
    }

    /// The startup group posts once every member has been decided: one banner
    /// for one waiting session, a single summary for several.
    private mutating func emitStartupGroup(sessions: [LiveSession], input: NotificationInput, into plan: inout NotificationPlan) {
        guard !startupGroup.isEmpty else { return }
        let members = startupGroup
        let undecided = members.contains { key in
            switch tracks[key]?.phase {
            case .holding, .awaitingFrontmost: return true
            default: return false
            }
        }
        guard !undecided else { return }
        startupGroup = []

        let byKey = Dictionary(uniqueKeysWithValues: sessions.map { ($0.key, $0) })
        let cleared = members
            .compactMap { key -> LiveSession? in
                guard tracks[key]?.phase == .cleared else { return nil }
                return byKey[key]
            }
            .sorted { ($0.startedAt, $0.pid) < ($1.startedAt, $1.pid) }

        switch cleared.count {
        case 0:
            return
        case 1:
            let session = cleared[0]
            let note = Self.needsYouNote(for: session, episode: tracks[session.key]?.episode ?? 1, title: input.title(session))
            plan.posts.append(note)
            tracks[session.key]?.phase = .posted(note.identifier)
        default:
            let note = Self.summaryNote(for: cleared, titles: cleared.map(input.title))
            plan.posts.append(note)
            summary = (note.identifier, Set(cleared.map(\.key)))
            for session in cleared { tracks[session.key]?.phase = .summarised }
        }
    }

    /// The summary goes when the last session it covers stops waiting.
    private mutating func reconcileSummary(into plan: inout NotificationPlan) {
        guard let current = summary else { return }
        let members = current.members.filter { tracks[$0]?.phase == .summarised }
        if members.isEmpty {
            plan.withdrawals.append(current.identifier)
            summary = nil
        } else {
            summary = (current.identifier, members)
        }
    }

    private func withdrawNeedsYou(of track: Track, into plan: inout NotificationPlan) {
        if case .posted(let id) = track.phase { plan.withdrawals.append(id) }
    }

    // MARK: Startup reconciliation

    private struct Adoption {
        var needsYou: [LiveSessionKey: String] = [:]
        var yourTurn: [LiveSessionKey: String] = [:]
        var summaryMembers: Set<LiveSessionKey> = []
    }

    /// Matches what an earlier run left on screen against the first list. A
    /// banner whose session is still in the state it announced is adopted — it
    /// stays, and nothing is posted for that episode again; any other is
    /// withdrawn.
    private mutating func adopt(sessions: [LiveSession], into plan: inout NotificationPlan) -> Adoption {
        var adoption = Adoption()
        func match(_ token: String, _ status: SessionStatus) -> LiveSession? {
            sessions.first { $0.status == status && Self.token($0.key) == token }
        }
        for note in seed {
            switch note.kind {
            case .needsYou:
                if let token = note.rowTokens.first, let session = match(token, .needsYou), adoption.needsYou[session.key] == nil {
                    adoption.needsYou[session.key] = note.identifier
                } else {
                    plan.withdrawals.append(note.identifier)
                }
            case .yourTurn:
                if let token = note.rowTokens.first, let session = match(token, .yourTurn), adoption.yourTurn[session.key] == nil {
                    adoption.yourTurn[session.key] = note.identifier
                } else {
                    plan.withdrawals.append(note.identifier)
                }
            case .needsYouSummary:
                let members = Set(note.rowTokens.compactMap { match($0, .needsYou)?.key })
                if members.isEmpty || summary != nil {
                    plan.withdrawals.append(note.identifier)
                } else {
                    summary = (note.identifier, members)
                    adoption.summaryMembers = members
                }
            }
        }
        return adoption
    }

    // MARK: Wording

    /// The row key a notification carries (`userInfo`), the same hash a row's
    /// accessibility identifier uses.
    public static func token(_ key: LiveSessionKey) -> String {
        AccessibilityID.Popover.Sessions.liveRowKey(key)
    }

    static func needsYouNote(for session: LiveSession, episode: Int, title: String) -> PlannedNotification {
        let token = token(session.key)
        return PlannedNotification(
            identifier: "\(NotificationKind.needsYou.rawValue).\(token).\(episode)",
            kind: .needsYou,
            rowTokens: [token],
            title: NotificationText.needsYouTitle(name: title),
            body: NotificationText.needsYouBody(waitingFor: session.waitingFor, folder: NotificationText.folderName(session.cwd)),
            threadID: NotificationText.thread(session.cwd)
        )
    }

    static func yourTurnNote(for session: LiveSession, turnCount: Int, length: TimeInterval, title: String) -> PlannedNotification {
        let token = token(session.key)
        return PlannedNotification(
            identifier: "\(NotificationKind.yourTurn.rawValue).\(token).\(turnCount)",
            kind: .yourTurn,
            rowTokens: [token],
            title: NotificationText.yourTurnTitle(name: title),
            body: NotificationText.yourTurnBody(length: length, folder: NotificationText.folderName(session.cwd)),
            threadID: NotificationText.thread(session.cwd)
        )
    }

    static func summaryNote(for sessions: [LiveSession], titles: [String]) -> PlannedNotification {
        PlannedNotification(
            identifier: "\(NotificationKind.needsYou.rawValue).summary",
            kind: .needsYouSummary,
            rowTokens: sessions.map { token($0.key) },
            title: "\(sessions.count) sessions need you",
            body: NotificationText.summaryBody(names: titles),
            threadID: "needs-you.summary"
        )
    }
}

// MARK: - Words

/// The text of a notification, in one place so a test can pin what a banner
/// says and the planner stays about timing.
public enum NotificationText {
    /// A name when nothing better is known: the registry's, else the agent's.
    public static func defaultTitle(_ session: LiveSession) -> String {
        session.registryName.trimmedNonEmpty ?? session.agentDisplayName
    }

    /// The last component of a working directory; nil for none.
    public static func folderName(_ cwd: String?) -> String? { SessionRowWording.folderName(cwd) }

    static func thread(_ cwd: String?) -> String { cwd ?? "no-folder" }

    public static func needsYouTitle(name: String) -> String { "\(name) needs you" }

    public static func needsYouBody(waitingFor: String?, folder: String?) -> String {
        let reason = waitingFor.flatMap { SessionStatusMapping.needsYouLabels[$0] } ?? "Waiting for you"
        guard let folder else { return reason }
        return "\(reason) in \(folder)"
    }

    public static func yourTurnTitle(name: String) -> String { "\(name) is ready" }

    public static func yourTurnBody(length: TimeInterval, folder: String?) -> String {
        let seconds = Int(length.rounded())
        let took = seconds < 90 ? "\(seconds)s" : "\(seconds / 60)m"
        guard let folder else { return "Your turn, after \(took)" }
        return "Your turn in \(folder), after \(took)"
    }

    public static func summaryBody(names: [String]) -> String {
        let shown = names.prefix(3).joined(separator: ", ")
        let more = names.count - 3
        return more > 0 ? "\(shown), and \(more) more" : shown
    }
}
