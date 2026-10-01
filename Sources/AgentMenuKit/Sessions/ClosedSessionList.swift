// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The recency buckets of the Closed view (R29).
public enum RecencySection: Int, CaseIterable, Comparable {
    case today, yesterday, last7Days, older

    public var title: String {
        switch self {
        case .today: return "Today"
        case .yesterday: return "Yesterday"
        case .last7Days: return "Last 7 days"
        case .older: return "Older"
        }
    }

    public static func < (lhs: RecencySection, rhs: RecencySection) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Buckets a modification time against an injected clock and calendar, so
    /// a test fixes both. "Last 7 days" is the six days before yesterday, so
    /// the buckets never overlap: today, yesterday, then two to seven days ago.
    /// A time in the future (clock skew) counts as today.
    public static func section(for date: Date, now: Date, calendar: Calendar) -> RecencySection {
        Boundaries(now: now, calendar: calendar).section(for: date)
    }

    /// The day boundaries for one clock reading, worked out once so a list
    /// of many entries does not redo the calendar arithmetic for each.
    struct Boundaries {
        let startOfToday: Date
        /// Nil, like `startOfWeek`, when the calendar cannot answer; every
        /// time before today is then Older.
        let startOfYesterday: Date?
        let startOfWeek: Date?

        init(now: Date, calendar: Calendar) {
            startOfToday = calendar.startOfDay(for: now)
            startOfYesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday)
            startOfWeek = calendar.date(byAdding: .day, value: -7, to: startOfToday)
        }

        func section(for date: Date) -> RecencySection {
            if date >= startOfToday { return .today }
            guard let startOfYesterday, let startOfWeek else { return .older }
            if date >= startOfYesterday { return .yesterday }
            if date >= startOfWeek { return .last7Days }
            return .older
        }
    }
}

/// One past session as the Closed list presents it.
public struct ClosedSession: Equatable, Identifiable {
    public let entry: TranscriptEntry
    public let title: SessionTitle
    /// Whether AgentMenu launched it. Only unowned runs fold.
    public let isOwned: Bool

    public var id: String { entry.sessionId }
    public var name: String { title.text }
}

/// Unowned runs of one skill in one folder, folded into a single collapsed row.
public struct SkillFold: Equatable, Identifiable {
    public let skill: String
    public let cwd: String?
    /// Newest first.
    public let sessions: [ClosedSession]

    public var count: Int { sessions.count }
    public var id: String { "\(skill)\u{0}\(cwd ?? "")" }
}

public enum ClosedRow: Equatable, Identifiable {
    case session(ClosedSession)
    case fold(SkillFold)

    public var id: String {
        switch self {
        case .session(let session): return session.id
        case .fold(let fold): return "fold:" + fold.id
        }
    }

    /// The newest transcript the row stands for; rows sort by it.
    public var modified: Date {
        switch self {
        case .session(let session): return session.entry.modified
        case .fold(let fold): return fold.sessions.first?.entry.modified ?? .distantPast
        }
    }
}

public struct ClosedSection: Equatable {
    public let section: RecencySection
    public let rows: [ClosedRow]
}

/// Turns indexed transcripts into the Closed view: which sessions belong in it,
/// what each is called, how they group, and what a search leaves.
public enum ClosedSessionList {
    /// - Parameters:
    ///   - live: session ids the registry reports as running, including rows
    ///     the Live view does not show, plus resumes still in flight. They
    ///     belong in Live, not here (AE3), and reappear once the id leaves
    ///     this set.
    ///   - owned: session ids AgentMenu launched. Empty until ownership exists.
    ///   - renames: names set in AgentMenu, by session id; they win over every
    ///     recorded title.
    ///   - search: matched against each session's name and folder.
    public static func build(
        entries: [TranscriptEntry],
        live: Set<String> = [],
        owned: Set<String> = [],
        renames: [String: String] = [:],
        search: String? = nil,
        now: Date,
        calendar: Calendar = .current
    ) -> [ClosedSection] {
        var sessions: [ClosedSession] = []
        for entry in entries {
            if live.contains(entry.sessionId) { continue }
            // R28: sessions hosted by an SDK, IDE or desktop app are not the
            // user's to resume from a terminal. A transcript that carries no
            // entrypoint predates the field and is treated as a CLI session.
            if let entrypoint = entry.entrypoint, entrypoint != "cli" { continue }
            sessions.append(ClosedSession(
                entry: entry,
                title: entry.title(rename: renames[entry.sessionId]),
                isOwned: owned.contains(entry.sessionId)
            ))
        }

        let tokens = (search ?? "").split(whereSeparator: \.isWhitespace).map(String.init)
        let searching = !tokens.isEmpty
        if searching {
            sessions = sessions.filter { matches($0, tokens: tokens) }
        }
        sessions.sort {
            $0.entry.modified != $1.entry.modified
                ? $0.entry.modified > $1.entry.modified
                : $0.id < $1.id
        }

        let boundaries = RecencySection.Boundaries(now: now, calendar: calendar)
        var bySection: [RecencySection: [ClosedSession]] = [:]
        for session in sessions {
            let section = boundaries.section(for: session.entry.modified)
            bySection[section, default: []].append(session)
        }

        return RecencySection.allCases.compactMap { section in
            guard let members = bySection[section], !members.isEmpty else { return nil }
            // A search finds runs one by one (R29): folding would hide the very
            // run being looked for behind a count.
            let rows = searching ? members.map(ClosedRow.session) : fold(members)
            return ClosedSection(section: section, rows: rows)
        }
    }

    /// Every whitespace-separated token of the query must appear, ignoring case
    /// and diacritics, in the name or in the folder path.
    static func matches(_ session: ClosedSession, tokens: [String]) -> Bool {
        let haystacks = [session.name, session.entry.cwd ?? ""]
        return tokens.allSatisfy { token in
            haystacks.contains { $0.range(of: token, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }
    }

    /// Folds unowned bare skill runs, per skill and folder, into one row each.
    /// A skill run once in a folder stays a plain row: "collect-invoices (1)"
    /// hides a click for no saving. Input is newest first and so is the output,
    /// with a fold placed where its newest run would have been.
    private static func fold(_ sessions: [ClosedSession]) -> [ClosedRow] {
        struct Key: Hashable { let skill: String; let cwd: String? }
        func key(_ session: ClosedSession) -> Key? {
            guard !session.isOwned, let skill = session.entry.skill, skill.isBare else { return nil }
            return Key(skill: skill.name, cwd: session.entry.cwd)
        }

        var groups: [Key: [ClosedSession]] = [:]
        for session in sessions {
            if let key = key(session) { groups[key, default: []].append(session) }
        }

        var rows: [ClosedRow] = []
        var placed = Set<Key>()
        for session in sessions {
            guard let key = key(session), let group = groups[key], group.count > 1 else {
                rows.append(.session(session))
                continue
            }
            if placed.insert(key).inserted {
                rows.append(.fold(SkillFold(skill: key.skill, cwd: key.cwd, sessions: group)))
            }
        }
        return rows
    }
}
