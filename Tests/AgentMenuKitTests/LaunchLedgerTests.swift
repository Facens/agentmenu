// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

// The launch ledger (U11): matching a launch to its registry row (KTD7), the
// 15-second Failed-to-start rule (R36), following a row across `/clear`,
// adoption after a crash, and what the ledger hands the snapshot and the
// restore guard. All pure: an observation is a value and the clock is an
// argument.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

private let configDirectory = "/profiles/work"
private let pinned = "5d1c7e0a-3b6e-4d7a-9c21-0e0b7a4d1f33"
private let resumed = "0f0c6a52-2b1d-4a43-8d37-6a1b9d2c7e10"

private func freshRow(
    id: String = pinned,
    hosted: Bool = true,
    started: Date = t0
) -> LedgerRow {
    LedgerRow(
        launchID: id,
        kind: .fresh,
        profileID: "work",
        configDirectory: configDirectory,
        cwd: "/projects/app",
        preset: Preset(model: "opus", keepRunning: hosted),
        terminalID: "terminal-app",
        hostSocket: hosted ? "/h/s" : nil,
        startedAt: started
    )
}

private func restoreRow(launchID: String = "11111111-1111-4111-8111-111111111111", hosted: Bool = true) -> LedgerRow {
    LedgerRow(
        launchID: launchID,
        kind: .restore(resumedSessionID: resumed),
        profileID: "work",
        configDirectory: configDirectory,
        cwd: "/projects/app",
        terminalID: "iterm2",
        hostSocket: hosted ? "/h/s" : nil,
        startedAt: t0
    )
}

private func session(
    pid: Int32,
    id: String?,
    tty: String? = nil,
    tmux: String? = nil,
    status: SessionStatus = .working
) -> LiveSession {
    LiveSession(
        key: LiveSessionKey(configDirectory: configDirectory, pid: pid, procStart: 1_800_000_000 + Int(pid)),
        agentID: RegistryReader.claudeAgentID,
        agentDisplayName: "Claude Code",
        pid: pid,
        sessionId: id,
        cwd: "/projects/app",
        status: status,
        tty: tty,
        tmux: tmux,
        startedAt: t0
    )
}

private func observe(
    _ live: [LiveSession],
    host: HostSnapshot? = nil,
    now: Date,
    running: Bool = false
) -> LedgerObservation {
    LedgerObservation(live: live, host: host, now: now, isSameProcessRunning: { _ in running })
}

private func pane(_ tty: String, session: String, dead: Bool = false) -> HostPane {
    HostPane(tty: tty, pid: 1, isDead: dead, sessionName: session)
}

func runLaunchLedgerTests(_ t: TestRunner) {
    t.suite("LaunchLedger")

    // MARK: Identity

    do {
        let id = LaunchLedger.newLaunchID()
        t.expect(SessionIdentifier.isValid(id), "a fresh launch id is a lowercase canonical UUID, the spelling `--session-id` accepts")
        t.expect(id == id.lowercased(), "and is lowercase")
        t.expect(LaunchLedger.newLaunchID() != id, "and differs from the last")
    }

    // MARK: A registry row with the pinned id marks the row Live with pid and procStart

    do {
        var ledger = LaunchLedger()
        ledger.begin(freshRow(), now: t0)
        t.expectEqual(ledger.pendingLaunches().count, 1, "a launch is Starting before its agent registers")
        t.expectEqual(ledger.pendingLaunches().first?.phase, .starting, "…as Starting")

        let changed = ledger.reconcile(observe([session(pid: 4242, id: pinned)], now: at(2)))
        t.expect(changed, "a match changes the row")
        let row = ledger.row(launchID: pinned)
        t.expectEqual(row?.phase, .live, "the pinned session id marks the row Live")
        t.expectEqual(row?.pid, 4242, "…with the pid")
        t.expectEqual(row?.procStart, 1_800_000_000 + 4242, "…and procStart")
        t.expectEqual(row?.lastSessionID, pinned, "…and the last session id seen")
        t.expect(ledger.pendingLaunches().isEmpty, "a live row is no longer pending")
        t.expect(ledger.inFlightSessionIDs(now: at(2)).isEmpty, "…nor in flight")

        let owned = ledger.ownedAttachments(live: [session(pid: 4242, id: pinned)], host: nil)
        t.expectEqual(owned[session(pid: 4242, id: pinned).key], .attached, "an owned session with no host information is attached")
    }

    // MARK: /clear changes the id; ownership follows pid and procStart

    do {
        var ledger = LaunchLedger()
        ledger.begin(freshRow(), now: t0)
        _ = ledger.reconcile(observe([session(pid: 7, id: pinned)], now: at(1)))
        let cleared = session(pid: 7, id: "99999999-9999-4999-8999-999999999999")
        let changed = ledger.reconcile(observe([cleared], now: at(30)))
        t.expect(changed, "a new session id on the same process is a change")
        let row = ledger.row(launchID: pinned)
        t.expectEqual(row?.phase, .live, "…and the row stays Live")
        t.expectEqual(row?.lastSessionID, "99999999-9999-4999-8999-999999999999", "the last seen id is updated")
        t.expectEqual(row?.pid, 7, "ownership is still by pid")
        t.expect(ledger.row(for: cleared.key) != nil, "the new id's row is found through its key")
        t.expect(ledger.ownedAttachments(live: [cleared], host: nil)[cleared.key] != nil, "and the cleared session is still owned")
    }

    // MARK: No registry row after the timeout is Failed to start, with a reason

    do {
        var ledger = LaunchLedger()
        ledger.begin(freshRow(), now: t0)
        _ = ledger.reconcile(observe([], now: at(14)))
        t.expectEqual(ledger.row(launchID: pinned)?.phase, .starting, "14 seconds in, still Starting")
        _ = ledger.reconcile(observe([], now: at(15)))
        if case .failed(let reason)? = ledger.row(launchID: pinned)?.phase {
            t.expectEqual(reason, LaunchLedger.timeoutReason, "no registry row in 15 seconds is a timeout")
        } else {
            t.expect(false, "15 seconds with no registry row is Failed to start")
        }
        t.expectEqual(ledger.pendingLaunches().first?.phase, .failedToStart(reason: LaunchLedger.timeoutReason), "the pending row carries the reason")
        t.expect(ledger.pendingLaunches().count == 1, "a failed launch stays listed until dismissed")

        // A hosted launch whose tmux session vanished says so.
        var vanished = LaunchLedger()
        vanished.begin(freshRow(), now: t0)
        _ = vanished.reconcile(observe([], host: HostSnapshot(), now: at(16)))
        t.expectEqual(
            vanished.row(launchID: pinned)?.phase,
            .failed(reason: LaunchLedger.sessionEndedReason),
            "a hosted launch whose session is gone from the host says the session ended"
        )
        // An unreadable host is no evidence of that.
        var unknown = LaunchLedger()
        unknown.begin(freshRow(), now: t0)
        _ = unknown.reconcile(observe([], host: nil, now: at(16)))
        t.expectEqual(unknown.row(launchID: pinned)?.phase, .failed(reason: LaunchLedger.timeoutReason), "with no host information the reason is the timeout")
        // A pane that is still there is not "ended".
        var alive = LaunchLedger()
        alive.begin(freshRow(), now: t0)
        _ = alive.reconcile(observe([], host: HostSnapshot(panes: [pane("ttys9", session: pinned)]), now: at(16)))
        t.expectEqual(alive.row(launchID: pinned)?.phase, .failed(reason: LaunchLedger.timeoutReason), "a live pane means the agent is slow, not gone")

        // Dismissing removes it from the list and from the ledger on the next prune.
        ledger.dismiss(launchID: pinned)
        t.expect(ledger.pendingLaunches().isEmpty, "a dismissed row is not listed")
        ledger.prune(now: at(20))
        t.expect(ledger.row(launchID: pinned) == nil, "and is pruned")
    }

    // MARK: Failed is not final: a slow agent that registers late is still owned

    do {
        var ledger = LaunchLedger()
        ledger.begin(freshRow(), now: t0)
        _ = ledger.reconcile(observe([], now: at(20)))
        t.expect({ if case .failed? = ledger.row(launchID: pinned)?.phase { return true } else { return false } }(), "marked failed at 20 s")
        t.expect(ledger.inFlightSessionIDs(now: at(21)).contains(pinned), "a failed launch is still in flight for the restore guard")
        _ = ledger.reconcile(observe([session(pid: 55, id: pinned)], now: at(40)))
        t.expectEqual(ledger.row(launchID: pinned)?.phase, .live, "a late registration flips Failed to Live")
        t.expectEqual(ledger.row(launchID: pinned)?.pid, 55, "…with its pid")

        // Long after, a row stops being matched.
        var stale = LaunchLedger()
        stale.begin(freshRow(), now: t0)
        _ = stale.reconcile(observe([], now: at(20)))
        _ = stale.reconcile(observe([session(pid: 56, id: pinned)], now: at(300)))
        t.expect({ if case .failed? = stale.row(launchID: pinned)?.phase { return true } else { return false } }(), "past the late-match window a failed row is left alone")
        t.expect(!stale.inFlightSessionIDs(now: at(300)).contains(pinned), "…and no longer in flight")
        t.expect(stale.hasRowsAwaitingRegistration(now: at(60)), "a failed row inside the window still needs the timer")
        t.expect(!stale.hasRowsAwaitingRegistration(now: at(300)), "a failed row past it does not keep a timer running for ever")
        // A hosted agent that registers after the window is still owned, by its pane.
        let lateHost = HostSnapshot(panes: [pane("ttys070", session: pinned)])
        _ = stale.reconcile(observe([session(pid: 57, id: nil, tty: "ttys070")], host: lateHost, now: at(400)))
        t.expectEqual(stale.row(launchID: pinned)?.phase, .live, "…but a late hosted agent is still matched by its pane tty")
    }

    // MARK: Restores: matched by the resumed id, then by pane tty; never by the registry's tmux field

    do {
        var byID = LaunchLedger()
        byID.begin(restoreRow(), now: t0)
        t.expect(byID.inFlightSessionIDs(now: at(1)).contains(resumed), "a restore is in flight under the resumed id, not its launch id")
        t.expect(!byID.inFlightSessionIDs(now: at(1)).contains("11111111-1111-4111-8111-111111111111"), "…and not under the tmux name")
        _ = byID.reconcile(observe([session(pid: 10, id: resumed, tmux: nil)], now: at(3)))
        t.expectEqual(byID.row(launchID: "11111111-1111-4111-8111-111111111111")?.phase, .live, "a restored hosted session with no registry tmux field is matched by its resumed id")

        var byTTY = LaunchLedger()
        byTTY.begin(restoreRow(), now: t0)
        let host = HostSnapshot(panes: [pane("ttys031", session: "11111111-1111-4111-8111-111111111111")])
        let noID = session(pid: 11, id: nil, tty: "ttys031")
        _ = byTTY.reconcile(observe([noID], host: host, now: at(3)))
        t.expectEqual(byTTY.row(launchID: "11111111-1111-4111-8111-111111111111")?.pid, 11, "…and by pane tty when the id is missing")

        // A different process on some other tty, with the registry's tmux
        // field set, is not matched on that alone.
        var hint = LaunchLedger()
        hint.begin(restoreRow(), now: t0)
        let stranger = session(pid: 12, id: "22222222-2222-4222-8222-222222222222", tty: "ttys099", tmux: "/h/s,1,%0")
        _ = hint.reconcile(observe([stranger], host: host, now: at(3)))
        t.expectEqual(hint.row(launchID: "11111111-1111-4111-8111-111111111111")?.phase, .starting, "the registry's tmux field is only a hint")

        // A plain launch is never matched by tty.
        var plain = LaunchLedger()
        plain.begin(restoreRow(hosted: false), now: t0)
        _ = plain.reconcile(observe([session(pid: 13, id: nil, tty: "ttys031")], host: host, now: at(3)))
        t.expectEqual(plain.row(launchID: "11111111-1111-4111-8111-111111111111")?.phase, .starting, "a plain row has no pane to match by")

        // One registry row can belong to one launch only.
        var two = LaunchLedger()
        two.begin(freshRow(id: pinned, hosted: false), now: t0)
        two.begin(restoreRow(launchID: "33333333-3333-4333-8333-333333333333", hosted: false), now: t0)
        _ = two.reconcile(observe([session(pid: 14, id: pinned)], now: at(2)))
        t.expectEqual(two.row(launchID: pinned)?.phase, .live, "the pinned row takes the row it matches")
        t.expectEqual(two.row(launchID: "33333333-3333-4333-8333-333333333333")?.phase, .starting, "…and the other launch does not")
    }

    // MARK: A matched row ends when its process is gone, never because it left one list

    do {
        var ledger = LaunchLedger()
        ledger.begin(freshRow(hosted: false), now: t0)
        _ = ledger.reconcile(observe([session(pid: 21, id: pinned)], now: at(1)))

        // Missing from the list but still running (a profile edit restarted
        // the reader, or its profile was removed): not ended.
        let kept = ledger.reconcile(observe([], now: at(5), running: true))
        t.expect(!kept, "a row missing from one list whose process runs changes nothing")
        t.expect(ledger.row(launchID: pinned)?.endedAt == nil, "…and is not ended")

        // The registry file was removed and the process is gone.
        let ended = ledger.reconcile(observe([], now: at(9), running: false))
        t.expect(ended, "a followed row that is gone ends")
        t.expectEqual(ledger.row(launchID: pinned)?.endedAt, at(9), "with the time it was seen to end")
        t.expect(ledger.row(launchID: pinned)?.endCause == nil, "and no cause: reconcile only says when")
        t.expect(ledger.liveOwnedRows.isEmpty, "an ended row is not in the live owned set")
        t.expect(ledger.ownedAttachments(live: [session(pid: 21, id: pinned)], host: nil).isEmpty, "…and not owned")
        let again = ledger.reconcile(observe([session(pid: 21, id: pinned)], now: at(12), running: true))
        t.expect(!again, "an ended row stays ended")
    }

    // MARK: Adoption after a crash

    do {
        let id = pinned
        var ledger = LaunchLedger()
        ledger.begin(freshRow(started: t0), now: t0)
        // AgentMenu crashed; it is back an hour later. The tmux session is alive.
        let later = at(3600)
        let host = HostSnapshot(panes: [pane("ttys040", session: id)])
        let adopted = ledger.adopt(host: host, now: later)
        t.expectEqual(adopted, [id], "a Starting row with a live pane is adopted")
        _ = ledger.reconcile(observe([], host: host, now: later.addingTimeInterval(1)))
        t.expectEqual(ledger.row(launchID: id)?.phase, .starting, "adopted, it is not failed by a clock that started before the crash")
        t.expect(ledger.row(launchID: id)?.isActive == true, "and it is still an active row, not a launch to repeat")
        t.expect(ledger.inFlightSessionIDs(now: later).contains(id), "it is in flight for the restore guard")

        // The agent registers a few seconds later: matched by its pane tty.
        let registered = session(pid: 77, id: nil, tty: "ttys040")
        _ = ledger.reconcile(observe([registered], host: host, now: later.addingTimeInterval(4)))
        t.expectEqual(ledger.row(launchID: id)?.phase, .live, "…and then matched by pane tty")

        // Without adoption the old clock would have failed it at once.
        var unadopted = LaunchLedger()
        unadopted.begin(freshRow(started: t0), now: t0)
        _ = unadopted.reconcile(observe([], host: host, now: later))
        t.expect({ if case .failed? = unadopted.row(launchID: id)?.phase { return true } else { return false } }(), "an unadopted stale row fails on its first look")

        // No pane, no adoption; and a plain row is never adopted.
        var gone = LaunchLedger()
        gone.begin(freshRow(), now: t0)
        t.expectEqual(gone.adopt(host: HostSnapshot(), now: later), [], "a Starting row with no pane is not adopted")
        t.expectEqual(gone.adopt(host: nil, now: later), [], "nor when the host cannot be read")
        var plainRow = LaunchLedger()
        plainRow.begin(freshRow(hosted: false), now: t0)
        t.expectEqual(plainRow.adopt(host: host, now: later), [], "a plain launch has nothing in the host to adopt")
        var live = LaunchLedger()
        live.begin(freshRow(), now: t0)
        _ = live.reconcile(observe([session(pid: 5, id: id)], now: at(2)))
        t.expectEqual(live.adopt(host: host, now: later), [], "a Live row needs no adoption: it is followed by pid")
    }

    // MARK: Ownership for the snapshot and for a click

    do {
        var ledger = LaunchLedger()
        ledger.begin(freshRow(id: pinned, hosted: true), now: t0)
        ledger.begin(freshRow(id: "44444444-4444-4444-8444-444444444444", hosted: false), now: t0)
        let hostedSession = session(pid: 31, id: pinned, tty: "ttys050")
        let plainSession = session(pid: 32, id: "44444444-4444-4444-8444-444444444444", tty: "ttys051")
        let strangerSession = session(pid: 33, id: "55555555-5555-4555-8555-555555555555", tty: "ttys052")
        let live = [hostedSession, plainSession, strangerSession]
        let attached = HostSnapshot(
            panes: [pane("ttys050", session: pinned)],
            clients: [HostClient(tty: "ttys100", pid: 1, sessionName: pinned)]
        )
        _ = ledger.reconcile(observe(live, host: attached, now: at(2)))

        let owned = ledger.ownedAttachments(live: live, host: attached)
        t.expectEqual(owned[hostedSession.key], .attached, "a hosted session with a client is attached")
        t.expectEqual(owned[plainSession.key], .attached, "a plain owned session is attached")
        t.expect(owned[strangerSession.key] == nil, "a session AgentMenu did not launch is not owned")

        let detached = HostSnapshot(panes: [pane("ttys050", session: pinned)])
        t.expectEqual(ledger.ownedAttachments(live: live, host: detached)[hostedSession.key], .detached, "hosted with no client is Detached")
        t.expectEqual(ledger.ownedAttachments(live: live, host: detached)[plainSession.key], .attached, "…and a plain session never is")

        let info = ledger.ownership(of: hostedSession, host: attached)
        t.expectEqual(info?.launchID, pinned, "a click knows the tmux session")
        t.expectEqual(info?.clientTTY, "ttys100", "…and the client tty that holds the window")
        t.expectEqual(info?.terminalID, "terminal-app", "…and the terminal it was launched in")
        t.expectEqual(info?.isDetached, false, "attached")
        t.expectEqual(ledger.ownership(of: hostedSession, host: detached)?.isDetached, true, "detached")
        t.expect(ledger.ownership(of: strangerSession, host: attached) == nil, "no ownership for a stranger")
        t.expectEqual(ledger.ownership(of: plainSession, host: attached)?.launchID, nil, "a plain row has no tmux session to attach to")

        // A hosted pane with no ledger row at all is still owned (KTD7: a
        // hosted session at any time by tty).
        let orphan = session(pid: 34, id: "66666666-6666-4666-8666-666666666666", tty: "ttys060")
        let orphanHost = HostSnapshot(panes: [pane("ttys060", session: "orphan-session")])
        t.expectEqual(LaunchLedger().ownedAttachments(live: [orphan], host: orphanHost)[orphan.key], .detached, "a process in a host pane is owned by tty even with no ledger row")
        t.expectEqual(LaunchLedger().ownership(of: orphan, host: orphanHost)?.launchID, "orphan-session", "…and knows its tmux session")
    }

    // MARK: Pending rows for the list

    do {
        var ledger = LaunchLedger()
        ledger.begin(freshRow(), now: t0)
        let pending = ledger.pendingLaunches()
        t.expectEqual(pending.first?.id, pinned, "the pending row is the launch")
        t.expectEqual(pending.first?.title, "app", "…titled by its folder")
        t.expectEqual(pending.first?.profileID, "work", "…on its account")
        t.expect(pending.first?.folderPath != nil, "…in its folder's group")
        t.expect(ledger.hasRowsAwaitingRegistration(now: at(1)), "a Starting row needs a timer")
        _ = ledger.reconcile(observe([session(pid: 3, id: pinned)], now: at(1)))
        t.expect(!ledger.hasRowsAwaitingRegistration(now: at(2)), "a Live row does not")
        t.expect(ledger.hasActiveHostedRows, "…but a hosted one still needs the host asked")
    }

    // MARK: Rows are replaced and pruned

    do {
        var ledger = LaunchLedger()
        ledger.begin(freshRow(), now: t0)
        var again = freshRow()
        again.cwd = "/projects/other"
        ledger.begin(again, now: t0)
        t.expectEqual(ledger.rows.count, 1, "a launch id appears once")
        t.expectEqual(ledger.rows.first?.cwd, "/projects/other", "the newer row replaces the older")

        var old = LaunchLedger()
        var done = freshRow()
        done.endedAt = t0
        old.begin(done, now: t0)
        old.prune(now: t0.addingTimeInterval(LaunchLedger.endedRetention + 1))
        t.expect(old.rows.isEmpty, "an ended row is kept for a month, then pruned")

        var many = LaunchLedger()
        for index in 0..<(LaunchLedger.maximumRows + 20) {
            var row = freshRow(id: String(format: "00000000-0000-4000-8000-%012d", index))
            row.endedAt = at(TimeInterval(index))
            many.begin(row, now: at(0))
        }
        many.begin(freshRow(id: "77777777-7777-4777-8777-777777777777"), now: at(1))
        t.expect(many.rows.count <= LaunchLedger.maximumRows, "the ledger is capped")
        t.expect(many.row(launchID: "77777777-7777-4777-8777-777777777777") != nil, "…and the cap never drops an active row")
    }

    // MARK: Stored form (KTD12): round trip, unknown fields kept, no `ledger` key without a launch

    do {
        let dir = TempDir("ledger-store")
        defer { dir.cleanup() }
        let url = dir.url.appendingPathComponent("sessions.json")
        let store = SessionStore(url: url)

        t.expectNoThrow("a rename alone") { try store.setRename("Invoices", for: "a") }
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            t.expect(!text.contains("ledger"), "a store that has only held renames carries no ledger key")
        }

        var row = freshRow()
        row.preset = Preset(agent: "claude-code", terminal: "terminal-app", profile: "work", model: "opus", effort: "high",
                            permissionMode: "plan", advisor: .model("sonnet"), keepRunning: true)
        t.expectNoThrow("record a launch") { try store.updateLedger { $0.begin(row, now: t0) } }
        t.expectNoThrow("and follow it") {
            try store.updateLedger { ledger in
                _ = ledger.reconcile(observe([session(pid: 91, id: pinned)], now: at(3)))
            }
        }

        let reloaded = SessionStore(url: url)
        t.expectNoThrow("a second store loads the file") { _ = try reloaded.load() }
        let back = reloaded.ledger.row(launchID: pinned)
        t.expectEqual(back?.phase, .live, "the phase round-trips")
        t.expectEqual(back?.pid, 91, "pid round-trips")
        t.expectEqual(back?.procStart, 1_800_000_000 + 91, "procStart round-trips")
        t.expectEqual(back?.lastSessionID, pinned, "the last seen id round-trips")
        t.expectEqual(back?.preset, row.preset, "the resolved preset round-trips, advisor and all")
        t.expectEqual(back?.hostSocket, "/h/s", "the host socket round-trips")
        t.expectEqual(back?.terminalID, "terminal-app", "the terminal round-trips")
        t.expectEqual(reloaded.renames["a"], "Invoices", "renames are untouched by ledger writes")

        // The cause slot, written by a later unit, survives a rewrite here.
        t.expectNoThrow("U12 and U13 write a cause") {
            try store.updateLedger { $0.update(launchID: pinned) { $0.endedAt = at(10); $0.endCause = .together } }
        }
        t.expectEqual(SessionStore(url: url).ledgerFromDisk().row(launchID: pinned)?.endCause, .together, "the cause slot round-trips")

        // An end cause this build does not know (a newer build's, or the free
        // text an earlier build allowed) is read back and written as it was.
        t.expectNoThrow("a cause this build has no case for") {
            try store.updateLedger { $0.update(launchID: pinned) { $0.endCause = EndCause(rawValue: "quit-all") } }
        }
        let foreign = SessionStore(url: url).ledgerFromDisk().row(launchID: pinned)?.endCause
        t.expectEqual(foreign, .unrecognised("quit-all"), "an unknown cause is kept, not dropped")
        t.expectEqual(foreign?.rawValue, "quit-all", "…verbatim")
        t.expectEqual(
            ["individual", "together", "host-died", "power-off", "unexplained", "exited"].map { EndCause(rawValue: $0).rawValue },
            ["individual", "together", "host-died", "power-off", "unexplained", "exited"],
            "every known cause round-trips through its raw value"
        )
        t.expect(EndCause(rawValue: "individual") == .individual && EndCause(rawValue: "together") == .together, "U12's two causes parse to their cases")

        // A field this build does not know is kept when the row is rewritten.
        if let data = try? Data(contentsOf: url),
           var object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           var ledger = object["ledger"] as? [String: Any],
           var rows = ledger["rows"] as? [[String: Any]], !rows.isEmpty {
            rows[0]["future_field"] = ["nested": [1, 2, 3], "flag": true]
            ledger["rows"] = rows
            ledger["future_key"] = "kept"
            object["ledger"] = ledger
            object["future_top_level"] = 7
            if let rewritten = try? JSONSerialization.data(withJSONObject: object) {
                try? rewritten.write(to: url)
            }
        }
        let third = SessionStore(url: url)
        t.expectNoThrow("rewrite after a newer build added fields") {
            try third.updateLedger { $0.update(launchID: pinned) { $0.lastSessionID = "88888888-8888-4888-8888-888888888888" } }
        }
        if let data = try? Data(contentsOf: url),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            t.expectEqual((object["future_top_level"] as? NSNumber)?.intValue, 7, "an unknown top-level key survives a ledger write")
            let ledger = object["ledger"] as? [String: Any]
            t.expectEqual(ledger?["future_key"] as? String, "kept", "an unknown key inside the ledger survives")
            let rows = ledger?["rows"] as? [[String: Any]]
            t.expect(rows?.first?["future_field"] != nil, "an unknown field inside a row survives")
            t.expectEqual(rows?.first?["last_session_id"] as? String, "88888888-8888-4888-8888-888888888888", "and the change is written")
        } else {
            t.expect(false, "the store is valid JSON")
        }

        // A crash mid-write: a half-written temporary file sits beside the
        // store (the write never reached its rename). The target is intact,
        // loads, and the next write succeeds and still parses.
        let crashDir = TempDir("ledger-crash")
        defer { crashDir.cleanup() }
        let crashURL = crashDir.url.appendingPathComponent("sessions.json")
        let crashStore = SessionStore(url: crashURL)
        t.expectNoThrow("record a launch before the crash") { try crashStore.updateLedger { $0.begin(freshRow(), now: t0) } }
        let intact = try? Data(contentsOf: crashURL)
        let stray = crashDir.url.appendingPathComponent(".sessions.json.\(UUID().uuidString).tmp")
        try? (intact ?? Data()).prefix(max(1, (intact?.count ?? 2) / 2)).write(to: stray)
        t.expectEqual(try? Data(contentsOf: crashURL), intact, "the target is untouched by the stray temporary file")
        let afterCrash = SessionStore(url: crashURL)
        t.expectNoThrow("a fresh store loads after the crash") { _ = try afterCrash.load() }
        t.expect(afterCrash.ledger.row(launchID: pinned) != nil, "the ledger row survived the crash")
        t.expectNoThrow("and the next write succeeds") {
            try afterCrash.updateLedger { _ = $0.reconcile(observe([session(pid: 8, id: pinned)], now: at(1))) }
        }
        if let data = try? Data(contentsOf: crashURL), (try? JSONSerialization.jsonObject(with: data)) != nil {
            t.expect(true, "the target still parses")
        } else {
            t.expect(false, "the target still parses after the next write")
        }
        t.expectEqual(SessionStore(url: crashURL).ledgerFromDisk().row(launchID: pinned)?.phase, .live, "…with the new state")

        // A row this build cannot read is skipped, not fatal.
        try? Data("""
        {"schema": 1, "ledger": {"rows": [{"nonsense": true}, 5]}}
        """.utf8).write(to: url)
        let lenient = SessionStore(url: url)
        t.expectNoThrow("an unreadable row does not fail the load") { _ = try lenient.load() }
        t.expect(lenient.ledger.isEmpty, "…and is skipped")

        // A ledger that is not shaped like one is refused like any other corruption.
        try? Data(#"{"schema": 1, "ledger": []}"#.utf8).write(to: url)
        t.expectThrows("a ledger that is not an object is refused") { try SessionStore(url: url).load() }
    }

    // MARK: Classification bookkeeping (U13)

    do {
        func live(_ id: String, pid: Int32, cause: EndCause? = nil) -> LedgerRow {
            var row = freshRow(id: id)
            row.phase = .live
            row.pid = pid
            row.procStart = 1_800_000_000 + Int(pid)
            row.lastSessionID = id
            row.endCause = cause
            return row
        }
        let other = "6a6a6a6a-1111-4111-8111-111111111111"
        var ledger = LaunchLedger(rows: [live(pinned, pid: 10), live(other, pid: 11, cause: .individual)])

        t.expect(!ledger.hasRowsAwaitingClassification, "a live row is not waiting to be classified")
        let recorded = ledger.recordCauseForUnexplainedLiveRows(.powerOff, at: at(7))
        t.expectEqual(ledger.row(launchID: pinned)?.causeRecordedAt, at(7), "and says when")
        t.expectEqual(recorded, [pinned], "the power-off cause goes to the live rows that carry none")
        t.expectEqual(ledger.row(launchID: other)?.endCause, .individual, "a quit in progress keeps its cause")
        t.expectEqual(ledger.row(launchID: pinned)?.endCause, .powerOff, "and the other records it")

        t.expectEqual(ledger.clearCauseOnLiveRows(.powerOff), [pinned], "a logout that did not happen is taken back")
        t.expectEqual(ledger.row(launchID: pinned)?.endCause, nil, "from the row that had it")
        t.expectEqual(ledger.row(launchID: pinned)?.causeRecordedAt, nil, "with its time")
        t.expectEqual(ledger.row(launchID: other)?.endCause, .individual, "and only that")

        ledger.update(launchID: pinned) { $0.endedAt = at(5) }
        t.expect(ledger.row(launchID: pinned)?.awaitsClassification == true, "an ended row waits to be classified")
        t.expect(ledger.hasRowsAwaitingClassification, "and the ledger says so")
        ledger.markClassified(launchID: pinned, cause: .unexplained)
        t.expectEqual(ledger.row(launchID: pinned)?.endCause, .unexplained, "a row with no cause records the classification")
        t.expect(ledger.row(launchID: pinned)?.classified == true, "and is marked")
        t.expect(!ledger.hasRowsAwaitingClassification, "so nothing waits")
        ledger.update(launchID: other) { $0.endedAt = at(6) }
        ledger.markClassified(launchID: other, cause: .exited)
        t.expectEqual(ledger.row(launchID: other)?.endCause, .individual, "a recorded cause is never overwritten by the classification")
    }

}

private extension SessionStore {
    /// A fresh read of the file, for what a second process would see.
    func ledgerFromDisk() -> LaunchLedger {
        _ = try? load()
        return ledger
    }
}
