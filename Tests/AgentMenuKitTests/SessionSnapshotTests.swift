// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

// The snapshot builder (R3-R7, R9): live records + the transcript index + the
// renames table in, what the Sessions tab and the badge show out. Live rows
// are built by hand through `LiveSession`'s public initialiser; transcripts
// are real JSONL in a temp directory, indexed by the real `TranscriptIndex`,
// so the lookup by (config directory, session id) is exercised the way the
// app will use it. Nothing here reads a real profile.

// MARK: - Fixtures

private let base = Date(timeIntervalSince1970: 1_790_753_423)

private func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

private struct Account {
    let id: String
    let name: String
    let dir: TempDir

    init(_ id: String, _ name: String) {
        self.id = id
        self.name = name
        dir = TempDir("snapshot-\(id)")
    }

    var directory: URL { dir.url }
    var profile: RegistryProfile { RegistryProfile(id: id, name: name, directory: dir.url) }
    var transcriptProfile: TranscriptProfile { TranscriptProfile(id: id, directory: dir.url) }

    /// A transcript for `session`, with whatever title records are given.
    func transcript(
        _ session: String,
        cwd: String,
        prompt: String = "look at the invoices",
        aiTitle: String? = nil,
        customTitle: String? = nil
    ) {
        var lines: [String] = []
        let user: [String: Any] = [
            "type": "user", "sessionId": session, "cwd": cwd, "entrypoint": "cli", "isSidechain": false,
            "message": ["role": "user", "content": prompt],
            "uuid": UUID().uuidString, "timestamp": "2026-09-30T10:00:00.000Z", "version": "2.1.285",
        ]
        lines.append(jsonLine(user))
        if let aiTitle { lines.append(jsonLine(["type": "ai-title", "aiTitle": aiTitle, "sessionId": session])) }
        if let customTitle { lines.append(jsonLine(["type": "custom-title", "customTitle": customTitle, "sessionId": session])) }
        try? dir.write(lines.joined(separator: "\n") + "\n", to: "projects/-proj/\(session).jsonl")
    }
}

private func jsonLine(_ object: [String: Any]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
    return String(decoding: data, as: UTF8.self)
}

private var nextPid: Int32 = 1000

/// A Claude Code row registered in `account`'s directory.
private func claude(
    _ account: Account,
    cwd: String? = "/work/hub",
    session: String? = nil,
    status: SessionStatus = .yourTurn,
    registryName: String? = nil,
    pid: Int32? = nil,
    procStart: Int = 1_790_753_000,
    started: TimeInterval = 0,
    statusUpdated: TimeInterval? = nil,
    updated: TimeInterval? = nil
) -> LiveSession {
    let pid = pid ?? { nextPid += 1; return nextPid }()
    let directory = account.directory.standardizedFileURL
    return LiveSession(
        key: LiveSessionKey(configDirectory: directory.path, pid: pid, procStart: procStart),
        agentID: "claude-code",
        agentDisplayName: "Claude Code",
        profileID: account.id,
        profileName: account.name,
        configDirectory: directory,
        pid: pid,
        sessionId: session ?? "session-\(pid)-abcdefgh",
        cwd: cwd,
        kind: "interactive",
        entrypoint: "cli",
        registryName: registryName,
        status: status,
        startedAt: at(started),
        updatedAt: updated.map(at),
        statusUpdatedAt: statusUpdated.map(at)
    )
}

/// An agent found by the process scan: no registry, no profile, no session id.
private func scanned(cwd: String? = "/work/hub", pid: Int32 = 5000) -> LiveSession {
    LiveSession(
        key: LiveSessionKey(configDirectory: nil, pid: pid, procStart: 1_790_753_100),
        agentID: "codex",
        agentDisplayName: "Codex",
        pid: pid,
        cwd: cwd,
        status: .unknown,
        startedAt: at(0)
    )
}

private func target(_ label: String, _ path: String, id: String? = nil) -> FolderTarget {
    FolderTarget(id: id ?? label.lowercased(), label: label, path: path)
}

private func build(
    _ live: [LiveSession],
    accounts: [Account],
    folders: [FolderTarget] = [],
    transcripts: [TranscriptEntry] = [],
    renames: [String: String] = [:],
    owned: [LiveSessionKey: WindowAttachment] = [:],
    pill: AccountPill = .all
) -> SessionSnapshot {
    SessionSnapshot.build(
        live: live,
        transcripts: transcripts,
        profiles: accounts.map(\.profile),
        folders: folders,
        renames: renames,
        owned: owned,
        pill: pill
    )
}

private func index(_ accounts: [Account]) -> [TranscriptEntry] {
    TranscriptIndex().scan(profiles: accounts.map(\.transcriptProfile), now: Date())
}

func runSessionSnapshotTests(_ t: TestRunner) {
    t.suite("SessionSnapshot")

    let personal = Account("personal", "Personal")
    let work = Account("work", "Work")
    defer { personal.dir.cleanup(); work.dir.cleanup() }
    let both = [personal, work]

    // MARK: 1. Grouping by project folder (R4).

    do {
        let a = claude(personal, cwd: "/work/hub", status: .working, started: 10)
        let b = claude(personal, cwd: "/work/hub", status: .yourTurn, started: 20)
        let c = claude(personal, cwd: "/work/other-thing", status: .yourTurn, started: 30)
        let snapshot = build([a, b, c], accounts: both, folders: [target("Hub Site", "/work/hub")])

        t.expectEqual(snapshot.groups.map(\.title), ["Hub Site", "other-thing"], "a launch-target folder shows its display name; another folder shows its own name")
        t.expectEqual(snapshot.groups.first?.rows.count, 2, "both sessions in the launch-target folder are in its group")
        t.expectEqual(snapshot.groups.last?.rows.count, 1, "the session elsewhere has a group of its own")
        t.expectEqual(snapshot.groups.map(\.kind), [
            .folder(path: "/work/hub", isLaunchTarget: true),
            .folder(path: "/work/other-thing", isLaunchTarget: false),
        ], "the group kinds say which folder each is and whether it is a launch target")
        t.expect(snapshot.needsYouGroup == nil, "with nobody waiting there is no Needs you group")
        t.expectEqual(snapshot.badgeCount, 0, "…and the badge is zero")
        t.expectEqual(
            snapshot.groups.first?.rows.map(\.key), [a.key, b.key],
            "rows inside a group are ordered by urgency: Working before Your turn"
        )
        t.expectEqual(snapshot.groups.first?.id, "folder:/work/hub", "a folder group's id is its folder")
    }

    // A path is matched by expansion and normalisation, not by spelling:
    // a trailing slash, a `~`, and a symlinked spelling all name one folder.
    do {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let real = TempDir("snapshot-realdir")
        defer { real.cleanup() }
        let realFolder = real.url.appendingPathComponent("proj", isDirectory: true)
        let link = real.url.appendingPathComponent("link")
        try? FileManager.default.createDirectory(at: realFolder, withIntermediateDirectories: true)
        try? FileManager.default.createSymbolicLink(at: link, withDestinationURL: realFolder)

        let inHome = claude(personal, cwd: home + "/hubdir")
        let viaSymlink = claude(personal, cwd: realFolder.path)
        let snapshot = build(
            [inHome, viaSymlink], accounts: both,
            folders: [target("Home Hub", "~/hubdir/"), target("Linked", link.path)]
        )
        t.expectEqual(snapshot.groups.map(\.title), ["Home Hub", "Linked"], "a `~` path with a trailing slash matches its expanded cwd; a symlinked target matches the real cwd")
        t.expect(snapshot.groups.allSatisfy { $0.rows.count == 1 }, "each session joined exactly one group")
    }

    // The match is exact: a session in a subfolder of a target is not in the
    // target's group.
    do {
        let inTarget = claude(personal, cwd: "/work/hub")
        let inSub = claude(personal, cwd: "/work/hub/packages/api")
        let snapshot = build([inTarget, inSub], accounts: both, folders: [target("Hub", "/work/hub")])
        t.expectEqual(snapshot.groups.map(\.title).sorted(), ["Hub", "api"], "a subfolder of a target is a folder of its own")
        t.expectEqual(snapshot.groups.first { $0.title == "Hub" }?.rows.count, 1, "…and does not join the target's group")
    }

    // Several targets on one path are one group, labelled by the first.
    do {
        let s = claude(personal, cwd: "/work/hub")
        let snapshot = build(
            [s], accounts: both,
            folders: [target("Hub (work)", "/work/hub", id: "a"), target("Hub (personal)", "/work/hub/", id: "b")]
        )
        t.expectEqual(snapshot.groups.map(\.title), ["Hub (work)"], "two launch targets on one folder make one group, labelled by the first entry")
    }

    // Group order: Needs you, then launch targets in the order configured,
    // then other folders by newest activity, then rows with no folder.
    do {
        let noFolder = claude(personal, cwd: nil, started: 500)
        let oldElsewhere = claude(personal, cwd: "/z/old", started: 100)
        let newElsewhere = claude(personal, cwd: "/a/new", started: 400)
        let second = claude(personal, cwd: "/work/second", started: 50)
        let first = claude(personal, cwd: "/work/first", started: 60)
        let waiting = claude(personal, cwd: "/work/first", status: .needsYou, started: 70)
        let snapshot = build(
            [noFolder, oldElsewhere, newElsewhere, second, first, waiting], accounts: both,
            folders: [target("First", "/work/first"), target("Second", "/work/second")]
        )
        t.expectEqual(
            snapshot.groups.map(\.title), ["Needs you", "First", "Second", "new", "old", "No folder"],
            "Needs you, launch targets in configured order, other folders newest first, then no folder"
        )
        t.expectEqual(snapshot.groups.last?.kind, .folder(path: nil, isLaunchTarget: false), "the no-folder group has no path")
        t.expectEqual(snapshot.groups.last?.id, "no-folder", "…and its own id")
    }

    // Two other folders with the same name keep their identity: distinct ids,
    // and a label that tells them apart.
    do {
        let one = claude(personal, cwd: "/clients/acme/app")
        let two = claude(personal, cwd: "/clients/globex/app")
        let snapshot = build([one, two], accounts: both)
        t.expectEqual(snapshot.groups.count, 2, "two folders that share a name are two groups")
        t.expectEqual(Set(snapshot.groups.map(\.id)).count, 2, "…with distinct ids")
        t.expectEqual(Set(snapshot.groups.map(\.title)).count, 2, "…and labels that differ, so the rows can be told apart")
    }

    // MARK: 2. Needs you (R5): its own group, on top, and only there.

    do {
        let waiting = claude(personal, cwd: "/work/hub", status: .needsYou, started: 10)
        let busy = claude(personal, cwd: "/work/hub", status: .working, started: 20)
        let snapshot = build([waiting, busy], accounts: both, folders: [target("Hub", "/work/hub")])

        t.expectEqual(snapshot.groups.first?.kind, .needsYou, "the Needs you group is first")
        t.expectEqual(snapshot.needsYouGroup?.title, "Needs you", "…and is called that")
        t.expectEqual(snapshot.needsYouGroup?.rows.map(\.key), [waiting.key], "it holds the waiting session")
        t.expectEqual(snapshot.groups.dropFirst().flatMap(\.rows).map(\.key), [busy.key], "the folder group holds only the other session")
        t.expectEqual(snapshot.groups.flatMap(\.rows).filter { $0.key == waiting.key }.count, 1, "a Needs-you session appears exactly once")
        t.expectEqual(snapshot.badgeCount, 1, "the badge counts it")
        t.expectEqual(snapshot.needsYouGroup?.id, "needs-you", "the group has a stable id")

        // When the only session in a folder is waiting, the folder has no group.
        let alone = build([claude(personal, cwd: "/work/lonely", status: .needsYou)], accounts: both)
        t.expectEqual(alone.groups.map(\.title), ["Needs you"], "a folder whose only session is waiting has no empty group of its own")
    }

    // MARK: 3. AE9: detached is a marker, not a status.

    do {
        let a = claude(personal, cwd: "/work/hub", status: .needsYou)
        let b = claude(personal, cwd: "/work/hub", status: .yourTurn)
        let c = claude(personal, cwd: "/work/hub", status: .needsYou)
        let snapshot = build(
            [a, b, c], accounts: both, folders: [target("Hub", "/work/hub")],
            owned: [a.key: .detached, b.key: .detached, c.key: .attached]
        )
        let rowA = snapshot.needsYouGroup?.rows.first { $0.key == a.key }
        t.expect(rowA != nil, "AE9: the detached owned session is in the Needs you group")
        t.expectEqual(rowA?.status, .needsYou, "AE9: its status is still Needs you")
        t.expectEqual(rowA?.isDetached, true, "AE9: it carries the Detached marker")
        t.expectEqual(rowA?.isOwned, true, "AE9: and is owned")
        t.expectEqual(snapshot.badgeCount, 2, "AE9: the badge counts it, marker or not")
        let rowB = snapshot.groups.flatMap(\.rows).first { $0.key == b.key }
        t.expectEqual(rowB?.status, .yourTurn, "a detached Your-turn session keeps its status")
        t.expectEqual(rowB?.isDetached, true, "…and carries the marker")
        t.expect(snapshot.needsYouGroup?.rows.contains { $0.key == b.key } == false, "the marker alone does not move it to Needs you")
        let rowC = snapshot.needsYouGroup?.rows.first { $0.key == c.key }
        t.expectEqual(rowC?.isDetached, false, "an owned session with a window attached is not detached")
        t.expectEqual(rowC?.isOwned, true, "…but is owned")

        let plain = build([a], accounts: both)
        t.expectEqual(plain.needsYouGroup?.rows.first?.isOwned, false, "with no ownership input nothing is owned")
        t.expectEqual(plain.needsYouGroup?.rows.first?.isDetached, false, "…and nothing is detached")
    }

    // MARK: 4. AE4: the pill filters the list, never the badge (R6, R7).

    do {
        let mine = claude(personal, cwd: "/work/hub", status: .yourTurn, started: 10)
        let theirs = claude(work, cwd: "/work/hub", status: .needsYou, started: 20)
        let theirsBusy = claude(work, cwd: "/work/other", status: .working, started: 30)
        let all = [mine, theirs, theirsBusy]

        let everything = build(all, accounts: both)
        t.expectEqual(everything.selectedPill, .all, "All is the default pill")
        t.expectEqual(everything.groups.flatMap(\.rows).count, 3, "All shows every row")

        let onlyPersonal = build(all, accounts: both, pill: .profile("personal"))
        t.expectEqual(onlyPersonal.selectedPill, .profile("personal"), "the Personal pill is selected")
        t.expectEqual(onlyPersonal.groups.flatMap(\.rows).map(\.key), [mine.key], "AE4: the Personal pill hides both Work rows")
        t.expect(onlyPersonal.needsYouGroup == nil, "AE4: the Work session that is waiting is not listed under Personal")
        t.expectEqual(onlyPersonal.badgeCount, 1, "AE4: the badge still counts the Work session")
        t.expectEqual(everything.badgeCount, 1, "the badge is the same with any pill")

        // A pill for the other account shows its rows, Needs you included.
        let onlyWork = build(all, accounts: both, pill: .profile("work"))
        t.expectEqual(onlyWork.needsYouGroup?.rows.map(\.key), [theirs.key], "the Work pill shows the waiting Work session in Needs you")
        t.expectEqual(onlyWork.groups.flatMap(\.rows).count, 2, "…and its other row")

        // The pills: All, then one per profile in configured order, each with
        // its own Needs-you count; the counts do not depend on the selection.
        t.expectEqual(everything.pills.map(\.title), ["All", "Personal", "Work"], "pills are All, then one per profile in configured order")
        t.expectEqual(everything.pills.map(\.needsYouCount), [1, 0, 1], "each pill counts its own waiting sessions; All counts every account")
        t.expectEqual(onlyPersonal.pills.map(\.needsYouCount), [1, 0, 1], "the counts do not change with the selected pill")
        t.expectEqual(everything.pills.map(\.pill), [.all, .profile("personal"), .profile("work")], "each pill names what it selects")
        t.expectEqual(everything.pills.map(\.id), ["all", "profile:personal", "profile:work"], "pills have stable ids")

        // A pill for a profile that no longer exists falls back to All.
        let gone = build(all, accounts: both, pill: .profile("deleted"))
        t.expectEqual(gone.selectedPill, .all, "a pill for a removed profile falls back to All")
        t.expectEqual(gone.groups.flatMap(\.rows).count, 3, "…and shows every row")
    }

    // Non-Claude agents have no profile: All only, never in a count.
    do {
        let codex = scanned(cwd: "/work/hub")
        let mine = claude(personal, cwd: "/work/hub", status: .needsYou)
        let all = build([codex, mine], accounts: both)
        t.expectEqual(all.groups.flatMap(\.rows).count, 2, "under All a scanned agent is listed")
        let row = all.groups.flatMap(\.rows).first { $0.key == codex.key }
        t.expectEqual(row?.status, .unknown, "its status is Unknown")
        t.expect(row?.profileID == nil && row?.profileName == nil, "it belongs to no profile")
        t.expectEqual(row?.title.text, "Codex", "it is named after the agent")
        t.expectEqual(row?.sessionId, nil, "it has no session id")
        t.expectEqual(all.badgeCount, 1, "it never counts toward the badge")
        t.expectEqual(all.pills.map(\.needsYouCount), [1, 1, 0], "…nor toward any pill")

        let filtered = build([codex, mine], accounts: both, pill: .profile("personal"))
        t.expect(!filtered.groups.flatMap(\.rows).contains { $0.key == codex.key }, "under a profile pill a scanned agent is hidden")
        let other = build([codex], accounts: both, pill: .profile("work"))
        t.expect(other.groups.isEmpty, "…under every profile pill")
    }

    // Two profiles on one directory (R6): rows go to the first, flagged.
    do {
        let shared = Account("first", "First")
        let twin = RegistryProfile(id: "second", name: "Second", directory: shared.directory)
        defer { shared.dir.cleanup() }
        let row = claude(shared, cwd: "/work/hub", status: .needsYou)
        let snapshot = SessionSnapshot.build(
            live: [row], transcripts: [], profiles: [shared.profile, twin, personal.profile], folders: [],
            renames: [:], owned: [:], pill: .all
        )
        let listed = snapshot.needsYouGroup?.rows.first
        t.expectEqual(listed?.profileID, "first", "a row in a shared directory is attributed to the profile listed first")
        t.expectEqual(listed?.profileName, "First", "…by name too")
        t.expectEqual(listed?.sharedDirectory?.attributedTo, "First", "the shared-directory flag names the profile it is attributed to")
        t.expectEqual(listed?.sharedDirectory?.alsoUsedBy, ["Second"], "…and the other profiles on that directory")
        t.expect(listed?.sharedDirectory?.tooltip.contains("First") == true && listed?.sharedDirectory?.tooltip.contains("Second") == true, "the tooltip names both")
        t.expectEqual(snapshot.pills.map(\.title), ["All", "First", "Second", "Personal"], "each profile still has its pill")
        t.expectEqual(snapshot.pills.map(\.needsYouCount), [1, 1, 0, 0], "the row counts under the first profile's pill only")
        t.expectEqual(snapshot.pills.first { $0.pill == .profile("second") }?.sharedDirectoryWith, ["First"], "the second profile's pill says its directory is shared")

        let secondPill = SessionSnapshot.build(
            live: [row], transcripts: [], profiles: [shared.profile, twin], folders: [],
            renames: [:], owned: [:], pill: .profile("second")
        )
        t.expect(secondPill.groups.isEmpty, "the second profile's pill shows nothing: the rows belong to the first")

        // A row on an unshared directory carries no flag.
        let plain = build([claude(personal)], accounts: both)
        t.expect(plain.groups.first?.rows.first?.sharedDirectory == nil, "an unshared directory is not flagged")
    }

    // MARK: 5. Names (R3).

    do {
        personal.transcript("named-1111", cwd: "/work/hub", prompt: "sort the invoices", aiTitle: "Invoice sorting")
        personal.transcript("named-2222", cwd: "/work/hub", prompt: "audit the ledger", aiTitle: "Ledger audit", customTitle: "Ledger, by hand")
        personal.transcript("named-3333", cwd: "/work/hub", prompt: "fix the login page")
        personal.transcript("named-4444", cwd: "/work/hub", prompt: "/collect-invoices")
        let entries = index(both)
        let s1 = claude(personal, session: "named-1111", registryName: "registry one")
        let s2 = claude(personal, session: "named-2222")
        let s3 = claude(personal, session: "named-3333", registryName: "Registry three")
        let s3bare = claude(personal, session: "named-3333")
        let s4 = claude(personal, session: "named-4444")

        func title(_ row: LiveSession, renames: [String: String] = [:], entries: [TranscriptEntry] = entries) -> SessionTitle? {
            build([row], accounts: both, transcripts: entries, renames: renames).groups.first?.rows.first?.title
        }

        t.expectEqual(title(s1)?.text, "Invoice sorting", "the transcript's recorded title is the name")
        t.expectEqual(title(s1)?.source, .aiTitle, "…and says where it came from")
        t.expectEqual(title(s2)?.text, "Ledger, by hand", "a custom title beats an AI title, by U3's ladder")

        // Rename overrides, and clearing restores.
        t.expectEqual(title(s1, renames: ["named-1111": "Q3 invoices"])?.text, "Q3 invoices", "a rename overrides the transcript title")
        t.expectEqual(title(s1, renames: ["named-1111": "Q3 invoices"])?.source, .rename, "…and is marked as a rename")
        t.expectEqual(title(s1, renames: [:])?.text, "Invoice sorting", "clearing the rename restores the transcript title")
        t.expectEqual(title(s1, renames: ["other-session": "x"])?.text, "Invoice sorting", "a rename for another session changes nothing")
        t.expectEqual(title(s1, renames: ["named-1111": "  "])?.text, "Invoice sorting", "a blank rename is not a name")

        // Round trip through the real store: set, build, clear, build.
        let dir = TempDir("snapshot-store")
        defer { dir.cleanup() }
        let store = SessionStore(url: dir.url.appendingPathComponent("sessions.json"))
        try? store.setRename("From the store", for: "named-1111")
        t.expectEqual(title(s1, renames: store.renames)?.text, "From the store", "a rename saved in the store reaches the row")
        try? store.setRename(nil, for: "named-1111")
        t.expectEqual(title(s1, renames: store.renames)?.text, "Invoice sorting", "clearing it in the store restores the recorded title")

        // No recorded title: the registry's name outranks a name made of the
        // first prompt, and both rank below anything the agent recorded.
        t.expectEqual(title(s3)?.text, "Registry three", "with no recorded title the registry's name is used before the first prompt")
        t.expectEqual(title(s3bare)?.text, "fix the login page", "with neither, the first prompt names the row")
        t.expectEqual(title(s4)?.text, "/collect-invoices", "…or the skill it invoked")
        t.expectEqual(title(s3, renames: ["named-3333": "Mine"])?.text, "Mine", "a rename beats the registry name too")

        // No transcript at all.
        let fresh = claude(personal, session: "abcd1234-5678-90ab", registryName: "Brand new")
        t.expectEqual(title(fresh)?.text, "Brand new", "a live row with no transcript yet falls back to the registry name")
        let noName = claude(personal, session: "abcd1234-5678-90ab")
        t.expectEqual(title(noName)?.text, "abcd1234", "…then to the session id prefix")
        t.expectEqual(title(noName)?.source, .sessionIdPrefix, "…marked as such")
        let blankName = claude(personal, session: "abcd1234-5678-90ab", registryName: "   ")
        t.expectEqual(title(blankName)?.text, "abcd1234", "a blank registry name is no name")
        t.expectEqual(title(fresh, renames: ["abcd1234-5678-90ab": "Renamed early"])?.text, "Renamed early", "a row with no transcript can still be renamed")

        // The transcript is found by config directory as well as session id.
        work.transcript("named-1111", cwd: "/work/hub", prompt: "the work account's own", aiTitle: "Work title")
        let both2 = index(both)
        let inWork = claude(work, session: "named-1111")
        t.expectEqual(title(inWork, entries: both2)?.text, "Work title", "a transcript is looked up in the row's own config directory")
        t.expectEqual(title(s1, entries: both2)?.text, "Invoice sorting", "…so the same session id in another account does not cross over")
        let noTranscriptHere = claude(work, session: "named-4444")
        t.expectEqual(title(noTranscriptHere, entries: both2)?.text, "named-44", "a session id that only exists in another account's store is not borrowed")
        try? FileManager.default.removeItem(at: work.directory.appendingPathComponent("projects"))

        // A row with no session id (a registry file written before the id).
        let anon = LiveSession(
            key: LiveSessionKey(configDirectory: personal.directory.standardizedFileURL.path, pid: 7, procStart: 1),
            agentID: "claude-code", agentDisplayName: "Claude Code",
            profileID: "personal", profileName: "Personal", configDirectory: personal.directory.standardizedFileURL,
            pid: 7, sessionId: nil, cwd: "/work/hub", registryName: "Early name", status: .working, startedAt: at(0)
        )
        t.expectEqual(title(anon)?.text, "Early name", "a row with no session id is named by the registry")
        t.expectEqual(build([anon], accounts: both).groups.first?.rows.first?.sessionId, nil, "…and has no session id to rename by")
    }

    // MARK: 6. Ordering inside a group.

    do {
        let needsOld = claude(personal, cwd: "/w", status: .needsYou, started: 10, statusUpdated: 100)
        let needsNew = claude(personal, cwd: "/w", status: .needsYou, started: 20, statusUpdated: 300)
        let working = claude(personal, cwd: "/x", status: .working, started: 0, statusUpdated: 200)
        let workingNewer = claude(personal, cwd: "/x", status: .working, started: 0, updated: 250)
        let turn = claude(personal, cwd: "/x", status: .yourTurn, started: 0, statusUpdated: 900)
        let unknown = claude(personal, cwd: "/x", status: .unknown, started: 0, statusUpdated: 950)
        let startedOnly = claude(personal, cwd: "/x", status: .yourTurn, started: 500)

        let snapshot = build([unknown, turn, working, needsOld, workingNewer, needsNew, startedOnly], accounts: both)
        t.expectEqual(snapshot.needsYouGroup?.rows.map(\.key), [needsNew.key, needsOld.key], "in Needs you, the newest activity comes first")
        let folder = snapshot.groups.first { $0.title == "x" }
        t.expectEqual(
            folder?.rows.map(\.key), [workingNewer.key, working.key, turn.key, startedOnly.key, unknown.key],
            "Working, then Your turn, then Unknown; newest activity first within each"
        )
        t.expectEqual(folder?.rows.first { $0.key == workingNewer.key }?.lastActivity, at(250), "activity is the newer of the status time and the update time")
        t.expectEqual(folder?.rows.first { $0.key == working.key }?.lastActivity, at(200), "the status time counts when there is no update time")
        t.expectEqual(folder?.rows.first { $0.key == startedOnly.key }?.lastActivity, at(500), "the start time is the last resort")
        t.expectEqual(
            SessionStatus.allCases.sorted { $0.urgencyRank < $1.urgencyRank },
            [.needsYou, .working, .yourTurn, .unknown],
            "urgency ranks Needs you above Working above Your turn above Unknown"
        )

        // Equal activity: the order is still fixed (pid), not incidental.
        let x = claude(personal, cwd: "/t", pid: 41, started: 5)
        let y = claude(personal, cwd: "/t", pid: 40, started: 5)
        t.expectEqual(build([x, y], accounts: both).groups.first?.rows.map(\.live.pid), [40, 41], "a tie on urgency and activity is broken by pid")
        t.expectEqual(build([y, x], accounts: both).groups.first?.rows.map(\.live.pid), [40, 41], "…whatever order the rows arrive in")
    }

    // MARK: 7. Identity (KTD7): a row is keyed by (directory, pid, procStart),
    // never by session id.

    do {
        let one = claude(personal, cwd: "/w", session: "shared-id", pid: 71)
        let two = claude(personal, cwd: "/w", session: "shared-id", pid: 72)
        let reusedPid = claude(personal, cwd: "/w", session: "shared-id", pid: 71, procStart: 1_790_760_000)
        let snapshot = build([one, two, reusedPid], accounts: both)
        let rows = snapshot.groups.flatMap(\.rows)
        t.expectEqual(rows.count, 3, "two processes that share a session id are two rows")
        t.expectEqual(Set(rows.map(\.id)).count, 3, "…with distinct ids")
        t.expectEqual(rows.map(\.id), rows.map(\.key), "a row's id is its live key")

        let duplicate = build([one, one], accounts: both)
        t.expectEqual(duplicate.groups.flatMap(\.rows).count, 1, "the same key twice is one row")

        // Ownership is by key: the id's other holder is not marked.
        let owned = build([one, two], accounts: both, owned: [one.key: .detached])
        t.expectEqual(owned.groups.flatMap(\.rows).filter(\.isOwned).map(\.live.pid), [71], "ownership follows the key, not the session id")
        t.expectEqual(owned.rows.count, 2, "rows lists every row once")
    }

    // MARK: 8. Nothing live.

    do {
        let empty = build([], accounts: both)
        t.expect(empty.groups.isEmpty, "no sessions, no groups")
        t.expectEqual(empty.badgeCount, 0, "…and no badge")
        t.expectEqual(empty.pills.map(\.title), ["All", "Personal", "Work"], "the pills are still there")
        t.expect(empty.isEmpty, "the snapshot says it is empty")
        let noProfiles = SessionSnapshot.build(live: [], transcripts: [], profiles: [], folders: [], renames: [:], owned: [:], pill: .all)
        t.expectEqual(noProfiles.pills.map(\.title), ["All"], "with no profiles there is only All")
    }
}
