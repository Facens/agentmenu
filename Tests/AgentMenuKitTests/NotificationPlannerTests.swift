// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

// U7 — Needs-you and Your-turn notifications (R32, R33, KTD10, KTD15).
//
// The planner is pure and takes its clock as a value, so every test here
// drives time by hand: no sleeping, no `Date()`, no notification centre.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func key(_ pid: Int32 = 100) -> LiveSessionKey {
    LiveSessionKey(configDirectory: "/cfg/work", pid: pid, procStart: 1_799_990_000 + Int(pid))
}

private let iterm = TerminalIdentity(id: "iterm2", displayName: "iTerm2")

private func session(
    _ status: SessionStatus,
    pid: Int32 = 100,
    sessionId: String = "00000000-0000-4000-8000-000000000001",
    tty: String? = nil,
    terminal: TerminalIdentity = .other,
    cwd: String? = "/Users/test/dev/agentmenu",
    waitingFor: String? = "permission prompt",
    name: String? = "Fix the parser",
    statusUpdatedAt: Date? = nil
) -> LiveSession {
    LiveSession(
        key: key(pid), agentID: "claude-code", agentDisplayName: "Claude Code",
        pid: pid, sessionId: sessionId, cwd: cwd, registryName: name,
        status: status, waitingFor: status == .needsYou ? waitingFor : nil,
        tty: tty, terminal: terminal,
        startedAt: t0.addingTimeInterval(-600), statusUpdatedAt: statusUpdatedAt
    )
}

/// A planner and a hand-wound clock.
private struct Sim {
    var planner = NotificationPlanner()
    var now = t0
    var settings = NotificationSettings()
    var authorization = NotificationAuthorization.authorized
    var owned: Set<LiveSessionKey> = []

    mutating func step(
        _ seconds: TimeInterval,
        _ live: [LiveSession],
        frontmost: [String: FrontmostAnswer] = [:]
    ) -> NotificationPlan {
        now = now.addingTimeInterval(seconds)
        return planner.evaluate(NotificationInput(
            now: now, live: live, owned: owned, settings: settings,
            authorization: authorization, frontmost: frontmost
        ))
    }
}

func runNotificationPlannerTests(_ t: TestRunner) {
    t.suite("NotificationPlanner")

    // MARK: R32 — the hold-down

    do {
        var sim = Sim()
        let waiting = [session(.needsYou)]
        let first = sim.step(0, waiting)
        t.expect(first.posts.isEmpty, "nothing posts the moment a session starts waiting")
        t.expectEqual(first.nextDeadline, t0.addingTimeInterval(3), "the planner says when the hold-down ends, for the app's timer")
        let early = sim.step(2.5, waiting)
        t.expect(early.posts.isEmpty, "2.5 s is still inside the hold-down")
        t.expectEqual(early.nextDeadline, t0.addingTimeInterval(3), "and the deadline has not moved")
        let due = sim.step(0.5, waiting)
        t.expectEqual(due.posts.count, 1, "Needs you held for 3 s posts once")
        t.expectEqual(due.nextDeadline, nil, "no hold-down is left running")
        let note = due.posts.first
        t.expectEqual(note?.kind, .needsYou, "it is a Needs-you notification")
        t.expectEqual(note?.title, "Fix the parser needs you", "it names the session")
        t.expectEqual(note?.body, "Permission prompt in agentmenu", "and the folder and the reason")
        t.expectEqual(note?.threadID, "/Users/test/dev/agentmenu", "its thread is the folder")
        t.expectEqual(note?.rowTokens, [NotificationPlanner.token(key())], "it carries the row key")
        let later = sim.step(10, waiting)
        t.expect(later.isEmpty, "the same episode across later snapshots posts nothing more")
    }

    do {
        var sim = Sim()
        _ = sim.step(0, [session(.needsYou)])
        let answered = sim.step(2, [session(.working)])
        t.expect(answered.posts.isEmpty && answered.withdrawals.isEmpty, "answered at 2 s: nothing posted, nothing to withdraw")
        let after = sim.step(5, [session(.working)])
        t.expect(after.isEmpty, "and nothing posts afterwards for that episode")
        t.expectEqual(after.nextDeadline, nil, "no deadline is left dangling")
    }

    // MARK: Withdraw, episodes, /clear

    do {
        var sim = Sim()
        _ = sim.step(0, [session(.needsYou)])
        let posted = sim.step(3, [session(.needsYou)])
        let id = posted.posts.first?.identifier
        let left = sim.step(1, [session(.working)])
        t.expectEqual(left.withdrawals, id.map { [$0] } ?? [], "leaving Needs you withdraws the notification that was posted")
        t.expect(left.posts.isEmpty, "and posts nothing")
        t.expect(sim.step(1, [session(.working)]).withdrawals.isEmpty, "it is withdrawn once")
    }

    do {
        var sim = Sim()
        _ = sim.step(0, [session(.needsYou)])
        let first = sim.step(3, [session(.needsYou)])
        _ = sim.step(1, [session(.working)])
        _ = sim.step(1, [session(.needsYou)])
        let second = sim.step(3, [session(.needsYou)])
        t.expectEqual(second.posts.count, 1, "a second waiting episode of the same session posts again")
        t.expect(first.posts.first?.identifier != second.posts.first?.identifier, "under its own identifier (row key, episode)")
        t.expect(sim.step(5, [session(.needsYou)]).posts.isEmpty, "and only once")
    }

    do {
        var sim = Sim()
        _ = sim.step(0, [session(.needsYou, sessionId: "00000000-0000-4000-8000-00000000000a")])
        let posted = sim.step(3, [session(.needsYou, sessionId: "00000000-0000-4000-8000-00000000000a")])
        // `/clear` rewrites the id in place; the pid and its start do not move.
        let cleared = sim.step(4, [session(.needsYou, sessionId: "00000000-0000-4000-8000-00000000000b", statusUpdatedAt: t0.addingTimeInterval(6))])
        t.expectEqual(posted.posts.count, 1, "the episode posted")
        t.expect(cleared.isEmpty, "/clear changing the session id mid-episode does not re-post or withdraw")
    }

    do {
        var sim = Sim()
        _ = sim.step(0, [session(.needsYou)])
        let posted = sim.step(3, [session(.needsYou)])
        let gone = sim.step(1, [])
        t.expectEqual(gone.withdrawals, posted.posts.map(\.identifier), "a session that ends while Needs you withdraws its notification")
        let other = sim.step(1, [session(.needsYou)])
        t.expect(other.posts.isEmpty, "and a newcomer has its own hold-down")
    }

    do {
        var sim = Sim()
        _ = sim.step(0, [])
        _ = sim.step(1, [session(.needsYou), session(.needsYou, pid: 200)])
        let posted = sim.step(3, [session(.needsYou), session(.needsYou, pid: 200)])
        t.expectEqual(posted.posts.count, 2, "two sessions that start waiting while the app runs are two notifications, not a summary")
    }

    // MARK: Unknown never notifies

    do {
        var sim = Sim()
        for second in stride(from: 0, through: 60, by: 5) {
            let plan = sim.step(second == 0 ? 0 : 5, [session(.unknown)])
            t.expect(plan.isEmpty, "an unknown-status row never notifies (\(second)s)")
        }
        var sim2 = Sim()
        _ = sim2.step(0, [session(.working)])
        _ = sim2.step(40, [session(.unknown)])
        t.expect(sim2.step(40, [session(.unknown)]).posts.isEmpty, "unknown after working is not promoted to Needs you")
        var sim3 = Sim()
        _ = sim3.step(0, [session(.needsYou)])
        let posted = sim3.step(3, [session(.needsYou)])
        let becameUnknown = sim3.step(1, [session(.unknown)])
        t.expectEqual(becameUnknown.withdrawals, posted.posts.map(\.identifier), "a row that stops being Needs you — even into unknown — takes its banner back")
    }

    // MARK: KTD10 — frontmost suppression (AE11)

    do {
        var sim = Sim()
        let here = session(.needsYou, tty: "ttys004", terminal: iterm)
        _ = sim.step(0, [here])
        let due = sim.step(3, [here])
        t.expectEqual(due.frontmostChecks, [FrontmostCheck(terminalID: "iterm2")], "when the hold-down expires the terminal is asked which tab is on screen")
        t.expect(due.posts.isEmpty, "and nothing posts until it answers")
        let again = sim.step(1, [here])
        t.expect(again.frontmostChecks.isEmpty, "the terminal is asked once, not on every tick")
        let answered = sim.step(0.5, [here], frontmost: ["iterm2": .selectedTTY("/dev/ttys004")])
        t.expect(answered.posts.isEmpty, "AE11: Needs you while that session's tty is frontmost posts nothing")
        t.expect(sim.step(10, [here]).isEmpty, "and stays quiet for the rest of the episode, without asking again")
    }

    do {
        var sim = Sim()
        let here = session(.needsYou, tty: "/dev/ttys004", terminal: iterm)
        _ = sim.step(0, [here])
        _ = sim.step(3, [here])
        let other = sim.step(0.5, [here], frontmost: ["iterm2": .selectedTTY("ttys009")])
        t.expectEqual(other.posts.count, 1, "another tab in front does not suppress it")
    }

    do {
        var sim = Sim()
        let here = session(.needsYou, tty: "ttys004", terminal: iterm)
        _ = sim.step(0, [here])
        _ = sim.step(3, [here])
        let answered = sim.step(0.5, [here], frontmost: ["iterm2": .notFrontmost])
        t.expectEqual(answered.posts.count, 1, "no frontmost tty available (terminal in back, key absent, no Automation grant) counts as not frontmost and posts")
    }

    do {
        // A session the app cannot place in a terminal, or with no tty, is
        // never asked about: it cannot be the tab on screen.
        var sim = Sim()
        let noTTY = session(.needsYou, tty: nil, terminal: iterm)
        _ = sim.step(0, [noTTY])
        let due = sim.step(3, [noTTY])
        t.expect(due.frontmostChecks.isEmpty, "a session with no tty is not asked about")
        t.expectEqual(due.posts.count, 1, "and posts")
        var sim2 = Sim()
        let unplaced = session(.needsYou, tty: "ttys004", terminal: .other)
        _ = sim2.step(0, [unplaced])
        let due2 = sim2.step(3, [unplaced])
        t.expect(due2.frontmostChecks.isEmpty && due2.posts.count == 1, "an unrecognised terminal posts without a question")
    }

    do {
        // Two sessions in one terminal: one question.
        var sim = Sim()
        let a = session(.needsYou, pid: 1, tty: "ttys001", terminal: iterm)
        let b = session(.needsYou, pid: 2, tty: "ttys002", terminal: iterm)
        _ = sim.step(0, [a, b])
        let due = sim.step(3, [a, b])
        t.expectEqual(due.frontmostChecks.count, 1, "two sessions expiring in one terminal ask it once")
        let answered = sim.step(0.2, [a, b], frontmost: ["iterm2": .selectedTTY("ttys002")])
        t.expectEqual(answered.posts.map(\.rowTokens), [[NotificationPlanner.token(key(1))]], "the one on screen is suppressed, the other posts")
    }

    do {
        // Leaving while the answer is pending ends the episode quietly.
        var sim = Sim()
        let here = session(.needsYou, tty: "ttys004", terminal: iterm)
        _ = sim.step(0, [here])
        _ = sim.step(3, [here])
        let left = sim.step(0.1, [session(.needsYou, tty: "ttys004", terminal: iterm).with(status: .working)], frontmost: ["iterm2": .notFrontmost])
        t.expect(left.isEmpty, "an episode that ends while its question is pending posts and withdraws nothing")
    }

    // MARK: Toggle and authorization

    do {
        var sim = Sim()
        sim.settings.needsYou = false
        _ = sim.step(0, [session(.needsYou)])
        t.expect(sim.step(3, [session(.needsYou)]).posts.isEmpty, "the Needs-you toggle off suppresses posting")
        sim.settings.needsYou = true
        t.expect(sim.step(5, [session(.needsYou)]).posts.isEmpty, "turning it on mid-episode does not announce it after the fact")
        _ = sim.step(1, [session(.working)])
        _ = sim.step(1, [session(.needsYou)])
        t.expectEqual(sim.step(3, [session(.needsYou)]).posts.count, 1, "the next episode posts")
    }

    do {
        var sim = Sim()
        _ = sim.step(0, [session(.needsYou)])
        let posted = sim.step(3, [session(.needsYou)])
        sim.settings.needsYou = false
        let off = sim.step(1, [session(.needsYou)])
        t.expectEqual(off.withdrawals, posted.posts.map(\.identifier), "turning the toggle off takes down what is showing")
    }

    // The startup summary is what is showing when the gate closes: it is
    // withdrawn, its members stay decided, and opening the gate again in the
    // same episode announces nothing after the fact.
    for closeGate in ["the Needs-you toggle", "authorization denied"] {
        var sim = Sim()
        let live = [session(.needsYou, pid: 1, name: "One"), session(.needsYou, pid: 2, name: "Two")]
        _ = sim.step(0, live)
        let due = sim.step(3, live)
        t.expectEqual(due.posts.first?.kind, .needsYouSummary, "\(closeGate): two sessions waiting at startup post a summary")
        let summaryID = due.posts.first?.identifier
        t.expect(summaryID != nil, "\(closeGate): the summary has an identifier")

        if closeGate == "the Needs-you toggle" {
            sim.settings.needsYou = false
        } else {
            sim.authorization = .denied
        }
        let off = sim.step(1, live)
        t.expectEqual(off.withdrawals, summaryID.map { [$0] } ?? [], "\(closeGate): closing the gate takes down the summary, and only it")
        t.expect(off.posts.isEmpty, "\(closeGate): and posts nothing")
        t.expect(sim.step(1, live).withdrawals.isEmpty, "\(closeGate): it is withdrawn once")

        if closeGate == "the Needs-you toggle" {
            sim.settings.needsYou = true
        } else {
            sim.authorization = .authorized
        }
        t.expect(sim.step(1, live).posts.isEmpty, "\(closeGate): opening the gate again does not re-announce the same episode")
        t.expect(sim.step(5, live).isEmpty, "\(closeGate): and nothing follows for the members")
    }

    do {
        var sim = Sim()
        sim.authorization = .denied
        _ = sim.step(0, [session(.needsYou)])
        let due = sim.step(3, [session(.needsYou)])
        t.expect(due.posts.isEmpty && due.frontmostChecks.isEmpty, "authorization denied: the planner runs, nothing is posted, no terminal is asked")
        sim.authorization = .authorized
        t.expect(sim.step(5, [session(.needsYou)]).posts.isEmpty, "granting it mid-episode does not announce the old episode")
        t.expectEqual(
            NotificationGuidance.sessionsTab(authorization: .denied, notifyNeedsYou: true)?.contains(NotificationGuidance.systemSettingsPath),
            true, "denied: the Sessions tab guidance carries the System Settings path"
        )
        t.expectEqual(NotificationGuidance.systemSettingsPath, "System Settings › Notifications › AgentMenu", "and the path is the one macOS shows")
        t.expectEqual(NotificationGuidance.sessionsTab(authorization: .authorized, notifyNeedsYou: true), nil, "no guidance when allowed")
        t.expectEqual(NotificationGuidance.sessionsTab(authorization: .notDetermined, notifyNeedsYou: true), nil, "no guidance before the question is answered")
        t.expectEqual(NotificationGuidance.sessionsTab(authorization: .denied, notifyNeedsYou: false), nil, "no guidance under a switch that is off")
        t.expectEqual(
            NotificationGuidance.settings(authorization: .denied)?.contains(NotificationGuidance.systemSettingsPath), true,
            "the Settings toggle's note carries the path too, whatever the switch says"
        )
        t.expectEqual(NotificationGuidance.settings(authorization: .authorized), nil, "and is absent when allowed")
    }

    do {
        var sim = Sim()
        sim.authorization = .notDetermined
        _ = sim.step(0, [session(.needsYou)])
        let waiting = sim.step(6, [session(.needsYou)])
        t.expect(waiting.posts.isEmpty && waiting.nextDeadline == nil, "an undetermined authorization holds the episode, with no deadline to spin on")
        sim.authorization = .authorized
        t.expectEqual(sim.step(1, [session(.needsYou)]).posts.count, 1, "and it posts once macOS says yes")
    }

    // MARK: Startup

    do {
        var sim = Sim()
        let live = [session(.needsYou, pid: 1, name: "One"), session(.needsYou, pid: 2, name: "Two"), session(.needsYou, pid: 3, name: "Three"), session(.working, pid: 4)]
        _ = sim.step(0, live)
        let due = sim.step(3, live)
        t.expectEqual(due.posts.count, 1, "at startup, sessions already in Needs you post ONE summary rather than one each")
        t.expectEqual(due.posts.first?.kind, .needsYouSummary, "it is a summary")
        t.expectEqual(due.posts.first?.title, "3 sessions need you", "naming how many")
        t.expectEqual(due.posts.first?.body, "One, Two, Three", "and which")
        t.expectEqual(due.posts.first?.rowTokens.count, 3, "carrying all three row keys")
        t.expect(sim.step(10, live).isEmpty, "and nothing more while they wait")

        // The summary stays until the last session it covers stops waiting.
        let one = sim.step(1, [session(.working, pid: 1), session(.needsYou, pid: 2), session(.needsYou, pid: 3)])
        t.expect(one.withdrawals.isEmpty, "the summary stays while two still wait")
        let two = sim.step(1, [session(.working, pid: 1), session(.working, pid: 2), session(.needsYou, pid: 3)])
        t.expect(two.withdrawals.isEmpty, "and while one does")
        let last = sim.step(1, [session(.working, pid: 1), session(.working, pid: 2), session(.yourTurn, pid: 3)])
        t.expectEqual(last.withdrawals, due.posts.map(\.identifier), "it goes when the last one stops")

        // A session that starts waiting later is an ordinary episode.
        let fresh = sim.step(1, [session(.needsYou, pid: 4)])
        t.expect(fresh.posts.isEmpty, "a later session gets its own hold-down")
        t.expectEqual(sim.step(3, [session(.needsYou, pid: 4)]).posts.first?.kind, .needsYou, "and its own notification, not a summary")
    }

    do {
        var sim = Sim()
        let live = [session(.needsYou, pid: 1), session(.working, pid: 2)]
        _ = sim.step(0, live)
        let due = sim.step(3, live)
        t.expectEqual(due.posts.first?.kind, .needsYou, "a single session waiting at startup gets its own banner, not a summary of one")
    }

    do {
        // The group waits for the slowest member's frontmost answer, and
        // the one on screen is left out of it.
        var sim = Sim()
        let a = session(.needsYou, pid: 1, tty: "ttys001", terminal: iterm)
        let b = session(.needsYou, pid: 2, tty: "ttys002", terminal: iterm)
        let c = session(.needsYou, pid: 3)
        _ = sim.step(0, [a, b, c])
        let due = sim.step(3, [a, b, c])
        t.expect(due.posts.isEmpty, "the startup group posts nothing while a question is open")
        let answered = sim.step(0.2, [a, b, c], frontmost: ["iterm2": .selectedTTY("ttys001")])
        t.expectEqual(answered.posts.count, 1, "then one summary")
        t.expectEqual(answered.posts.first?.rowTokens.count, 2, "without the session on screen")
    }

    // MARK: Reconciling what an earlier run left on screen

    do {
        var planner = NotificationPlanner()
        let stillWaiting = DeliveredNotification(identifier: "needs-you.\(NotificationPlanner.token(key(1))).1", kind: .needsYou, rowTokens: [NotificationPlanner.token(key(1))])
        let answered = DeliveredNotification(identifier: "needs-you.\(NotificationPlanner.token(key(2))).1", kind: .needsYou, rowTokens: [NotificationPlanner.token(key(2))])
        let ended = DeliveredNotification(identifier: "needs-you.\(NotificationPlanner.token(key(3))).1", kind: .needsYou, rowTokens: [NotificationPlanner.token(key(3))])
        planner.seed(delivered: [stillWaiting, answered, ended])
        let live = [session(.needsYou, pid: 1), session(.working, pid: 2)]
        let first = planner.evaluate(NotificationInput(now: t0, live: live))
        t.expectEqual(Set(first.withdrawals), Set([answered.identifier, ended.identifier]), "at startup, delivered banners whose session is no longer Needs you are withdrawn")
        let later = planner.evaluate(NotificationInput(now: t0.addingTimeInterval(4), live: live))
        t.expect(later.posts.isEmpty, "a banner that is still true is adopted: the episode is not announced twice")
        let gone = planner.evaluate(NotificationInput(now: t0.addingTimeInterval(5), live: [session(.working, pid: 1), session(.working, pid: 2)]))
        t.expectEqual(gone.withdrawals, [stillWaiting.identifier], "and the adopted banner is withdrawn when its session stops waiting")
    }

    do {
        var planner = NotificationPlanner()
        let tokens = [1, 2].map { NotificationPlanner.token(key(Int32($0))) }
        let summary = DeliveredNotification(identifier: "needs-you.summary", kind: .needsYouSummary, rowTokens: tokens)
        planner.seed(delivered: [summary])
        let live = [session(.needsYou, pid: 1), session(.needsYou, pid: 2)]
        let first = planner.evaluate(NotificationInput(now: t0, live: live))
        t.expect(first.withdrawals.isEmpty, "a delivered summary with waiting members is kept")
        t.expect(planner.evaluate(NotificationInput(now: t0.addingTimeInterval(4), live: live)).posts.isEmpty, "and they are not summarised again")
        let gone = planner.evaluate(NotificationInput(now: t0.addingTimeInterval(5), live: []))
        t.expectEqual(gone.withdrawals, ["needs-you.summary"], "it goes when they do")

        var other = NotificationPlanner()
        other.seed(delivered: [summary])
        t.expectEqual(other.evaluate(NotificationInput(now: t0, live: [session(.working, pid: 9)])).withdrawals, ["needs-you.summary"], "a summary with nobody left waiting is withdrawn at once")
    }

    // MARK: R33 — Your turn

    do {
        var sim = Sim()
        sim.settings.yourTurn = true
        sim.owned = [key()]
        _ = sim.step(0, [session(.working)])
        let done = sim.step(45, [session(.yourTurn)])
        t.expectEqual(done.posts.count, 1, "Your turn after a 45 s turn of an owned session posts")
        t.expectEqual(done.posts.first?.kind, .yourTurn, "it is a Your-turn notification")
        t.expectEqual(done.posts.first?.title, "Fix the parser is ready", "it names the session")
        t.expectEqual(done.posts.first?.body, "Your turn in agentmenu, after 45s", "the folder and how long it took")
        t.expect(sim.step(20, [session(.yourTurn)]).posts.isEmpty, "and only once")
        let busy = sim.step(1, [session(.working)])
        t.expectEqual(busy.withdrawals, done.posts.map(\.identifier), "starting work again takes the banner back")
        let second = sim.step(40, [session(.yourTurn)])
        t.expectEqual(second.posts.count, 1, "the next long turn posts again")
        t.expect(second.posts.first?.identifier != done.posts.first?.identifier, "under its own identifier")
    }

    do {
        var sim = Sim()
        sim.settings.yourTurn = true
        sim.owned = [key()]
        _ = sim.step(0, [session(.working)])
        t.expect(sim.step(10, [session(.yourTurn)]).posts.isEmpty, "after a 10 s turn it does not")
        _ = sim.step(1, [session(.working)])
        t.expect(sim.step(29, [session(.yourTurn)]).posts.isEmpty, "29 s is still short")
        _ = sim.step(1, [session(.working)])
        t.expectEqual(sim.step(30, [session(.yourTurn)]).posts.count, 1, "30 s is enough")
    }

    do {
        var sim = Sim()
        sim.settings.yourTurn = true
        _ = sim.step(0, [session(.working)])
        t.expect(sim.step(120, [session(.yourTurn)]).posts.isEmpty, "for an unowned session Your turn never notifies")
        var off = Sim()
        off.owned = [key()]
        _ = off.step(0, [session(.working)])
        t.expect(off.step(120, [session(.yourTurn)]).posts.isEmpty, "with the Your-turn toggle off it never posts, owned or not")
    }

    do {
        // A permission wait in the middle is part of the turn.
        var sim = Sim()
        sim.settings.yourTurn = true
        sim.owned = [key()]
        _ = sim.step(0, [session(.working)])
        _ = sim.step(20, [session(.needsYou)])
        _ = sim.step(5, [session(.working)])
        t.expectEqual(sim.step(10, [session(.yourTurn)]).posts.count, 1, "a turn spans a Needs-you wait: 35 s from the first working")

        // A session first seen already at Your turn has no known turn.
        var cold = Sim()
        cold.settings.yourTurn = true
        cold.owned = [key()]
        t.expect(cold.step(0, [session(.yourTurn)]).posts.isEmpty, "a session first seen idle posts nothing")

        // The registry's own timestamp dates a turn that began before the app did.
        var started = Sim()
        started.settings.yourTurn = true
        started.owned = [key()]
        _ = started.step(0, [session(.working, statusUpdatedAt: t0.addingTimeInterval(-300))])
        t.expectEqual(started.step(2, [session(.yourTurn)]).posts.count, 1, "an app started mid-turn counts the turn from the registry's own time")
    }

    do {
        var sim = Sim()
        sim.settings.yourTurn = true
        sim.owned = [key()]
        sim.authorization = .denied
        _ = sim.step(0, [session(.working)])
        t.expect(sim.step(60, [session(.yourTurn)]).posts.isEmpty, "denied authorization silences Your turn too")
    }

    // MARK: Click

    do {
        let live = [session(.needsYou, pid: 1)]
        let token = NotificationPlanner.token(key(1))
        t.expectEqual(
            NotificationClick.resolve(userInfo: ["kind": "needs-you", "rows": token], live: live), .focus(key(1)),
            "a click on a banner whose session is running focuses it (R8)"
        )
        t.expectEqual(
            NotificationClick.resolve(userInfo: ["kind": "needs-you", "rows": token], live: []), .showClosed,
            "a click on a banner whose session has ended opens the Sessions tab on Closed"
        )
        t.expectEqual(
            NotificationClick.resolve(userInfo: ["kind": "your-turn", "rows": token], live: []), .showClosed,
            "a Your-turn banner does the same"
        )
        t.expectEqual(
            NotificationClick.resolve(userInfo: ["kind": "needs-you-summary", "rows": token], live: live), .showLive,
            "a summary opens the live list"
        )
        t.expectEqual(NotificationClick.resolve(userInfo: [:], live: live), .showLive, "a banner this build cannot read opens the live list")
        t.expectEqual(NotificationClick.resolve(userInfo: ["kind": "needs-you"], live: live), .showLive, "as does one with no row")

        // The userInfo the planner writes is the one the click reads.
        var sim = Sim()
        _ = sim.step(0, [session(.needsYou, pid: 1)])
        if let note = sim.step(3, [session(.needsYou, pid: 1)]).posts.first {
            t.expectEqual(NotificationClick.resolve(userInfo: note.userInfo, live: live), .focus(key(1)), "a planned notification's userInfo resolves back to its row key")
            t.expectEqual(
                DeliveredNotification(identifier: note.identifier, userInfo: note.userInfo),
                DeliveredNotification(identifier: note.identifier, kind: .needsYou, rowTokens: note.rowTokens),
                "and round-trips through the reconciliation type"
            )
        } else {
            t.expect(false, "expected a notification to read back")
        }
        t.expect(DeliveredNotification(identifier: "x", userInfo: ["kind": "nonsense"]) == nil, "a notification that is not ours is not adopted")
    }

    // MARK: Asking macOS (KTD15)

    do {
        var config = Config()
        t.expect(NotificationAuthorizationPolicy.shouldRequest(config: config), "a fresh config asks on the first user action")
        config.notificationsAsked = true
        t.expect(!NotificationAuthorizationPolicy.shouldRequest(config: config), "and never again once asked, whatever the answer")
        var off = Config()
        off.notifyNeedsYou = false
        t.expect(NotificationAuthorizationPolicy.shouldRequest(config: off), "Your-turn notifications alone are still worth asking permission for")
        off.notifyYourTurn = false
        t.expect(!NotificationAuthorizationPolicy.shouldRequest(config: off), "with both toggles off there is nothing to ask permission for")
    }

    // MARK: The frontmost probe

    do {
        let terminals = [
            TerminalManifest(
                id: "iterm2", displayName: "iTerm2", kind: .applescript, bundleID: "com.googlecode.iterm2",
                appleScript: "on run argv\nend run", frontmostTTYAppleScript: "tell application \"iTerm\" to return \"x\"", origin: .bundled
            ),
            TerminalManifest(
                id: "bare", displayName: "Bare", kind: .applescript, bundleID: "com.example.bare",
                appleScript: "on run argv\nend run", origin: .bundled
            ),
        ]
        t.expect(FrontmostTTYProbe.request(terminalID: "iterm2", terminals: terminals) != nil, "a terminal with the key can be asked")
        t.expect(FrontmostTTYProbe.request(terminalID: "bare", terminals: terminals) == nil, "a terminal without the key cannot")
        t.expect(FrontmostTTYProbe.request(terminalID: "missing", terminals: terminals) == nil, "nor can one that is not loaded")

        guard let request = FrontmostTTYProbe.request(terminalID: "iterm2", terminals: terminals) else { return }
        final class Calls { var scripts: [[String]] = [] }

        func probe(output: Result<String, Error>, granted: Bool = true, calls: Calls) -> FrontmostTTYProbe {
            FrontmostTTYProbe(
                runner: { _, arguments in calls.scripts.append(arguments); return try output.get() },
                automationGranted: { _ in granted }
            )
        }

        let ok = Calls()
        t.expectEqual(
            probe(output: .success("/dev/ttys004\n"), calls: ok).answer(request, frontmostBundleID: "com.googlecode.iterm2"),
            .selectedTTY("/dev/ttys004"), "the frontmost terminal's selected tab comes back as a tty"
        )
        t.expectEqual(ok.scripts.count, 1, "asking costs one script")
        t.expectEqual(ok.scripts.first?.first, "-e", "run inline with osascript -e")
        t.expectEqual(
            probe(output: .success("ttys004"), calls: Calls()).answer(request, frontmostBundleID: "com.googlecode.iterm2"),
            .selectedTTY("/dev/ttys004"), "a bare device name is normalised to the device form"
        )

        for (what, bundle) in [("another app in front", "com.apple.Safari" as String?), ("nothing in front", nil)] {
            let calls = Calls()
            t.expectEqual(
                probe(output: .success("/dev/ttys004"), calls: calls).answer(request, frontmostBundleID: bundle),
                .notFrontmost, "\(what) counts as not frontmost"
            )
            t.expectEqual(calls.scripts.count, 0, "and no Apple Event is sent unless the terminal is frontmost (\(what))")
        }

        let denied = Calls()
        t.expectEqual(
            probe(output: .success("/dev/ttys004"), granted: false, calls: denied).answer(request, frontmostBundleID: "com.googlecode.iterm2"),
            .notFrontmost, "no Automation grant counts as not frontmost"
        )
        t.expectEqual(denied.scripts.count, 0, "and is checked before any Apple Event is sent")

        struct Boom: Error {}
        t.expectEqual(
            probe(output: .failure(Boom()), calls: Calls()).answer(request, frontmostBundleID: "com.googlecode.iterm2"),
            .notFrontmost, "a script error counts as not frontmost"
        )
        for garbage in ["", "missing value", "not a tty; rm -rf", "/dev/"] {
            t.expectEqual(
                probe(output: .success(garbage), calls: Calls()).answer(request, frontmostBundleID: "com.googlecode.iterm2"),
                .notFrontmost, "an answer that is not a tty (\"\(garbage)\") counts as not frontmost"
            )
        }
    }

    // MARK: The manifest key

    do {
        t.expectNoThrow("frontmost_tty_applescript parses on an applescript terminal") {
            let manifest = try TerminalManifest.parse("""
            schema = 1
            id = "x"
            display_name = "X"
            kind = "applescript"
            bundle_id = "com.example.x"
            applescript = "on run argv\\nend run"
            frontmost_tty_applescript = "return \\"/dev/ttys001\\""
            """, origin: .user)
            if manifest.frontmostTTYAppleScript != "return \"/dev/ttys001\"" {
                throw NSError(domain: "test", code: 1, userInfo: [NSLocalizedDescriptionKey: "script not kept: \(manifest.frontmostTTYAppleScript ?? "nil")"])
            }
        }
        let bare = try? TerminalManifest.parse("""
        schema = 1
        id = "x"
        display_name = "X"
        kind = "applescript"
        bundle_id = "com.example.x"
        applescript = "on run argv\\nend run"
        """, origin: .user)
        t.expect(bare != nil && bare?.frontmostTTYAppleScript == nil, "the key is optional: a manifest that predates it still loads, never frontmost")
        t.expectThrows("an empty frontmost_tty_applescript is rejected") {
            try TerminalManifest.parse("""
            schema = 1
            id = "x"
            display_name = "X"
            kind = "applescript"
            bundle_id = "com.example.x"
            applescript = "on run argv\\nend run"
            frontmost_tty_applescript = ""
            """, origin: .user)
        }
        t.expectThrows("an argv terminal cannot set frontmost_tty_applescript") {
            try TerminalManifest.parse("""
            schema = 1
            id = "argv-x"
            display_name = "Argv"
            kind = "argv"
            binary = "tool"
            args = []
            frontmost_tty_applescript = "return \\"\\""
            """, origin: .user)
        }

        let resources = repositoryRoot().appendingPathComponent("Resources/terminals")
        let expected = [
            ("terminal-app.toml", "tty of selected tab of front window"),
            ("iterm2.toml", "tty of current session of current tab of current window"),
        ]
        for (file, fragment) in expected {
            let text = try? String(contentsOf: resources.appendingPathComponent(file), encoding: .utf8)
            let manifest = text.flatMap { try? TerminalManifest.parse($0, origin: .bundled) }
            let script = manifest?.frontmostTTYAppleScript ?? ""
            t.expect(script.contains(fragment), "\(file) asks the terminal for its selected tab's tty")
            t.expect(!script.contains("activate"), "\(file)'s frontmost script never activates the terminal")
        }
    }
}

private extension LiveSession {
    /// The same row in another status.
    func with(status: SessionStatus) -> LiveSession {
        LiveSession(
            key: key, agentID: agentID, agentDisplayName: agentDisplayName, pid: pid,
            sessionId: sessionId, cwd: cwd, registryName: registryName, status: status,
            tty: tty, terminal: terminal, startedAt: startedAt
        )
    }
}
