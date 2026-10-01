// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// What Quit and Quit all do and when they ask first (U12, R19 to R21, KTD11):
// pure functions over what the Sessions tab already knows, so each rule is a
// call a test makes instead of a dialog someone has to provoke.

/// One live session as a quit sees it.
public struct QuitCandidate: Equatable, Sendable {
    public let key: LiveSessionKey
    /// The name the row shows, for the dialog.
    public let name: String
    public let status: SessionStatus
    /// AgentMenu launched or restored it (R20): the ledger follows it, or it
    /// sits in a pane of AgentMenu's own host.
    public let isOwned: Bool
    /// The account it is attributed to, for the per-account count; nil for an
    /// agent with no registry.
    public let accountName: String?

    public init(key: LiveSessionKey, name: String, status: SessionStatus, isOwned: Bool, accountName: String? = nil) {
        self.key = key
        self.name = name
        self.status = status
        self.isOwned = isOwned
        self.accountName = accountName
    }

    /// Working is the one status with a turn in flight whose answer a quit
    /// throws away (R21). Waiting on the user, or at the user's turn, is not.
    public var isWorking: Bool { status == .working }
}

/// What the dialog says. The app shows it as an `NSAlert` and never composes
/// wording of its own.
public struct QuitConfirmation: Equatable, Sendable {
    public let title: String
    public let message: String
    /// The affirmative button: "Quit" or "Quit all".
    public let confirmTitle: String
    public let cancelTitle: String
    /// How many of the affected sessions are Working.
    public let workingCount: Int

    public init(title: String, message: String, confirmTitle: String, cancelTitle: String = "Cancel", workingCount: Int) {
        self.title = title
        self.message = message
        self.confirmTitle = confirmTitle
        self.cancelTitle = cancelTitle
        self.workingCount = workingCount
    }
}

/// What to do for one Quit or one Quit all.
public struct QuitPlan: Equatable, Sendable {
    /// Every session to signal, in the order given.
    public let targets: [QuitCandidate]
    /// What to record in the ledger for the owned targets before signalling.
    /// An unowned target has no ledger row and gets nothing recorded.
    public let cause: EndCause
    /// nil when it acts immediately (R21).
    public let confirmation: QuitConfirmation?

    public init(targets: [QuitCandidate], cause: EndCause, confirmation: QuitConfirmation?) {
        self.targets = targets
        self.cause = cause
        self.confirmation = confirmation
    }

    public var isEmpty: Bool { targets.isEmpty }
}

public enum QuitPolicy {
    /// KTD11: the wording that makes the cost of a mid-turn quit plain.
    static let lostTurnNote = "Quitting now loses the answer it is working on."
    static let keptNote = "The conversation up to your last message is kept."

    /// Quit on one row (R19): any live session, owned or not. An owned one is
    /// recorded as `individual`; an unowned one has nothing to record.
    public static func planQuit(_ session: QuitCandidate) -> QuitPlan {
        QuitPlan(
            targets: [session],
            cause: .individual,
            confirmation: confirmation(forOne: session)
        )
    }

    /// Quit all (R20): every owned live session in every account, whichever
    /// pill is selected and keep-running or not, and no unowned one. A session
    /// listed twice is quit once.
    public static func planQuitAll(live: [QuitCandidate]) -> QuitPlan {
        var seen = Set<LiveSessionKey>()
        let targets = live.filter { $0.isOwned && seen.insert($0.key).inserted }
        return QuitPlan(
            targets: targets,
            cause: .together,
            confirmation: confirmation(forAll: targets)
        )
    }

    /// How many Quit all would end: the header item's count.
    public static func quitAllCount(live: [QuitCandidate]) -> Int {
        planQuitAll(live: live).targets.count
    }

    // MARK: The dialog

    private static func confirmation(forOne session: QuitCandidate) -> QuitConfirmation? {
        guard session.isWorking else { return nil }
        let name = quoted(session.name)
        return QuitConfirmation(
            title: "Quit \(name)?",
            message: "It is working on a turn. \(lostTurnNote) \(keptNote)",
            confirmTitle: "Quit",
            workingCount: 1
        )
    }

    private static func confirmation(forAll targets: [QuitCandidate]) -> QuitConfirmation? {
        let working = targets.filter(\.isWorking)
        guard !working.isEmpty else { return nil }

        var lines: [String] = []
        lines.append("This ends \(count(targets.count, "session")) AgentMenu started" + perAccount(targets) + ".")
        let names = working.prefix(3).map { quoted($0.name) }
        let rest = working.count - names.count
        let list = names.joined(separator: ", ") + (rest > 0 ? " and \(rest) more" : "")
        if working.count == 1 {
            lines.append("\(list) is working on a turn. \(lostTurnNote)")
        } else {
            lines.append("\(working.count) are working on a turn (\(list)). Quitting now loses the answers they are working on.")
        }
        lines.append("Sessions AgentMenu did not start keep running. \(keptNote)")
        return QuitConfirmation(
            title: "Quit all (\(targets.count))?",
            message: lines.joined(separator: " "),
            confirmTitle: "Quit all",
            workingCount: working.count
        )
    }

    /// " (Work 2, Personal 1)" for sessions across more than one account, in
    /// order of first appearance; empty when one account holds them all and no
    /// breakdown tells anything. A session with no account counts as "Other".
    static func perAccount(_ targets: [QuitCandidate]) -> String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for target in targets {
            let account = target.accountName ?? "Other"
            if counts[account] == nil { order.append(account) }
            counts[account, default: 0] += 1
        }
        guard order.count > 1 else {
            return order.first.map { $0 == "Other" ? "" : " in \($0)" } ?? ""
        }
        return " (" + order.map { "\($0) \(counts[$0] ?? 0)" }.joined(separator: ", ") + ")"
    }

    private static func quoted(_ name: String) -> String { "\u{201C}\(name)\u{201D}" }

    private static func count(_ n: Int, _ noun: String) -> String { n == 1 ? "1 \(noun)" : "\(n) \(noun)s" }
}
