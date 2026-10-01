// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// What a session id must look like before anything resumes it.
///
/// A session id ends up as one argv element of `claude --resume <id>`, typed
/// into a terminal, and is compared against the registry by the restore guard.
/// Both jobs want the same thing: the canonical form Claude Code itself writes,
/// a lowercase hyphenated UUID (`8-4-4-4-12` hex digits). Anything else — an
/// empty string, a path, a name, a shell metacharacter, an uppercase spelling
/// of the same UUID that the guard's exact comparison would not match against
/// a live row's lowercase one — is refused rather than repaired, so nothing odd
/// reaches a terminal and the guard can never be talked past by spelling.
public enum SessionIdentifier {
    /// Group lengths of the canonical form, in order.
    private static let groups = [8, 4, 4, 4, 12]

    public static func isValid(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == groups.count else { return false }
        for (part, length) in zip(parts, groups) {
            guard part.utf8.count == length, part.utf8.allSatisfy(isLowercaseHex) else { return false }
        }
        return true
    }

    private static func isLowercaseHex(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x61...0x66).contains(byte)
    }
}

/// Everything the restore guard looks at (KTD13).
///
/// A struct rather than a bare array so inputs are fields, added without
/// changing the guard's signature or any caller that builds one from the
/// registry alone. In its registry-only form it holds the running rows across
/// every profile: the reader already drops a dead pid, so a session whose only
/// registry file belongs to one is simply not in this list. `ledger` and `host`
/// add what AgentMenu itself knows: launches still waiting to register, and the
/// panes of the session host, which hold a session no registry row shows.
public struct RestoreGuardSnapshot: Equatable, Sendable {
    /// Live rows from every profile's registry, and from the process scan.
    public var liveSessions: [LiveSession]
    /// The session id of every live registry row, including the ones the
    /// display filter drops: an IDE or desktop host, a spare row, a parked job
    /// (`RegistryReader.liveSessionIDs`). A session here has no row to focus,
    /// but a second process on it would still corrupt its transcript.
    public var otherLiveSessionIDs: Set<String>
    /// Resumes typed into a terminal whose process has not registered yet
    /// (`InFlightResumes`).
    public var inFlight: Set<String>
    /// Every launch AgentMenu made (U11). Its rows add the launches still
    /// waiting to register (the plain `inFlight` set is for resumes typed into
    /// a terminal) and, with `host`, the sessions running in a pane.
    public var ledger: LaunchLedger
    /// The session host's panes and clients as of the last look; nil when it
    /// was not asked or no server answers, which reads as "no information".
    public var host: HostSnapshot?
    public var now: Date

    public init(
        liveSessions: [LiveSession] = [],
        otherLiveSessionIDs: Set<String> = [],
        inFlight: Set<String> = [],
        ledger: LaunchLedger = LaunchLedger(),
        host: HostSnapshot? = nil,
        now: Date = Date()
    ) {
        self.liveSessions = liveSessions
        self.otherLiveSessionIDs = otherLiveSessionIDs
        self.inFlight = inFlight
        self.ledger = ledger
        self.host = host
        self.now = now
    }
}

/// Why a resume was refused.
public enum RestoreRefusal: Equatable, Sendable {
    /// The id is empty or not a session id. It cannot be resumed safely, and
    /// there is nothing to focus instead.
    case invalidSessionID
    /// A live row already holds this session. Resuming it a second time would
    /// have two processes writing one transcript, so the caller focuses a row
    /// instead (R27). `focus` lists every matching row, in snapshot order: two
    /// rows can share an id (a forked or resumed session), and which one the
    /// user meant is the caller's call, not the guard's.
    case alreadyLive(focus: [LiveSessionKey])
    /// A live process holds this session, but under a registry row AgentMenu
    /// does not list (hosted by an IDE or the desktop app, or parked), so
    /// there is nothing to focus.
    case runningElsewhere
    /// A resume of this session was typed a moment ago and has not registered
    /// yet, or AgentMenu launched it and it has not registered yet.
    case launchInFlight
    /// An owned session is running under the session host with no window
    /// attached (the Detached marker). Resuming would start a second process
    /// on its transcript; the caller attaches a window to this tmux session
    /// instead (R27, AE2).
    case reattach(launchID: String)
}

public enum RestoreDecision: Equatable, Sendable {
    case allow
    case refuse(RestoreRefusal)

    public var isAllowed: Bool { self == .allow }

    /// The rows to bring forward instead, empty unless the session is live.
    public var focusKeys: [LiveSessionKey] {
        if case .refuse(.alreadyLive(let keys)) = self { return keys }
        return []
    }
}

/// One restore guard for every entry point (KTD13, R27): a History click, Reopen
/// all, Reopen last closed. A pure function over a snapshot, so every rule is
/// exercised without a process table behind it.
///
/// A session is refused when a displayed live row holds it (the caller focuses
/// that row, or, for an owned session with no window, reattaches it), when any
/// other live registry row holds it (`runningElsewhere`), when its own launch or
/// resume is still in flight, when a pane of the session host is running it
/// whatever the registry shows, or when a launch AgentMenu follows is running
/// it under a process the ledger has not seen end.
///
/// Session ids compare exactly, and every profile's rows count: a session that
/// is live under the Work account still blocks a resume started from the
/// Personal pill, because the transcript — not the account — is what a second
/// process would corrupt.
public enum RestoreGuard {
    public static func check(sessionID: String, snapshot: RestoreGuardSnapshot) -> RestoreDecision {
        guard SessionIdentifier.isValid(sessionID) else { return .refuse(.invalidSessionID) }

        var matches: [LiveSessionKey] = []
        for session in snapshot.liveSessions where session.sessionId == sessionID {
            if !matches.contains(session.key) { matches.append(session.key) }
        }
        if !matches.isEmpty {
            // Owned, hosted and with no client attached: there is no window to
            // focus, only a tmux session to attach to.
            for session in snapshot.liveSessions where session.sessionId == sessionID {
                if let info = snapshot.ledger.ownership(of: session, host: snapshot.host),
                   info.isDetached, let launchID = info.launchID {
                    return .refuse(.reattach(launchID: launchID))
                }
            }
            return .refuse(.alreadyLive(focus: matches))
        }
        if snapshot.otherLiveSessionIDs.contains(sessionID) { return .refuse(.runningElsewhere) }
        if snapshot.inFlight.contains(sessionID) || snapshot.ledger.inFlightSessionIDs(now: snapshot.now).contains(sessionID) {
            return .refuse(.launchInFlight)
        }
        // A pane that is running it, though no registry row says so (the
        // registry file is late, or was removed under a live process). Only
        // rows the ledger follows can be matched to a pane by session id.
        if let host = snapshot.host {
            for row in snapshot.ledger.rows where row.isActive && row.isHosted && heldIDs(of: row).contains(sessionID) {
                guard host.panes.contains(where: { $0.sessionName == row.launchID && !$0.isDead }) else { continue }
                // With a client attached there is a window, but no row to
                // focus it from: nothing to do but not start a second one.
                return .refuse(host.isDetached(row.launchID) ? .reattach(launchID: row.launchID) : .runningElsewhere)
            }
        }
        // A launch AgentMenu follows whose registry file is gone (removed under
        // a live process, or its profile no longer listed) and that no pane
        // accounts for: a plain launch has no pane at all. The ledger ends a
        // row only once its process (pid and start time) is no longer running,
        // so a row still active holds its session. A hosted row is judged by
        // its pane when the host was looked at: no live pane there means the
        // process went with its tmux session. There is no row to focus.
        for row in snapshot.ledger.liveOwnedRows where !row.isHosted || snapshot.host == nil {
            if heldIDs(of: row).contains(sessionID) { return .refuse(.runningElsewhere) }
        }
        return .allow
    }

    /// The session ids a ledger row's agent holds: the latest it was seen
    /// with, else the one it was pinned or resumed to. A live row's pinned id
    /// is not held once `/clear` has replaced it.
    private static func heldIDs(of row: LedgerRow) -> Set<String> {
        var ids = Set<String>()
        if let last = row.lastSessionID { ids.insert(last) }
        if row.phase != .live || row.lastSessionID == nil { ids.insert(row.pinnedOrResumedID) }
        return ids
    }
}
