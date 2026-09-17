// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// How close an account is to its limit, in the four steps the menu-bar
/// indicator distinguishes (R23-R25 govern what may be shown; this decides
/// when it is worth showing at all).
///
/// The thresholds are on the *used* percentage of the worst window, not on a
/// projection: a projection is a guess about the future and the menu bar is
/// not the place to argue one. What the icon reports is the reading.
public enum UsageAlertLevel: Int, Comparable, CaseIterable {
    /// Below `caution`. The icon says nothing — a menu bar that always has
    /// something to say is a menu bar nobody reads.
    case normal
    case caution
    case warning
    case exhausted

    public static func < (lhs: UsageAlertLevel, rhs: UsageAlertLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// Where each step begins, as a used percentage.
    public static let cautionAt: Double = 80
    public static let warningAt: Double = 90
    public static let exhaustedAt: Double = 100

    public init(usedPercentage: Double) {
        switch usedPercentage {
        case ..<Self.cautionAt: self = .normal
        case ..<Self.warningAt: self = .caution
        case ..<Self.exhaustedAt: self = .warning
        default: self = .exhausted
        }
    }
}

/// The worst window of one account, and how bad it is.
public struct UsageAlert: Equatable {
    public let level: UsageAlertLevel
    public let kind: UsageWindowKind
    public let usedPercentage: Double
    public let resetsAt: Date
    /// How old the reading behind this is. Carried so the caller can say so
    /// rather than presenting an hours-old number as the state right now.
    public let age: TimeInterval

    public init(level: UsageAlertLevel, kind: UsageWindowKind, usedPercentage: Double, resetsAt: Date, age: TimeInterval) {
        self.level = level
        self.kind = kind
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
        self.age = age
    }

    /// The worst window worth reporting, or nil when there is nothing to say.
    ///
    /// A window past its own `resets_at` is excluded: the counter has reset
    /// server-side, so a stored 100% describes an instance that no longer
    /// exists, and putting a red badge in the menu bar for it would be a
    /// false alarm that outlives the limit it reports (R24).
    ///
    /// Staleness does not exclude — an old reading of 97% is still the last
    /// thing known, and dropping it would quietly replace "97%, read an hour
    /// ago" with "nothing to report". The age travels with the alert so the
    /// tooltip can qualify it.
    public static func worst(
        in snapshot: UsageSnapshot,
        now: Date = Date(),
        staleAfter: TimeInterval
    ) -> UsageAlert? {
        let age = snapshot.age(now: now)
        let candidates = snapshot.windows.filter {
            $0.state(now: now, age: age, staleAfter: staleAfter) != .rolledOver
        }
        guard let worst = candidates.max(by: { $0.usedPercentage < $1.usedPercentage }) else { return nil }
        let level = UsageAlertLevel(usedPercentage: worst.usedPercentage)
        guard level > .normal else { return nil }
        return UsageAlert(
            level: level,
            kind: worst.kind,
            usedPercentage: worst.usedPercentage,
            resetsAt: worst.resetsAt,
            age: age
        )
    }

    /// What the menu bar shows beside the glyph. Short on purpose: the menu
    /// bar is shared with every other app, and this one is not entitled to
    /// more of it than a number.
    public var badge: String {
        level == .exhausted ? "out" : "\(Int(usedPercentage.rounded()))%"
    }
}
