// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

// Ending a session (U12, KTD11): SIGINT, then SIGTERM after five seconds,
// never SIGKILL. Both let Claude Code finish its transcript; SIGKILL would
// not. The cause is written to the ledger before the first signal, so what
// follows never has to guess why a session went.

/// The only signals a quit can send. There is no case for SIGKILL: sending one
/// is not something a caller can ask for.
public enum QuitSignal: Equatable, Sendable {
    case interrupt
    case terminate

    public var number: Int32 {
        switch self {
        case .interrupt: return SIGINT
        case .terminate: return SIGTERM
        }
    }
}

public enum QuitSendResult: Equatable, Sendable {
    case sent
    /// ESRCH: the process ended between the decision and the signal. Already
    /// done, not a failure.
    case noSuchProcess
    /// Anything else (EPERM: not ours to signal), with the system's words.
    case failed(String)
}

/// The two things a quit asks the system, behind a protocol so a test hands it
/// a recorder instead of a process.
public protocol QuitSignalling: Sendable {
    /// Whether the process that was registered under `key` is still running:
    /// the pid is alive and its start time is the recorded one. A pid the
    /// system has since given to another process is not it (KTD7).
    func isSameProcessRunning(_ key: LiveSessionKey) -> Bool
    func send(_ signal: QuitSignal, to pid: Int32) -> QuitSendResult
}

/// The real thing: `kill(2)` and the kernel's process table.
public struct SystemQuitSignaller: QuitSignalling {
    public init() {}

    public func isSameProcessRunning(_ key: LiveSessionKey) -> Bool {
        ProcessLiveness.isSameProcessRunning(key)
    }

    public func send(_ signal: QuitSignal, to pid: Int32) -> QuitSendResult {
        // `kill` with 0 or a negative pid addresses a whole process group or
        // every process the user owns, and pid 1 is launchd. None is a
        // session; never ask.
        guard pid > 1, pid != getpid() else { return .failed("not a session's process") }
        if kill(pid, signal.number) == 0 { return .sent }
        let code = errno
        if code == ESRCH { return .noSuchProcess }
        return .failed(String(cString: strerror(code)))
    }
}

/// What a quit did for one session.
public enum QuitOutcome: Equatable, Sendable {
    /// SIGINT was sent; the session is now Quitting.
    case interrupted
    /// The process was already gone (or the pid is another process's by now),
    /// so nothing was signalled. Not an error.
    case alreadyEnded
    /// A quit for it is already under way.
    case alreadyQuitting
    case failed(String)
}

/// What one `tick` found.
public struct QuitTick: Equatable, Sendable {
    /// Sessions that ignored SIGINT for the grace period and were sent SIGTERM.
    public var escalated: [LiveSessionKey] = []
    /// Sessions whose process has ended.
    public var finished: [LiveSessionKey] = []
    /// Sessions still running well after SIGTERM, which are left alone and no
    /// longer shown as Quitting.
    public var gaveUp: [LiveSessionKey] = []

    public var isEmpty: Bool { escalated.isEmpty && finished.isEmpty && gaveUp.isEmpty }
}

/// Sends the quits and follows them until the process ends.
///
/// Holds no timer: the caller calls `tick()` (once a second is plenty) while
/// `isQuitting` and the injected clock says when SIGTERM is due. That keeps the
/// five seconds testable without waiting for them.
///
/// Safe from any thread: one lock guards the pending set. The store's own lock
/// is taken inside it, never the other way round.
public final class SessionQuitter: @unchecked Sendable {
    /// KTD11.
    public static let escalationDelay: TimeInterval = 5
    /// A process that is still running this long after SIGINT is left alone:
    /// it is not going to be killed, and a row dimmed for ever is a lie.
    public static let giveUpDelay: TimeInterval = 30

    private struct Pending {
        let interruptedAt: Date
        var terminated = false
        /// What was recorded in the ledger for it, to take back if it never
        /// ends.
        let recordedCause: EndCause?
    }

    private let store: SessionStore
    private let signaller: QuitSignalling
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var pending: [LiveSessionKey: Pending] = [:]

    public init(store: SessionStore, signaller: QuitSignalling = SystemQuitSignaller(), now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.signaller = signaller
        self.now = now
    }

    /// The sessions a quit is under way for.
    public var quitting: Set<LiveSessionKey> {
        lock.lock()
        defer { lock.unlock() }
        return Set(pending.keys)
    }

    public var isQuitting: Bool { !quitting.isEmpty }

    /// Quits the plan's targets.
    ///
    /// 1. A target whose process is no longer running is `alreadyEnded` and
    ///    nothing is recorded for it: a session that went by itself is not one
    ///    AgentMenu quit.
    /// 2. The cause is recorded for every remaining owned target in one write.
    ///    An unowned one has no row and records nothing. A store that cannot be
    ///    written does not stop the quit: the user asked for it, and the
    ///    classification falls back to what is seen.
    /// 3. Only then is SIGINT sent, to each.
    @discardableResult
    public func quit(_ plan: QuitPlan) -> [LiveSessionKey: QuitOutcome] {
        lock.lock()
        defer { lock.unlock() }

        var outcomes: [LiveSessionKey: QuitOutcome] = [:]
        var toSignal: [QuitCandidate] = []
        for target in plan.targets {
            if pending[target.key] != nil {
                outcomes[target.key] = .alreadyQuitting
            } else if !signaller.isSameProcessRunning(target.key) {
                outcomes[target.key] = .alreadyEnded
            } else {
                toSignal.append(target)
            }
        }

        // Only a target with a live ledger row is recorded: an owned session
        // known by its pane alone has no row to write to.
        let started = now()
        let owned = toSignal.filter(\.isOwned).map(\.key)
        var recorded = Set<LiveSessionKey>()
        if !owned.isEmpty {
            do {
                try store.updateLedger { ledger in
                    ledger.recordCause(plan.cause, for: owned, at: started)
                }
                let rows = store.ledger.rows
                recorded = Set(owned.filter { key in
                    rows.contains { $0.isActive && $0.liveKey == key && $0.endCause == plan.cause }
                })
            } catch {
                // The quit goes ahead without it.
            }
        }

        for target in toSignal {
            switch signaller.send(.interrupt, to: target.key.pid) {
            case .sent:
                pending[target.key] = Pending(
                    interruptedAt: started,
                    recordedCause: recorded.contains(target.key) ? plan.cause : nil
                )
                outcomes[target.key] = .interrupted
            case .noSuchProcess:
                outcomes[target.key] = .alreadyEnded
            case .failed(let reason):
                outcomes[target.key] = .failed(reason)
                // Nothing was signalled, so nothing ends: take the intent back.
                if recorded.contains(target.key) { clearCause(plan.cause, for: target.key) }
            }
        }
        return outcomes
    }

    /// Moves every quit along: finished ones are dropped; one that ignored
    /// SIGINT for five seconds is sent SIGTERM; one still running after the
    /// give-up delay is released. The process is looked up by (pid, start time)
    /// each time, so a pid reused by a stranger is never signalled.
    @discardableResult
    public func tick() -> QuitTick {
        lock.lock()
        defer { lock.unlock() }

        var result = QuitTick()
        let current = now()
        for (key, state) in pending {
            guard signaller.isSameProcessRunning(key) else {
                pending[key] = nil
                result.finished.append(key)
                continue
            }
            let elapsed = current.timeIntervalSince(state.interruptedAt)
            if elapsed >= Self.giveUpDelay {
                pending[key] = nil
                result.gaveUp.append(key)
                if let cause = state.recordedCause { clearCause(cause, for: key) }
            } else if elapsed >= Self.escalationDelay, !state.terminated {
                var next = state
                next.terminated = true
                pending[key] = next
                switch signaller.send(.terminate, to: key.pid) {
                case .sent, .failed: result.escalated.append(key)
                case .noSuchProcess:
                    pending[key] = nil
                    result.finished.append(key)
                }
            }
        }
        return result
    }

    private func clearCause(_ cause: EndCause, for key: LiveSessionKey) {
        try? store.updateLedger { $0.clearCause(cause, for: key) }
    }
}
