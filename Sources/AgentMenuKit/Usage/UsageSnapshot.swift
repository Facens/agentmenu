// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The two rate-limit windows Claude Code reports. Order here is the display
/// order the popover uses (R23), independent of JSON key order.
public enum UsageWindowKind: String, CaseIterable {
    case fiveHour = "five_hour"
    case sevenDay = "seven_day"
}

/// How a window's stored percentage relates to "right now".
///
/// `rolledOver` takes precedence over `stale`: once `resetsAt` has passed the
/// counter has reset server-side, so the stored percentage describes a window
/// that no longer exists, regardless of how fresh the read was (R24).
public enum UsageWindowState: Equatable {
    case current
    case stale
    case rolledOver
}

/// One rate-limit window as read from the snapshot. `usedPercentage` is
/// whatever the file said — not clamped, not rounded.
public struct UsageWindow: Equatable {
    public let kind: UsageWindowKind
    public let usedPercentage: Double
    public let resetsAt: Date

    public init(kind: UsageWindowKind, usedPercentage: Double, resetsAt: Date) {
        self.kind = kind
        self.usedPercentage = usedPercentage
        self.resetsAt = resetsAt
    }

    /// `age` is passed in (rather than computed from `now` and a stored
    /// `ts`) so a caller classifying every window in a snapshot uses one
    /// consistent age instead of drifting between per-call `Date()` reads.
    public func state(now: Date, age: TimeInterval, staleAfter: TimeInterval) -> UsageWindowState {
        if resetsAt <= now {
            return .rolledOver
        }
        return age <= staleAfter ? .current : .stale
    }
}

/// A parsed `tb-rate-snapshot.json`. Only windows actually present in the
/// file appear in `windows` — a missing window is never synthesised as zero
/// (R24).
public struct UsageSnapshot: Equatable {
    public let version: Int
    public let writtenAt: Date
    public let windows: [UsageWindow]

    public init(version: Int, writtenAt: Date, windows: [UsageWindow]) {
        self.version = version
        self.writtenAt = writtenAt
        self.windows = windows
    }

    /// Seconds between `writtenAt` and `now`. Not clamped: a `writtenAt` in
    /// the future (clock skew, a snapshot copied from another machine)
    /// yields a negative age rather than being forced to zero.
    public func age(now: Date) -> TimeInterval {
        now.timeIntervalSince(writtenAt)
    }

    public func window(_ kind: UsageWindowKind) -> UsageWindow? {
        windows.first { $0.kind == kind }
    }

    /// Renders an age for the UI. Deliberately just four buckets — this is
    /// not a general-purpose date formatter, only what the readout needs.
    public static func describeAge(_ interval: TimeInterval) -> String {
        // Clamped only for display: a negative interval (clock skew, or a
        // snapshot copied from another machine with a slightly-ahead clock)
        // still reads as "just now" rather than a confusing negative value.
        // `age(now:)` itself stays unclamped — only the label is smoothed.
        let clamped = max(interval, 0)
        if clamped < 60 {
            return "just now"
        }
        let minutes = Int(clamped / 60)
        if minutes < 60 {
            return "\(minutes)m ago"
        }
        let hours = Int(clamped / 3600)
        if hours < 24 {
            return "\(hours)h ago"
        }
        let days = Int(clamped / 86400)
        return "\(days)d ago"
    }
}

/// The result of trying to read a snapshot. `.refused` and `.unavailable`
/// are both non-error outcomes the UI must render without a special case —
/// only `.refused` carries a reason, because `.unavailable` (R25) is the
/// ordinary "no session has run yet" state, not a problem to explain.
public enum UsageReading: Equatable {
    case unavailable
    case refused(reason: String)
    case available(UsageSnapshot)
}
