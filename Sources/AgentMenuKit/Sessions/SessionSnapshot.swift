// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Whether an owned session has a terminal window on screen. Only owned
/// sessions have one to lose (R9), so it is carried as the value of an
/// ownership map: a session absent from the map is not owned, and there is no
/// way to say "detached" about one that is not.
public enum WindowAttachment: Equatable, Sendable {
    case attached
    /// Hosted and running with no window attached. A marker beside the
    /// status; it never changes the status, the grouping or the badge.
    case detached
}

extension SessionStatus {
    /// How urgently a row wants the user, lowest first: Needs you (someone is
    /// blocked on you), Working (worth a glance), Your turn (finished, can
    /// wait), Unknown (no signal). It orders rows within a group.
    public var urgencyRank: Int {
        switch self {
        case .needsYou: return 0
        case .working: return 1
        case .yourTurn: return 2
        case .unknown: return 3
        }
    }
}

/// One account-filter pill (R6).
public enum AccountPill: Hashable, Sendable {
    /// Every account, and the only pill that shows an agent with no profile.
    case all
    /// One profile, by its id.
    case profile(String)

    public var id: String {
        switch self {
        case .all: return "all"
        case .profile(let id): return "profile:\(id)"
        }
    }
}

/// A pill as the tab draws it.
public struct AccountPillInfo: Equatable, Identifiable {
    public let pill: AccountPill
    /// `All`, or the profile's name.
    public let title: String
    /// Sessions waiting on the user under this pill, regardless of which pill
    /// is selected: a pill for the account you are not looking at is exactly
    /// where a count is useful.
    public let needsYouCount: Int
    /// Names of the other profiles that use this profile's config directory.
    /// Empty for `All` and for an unshared directory.
    public let sharedDirectoryWith: [String]

    public var id: String { pill.id }
}

/// Why a row is listed under one profile when two profiles name its config
/// directory (R6). The registry files sit in the directory, not in a profile,
/// so nothing can say which of the two started the session; the first listed
/// gets it, and the row says so.
public struct SharedDirectoryNote: Equatable {
    public let attributedTo: String
    public let alsoUsedBy: [String]

    /// For the row's help tag.
    public var tooltip: String {
        let names = ([attributedTo] + alsoUsedBy).joined(separator: " and ")
        return "\(names) use the same config directory, so their sessions can't be told apart. This one is listed under \(attributedTo)."
    }
}

/// One live session as the Sessions tab shows it.
public struct SessionRow: Equatable, Identifiable {
    /// (config directory, pid, procStart), KTD7. The UI's stable identity for
    /// the row: it survives a `/clear` (which changes the session id) and
    /// never merges two processes that share one.
    public let key: LiveSessionKey
    public var id: LiveSessionKey { key }
    public let live: LiveSession

    /// The session id, nil for an agent with no registry or a registry file
    /// written before the id. A rename is keyed by it, so a row without one
    /// cannot be renamed.
    public let sessionId: String?
    public let title: SessionTitle
    public var name: String { title.text }

    /// Never `Detached`: that is `isDetached`, beside the status (R9).
    public let status: SessionStatus
    public let isOwned: Bool
    /// Owned, and no window attached.
    public let isDetached: Bool

    /// The profile the row is attributed to; nil for a scanned agent, which
    /// has none.
    public let profileID: String?
    public let profileName: String?
    /// Set when another profile names the same config directory.
    public let sharedDirectory: SharedDirectoryNote?

    /// The session's folder, normalised the way launch targets are; nil when
    /// the row has no working directory.
    public let folderPath: String?
    /// When the row last did anything: the newer of its status time and its
    /// update time, else its start.
    public let lastActivity: Date
}

public enum SessionGroupKind: Equatable {
    /// Every session waiting on the user (R5).
    case needsYou
    /// A project folder. `path` is nil for sessions with no working directory.
    case folder(path: String?, isLaunchTarget: Bool)
}

public struct SessionGroup: Equatable, Identifiable {
    /// `needs-you`, `folder:<path>` or `no-folder`.
    public let id: String
    public let kind: SessionGroupKind
    public let title: String
    public let rows: [SessionRow]
}

/// What the Sessions tab and the menu-bar badge show, built by one pure
/// function from live records, the transcript index and the renames table.
///
/// Pure in the sense that matters: the same inputs give the same snapshot, it
/// keeps no state, and it does not read a registry or a transcript itself. The
/// one thing it asks of the disk is `FolderTarget.normalize` — the same symlink
/// resolution `Config.folder(forPath:)` already uses, applied to both sides of
/// a folder comparison so "the same folder" means one thing everywhere.
///
/// **Folders (R4).** A session belongs to a launch target when its working
/// directory *is* the target's folder, after expansion and normalisation. A
/// session in a subfolder does not join its parent's group: it is a different
/// place, and a target's group would otherwise silently swallow every
/// worktree and package checked out below it. Several targets on one folder
/// are one group, labelled by the first of them, because a session's
/// directory cannot say which entry started it.
///
/// **Order.** Needs you first. Then launch-target groups, in the order the
/// user arranged them. Then other folders, most recently active first. Then
/// sessions with no folder. Rows inside a group go by `urgencyRank`, then
/// last activity newest first, then pid so that a tie cannot reorder itself
/// between two refreshes.
public struct SessionSnapshot: Equatable {
    /// `All`, then one per profile in configured order (R6). A profile that
    /// shares its config directory with an earlier one keeps its pill; the
    /// pill is just empty, and says why.
    public let pills: [AccountPillInfo]
    /// The pill in force. A pill for a profile that no longer exists is not
    /// honoured: it falls back to `All`, so a deleted account cannot leave the
    /// tab filtered to nothing with no pill to click.
    public let selectedPill: AccountPill
    /// The Needs you group, nil when nobody under the selected pill is
    /// waiting.
    public let needsYouGroup: SessionGroup?
    public let folderGroups: [SessionGroup]
    /// Sessions waiting on the user across every account, ignoring the
    /// selected pill (R7): the badge is for what needs you, not for what you
    /// are looking at. Agents with no status signal are Unknown and never
    /// count.
    public let badgeCount: Int

    /// Needs you, then the folder groups: the order to draw them in.
    public var groups: [SessionGroup] {
        (needsYouGroup.map { [$0] } ?? []) + folderGroups
    }

    /// Every listed row, in display order.
    public var rows: [SessionRow] { groups.flatMap(\.rows) }

    /// Nothing to list under the selected pill.
    public var isEmpty: Bool { groups.isEmpty }

    /// - Parameters:
    ///   - live: what the registry reader reports.
    ///   - transcripts: the transcript index's entries; a row finds its own
    ///     by (config directory, session id).
    ///   - profiles: every configured profile, resolved, in configured order.
    ///     All of them, not the reader's de-duplicated list: only the full
    ///     list can tell that two share a directory.
    ///   - folders: the launch targets.
    ///   - renames: names set in AgentMenu, by session id.
    ///   - owned: sessions AgentMenu launched, by live key, with whether a
    ///     window is attached. Empty until ownership exists.
    ///   - pill: the account filter.
    public static func build(
        live: [LiveSession],
        transcripts: [TranscriptEntry] = [],
        profiles: [RegistryProfile],
        folders: [FolderTarget] = [],
        renames: [String: String] = [:],
        owned: [LiveSessionKey: WindowAttachment] = [:],
        pill: AccountPill = .all
    ) -> SessionSnapshot {
        // Profiles that name one directory, in configured order.
        var profilesByDirectory: [String: [RegistryProfile]] = [:]
        for profile in profiles {
            profilesByDirectory[profile.directory.standardizedFileURL.path, default: []].append(profile)
        }

        var entries: [TranscriptKey: TranscriptEntry] = [:]
        for entry in transcripts {
            let key = TranscriptKey(directory: entry.configDirectory.standardizedFileURL.path, sessionId: entry.sessionId)
            if entries[key] == nil { entries[key] = entry }
        }

        var normalized: [String: String] = [:]
        func folderPath(_ cwd: String?) -> String? {
            guard let cwd, !cwd.isEmpty else { return nil }
            if let hit = normalized[cwd] { return hit }
            let path = FolderTarget.normalize(cwd)
            normalized[cwd] = path
            return path
        }

        var seen = Set<LiveSessionKey>()
        var rows: [SessionRow] = []
        for session in live where seen.insert(session.key).inserted {
            let directory = transcriptDirectory(of: session)
            let holders = directory.flatMap { profilesByDirectory[$0] } ?? []
            let attributed = holders.first
            let shared = holders.count > 1
                ? SharedDirectoryNote(attributedTo: holders[0].name, alsoUsedBy: holders.dropFirst().map(\.name))
                : nil

            let entry = session.sessionId.flatMap { id in
                directory.flatMap { entries[TranscriptKey(directory: $0, sessionId: id)] }
            }
            let attachment = owned[session.key]
            rows.append(SessionRow(
                key: session.key,
                live: session,
                sessionId: session.sessionId,
                title: title(for: session, entry: entry, renames: renames),
                status: session.status,
                isOwned: attachment != nil,
                isDetached: attachment == .detached,
                // The registry reader has already done this attribution for
                // a Claude Code row, but from its own de-duplicated list. If
                // the profile is no longer configured, its answer stands.
                profileID: attributed?.id ?? session.profileID,
                profileName: attributed?.name ?? session.profileName,
                sharedDirectory: shared,
                folderPath: folderPath(session.cwd),
                lastActivity: [session.statusUpdatedAt, session.updatedAt].compactMap { $0 }.max() ?? session.startedAt
            ))
        }

        // The badge and the pill counts look at every row, unfiltered.
        let waiting = rows.filter { $0.status == .needsYou }
        var waitingByProfile: [String: Int] = [:]
        for row in waiting {
            if let id = row.profileID { waitingByProfile[id, default: 0] += 1 }
        }

        var pills = [AccountPillInfo(pill: .all, title: "All", needsYouCount: waiting.count, sharedDirectoryWith: [])]
        for profile in profiles {
            let others = (profilesByDirectory[profile.directory.standardizedFileURL.path] ?? [])
                .filter { $0.id != profile.id }
                .map(\.name)
            pills.append(AccountPillInfo(
                pill: .profile(profile.id),
                title: profile.name,
                needsYouCount: waitingByProfile[profile.id] ?? 0,
                sharedDirectoryWith: others
            ))
        }

        let selected: AccountPill
        switch pill {
        case .all: selected = .all
        case .profile(let id): selected = profiles.contains { $0.id == id } ? pill : .all
        }
        let visible = rows.filter { selected.includes(profileID: $0.profileID) }

        // Groups.
        var targetLabels: [String: String] = [:]
        var targetOrder: [String] = []
        for folder in folders {
            let path = folder.normalizedPath
            if targetLabels[path] == nil {
                targetLabels[path] = folder.label.isEmpty ? basename(path) : folder.label
                targetOrder.append(path)
            }
        }

        let needsYouRows = visible.filter { $0.status == .needsYou }.sorted(by: rowOrder)
        var byFolder: [String?: [SessionRow]] = [:]
        for row in visible where row.status != .needsYou {
            byFolder[row.folderPath, default: []].append(row)
        }

        var folderGroups: [SessionGroup] = []
        for path in targetOrder {
            guard let members = byFolder[path] else { continue }
            folderGroups.append(SessionGroup(
                id: "folder:\(path)",
                kind: .folder(path: path, isLaunchTarget: true),
                title: targetLabels[path] ?? basename(path),
                rows: members.sorted(by: rowOrder)
            ))
        }

        let others = byFolder.compactMap { path, members -> (path: String, rows: [SessionRow])? in
            guard let path, targetLabels[path] == nil else { return nil }
            return (path, members.sorted(by: rowOrder))
        }
        // A name shared by two folders (or by a folder and a target's label)
        // would leave two identical headings; those fall back to the path.
        var nameCounts: [String: Int] = [:]
        for label in targetOrder.compactMap({ targetLabels[$0] }) { nameCounts[label, default: 0] += 1 }
        for other in others { nameCounts[basename(other.path), default: 0] += 1 }
        let ordered = others.sorted {
            let lhs = $0.rows.map(\.lastActivity).max() ?? .distantPast
            let rhs = $1.rows.map(\.lastActivity).max() ?? .distantPast
            if lhs != rhs { return lhs > rhs }
            return $0.path < $1.path
        }
        for other in ordered {
            let name = basename(other.path)
            folderGroups.append(SessionGroup(
                id: "folder:\(other.path)",
                kind: .folder(path: other.path, isLaunchTarget: false),
                title: (nameCounts[name] ?? 0) > 1 ? (other.path as NSString).abbreviatingWithTildeInPath : name,
                rows: other.rows
            ))
        }

        if let members = byFolder[nil] {
            folderGroups.append(SessionGroup(
                id: "no-folder",
                kind: .folder(path: nil, isLaunchTarget: false),
                title: "No folder",
                rows: members.sorted(by: rowOrder)
            ))
        }

        return SessionSnapshot(
            pills: pills,
            selectedPill: selected,
            needsYouGroup: needsYouRows.isEmpty
                ? nil
                : SessionGroup(id: "needs-you", kind: .needsYou, title: "Needs you", rows: needsYouRows),
            folderGroups: folderGroups,
            badgeCount: waiting.count
        )
    }

    // MARK: - Pieces

    private struct TranscriptKey: Hashable {
        let directory: String
        let sessionId: String
    }

    /// The config directory a session's transcript is looked up under.
    private static func transcriptDirectory(of session: LiveSession) -> String? {
        session.configDirectory?.standardizedFileURL.path ?? session.key.configDirectory
    }

    /// The title the session's row shows, without building the whole
    /// snapshot: for a caller that names one session (a notification) and
    /// must agree with the row.
    public static func rowTitle(
        for session: LiveSession,
        transcripts: [TranscriptEntry],
        renames: [String: String]
    ) -> SessionTitle {
        let directory = transcriptDirectory(of: session)
        let entry = session.sessionId.flatMap { id in
            directory.flatMap { directory in
                transcripts.first {
                    $0.sessionId == id && $0.configDirectory.standardizedFileURL.path == directory
                }
            }
        }
        return title(for: session, entry: entry, renames: renames)
    }

    private static func basename(_ path: String) -> String {
        SessionRowWording.folderName(path) ?? path
    }

    private static func rowOrder(_ lhs: SessionRow, _ rhs: SessionRow) -> Bool {
        if lhs.status.urgencyRank != rhs.status.urgencyRank { return lhs.status.urgencyRank < rhs.status.urgencyRank }
        if lhs.lastActivity != rhs.lastActivity { return lhs.lastActivity > rhs.lastActivity }
        if lhs.live.pid != rhs.live.pid { return lhs.live.pid < rhs.live.pid }
        if lhs.key.procStart != rhs.key.procStart { return lhs.key.procStart < rhs.key.procStart }
        return (lhs.key.configDirectory ?? "") < (rhs.key.configDirectory ?? "")
    }

    /// R3, on top of U3's ladder rather than beside it: a rename, then what
    /// the agent recorded in the transcript (agent name, custom title, AI
    /// title, summary), then the name in the registry, and only then what U3
    /// falls back to (the first prompt or skill, the id prefix).
    ///
    /// The registry name sits above the prompt-derived rungs because it is
    /// Claude Code's own current name for the session, while a name made of
    /// the first thing typed is a guess; and it is the only name a session
    /// that has not written a transcript yet has. It is reported as an agent
    /// name, which is what it is.
    private static func title(for session: LiveSession, entry: TranscriptEntry?, renames: [String: String]) -> SessionTitle {
        guard let sessionId = session.sessionId, !sessionId.isEmpty else {
            // No id to look anything up or rename by: a scanned agent, named
            // for what it is.
            return SessionTitle(text: session.registryName.trimmedNonEmpty ?? session.agentDisplayName, source: .agentName)
        }
        // A rename is decided here, not left to U3's resolver, only because
        // the registry name below must not get in front of it.
        if let rename = renames[sessionId].trimmedNonEmpty { return SessionTitle(text: rename, source: .rename) }
        let fromTranscript = entry?.title()
        if let fromTranscript, isRecorded(fromTranscript.source) { return fromTranscript }
        if let name = session.registryName.trimmedNonEmpty { return SessionTitle(text: name, source: .agentName) }
        return fromTranscript ?? SessionTitles.resolve(sessionId: sessionId)
    }

    /// Sources that are something a person or the agent chose, as opposed to
    /// the fallbacks derived from a prompt or an id.
    private static func isRecorded(_ source: TitleSource) -> Bool {
        switch source {
        case .rename, .agentName, .customTitle, .aiTitle, .summary: return true
        case .firstPrompt, .skill, .sessionIdPrefix: return false
        }
    }
}
