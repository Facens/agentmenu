// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// The journal's event vocabulary (KTD3).
///
/// A closed enum rather than free strings, because a scenario waits on an
/// event by name (`harness/guest/wait.sh --event "setup shown"`) and a typo in
/// a name is indistinguishable from a step that never happened — the scenario
/// simply times out, and the report blames the app. The raw values are the
/// names the plan writes, spaces and all, so the vocabulary in the plan, in a
/// scenario and in the journal are one string.
///
/// This is AgentMenu's half of KTD3's list. MeetingHop's events (`card shown`,
/// `join fired`, …) live in that app; the two never share a process.
public enum JournalEvent: String, CaseIterable, Sendable {
    /// The first line of every run: the fixture echo and the boot counter.
    case harnessStarted = "harness started"
    case detectingStarted = "detecting started"
    case detectingFinished = "detecting finished"
    case setupShown = "setup shown"
    case setupFinished = "setup finished"
    /// The launch-at-login question's own answer, once — from the setup
    /// card's checkbox on a fresh install, or from `LaunchAtLoginPrompt`'s
    /// one-shot alert on an install that already finished first run before
    /// the question existed. Fires on the one transition that matters:
    /// `launch_at_login_asked` going from unset/false to true.
    case launchAtLoginAsked = "launch at login asked"
    case launchRequested = "launch requested"
    case launchResult = "launch result"
    case bridgeInstalled = "bridge installed"
    /// Not in KTD3's list of end states, but R13 asks for the state the app is
    /// in, and "the configuration could not be written" is the one failure
    /// that makes every later assertion meaningless.
    case saveFailed = "save failed"
    /// A live session appeared in the registry or the process scan (KTD16).
    /// Payload: `JournalData.sessionSeen`.
    case sessionSeen = "session seen"
    /// A live session's status changed. Payload: `JournalData.sessionStatusChanged`.
    case sessionStatusChanged = "session status changed"
    /// A restore ended, in a launch or a refusal. Payload: `JournalData.restoreResult`.
    case restoreResult = "restore result"
    /// The Needs-you count the menu-bar item draws changed, including its
    /// first reading. Payload: `JournalData.badgeChanged`.
    case badgeChanged = "badge changed"
    /// A click on a live row (or a notification, or the restore guard's
    /// "already running" answer) tried to bring a terminal forward and ended.
    /// Payload: `JournalData.focusResult`.
    case focusResult = "focus result"
    /// AgentMenu asked its own session host to start a session for a launch
    /// (KTD16, U11). Payload: `JournalData.hostLaunch`.
    case hostLaunch = "host launch"
    /// A Reopen all finished (U14): how many it tried and how they went.
    /// Payload: `JournalData.reopenAll`.
    case reopenAll = "reopen all"
}

/// A value a journal line can carry.
///
/// A closed set rather than `Any`, so a line is JSON by construction: there is
/// no way to hand the writer a value that serialises to something else, or to
/// nothing, half way through a run. `JournalData` and the app's taps build
/// their payloads out of these.
public enum JournalValue: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case boolean(Bool)
    case list([JournalValue])
    case object([String: JournalValue])

    /// A single value is truncated at this length. The journal has a fixed
    /// size cap and drops the oldest lines to stay under it, so one unbounded
    /// string — an error message that quotes a whole file, say — would evict
    /// the run's own history to make room for itself. Long enough for any
    /// path this app handles.
    public static let maximumStringLength = 512

    /// The Foundation value `JSONSerialization` accepts. Strings are truncated
    /// here rather than at each call site, so the rule holds for every payload
    /// including the ones a later unit adds.
    var jsonObject: Any {
        switch self {
        case .string(let value):
            guard value.count > Self.maximumStringLength else { return value }
            return String(value.prefix(Self.maximumStringLength - 1)) + "…"
        case .integer(let value):
            return value
        case .boolean(let value):
            return value
        case .list(let values):
            return values.map(\.jsonObject)
        case .object(let values):
            return values.mapValues(\.jsonObject)
        }
    }
}

/// Payloads whose shape is a rule rather than a convenience.
///
/// `launch requested` is the one event that sees a command about to be run,
/// and KTD3 is explicit that it records the *names* of the environment
/// variables the command sets and never their values — `CLAUDE_CONFIG_DIR`
/// names an account, and an agent manifest is free to put anything else in
/// there. Building that payload in the Kit rather than in the app's tap is
/// what makes the rule testable: the app target is not linked into the test
/// suite, the Kit is.
public enum JournalData {
    /// The command-derived half of `launch requested`: what will run, where,
    /// and which variables are set — never with what. The argument vector is
    /// deliberately absent too; KTD3 names three fields and this writes three.
    public static func launchRequested(command: LaunchCommand) -> [String: JournalValue] {
        [
            "binary": .string(command.executable),
            "directory": .string(command.workingDirectory),
            "env": .list(command.environment.keys.sorted().map(JournalValue.string)),
        ]
    }

    // MARK: Sessions (KTD16)
    //
    // A session's title is the user's own words, its folder is a path, and its
    // argv is a command line. None of them belongs in a journal that a leaked
    // harness directory would expose, so these payloads are built from the
    // row's identity and closed vocabularies only: the hashed key (the same
    // hash the row's accessibility identifier carries), the agent id, the
    // profile id, and status values.

    public static func sessionSeen(_ session: LiveSession) -> [String: JournalValue] {
        var data: [String: JournalValue] = [
            "key": .string(AccessibilityID.Popover.Sessions.liveRowKey(session.key)),
            "agent": .string(session.agentID),
            "status": .string(session.status.rawValue),
        ]
        if let profile = session.profileID { data["profile"] = .string(profile) }
        return data
    }

    public static func sessionStatusChanged(_ session: LiveSession, from previous: SessionStatus) -> [String: JournalValue] {
        var data = sessionSeen(session)
        data["status"] = nil
        data["from"] = .string(previous.rawValue)
        data["to"] = .string(session.status.rawValue)
        return data
    }

    /// What the menu-bar item is drawing beside its glyph: the number of
    /// sessions waiting on the user, 0 when no badge is drawn.
    public static func badgeChanged(count: Int) -> [String: JournalValue] {
        ["count": .integer(count)]
    }

    /// How a focus attempt ended, for the row it was made on. The outcome and
    /// the reason are closed vocabularies: a `FocusOutcome` carries a terminal's
    /// display name and, for `failed`, the text `osascript` printed, and
    /// neither is journalled. The row is named by the hash its accessibility
    /// identifier carries, so a tty, a path or a title never reaches the file.
    public static func focusResult(key: LiveSessionKey, outcome: FocusOutcome) -> [String: JournalValue] {
        var data: [String: JournalValue] = [
            "key": .string(AccessibilityID.Popover.Sessions.liveRowKey(key)),
            "ok": .boolean(outcome.isFocused),
        ]
        switch outcome {
        case .focused:
            data["outcome"] = .string("focused")
        case .unavailable(let reason):
            data["outcome"] = .string("unavailable")
            switch reason {
            case .noTTY: data["reason"] = .string("noTTY")
            case .unrecognisedTerminal: data["reason"] = .string("unrecognisedTerminal")
            case .terminalCannotFocus: data["reason"] = .string("terminalCannotFocus")
            }
        case .notRunning:
            data["outcome"] = .string("notRunning")
        case .windowGone:
            data["outcome"] = .string("windowGone")
        case .automationDenied:
            data["outcome"] = .string("automationDenied")
        case .failed:
            data["outcome"] = .string("failed")
        }
        return data
    }

    /// A hosted launch's host call: which launch (the hash a Starting row's
    /// identifier carries), which terminal it was opened in, and whether the
    /// host created the session. Never the command, the argv, a path or an
    /// error's text.
    public static func hostLaunch(launchID: String, terminal: String, ok: Bool) -> [String: JournalValue] {
        [
            "launch": .string(AccessibilityID.Popover.Sessions.pendingRowKey(launchID: launchID)),
            "terminal": .string(terminal),
            "ok": .boolean(ok),
        ]
    }

    /// How a Reopen all went, as counts only: no title, path or session id
    /// (the per-session outcomes are `restore result` events).
    public static func reopenAll(total: Int, reopened: Int, failed: Int) -> [String: JournalValue] {
        [
            "total": .integer(total),
            "reopened": .integer(reopened),
            "failed": .integer(failed),
        ]
    }

    /// How a restore ended. A closed set: an error's own text can carry a
    /// path, so a failure is recorded as `failed` and never with its message.
    public enum RestoreOutcome: String, CaseIterable, Sendable {
        case launched
        /// The guard found the session already live and focused it instead.
        case focusedLive = "focused live"
        /// The guard found the session running where AgentMenu has no row to
        /// focus, or its own resume still in flight, and launched nothing.
        case alreadyRunning = "already running"
        case invalidSession = "invalid session"
        case notRestorable = "not restorable"
        case unknownProfile = "unknown profile"
        case agentUnavailable = "agent unavailable"
        case failed
    }

    /// `session` is the session id hashed the way a closed row's identifier is.
    public static func restoreResult(sessionID: String, outcome: RestoreOutcome) -> [String: JournalValue] {
        [
            "session": .string(AccessibilityID.Popover.Sessions.closedRowKey(sessionID: sessionID)),
            "outcome": .string(outcome.rawValue),
            "ok": .boolean(outcome == .launched || outcome == .focusedLive),
        ]
    }
}
