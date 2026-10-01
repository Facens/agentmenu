// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

// The restore guard (KTD13, R27) in its registry-only form: a pure function
// over the live rows of every profile. Rows are built by hand; the reader
// already drops a dead pid, so "a dead pid's registry file" is a live list
// that simply lacks the session.

private let sessionA = "0b6f3a52-7c1e-4d0a-9a43-5f1e2c7d8b90"
private let sessionB = "5d2c9e14-31aa-4b7e-8c60-9a1f3b2d4e77"

private func row(
    _ session: String?, profile: String = "personal", config: String = "/profiles/personal", pid: Int32
) -> LiveSession {
    LiveSession(
        key: LiveSessionKey(configDirectory: config, pid: pid, procStart: 1_790_000_000 + Int(pid)),
        agentID: RegistryReader.claudeAgentID,
        agentDisplayName: "Claude Code",
        profileID: profile,
        configDirectory: URL(fileURLWithPath: config),
        pid: pid,
        sessionId: session,
        status: .yourTurn,
        startedAt: Date(timeIntervalSince1970: 1_790_000_000)
    )
}

func runRestoreGuardTests(_ t: TestRunner) {
    t.suite("RestoreGuard")

    // MARK: AE3 — a live registry row holds the session: refuse, focus that row

    do {
        let live = row(sessionA, pid: 4101)
        let other = row(sessionB, pid: 4102)
        let decision = RestoreGuard.check(
            sessionID: sessionA, snapshot: RestoreGuardSnapshot(liveSessions: [other, live])
        )
        t.expectEqual(
            decision, .refuse(.alreadyLive(focus: [live.key])),
            "AE3: a session held by a live registry row is refused, and that row is the one to focus"
        )
        t.expectEqual(decision.focusKeys, [live.key], "focusKeys names the row")
        t.expect(!decision.isAllowed, "a refusal is not an allow")
    }

    // MARK: A dead pid's registry file never reaches the live list

    do {
        let snapshot = RestoreGuardSnapshot(liveSessions: [row(sessionB, pid: 4102)])
        t.expectEqual(
            RestoreGuard.check(sessionID: sessionA, snapshot: snapshot), .allow,
            "AE3: a session whose only registry file belonged to a dead pid is not live, so it may resume"
        )
        t.expectEqual(
            RestoreGuard.check(sessionID: sessionA, snapshot: RestoreGuardSnapshot()), .allow,
            "an empty snapshot allows a valid id"
        )
        t.expect(RestoreGuard.check(sessionID: sessionA, snapshot: snapshot).focusKeys.isEmpty, "an allow names nothing to focus")
    }

    // MARK: Live under another profile still refuses

    do {
        let work = row(sessionA, profile: "work", config: "/profiles/work", pid: 4201)
        let personal = row(sessionB, profile: "personal", config: "/profiles/personal", pid: 4202)
        let decision = RestoreGuard.check(
            sessionID: sessionA, snapshot: RestoreGuardSnapshot(liveSessions: [personal, work])
        )
        t.expectEqual(
            decision, .refuse(.alreadyLive(focus: [work.key])),
            "a session live under the Work account blocks a resume asked from anywhere else"
        )
    }

    // MARK: Two live rows share one id — both keys, in snapshot order

    do {
        let first = row(sessionA, profile: "work", config: "/profiles/work", pid: 4301)
        let second = row(sessionA, profile: "personal", config: "/profiles/personal", pid: 4302)
        let decision = RestoreGuard.check(
            sessionID: sessionA, snapshot: RestoreGuardSnapshot(liveSessions: [first, second])
        )
        t.expectEqual(
            decision, .refuse(.alreadyLive(focus: [first.key, second.key])),
            "two rows with one id (a forked or resumed session) are both returned, in snapshot order"
        )
        let duplicated = RestoreGuard.check(
            sessionID: sessionA, snapshot: RestoreGuardSnapshot(liveSessions: [first, first])
        )
        t.expectEqual(duplicated.focusKeys, [first.key], "one row listed twice is one key")
    }

    // MARK: Empty and malformed ids refuse, and match nothing

    do {
        // A row with no id (a scanned agent) must not make "" look live.
        let snapshot = RestoreGuardSnapshot(liveSessions: [row(nil, pid: 4401), row("", pid: 4402)])
        for bad in [
            "", " ", sessionA.uppercased(), " " + sessionA, sessionA + "\n", String(sessionA.dropLast()),
            "--resume", "../" + sessionA, sessionA.replacingOccurrences(of: "-", with: ""),
            "0b6f3a52-7c1e-4d0a-9a43-5f1e2c7d8b9g",
        ] {
            t.expectEqual(
                RestoreGuard.check(sessionID: bad, snapshot: snapshot), .refuse(.invalidSessionID),
                "\(bad.debugDescription) is not a session id, so it is refused"
            )
        }
    }

    // MARK: Ids compare exactly

    do {
        let near = sessionA.replacingOccurrences(of: "0b6f", with: "0b6e")
        let snapshot = RestoreGuardSnapshot(liveSessions: [row(near, pid: 4501)])
        t.expectEqual(
            RestoreGuard.check(sessionID: sessionA, snapshot: snapshot), .allow,
            "an id that differs by one character is another session"
        )
    }

    // MARK: SessionIdentifier

    do {
        t.expect(SessionIdentifier.isValid(sessionA), "the canonical lowercase UUID is valid")
        t.expect(!SessionIdentifier.isValid(""), "empty is not")
        t.expect(!SessionIdentifier.isValid(sessionA.uppercased()), "uppercase is not the form Claude Code writes")
        t.expect(!SessionIdentifier.isValid("é" + sessionA.dropFirst()), "non-ASCII is not valid")
    }

    // MARK: R27 — live rows the display filter drops, and launches not yet registered

    do {
        let hidden = RestoreGuardSnapshot(otherLiveSessionIDs: [sessionA])
        t.expectEqual(
            RestoreGuard.check(sessionID: sessionA, snapshot: hidden), .refuse(.runningElsewhere),
            "a session live under an IDE, desktop or parked row is refused though no listed row holds it"
        )
        t.expectEqual(RestoreGuard.check(sessionID: sessionA, snapshot: hidden).focusKeys, [], "there is nothing to focus")
        t.expectEqual(RestoreGuard.check(sessionID: sessionB, snapshot: hidden), .allow, "another session is unaffected")

        let flying = RestoreGuardSnapshot(inFlight: [sessionA])
        t.expectEqual(
            RestoreGuard.check(sessionID: sessionA, snapshot: flying), .refuse(.launchInFlight),
            "an id present only in flight is refused"
        )

        let live = row(sessionA, pid: 4601)
        t.expectEqual(
            RestoreGuard.check(
                sessionID: sessionA,
                snapshot: RestoreGuardSnapshot(liveSessions: [live], otherLiveSessionIDs: [sessionA], inFlight: [sessionA])
            ),
            .refuse(.alreadyLive(focus: [live.key])),
            "a listed row wins: it can be focused"
        )
    }

    // MARK: The in-flight helper, on an injected clock

    do {
        let start = Date(timeIntervalSince1970: 1_790_000_000)
        var flight = InFlightResumes()
        t.expect(flight.isEmpty, "nothing in flight to begin with")
        flight.begin(sessionA, now: start)
        t.expectEqual(flight.ids(now: start), [sessionA], "a launch just typed is in flight")
        t.expectEqual(flight.ids(now: start.addingTimeInterval(29)), [sessionA], "still in flight just before the expiry")
        t.expectEqual(flight.ids(now: start.addingTimeInterval(InFlightResumes.expiry)), [], "gone at the expiry, even unpruned")
        t.expectEqual(InFlightResumes.expiry, 30, "the expiry is 30 seconds")

        flight.prune(live: [sessionB], now: start.addingTimeInterval(5))
        t.expectEqual(flight.ids(now: start.addingTimeInterval(5)), [sessionA], "another session going live changes nothing")
        flight.prune(live: [sessionA], now: start.addingTimeInterval(5))
        t.expect(flight.isEmpty, "an id that appears in the live set is no longer in flight")

        flight.begin(sessionA, now: start)
        flight.prune(live: [], now: start.addingTimeInterval(31))
        t.expect(flight.isEmpty, "pruning drops an expired launch")
        flight.begin(sessionA, now: start)
        t.expectEqual(flight.ids(now: start.addingTimeInterval(-10)), [sessionA], "a clock that stepped back leaves it in flight")
    }

    // MARK: U13 — the ledger and the session host's panes

    let guardNow = Date(timeIntervalSince1970: 1_790_000_100)
    let launchA = "11111111-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

    /// A live owned row: the ledger follows the registry row by its key.
    func ownedLive(_ session: String?, pid: Int32, tty: String?) -> (LiveSession, LedgerRow) {
        let live = LiveSession(
            key: LiveSessionKey(configDirectory: "/profiles/personal", pid: pid, procStart: 1_790_000_000 + Int(pid)),
            agentID: RegistryReader.claudeAgentID, agentDisplayName: "Claude Code", profileID: "personal",
            pid: pid, sessionId: session, status: .yourTurn, tty: tty, startedAt: Date(timeIntervalSince1970: 1_790_000_000)
        )
        let row = LedgerRow(
            launchID: launchA, profileID: "personal", configDirectory: "/profiles/personal", cwd: "/p",
            terminalID: "terminal-app", hostSocket: "/h/s", startedAt: Date(timeIntervalSince1970: 1_789_999_000),
            phase: .live, pid: pid, procStart: live.key.procStart, lastSessionID: session
        )
        return (live, row)
    }

    func hostWith(attached: Bool, tty: String = "ttys010", dead: Bool = false) -> HostSnapshot {
        HostSnapshot(
            panes: [HostPane(tty: tty, pid: 500, isDead: dead, sessionName: launchA)],
            clients: attached ? [HostClient(tty: "ttys020", pid: 600, sessionName: launchA)] : []
        )
    }

    // AE2: an owned session that is running with no window is reattached.
    do {
        let (live, row) = ownedLive(sessionA, pid: 4701, tty: "ttys010")
        let detached = RestoreGuardSnapshot(
            liveSessions: [live], ledger: LaunchLedger(rows: [row]), host: hostWith(attached: false), now: guardNow
        )
        t.expectEqual(
            RestoreGuard.check(sessionID: sessionA, snapshot: detached), .refuse(.reattach(launchID: launchA)),
            "AE2: a session held by a live registry row and detached is reattached, not resumed a second time"
        )
        t.expectEqual(RestoreGuard.check(sessionID: sessionA, snapshot: detached).focusKeys, [], "there is no window to focus")
        t.expect(!RestoreGuard.check(sessionID: sessionA, snapshot: detached).isAllowed, "and it is not allowed")

        let attached = RestoreGuardSnapshot(
            liveSessions: [live], ledger: LaunchLedger(rows: [row]), host: hostWith(attached: true), now: guardNow
        )
        t.expectEqual(
            RestoreGuard.check(sessionID: sessionA, snapshot: attached), .refuse(.alreadyLive(focus: [live.key])),
            "AE2: with a window attached the live row is focused"
        )

        let unknown = RestoreGuardSnapshot(liveSessions: [live], ledger: LaunchLedger(rows: [row]), host: nil, now: guardNow)
        t.expectEqual(
            RestoreGuard.check(sessionID: sessionA, snapshot: unknown), .refuse(.alreadyLive(focus: [live.key])),
            "without a host snapshot there is no telling it is detached: the row is focused"
        )

        let plain = RestoreGuardSnapshot(
            liveSessions: [live], ledger: LaunchLedger(), host: hostWith(attached: false, tty: "ttys099"), now: guardNow
        )
        t.expectEqual(
            RestoreGuard.check(sessionID: sessionA, snapshot: plain), .refuse(.alreadyLive(focus: [live.key])),
            "a session AgentMenu does not own is only ever focused"
        )

        let byPane = RestoreGuardSnapshot(liveSessions: [live], ledger: LaunchLedger(), host: hostWith(attached: false), now: guardNow)
        t.expectEqual(
            RestoreGuard.check(sessionID: sessionA, snapshot: byPane), .refuse(.reattach(launchID: launchA)),
            "a session in a host pane is owned by that alone (KTD7), even with no ledger row left"
        )
    }

    // A launch the ledger still waits on is in flight.
    do {
        let fresh = LedgerRow(
            launchID: sessionA, profileID: "personal", cwd: "/p", terminalID: "terminal-app", hostSocket: "/h/s",
            startedAt: guardNow.addingTimeInterval(-5)
        )
        let starting = RestoreGuardSnapshot(ledger: LaunchLedger(rows: [fresh]), now: guardNow)
        t.expectEqual(
            RestoreGuard.check(sessionID: sessionA, snapshot: starting), .refuse(.launchInFlight),
            "a session id held by an in-flight ledger row is refused"
        )
        t.expectEqual(RestoreGuard.check(sessionID: sessionB, snapshot: starting), .allow, "another session is unaffected")

        var restoring = LedgerRow(
            launchID: launchA, kind: .restore(resumedSessionID: sessionB), cwd: "/p", terminalID: "terminal-app",
            hostSocket: "/h/s", startedAt: guardNow.addingTimeInterval(-5)
        )
        t.expectEqual(
            RestoreGuard.check(sessionID: sessionB, snapshot: RestoreGuardSnapshot(ledger: LaunchLedger(rows: [restoring]), now: guardNow)),
            .refuse(.launchInFlight),
            "so is the id a restore is resuming"
        )
        restoring.phase = .failed(reason: "slow")
        t.expectEqual(
            RestoreGuard.check(sessionID: sessionB, snapshot: RestoreGuardSnapshot(ledger: LaunchLedger(rows: [restoring]), now: guardNow)),
            .refuse(.launchInFlight),
            "a failed launch inside the late-match window may still come up"
        )
        t.expectEqual(
            RestoreGuard.check(
                sessionID: sessionB,
                snapshot: RestoreGuardSnapshot(ledger: LaunchLedger(rows: [restoring]), now: guardNow.addingTimeInterval(LaunchLedger.lateMatchWindow + 1))
            ),
            .allow,
            "and past it, no longer"
        )
    }

    // A live pane holds a session whatever the registry shows.
    do {
        let (_, row) = ownedLive(sessionA, pid: 4801, tty: "ttys010")
        let ledger = LaunchLedger(rows: [row])

        t.expectEqual(
            RestoreGuard.check(sessionID: sessionA, snapshot: RestoreGuardSnapshot(ledger: ledger, host: hostWith(attached: false), now: guardNow)),
            .refuse(.reattach(launchID: launchA)),
            "a session whose pane is live and detached is reattached though no registry row lists it"
        )
        t.expectEqual(
            RestoreGuard.check(sessionID: sessionA, snapshot: RestoreGuardSnapshot(ledger: ledger, host: hostWith(attached: true), now: guardNow)),
            .refuse(.runningElsewhere),
            "with a window attached and no row to focus it is refused, and nothing is started"
        )
        t.expectEqual(
            RestoreGuard.check(sessionID: sessionA, snapshot: RestoreGuardSnapshot(ledger: ledger, host: hostWith(attached: false, dead: true), now: guardNow)),
            .allow,
            "a dead pane holds nothing"
        )
        t.expectEqual(
            RestoreGuard.check(sessionID: sessionA, snapshot: RestoreGuardSnapshot(ledger: ledger, host: HostSnapshot(), now: guardNow)),
            .allow,
            "a host with no pane for it holds nothing"
        )
        t.expectEqual(
            RestoreGuard.check(sessionID: sessionA, snapshot: RestoreGuardSnapshot(ledger: ledger, host: nil, now: guardNow)),
            .refuse(.runningElsewhere),
            "with no host information the ledger's own word stands: its process has not been seen to end"
        )

        var over = row
        over.endedAt = guardNow
        t.expectEqual(
            RestoreGuard.check(sessionID: sessionA, snapshot: RestoreGuardSnapshot(ledger: LaunchLedger(rows: [over]), host: hostWith(attached: false), now: guardNow)),
            .allow,
            "an ended ledger row holds nothing"
        )

        // /clear changed the id in place: the old one is a closed conversation.
        var cleared = row
        cleared.launchID = launchA
        cleared.lastSessionID = sessionB
        let clearedSnapshot = RestoreGuardSnapshot(ledger: LaunchLedger(rows: [cleared]), host: hostWith(attached: false), now: guardNow)
        t.expectEqual(RestoreGuard.check(sessionID: sessionB, snapshot: clearedSnapshot), .refuse(.reattach(launchID: launchA)), "the id the agent holds now is refused")
        t.expectEqual(RestoreGuard.check(sessionID: sessionA, snapshot: clearedSnapshot), .allow, "the one /clear replaced is not")
    }

    // A plain launch has no pane: the ledger row alone says it is running when
    // its registry file is gone (removed under a live process).
    do {
        let (_, hosted) = ownedLive(sessionA, pid: 4951, tty: nil)
        var plain = hosted
        plain.hostSocket = nil
        let snapshot = RestoreGuardSnapshot(ledger: LaunchLedger(rows: [plain]), host: HostSnapshot(), now: guardNow)
        t.expectEqual(
            RestoreGuard.check(sessionID: sessionA, snapshot: snapshot), .refuse(.runningElsewhere),
            "a plain owned row still live in the ledger holds its session though no registry file lists it"
        )
        t.expectEqual(
            RestoreGuard.check(sessionID: sessionA, snapshot: RestoreGuardSnapshot(ledger: LaunchLedger(rows: [plain]), now: guardNow)),
            .refuse(.runningElsewhere),
            "…with no host information too"
        )
        t.expectEqual(RestoreGuard.check(sessionID: sessionB, snapshot: snapshot), .allow, "another session is not held by it")

        var cleared = plain
        cleared.lastSessionID = sessionB
        t.expectEqual(
            RestoreGuard.check(sessionID: sessionA, snapshot: RestoreGuardSnapshot(ledger: LaunchLedger(rows: [cleared]), now: guardNow)),
            .allow,
            "the id /clear replaced is a closed conversation"
        )
        t.expectEqual(
            RestoreGuard.check(sessionID: sessionB, snapshot: RestoreGuardSnapshot(ledger: LaunchLedger(rows: [cleared]), now: guardNow)),
            .refuse(.runningElsewhere),
            "…and the one it holds now is held"
        )

        var over = plain
        over.endedAt = guardNow
        t.expectEqual(
            RestoreGuard.check(sessionID: sessionA, snapshot: RestoreGuardSnapshot(ledger: LaunchLedger(rows: [over]), now: guardNow)),
            .allow,
            "a plain row that ended holds nothing"
        )
        var starting = plain
        starting.phase = .starting
        starting.pid = nil
        starting.procStart = nil
        starting.lastSessionID = nil
        t.expectEqual(
            RestoreGuard.check(sessionID: launchA, snapshot: RestoreGuardSnapshot(ledger: LaunchLedger(rows: [starting]), now: guardNow)),
            .refuse(.launchInFlight),
            "a launch still starting stays an in-flight launch, not a running one"
        )
    }

    // A stale registry file is a dead pid: it never reaches the live list, and
    // a dead launch leaves nothing behind.
    do {
        let (_, row) = ownedLive(sessionA, pid: 4901, tty: "ttys010")
        var gone = row
        gone.endedAt = guardNow.addingTimeInterval(-60)
        let snapshot = RestoreGuardSnapshot(
            liveSessions: [], otherLiveSessionIDs: [], ledger: LaunchLedger(rows: [gone]), host: HostSnapshot(), now: guardNow
        )
        t.expectEqual(
            RestoreGuard.check(sessionID: sessionA, snapshot: snapshot), .allow,
            "a session id whose only registry file is stale (a dead pid) is allowed"
        )
    }
}
