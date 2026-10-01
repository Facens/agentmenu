// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

// The decisions behind the Sessions tab that are not drawing (U5): what the
// popover opens on, when the sweep runs, the menu-bar badge, the wording of a
// row, the header menu, the flattened list and its height math, and what a new
// live list means for the journal. The views themselves are manual-only.

private let base = Date(timeIntervalSince1970: 1_790_753_423)

private var nextPid: Int32 = 2000

private func live(
    status: SessionStatus = .yourTurn,
    profile: String = "work",
    cwd: String? = "/work/hub",
    pid: Int32? = nil,
    agent: String = "claude-code"
) -> LiveSession {
    let pid = pid ?? { nextPid += 1; return nextPid }()
    let directory = URL(fileURLWithPath: "/tmp/agentmenu-presentation-\(profile)")
    let isClaude = agent == "claude-code"
    return LiveSession(
        key: LiveSessionKey(configDirectory: isClaude ? directory.path : nil, pid: pid, procStart: 1_790_753_000),
        agentID: agent,
        agentDisplayName: isClaude ? "Claude Code" : "Codex",
        profileID: isClaude ? profile : nil,
        profileName: isClaude ? profile.capitalized : nil,
        configDirectory: isClaude ? directory : nil,
        pid: pid,
        sessionId: isClaude ? "session-\(pid)-abcdefgh" : nil,
        cwd: cwd,
        kind: isClaude ? "interactive" : nil,
        entrypoint: isClaude ? "cli" : nil,
        status: status,
        startedAt: base
    )
}

private func profiles(_ ids: [String]) -> [RegistryProfile] {
    ids.map {
        RegistryProfile(id: $0, name: $0.capitalized, directory: URL(fileURLWithPath: "/tmp/agentmenu-presentation-\($0)"))
    }
}

private func snapshot(
    _ sessions: [LiveSession],
    profileIDs: [String] = ["work", "personal"],
    folders: [FolderTarget] = [],
    pill: AccountPill = .all
) -> SessionSnapshot {
    SessionSnapshot.build(live: sessions, profiles: profiles(profileIDs), folders: folders, pill: pill)
}

private func pending(
    _ id: String,
    folder: String?,
    profile: String? = "work",
    phase: PendingLaunch.Phase = .starting
) -> PendingLaunch {
    PendingLaunch(id: id, title: id, folderPath: folder, profileID: profile, phase: phase)
}

private func headers(_ items: [SessionsListItem]) -> [String] {
    items.compactMap {
        if case .groupHeader(_, let title, _, _) = $0 { return title }
        return nil
    }
}

func runSessionsPresentationTests(_ t: TestRunner) {
    t.suite("Sessions presentation")

    // MARK: 1. The popover opens on Launch, and the Sessions tab on Live / All (KTD16, R6).

    t.expectEqual(PopoverTab.onOpen, .launch, "the popover always opens on Launch")
    t.expectEqual(SessionsViewState.onOpen, SessionsViewState(mode: .live, pill: .all, search: ""), "an open shows Live, under All, with no search")
    var state = SessionsViewState(mode: .closed, pill: .profile("personal"), search: "invoices")
    state.reopen()
    t.expectEqual(state, .onOpen, "reopening puts the mode, the pill and the search back")

    t.expect(AccountPill.all.includes(profileID: nil), "All includes an agent with no profile")
    t.expect(AccountPill.all.includes(profileID: "work"), "All includes every profile")
    t.expect(AccountPill.profile("work").includes(profileID: "work"), "a profile pill includes its own profile")
    t.expect(!AccountPill.profile("work").includes(profileID: "personal"), "a profile pill leaves the others out")
    t.expect(!AccountPill.profile("work").includes(profileID: nil), "a profile pill leaves out an agent with no profile")

    // MARK: 2. The sweep runs only while a session is listed (KTD9).

    t.expectEqual(SweepPolicy.interval, 2, "the sweep is every 2 seconds")
    t.expect(!SweepPolicy.isActive(listedSessions: 0), "no sweep with nothing listed")
    t.expect(SweepPolicy.isActive(listedSessions: 1), "a sweep once one session is listed")
    t.expect(SweepPolicy.isActive(listedSessions: 15), "…and for many")

    // MARK: 3. The badge counts Needs-you across every account (R7).

    do {
        let sessions = [
            live(status: .needsYou, profile: "work"),
            live(status: .needsYou, profile: "personal"),
            live(status: .working, profile: "work"),
            live(status: .yourTurn, profile: "personal"),
            live(status: .unknown, profile: "work"),
            live(status: .unknown, agent: "codex"),
        ]
        t.expectEqual(SessionBadge.count(live: sessions), 2, "the badge counts Needs you and nothing else, across accounts")
        t.expectEqual(
            SessionBadge.count(live: sessions), snapshot(sessions).badgeCount,
            "the light count equals the snapshot's badge count"
        )
        t.expectEqual(
            SessionBadge.count(live: sessions), snapshot(sessions, pill: .profile("work")).badgeCount,
            "…whichever pill is selected"
        )
        t.expectEqual(SessionBadge.count(live: sessions + sessions), 2, "a row listed twice counts once")
        t.expectEqual(SessionBadge.count(live: []), 0, "nothing listed, nothing to count")
    }
    t.expect(SessionBadge.text(count: 0) == nil, "no text at zero, so the title is unchanged")
    t.expect(SessionBadge.text(count: -1) == nil, "no text below zero")
    t.expectEqual(SessionBadge.text(count: 3), "3", "the number as is")
    t.expectEqual(SessionBadge.text(count: 99), "99", "99 is shown in full")
    t.expectEqual(SessionBadge.text(count: 100), "99+", "past 99 it is capped")
    t.expect(SessionBadge.tooltip(count: 0) == nil, "no tooltip at zero")
    t.expectEqual(SessionBadge.tooltip(count: 1), "1 session needs you", "singular")
    t.expectEqual(SessionBadge.tooltip(count: 4), "4 sessions need you", "plural")

    // MARK: 4. Status wording: a label and a symbol for every status, none shared (R9).

    t.expectEqual(SessionStatus.allCases.count, 4, "four statuses; adding one has to come here")
    t.expectEqual(Set(SessionStatus.allCases.map(\.label)).count, 4, "every status has its own label")
    t.expectEqual(Set(SessionStatus.allCases.map(\.symbolName)).count, 4, "every status has its own symbol, so colour is never the only cue")
    t.expectEqual(SessionStatus.needsYou.label, "Needs you", "Needs you reads as it is named")
    t.expectEqual(SessionStatus.unknown.label, "Running", "no signal is shown as running, never guessed (R11)")
    t.expectEqual(SessionRowWording.statusText(for: live(status: .working)), "Working", "a Claude Code row shows its status")
    t.expectEqual(
        SessionRowWording.statusText(for: live(status: .unknown, agent: "codex")), "Running",
        "another agent only says it is alive (R2)"
    )
    t.expectEqual(SessionRowWording.folderName("/work/hub"), "hub", "a row names its folder by the last component")
    t.expect(SessionRowWording.folderName(nil) == nil, "no folder, no name")
    t.expect(SessionRowWording.folderName("") == nil, "an empty folder, no name")

    // MARK: 5. The header menu: three items, counts in the title, a reason when empty.

    do {
        let empty = SessionsHeaderMenu.items(quitAllCount: 0, reopenAllCount: 0, reopenLastClosedCount: 0)
        t.expectEqual(empty.map(\.kind), [.quitAll, .reopenAll, .reopenLastClosed], "Quit all, Reopen all, Reopen last closed, in that order")
        t.expect(empty.allSatisfy { !$0.isEnabled }, "every empty item is disabled")
        t.expect(empty.allSatisfy { $0.disabledReason != nil && !$0.disabledReason!.contains("later") }, "…each says why it has nothing to do")
        t.expectEqual(empty.map(\.title), ["Quit all (0)", "Reopen all (0)", "Reopen last closed (0)"], "each title carries its count")
        t.expectEqual(empty[0].disabledReason, "No sessions started by AgentMenu are running.", "an empty Quit all says why")
        t.expectEqual(empty[1].disabledReason, "No sessions are waiting to be reopened.", "an empty Reopen all says why")
        t.expectEqual(empty[2].disabledReason, "No closed session to reopen.", "an empty Reopen last closed says why")

        let items = SessionsHeaderMenu.items(quitAllCount: 3, reopenAllCount: 2, reopenLastClosedCount: 1)
        t.expect(items.allSatisfy(\.isEnabled), "an item with something to do is enabled")
        t.expectEqual(items.map(\.title), ["Quit all (3)", "Reopen all (2)", "Reopen last closed (1)"], "the count is in the title")
    }

    // MARK: 6. The Reopen all strip.

    do {
        t.expectEqual(ReopenAllSummary(total: 3, failures: []).headline, "Reopened 3 sessions", "all reopened")
        t.expectEqual(ReopenAllSummary(total: 1, failures: []).headline, "Reopened 1 session", "one reopened")
        let partial = ReopenAllSummary(total: 4, failures: [.init(name: "Invoices", reason: "the folder is gone")])
        t.expectEqual(partial.headline, "Reopened 3 of 4; 1 failed", "a partial result says how many failed")
        t.expectEqual(partial.reopened, 3, "the reopened count is the rest")
        t.expectEqual(ReopenAllSummary(total: 0, failures: [.init(name: "x", reason: "y")]).reopened, 0, "never negative")
    }

    // MARK: 7. The live list: headers, rows, pending launches, heights.

    do {
        let rows = [
            live(status: .needsYou, cwd: "/work/hub"),
            live(status: .working, cwd: "/work/hub"),
            live(status: .yourTurn, cwd: "/work/invoices"),
        ]
        let snap = snapshot(rows, folders: [FolderTarget(id: "hub", label: "Hub", path: "/work/hub")])
        let items = SessionsListLayout.liveItems(snapshot: snap)
        t.expectEqual(headers(items), ["Needs you", "Hub", "invoices"], "Needs you first, then the launch target, then the other folder")
        t.expectEqual(items.count, 3 + 3, "three headers and three rows")
        t.expectEqual(
            SessionsListLayout.contentHeight(items),
            3 * SessionsListLayout.headerHeight + 3 * SessionsListLayout.liveRowHeight,
            "the height is the sum of each item's own"
        )
        t.expectEqual(Set(items.map(\.id)).count, items.count, "every item has its own id")
        t.expectEqual(
            SessionsListLayout.listHeight(items), SessionsListLayout.contentHeight(items),
            "a short list is as tall as its content, not the cap"
        )

        // The sessions-tab harness scenario plants exactly one waiting session
        // and asserts the Needs-you heading exists: that proves the row is under
        // it only because a waiting row is listed once, in that group, and the
        // heading comes first and is the only one marked as Needs you.
        let sole = SessionsListLayout.liveItems(snapshot: snapshot([live(status: .needsYou, cwd: "/work/hub")]))
        t.expectEqual(headers(sole), ["Needs you"], "a lone waiting session has no folder group besides Needs you")
        t.expectEqual(sole.count, 2, "one heading and one row")
        if case .groupHeader(_, _, let count, let isNeedsYou) = sole[0] {
            t.expect(isNeedsYou, "the heading the row sits under is the Needs-you one, which carries the identifier")
            t.expectEqual(count, 1, "counting the row")
        } else {
            t.expect(false, "the first item is the Needs-you heading")
        }
        if case .live = sole[1] {} else { t.expect(false, "the row follows its heading") }
        t.expectEqual(
            items.compactMap { item -> Bool? in
                if case .groupHeader(_, _, _, let isNeedsYou) = item { return isNeedsYou }
                return nil
            },
            [true, false, false],
            "only the first heading is the Needs-you one, so only one element carries its identifier"
        )

        let empty = SessionsListLayout.liveItems(snapshot: snapshot([]))
        t.expect(empty.isEmpty, "nothing listed, no items")
        t.expectEqual(SessionsListLayout.contentHeight(empty), 0, "…and no height")
        t.expectEqual(SessionsListLayout.listHeight(empty), SessionsListLayout.minHeight, "…but the list box keeps its floor")

        let many = (0..<30).map { _ in live(status: .working, cwd: "/work/hub") }
        let big = SessionsListLayout.liveItems(snapshot: snapshot(many))
        t.expect(SessionsListLayout.contentHeight(big) > SessionsListLayout.maxHeight, "thirty rows are taller than the cap")
        t.expectEqual(SessionsListLayout.listHeight(big), SessionsListLayout.maxHeight, "the list is capped and scrolls")
        t.expectEqual(SessionsListLayout.listHeight(big, cap: 100), 100, "a different cap is honoured")
    }

    // MARK: 8. Pending launches (R36): in their folder group, by phase, under the pill.

    do {
        let base = snapshot([live(status: .working, cwd: "/work/hub")], folders: [FolderTarget(id: "hub", label: "Hub", path: "/work/hub")])

        let starting = SessionsListLayout.liveItems(snapshot: base, pending: [pending("p1", folder: "/work/hub")])
        t.expectEqual(headers(starting), ["Hub"], "a starting launch joins the group of its folder")
        t.expectEqual(starting.count, 3, "a header, the pending row and the live row")
        if case .groupHeader(_, _, let count, _) = starting[0] { t.expectEqual(count, 2, "the group counts the pending launch too") }
        if case .pending = starting[1] { t.expect(true, "the pending row comes first in its group") } else { t.expect(false, "the pending row comes first in its group") }

        let failed = pending("p2", folder: "/work/hub", phase: .failedToStart(reason: "claude exited"))
        let failedItems = SessionsListLayout.liveItems(snapshot: base, pending: [failed])
        t.expectEqual(
            SessionsListLayout.contentHeight(failedItems),
            SessionsListLayout.headerHeight + SessionsListLayout.failedRowHeight + SessionsListLayout.liveRowHeight,
            "a failed launch is taller, for its reason"
        )

        let elsewhere = SessionsListLayout.liveItems(snapshot: base, pending: [pending("p3", folder: "/work/new")])
        t.expectEqual(headers(elsewhere), ["Hub", "new"], "a launch into a folder with no group gets one")

        let noFolder = SessionsListLayout.liveItems(snapshot: base, pending: [pending("p4", folder: nil)])
        t.expectEqual(headers(noFolder), ["Hub", "No folder"], "a launch with no folder gets the No folder group")

        let other = SessionsListLayout.liveItems(snapshot: base, pending: [pending("p5", folder: "/work/hub", profile: "personal")])
        let filtered = snapshot([live(status: .working, cwd: "/work/hub")], pill: .profile("work"))
        let filteredItems = SessionsListLayout.liveItems(snapshot: filtered, pending: [pending("p5", folder: "/work/hub", profile: "personal")])
        t.expectEqual(other.count, 3, "under All a launch of any account is listed")
        t.expectEqual(filteredItems.count, 2, "under another account's pill it is left out, like a row would be")

        let onlyPending = SessionsListLayout.liveItems(snapshot: snapshot([]), pending: [pending("p6", folder: "/work/hub")])
        t.expectEqual(headers(onlyPending), ["hub"], "a starting launch is listed even with no live session at all")
    }

    // MARK: 9. The journal diff: seen once, status changes, a session that leaves and returns (KTD16).

    do {
        let a = live(status: .working, pid: 4001)
        let b = live(status: .yourTurn, pid: 4002)
        let first = SessionJournalDiff.compare(previous: [:], current: [a, b])
        t.expectEqual(first.appeared.map(\.pid), [4001, 4002], "every session is seen the first time")
        t.expect(first.changed.isEmpty, "nothing changed yet")

        let same = SessionJournalDiff.compare(previous: first.statuses, current: [a, b])
        t.expect(same.appeared.isEmpty && same.changed.isEmpty, "an unchanged list reports nothing")

        let aNeedsYou = live(status: .needsYou, pid: 4001)
        let moved = SessionJournalDiff.compare(previous: first.statuses, current: [aNeedsYou, b])
        t.expect(moved.appeared.isEmpty, "a status change is not a new session")
        t.expectEqual(moved.changed.count, 1, "one status changed")
        t.expectEqual(moved.changed.first?.from, .working, "from what it was")
        t.expectEqual(moved.changed.first?.session.status, .needsYou, "to what it is")

        let gone = SessionJournalDiff.compare(previous: first.statuses, current: [b])
        t.expectEqual(gone.statuses.count, 1, "a session that left is forgotten")
        let back = SessionJournalDiff.compare(previous: gone.statuses, current: [a, b])
        t.expectEqual(back.appeared.map(\.pid), [4001], "…so one that returns under its key is seen again")

        let duplicate = SessionJournalDiff.compare(previous: [:], current: [a, a])
        t.expectEqual(duplicate.appeared.count, 1, "a row listed twice is seen once")
    }

    // MARK: 10. Restore outcomes from refusals: a closed vocabulary, nothing from the error text.

    do {
        typealias Outcome = JournalData.RestoreOutcome
        t.expectEqual(Outcome(refusal: .invalidSessionID), .invalidSession, "invalid id")
        t.expectEqual(Outcome(refusal: .alreadyLive(focus: [])), .focusedLive, "already live is focused instead")
        t.expectEqual(Outcome(refusal: .runningElsewhere), .alreadyRunning, "running under a host with no listed row")
        t.expectEqual(Outcome(refusal: .launchInFlight), .alreadyRunning, "a resume not yet registered")
        t.expectEqual(Outcome(refusal: .notRestorable(reason: "/Users/someone/secret")), .notRestorable, "the reason text is not carried")
        t.expectEqual(Outcome(refusal: .unknownProfile(id: "x")), .unknownProfile, "unknown profile")
        t.expectEqual(Outcome(refusal: .agentUnavailable), .agentUnavailable, "agent unavailable")
    }

    // MARK: 11. The closed list: headings, rows, and a fold only when opened.

    do {
        let store = TempDir("presentation-closed")
        defer { store.cleanup() }
        func write(_ session: String, prompt: String, hoursAgo: Double) {
            let record: [String: Any] = [
                "type": "user", "sessionId": session, "cwd": "/work/invoices", "entrypoint": "cli", "isSidechain": false,
                "message": ["role": "user", "content": prompt],
                "uuid": UUID().uuidString, "timestamp": "2026-09-30T10:00:00.000Z", "version": "2.1.285",
            ]
            let data = try! JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes])
            try? store.write(String(decoding: data, as: UTF8.self) + "\n", to: "projects/-work-invoices/\(session).jsonl")
            let url = store.url.appendingPathComponent("projects/-work-invoices/\(session).jsonl")
            try? FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-hoursAgo * 3_600)], ofItemAtPath: url.path
            )
        }
        write("10000000-0000-4000-8000-000000000001", prompt: "/collect-invoices", hoursAgo: 0.1)
        write("10000000-0000-4000-8000-000000000002", prompt: "/collect-invoices", hoursAgo: 0.2)
        write("10000000-0000-4000-8000-000000000003", prompt: "/collect-invoices", hoursAgo: 0.3)
        write("10000000-0000-4000-8000-000000000004", prompt: "tidy the ledger", hoursAgo: 0.4)

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let now = Date()
        let sections = ClosedSessionList.build(
            entries: TranscriptIndex().scan(profiles: [TranscriptProfile(id: "work", directory: store.url)], now: now),
            now: now, calendar: calendar
        )
        guard let fold = sections.flatMap(\.rows).compactMap({ row -> SkillFold? in
            if case .fold(let fold) = row { return fold }
            return nil
        }).first else {
            t.expect(false, "the three bare skill runs folded into one row")
            return
        }
        t.expectEqual(fold.count, 3, "the fold holds the three runs")

        let collapsed = SessionsListLayout.closedItems(sections: sections)
        let opened = SessionsListLayout.closedItems(sections: sections, expandedFolds: [fold.id])
        t.expectEqual(opened.count - collapsed.count, 3, "opening a fold shows its three runs")
        t.expectEqual(
            SessionsListLayout.contentHeight(opened) - SessionsListLayout.contentHeight(collapsed),
            3 * SessionsListLayout.foldedChildHeight,
            "…each at the folded child's height"
        )
        t.expectEqual(Set(opened.map(\.id)).count, opened.count, "closed items have unique ids, folded runs included")
        if case .sectionHeader = collapsed[0] { t.expect(true, "a recency heading leads the list") } else { t.expect(false, "a recency heading leads the list") }
    }
}
