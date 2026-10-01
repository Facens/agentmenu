// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import AgentMenuKit

/// The app half of ownership (U11, KTD7, KTD12): feeds `LaunchLedger.reconcile`
/// what the registry and the session host say, writes what it decides, and
/// hands the Sessions model what it draws.
///
/// All the rules are in the Kit (`LaunchLedger`); this is the schedule.
///
/// - **What runs when.** A reconcile follows every registry delivery, and a
///   timer keeps it going while it has something to decide that no registry
///   file will announce: once a second while a launch is waiting to register
///   (the 15 seconds, R36), once every two seconds while the popover is open
///   and a hosted session exists (the Detached marker follows a window being
///   closed, which changes no registry file at all).
/// - **The host is asked off the main thread.** A snapshot is a socket probe
///   and, when a server answers, two `tmux` runs. Nothing is asked of a host
///   that is not running, and the host is never created here.
/// - **One writer of the ledger's follow-up state.** The launch path adds
///   rows; this only reconciles them, inside the store's own lock, so a row a
///   launch added a moment ago is never overwritten with a stale copy.
/// - **Classification (U13).** After each reconcile, the rows that ended are
///   handed to `RestorePlanner` with what was just observed: the host's status
///   (read off the main thread beside the snapshot, since no snapshot is taken
///   when the server is down), the power-off notification, the boot id and
///   which sessions never got a prompt. The result is written with the ledger,
///   in one write, so a row is never marked classified without its session
///   being somewhere. A disappearance AgentMenu did not cause waits out the
///   planner's settle window, and a timer runs a sweep to see it through.
@MainActor
final class OwnedSessionsTracker {
    private let store: SessionStore
    private let host: SessionHosting?
    private let terminalName: (String) -> String?
    private let changed: () -> Void

    private(set) var owned: [LiveSessionKey: WindowAttachment] = [:]
    private(set) var pending: [PendingLaunch] = []
    private(set) var hostSnapshot: HostSnapshot?
    /// The pending reopen set, the closed stack and the boot id, as last
    /// written (U13). U14's Reopen all and Reopen last closed read and change
    /// these through the store; the counts are for the header menu.
    private(set) var restore = RestoreState()
    /// Set when the session host died with sessions in it and the pending set
    /// took them. U14 posts the notice and takes it with
    /// `consumeHostDeathNotice()`.
    private(set) var hostDeathNotice: HostDeathNotice?

    private var latestLive: [LiveSession]?
    private var popoverOpen = false
    private var started = false
    private var adopted = false
    private var refreshing = false
    private var refreshAgain = false
    private var timer: Timer?
    private var classifying = false
    /// When `NSWorkspace.willPowerOffNotification` arrived. Held in memory
    /// only: a relaunch after the shutdown sees the boot id change instead.
    private var powerOffAt: Date?
    private var powerOffObserver: NSObjectProtocol?
    private let transcriptIndex: TranscriptIndex
    private let transcriptDirectories: () -> [URL]
    private let bootID: () -> String?
    /// The boot id the store held when AgentMenu started differs from this
    /// boot's: the Mac restarted since the last run (R25). Read once, in `init`,
    /// before the first classification records the new boot id over the old.
    let bootChangedAtLaunch: Bool
    /// The relaunch classification has run, so `restore` is this launch's
    /// reading of what the restart left.
    private(set) var launchPassDone = false

    /// How long after a power-off notification a session that is still live is
    /// taken to have been spared (the logout was cancelled), and its recorded
    /// cause is taken back.
    private static let powerOffGrace: TimeInterval = RestorePlanner.powerOffWindow

    /// - Parameters:
    ///   - terminalName: a terminal manifest's display name by id, for the
    ///     row of a hosted session whose process tree ends at tmux.
    ///   - changed: called on the main actor whenever what the tracker
    ///     publishes may have changed.
    ///   - transcriptIndex: how a session is found to have never been
    ///     prompted.
    ///   - transcriptDirectories: every configured profile's config directory,
    ///     for the sessions whose own row names none.
    ///   - bootID: this boot's identifier (`BootID.current`).
    init(
        store: SessionStore,
        host: SessionHosting?,
        terminalName: @escaping (String) -> String?,
        transcriptIndex: TranscriptIndex = TranscriptIndex(),
        transcriptDirectories: @escaping () -> [URL] = { [] },
        bootID: @escaping () -> String? = { BootID.current() },
        changed: @escaping () -> Void
    ) {
        self.store = store
        self.host = host
        self.terminalName = terminalName
        self.transcriptIndex = transcriptIndex
        self.transcriptDirectories = transcriptDirectories
        self.bootID = bootID
        self.changed = changed
        // The store is read here, so the counts the header menu shows are the
        // last run's before the first sweep has written anything.
        _ = try? store.load()
        self.restore = store.restore
        self.bootChangedAtLaunch = BootID.hasChanged(from: store.restore.bootID, to: bootID())
        observePowerOff()
    }

    deinit {
        if let powerOffObserver { NSWorkspace.shared.notificationCenter.removeObserver(powerOffObserver) }
    }

    // MARK: - Power off (KTD12)

    /// Logout or shutdown is coming. The whole live owned set is recorded at
    /// once, in this one write, before the system takes the sessions down: the
    /// process may be gone a moment later, and the boot id says the rest at the
    /// next launch. No host-death notice follows, whatever the host does next.
    private func observePowerOff() {
        powerOffObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willPowerOffNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.powerOffNotified() }
        }
    }

    func powerOffNotified(now: Date = Date()) {
        powerOffAt = now
        try? store.updateLedger { $0.recordCauseForUnexplainedLiveRows(.powerOff, at: now) }
    }

    /// Takes the recorded intent back from sessions that outlived a
    /// notification no shutdown followed.
    private func releasePowerOffIfSpared(now: Date) {
        guard let at = powerOffAt, now.timeIntervalSince(at) > Self.powerOffGrace else { return }
        powerOffAt = nil
        try? store.updateLedger { $0.clearCauseOnLiveRows(.powerOff) }
    }

    /// U14 posts the host-death notice and takes it, so it is posted once.
    func consumeHostDeathNotice() -> HostDeathNotice? {
        defer { hostDeathNotice = nil }
        return hostDeathNotice
    }

    /// A restore changed the pending set or the closed stack: what is
    /// published follows the store at once, without waiting for a sweep.
    func restoreChanged() {
        restore = store.restore
        changed()
    }

    /// Forgets the host's recorded death once nothing is left that it explains
    /// (U14, R34): the notice has been raised, so the death is not read again
    /// as a new one. Not before: a hosted row still running, or ended and
    /// still inside the planner's settle window, is classified from the death,
    /// and would land on the closed stack if the record went first (AE10).
    /// A crashed host is never restored on its own: this only forgets.
    private func settleHostRecord(status: HostStatus) {
        guard status == .died, RestoreActions.mayClearHostRecord(ledger: store.ledger) else { return }
        host?.clearRecord()
    }

    // MARK: - Inputs

    func registryChanged(_ live: [LiveSession]) {
        latestLive = live
        refresh()
    }

    func popoverOpenChanged(_ open: Bool) {
        popoverOpen = open
        if open { refresh() } else { rearmTimer() }
    }

    /// A launch has just written its row (or the user dismissed one).
    func ledgerChanged() {
        refresh()
    }

    func dismiss(launchID: String) {
        try? store.updateLedger { $0.dismiss(launchID: launchID) }
        refresh()
    }

    // MARK: - Reading

    /// Session ids a restore must treat as being started right now.
    func inFlightSessionIDs(now: Date = Date()) -> Set<String> {
        store.ledger.inFlightSessionIDs(now: now)
    }

    func ownership(of session: LiveSession) -> OwnedSessionInfo? {
        store.ledger.ownership(of: session, host: hostSnapshot)
    }

    /// The live list as the rows should show it: a hosted session's terminal
    /// is the one its window was opened in, not what its process tree says
    /// (tmux).
    func presented(_ live: [LiveSession]) -> [LiveSession] {
        let ledger = store.ledger
        return live.map { session in
            guard session.isClaudeCode,
                  let info = ledger.ownership(of: session, host: hostSnapshot),
                  info.isHosted, let terminalID = info.terminalID,
                  let name = terminalName(terminalID)
            else { return session }
            return session.replacingTerminal(TerminalIdentity(id: terminalID, displayName: name))
        }
    }

    // MARK: - Reconciling

    func refresh() {
        guard let live = latestLive else { return }
        if refreshing {
            refreshAgain = true
            return
        }
        refreshing = true
        let host = host
        Task { [weak self] in
            // The ledger is read at the moment of asking: only a hosted
            // launch (or a server that already answers) makes a snapshot
            // worth two `tmux` runs.
            let looked: (snapshot: HostSnapshot?, status: HostStatus) = await Task.detached(priority: .utility) {
                // The status is read whether or not a server answers: a
                // server that is gone is how a death shows.
                let status = host?.status() ?? .neverStarted
                guard let host, host.isServerAlive() else { return (nil, status) }
                return (try? host.snapshot(), status)
            }.value
            self?.finishRefresh(live: live, host: looked.snapshot, hostStatus: looked.status)
        }
    }

    private func finishRefresh(live: [LiveSession], host snapshot: HostSnapshot?, hostStatus: HostStatus) {
        refreshing = false
        let now = Date()
        let observation = LedgerObservation(
            live: live,
            host: snapshot,
            now: now,
            isSameProcessRunning: { ProcessLiveness.isSameProcessRunning($0) }
        )
        let firstPass = !adopted
        adopted = true
        // Before the reconcile, so a session that outlived a cancelled logout
        // and ends on this very look is not classified from its stale
        // power-off cause.
        releasePowerOffIfSpared(now: now)
        // Inside the store's lock, so a row a launch adds meanwhile is never
        // overwritten by a stale copy.
        try? store.updateLedger { ledger in
            if firstPass { ledger.adopt(host: snapshot, now: now) }
            _ = ledger.reconcile(observation)
            // A quit's cause outlasts the quitter that followed it when
            // AgentMenu exits within its 30 seconds; the row is still live
            // here, so the quit did not end it.
            ledger.releaseStaleQuitCauses(now: now)
        }
        hostSnapshot = snapshot
        classifyEndings(live: live, hostStatus: hostStatus, relaunch: firstPass, now: now)
        settleHostRecord(status: hostStatus)
        let ledger = store.ledger
        owned = ledger.ownedAttachments(live: live, host: snapshot)
        pending = ledger.pendingLaunches()
        restore = store.restore
        rearmTimer()
        changed()
        if refreshAgain {
            refreshAgain = false
            refresh()
        }
    }

    // MARK: - Classifying (U13)

    /// Decides what the rows that ended became. With nothing to decide and
    /// nothing to keep in step (the boot id, a session brought back some other
    /// way), it does nothing, and nothing is read from disk for it. When a row
    /// ended, the transcripts of those sessions are looked at off the main
    /// thread first, to leave out the ones never prompted.
    private func classifyEndings(live: [LiveSession], hostStatus: HostStatus, relaunch: Bool, now: Date) {
        guard !classifying else { return }
        let liveIDs = Set(live.compactMap(\.sessionId)).union(store.ledger.liveOwnedRows.compactMap(\.lastSessionID))
        let candidates = RestorePlanner.candidates(in: store.ledger)
        let current = bootID()
        let state = store.restore
        let staleLive = (state.pending?.sessions.contains { liveIDs.contains($0.sessionID) } ?? false)
            || state.closed.contains { liveIDs.contains($0.sessionID) }
        let bootToRecord = current != nil && state.bootID != current
        guard relaunch || !candidates.isEmpty || staleLive || bootToRecord else { return }

        guard !candidates.isEmpty else {
            applyClassification(
                neverPrompted: [], liveIDs: liveIDs, hostStatus: hostStatus, relaunch: relaunch, bootID: current, now: now,
                republish: false
            )
            return
        }

        classifying = true
        let index = transcriptIndex
        let directories = transcriptDirectories()
        Task { [weak self] in
            let never: Set<String> = await Task.detached(priority: .utility) {
                var result = Set<String>()
                for row in candidates {
                    guard let id = RestorePlanner.resumableSessionID(of: row) else { continue }
                    var places = row.configDirectory.map { [URL(fileURLWithPath: $0)] } ?? []
                    places.append(contentsOf: directories)
                    if index.promptState(ofSession: id, in: places) == .neverPrompted { result.insert(id) }
                }
                return result
            }.value
            self?.applyClassification(
                neverPrompted: never, liveIDs: liveIDs, hostStatus: hostStatus, relaunch: relaunch, bootID: current,
                now: Date(), republish: true
            )
            self?.classifying = false
        }
    }

    private func applyClassification(
        neverPrompted: Set<String>, liveIDs: Set<String>, hostStatus: HostStatus, relaunch: Bool, bootID: String?,
        now: Date, republish: Bool
    ) {
        let context = RestoreContext(
            now: now,
            isRelaunchPass: relaunch,
            hostStatus: hostStatus,
            powerOffAt: powerOffAt,
            currentBootID: bootID,
            neverPrompted: neverPrompted,
            liveSessionIDs: liveIDs
        )
        if relaunch { launchPassDone = true }
        var notice: HostDeathNotice?
        // One write for the ledger rows it marks and the state it replaces.
        try? store.update { data in
            notice = RestorePlanner.classify(&data, context: context).hostDeathNotice
        }
        if let notice { hostDeathNotice = notice }
        settleHostRecord(status: hostStatus)
        restore = store.restore
        // From the asynchronous path, the sweep that started this has already
        // published without it.
        if republish {
            pending = store.ledger.pendingLaunches()
            rearmTimer()
            changed()
        }
    }

    // MARK: - The timer

    private func rearmTimer() {
        timer?.invalidate()
        timer = nil
        let ledger = store.ledger
        let interval: TimeInterval?
        if ledger.hasRowsAwaitingRegistration(now: Date()) {
            interval = 1
        } else if RestorePlanner.candidates(in: ledger).contains(where: {
            // Only while the settle window can still run out: a row that is
            // stuck unclassified must not keep a timer going for ever.
            Date().timeIntervalSince($0.endedAt ?? .distantPast) < RestorePlanner.settleWindow + 5
        }) {
            interval = 1
        } else if popoverOpen, ledger.hasActiveHostedRows {
            interval = 2
        } else {
            interval = nil
        }
        guard let interval else { return }
        let timer = Timer(timeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }
}
