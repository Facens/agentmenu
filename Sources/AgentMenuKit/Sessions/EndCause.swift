// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Why an owned session ended, as far as AgentMenu knows (KTD12): the one
/// vocabulary the launch ledger's `end_cause` slot is written in, by U12 for
/// the quits AgentMenu causes itself and by U13 for everything it works out
/// afterwards.
///
/// Persisted as its `rawValue`. Reading is tolerant: a string this build does
/// not know (written by a newer build, or by an older one before this type
/// existed) is kept verbatim as `.unrecognised` and written back as it was, so
/// a rewrite of the row never loses it.
///
/// Recording a cause marks intent. It is not the end: when the session ended
/// is `LedgerRow.endedAt`, which only `LaunchLedger.reconcile` sets, from what
/// it sees.
public enum EndCause: Equatable, Hashable, Sendable {
    /// Quit from AgentMenu, on that one session (U12). Goes to the closed
    /// stack.
    case individual
    /// Quit all, or the power-off notification recording the whole live
    /// owned set at once (U12, U13). Goes to the pending reopen set.
    case together
    /// The session host's tmux server died with the session in it (U13).
    case hostDied
    /// Logout or shutdown, or a boot id that changed (U13).
    case powerOff
    /// Gone while AgentMenu was not running, with nothing to explain it
    /// (U13).
    case unexplained
    /// The agent's own `/exit`, or its window closed with keep-running off,
    /// seen while AgentMenu ran (U13). Goes to the closed stack.
    case exited
    /// A stored string this build does not know, kept as it was.
    case unrecognised(String)

    public init(rawValue: String) {
        switch rawValue {
        case "individual": self = .individual
        case "together": self = .together
        case "host-died": self = .hostDied
        case "power-off": self = .powerOff
        case "unexplained": self = .unexplained
        case "exited": self = .exited
        default: self = .unrecognised(rawValue)
        }
    }

    public var rawValue: String {
        switch self {
        case .individual: return "individual"
        case .together: return "together"
        case .hostDied: return "host-died"
        case .powerOff: return "power-off"
        case .unexplained: return "unexplained"
        case .exited: return "exited"
        case .unrecognised(let raw): return raw
        }
    }
}
