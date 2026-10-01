// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

// Quit and Quit all (U12, R19 to R21): which sessions each one takes, whether it
// asks first, and what the question says. Pure.

private func key(_ pid: Int32, _ directory: String = "/profiles/work") -> LiveSessionKey {
    LiveSessionKey(configDirectory: directory, pid: pid, procStart: 1_800_000_000 + Int(pid))
}

private func candidate(
    _ pid: Int32,
    _ name: String = "session",
    status: SessionStatus = .yourTurn,
    owned: Bool = true,
    account: String? = "Work"
) -> QuitCandidate {
    QuitCandidate(key: key(pid), name: name, status: status, isOwned: owned, accountName: account)
}

func runQuitPolicyTests(_ t: TestRunner) {
    t.suite("QuitPolicy")

    // MARK: Covers AE7: confirm only when something is Working (R21)

    do {
        let idle = [candidate(1, status: .yourTurn), candidate(2, status: .needsYou), candidate(3, status: .unknown)]
        let plan = QuitPolicy.planQuitAll(live: idle)
        t.expect(plan.confirmation == nil, "every owned session at Your turn, Needs you or Running: Quit all acts at once")
        t.expectEqual(plan.targets.count, 3, "…and takes all three")

        let one = candidate(4, "Invoices", status: .working)
        let withWorking = QuitPolicy.planQuitAll(live: idle + [one])
        t.expect(withWorking.confirmation != nil, "one Working session: Quit all asks first")
        t.expectEqual(withWorking.confirmation?.workingCount, 1, "…and counts it")
        t.expect(withWorking.confirmation?.message.contains("Invoices") == true, "…and names it")
        t.expect(withWorking.confirmation?.message.localizedCaseInsensitiveContains("loses") == true, "…and says the turn in flight is lost")
        t.expectEqual(withWorking.confirmation?.confirmTitle, "Quit all", "the button says what it does")
        t.expectEqual(withWorking.confirmation?.cancelTitle, "Cancel", "and there is a way out")

        let many = QuitPolicy.planQuitAll(live: (1...5).map { candidate(Int32($0), "run \($0)", status: .working) })
        t.expectEqual(many.confirmation?.workingCount, 5, "five Working sessions are counted")
        t.expect(many.confirmation?.message.contains("and 2 more") == true, "…and only the first three are named")

        // An unowned Working session is not affected by Quit all, so it asks nothing.
        let unownedWorking = QuitPolicy.planQuitAll(live: [candidate(1, status: .yourTurn), candidate(2, status: .working, owned: false)])
        t.expect(unownedWorking.confirmation == nil, "a Working session Quit all does not touch asks nothing")
    }

    // The row menu's Quit asks only when that session is Working.
    do {
        t.expect(QuitPolicy.planQuit(candidate(1, status: .yourTurn)).confirmation == nil, "Quit on a Your-turn row acts at once")
        t.expect(QuitPolicy.planQuit(candidate(1, status: .needsYou)).confirmation == nil, "Quit on a Needs-you row acts at once")
        let working = QuitPolicy.planQuit(candidate(1, "Release notes", status: .working))
        t.expect(working.confirmation?.title.contains("Release notes") == true, "Quit on a Working row asks, naming it")
        t.expect(working.confirmation?.message.localizedCaseInsensitiveContains("loses") == true, "…and says what is lost")
        t.expectEqual(working.confirmation?.confirmTitle, "Quit", "the button says Quit")
        t.expect(QuitPolicy.planQuit(candidate(1, status: .working, owned: false)).confirmation != nil, "an unowned Working row asks too (R21)")
    }

    // MARK: Covers AE5: Quit all takes owned sessions only (R20)

    do {
        let live = [
            candidate(1, "owned, hosted"),
            candidate(2, "script run", owned: false),
            candidate(3, "owned, keep-running off", status: .working),
            candidate(4, "other agent", owned: false, account: nil),
        ]
        let plan = QuitPolicy.planQuitAll(live: live)
        t.expectEqual(plan.targets.map(\.key.pid), [1, 3], "Quit all takes the owned rows, hosted or not, and leaves unowned ones")
        t.expectEqual(QuitPolicy.quitAllCount(live: live), 2, "the header count is the same two")
        t.expectEqual(plan.cause, .together, "Quit all records `together`")
        t.expectEqual(QuitPolicy.planQuit(candidate(1)).cause, .individual, "Quit on a row records `individual`")

        let none = QuitPolicy.planQuitAll(live: [candidate(2, owned: false)])
        t.expect(none.isEmpty && none.confirmation == nil, "with no owned session there is nothing to quit and nothing to ask")

        let twice = QuitPolicy.planQuitAll(live: [candidate(1), candidate(1)])
        t.expectEqual(twice.targets.count, 1, "a session listed twice is quit once")
    }

    // AE5 end to end: ownership comes from the ledger (what the app's tracker
    // reads), not from a label on the candidate.
    do {
        func ledgerRow(_ id: String, pid: Int32, hosted: Bool) -> LedgerRow {
            LedgerRow(
                launchID: id,
                profileID: "work",
                configDirectory: "/profiles/work",
                cwd: "/projects/app",
                preset: Preset(keepRunning: hosted),
                terminalID: "terminal-app",
                hostSocket: hosted ? "/h/s" : nil,
                startedAt: Date(timeIntervalSince1970: 1_800_000_000),
                phase: .live,
                pid: pid,
                procStart: 1_800_000_000 + Int(pid)
            )
        }
        func session(_ pid: Int32) -> LiveSession {
            LiveSession(
                key: key(pid), agentID: RegistryReader.claudeAgentID, agentDisplayName: "Claude Code",
                pid: pid, status: .yourTurn, startedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        }
        var ledger = LaunchLedger()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        ledger.begin(ledgerRow("aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa", pid: 1, hosted: true), now: now)
        ledger.begin(ledgerRow("bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb", pid: 2, hosted: false), now: now)
        let live = [session(1), session(2), session(3)]
        let owned = ledger.ownedAttachments(live: live, host: nil)
        let candidates = live.map { QuitCandidate(key: $0.key, name: "s", status: $0.status, isOwned: owned[$0.key] != nil) }
        t.expectEqual(
            QuitPolicy.planQuitAll(live: candidates).targets.map(\.key.pid), [1, 2],
            "a hosted and a plain (keep-running off) owned launch are both taken; a session with no ledger row is not"
        )
    }

    // MARK: The confirmation names the count per account

    do {
        let live = [
            candidate(1, status: .working, account: "Work"),
            candidate(2, account: "Work"),
            candidate(3, account: "Personal"),
        ]
        let message = QuitPolicy.planQuitAll(live: live).confirmation?.message ?? ""
        t.expect(message.contains("Work 2") && message.contains("Personal 1"), "Quit all names the count per account: \(message)")
        t.expect(message.contains("3 sessions"), "…and the total")
        t.expect(message.localizedCaseInsensitiveContains("did not start"), "…and that sessions AgentMenu did not start keep running")

        let oneAccount = QuitPolicy.planQuitAll(live: [candidate(1, status: .working, account: "Work"), candidate(2, account: "Work")]).confirmation?.message ?? ""
        t.expect(oneAccount.contains("in Work"), "one account is named once: \(oneAccount)")
        let title = QuitPolicy.planQuitAll(live: live).confirmation?.title
        t.expectEqual(title, "Quit all (3)?", "the title carries the count")

        let single = QuitPolicy.planQuitAll(live: [candidate(1, "Only one", status: .working)]).confirmation
        t.expect(single?.message.contains("1 session ") == true, "one session is not pluralised")
    }

    // MARK: The header item follows the count

    do {
        let live = [candidate(1), candidate(2, owned: false)]
        let items = SessionsHeaderMenu.items(
            quitAllCount: QuitPolicy.quitAllCount(live: live), reopenAllCount: 0, reopenLastClosedCount: 0
        )
        t.expect(items[0].isEnabled && items[0].title == "Quit all (1)", "Quit all is enabled with its count of owned sessions")
    }
}
