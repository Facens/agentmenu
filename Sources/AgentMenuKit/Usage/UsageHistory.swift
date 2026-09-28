// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One window's movement inside a single clock hour.
///
/// Four numbers rather than two: the first and last usage seen in that hour, and
/// the first and last reset epoch. The reset pair is what makes a window rollover
/// visible after the fact — without it, usage dropping from 80 to 5 is
/// indistinguishable from a correction.
public struct WindowObservation: Equatable {
    public let usedFirst: Double
    public let usedLast: Double
    public let resetFirst: Date
    public let resetLast: Date

    public init(usedFirst: Double, usedLast: Double, resetFirst: Date, resetLast: Date) {
        self.usedFirst = usedFirst
        self.usedLast = usedLast
        self.resetFirst = resetFirst
        self.resetLast = resetLast
    }
}

/// One line of `tb-rate-history.jsonl`: a local clock hour, and what each window
/// did inside it.
public struct UsageHistoryRow: Equatable {
    public let hourStart: Date
    public let windows: [UsageWindowKind: WindowObservation]

    public init(hourStart: Date, windows: [UsageWindowKind: WindowObservation]) {
        self.hourStart = hourStart
        self.windows = windows
    }
}

/// The rate-limit history a status-line bridge appends to, one row per local
/// clock hour, kept for 28 days.
///
/// Like the snapshot, this file is written by another process and read here: a
/// malformed line is skipped rather than fatal, because a history that refuses
/// to load takes the projection down with it for no gain.
public struct UsageHistory: Equatable {
    public static let retention: TimeInterval = 28 * 86_400
    public static let fileName = "tb-rate-history.jsonl"

    /// Sorted by hour, oldest first, nothing older than `retention`.
    public let rows: [UsageHistoryRow]

    public init(rows: [UsageHistoryRow]) {
        self.rows = rows.sorted { $0.hourStart < $1.hourStart }
    }

    public var isEmpty: Bool { rows.isEmpty }

    public static func parse(_ text: String, now: Date = Date()) -> UsageHistory {
        var rows: [UsageHistoryRow] = []
        let cutoff = now.addingTimeInterval(-retention)

        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let json = object as? [String: Any],
                  let hour = json["h"] as? NSNumber else { continue }

            let hourStart = Date(timeIntervalSince1970: hour.doubleValue)
            guard hourStart >= cutoff else { continue }

            var windows: [UsageWindowKind: WindowObservation] = [:]
            for kind in UsageWindowKind.allCases {
                guard let raw = json[kind.rawValue] as? [Any], raw.count == 4,
                      let usedFirst = (raw[0] as? NSNumber)?.doubleValue,
                      let usedLast = (raw[1] as? NSNumber)?.doubleValue,
                      let resetFirst = (raw[2] as? NSNumber)?.doubleValue,
                      let resetLast = (raw[3] as? NSNumber)?.doubleValue else { continue }
                windows[kind] = WindowObservation(
                    usedFirst: usedFirst,
                    usedLast: usedLast,
                    resetFirst: Date(timeIntervalSince1970: resetFirst),
                    resetLast: Date(timeIntervalSince1970: resetLast)
                )
            }
            guard !windows.isEmpty else { continue }
            rows.append(UsageHistoryRow(hourStart: hourStart, windows: windows))
        }
        return UsageHistory(rows: rows)
    }

    /// Reads the history file, or nil when there is none — the projection then
    /// simply does not appear, the same way the readout hides itself (R25).
    public static func read(at url: URL, now: Date = Date()) -> UsageHistory? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let history = parse(text, now: now)
        return history.isEmpty ? nil : history
    }

    /// The history sits beside the snapshot the manifest declares, so one
    /// template locates both.
    public static func path(snapshotTemplate: String, profileDirectory: URL) -> URL {
        UsageReader.resolvePath(template: snapshotTemplate, profileDirectory: profileDirectory)
            .deletingLastPathComponent()
            .appendingPathComponent(fileName)
    }
}

// MARK: - One account per history
//
// Two Claude accounts on one machine can end up writing into the same config
// directory's history and snapshot (a bare `claude` with no
// `CLAUDE_CONFIG_DIR` reads whichever login the keychain hands it, yet always
// writes into `~/.claude`). Interleaved like that, every flip back to the
// other account's weekly window looked like a fresh window starting from
// zero, and 2% of a work week projected 189%.
//
// The weekly reset is the fingerprint: each account resets its `seven_day`
// window at its own point in the week, and a rollover moves it by whole
// weeks. `weeklyPhase` is the reset point this history has seen most of over
// the last week; `trimmed` uses it to strip out rows (or the parts of rows)
// that belong to a different phase, so a projection built from this history
// never counts a stranger's usage as this account's own.
//
// This is a port of the identically-named idea in the team status-line
// script that writes these files (`assets/statusline-command.sh`, the
// "--- one account per history ---" block) — read the comment there for why
// there is deliberately no recency override: a payload on the wrong phase is
// never treated as current, so an old file only heals by this trim aging the
// wrong phase out of the retention window, never by simply following
// whoever wrote most recently.
extension UsageHistory {
    /// Length of the billing week the `seven_day` window repeats on.
    public static let week: TimeInterval = 7 * 86_400

    /// True when two points in time sit within an hour of the same point in
    /// the weekly cycle. An hour of slack absorbs the server's own rounding
    /// and ordinary clock skew, while staying far short of the day-or-more
    /// gap between two real accounts' reset points.
    public static func samePhase(_ a: Date, _ b: Date) -> Bool {
        let weekSeconds = Int(week)
        let diff = Int(a.timeIntervalSince1970.rounded()) - Int(b.timeIntervalSince1970.rounded())
        // Swift's `%` is a remainder, not a modulo: for a negative `diff` it
        // returns a negative result, which would make `min(d, week - d)`
        // negative too — and so <= 3600 for *any* later reset, matching
        // everything instead of only what is actually close in phase.
        let remainder = ((diff % weekSeconds) + weekSeconds) % weekSeconds
        return min(remainder, weekSeconds - remainder) <= 3600
    }

    /// The weekly reset point this history has seen most of over the last
    /// week — this account's fingerprint. Considers only rows from the last
    /// week (an older phase this history has moved away from must not keep
    /// winning) and both `resetFirst` and `resetLast` of each row's
    /// `seven_day` observation, since a row that straddles a rollover
    /// carries one of each. Ties go to the cluster last seen. Nil when there
    /// is not enough `seven_day` evidence yet to say anything — the caller
    /// then leaves every row alone.
    public static func weeklyPhase(rows: [UsageHistoryRow], now: Date) -> Date? {
        struct Cluster { let representative: Date; var count: Int; var latest: Date }
        var clusters: [Cluster] = []
        let cutoff = now.addingTimeInterval(-week)
        for row in rows where row.hourStart >= cutoff {
            guard let seven = row.windows[.sevenDay] else { continue }
            for reset in [seven.resetFirst, seven.resetLast] {
                if let index = clusters.firstIndex(where: { samePhase($0.representative, reset) }) {
                    clusters[index].count += 1
                    clusters[index].latest = max(clusters[index].latest, row.hourStart)
                } else {
                    clusters.append(Cluster(representative: reset, count: 1, latest: row.hourStart))
                }
            }
        }
        guard var best = clusters.first else { return nil }
        for cluster in clusters.dropFirst()
        where cluster.count > best.count || (cluster.count == best.count && cluster.latest > best.latest) {
            best = cluster
        }
        return best.representative
    }

    /// `rows`, with anything that belongs to a different weekly phase
    /// trimmed or dropped.
    ///
    /// A row whose `seven_day` observation matches `phase` at both ends is
    /// kept as-is. One end matching (the row straddles the rollover, or a
    /// merge inside one hour crossed it) keeps only the matching reading,
    /// collapsed to a first-equals-last pair. Neither end matching means
    /// nothing in that hour is known to be this account's — its `five_hour`
    /// reading almost certainly came from the same foreign session, so it is
    /// dropped too, and the row disappears entirely once both windows are
    /// gone.
    ///
    /// A row with no `seven_day` observation at all — a `five_hour`-only
    /// reading — is left untouched: nothing about it is known to belong to a
    /// different account.
    public static func trimmed(rows: [UsageHistoryRow], toPhase phase: Date) -> [UsageHistoryRow] {
        rows.compactMap { row -> UsageHistoryRow? in
            guard let seven = row.windows[.sevenDay] else { return row }
            let matchesFirst = samePhase(phase, seven.resetFirst)
            let matchesLast = samePhase(phase, seven.resetLast)
            var windows = row.windows
            if matchesFirst, matchesLast {
                // Unchanged.
            } else if matchesFirst {
                windows[.sevenDay] = WindowObservation(
                    usedFirst: seven.usedFirst, usedLast: seven.usedFirst,
                    resetFirst: seven.resetFirst, resetLast: seven.resetFirst
                )
            } else if matchesLast {
                windows[.sevenDay] = WindowObservation(
                    usedFirst: seven.usedLast, usedLast: seven.usedLast,
                    resetFirst: seven.resetLast, resetLast: seven.resetLast
                )
            } else {
                windows.removeValue(forKey: .sevenDay)
                windows.removeValue(forKey: .fiveHour)
            }
            return windows.isEmpty ? nil : UsageHistoryRow(hourStart: row.hourStart, windows: windows)
        }
    }

    /// The read-side half of the fix: the history a projection should
    /// actually be built from, with any foreign-account rows filtered out,
    /// plus the phase that was used to filter them (nil, and `self`
    /// unchanged, when there was not enough evidence yet to establish one).
    public func trimmedToOwnPhase(now: Date) -> (history: UsageHistory, phase: Date?) {
        guard let phase = UsageHistory.weeklyPhase(rows: rows, now: now) else { return (self, nil) }
        return (UsageHistory(rows: UsageHistory.trimmed(rows: rows, toPhase: phase)), phase)
    }
}
