// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AgentMenuKit

/// The 5-hour and weekly readout (R23, R24, R25).
///
/// It hides itself when there is nothing to show, and it never presents a value
/// as current when it is not: the reading only refreshes while an agent session
/// runs, so its age is part of the value, and a window past its reset is shown
/// as reset rather than as a percentage nobody should act on.
struct UsageStrip: View {
    let reading: UsageReading
    /// Absent when there is no history to project from, which is most machines
    /// until the status-line bridge has been running for a while.
    var projector: UsageProjector?
    var now: Date = Date()
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        switch reading {
        case .unavailable, .refused:
            EmptyView()                             // R25
        case .available(let snapshot):
            if snapshot.windows.isEmpty {
                EmptyView()
            } else {
                content(snapshot)
            }
        }
    }

    private func content(_ snapshot: UsageSnapshot) -> some View {
        let age = snapshot.age(now: now)
        let stale = age > UsageReader.defaultStaleAfter
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Rate limits")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("read \(UsageSnapshot.describeAge(age))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            // Every window Claude Code reports gets a line, present or not.
            // A window is absent from the snapshot whenever the last payload
            // did not carry it and the stored one had passed its own reset —
            // ordinary, and on this machine the common case: across both
            // accounts' histories, half the observations carry `seven_day`
            // alone. Dropping the line entirely made an account look like it
            // had lost its 5-hour readout; a line that says it has no current
            // window says the true thing instead.
            ForEach(UsageWindowKind.allCases, id: \.self) { kind in
                if let window = snapshot.window(kind) {
                    row(window, age: age, stale: stale)
                } else {
                    missingRow(kind)
                }
            }
            projections(snapshot)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .cardSurface()
    }

    private func row(_ window: UsageWindow, age: TimeInterval, stale: Bool) -> some View {
        let state = window.state(now: now, age: age, staleAfter: UsageReader.defaultStaleAfter)
        return HStack(spacing: 8) {
            Text(label(window.kind))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .leading)
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(scheme == .dark ? 0.14 : 0.09))
                    if state != .rolledOver {
                        Capsule()
                            .fill(Color.brandAccent(scheme).opacity(stale ? 0.5 : 1))
                            .frame(width: max(0, min(1, window.usedPercentage / 100)) * geometry.size.width)
                    }
                }
            }
            .frame(height: 5)
            Text(state == .rolledOver ? "reset" : "\(Int(window.usedPercentage.rounded()))%")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(state == .current ? .primary : .secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(window, state: state, age: age))
        .accessibilityIdentifier(AccessibilityID.Popover.usageWindow(window.kind.rawValue))
    }

    /// A window the snapshot does not carry. Not zero, not stale — no
    /// reading at all, which for the 5-hour window means nothing has been
    /// spent since it last reset.
    private func missingRow(_ kind: UsageWindowKind) -> some View {
        HStack(spacing: 8) {
            Text(label(kind))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .leading)
            Capsule()
                .fill(Color.primary.opacity(scheme == .dark ? 0.14 : 0.09))
                .frame(height: 5)
            Text("—")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.tertiary)
                .frame(width: 36, alignment: .trailing)
        }
        .help("No current \(label(kind)) window: nothing has been spent since it last reset.")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(label(kind)): no current window")
        .accessibilityIdentifier(AccessibilityID.Popover.usageWindow(kind.rawValue))
    }

    /// The burn-rate line: where each window is heading, not where it is.
    /// Only windows the projector will speak about appear, so a fresh window or
    /// a thin history simply says nothing rather than guessing.
    @ViewBuilder
    private func projections(_ snapshot: UsageSnapshot) -> some View {
        let lines = snapshot.windows.compactMap { window -> (warns: Bool, text: String)? in
            // An exhausted window is reported, not projected: what is left to
            // say about it is when it comes back.
            if window.usedPercentage >= 100 {
                return (true, "\(label(window.kind)) is out until \(Self.when(window.resetsAt, now: now))")
            }
            guard let projection = projector?.projection(for: window, now: now) else { return nil }
            if projection.willExhaust, let at = projection.exhaustsAt {
                return (true, "\(label(window.kind)) runs out \(Self.when(at, now: now))")
            }
            return (false, "\(label(window.kind)) on course for \(Int(projection.projectedAtReset.rounded()))%")
        }
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    HStack(spacing: 5) {
                        Image(systemName: line.warns ? "exclamationmark.triangle.fill" : "chart.line.uptrend.xyaxis")
                            .font(.system(size: 9))
                            .foregroundStyle(line.warns ? Color.brandWarning(scheme) : .secondary)
                        Text(line.text)
                            .font(.system(size: 11))
                            .foregroundStyle(line.warns ? Color.brandWarning(scheme) : .secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    /// Local time, in the shortest form that is still unambiguous.
    static func when(_ date: Date, now: Date) -> String {
        // A moment that has already passed is stated as now, not as a time in
        // the past dressed up as a prediction.
        if date <= now { return "now" }
        let formatter = DateFormatter()
        if Calendar.current.isDate(date, inSameDayAs: now) {
            formatter.dateFormat = "HH:mm"
            return "today " + formatter.string(from: date)
        }
        if date.timeIntervalSince(now) < 6 * 86_400 {
            formatter.dateFormat = "EEE HH:mm"
            return formatter.string(from: date)
        }
        formatter.dateFormat = "d MMM HH:mm"
        return formatter.string(from: date)
    }

    private func label(_ kind: UsageWindowKind) -> String {
        switch kind {
        case .fiveHour: return "5h"
        case .sevenDay: return "7d"
        }
    }

    private func accessibilityLabel(_ window: UsageWindow, state: UsageWindowState, age: TimeInterval) -> String {
        let name = window.kind == .fiveHour ? "five hour window" : "weekly window"
        switch state {
        case .rolledOver: return "\(name): reset since the last reading"
        case .stale: return "\(name): \(Int(window.usedPercentage.rounded())) percent, read \(UsageSnapshot.describeAge(age))"
        case .current: return "\(name): \(Int(window.usedPercentage.rounded())) percent"
        }
    }
}
