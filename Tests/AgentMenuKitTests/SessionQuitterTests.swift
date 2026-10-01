// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation
import AgentMenuKit

// Ending sessions (U12, KTD11): the cause is written before the signal, SIGTERM
// follows an ignored SIGINT after five seconds, SIGKILL is never sent, an
// unowned row is signalled and recorded nowhere, and a pid that is not the
// session's any more is never touched. A fake signaller and a fake clock stand
// in for the system; the end-to-end cases signal only children the test spawns.

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
private let directory = "/profiles/work"
private let launchA = "5d1c7e0a-3b6e-4d7a-9c21-0e0b7a4d1f33"
private let launchB = "0f0c6a52-2b1d-4a43-8d37-6a1b9d2c7e10"

private func key(_ pid: Int32) -> LiveSessionKey {
    LiveSessionKey(configDirectory: directory, pid: pid, procStart: 1_800_000_000 + Int(pid))
}

private func ownedRow(_ launchID: String, pid: Int32) -> LedgerRow {
    LedgerRow(
        launchID: launchID,
        profileID: "work",
        configDirectory: directory,
        cwd: "/projects/app",
        terminalID: "terminal-app",
        startedAt: t0,
        phase: .live,
        pid: pid,
        procStart: 1_800_000_000 + Int(pid),
        lastSessionID: launchID
    )
}

private func candidate(_ pid: Int32, owned: Bool = true, status: SessionStatus = .yourTurn) -> QuitCandidate {
    QuitCandidate(key: key(pid), name: "s\(pid)", status: status, isOwned: owned, accountName: "Work")
}

/// A clock the test moves.
private final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date) { value = start }
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value = value.addingTimeInterval(seconds); lock.unlock() }
}

/// A system that records what it was asked and answers from a script.
private final class FakeSignaller: QuitSignalling, @unchecked Sendable {
    struct Sent: Equatable {
        let signal: QuitSignal
        let pid: Int32
        /// The cause the store held for the row at the moment of sending.
        let causeInStore: EndCause?
    }

    private let lock = NSLock()
    private var running: Set<LiveSessionKey>
    private var sent: [Sent] = []
    var observe: ((Int32) -> EndCause?)?
    /// What `send` answers, by pid; `.sent` otherwise.
    var answers: [Int32: QuitSendResult] = [:]
    /// Processes that exit as soon as they are interrupted.
    var diesOnInterrupt: Set<Int32> = []
    var asked: [LiveSessionKey] = []

    init(running: [LiveSessionKey]) { self.running = Set(running) }

    var log: [Sent] { lock.lock(); defer { lock.unlock() }; return sent }
    func exit(_ key: LiveSessionKey) { lock.lock(); running.remove(key); lock.unlock() }

    func isSameProcessRunning(_ key: LiveSessionKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        asked.append(key)
        return running.contains(key)
    }

    func send(_ signal: QuitSignal, to pid: Int32) -> QuitSendResult {
        let cause = observe?(pid)
        lock.lock()
        sent.append(Sent(signal: signal, pid: pid, causeInStore: cause))
        let answer = answers[pid] ?? .sent
        if signal == .interrupt, diesOnInterrupt.contains(pid) { running = running.filter { $0.pid != pid } }
        lock.unlock()
        return answer
    }
}

/// A store holding one live owned row per (launch id, pid).
private func storeWith(_ dir: TempDir, rows: [(String, Int32)]) -> SessionStore {
    let store = SessionStore(url: dir.url.appendingPathComponent("sessions.json"))
    try? store.updateLedger { ledger in
        for (launch, pid) in rows { ledger.begin(ownedRow(launch, pid: pid), now: t0) }
    }
    return store
}

private func cause(_ store: SessionStore, _ launch: String) -> EndCause? {
    _ = try? store.load()
    return store.ledger.row(launchID: launch)?.endCause
}

func runSessionQuitterTests(_ t: TestRunner) {
    t.suite("SessionQuitter")

    // MARK: The cause is recorded before the signal

    do {
        let dir = TempDir("quitter-order")
        defer { dir.cleanup() }
        let store = storeWith(dir, rows: [(launchA, 11)])
        let signaller = FakeSignaller(running: [key(11)])
        // Read the store at the instant the signal goes out.
        signaller.observe = { _ in cause(SessionStore(url: store.url), launchA) }
        let quitter = SessionQuitter(store: store, signaller: signaller, now: { t0 })

        let outcomes = quitter.quit(QuitPolicy.planQuit(candidate(11)))
        t.expectEqual(outcomes[key(11)], .interrupted, "Quit interrupts the session")
        t.expectEqual(signaller.log.map(\.signal), [.interrupt], "with SIGINT first")
        t.expectEqual(signaller.log.first?.causeInStore, .individual, "`individual` was already in the store when SIGINT went out")
        t.expectEqual(cause(store, launchA), .individual, "and it is still there")
        t.expect(store.ledger.row(launchID: launchA)?.endedAt == nil, "recording a cause does not end the row: only reconcile does")
        t.expectEqual(quitter.quitting, [key(11)], "the session is Quitting")
    }

    // MARK: Quit all records `together` for every target before any signal

    do {
        let dir = TempDir("quitter-all")
        defer { dir.cleanup() }
        let store = storeWith(dir, rows: [(launchA, 21), (launchB, 22)])
        let signaller = FakeSignaller(running: [key(21), key(22), key(23)])
        // At the first signal, every target already has its cause.
        var atFirstSignal: [EndCause?] = []
        signaller.observe = { _ in
            if atFirstSignal.isEmpty {
                atFirstSignal = [cause(SessionStore(url: store.url), launchA), cause(SessionStore(url: store.url), launchB)]
            }
            return nil
        }
        let quitter = SessionQuitter(store: store, signaller: signaller, now: { t0 })
        let plan = QuitPolicy.planQuitAll(live: [candidate(21), candidate(22), candidate(23, owned: false)])
        quitter.quit(plan)
        t.expectEqual(atFirstSignal, [.together, .together], "both targets carried `together` before the first signal")
        t.expectEqual(signaller.log.map(\.pid).sorted(), [21, 22], "only the owned targets were signalled")
        t.expect(!signaller.log.contains { $0.pid == 23 }, "the unowned session was left alone")
        t.expectEqual(cause(store, launchA), .together, "the first row holds `together`")
        t.expectEqual(cause(store, launchB), .together, "the second row holds `together`")
    }

    // MARK: SIGINT ignored: SIGTERM after five seconds, never SIGKILL

    do {
        let dir = TempDir("quitter-escalate")
        defer { dir.cleanup() }
        let store = storeWith(dir, rows: [(launchA, 31)])
        let signaller = FakeSignaller(running: [key(31)])
        let clock = Clock(t0)
        let quitter = SessionQuitter(store: store, signaller: signaller, now: { clock.now() })

        quitter.quit(QuitPolicy.planQuit(candidate(31)))
        clock.advance(4.9)
        var tick = quitter.tick()
        t.expect(tick.isEmpty, "4.9 seconds in: nothing more is sent")
        t.expectEqual(signaller.log.map(\.signal), [.interrupt], "…only the SIGINT so far")

        clock.advance(0.1)
        tick = quitter.tick()
        t.expectEqual(tick.escalated, [key(31)], "5 seconds in: the session is escalated")
        t.expectEqual(signaller.log.map(\.signal), [.interrupt, .terminate], "SIGTERM follows SIGINT")

        clock.advance(10)
        quitter.tick()
        t.expectEqual(signaller.log.map(\.signal), [.interrupt, .terminate], "SIGTERM is sent once")
        t.expectEqual(quitter.quitting, [key(31)], "a session that still runs stays Quitting")

        clock.advance(SessionQuitter.giveUpDelay)
        tick = quitter.tick()
        t.expectEqual(tick.gaveUp, [key(31)], "a session that outlasts SIGTERM is released, not killed")
        t.expect(!quitter.isQuitting, "…and no longer shown as Quitting")
        t.expect(cause(store, launchA) == nil, "…and the cause recorded for a quit that did not end it is taken back")
        t.expect(signaller.log.allSatisfy { $0.signal == .interrupt || $0.signal == .terminate }, "SIGKILL was never sent")
        t.expectEqual(QuitSignal.interrupt.number, SIGINT, "interrupt is SIGINT")
        t.expectEqual(QuitSignal.terminate.number, SIGTERM, "terminate is SIGTERM")
        t.expect(![QuitSignal.interrupt.number, QuitSignal.terminate.number].contains(SIGKILL), "neither signal is SIGKILL")

        // A session that exits on SIGINT is never escalated.
        let quick = FakeSignaller(running: [key(32)])
        quick.diesOnInterrupt = [32]
        let clock2 = Clock(t0)
        let quitter2 = SessionQuitter(store: store, signaller: quick, now: { clock2.now() })
        quitter2.quit(QuitPolicy.planQuit(candidate(32, owned: false)))
        clock2.advance(6)
        let done = quitter2.tick()
        t.expectEqual(done.finished, [key(32)], "a session that exited is finished")
        t.expect(done.escalated.isEmpty, "…and not sent SIGTERM")
        t.expectEqual(quick.log.map(\.signal), [.interrupt], "only SIGINT")
        t.expect(!quitter2.isQuitting, "…and no longer Quitting")
    }

    // MARK: An unowned row is signalled and recorded nowhere

    do {
        let dir = TempDir("quitter-unowned")
        defer { dir.cleanup() }
        let store = storeWith(dir, rows: [(launchA, 41)])
        let before = store.ledger
        let signaller = FakeSignaller(running: [key(41), key(42)])
        let quitter = SessionQuitter(store: store, signaller: signaller, now: { t0 })

        let outcomes = quitter.quit(QuitPolicy.planQuit(candidate(42, owned: false)))
        t.expectEqual(outcomes[key(42)], .interrupted, "an unowned session is signalled")
        t.expectEqual(signaller.log.map(\.pid), [42], "…and only it")
        t.expect(store.ledger == before && cause(store, launchA) == nil, "nothing was written to the ledger")
        t.expect(store.ledger.row(for: key(42)) == nil, "it has no ledger row, so it can never enter the closed stack")

        // A session that is owned with the ledger store absent entirely: nothing to write, still quits.
        let bare = SessionStore(url: dir.url.appendingPathComponent("never-written.json"))
        let quitter2 = SessionQuitter(store: bare, signaller: FakeSignaller(running: [key(43)]), now: { t0 })
        quitter2.quit(QuitPolicy.planQuit(candidate(43, owned: false)))
        t.expect(!bare.exists, "quitting an unowned session creates no store file")
    }

    // MARK: Owned by its pane alone: no ledger row, so nothing to record, and still quit

    do {
        let dir = TempDir("quitter-pane-only")
        defer { dir.cleanup() }
        let store = storeWith(dir, rows: [(launchA, 81)])
        let signaller = FakeSignaller(running: [key(82)])
        let quitter = SessionQuitter(store: store, signaller: signaller, now: { t0 })
        let outcomes = quitter.quit(QuitPolicy.planQuit(candidate(82)))
        t.expectEqual(outcomes[key(82)], .interrupted, "an owned session with no live ledger row is still quit")
        t.expect(cause(store, launchA) == nil, "…and no other row picked up its cause")
    }

    // MARK: ESRCH is an ended session, not an error

    do {
        let dir = TempDir("quitter-esrch")
        defer { dir.cleanup() }
        let store = storeWith(dir, rows: [(launchA, 51)])
        // Running when asked, gone when signalled.
        let signaller = FakeSignaller(running: [key(51)])
        signaller.answers[51] = .noSuchProcess
        let quitter = SessionQuitter(store: store, signaller: signaller, now: { t0 })

        let outcomes = quitter.quit(QuitPolicy.planQuit(candidate(51)))
        t.expectEqual(outcomes[key(51)], .alreadyEnded, "ESRCH is already ended")
        t.expect(!quitter.isQuitting, "…and there is nothing to follow")

        // Not running at all: not even signalled, and nothing recorded.
        let gone = FakeSignaller(running: [])
        let quitter2 = SessionQuitter(store: store, signaller: gone, now: { t0 })
        let again = quitter2.quit(QuitPolicy.planQuit(candidate(51)))
        t.expectEqual(again[key(51)], .alreadyEnded, "a process that is gone is already ended")
        t.expect(gone.log.isEmpty, "…and no signal is sent")

        // EPERM is a real failure, reported, and the intent is taken back.
        let store2 = storeWith(TempDir("quitter-eperm-store"), rows: [(launchB, 52)])
        let denied = FakeSignaller(running: [key(52)])
        denied.answers[52] = .failed("Operation not permitted")
        let quitter3 = SessionQuitter(store: store2, signaller: denied, now: { t0 })
        let failure = quitter3.quit(QuitPolicy.planQuit(candidate(52)))
        t.expectEqual(failure[key(52)], .failed("Operation not permitted"), "a refusal is reported")
        t.expect(cause(store2, launchB) == nil, "…and no cause is left behind for a session nothing ended")
        try? FileManager.default.removeItem(at: store2.url.deletingLastPathComponent())
    }

    // MARK: A reused pid is never signalled

    do {
        let dir = TempDir("quitter-reuse")
        defer { dir.cleanup() }
        let store = storeWith(dir, rows: [(launchA, 61)])
        // The pid is alive, but it is another process: its start time is not
        // the session's, so the key is not "running".
        let signaller = FakeSignaller(running: [])
        let quitter = SessionQuitter(store: store, signaller: signaller, now: { t0 })
        let outcomes = quitter.quit(QuitPolicy.planQuit(candidate(61)))
        t.expectEqual(outcomes[key(61)], .alreadyEnded, "a pid whose start time does not match is not the session")
        t.expect(signaller.log.isEmpty, "…and is never signalled")
        t.expect(cause(store, launchA) == nil, "…and no cause is recorded for it")

        // And on the way: a process that was the session when SIGINT went out,
        // and was replaced before the escalation, is not sent SIGTERM.
        let live = FakeSignaller(running: [key(62)])
        let clock = Clock(t0)
        let quitter2 = SessionQuitter(store: store, signaller: live, now: { clock.now() })
        quitter2.quit(QuitPolicy.planQuit(candidate(62, owned: false)))
        live.exit(key(62))
        clock.advance(6)
        let tick = quitter2.tick()
        t.expectEqual(tick.finished, [key(62)], "the session ended, and its pid may now be anyone's")
        t.expectEqual(live.log.map(\.signal), [.interrupt], "SIGTERM is not sent to whatever holds the pid now")
    }

    // MARK: A second quit while one is under way

    do {
        let dir = TempDir("quitter-twice")
        defer { dir.cleanup() }
        let store = storeWith(dir, rows: [(launchA, 71)])
        let signaller = FakeSignaller(running: [key(71)])
        let quitter = SessionQuitter(store: store, signaller: signaller, now: { t0 })
        quitter.quit(QuitPolicy.planQuit(candidate(71)))
        let second = quitter.quit(QuitPolicy.planQuitAll(live: [candidate(71)]))
        t.expectEqual(second[key(71)], .alreadyQuitting, "a second quit is not a second signal")
        t.expectEqual(signaller.log.count, 1, "…one SIGINT in all")
    }

    // MARK: Real signals, sent only to a child the test starts

    do {
        let table = LibprocProcessTable()

        func spawnSleeper() -> Process? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["30"]
            do { try process.run() } catch { return nil }
            return process
        }
        func awaitEntry(_ pid: Int32) -> ProcessEntry? {
            for _ in 0..<50 {
                if let entry = table.entry(for: pid) { return entry }
                usleep(20_000)
            }
            return nil
        }

        if let child = spawnSleeper(), let entry = awaitEntry(child.processIdentifier) {
            let dir = TempDir("quitter-real")
            defer { dir.cleanup() }
            let childKey = LiveSessionKey(configDirectory: nil, pid: child.processIdentifier, procStart: Int(entry.startTime))
            let store = SessionStore(url: dir.url.appendingPathComponent("sessions.json"))
            let quitter = SessionQuitter(store: store)
            let target = QuitCandidate(key: childKey, name: "child", status: .yourTurn, isOwned: false)
            let outcome = quitter.quit(QuitPolicy.planQuit(target))[childKey]
            // A watchdog, so a signal that did not land cannot hang the suite.
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { if child.isRunning { child.terminate() } }
            child.waitUntilExit()
            t.expectEqual(outcome, .interrupted, "the real signaller sends SIGINT to a live child")
            t.expect(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGINT, "the child died of SIGINT, not anything else")
            _ = quitter.tick()
            t.expect(!quitter.isQuitting, "its exit is noticed")
        } else {
            t.expect(false, "could not start a child to signal")
        }

        // A key whose start time is not the child's: never signalled.
        if let child = spawnSleeper(), let entry = awaitEntry(child.processIdentifier) {
            let dir = TempDir("quitter-real-reuse")
            defer { dir.cleanup() }
            let wrong = LiveSessionKey(configDirectory: nil, pid: child.processIdentifier, procStart: Int(entry.startTime) - 3600)
            let quitter = SessionQuitter(store: SessionStore(url: dir.url.appendingPathComponent("sessions.json")))
            let outcome = quitter.quit(QuitPolicy.planQuit(QuitCandidate(key: wrong, name: "stranger", status: .working, isOwned: false)))[wrong]
            usleep(150_000)
            t.expectEqual(outcome, .alreadyEnded, "a live pid with the wrong start time is not the session")
            t.expect(child.isRunning, "…and the process holding the pid was not signalled")
            child.terminate()
            child.waitUntilExit()
        } else {
            t.expect(false, "could not start a second child")
        }

        // The system signaller refuses pids that are not a session's, whatever it is asked.
        let system = SystemQuitSignaller()
        for pid: Int32 in [0, 1, -1, getpid()] {
            if case .failed = system.send(.interrupt, to: pid) {
                t.expect(true, "pid \(pid) is refused")
            } else {
                t.expect(false, "pid \(pid) must never be signalled")
            }
        }
    }
}
