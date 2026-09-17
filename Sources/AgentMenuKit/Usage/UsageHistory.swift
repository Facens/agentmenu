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
