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
    case launchRequested = "launch requested"
    case launchResult = "launch result"
    case bridgeInstalled = "bridge installed"
    /// Not in KTD3's list of end states, but R13 asks for the state the app is
    /// in, and "the configuration could not be written" is the one failure
    /// that makes every later assertion meaningless.
    case saveFailed = "save failed"
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
}
