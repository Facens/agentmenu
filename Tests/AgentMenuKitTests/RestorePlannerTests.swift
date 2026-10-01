// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

// Restore classification (U13, KTD12): what each ended owned session becomes.
// Everything is a value: rows are built by hand, the clock is an argument, and
// the planner is handed what the app observed. Nothing here touches a process
// or a file.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private let sessionA = "0b6f3a52-7c1e-4d0a-9a43-5f1e2c7d8b90"
private let sessionB = "5d2c9e14-31aa-4b7e-8c60-9a1f3b2d4e77"
private let sessionC = "7a9e1c33-62d4-4f08-b1a5-3c4d5e6f7a88"
private let sessionD = "9c8b7a65-4321-4fed-a987-0123456789ab"
private let bootOne = "uuid:11111111-0000-0000-0000-000000000001"
private let bootTwo = "uuid:22222222-0000-0000-0000-000000000002"

private func launchID(_ session: String) -> String { "launch-" + session.prefix(8) }

/// A live-phase row that has ended. `recorded` is when its cause was recorded,
/// for a cause recorded before the end.
private func ended(
    _ session: String,
    at endedAt: Date,
    cause: EndCause? = nil,
    recorded: Date? = nil,
    hosted: Bool = true,
    keepRunning: Bool? = nil,
    classified: Bool = false
) -> LedgerRow {
    LedgerRow(
        launchID: launchID(session),
        profileID: "work",
        configDirectory: "/profiles/work",
        cwd: "/projects/app",
        preset: Preset(model: "opus", keepRunning: keepRunning ?? hosted),
        terminalID: "terminal-app",
        hostSocket: hosted ? "/h/s" : nil,
        startedAt: t0.addingTimeInterval(-3600),
        phase: .live,
        pid: 4000 + Int32(session.utf8.first ?? 0),
        procStart: 1_799_990_000,
        lastSessionID: session,
        endedAt: endedAt,
        endCause: cause,
        causeRecordedAt: recorded,
        classified: classified
    )
}

private func context(
    now: Date,
    relaunch: Bool = false,
    host: HostStatus = .running,
    powerOffAt: Date? = nil,
    boot: String? = bootOne,
    never: Set<String> = [],
    live: Set<String> = []
) -> RestoreContext {
    RestoreContext(
        now: now, isRelaunchPass: relaunch, hostStatus: host, powerOffAt: powerOffAt,
        currentBootID: boot, neverPrompted: never, liveSessionIDs: live
    )
}

private func data(_ rows: [LedgerRow], restore: RestoreState = RestoreState(bootID: bootOne)) -> SessionStoreData {
    SessionStoreData(ledger: LaunchLedger(rows: rows), restore: restore)
}

private func ids(_ set: PendingReopenSet?) -> [String] { set?.sessionIDs ?? [] }

func runRestorePlannerTests(_ t: TestRunner) {
    t.suite("RestorePlanner")

    // MARK: AE1 — B quit individually, then Quit all on A and C

    do {
        var store = data([
            ended(sessionB, at: at(0), cause: .individual),
            ended(sessionA, at: at(10), cause: .together),
            ended(sessionC, at: at(12), cause: .together),
        ])
        let plan = RestorePlanner.classify(&store, context: context(now: at(20)))
        t.expectEqual(ids(store.restore.pending), [sessionA, sessionC], "AE1: Quit all's sessions are the pending set")
        t.expectEqual(store.restore.closed.map(\.sessionID), [sessionB], "AE1: the session quit individually is on the closed stack")
        t.expectEqual(store.restore.lastClosed?.sessionID, sessionB, "AE1: and is its top")
        t.expectEqual(store.restore.pendingCount, 2, "the pending count is the set's size")
        t.expectEqual(store.restore.closedCount, 1, "the closed count is the stack's depth")
        t.expectEqual(plan.hostDeathNotice, nil, "a Quit all is no host death")
        t.expect(store.ledger.rows.allSatisfy(\.classified), "every decided row is marked, so no later sweep decides it again")
        t.expectEqual(store.ledger.row(launchID: launchID(sessionA))?.endCause, .together, "a recorded cause is kept as it was")

        let again = RestorePlanner.classify(&store, context: context(now: at(30)))
        t.expect(again.classifications.isEmpty, "a second sweep decides nothing")
        t.expectEqual(ids(store.restore.pending), [sessionA, sessionC], "and the set is untouched")
    }

    // A recorded individual quit needs no settle window: AgentMenu caused it.
    do {
        var store = data([ended(sessionB, at: at(0), cause: .individual)])
        RestorePlanner.classify(&store, context: context(now: at(0.2)))
        t.expectEqual(store.restore.closed.map(\.sessionID), [sessionB], "an individual quit is classified at once")
    }

    // Quit all ends its sessions apart (SIGINT, then SIGTERM): one event.
    do {
        var store = data([ended(sessionA, at: at(0), cause: .together)])
        RestorePlanner.classify(&store, context: context(now: at(1)))
        store = SessionStoreData(
            ledger: LaunchLedger(rows: store.ledger.rows + [ended(sessionC, at: at(25), cause: .together)]),
            restore: store.restore
        )
        RestorePlanner.classify(&store, context: context(now: at(26)))
        t.expectEqual(ids(store.restore.pending), [sessionA, sessionC], "a Quit all that ends 25 seconds apart is still one set")
    }

    // A new event replaces a set nobody acted on; one the user acted on is
    // kept (R35) and the new sessions join it.
    do {
        let old = PendingReopenSet(
            sessions: [RestorableSession(
                sessionID: sessionD, launchID: launchID(sessionD), cwd: "/projects/app", terminalID: "terminal-app",
                endedAt: at(-1000), cause: .together
            )],
            formedAt: at(-1000), cause: .together
        )
        var untouched = data(
            [ended(sessionA, at: at(0), cause: .together)],
            restore: RestoreState(pending: old, bootID: bootOne)
        )
        RestorePlanner.classify(&untouched, context: context(now: at(5)))
        t.expectEqual(ids(untouched.restore.pending), [sessionA], "a new together event replaces an untouched pending set")

        var acted = old
        acted.touched = true
        var touched = data(
            [ended(sessionA, at: at(0), cause: .together)],
            restore: RestoreState(pending: acted, bootID: bootOne)
        )
        RestorePlanner.classify(&touched, context: context(now: at(5)))
        t.expectEqual(Set(ids(touched.restore.pending)), [sessionA, sessionD], "a set the user acted on keeps what is left and gains the new sessions")
    }


    // MARK: One event that straddles an AgentMenu restart (R23)

    do {
        // Quit all on A and C, then AgentMenu is quit. A ends and is classified
        // while it runs; C exits afterwards, and is seen at the next launch.
        let quitAt = at(0)
        var store = data([
            ended(sessionA, at: at(3), cause: .together, recorded: quitAt),
            ended(sessionC, at: at(-1), cause: .together, recorded: quitAt),
        ])
        // C is still live in the ledger at first: only A has ended.
        store.ledger.update(launchID: launchID(sessionC)) { $0.endedAt = nil }
        RestorePlanner.classify(&store, context: context(now: at(5)))
        t.expectEqual(ids(store.restore.pending), [sessionA], "A, which ended while AgentMenu ran, is the set")

        store.ledger.update(launchID: launchID(sessionC)) { $0.endedAt = at(400) }
        RestorePlanner.classify(&store, context: context(now: at(400), relaunch: true))
        t.expectEqual(Set(ids(store.restore.pending)), [sessionA, sessionC], "C, which ended after a restart with the cause recorded before the set formed, joins it")
    }

    do {
        // The shutdown: the notification recorded the cause for A and B; A died
        // while AgentMenu was alive, B only after the reboot.
        let notified = at(0)
        var store = data([
            ended(sessionA, at: at(3), cause: .powerOff, recorded: notified),
            ended(sessionB, at: at(3), cause: .powerOff, recorded: notified),
        ])
        store.ledger.update(launchID: launchID(sessionB)) { $0.endedAt = nil }
        RestorePlanner.classify(&store, context: context(now: at(5), powerOffAt: notified))
        t.expectEqual(ids(store.restore.pending), [sessionA], "A is classified as the Mac goes down")

        store.ledger.update(launchID: launchID(sessionB)) { $0.endedAt = at(900) }
        RestorePlanner.classify(&store, context: context(now: at(900), relaunch: true, boot: bootTwo))
        t.expectEqual(Set(ids(store.restore.pending)), [sessionA, sessionB], "B, found gone after the reboot, joins the same set")
    }

    do {
        // A different event, even a minute-ish later, does not: its cause was
        // recorded after the set formed.
        let old = PendingReopenSet(
            sessions: [sessionA, sessionC].map {
                RestorableSession(sessionID: $0, launchID: launchID($0), cwd: "/p", terminalID: "t", endedAt: at(10), cause: .together)
            },
            formedAt: at(11), cause: .together
        )
        var store = data(
            [
                ended(sessionD, at: at(35), cause: .together, recorded: at(20)),
                ended(sessionB, at: at(36), cause: .together, recorded: at(20)),
            ],
            restore: RestoreState(pending: old, bootID: bootOne)
        )
        RestorePlanner.classify(&store, context: context(now: at(40)))
        t.expectEqual(Set(ids(store.restore.pending)), [sessionD, sessionB], "a new Quit all a few seconds later replaces the set it did not come from")

        // Rows from before the stamp existed fall back to the time window.
        var legacy = data(
            [ended(sessionD, at: at(35), cause: .together)],
            restore: RestoreState(pending: old, bootID: bootOne)
        )
        RestorePlanner.classify(&legacy, context: context(now: at(40)))
        t.expectEqual(Set(ids(legacy.restore.pending)), [sessionA, sessionC, sessionD], "without a stamp, a session of the same cause within the window joins")
    }

    // MARK: Boot id

    do {
        var store = data(
            [sessionA, sessionB, sessionC].map { ended($0, at: at(100)) },
            restore: RestoreState(bootID: bootOne)
        )
        let plan = RestorePlanner.classify(&store, context: context(now: at(100), relaunch: true, boot: bootTwo))
        t.expectEqual(Set(ids(store.restore.pending)), [sessionA, sessionB, sessionC], "a changed boot id sends all three live owned sessions to the pending set")
        t.expectEqual(store.restore.pending?.cause, .powerOff, "as a shutdown")
        t.expect(store.restore.closed.isEmpty, "and none to the closed stack")
        t.expectEqual(store.restore.bootID, bootTwo, "the new boot id is recorded")
        t.expectEqual(plan.hostDeathNotice, nil, "no host-death notice for a restart")
        t.expect(store.ledger.rows.allSatisfy { $0.endCause == .powerOff }, "the ledger records why")
    }

    // MARK: An unexplained disappearance while AgentMenu was not running

    do {
        var store = data([ended(sessionA, at: at(50))], restore: RestoreState(bootID: bootOne))
        RestorePlanner.classify(&store, context: context(now: at(50), relaunch: true))
        t.expectEqual(ids(store.restore.pending), [sessionA], "a session that ended while AgentMenu was not running is pending")
        t.expectEqual(store.restore.pending?.cause, .unexplained, "unexplained")
        t.expect(store.restore.closed.isEmpty, "and not closed")

        // Same boot, a hosted session, a dead host: still only unexplained.
        var hosted = data([ended(sessionA, at: at(50))], restore: RestoreState(bootID: bootOne))
        let plan = RestorePlanner.classify(&hosted, context: context(now: at(50), relaunch: true, host: .died))
        t.expectEqual(hosted.restore.pending?.cause, .unexplained, "on a relaunch only the boot id can explain it")
        t.expectEqual(plan.hostDeathNotice, nil, "so no notice")
    }

    // MARK: Host death

    do {
        var store = data([ended(sessionA, at: at(0)), ended(sessionB, at: at(0))])
        let plan = RestorePlanner.classify(&store, context: context(now: at(2.5), host: .died))
        t.expectEqual(Set(ids(store.restore.pending)), [sessionA, sessionB], "host death puts all its sessions in the pending set")
        t.expectEqual(store.restore.pending?.cause, .hostDied, "named as the host dying")
        t.expect(store.restore.closed.isEmpty, "none to the closed stack")
        t.expectEqual(plan.hostDeathNotice?.count, 2, "one notice, for two sessions")
        t.expectEqual(Set(plan.hostDeathNotice?.sessionIDs ?? []), [sessionA, sessionB], "naming them")
    }

    // A plain launch does not run in the host: its death is not the host's.
    do {
        var store = data([ended(sessionA, at: at(0), hosted: false)])
        RestorePlanner.classify(&store, context: context(now: at(5), host: .died))
        t.expectEqual(store.restore.closed.map(\.sessionID), [sessionA], "a plain launch is not taken by a host death")
    }

    // MARK: AE10 — the registry notices before the host death is detected

    do {
        var store = data([ended(sessionA, at: at(0)), ended(sessionB, at: at(0))])
        let early = RestorePlanner.classify(&store, context: context(now: at(0.5), host: .running))
        t.expect(early.classifications.isEmpty, "AE10: inside the settle window nothing is classified")
        t.expect(store.restore.pending == nil && store.restore.closed.isEmpty, "AE10: and neither list has moved")
        t.expect(store.ledger.rows.allSatisfy { !$0.classified }, "AE10: the rows still wait")

        let settled = RestorePlanner.classify(&store, context: context(now: at(2.5), host: .died))
        t.expectEqual(Set(ids(store.restore.pending)), [sessionA, sessionB], "AE10: after the window the host is checked first, and both land in the pending set")
        t.expectEqual(settled.hostDeathNotice?.count, 2, "AE10: with one notice naming two sessions")

        // A third session of that host ending a moment later joins the set
        // and does not raise a second notice.
        store = SessionStoreData(
            ledger: LaunchLedger(rows: store.ledger.rows + [ended(sessionC, at: at(3))]),
            restore: store.restore
        )
        let late = RestorePlanner.classify(&store, context: context(now: at(5.5), host: .died))
        t.expectEqual(Set(ids(store.restore.pending)), [sessionA, sessionB, sessionC], "AE10: a straggler joins the same set")
        t.expectEqual(late.hostDeathNotice, nil, "AE10: and the death is announced once")
    }

    // MARK: Power off

    do {
        // Removals after the notification: a hosted one and a keep-running-off
        // one, the host gone as well. Pending, and no host-death notice.
        var store = data([
            ended(sessionA, at: at(1), hosted: true),
            ended(sessionB, at: at(1), hosted: false, keepRunning: false),
        ])
        let plan = RestorePlanner.classify(&store, context: context(now: at(3.5), host: .died, powerOffAt: at(0)))
        t.expectEqual(Set(ids(store.restore.pending)), [sessionA, sessionB], "after the power-off notification both land in the pending set, keep-running-off included")
        t.expectEqual(store.restore.pending?.cause, .powerOff, "as a shutdown")
        t.expectEqual(plan.hostDeathNotice, nil, "with no host-death notice, though the host died too")
    }

    do {
        // The notification recorded the cause for the whole live set at once.
        var ledger = LaunchLedger(rows: [sessionA, sessionB].map {
            var row = ended($0, at: at(0))
            row.endedAt = nil
            return row
        })
        let recorded = ledger.recordCauseForUnexplainedLiveRows(.powerOff)
        t.expectEqual(recorded.count, 2, "the power-off cause is recorded for the whole live set in one call")
        ledger.update(launchID: launchID(sessionA)) { $0.endedAt = at(3) }
        ledger.update(launchID: launchID(sessionB)) { $0.endedAt = at(4) }
        var store = SessionStoreData(ledger: ledger, restore: RestoreState(bootID: bootOne))
        let plan = RestorePlanner.classify(&store, context: context(now: at(4.1), host: .died))
        t.expectEqual(Set(ids(store.restore.pending)), [sessionA, sessionB], "a row carrying the recorded cause needs no settle window")
        t.expectEqual(plan.hostDeathNotice, nil, "and posts no notice")
    }

    do {
        // A notification no shutdown followed does not explain a session that
        // ends long after it.
        var store = data([ended(sessionA, at: at(1000))])
        RestorePlanner.classify(&store, context: context(now: at(1003), powerOffAt: at(0)))
        t.expectEqual(store.restore.closed.map(\.sessionID), [sessionA], "a power-off notification does not explain what ends much later")
    }

    do {
        // The power-off cause was recorded for a logout somebody cancelled,
        // AgentMenu restarted (the in-memory release is gone), and the session
        // ends with a later `/exit`: nothing explains it but itself.
        var store = data([ended(sessionA, at: at(1000), cause: .powerOff, recorded: at(0))])
        let plan = RestorePlanner.classify(&store, context: context(now: at(1003)))
        t.expectEqual(store.restore.closed.map(\.sessionID), [sessionA], "a stale recorded power-off does not send a later /exit to Reopen all")
        t.expect(store.restore.pending == nil, "…and nothing is pending")
        t.expectEqual(plan.classifications.first?.destination, .closedStack, "the row is decided as closed")
        t.expectEqual(store.restore.closed.first?.cause, .exited, "…as an ending of its own")

        // Inside the window the notification explains it, as ever.
        var near = data([ended(sessionA, at: at(100), cause: .powerOff, recorded: at(0))])
        RestorePlanner.classify(&near, context: context(now: at(100.1)))
        t.expectEqual(ids(near.restore.pending), [sessionA], "a power-off recorded within the window still explains the ending")
        t.expectEqual(near.restore.pending?.cause, .powerOff, "as a shutdown")

        // On the relaunch pass nothing was watching: the recorded cause stands.
        var away = data([ended(sessionA, at: at(1000), cause: .powerOff, recorded: at(0))])
        RestorePlanner.classify(&away, context: context(now: at(1003), relaunch: true))
        t.expectEqual(ids(away.restore.pending), [sessionA], "a relaunch keeps honouring a recorded power-off")

        // A row that says nothing of when it was recorded keeps it too.
        var unstamped = data([ended(sessionA, at: at(1000), cause: .powerOff)])
        RestorePlanner.classify(&unstamped, context: context(now: at(1003)))
        t.expectEqual(ids(unstamped.restore.pending), [sessionA], "a power-off with no recorded time is not bounded")
    }

    do {
        // A quit whose quitter was lost with an AgentMenu restart: the cause
        // stays on a live row until it is released, and only then.
        func live(_ cause: EndCause, recorded: Date?, session: String = sessionA) -> LedgerRow {
            var row = ended(session, at: at(0), cause: cause, recorded: recorded)
            row.endedAt = nil
            return row
        }
        var ledger = LaunchLedger(rows: [live(.individual, recorded: at(0))])
        t.expect(ledger.releaseStaleQuitCauses(now: at(30)).isEmpty, "a quit inside the quitter's 30 seconds is left to it")
        t.expectEqual(ledger.row(launchID: launchID(sessionA))?.endCause, .individual, "…its cause stays")
        t.expectEqual(ledger.releaseStaleQuitCauses(now: at(31)), [launchID(sessionA)], "past them, a still-live row is released")
        t.expect(ledger.row(launchID: launchID(sessionA))?.endCause == nil, "…its cause is gone")
        t.expect(ledger.row(launchID: launchID(sessionA))?.causeRecordedAt == nil, "…and its time")

        var together = LaunchLedger(rows: [live(.together, recorded: at(0))])
        t.expectEqual(together.releaseStaleQuitCauses(now: at(60)).count, 1, "a Quit all's cause is released the same way")

        var other = LaunchLedger(rows: [
            live(.powerOff, recorded: at(0)), live(.individual, recorded: nil, session: sessionB),
        ])
        t.expect(other.releaseStaleQuitCauses(now: at(600)).isEmpty, "only a stamped individual or together cause is taken back")

        // It ends later by itself: classified from what is seen, not from the stale quit.
        var store = SessionStoreData(ledger: ledger, restore: RestoreState(bootID: bootOne))
        store.ledger.update(launchID: launchID(sessionA)) { $0.endedAt = at(700) }
        RestorePlanner.classify(&store, context: context(now: at(703)))
        t.expectEqual(store.restore.closed.map(\.sessionID), [sessionA], "a later /exit goes to the closed stack")
        t.expect(store.restore.pending == nil, "…not to Reopen all")

        var finished = LaunchLedger(rows: [live(.individual, recorded: at(0))])
        finished.update(launchID: launchID(sessionA)) { $0.endedAt = at(10) }
        t.expect(finished.releaseStaleQuitCauses(now: at(600)).isEmpty, "a row that has ended keeps its cause: it is history")
    }

    // MARK: The closed stack

    do {
        // The last hosted session exits normally: the server stays up.
        var store = data([ended(sessionA, at: at(0), hosted: true)])
        let inside = RestorePlanner.classify(&store, context: context(now: at(1), host: .running))
        t.expect(inside.classifications.isEmpty, "a session that went by itself waits one settle window")
        let plan = RestorePlanner.classify(&store, context: context(now: at(2.5), host: .running))
        t.expectEqual(store.restore.closed.map(\.sessionID), [sessionA], "the last hosted session exiting normally goes to the closed stack")
        t.expectEqual(store.restore.closed.first?.cause, .exited, "as an exit")
        t.expect(store.restore.pending == nil, "and not the pending set")
        t.expectEqual(plan.hostDeathNotice, nil, "with no notice")
    }

    do {
        // AE8: keep-running off, the window closes, AgentMenu running.
        var store = data([ended(sessionA, at: at(0), hosted: false, keepRunning: false)])
        RestorePlanner.classify(&store, context: context(now: at(1), host: .neverStarted))
        t.expect(store.restore.closed.isEmpty, "AE8: not before the settle window")
        RestorePlanner.classify(&store, context: context(now: at(2.1), host: .neverStarted))
        t.expectEqual(store.restore.closed.map(\.sessionID), [sessionA], "AE8: a keep-running-off session whose window closed lands on the closed stack after the settle window")
        t.expect(store.restore.pending == nil, "AE8: not in the pending set")
    }

    do {
        // The stack is newest first, once per session, and bounded.
        var rows = (0..<(RestoreState.maximumClosed + 5)).map { n -> LedgerRow in
            let id = String(format: "%08x-0000-4000-8000-000000000000", n + 1)
            return ended(id, at: at(Double(n)), cause: .individual)
        }
        var store = data(rows)
        RestorePlanner.classify(&store, context: context(now: at(1000)))
        t.expectEqual(store.restore.closedCount, RestoreState.maximumClosed, "the closed stack is bounded")
        t.expectEqual(store.restore.lastClosed?.sessionID, String(format: "%08x-0000-4000-8000-000000000000", RestoreState.maximumClosed + 5), "its top is the most recent")

        // The same session closing again moves to the top, once.
        rows = [ended(sessionA, at: at(0), cause: .individual), ended(sessionB, at: at(10), cause: .individual)]
        var twice = data(rows)
        RestorePlanner.classify(&twice, context: context(now: at(20)))
        var again = ended(sessionA, at: at(30), cause: .individual)
        again.launchID = "launch-again"
        twice = SessionStoreData(ledger: LaunchLedger(rows: twice.ledger.rows + [again]), restore: twice.restore)
        RestorePlanner.classify(&twice, context: context(now: at(40)))
        t.expectEqual(twice.restore.closed.map(\.sessionID), [sessionA, sessionB], "a session closed again is on the stack once, on top")
    }

    // MARK: Never prompted

    do {
        var store = data([
            ended(sessionA, at: at(0), cause: .together),
            ended(sessionB, at: at(0), cause: .together),
            ended(sessionC, at: at(0), cause: .individual),
        ])
        RestorePlanner.classify(&store, context: context(now: at(5), never: [sessionB, sessionC]))
        t.expectEqual(ids(store.restore.pending), [sessionA], "a never-prompted session is excluded from the pending set")
        t.expect(store.restore.closed.isEmpty, "and from the closed stack")
        t.expect(store.ledger.rows.allSatisfy(\.classified), "it is still marked, so it is not asked about again")
    }

    // MARK: Pending-set semantics

    do {
        var state = RestoreState(
            pending: PendingReopenSet(
                sessions: [sessionA, sessionB, sessionC].map {
                    RestorableSession(sessionID: $0, launchID: launchID($0), cwd: "/p", terminalID: "t", endedAt: t0, cause: .together)
                },
                formedAt: t0, cause: .together
            ),
            closed: [sessionD].map {
                RestorableSession(sessionID: $0, launchID: launchID($0), cwd: "/p", terminalID: "t", endedAt: t0, cause: .individual)
            },
            bootID: bootOne
        )
        t.expect(state.contains(sessionD) && state.contains(sessionA), "the state knows what it holds")
        state.restored([sessionA, sessionD])
        t.expectEqual(ids(state.pending), [sessionB, sessionC], "restoring a session removes it from the pending set")
        t.expect(state.closed.isEmpty, "and from the closed stack (R24)")
        t.expectEqual(state.pending?.touched, true, "and the set counts as acted on")
        state.restored([sessionB, sessionC])
        t.expect(state.pending == nil, "an emptied set is gone, not empty")
        t.expectEqual(state.pendingCount, 0, "count 0")

        // A failure stays (R35): nothing is passed for it.
        var partial = RestoreState(pending: PendingReopenSet(
            sessions: [sessionA, sessionB].map {
                RestorableSession(sessionID: $0, launchID: launchID($0), cwd: "/p", terminalID: "t", endedAt: t0, cause: .together)
            },
            formedAt: t0, cause: .together
        ))
        partial.restored([sessionA])
        t.expectEqual(ids(partial.pending), [sessionB], "a session that could not be restored stays in the set for a later try")
    }

    do {
        // Brought back some other way: running, so neither closed nor pending.
        let session = RestorableSession(sessionID: sessionA, launchID: "x", cwd: "/p", terminalID: "t", endedAt: t0, cause: .together)
        var store = data([], restore: RestoreState(pending: PendingReopenSet(sessions: [session], formedAt: t0, cause: .together), closed: [session], bootID: bootOne))
        RestorePlanner.classify(&store, context: context(now: at(10), live: [sessionA]))
        t.expect(store.restore.pending == nil && store.restore.closed.isEmpty, "a session that is live again leaves both lists")
    }

    do {
        // A session in the pending set that is then quit individually is
        // closed, not both.
        let session = RestorableSession(sessionID: sessionA, launchID: "x", cwd: "/p", terminalID: "t", endedAt: t0, cause: .together)
        var store = data(
            [ended(sessionA, at: at(100), cause: .individual)],
            restore: RestoreState(pending: PendingReopenSet(sessions: [session], formedAt: t0, cause: .together), bootID: bootOne)
        )
        RestorePlanner.classify(&store, context: context(now: at(101)))
        t.expect(store.restore.pending == nil, "a session quit individually after a restore leaves the pending set")
        t.expectEqual(store.restore.closed.map(\.sessionID), [sessionA], "and is on the closed stack")
    }

    // MARK: The row carries what a restore needs

    do {
        var row = ended(sessionA, at: at(0), cause: .together)
        row.preset = Preset(model: "opus", effort: "high", keepRunning: true)
        row.lastSessionID = sessionB  // /clear changed the id
        var store = data([row])
        RestorePlanner.classify(&store, context: context(now: at(1)))
        let kept = store.restore.pending?.sessions.first
        t.expectEqual(kept?.sessionID, sessionB, "the session id is the latest, which /clear leaves behind")
        t.expectEqual(kept?.launchID, launchID(sessionA), "the tmux session name is the launch's")
        t.expectEqual(kept?.preset.model, "opus", "the preset is kept whole")
        t.expectEqual(kept?.preset.effort, "high", "the preset is kept whole")
        t.expectEqual(kept?.cwd, "/projects/app", "the folder is kept")
        t.expectEqual(kept?.profileID, "work", "and the account")
        t.expectEqual(kept?.hostSocket, "/h/s", "and where it ran")
    }

    // MARK: A store from before this unit

    do {
        // Ended rows nobody classified, no boot id: history, not a set.
        var store = data(
            [ended(sessionA, at: at(-5000)), ended(sessionB, at: at(-4000), cause: .together)],
            restore: RestoreState()
        )
        RestorePlanner.classify(&store, context: context(now: at(0), relaunch: true))
        t.expect(store.restore.pending == nil && store.restore.closed.isEmpty, "rows from before the classification existed are not offered for reopening")
        t.expect(store.ledger.rows.allSatisfy(\.classified), "they are marked, so they stay history")
        t.expectEqual(store.restore.bootID, bootOne, "and the first boot id is recorded")
    }

    // MARK: Rows that are not candidates

    do {
        var store = data([
            ended(sessionA, at: at(0), cause: .together, classified: true),
            LedgerRow(launchID: "starting", cwd: "/p", terminalID: "t", startedAt: t0),
            {
                var failed = LedgerRow(launchID: "failed", cwd: "/p", terminalID: "t", startedAt: t0)
                failed.phase = .failed(reason: "no")
                return failed
            }(),
        ])
        let plan = RestorePlanner.classify(&store, context: context(now: at(100)))
        t.expect(plan.classifications.isEmpty, "a classified row, a Starting one and a Failed one are not classified")
        t.expect(store.restore.pending == nil, "so nothing is pending")
    }

    // MARK: Purity

    do {
        let rows = [ended(sessionA, at: at(0), cause: .together)]
        let state = RestoreState(bootID: bootOne)
        let one = RestorePlanner.plan(ledger: LaunchLedger(rows: rows), state: state, context: context(now: at(5)))
        let two = RestorePlanner.plan(ledger: LaunchLedger(rows: rows), state: state, context: context(now: at(5)))
        t.expectEqual(one, two, "the same inputs give the same decisions")
        t.expect(rows[0].classified == false, "and planning changes nothing until it is applied")
    }

    // MARK: Boot id

    do {
        t.expect(BootID.current() != nil, "this Mac has a boot id")
        t.expectEqual(BootID.current(), BootID.current(), "which is the same on two readings")
        t.expect(!BootID.hasChanged(from: nil, to: bootOne), "no stored boot id is not a change")
        t.expect(!BootID.hasChanged(from: bootOne, to: nil), "an unreadable boot id is not a change")
        t.expect(!BootID.hasChanged(from: bootOne, to: bootOne), "the same boot is not a change")
        t.expect(BootID.hasChanged(from: bootOne, to: bootTwo), "a different boot session is a change")
        t.expect(!BootID.hasChanged(from: "boottime:1000", to: "boottime:1030"), "a clock step inside the tolerance is the same boot")
        t.expect(BootID.hasChanged(from: "boottime:1000", to: "boottime:1200"), "boot times minutes apart are two boots")
        t.expect(!BootID.hasChanged(from: "boottime:1000", to: bootOne), "two kinds of identifier are not compared")
    }
}

// MARK: - Restore actions (U14)

private func claudeManifest() throws -> AgentManifest {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/agents/claude-code.toml")
    return try AgentManifest.parse(String(contentsOf: url, encoding: .utf8), origin: .bundled)
}

private final class RunBox<V>: @unchecked Sendable { var value: V? }

private func blockingRun<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T? {
    let box = RunBox<T>()
    let done = DispatchSemaphore(value: 0)
    Task {
        box.value = await body()
        done.signal()
    }
    done.wait()
    return box.value
}

/// An ended owned session, as the closed stack or the pending set holds it.
private func restorable(
    _ session: String,
    profile: String? = "work",
    config: String? = "/profiles/work",
    cwd: String,
    preset: Preset = Preset(model: "opus", effort: "high", keepRunning: true),
    terminal: String = "terminal-app",
    hostSocket: String? = "/h/s",
    cause: EndCause = .together,
    endedAt: Date = at(0)
) -> RestorableSession {
    RestorableSession(
        sessionID: session, launchID: launchID(session), profileID: profile, configDirectory: config, cwd: cwd,
        preset: preset, terminalID: terminal, hostSocket: hostSocket, endedAt: endedAt, cause: cause
    )
}

private func liveRow(_ session: String, pid: Int32, tty: String? = nil) -> LiveSession {
    LiveSession(
        key: LiveSessionKey(configDirectory: "/profiles/work", pid: pid, procStart: 1_790_000_000 + Int(pid)),
        agentID: RegistryReader.claudeAgentID, agentDisplayName: "Claude Code", profileID: "work",
        configDirectory: URL(fileURLWithPath: "/profiles/work"), pid: pid, sessionId: session, status: .yourTurn,
        tty: tty, startedAt: Date(timeIntervalSince1970: 1_790_000_000)
    )
}

func runRestoreActionsTests(_ t: TestRunner) {
    t.suite("RestoreActions")

    guard let claude = t.attempt("load the real claude-code manifest", { try claudeManifest() }) else { return }

    let workStore = TempDir("actions-work")
    let personalStore = TempDir("actions-personal")
    let project = TempDir("actions-project")
    let elsewhere = TempDir("actions-elsewhere")
    defer { workStore.cleanup(); personalStore.cleanup(); project.cleanup(); elsewhere.cleanup() }

    var config = Config()
    config.defaults = Preset(model: "sonnet", effort: "low")
    config.profiles = [
        Profile(id: "work", name: "Work", configDirectory: workStore.url.path),
        Profile(id: "personal", name: "Personal", configDirectory: personalStore.url.path),
    ]
    config.folders = [FolderTarget(label: "Project", path: project.url.path, profileID: "work", preset: Preset(model: "opus"))]

    let sameTerminal: (Preset) -> String? = { $0.terminal ?? "terminal-app" }
    let none = RestoreGuardSnapshot()

    // MARK: AE10 — a host death with two owned sessions: one notification, both pending

    do {
        var store = data([ended(sessionA, at: at(0)), ended(sessionB, at: at(0))])
        let plan = RestorePlanner.classify(&store, context: context(now: at(2.5), host: .died))
        t.expectEqual(Set(ids(store.restore.pending)), [sessionA, sessionB], "AE10: both sessions wait in the pending set")
        t.expectEqual(store.restore.pending?.cause, .hostDied, "AE10: as a host death")
        if let notice = plan.hostDeathNotice, let note = HostDeathNotification.make(for: notice) {
            t.expectEqual(note.title, "2 sessions ended", "AE10: the one notification names how many ended")
            t.expect(note.body.contains("Reopen all"), "AE10: and offers Reopen all")
            t.expectEqual(HostDeathNotification.identifier, "host-died", "AE10: with a fixed identifier, so a repeat replaces it")
            t.expectEqual(
                NotificationClick.resolve(userInfo: note.userInfo, live: []), .showLive,
                "AE10: a click on its body opens the Sessions tab"
            )
        } else {
            t.expect(false, "AE10: a host death yields a notification decision")
        }
        t.expectEqual(
            HostDeathNotification.make(for: HostDeathNotice(count: 1, sessionIDs: [sessionA]))?.title, "1 session ended",
            "one session reads as singular"
        )
        t.expect(HostDeathNotification.make(for: HostDeathNotice(count: 0, sessionIDs: [])) == nil, "no session, no notification")
        t.expectEqual(RestorePlanner.classify(&store, context: context(now: at(9), host: .died)).hostDeathNotice, nil, "and nothing more is announced")
    }

    // MARK: R30 — an unlaunched History session: account from the transcript, model from the folder

    do {
        func transcript(_ store: TempDir, session: String, cwd: String) {
            let record: [String: Any] = [
                "type": "user", "sessionId": session, "entrypoint": "cli", "isSidechain": false, "cwd": cwd,
                "message": ["role": "user", "content": "look at the invoices"],
                "uuid": UUID().uuidString, "timestamp": "2026-09-30T10:00:00.000Z", "version": "2.1.285",
            ]
            let line = String(decoding: try! JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes]), as: UTF8.self)
            try? store.write(line + "\n", to: "projects/-proj/\(session).jsonl")
        }
        transcript(personalStore, session: sessionC, cwd: project.url.path)
        let entry = TranscriptIndex()
            .scan(profiles: [TranscriptProfile(id: "personal", directory: personalStore.url)], now: Date())
            .first { $0.sessionId == sessionC }
        guard let entry else { t.expect(false, "index the History fixture"); return }

        switch RestoreActions.plan(
            source: .history(entry, recorded: nil), config: config, agent: claude, terminalFor: sameTerminal, guardSnapshot: none
        ) {
        case .failure(let refusal):
            t.expect(false, "an unlaunched History session plans a restore — refused: \(refusal)")
        case .success(let launch):
            t.expectEqual(launch.origin, .history, "it is a History restore")
            t.expectEqual(launch.profile.id, "personal", "the account is the profile whose store holds the transcript")
            t.expectEqual(launch.resolved.preset.model, "opus", "the model comes from the folder's launch target")
            t.expectEqual(launch.resolved.preset.effort, "low", "and the global default fills the rest")
            t.expect(launch.wantsHost, "keep-running follows the default (on)")
            if let command = t.attempt("build the command", { try launch.command(binaryPath: "/bin/claude", launchID: "5d1c7e0a-3b6e-4d7a-9c21-0e0b7a4d1f33") }) {
                t.expectEqual(Array(command.arguments.prefix(2)), ["--resume", sessionC], "it resumes by id")
                t.expect(!command.arguments.contains("--session-id"), "and never carries --session-id (KTD14)")
                t.expectEqual(command.environment["CLAUDE_CONFIG_DIR"], personalStore.url.path, "on the transcript's account")
            }
        }

        // R31, R26: the same click for a session AgentMenu did launch uses its recorded launch.
        let recorded = restorable(
            sessionC, profile: "work", config: workStore.url.path, cwd: project.url.path,
            preset: Preset(agent: "claude-code", terminal: "terminal-app", profile: "work", model: "fable", permissionMode: "plan", keepRunning: false),
            hostSocket: nil, cause: .exited
        )
        if case .success(let launch) = RestoreActions.plan(
            source: .history(entry, recorded: recorded), config: config, agent: claude, terminalFor: sameTerminal, guardSnapshot: none
        ) {
            t.expectEqual(launch.origin, .recorded, "a session AgentMenu launched restores from its record, wherever the click was")
            t.expectEqual(launch.profile.id, "work", "on the account it ran under, not the transcript's store")
            t.expectEqual(launch.resolved.preset.model, "fable", "with the model it was launched with, not the folder's")
            t.expectEqual(launch.resolved.preset.permissionMode, "plan", "and its permission mode")
            t.expect(!launch.wantsHost, "keep-running off was recorded: the plain launch path")
        } else {
            t.expect(false, "a recorded History session plans a restore")
        }
    }

    // MARK: AE3 — a History session that is live elsewhere focuses; it does not resume

    do {
        let entryLive = TranscriptIndex()
            .scan(profiles: [TranscriptProfile(id: "personal", directory: personalStore.url)], now: Date())
            .first { $0.sessionId == sessionC }
        let live = liveRow(sessionC, pid: 5100)
        if let entryLive {
            let result = RestoreActions.plan(
                source: .history(entryLive, recorded: nil), config: config, agent: claude, terminalFor: sameTerminal,
                guardSnapshot: RestoreGuardSnapshot(liveSessions: [live])
            )
            t.expectEqual(result.failure, .alreadyLive(focus: [live.key]), "AE3: a History session held by a live row is refused, with the row to focus")
            if let refusal = result.failure {
                t.expectEqual(RestoreActions.outcome(for: refusal), .alreadyRunning, "AE3: and counts as running in a Reopen all, with nothing launched")
            }
        } else {
            t.expect(false, "AE3: the History fixture was indexed")
        }
    }

    // MARK: R26, KTD14 — an owned restore: recorded keep-running, recorded terminal, whole preset

    do {
        let hosted = restorable(
            sessionA, cwd: project.url.path,
            preset: Preset(model: "opus", effort: "high", permissionMode: "acceptEdits", advisor: .off, keepRunning: true),
            terminal: "iterm2"
        )
        switch RestoreActions.plan(source: .recorded(hosted), config: config, agent: claude, terminalFor: sameTerminal, guardSnapshot: none) {
        case .failure(let refusal):
            t.expect(false, "a recorded session plans a restore — refused: \(refusal)")
        case .success(let launch):
            t.expect(launch.wantsHost, "keep-running on was recorded: the hosted launch path")
            t.expectEqual(launch.terminalID, "iterm2", "in the terminal it was launched in")
            t.expect(!launch.terminalChanged, "which was not replaced")
            t.expectEqual(launch.profile.id, "work", "on its own account")
            t.expectEqual(launch.resolved.preset.model, "opus", "with its own model, not today's default")
            if let command = t.attempt("build the recorded command", { try launch.command(binaryPath: "/bin/claude", launchID: "5d1c7e0a-3b6e-4d7a-9c21-0e0b7a4d1f33") }) {
                let args = command.arguments
                t.expectEqual(Array(args.prefix(2)), ["--resume", sessionA], "it resumes the same conversation")
                t.expect(zip(args, args.dropFirst()).contains { $0 == "--model" && $1 == "opus" }, "re-passing the model")
                t.expect(zip(args, args.dropFirst()).contains { $0 == "--effort" && $1 == "high" }, "the effort")
                t.expect(zip(args, args.dropFirst()).contains { $0 == "--permission-mode" && $1 == "acceptEdits" }, "the permission mode")
                t.expect(!args.contains("--session-id"), "never --session-id")
                t.expectEqual(command.workingDirectory, project.url.path, "in the same folder")
            }
        }

        let plain = restorable(
            sessionB, cwd: project.url.path, preset: Preset(model: "opus", keepRunning: false), terminal: "terminal-app", hostSocket: nil
        )
        if case .success(let launch) = RestoreActions.plan(source: .recorded(plain), config: config, agent: claude, terminalFor: sameTerminal, guardSnapshot: none) {
            t.expect(!launch.wantsHost, "keep-running off was recorded: the plain launch path")
        } else { t.expect(false, "a plain recorded session plans a restore") }

        // The recorded terminal is gone: the fallback is used, and keep-running is judged on it.
        let fallback: (Preset) -> String? = { $0.terminal == "iterm2" ? "kitty" : $0.terminal }
        if case .success(let launch) = RestoreActions.plan(source: .recorded(hosted), config: config, agent: claude, terminalFor: fallback, guardSnapshot: none) {
            t.expect(launch.terminalChanged, "a terminal that is gone is replaced, and the result says so")
            t.expectEqual(launch.terminalID, "kitty", "by the fallback")
            t.expect(!launch.wantsHost, "and a terminal that cannot attach restores plainly rather than failing")
        } else { t.expect(false, "a missing terminal does not refuse the restore") }

        // An account that is no longer configured, and a folder the transcript cannot name.
        let gone = restorable(sessionD, profile: "ghost", config: "/profiles/ghost", cwd: project.url.path)
        t.expectEqual(
            RestoreActions.plan(source: .recorded(gone), config: config, agent: claude, terminalFor: sameTerminal, guardSnapshot: none).failure,
            .unknownProfile(id: "ghost"), "an account that is no longer configured is a reason, not a guess"
        )
        let byDirectory = restorable(sessionD, profile: nil, config: workStore.url.path, cwd: project.url.path)
        t.expectEqual(
            (try? RestoreActions.plan(source: .recorded(byDirectory), config: config, agent: claude, terminalFor: sameTerminal, guardSnapshot: none).get())?.profile.id,
            "work", "a record with no profile id finds its account by config directory"
        )
        let badFolder = restorable(sessionD, cwd: "relative/path")
        if case .notRestorable? = RestoreActions.plan(source: .recorded(badFolder), config: config, agent: claude, terminalFor: sameTerminal, guardSnapshot: none).failure {
            t.expect(true, "a folder that cannot be typed into a terminal is refused")
        } else { t.expect(false, "a folder that cannot be typed into a terminal is refused") }
        t.expectEqual(
            RestoreActions.plan(source: .recorded(hosted), config: config, agent: nil, terminalFor: sameTerminal, guardSnapshot: none).failure,
            .agentUnavailable, "no usable Claude Code, no restore"
        )
    }

    // MARK: AE2 — an owned, detached, live session reattaches instead of resuming

    do {
        let session = restorable(sessionA, cwd: project.url.path)
        let live = liveRow(sessionA, pid: 5200, tty: "ttys010")
        let row = LedgerRow(
            launchID: launchID(sessionA), profileID: "work", configDirectory: "/profiles/work", cwd: project.url.path,
            terminalID: "terminal-app", hostSocket: "/h/s", startedAt: at(-100), phase: .live, pid: 5200,
            procStart: live.key.procStart, lastSessionID: sessionA
        )
        let host = HostSnapshot(panes: [HostPane(tty: "ttys010", pid: 500, isDead: false, sessionName: launchID(sessionA))], clients: [])
        let refusal = RestoreActions.plan(
            source: .recorded(session), config: config, agent: claude, terminalFor: sameTerminal,
            guardSnapshot: RestoreGuardSnapshot(liveSessions: [live], ledger: LaunchLedger(rows: [row]), host: host, now: at(0))
        ).failure
        t.expectEqual(refusal, .runningDetached(launchID: launchID(sessionA)), "AE2: a detached owned session is reattached, not resumed again")
        if let refusal { t.expectEqual(RestoreActions.outcome(for: refusal), .alreadyRunning, "AE2: and is not a failure in a Reopen all") }
    }

    // MARK: What is on offer, and Reopen last closed walking back

    do {
        let a = restorable(sessionA, cwd: "/p/a", endedAt: at(30))
        let b = restorable(sessionB, cwd: "/p/b", endedAt: at(20))
        let c = restorable(sessionC, cwd: "/p/c", endedAt: at(10))
        var state = RestoreState(closed: [a, b, c], bootID: bootOne)
        let first = RestoreActions.offer(state: state, starting: [])
        t.expectEqual(first.lastClosed?.sessionID, sessionA, "Reopen last closed takes the newest")
        t.expectEqual(first.closedCount, 3, "and can be repeated as often as the stack is deep")

        // A launched, not yet registered: the next press walks back.
        let second = RestoreActions.offer(state: state, starting: [sessionA])
        t.expectEqual(second.lastClosed?.sessionID, sessionB, "a second press, with the first still starting, takes the next one")
        t.expectEqual(second.closedCount, 2, "and the count already drops")
        t.expectEqual(RestoreActions.offer(state: state, starting: [sessionA, sessionB]).lastClosed?.sessionID, sessionC, "and a third walks back again")
        t.expectEqual(state.closed.map(\.sessionID), [sessionA, sessionB, sessionC], "none of it removes anything before it is running")

        // Once the restored session is live, the planner takes it off the stack.
        let plan = RestorePlanner.plan(ledger: LaunchLedger(), state: state, context: context(now: at(60), live: [sessionA]))
        state = plan.state
        t.expectEqual(state.closed.map(\.sessionID), [sessionB, sessionC], "a restored session leaves the closed stack when it is running")
        t.expectEqual(RestoreActions.offer(state: state, starting: []).lastClosed?.sessionID, sessionB, "and the next press takes the one below it")

        // Starting restore rows come from the ledger by the resumed id.
        let starting = LedgerRow(
            launchID: "5d1c7e0a-3b6e-4d7a-9c21-0e0b7a4d1f33", kind: .restore(resumedSessionID: sessionB), cwd: "/p/b",
            terminalID: "terminal-app", startedAt: at(0)
        )
        var failed = starting
        failed.launchID = "6e2d8f1b-4c7f-4e8b-8d32-1f1c8b5e2044"
        failed.kind = .restore(resumedSessionID: sessionC)
        failed.phase = .failed(reason: "x")
        t.expectEqual(
            RestoreActions.startingSessionIDs(in: LaunchLedger(rows: [starting, failed])), [sessionB],
            "only a restore still waiting to register is starting; a failed one is offered again"
        )
    }

    // MARK: Pending set offer and the banner

    do {
        let pendingSet = PendingReopenSet(
            sessions: [restorable(sessionA, cwd: "/p/a"), restorable(sessionB, cwd: "/p/b")], formedAt: at(5), cause: .powerOff
        )
        let state = RestoreState(pending: pendingSet, bootID: bootOne)
        let offer = RestoreActions.offer(state: state, starting: [])
        t.expectEqual(offer.pendingCount, 2, "Reopen all counts the pending set")
        let banner = RestoreActions.banner(offer: offer, dismissedFormedAt: nil)
        t.expectEqual(banner?.count, 2, "F2: after a restart the banner offers the whole set")
        t.expect(banner?.message.contains("2 sessions") == true, "and says how many")
        t.expect(RestoreActions.banner(offer: offer, dismissedFormedAt: at(5)) == nil, "a dismissed banner stays gone for that set")
        t.expect(RestoreActions.banner(offer: offer, dismissedFormedAt: at(1)) != nil, "and not for a later one")
        t.expect(RestoreActions.banner(offer: RestoreActions.offer(state: state, starting: [sessionA, sessionB]), dismissedFormedAt: nil) == nil, "it clears while every session is already starting")
        t.expect(RestoreActions.banner(offer: RestoreActions.offer(state: RestoreState(), starting: []), dismissedFormedAt: nil) == nil, "and with an empty set")
        var together = pendingSet
        together.cause = .together
        t.expect(
            RestoreActions.banner(offer: RestoreActions.offer(state: RestoreState(pending: together), starting: []), dismissedFormedAt: nil) == nil,
            "a Quit all is the user's own act: no banner, the header menu has it"
        )
        var died = pendingSet
        died.cause = .hostDied
        t.expect(
            RestoreActions.banner(offer: RestoreActions.offer(state: RestoreState(pending: died), starting: []), dismissedFormedAt: nil)?.message.contains("session host") == true,
            "a host death names it"
        )
    }

    // MARK: A batch of five runs as three, then two; one failure stays pending with its reason

    do {
        final class Recorder: @unchecked Sendable {
            var events: [String] = []
        }
        let recorder = Recorder()
        let items = [sessionA, sessionB, sessionC, sessionD, "11111111-2222-4333-8444-555555555555"]
        let results = blockingRun {
            await RestoreActions.run(
                items: items,
                sessionID: { $0 },
                name: { "name-\($0.prefix(4))" },
                start: { item -> RestoreStart<String> in
                    recorder.events.append("start \(item.prefix(4))")
                    return .started(item)
                },
                settle: { item in
                    recorder.events.append("settle \(item.prefix(4))")
                    return item == sessionB
                        ? .failed(reason: "The agent did not start within 15 seconds.", journal: .failed)
                        : .reopened
                }
            )
        } ?? []
        t.expectEqual(results.count, 5, "every session gets a result")
        t.expectEqual(
            recorder.events,
            ["start 0b6f", "start 5d2c", "start 7a9e", "settle 0b6f", "settle 5d2c", "settle 7a9e",
             "start 9c8b", "start 1111", "settle 9c8b", "settle 1111"],
            "five restores run as three, awaited, then two: the fourth does not start before the first batch is up"
        )
        t.expectEqual(results.map(\.sessionID), items, "results come back in order")
        let summary = RestoreActions.summary(of: results)
        t.expectEqual(summary.total, 5, "the summary counts them all")
        t.expectEqual(summary.failures.count, 1, "one failed")
        t.expectEqual(summary.failures.first?.reason, "The agent did not start within 15 seconds.", "with its reason")
        t.expectEqual(summary.failures.first?.name, "name-5d2c", "and its name")
        t.expectEqual(summary.headline, "Reopened 4 of 5; 1 failed", "R35: the strip says how it went")

        // The set after it: the failure stays in both lists; the rest left.
        var state = RestoreState(
            pending: PendingReopenSet(
                sessions: items.map { restorable($0, cwd: "/p/x") }, formedAt: at(0), cause: .powerOff
            ),
            closed: items.map { restorable($0, cwd: "/p/x") },
            bootID: bootOne
        )
        RestoreActions.apply(results, to: &state)
        t.expectEqual(ids(state.pending), [sessionB], "R35: a session that could not be restored stays in the pending set for a later try")
        t.expectEqual(state.closed.map(\.sessionID), [sessionB], "and on the closed stack")
        t.expect(state.pending?.touched == true, "a Reopen all marks the set as acted on, so a later event does not replace what is left")
        t.expectEqual(RestoreActions.offer(state: state, starting: []).pendingCount, 1, "and it is still offered")

        // Items that finish at the start (already running, refused) are results too.
        let mixed = blockingRun {
            await RestoreActions.run(
                items: [sessionA, sessionB], sessionID: { $0 }, name: { $0 },
                start: { item -> RestoreStart<String> in
                    item == sessionA ? .finished(.alreadyRunning) : .finished(.failed(reason: "no", journal: .notRestorable))
                },
                settle: { _ in .reopened }
            )
        } ?? []
        t.expectEqual(mixed.map(\.outcome.isSuccess), [true, false], "a refusal at the start is a result and does not stop the rest")
        t.expectEqual(RestoreActions.batches([1, 2, 3, 4, 5, 6, 7]).map(\.count), [3, 3, 1], "batches of three")
        t.expectEqual(RestoreActions.batches([Int]()).count, 0, "no items, no batches")
    }

    // MARK: Waiting for a restore to come up, and what a failure reads like

    do {
        var row = LedgerRow(
            launchID: "5d1c7e0a-3b6e-4d7a-9c21-0e0b7a4d1f33", kind: .restore(resumedSessionID: sessionA), cwd: "/p",
            terminalID: "terminal-app", startedAt: at(0)
        )
        t.expectEqual(RestoreActions.registration(of: row), .waiting, "a launch with no registry row yet is waiting")
        row.phase = .live
        t.expectEqual(RestoreActions.registration(of: row), .registered, "a registered one is up")
        row.phase = .failed(reason: LaunchLedger.timeoutReason)
        if case .failed(let reason) = RestoreActions.registration(of: row) {
            t.expect(reason.contains("did not start within 15 seconds"), "a launch that never registered fails with the ledger's reason")
            t.expect(reason.contains("conversation"), "and says what that usually means for a resume (no conversation found)")
        } else { t.expect(false, "a failed row is a failure") }
        row.phase = .starting
        row.endedAt = at(3)
        if case .failed = RestoreActions.registration(of: row) { t.expect(true, "a launch that ended before it registered failed") } else { t.expect(false, "a launch that ended before it registered failed") }
        if case .failed = RestoreActions.registration(of: nil) { t.expect(true, "a row that is gone is a failure") } else { t.expect(false, "a row that is gone is a failure") }
        // A retry inside the late-match window names the failure, not "already being resumed".
        var failedRow = row
        failedRow.phase = .failed(reason: LaunchLedger.timeoutReason)
        failedRow.endedAt = nil
        let failedLedger = LaunchLedger(rows: [failedRow])
        if case .failed(let why, _) = RestoreActions.outcome(for: .launchInFlight, sessionID: sessionA, ledger: failedLedger) {
            t.expect(why.contains("failed to start"), "R35: a retry just after a failure says it failed, not that it is being resumed")
        } else { t.expect(false, "a retry just after a failure is a failure with a reason") }
        if case .failed(let why, _) = RestoreActions.outcome(for: .launchInFlight, sessionID: sessionA, ledger: LaunchLedger()) {
            t.expect(why.contains("already being resumed"), "and with no failed launch it is the plain in-flight reason")
        } else { t.expect(false, "an in-flight refusal is a failure with a reason") }
        t.expect(RestoreActions.recentFailure(of: sessionB, in: failedLedger) == nil, "another session is unaffected")
        t.expectEqual(RestoreActions.restoreFailure("The terminal could not open the session: x"), "The terminal could not open the session: x", "other reasons are kept as they are")
    }

    // MARK: Lookup of a session's record, and the host record

    do {
        let pendingSession = restorable(sessionA, cwd: "/p/a")
        let closedSession = restorable(sessionB, cwd: "/p/b")
        let state = RestoreState(
            pending: PendingReopenSet(sessions: [pendingSession], formedAt: at(0), cause: .together), closed: [closedSession]
        )
        let aged = ended(sessionC, at: at(-500), cause: .exited, classified: true)
        let ledger = LaunchLedger(rows: [aged])
        t.expectEqual(RestoreActions.recordedSession(for: sessionA, state: state, ledger: ledger), pendingSession, "found in the pending set")
        t.expectEqual(RestoreActions.recordedSession(for: sessionB, state: state, ledger: ledger), closedSession, "found on the closed stack")
        let fromLedger = RestoreActions.recordedSession(for: sessionC, state: state, ledger: ledger)
        t.expectEqual(fromLedger?.profileID, "work", "a session that fell off the stack is found in the ledger")
        t.expectEqual(fromLedger?.preset.keepRunning, true, "with its recorded preset")
        t.expect(RestoreActions.recordedSession(for: sessionD, state: state, ledger: ledger) == nil, "a session AgentMenu never launched has no record")
        t.expectEqual(
            RestoreActions.displayName(of: pendingSession, entry: nil, rename: "  my name "), "my name", "a rename names it"
        )
        t.expectEqual(RestoreActions.displayName(of: pendingSession, entry: nil, rename: nil), "a", "else its folder")

        t.expect(RestoreActions.mayClearHostRecord(ledger: LaunchLedger()), "no rows: the host's recorded death may go")
        var hostedLive = ended(sessionA, at: at(0))
        hostedLive.endedAt = nil
        t.expect(!RestoreActions.mayClearHostRecord(ledger: LaunchLedger(rows: [hostedLive])), "a hosted row still running is about to end under a dead server: keep the record")
        t.expect(!RestoreActions.mayClearHostRecord(ledger: LaunchLedger(rows: [ended(sessionA, at: at(0))])), "an ended one still inside the settle window would be misread: keep it")
        t.expect(RestoreActions.mayClearHostRecord(ledger: LaunchLedger(rows: [ended(sessionA, at: at(0), classified: true)])), "once every hosted row is classified it may go")
        t.expect(RestoreActions.mayClearHostRecord(ledger: LaunchLedger(rows: [ended(sessionA, at: at(0), hosted: false)])), "a plain launch has nothing to do with the host")
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
