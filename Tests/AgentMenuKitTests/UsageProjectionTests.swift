// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

func runUsageProjectionTests(_ t: TestRunner) {
    t.suite("UsageProjection")

    let hour: TimeInterval = 3600
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Rome") ?? .current
    let now = Date(timeIntervalSince1970: 1_788_800_400)   // a round local hour

    func hourStart(_ date: Date) -> Date {
        calendar.date(from: calendar.dateComponents([.year, .month, .day, .hour], from: date)) ?? date
    }

    // MARK: Parsing

    let text = """
    {"h":\(Int(now.timeIntervalSince1970 - 3 * hour)),"five_hour":[10,20,1788819000,1788819000],"seven_day":[17,24,1789164000,1789164000]}
    not json at all
    {"h":\(Int(now.timeIntervalSince1970 - 2 * hour)),"five_hour":[20,35,1788819000,1788819000]}
    {"h":\(Int(now.timeIntervalSince1970 - 40 * 24 * hour)),"five_hour":[1,2,10,10]}
    {"h":\(Int(now.timeIntervalSince1970 - 1 * hour)),"seven_day":[24,26,1789164000,1789164000]}
    """
    let history = UsageHistory.parse(text, now: now)
    t.expectEqual(history.rows.count, 3, "malformed lines skipped and rows past retention dropped")
    t.expectEqual(history.rows.first?.windows[.fiveHour]?.usedLast, 20, "first row's five_hour usedLast")
    t.expect(history.rows.last?.windows[.fiveHour] == nil, "a window absent from the line is absent from the row")
    t.expect(history.rows[0].hourStart < history.rows[1].hourStart, "rows come back in time order")

    // MARK: Deltas

    let sameReset = Date(timeIntervalSince1970: 1_788_819_000)
    let rows = [
        UsageHistoryRow(hourStart: now.addingTimeInterval(-3 * hour), windows: [
            .fiveHour: WindowObservation(usedFirst: 10, usedLast: 20, resetFirst: sameReset, resetLast: sameReset),
        ]),
        UsageHistoryRow(hourStart: now.addingTimeInterval(-2 * hour), windows: [
            .fiveHour: WindowObservation(usedFirst: 20, usedLast: 35, resetFirst: sameReset, resetLast: sameReset),
        ]),
        UsageHistoryRow(hourStart: now.addingTimeInterval(-1 * hour), windows: [
            // The window reset between the two rows: consumption starts from zero.
            .fiveHour: WindowObservation(usedFirst: 4, usedLast: 12,
                                         resetFirst: sameReset.addingTimeInterval(5 * hour),
                                         resetLast: sameReset.addingTimeInterval(5 * hour)),
        ]),
    ]
    let deltas = UsageProjector.deltas(kind: .fiveHour, rows: rows).map(\.delta)
    t.expectEqual(deltas, [10, 15, 12], "deltas: first row's own span, then the difference, then the whole value after a reset")

    let negative = UsageProjector.deltas(kind: .fiveHour, rows: [
        UsageHistoryRow(hourStart: now, windows: [
            .fiveHour: WindowObservation(usedFirst: 30, usedLast: 20, resetFirst: sameReset, resetLast: sameReset),
        ]),
    ]).map(\.delta)
    t.expectEqual(negative, [0], "a usage correction downwards is never negative consumption")

    // A reading that dips and comes back is not consumption.
    //
    // Every session of an account writes this history, each from whatever its
    // own last server contact said, so within one hour the file can hold 43,
    // then 8, then 43 again with nothing spent in between. Counting each rise
    // from the previous reading turned a personal account sitting at 4% of its
    // week into 280% attributed and a 167% projection at reset.
    let flapping = [
        UsageHistoryRow(hourStart: now.addingTimeInterval(-4 * hour), windows: [
            .sevenDay: WindowObservation(usedFirst: 40, usedLast: 43, resetFirst: sameReset, resetLast: sameReset),
        ]),
        UsageHistoryRow(hourStart: now.addingTimeInterval(-3 * hour), windows: [
            .sevenDay: WindowObservation(usedFirst: 43, usedLast: 8, resetFirst: sameReset, resetLast: sameReset),
        ]),
        UsageHistoryRow(hourStart: now.addingTimeInterval(-2 * hour), windows: [
            .sevenDay: WindowObservation(usedFirst: 20, usedLast: 43, resetFirst: sameReset, resetLast: sameReset),
        ]),
        UsageHistoryRow(hourStart: now.addingTimeInterval(-1 * hour), windows: [
            .sevenDay: WindowObservation(usedFirst: 43, usedLast: 45, resetFirst: sameReset, resetLast: sameReset),
        ]),
    ]
    let flapDeltas = UsageProjector.deltas(kind: .sevenDay, rows: flapping).map(\.delta)
    t.expectEqual(flapDeltas, [3, 0, 0, 2], "a dip and a recovery inside one window instance attribute nothing")
    t.expectEqual(flapDeltas.reduce(0, +), 5, "the instance attributes what it actually climbed, not every rise")

    // MARK: The wall-clock fallback

    let emptyProjector = UsageProjector(history: UsageHistory(rows: []), calendar: calendar)
    t.expect(!emptyProjector.isTrusted, "no history is not a trusted profile")

    // Half the window gone, half the quota gone: on course for exactly 100%.
    let halfway = UsageWindow(kind: .fiveHour, usedPercentage: 50,
                              resetsAt: now.addingTimeInterval(2.5 * hour))
    let wall = emptyProjector.projection(for: halfway, now: now)
    t.expectEqual(wall?.basis, .wallClock, "with no profile the wall-clock model is used")
    t.expectEqual(wall.map { ($0.projectedAtReset * 10).rounded() / 10 }, 100, "50% spent at the halfway point projects to 100%")

    let burning = UsageWindow(kind: .fiveHour, usedPercentage: 80, resetsAt: now.addingTimeInterval(2.5 * hour))
    let fast = emptyProjector.projection(for: burning, now: now)
    t.expect((fast?.projectedAtReset ?? 0) > 100, "80% spent at the halfway point projects past the quota")
    t.expect(fast?.exhaustsAt != nil, "and names when it runs out")
    t.expect(fast?.willExhaust == true, "willExhaust says so")

    // Seconds into a window the elapsed share is near zero: stay quiet.
    let fresh = UsageWindow(kind: .fiveHour, usedPercentage: 3, resetsAt: now.addingTimeInterval(5 * hour - 60))
    t.expect(emptyProjector.projection(for: fresh, now: now) == nil, "a window barely started says nothing")

    // Early in the window with low usage is also below the gate.
    let early = UsageWindow(kind: .fiveHour, usedPercentage: 20, resetsAt: now.addingTimeInterval(4 * hour))
    t.expect(emptyProjector.projection(for: early, now: now) == nil, "under the gate with low usage says nothing")

    let earlyButSpent = UsageWindow(kind: .fiveHour, usedPercentage: 60, resetsAt: now.addingTimeInterval(4 * hour))
    t.expect(emptyProjector.projection(for: earlyButSpent, now: now) != nil, "under the gate but already spent still speaks")

    // A payload that disagrees with the assumed window length.
    let bogus = UsageWindow(kind: .fiveHour, usedPercentage: 50, resetsAt: now.addingTimeInterval(-hour))
    t.expect(emptyProjector.projection(for: bogus, now: now) == nil, "a reset in the past produces no projection")
    let zero = UsageWindow(kind: .fiveHour, usedPercentage: 0, resetsAt: now.addingTimeInterval(2 * hour))
    t.expect(emptyProjector.projection(for: zero, now: now) == nil, "nothing spent yet, nothing to project")

    // MARK: The learned model

    // Six days of activity in the same three afternoon hours, then a quiet
    // stretch: the profile knows the rhythm, so the projection must spend only
    // the hours that look like work.
    var learnedRows: [UsageHistoryRow] = []
    var reset = now.addingTimeInterval(-6 * 24 * hour)
    for day in 0..<6 {
        for slot in 0..<3 {
            let start = hourStart(now.addingTimeInterval(Double(-(6 - day)) * 24 * hour + Double(slot) * hour))
            learnedRows.append(UsageHistoryRow(hourStart: start, windows: [
                .fiveHour: WindowObservation(
                    usedFirst: Double(slot * 10),
                    usedLast: Double((slot + 1) * 10),
                    resetFirst: reset, resetLast: reset
                ),
                // Seeded alongside five_hour so `.sevenDay` has evidence too
                // (finding #7): this row set used to seed only `.fiveHour`,
                // so `rate(for: .sevenDay)`'s evidence was 0 and
                // `projection(for:)` silently returned nil for the
                // seven-day window below — the `if let` further down never
                // entered, and the documented claim it exists to check was
                // never actually checked.
                .sevenDay: WindowObservation(
                    usedFirst: Double(slot),
                    usedLast: Double(slot + 1),
                    resetFirst: reset.addingTimeInterval(2 * 24 * hour),
                    resetLast: reset.addingTimeInterval(2 * 24 * hour)
                ),
            ]))
        }
        reset = reset.addingTimeInterval(24 * hour)
    }
    let learned = UsageProjector(history: UsageHistory(rows: learnedRows), calendar: calendar)
    t.expect(learned.isTrusted, "six active days is a trusted profile")

    let (rate, evidence) = learned.rate(for: .fiveHour, now: now)
    t.expect(rate > 0, "a rate comes out of the history")
    t.expect(evidence >= 2, "with enough active hours behind it")

    let window = UsageWindow(kind: .fiveHour, usedPercentage: 30, resetsAt: now.addingTimeInterval(3 * hour))
    if let projection = learned.projection(for: window, now: now) {
        t.expectEqual(projection.basis, .learned, "a trusted profile uses the learned model")
        t.expect(projection.projectedAtReset >= 30, "the projection never goes below what is already spent")
    } else {
        t.expect(false, "a trusted profile with evidence produces a projection")
    }

    // The same rate against a seven-day window that has barely moved must not
    // claim exhaustion. `.sevenDay` evidence check first, so a regression
    // that drops it back to 0 fails loudly here instead of the `if let`
    // below just silently not entering again.
    let (_, weeklyEvidence) = learned.rate(for: .sevenDay, now: now)
    t.expect(weeklyEvidence >= 2, "seven_day has evidence too, now that the fixture seeds it")

    let weekly = UsageWindow(kind: .sevenDay, usedPercentage: 5, resetsAt: now.addingTimeInterval(6 * 24 * hour))
    if let projection = learned.projection(for: weekly, now: now) {
        t.expect(projection.exhaustsAt == nil || projection.projectedAtReset > 100,
                 "an exhaustion time is only reported when the quota actually runs out")
    } else {
        t.expect(false, "a trusted profile with seven_day evidence produces a projection for a seven_day window")
    }

    // MARK: DST fall-back — the projection walk must terminate (finding #1)

    ({
        var romeCalendar = Calendar(identifier: .gregorian)
        romeCalendar.timeZone = TimeZone(identifier: "Europe/Rome")!

        // The SECOND (later) occurrence of the repeated local hour created
        // by the autumn DST transition: Europe/Rome falls back from 03:00
        // CEST to 02:00 CET on 2026-10-25, so 02:00-03:00 happens twice.
        // `Calendar.date(from:)` resolves the ambiguous wall-clock
        // components to the FIRST occurrence, so starting the walk from the
        // second one is exactly the hazard the reviewer's repro hit.
        let ambiguousNow = Date(timeIntervalSince1970: 1_792_891_800) // 2026-10-25 02:30 CET

        // A trusted, fully-active profile, so `project` actually walks real
        // hours instead of taking the wall-clock fallback (which never
        // touches the loop at all): one observed-and-active row per hour for
        // the 8 days up to `ambiguousNow`, so `fraction(at:)` reads 1.0 at
        // every (weekday, hour) slot `project` will ask about.
        var dstRows: [UsageHistoryRow] = []
        var cursor = ambiguousNow.addingTimeInterval(-8 * 24 * hour)
        while cursor < ambiguousNow {
            // Each row gets its own reset (rather than one shared across
            // all of them), so `UsageProjector.deltas` reads every row as a
            // fresh window and its full `usedLast` counts as that hour's
            // delta — a reset shared across rows would instead compute the
            // *difference* between consecutive identical usedLast values,
            // which is zero, leaving only the very first row active and the
            // profile untrusted.
            let rowReset = cursor.addingTimeInterval(5 * hour)
            dstRows.append(UsageHistoryRow(hourStart: cursor, windows: [
                .fiveHour: WindowObservation(usedFirst: 0, usedLast: 1, resetFirst: rowReset, resetLast: rowReset),
            ]))
            cursor = cursor.addingTimeInterval(hour)
        }
        let dstProjector = UsageProjector(history: UsageHistory(rows: dstRows), calendar: romeCalendar, now: ambiguousNow)
        t.expect(dstProjector.isTrusted, "the DST fixture history is a trusted profile")

        let dstResetsAt = ambiguousNow.addingTimeInterval(24 * hour)

        // Time-bounded: this test target has no per-test timeout, and a
        // regression here is a genuine infinite loop rather than merely a
        // wrong answer — calling `project` unguarded would wedge `make
        // test` itself instead of failing it.
        let semaphore = DispatchSemaphore(value: 0)
        var dstResult: (projected: Double, exhausts: Date?)?
        DispatchQueue.global().async {
            dstResult = dstProjector.project(used: 0, resetsAt: dstResetsAt, rate: 1, now: ambiguousNow)
            semaphore.signal()
        }
        let terminated = semaphore.wait(timeout: .now() + 5) == .success
        t.expect(terminated, "the projection walk terminates on the DST fall-back's repeated hour instead of spinning forever")
        if terminated, let dstResult {
            // A completed 24-hour walk at rate 1/active-hour spends close to
            // 24 points. A walk that silently truncates at the (belt-and-
            // braces) iteration cap without the boundary fix spends only the
            // few minutes it manages before bailing — well under 1. The gap
            // between those two is wide enough that this assertion is only
            // discriminating if the walk actually completed.
            t.expect(dstResult.projected > 20, "a completed walk spends close to the full 24 hours, not a truncated sliver of it")
        }
    })()

    // MARK: The file on this machine, if it is there
    //
    // Best-effort smoke check against whatever real history/snapshot files
    // this machine happens to have. Every assertion here must be able to
    // fail (finding #7): no `t.expect(true, …)` standing in for "didn't
    // crash", and no assertion buried where a missing precondition quietly
    // skips it. Skips cleanly when the files are absent.

    for (label, directory) in [("work", "~/.claude"), ("personal", "~/.claude-personal")] {
        let expanded = URL(fileURLWithPath: NSString(string: directory).expandingTildeInPath)
        let url = UsageHistory.path(snapshotTemplate: "{profile_dir}/tb-rate-snapshot.json", profileDirectory: expanded)
        guard FileManager.default.fileExists(atPath: url.path) else {
            print("   (skip) \(label) history not present at \(url.path)")
            continue
        }
        guard let history = UsageHistory.read(at: url) else {
            print("   (info) \(label) history file exists but parsed to no rows")
            continue
        }
        t.expect(!history.rows.isEmpty, "\(label) history parses to at least one row")

        let projector = UsageProjector(history: history)
        let reading = UsageReader().read(template: "{profile_dir}/tb-rate-snapshot.json", profileDirectory: expanded)
        guard case .available(let snapshot) = reading else {
            // The snapshot can legitimately be stale, refused, or absent
            // even when the history file is present — nothing further to
            // check against a projection.
            print("   (info) \(label) snapshot not .available (\(reading)) — skipping projection checks")
            continue
        }
        for window in snapshot.windows {
            guard let projection = projector.projection(for: window) else { continue }
            // The one claim the docs actually make about a projection: it
            // never reports less than what is already spent.
            t.expect(
                projection.projectedAtReset >= window.usedPercentage,
                "\(label) \(window.kind.rawValue): projection never claims less than what is already spent"
            )
            print("   (info) \(label) \(window.kind.rawValue): used \(Int(window.usedPercentage))%, "
                  + "projected \(Int(projection.projectedAtReset.rounded()))% (\(projection.basis))")
        }
    }
}
