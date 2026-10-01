// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// One line of the Sessions list, flattened.
///
/// The Launch list can size itself as "rows × 30 pt" because every row there
/// is one fixed height. A grouped list cannot: it has headers and two kinds of
/// row, and a folded run hides children behind a click. Flattening it into
/// items that each know their own height keeps the popover's list sizing a sum
/// the view does not have to measure — which is what lets a `ScrollView`,
/// which takes whatever height it is offered, be given exactly its content's
/// height, capped (R29, R38).
public enum SessionsListItem: Equatable, Identifiable {
    /// A group's heading: "Needs you", or a folder.
    case groupHeader(id: String, title: String, count: Int, isNeedsYou: Bool)
    case live(SessionRow)
    case pending(PendingLaunch)
    /// A recency heading in the Closed view: Today, Yesterday, …
    case sectionHeader(RecencySection)
    case closed(ClosedSession, indented: Bool)
    case fold(SkillFold, expanded: Bool)

    public var id: String {
        switch self {
        case .groupHeader(let id, _, _, _): return "group:" + id
        case .live(let row): return "live:" + AccessibilityID.Popover.Sessions.liveRowKey(row.key)
        case .pending(let launch): return "pending:" + launch.id
        case .sectionHeader(let section): return "section:\(section.rawValue)"
        // The transcript's own path, not the session id: one id can have a
        // transcript under each of two accounts, and two rows with one
        // identity make a `ForEach` draw one of them twice. Never shown, and
        // never used as an accessibility identifier.
        case .closed(let session, _): return "closed:" + session.entry.transcriptURL.path
        case .fold(let fold, _): return "fold:" + fold.id
        }
    }

    public var height: Double {
        switch self {
        case .groupHeader, .sectionHeader: return SessionsListLayout.headerHeight
        case .live: return SessionsListLayout.liveRowHeight
        case .pending(let launch):
            if case .failedToStart = launch.phase { return SessionsListLayout.failedRowHeight }
            return SessionsListLayout.liveRowHeight
        case .closed(_, let indented):
            return indented ? SessionsListLayout.foldedChildHeight : SessionsListLayout.closedRowHeight
        case .fold: return SessionsListLayout.closedRowHeight
        }
    }
}

/// The Sessions list's items, and how tall they add up to.
public enum SessionsListLayout {
    // Points. A live row is two lines (name and status, then folder, account,
    // terminal and age); a closed row is two lines too, a little tighter.
    public static let headerHeight: Double = 26
    public static let liveRowHeight: Double = 48
    /// A failed launch carries its reason on up to two more lines, then
    /// Retry and Dismiss.
    public static let failedRowHeight: Double = 80
    public static let closedRowHeight: Double = 44
    public static let foldedChildHeight: Double = 40
    /// The tallest the list grows before it scrolls. The popover is also
    /// capped against the screen by its chrome, and this leaves room for it.
    public static let maxHeight: Double = 340
    /// The floor, so a one-row list is not a sliver.
    public static let minHeight: Double = 48

    public static func contentHeight(_ items: [SessionsListItem]) -> Double {
        items.reduce(0) { $0 + $1.height }
    }

    /// The height the list's `ScrollView` is given: its content's, capped.
    public static func listHeight(_ items: [SessionsListItem], cap: Double = maxHeight) -> Double {
        min(max(contentHeight(items), minHeight), cap)
    }

    // MARK: Live

    /// The live list: each snapshot group under its heading, with any owned
    /// launches that have no row yet placed in the group of their folder.
    ///
    /// A pending launch belongs to the group its folder would have. When no
    /// such group exists yet it gets one of its own, placed before the
    /// "No folder" group so that stays last. A pending launch under another
    /// account than the selected pill is left out, like a row would be.
    public static func liveItems(snapshot: SessionSnapshot, pending: [PendingLaunch] = []) -> [SessionsListItem] {
        let shown = pending.filter { snapshot.selectedPill.includes(profileID: $0.profileID) }
        var remaining = shown

        func takePending(forFolder path: String?) -> [PendingLaunch] {
            let mine = remaining.filter { $0.folderPath == path }
            remaining.removeAll { $0.folderPath == path }
            return mine
        }

        var items: [SessionsListItem] = []
        var pendingOnlyInserted = false

        // Groups for folders the snapshot has none of, each holding the
        // launches that are starting there.
        func appendPendingOnlyGroups() {
            guard !pendingOnlyInserted else { return }
            pendingOnlyInserted = true
            var paths: [String] = []
            for launch in remaining {
                if let path = launch.folderPath, !paths.contains(path) { paths.append(path) }
            }
            for path in paths {
                let members = takePending(forFolder: path)
                items.append(.groupHeader(
                    id: "folder:\(path)",
                    title: folderTitle(path),
                    count: members.count,
                    isNeedsYou: false
                ))
                items.append(contentsOf: members.map(SessionsListItem.pending))
            }
        }

        for group in snapshot.groups {
            var folderPath: String?
            var isFolder = false
            if case .folder(let path, _) = group.kind {
                folderPath = path
                isFolder = true
            }
            // The "No folder" group is last; launches for folders the list
            // has no group for come before it.
            if isFolder, folderPath == nil { appendPendingOnlyGroups() }

            let mine = isFolder && folderPath != nil ? takePending(forFolder: folderPath) : []
            items.append(.groupHeader(
                id: group.id,
                title: group.title,
                count: group.rows.count + mine.count,
                isNeedsYou: group.kind == .needsYou
            ))
            items.append(contentsOf: mine.map(SessionsListItem.pending))
            items.append(contentsOf: group.rows.map(SessionsListItem.live))
        }
        appendPendingOnlyGroups()

        // A launch with no folder at all, and no "No folder" group to join.
        let folderless = takePending(forFolder: nil)
        if !folderless.isEmpty {
            items.append(.groupHeader(id: "no-folder", title: "No folder", count: folderless.count, isNeedsYou: false))
            items.append(contentsOf: folderless.map(SessionsListItem.pending))
        }
        return items
    }

    // MARK: Closed

    /// The Closed list: recency headings, rows, and — for a fold the user has
    /// opened — its runs indented beneath it.
    public static func closedItems(sections: [ClosedSection], expandedFolds: Set<String> = []) -> [SessionsListItem] {
        var items: [SessionsListItem] = []
        for section in sections {
            items.append(.sectionHeader(section.section))
            for row in section.rows {
                switch row {
                case .session(let session):
                    items.append(.closed(session, indented: false))
                case .fold(let fold):
                    let expanded = expandedFolds.contains(fold.id)
                    items.append(.fold(fold, expanded: expanded))
                    if expanded {
                        items.append(contentsOf: fold.sessions.map { SessionsListItem.closed($0, indented: true) })
                    }
                }
            }
        }
        return items
    }

    private static func folderTitle(_ path: String?) -> String {
        SessionRowWording.folderName(path) ?? "No folder"
    }
}
