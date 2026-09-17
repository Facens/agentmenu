// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What a window is on course to reach by the time it resets.
public struct UsageProjection: Equatable {
    /// Which model produced it. `wallClock` is the honest fallback used until
    /// the history knows the user's rhythm; it assumes the rest of the window
    /// looks like the part already spent.
    public enum Basis: Equatable { case learned, wallClock }

    public let kind: UsageWindowKind
    /// Percent of the quota expected to be gone at reset. Above 100 means the
    /// window runs out first.
    public let projectedAtReset: Double
    /// When the quota runs out, when it does so before the reset.
    public let exhaustsAt: Date?
    public let basis: Basis

    public var willExhaust: Bool { exhaustsAt != nil && projectedAtReset > 100 }
}

/// The burn-rate projection.
///
/// It answers one question per window: at the pace this account is actually
/// going, is the quota going to last until it resets? Two models, because a
/// straight wall-clock reading is badly wrong for anyone who works in bursts —
/// it treats the eight hours you are asleep exactly like the eight hours you
/// are working.
///
/// The learned model spends the hours ahead in proportion to how likely each
/// (weekday, hour) slot is to be active for this account, at a spend-per-active
/// -hour rate weighted towards recent activity. Both come from the same history
/// file, and it is only trusted once it holds several active days.
///
/// This is a port of the model in the status-line script that writes the file;
/// the two must agree, so the constants here are its constants.
public struct UsageProjector {
    public struct Options: Equatable {
        /// Half-life of the rate estimate, in **active** hours — a quiet weekend
        /// does not age Friday out of the estimate.
        public var halfLife: Double = 8
        /// Effective active hours required behind a rate before it is used.
        public var minEvidence: Double = 2
        /// Active days required before the activity profile is trusted.
        public var minProfileDays: Int = 5
        /// Share of a window that must have elapsed before the wall-clock model
        /// says anything. Seconds into a window the elapsed share is near zero
        /// and the projection explodes.
        public var floor: Double = 0.05

        public init() {}
    }

    public let history: UsageHistory
    public let options: Options
    private let calendar: Calendar

    private let activeHours: Set<Date>
    private let observedSlots: [Slot: Int]
    private let activeSlots: [Slot: Int]
    private let activeDays: Int

    private struct Slot: Hashable { let weekday: Int; let hour: Int }

    public init(history: UsageHistory, options: Options = Options(), calendar: Calendar = .current, now: Date = Date()) {
        self.history = history
        self.options = options
        self.calendar = calendar

        var active: Set<Date> = []
        for kind in UsageWindowKind.allCases {
            for (row, delta) in UsageProjector.deltas(kind: kind, rows: history.rows) where delta > 0 {
                active.insert(row.hourStart)
            }
        }
        self.activeHours = active

        // The chance a given (weekday, hour) is active, over the whole span the
        // history covers — not only the hours that happen to appear in it.
        var observed: [Slot: Int] = [:]
        var activeCount: [Slot: Int] = [:]
        if let first = history.rows.first?.hourStart {
            var t = first
            let end = UsageProjector.hourStart(of: now, calendar: calendar)
            while t <= end {
                let components = calendar.dateComponents([.weekday, .hour], from: t)
                let slot = Slot(weekday: components.weekday ?? 0, hour: components.hour ?? 0)
                observed[slot, default: 0] += 1
                if active.contains(t) { activeCount[slot, default: 0] += 1 }
                t = t.addingTimeInterval(3600)
            }
        }
        self.observedSlots = observed
        self.activeSlots = activeCount
        self.activeDays = Set(active.map { calendar.startOfDay(for: $0) }).count
    }

    /// The activity profile is only as good as the days behind it.
    public var isTrusted: Bool { activeDays >= options.minProfileDays }

    public func projection(for window: UsageWindow, now: Date = Date()) -> UsageProjection? {
        let length = window.kind.length
        let windowStart = window.resetsAt.addingTimeInterval(-length)
        let elapsed = now.timeIntervalSince(windowStart)

        // Outside (0, length] the payload disagrees with the assumed window
        // length: stay quiet rather than publish a number built on a bad guess.
        guard elapsed > 0, elapsed <= length, window.usedPercentage > 0 else { return nil }

        // A window already at its cap has nothing left to project. The
        // wall-clock formula does not know that: with `used` at 100 it
        // computes `windowStart + elapsed * (100 / 100)`, which is `now` —
        // so the readout said "runs out today 12:24" at 12:24, and would have
        // said 12:25 a minute later. A prediction that always names the
        // current minute is not a prediction. What to say about an exhausted
        // window is when it resets, and that is a fact the caller already
        // holds.
        guard window.usedPercentage < 100 else { return nil }

        if isTrusted {
            let (rate, evidence) = self.rate(for: window.kind, now: now)
            guard evidence >= options.minEvidence else { return nil }
            let (projected, exhausts) = project(
                used: window.usedPercentage, resetsAt: window.resetsAt, rate: rate, now: now
            )
            return UsageProjection(
                kind: window.kind,
                projectedAtReset: projected,
                exhaustsAt: exhausts.flatMap { $0 < window.resetsAt ? $0 : nil },
                basis: .learned
            )
        }

        // Wall clock: assume the rest of the window looks like the part spent.
        guard !(elapsed < length * options.floor
                || (elapsed < window.kind.legacyGate && window.usedPercentage < 50)) else { return nil }
        let expected = elapsed / length * 100
        let pace = window.usedPercentage / expected
        let exhausts = windowStart.addingTimeInterval(elapsed * (100 / window.usedPercentage))
        return UsageProjection(
            kind: window.kind,
            projectedAtReset: pace * 100,
            exhaustsAt: exhausts < window.resetsAt ? exhausts : nil,
            basis: .wallClock
        )
    }

    // MARK: The learned model

    /// Consumption attributed to the hour that first saw it, so the deltas
    /// inside one window instance sum to the highest reading that instance
    /// reached. A reset starts the count from zero again.
    ///
    /// Each instance keeps a high-water mark and only a reading above it
    /// counts. The obvious alternative — the rise from the previous row's
    /// last reading — is what this replaced, and it is wrong for the file it
    /// reads: every session of an account writes this history, each from
    /// whatever its own last server contact said, so a value moves *down*
    /// and back up without a token being spent. Counting each rise made a
    /// personal account sitting at 4% of its week report 280% of the quota
    /// as already consumed, and a projection of 167% at reset — the number
    /// that sent us looking. Under the high-water rule the same file
    /// attributes 47% across two weekly instances, which is what the
    /// readings themselves say.
    ///
    /// The cost is real and it is the right way round: a rolling window
    /// whose usage ages out and is spent again inside one instance (the
    /// 5-hour window does this) has that second spend counted only insofar
    /// as it beats the instance's peak. Under-reporting a burn rate is a
    /// dull answer; over-reporting it by an order of magnitude is a wrong
    /// one that people act on.
    public static func deltas(kind: UsageWindowKind, rows: [UsageHistoryRow]) -> [(row: UsageHistoryRow, delta: Double)] {
        var out: [(row: UsageHistoryRow, delta: Double)] = []
        var instance: Date?
        var highWater = 0.0
        for row in rows {
            guard let observation = row.windows[kind] else { continue }
            let straddlesReset = observation.resetFirst != observation.resetLast
            if instance != observation.resetLast {
                // An instance this history watched begin starts from zero:
                // everything it shows was spent inside it. The very first row
                // of the file is the exception — whatever the window already
                // held when the history opened was spent before anything here
                // could see it, so it is not attributed to this hour.
                highWater = instance == nil && !straddlesReset ? observation.usedFirst : 0
                instance = observation.resetLast
            }
            let seen = straddlesReset
                ? observation.usedLast
                : max(observation.usedFirst, observation.usedLast)
            out.append((row, max(0, seen - highWater)))
            highWater = max(highWater, seen)
        }
        return out
    }

    /// Spend per active hour, weighted towards recent activity, plus the
    /// effective number of active hours behind it.
    public func rate(for kind: UsageWindowKind, now: Date) -> (rate: Double, evidence: Double) {
        let sequence = UsageProjector.deltas(kind: kind, rows: history.rows)
            .filter { activeHours.contains($0.row.hourStart) }
        guard !sequence.isEmpty else { return (0, 0) }

        let currentHour = UsageProjector.hourStart(of: now, calendar: calendar)
        var weightSum = 0.0
        var deltaSum = 0.0
        for (index, entry) in sequence.enumerated() {
            let weight = pow(0.5, Double(sequence.count - 1 - index) / options.halfLife)
            // The hour in progress has only partly elapsed, and its delta covers
            // only that part.
            let hours = entry.row.hourStart == currentHour
                ? max(0.25, now.timeIntervalSince(currentHour) / 3600)
                : 1.0
            weightSum += weight * hours
            deltaSum += weight * entry.delta
        }
        return (weightSum > 0 ? deltaSum / weightSum : 0, weightSum)
    }

    /// Walks the hours to the reset, spending the rate on each in proportion to
    /// how likely that slot is to be active. The hour in progress counts as
    /// fully active when it already is.
    public func project(used: Double, resetsAt: Date, rate: Double, now: Date) -> (projected: Double, exhausts: Date?) {
        var remaining = 100 - used
        var expectedHours = 0.0
        var exhausts: Date?
        var t = now
        let currentHour = UsageProjector.hourStart(of: now, calendar: calendar)

        // A 7-day window is at most ~168 hourly slots, plus one for the
        // partial hour `now` sits in — a wide margin over that is a belt-
        // and-braces cap, never meant to bind in ordinary operation now that
        // the advance below is strictly monotonic. Its job is only to make
        // sure a hazard nobody has thought of yet still returns a popover
        // instead of pegging the main thread (finding #1).
        var iterations = 0
        let maxIterations = 24 * 9

        while t < resetsAt {
            iterations += 1
            guard iterations <= maxIterations else { break }

            // `hourStart(of: t) + 3600` is *not* guaranteed to land after
            // `t`: on the repeated local hour of an autumn DST transition,
            // `Calendar.date(from:)` resolves the ambiguous wall-clock hour
            // to its first occurrence, so on the second (later) occurrence
            // this boundary can equal or even precede `t` — spinning
            // forever, since `t = slotEnd` never advances. Walk the boundary
            // forward in real hour-sized steps until it's strictly past `t`,
            // which both fixes that hazard and keeps every slot hour-long
            // (rather than shrinking it to `t + 1s`, which turns the loop
            // into ~1800 one-second slots across the repeated hour and
            // truncates the walk against the iteration cap above).
            var boundary = UsageProjector.hourStart(of: t, calendar: calendar).addingTimeInterval(3600)
            while boundary <= t {
                boundary = boundary.addingTimeInterval(3600)
            }
            let slotEnd = min(boundary, resetsAt)

            let span = slotEnd.timeIntervalSince(t) / 3600
            let share = (UsageProjector.hourStart(of: t, calendar: calendar) == currentHour
                         && activeHours.contains(currentHour)) ? 1.0 : fraction(at: t)
            let burn = rate * share * span
            expectedHours += share * span
            if exhausts == nil, burn > 0, remaining - burn <= 0 {
                exhausts = t.addingTimeInterval((remaining / burn) * slotEnd.timeIntervalSince(t))
            }
            remaining -= burn
            t = slotEnd
        }
        return (used + rate * expectedHours, exhausts)
    }

    private func fraction(at date: Date) -> Double {
        let components = calendar.dateComponents([.weekday, .hour], from: date)
        let slot = Slot(weekday: components.weekday ?? 0, hour: components.hour ?? 0)
        guard let observed = observedSlots[slot], observed > 0 else { return 0 }
        return Double(activeSlots[slot] ?? 0) / Double(observed)
    }

    static func hourStart(of date: Date, calendar: Calendar) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour], from: date)) ?? date
    }
}

extension UsageWindowKind {
    /// The window's length, which is what turns a reset epoch into a start.
    public var length: TimeInterval {
        switch self {
        case .fiveHour: return 5 * 3600
        case .sevenDay: return 7 * 86_400
        }
    }

    /// How much of the window must pass before the wall-clock fallback speaks,
    /// unless usage is already high.
    var legacyGate: TimeInterval {
        switch self {
        case .fiveHour: return 2 * 3600
        case .sevenDay: return 2 * 86_400
        }
    }
}
