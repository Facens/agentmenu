// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Resumes whose command has been typed but whose process has not yet written
/// its registry file (R27, KTD13).
///
/// There is a gap between a click that types `claude --resume <id>` and the new
/// process appearing in the registry; a second click on a Closed row that is
/// still listed would fall into it and start a second process on one
/// transcript. An id stays here until it shows up in the live set, which is the
/// registry taking over, or until `expiry` passes, which is a launch that never
/// came up (the command failed, or the user closed the tab).
///
/// A pure value over an injected clock: `ids(now:)` never reports an expired
/// id even if nothing has pruned it.
public struct InFlightResumes: Equatable, Sendable {
    /// How long an unregistered launch still counts as running.
    public static let expiry: TimeInterval = 30

    private var started: [String: Date] = [:]

    public init() {}

    /// Records a launch that has just been typed.
    public mutating func begin(_ sessionID: String, now: Date) {
        started[sessionID] = now
    }

    /// Drops the ids that are live now and those past `expiry`.
    public mutating func prune(live: Set<String>, now: Date) {
        started = started.filter { id, at in !live.contains(id) && Self.isFresh(at, now: now) }
    }

    /// The ids still in flight at `now`.
    public func ids(now: Date) -> Set<String> {
        Set(started.filter { Self.isFresh($0.value, now: now) }.keys)
    }

    public var isEmpty: Bool { started.isEmpty }

    /// A clock that stepped backwards leaves the launch in flight, which is
    /// the safe side.
    private static func isFresh(_ at: Date, now: Date) -> Bool {
        now.timeIntervalSince(at) < expiry
    }
}
