// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Combine
import Foundation
import AgentMenuKit

/// What is being renamed, if anything: one row at a time.
enum RenameTarget: Equatable {
    case live(LiveSessionKey)
    case closed(String)
}

/// Owns everything the Sessions tab and the menu-bar badge read (KTD9).
///
/// **It runs from launch**, not from the first time the popover opens: the
/// badge has to be right while the popover is closed, and the only source for
/// it is the registry. What runs while nothing is looking is therefore exactly
/// the watchers, the 2-second sweep while anything is listed, and a count.
/// The snapshot (folder normalisation, names, groups) is built only while the
/// popover is open, and the transcript index — the expensive part, a stat and
/// two small reads per transcript — is built only once the Sessions tab has
/// been opened, off the main thread.
///
/// The registry work itself never runs on the main thread either: the vnode
/// watchers, the sweep timer and the reader share one serial queue
/// (`RegistryHost`), and only the resulting list crosses back.
@MainActor
final class SessionsModel: ObservableObject {
    // MARK: Published state

    /// Every live session across every account, exactly as the registry
    /// reader last reported it. The journal observer and the badge read this;
    /// nothing filters it.
    @Published private(set) var live: [LiveSession] = []
    /// Sessions waiting on the user across every account (R7). Kept apart
    /// from `snapshot` so it stays current without the snapshot being built
    /// while the popover is closed.
    @Published private(set) var badgeCount = 0
    @Published private(set) var snapshot: SessionSnapshot
    @Published private(set) var viewState = SessionsViewState.onOpen
    @Published private(set) var closedSections: [ClosedSection] = []
    /// False until the transcript index has been built once. The Closed view
    /// shows a progress indicator in its place (R28).
    @Published private(set) var closedReady = false

    /// Launches AgentMenu made that have no live row yet (Starting) or never
    /// got one (Failed to start), from the launch ledger (U11, R36).
    @Published private(set) var pending: [PendingLaunch] = []
    /// Live rows being quit, dimmed and marked Quitting until their process
    /// ends (U12).
    @Published private(set) var quitting: Set<LiveSessionKey> = []
    /// How many owned sessions "Reopen all from last time" would bring back
    /// (U13, R23): the pending reopen set, without the sessions whose restore
    /// is already starting. The header menu shows it.
    @Published private(set) var pendingReopenCount = 0
    /// The sessions Reopen all would bring back, so a Closed row can say so
    /// (U5 step 8).
    @Published private(set) var pendingReopenIDs: Set<String> = []
    /// How deep the closed stack is: how many times "Reopen last closed" can
    /// be repeated (U13, R24).
    @Published private(set) var closedStackCount = 0
    /// The strip a Reopen all leaves at the top of the list.
    @Published var reopenSummary: ReopenAllSummary?
    /// How many sessions a Reopen all is bringing back right now, nil when none
    /// is running.
    @Published private(set) var reopening: Int?
    /// The post-restart banner above the tabs (U14): nil when the pending set
    /// is empty, was formed by a Quit all, or the user dismissed it.
    @Published private(set) var restoreBanner: RestoreBannerInfo?
    /// Whether the banner carries the once-only "reopen sessions at login?"
    /// question (U15, R25): a restart's set is on offer and nobody has answered.
    @Published private(set) var asksReopenAtLogin = false

    /// One line in place of a row's second line, by row key: why a click did
    /// not do what it said, or why a rename was not saved.
    @Published private(set) var rowMessages: [String: String] = [:]
    /// The longer text behind a row's message, shown as its tooltip — the
    /// message is one truncated line, and a fix that starts past the cut is
    /// no fix.
    @Published private(set) var rowHelps: [String: String] = [:]
    /// Closed sessions being resumed right now, so a second click cannot start
    /// a second process on one transcript.
    @Published private(set) var resuming: Set<String> = []
    /// Resumes typed into a terminal whose process has not yet written its
    /// registry file. Outlives the `resume` call: a second click on the
    /// still-listed Closed row must not start a second process (R27).
    private var inFlight = InFlightResumes()
    /// Every live registry row's session id, displayed or not (R27): the
    /// Closed list must not offer a session a process holds under an IDE or a
    /// parked row.
    private var liveSessionIDs: Set<String> = []
    @Published private(set) var expandedFolds: Set<String> = []

    /// Why Needs-you notifications cannot reach the user, with the System
    /// Settings path, or nil (R32, KTD15). Shown as a strip at the top of the
    /// tab.
    @Published private(set) var notificationGuidance: String?

    @Published private(set) var renaming: RenameTarget?
    @Published var renameDraft = ""
    private var renameOriginal = ""

    // MARK: Collaborators

    private unowned let environment: AppEnvironment
    private let store: SessionStore
    /// Sends the quits and follows them to the end of the process (U12).
    private let quitter: SessionQuitter
    private var quitTimer: Timer?
    private let index = TranscriptIndex()
    private var host: RegistryHost!
    /// Which sessions are owned, and whether each has a window (U11).
    private var tracker: OwnedSessionsTracker!
    private var config: Config
    private var hostSignature: HostSignature?
    private var cancellables: Set<AnyCancellable> = []

    private var transcripts: [TranscriptEntry] = []
    private var indexing = false
    private var indexAgain = false
    private var popoverOpen = false
    /// A change arrived while the popover was closed, so the snapshot is stale.
    private var snapshotDirty = true
    /// Live rows a focus is in flight for, so a second click cannot queue a
    /// second script behind a permission prompt.
    private var focusing: Set<LiveSessionKey> = []
    /// The registry has delivered a list at least once.
    private var hasDelivered = false
    /// A click on a notification could not focus its row, and is about to open
    /// the popover to show why: the next open keeps that row's message, which
    /// an ordinary open clears.
    private var keepMessagesOnNextOpen = false
    /// The pending set whose banner the user dismissed. Not the set's
    /// `touched` flag: a touched set is merged into the next event, so a
    /// dismissed one would come back with the next Quit all.
    private var bannerDismissedFormedAt: Date?
    /// A host-death notification is on screen (to withdraw it when it is moot).
    private var hostDeathPosted = false
    /// A Reopen last closed is running, so the shortcut cannot start two.
    private var reopeningLast = false
    private var offer = RestoreOffer()
    /// The startup restore has been weighed for this launch (U15): it is decided
    /// once, at the first reading that follows the relaunch pass.
    private var startupRestoreDecided = false

    init(environment: AppEnvironment) {
        self.environment = environment
        self.config = environment.config
        self.store = environment.sessionStore
        self.quitter = SessionQuitter(store: environment.sessionStore)
        self.snapshot = SessionSnapshot.build(live: [], profiles: [])
        self.host = RegistryHost(
            deliver: { [weak self] sessions in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.apply(live: sessions) }
                }
            },
            deliverIDs: { [weak self] ids in
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated { self?.apply(liveSessionIDs: ids) }
                }
            }
        )
        self.tracker = OwnedSessionsTracker(
            store: environment.sessionStore,
            host: environment.sessionHost,
            terminalName: { [weak environment] id in
                MainActor.assumeIsolated { environment?.registry.terminal(id: id)?.displayName }
            },
            transcriptIndex: index,
            transcriptDirectories: { [weak self] in
                MainActor.assumeIsolated { self?.transcriptDirectories() ?? [] }
            },
            changed: { [weak self] in self?.ownershipChanged() }
        )
    }

    /// Starts watching. Called once, at launch, after the journal has been
    /// activated; `start` replays the current configuration, which is what
    /// arms the first monitor.
    func start() {
        refreshRestoreOffer()
        // The sink's own parameter, never `environment.config`: `@Published`
        // fires before the new value is stored, so reading the property here
        // would always be one change behind.
        environment.$config
            .sink { [weak self] config in
                MainActor.assumeIsolated { self?.configChanged(config) }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest(environment.notifier.$authorization, environment.$config)
            .sink { [weak self] authorization, config in
                MainActor.assumeIsolated {
                    self?.notificationGuidance = NotificationGuidance.sessionsTab(
                        authorization: authorization,
                        notifyNeedsYou: config.notifyNeedsYou || config.notifyYourTurn
                    )
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Registry

    private struct HostSignature: Equatable {
        let profiles: [RegistryProfile]
        let scanTargets: [AgentScanTarget]
    }

    private func registryProfiles(for config: Config) -> [RegistryProfile] {
        config.profiles.map { RegistryProfile(profile: $0, profileRoot: environment.overrides.profileRoot) }
    }

    /// Other agents are found by process name, for the agents the user has
    /// turned on (R2). The enabled state is the configuration's own, falling
    /// back to the manifest's, exactly as `ManifestRegistry.availability`
    /// reads it — the manifest's flag alone would skip an agent the user
    /// enabled and list one they did not.
    private func scanTargets(for config: Config) -> [AgentScanTarget] {
        AgentScanTarget.targets(from: environment.registry.agents) { config.agentState[$0.id]?.enabled ?? $0.enabled }
    }

    private func configChanged(_ config: Config) {
        self.config = config
        let signature = HostSignature(profiles: registryProfiles(for: config), scanTargets: scanTargets(for: config))
        // The reader fixes its profiles when it is built, so a change to them
        // is a new reader and a new set of watches; anything else (a folder,
        // a preset) only changes how the snapshot is drawn.
        if signature != hostSignature {
            hostSignature = signature
            host.start(
                profiles: signature.profiles,
                scanTargets: signature.scanTargets,
                terminals: environment.registry.terminals
            )
            // A scan already running was started with the old profiles;
            // `refreshTranscripts` queues one more behind it.
            if closedReady { refreshTranscripts() }
        }
        // Whether the banner still owes the reopen-at-login question depends on
        // the config: Settings can answer it first.
        refreshRestoreOffer()
        rebuild()
    }

    private func apply(live sessions: [LiveSession]) {
        live = sessions
        hasDelivered = true
        badgeCount = SessionBadge.count(live: sessions)
        rebuild()
        environment.notifier.sessionsChanged(sessions)
        tracker.registryChanged(sessions)
    }

    /// Every configured profile's config directory, where its transcripts are.
    private func transcriptDirectories() -> [URL] {
        registryProfiles(for: config).map(\.directory)
    }

    /// The ledger or the host changed what is owned or still starting.
    private func ownershipChanged() {
        let launches = tracker.pending
        if launches != pending { pending = launches }
        refreshRestoreOffer()
        if let notice = tracker.consumeHostDeathNotice() {
            // R34: one notification naming how many ended and offering Reopen
            // all, once. Nothing is restored on its own: a crash mid-turn
            // deserves the user's eyes first. The tracker hands the notice
            // over once, so it is posted once.
            environment.notifier.postHostDeath(notice)
            hostDeathPosted = true
        }
        rebuild()
        environment.notifier.ownedChanged(Set(tracker.owned.keys))
    }

    /// What Reopen all and Reopen last closed would restore, the banner, and the
    /// tags on Closed rows, all from one reading of the store. A session whose
    /// restore is still starting is not offered a second time (it leaves the
    /// lists when it is running, and stays in them if it never comes up, R35).
    private func refreshRestoreOffer() {
        offer = RestoreActions.offer(
            state: store.restore, starting: RestoreActions.startingSessionIDs(in: store.ledger)
        )
        if offer.pendingCount != pendingReopenCount { pendingReopenCount = offer.pendingCount }
        if offer.closedCount != closedStackCount { closedStackCount = offer.closedCount }
        if offer.pendingIDs != pendingReopenIDs { pendingReopenIDs = offer.pendingIDs }
        let banner = RestoreActions.banner(offer: offer, dismissedFormedAt: bannerDismissedFormedAt)
        if banner != restoreBanner { restoreBanner = banner }
        let asks = banner != nil && ReopenAtLoginQuestion.surface(for: config, offer: offer) == .inBanner
        if asks != asksReopenAtLogin { asksReopenAtLogin = asks }
        restoreAtStartupIfAsked()
        if hostDeathPosted, offer.pendingCount == 0 {
            hostDeathPosted = false
            environment.notifier.withdrawHostDeath()
        }
    }

    /// "Reopen sessions at login" (R25): the first reading after the relaunch
    /// pass decides, once, whether the set a restart left comes back without a
    /// click. It goes through `reopenAll`, so the same guard stands in front of
    /// every session, and `ReopenAtLoginStartup` keeps a crashed host's set (and
    /// a Quit all's) out of it.
    private func restoreAtStartupIfAsked() {
        guard !startupRestoreDecided, tracker.launchPassDone else { return }
        startupRestoreDecided = true
        guard ReopenAtLoginStartup.shouldRestore(
            setting: config.reopenAtLogin,
            bootChangedAtLaunch: tracker.bootChangedAtLaunch,
            launchPassDone: tracker.launchPassDone,
            offer: offer
        ) else { return }
        Task { await reopenAll() }
    }

    /// The banner's question was answered (U15). Yes also reopens what is
    /// waiting, once: the answer is "now and at login", and the banner's own
    /// Reopen all stays for the people who say no.
    func answerReopenAtLogin(_ reopenAtLogin: Bool) {
        environment.update { ReopenAtLoginQuestion.record(answer: reopenAtLogin, in: &$0) }
        environment.flushPendingSave()
        refreshRestoreOffer()
        if reopenAtLogin { Task { await reopenAll() } }
    }

    /// The user closed the banner: it stays closed for this pending set.
    func dismissRestoreBanner() {
        bannerDismissedFormedAt = restoreBanner?.formedAt ?? offer.pendingFormedAt
        refreshRestoreOffer()
    }

    /// A launch has written or changed its ledger row (U11): the Starting row
    /// appears now, not when the terminal has finished opening.
    func ledgerChanged() {
        tracker.ledgerChanged()
    }

    /// The ids of every live registry row changed, which can happen without
    /// the displayed list changing. An in-flight resume whose process has
    /// registered is over, and the Closed list is drawn again.
    private func apply(liveSessionIDs ids: Set<String>) {
        liveSessionIDs = ids
        inFlight.prune(live: ids, now: Date())
        rebuildClosed()
    }

    /// What is running right now, read again rather than remembered: for a
    /// notification click, which must not decide from a list that predates it.
    func liveNow() -> [LiveSession] { host.liveNow().sessions }

    /// Waits, briefly, for the first list after launch. A click that started
    /// the app is delivered before the registry has been read, and an empty
    /// answer would call every session ended.
    func waitForFirstList(timeout: TimeInterval) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !hasDelivered, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Popover lifecycle

    /// The popover is about to be shown: everything goes back to what an open
    /// shows (KTD16, R6), and the list is re-read rather than trusted.
    func popoverWillOpen() {
        popoverOpen = true
        tracker.popoverOpenChanged(true)
        viewState.reopen()
        if !keepMessagesOnNextOpen {
            rowMessages = [:]
            rowHelps = [:]
        }
        keepMessagesOnNextOpen = false
        renaming = nil
        loadRenames()
        host.sweep()
        rebuild()
    }

    /// Read by the updater before it restarts the app.
    var isPopoverOpen: Bool { popoverOpen }

    /// A launch, a reopen or a quit is under way, and a relaunch now would
    /// cut it off. Read by the updater before it restarts the app.
    var hasWorkInFlight: Bool {
        reopening != nil || reopeningLast || !quitting.isEmpty
            || pending.contains { $0.phase == .starting }
    }

    func popoverDidClose() {
        popoverOpen = false
        tracker.popoverOpenChanged(false)
        keepMessagesOnNextOpen = false
        renaming = nil
    }

    /// The Sessions tab was selected. The first time, this builds the
    /// transcript index; every time, it re-reads, because a name or a closed
    /// session written since the last look is exactly what someone opening
    /// the tab is about to look for.
    func sessionsTabOpened() {
        // The first open is one of the two user actions that ask macOS for
        // notification permission (KTD15); every open re-reads the answer,
        // because it may have been changed in System Settings since.
        environment.notifier.requestAuthorizationIfNeeded()
        environment.notifier.refreshAuthorization()
        loadRenames()
        host.sweep()
        tracker.refresh()
        refreshTranscripts()
        rebuild()
    }

    // MARK: - View state

    func setMode(_ mode: SessionsMode) {
        guard viewState.mode != mode else { return }
        viewState.mode = mode
        renaming = nil
        if mode == .closed { refreshTranscripts() }
        rebuild()
    }

    func setPill(_ pill: AccountPill) {
        viewState.pill = pill
        rebuild()
    }

    func setSearch(_ text: String) {
        viewState.search = text
        rebuildClosed()
    }

    func toggleFold(_ id: String) {
        if expandedFolds.contains(id) { expandedFolds.remove(id) } else { expandedFolds.insert(id) }
    }

    // MARK: - Building what the views read

    private func rebuild() {
        guard popoverOpen else {
            snapshotDirty = true
            return
        }
        snapshotDirty = false
        // Assigned only when it differs: a sweep that changed nothing must
        // not make every view that reads the snapshot draw again.
        let built = SessionSnapshot.build(
            live: tracker.presented(live),
            transcripts: transcripts,
            profiles: registryProfiles(for: config),
            folders: config.folders,
            renames: store.renames,
            owned: tracker.owned,
            pill: viewState.pill
        )
        if built != snapshot { snapshot = built }
        rebuildClosed()
    }

    private func rebuildClosed() {
        guard popoverOpen, viewState.mode == .closed else { return }
        // The pill filters the closed list too (R6). The live ids come from
        // every account: a session running under another pill is still
        // running, and so not closed.
        let pill = snapshot.selectedPill
        let entries = transcripts.filter { pill.includes(profileID: $0.profileID) }
        // Also the ids of live rows the display filter drops, and of resumes
        // typed but not yet registered: none of them is closed.
        let live = Set(live.compactMap(\.sessionId))
            .union(liveSessionIDs)
            .union(inFlight.ids(now: Date()))
            .union(tracker.inFlightSessionIDs())
        let built = ClosedSessionList.build(
            entries: entries,
            live: live,
            owned: [],
            renames: store.renames,
            search: viewState.search,
            now: Date()
        )
        if built != closedSections { closedSections = built }
    }

    /// Scans the transcript store off the main thread. Coalesced: a request
    /// that arrives while a scan runs asks for one more when it ends, never
    /// for two at once.
    private func refreshTranscripts() {
        guard !indexing else {
            indexAgain = true
            return
        }
        indexing = true
        let profiles = registryProfiles(for: config).map { TranscriptProfile(id: $0.id, directory: $0.directory) }
        let index = index
        Task.detached(priority: .userInitiated) { [weak self] in
            let entries = index.scan(profiles: profiles, now: Date())
            await self?.transcriptsScanned(entries)
        }
    }

    private func transcriptsScanned(_ entries: [TranscriptEntry]) {
        // A rescan that found what is already held changes nothing to draw.
        let changed = entries != transcripts
        if changed { transcripts = entries }
        closedReady = true
        indexing = false
        if changed { rebuild() }
        if indexAgain {
            indexAgain = false
            refreshTranscripts()
        }
    }

    // MARK: - Rows

    func profileName(forID id: String) -> String {
        guard let profile = config.profile(id: id) else { return id }
        return profile.name.isEmpty ? profile.id : profile.name
    }

    func message(forLive key: LiveSessionKey) -> String? {
        rowMessages[AccessibilityID.Popover.Sessions.liveRowKey(key)]
    }

    func message(forClosed sessionID: String) -> String? {
        rowMessages[AccessibilityID.Popover.Sessions.closedRowKey(sessionID: sessionID)]
    }

    func help(forLive key: LiveSessionKey) -> String? {
        rowHelps[AccessibilityID.Popover.Sessions.liveRowKey(key)]
    }

    private func setMessage(_ text: String?, help: String? = nil, forKey key: String) {
        rowMessages[key] = text
        rowHelps[key] = help
    }

    // MARK: - Focusing a live row

    /// Clicking a live row brings its terminal window and tab forward (R8).
    /// Returns true when it did, so the popover can close as it does after a
    /// launch; otherwise the row says why and what to do (R37).
    func focus(_ row: SessionRow) async -> Bool {
        await focusOnce(row.key) { await focusLive(row.live) }
    }

    /// A click on a notification (R32): the same focus a click on the row does,
    /// for a session the caller found in a fresh list. When it fails, the
    /// row's message is kept through the popover opening to show it.
    func focusForNotification(_ live: LiveSession) async -> Bool {
        await focusOnce(live.key) {
            let focused = await focusLive(live)
            if !focused { keepMessagesOnNextOpen = true }
            return focused
        }
    }

    /// Runs a focus for `key` unless one is already in flight for it, in
    /// which case it answers false without starting another.
    private func focusOnce(_ key: LiveSessionKey, _ focus: () async -> Bool) async -> Bool {
        guard focusing.insert(key).inserted else { return false }
        defer { focusing.remove(key) }
        return await focus()
    }

    /// The name a notification gives a session: the one its row shows, with
    /// the renames and transcript titles the tab has, so the banner and the
    /// row never disagree.
    func notificationTitle(for live: LiveSession) -> String {
        SessionSnapshot.rowTitle(for: live, transcripts: transcripts, renames: store.renames).text
    }

    /// The shared path for a click on a live row and for the restore guard's
    /// "already running" answer.
    ///
    /// Ownership is looked up here, from the ledger and the host, rather than
    /// taken from the caller: a notification click and the restore guard's
    /// "already running" answer reach this with a bare live row, and must
    /// reattach a detached owned session just as a click on its row does.
    private func focusLive(_ live: LiveSession) async -> Bool {
        let messageKey = AccessibilityID.Popover.Sessions.liveRowKey(live.key)
        setMessage(nil, forKey: messageKey)
        let owned = tracker.ownership(of: live)

        // An owned session with no window has no tab to bring forward.
        if let owned, owned.isHosted, owned.isDetached {
            return await openAttachedWindowForOwnedSession(live, owned)
        }

        let outcome: FocusOutcome
        // A hosted session's window belongs to the tmux client attached to
        // it: its tty, and the terminal the launch recorded, are what the
        // terminal knows the tab by (KTD10).
        switch TerminalFocus.request(
            for: live,
            terminals: environment.registry.terminals,
            clientTTY: owned?.clientTTY,
            terminalID: owned?.isHosted == true ? owned?.terminalID : nil
        ) {
        case .failure(let reason):
            outcome = .unavailable(reason)
        case .success(let request):
            outcome = await FocusService.focus(request)
        }
        HarnessJournal.shared.focusResult(key: live.key, outcome: outcome)
        if outcome.isFocused { return true }

        // R37: for an owned session a window that cannot be reached is
        // replaced rather than reported.
        if let owned, await openAttachedWindowForOwnedSession(live, owned) { return true }

        setMessage(outcome.message, help: outcome.explanation, forKey: messageKey)
        return false
    }

    /// An owned, tmux-hosted session with no window on screen, or whose
    /// window cannot be focused, gets a new terminal window attached to it
    /// instead (R8, R37). A plain owned session has nothing to attach to, so
    /// it answers false and the caller shows the ordinary message.
    private func openAttachedWindowForOwnedSession(_ live: LiveSession, _ owned: OwnedSessionInfo) async -> Bool {
        guard let launchID = owned.launchID, let directory = owned.cwd, !directory.isEmpty else { return false }
        let messageKey = AccessibilityID.Popover.Sessions.liveRowKey(live.key)
        do {
            try await attachWindow(launchID: launchID, workingDirectory: directory, terminalID: owned.terminalID)
            return true
        } catch {
            let reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            setMessage("Couldn't open a window for this session: \(reason)", forKey: messageKey)
            return false
        }
    }

    /// A new terminal window attached to a hosted session's tmux session, then
    /// the tracker re-reads so the row sees the window. The one place the three
    /// attach paths (a live row, Reopen all, a single restore) share; each
    /// keeps its own result mapping and message.
    private func attachWindow(launchID: String, workingDirectory: String, terminalID: String?) async throws {
        try await environment.openAttachWindow(
            launchID: launchID, workingDirectory: workingDirectory, terminalID: terminalID
        )
        tracker.refresh()
    }

    /// The same, for a session the ledger knows by `launchID`: the folder and
    /// terminal come from its row. False when the ledger has no such row.
    private func attachWindowForLedgerRow(launchID: String) async throws -> Bool {
        guard let row = store.ledger.row(launchID: launchID) else { return false }
        try await attachWindow(launchID: launchID, workingDirectory: row.cwd, terminalID: row.terminalID)
        return true
    }

    // MARK: - Renaming

    /// Why renaming is unavailable, or nil. A store this build cannot write
    /// (a newer schema, an unreadable file) is left exactly as it is.
    var renameUnavailableReason: String? {
        store.refusal.map { "Can't rename: \($0)" }
    }

    func canRename(_ row: SessionRow) -> Bool { row.sessionId != nil && store.refusal == nil }

    private func loadRenames() {
        _ = try? store.load()
    }

    func beginRename(live row: SessionRow) {
        guard canRename(row) else { return }
        renaming = .live(row.key)
        renameOriginal = row.name
        renameDraft = row.name
    }

    func beginRename(closed session: ClosedSession) {
        guard store.refusal == nil else { return }
        renaming = .closed(session.id)
        renameOriginal = session.name
        renameDraft = session.name
    }

    func cancelRename() { renaming = nil }

    /// Saves the draft for `sessionID`. A blank draft clears the rename, which
    /// puts the transcript's own title back; a draft equal to what the row
    /// already shows changes nothing, so opening the field and pressing Return
    /// does not turn a recorded title into a rename.
    func commitRename(sessionID: String?, messageKey: String) {
        defer { renaming = nil }
        guard let sessionID else { return }
        let draft = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard draft != renameOriginal.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        do {
            try store.setRename(draft.isEmpty ? nil : draft, for: sessionID)
            setMessage(nil, forKey: messageKey)
        } catch {
            setMessage("Couldn't save the name: \(error)", forKey: messageKey)
        }
        rebuild()
    }

    // MARK: - Header menu

    /// Quit all, Reopen all, Reopen last closed, each with its count. Quit all
    /// counts the owned live sessions in every account (U12); Reopen all counts
    /// the pending reopen set and Reopen last closed the depth of the closed
    /// stack (U14), both without what is already starting.
    var headerMenuItems: [SessionsHeaderMenuItem] {
        SessionsHeaderMenu.items(
            quitAllCount: quitAllCount,
            reopenAllCount: reopening == nil ? pendingReopenCount : 0,
            reopenLastClosedCount: closedStackCount
        )
    }

    /// Runs a header item. True when the popover should close, as after a
    /// launch: only a Reopen last closed that brought a session back does.
    @discardableResult
    func perform(_ kind: SessionsHeaderMenuItem.Kind) async -> Bool {
        switch kind {
        case .quitAll:
            quitAll()
            return false
        case .reopenAll:
            await reopenAll()
            return false
        case .reopenLastClosed:
            return await reopenLastClosed()
        }
    }

    // MARK: - Quitting (U12)

    /// Owned live sessions in every account, whichever pill is selected, that
    /// are not already on their way out: what Quit all would end. Counted from
    /// the list as it stands, without names, so the header can ask on every draw.
    private var quitAllCount: Int {
        var seen = Set<LiveSessionKey>()
        return live.filter { session in
            tracker.owned[session.key] != nil && !quitting.contains(session.key) && seen.insert(session.key).inserted
        }.count
    }

    private func quitCandidate(for session: LiveSession) -> QuitCandidate {
        QuitCandidate(
            key: session.key,
            name: notificationTitle(for: session),
            // An agent with no registry has no status, only that it is alive.
            status: session.isClaudeCode ? session.status : .unknown,
            isOwned: tracker.owned[session.key] != nil,
            accountName: session.isClaudeCode ? session.profileName : nil
        )
    }

    /// The row menu's Quit (R19): any live session. An owned one is recorded
    /// as quit from AgentMenu; one AgentMenu did not start is only signalled.
    func quit(_ row: SessionRow) {
        guard !quitting.contains(row.key) else { return }
        // The status the confirmation reasons from is read again, not taken
        // from the row: a turn can have begun since the list was drawn.
        let session = host.liveNow().sessions.first { $0.key == row.key } ?? row.live
        carryOut(QuitPolicy.planQuit(quitCandidate(for: session)))
    }

    /// Quit all (R20): every owned session in every account, never a script's.
    private func quitAll() {
        let sessions = host.liveNow().sessions.filter { !quitting.contains($0.key) }
        carryOut(QuitPolicy.planQuitAll(live: sessions.map(quitCandidate(for:))))
    }

    /// Asks when the plan says to (R21), then records the cause and sends
    /// SIGINT. Cancelling leaves everything as it was.
    private func carryOut(_ plan: QuitPlan) {
        guard !plan.isEmpty else { return }
        if let confirmation = plan.confirmation, !QuitConfirmationAlert.confirm(confirmation) { return }
        for (key, outcome) in quitter.quit(plan) {
            if case .failed(let reason) = outcome {
                setMessage("Couldn't quit: \(reason)", forKey: AccessibilityID.Popover.Sessions.liveRowKey(key))
            }
        }
        quittingChanged()
        // One that was already gone is not Quitting; make the list notice.
        host.sweep()
    }

    private func quittingChanged() {
        let now = quitter.quitting
        if now != quitting { quitting = now }
        if now.isEmpty {
            quitTimer?.invalidate()
            quitTimer = nil
        } else if quitTimer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.quitTick() }
            }
            RunLoop.main.add(timer, forMode: .common)
            quitTimer = timer
        }
    }

    /// Once a second while anything is Quitting: SIGTERM for what ignored
    /// SIGINT, and the end of the dimming for what has exited.
    private func quitTick() {
        let result = quitter.tick()
        for key in result.gaveUp {
            setMessage(
                "Still running after Quit.",
                help: "AgentMenu asked it to quit and then told it to terminate; it did not exit, and AgentMenu never force-kills a session.",
                forKey: AccessibilityID.Popover.Sessions.liveRowKey(key)
            )
        }
        if !result.finished.isEmpty {
            host.sweep()
            tracker.refresh()
        }
        quittingChanged()
    }

    // MARK: - Pending launches

    func dismissPending(_ id: String) {
        tracker.dismiss(launchID: id)
    }

    // MARK: - Resuming a closed session

    /// When a launch that never registered ages out, the Closed row it hid
    /// comes back: nothing else would redraw the list at that moment.
    private func scheduleInFlightExpiry() {
        let delay = UInt64((InFlightResumes.expiry + 0.5) * 1_000_000_000)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            self?.inFlightExpired()
        }
    }

    private func inFlightExpired() {
        inFlight.prune(live: liveSessionIDs, now: Date())
        rebuildClosed()
    }

    /// Clicking a restorable Closed row (R30, R31): through the guard and the
    /// owned path, with the recorded preset when AgentMenu launched the session
    /// and the transcript's account and the folder's preset when it did not.
    /// Returns true when the popover should close, as a successful launch does
    /// (R41).
    func resume(_ session: ClosedSession) async -> Bool {
        let id = session.id
        guard !resuming.contains(id) else { return false }
        resuming.insert(id)
        defer { resuming.remove(id) }

        let recorded = RestoreActions.recordedSession(for: id, state: store.restore, ledger: store.ledger)
        return await restoreSingle(source: .history(session.entry, recorded: recorded)).closesPopover
    }

    // MARK: - Reopen last closed

    /// The most recently closed owned session (R24), repeatable to walk back:
    /// the one launched stays on the stack until it is running, and is not
    /// offered meanwhile. True when the popover should close.
    func reopenLastClosed() async -> Bool {
        guard !reopeningLast else { return false }
        reopeningLast = true
        defer { reopeningLast = false }
        refreshRestoreOffer()
        guard let session = offer.lastClosed else { return false }

        let outcome = await restoreSingle(source: .recorded(session))
        if case .failed(let reason) = outcome {
            reopenSummary = ReopenAllSummary(
                total: 1,
                failures: [.init(name: restoreName(of: session), reason: reason)]
            )
        }
        return outcome.closesPopover
    }

    // MARK: - Reopen all

    /// Everything that was live when it last stopped together (R23), in batches
    /// of three (KTD14), each batch up before the next starts. Each session is
    /// restored through the same guard as any other; the ones that come up leave
    /// the pending set, and the ones that do not stay in it with the reason
    /// (R35). It never restores a session on its own: only this does, from a
    /// click.
    func reopenAll() async {
        guard reopening == nil else { return }
        refreshRestoreOffer()
        let items = offer.pending
        guard !items.isEmpty else { return }

        // The user has acted on this set: a later event no longer replaces what
        // is left of it.
        try? store.updateRestore { $0.markPendingTouched() }
        reopening = items.count
        reopenSummary = nil
        defer { reopening = nil }

        // `run` reads the names off the main actor, after its awaits, so they
        // are read here, where `transcripts` and the store live.
        let names = Dictionary(
            items.map { ($0.sessionID, restoreName(of: $0)) },
            uniquingKeysWith: { first, _ in first }
        )
        let results = await RestoreActions.run(
            items: items,
            sessionID: { $0.sessionID },
            name: { names[$0.sessionID] ?? $0.sessionID },
            start: { await self.startRestore($0) },
            settle: { await self.awaitRegistration(launchID: $0) }
        )

        try? store.updateRestore { RestoreActions.apply(results, to: &$0) }
        tracker.restoreChanged()
        let summary = RestoreActions.summary(of: results)
        reopenSummary = summary
        for result in results {
            HarnessJournal.shared.restoreResult(sessionID: result.sessionID, outcome: result.outcome.journal)
        }
        HarnessJournal.shared.reopenAll(total: summary.total, reopened: summary.reopened, failed: summary.failures.count)
        // R35: which and why is where the user looks, so a failure brings the
        // Sessions tab forward, whichever surface Reopen all was started from.
        if !summary.failures.isEmpty { AppDelegate.shared?.showSessions(mode: .live) }
    }

    /// The name a result strip gives a pending session.
    private func restoreName(of session: RestorableSession) -> String {
        RestoreActions.displayName(
            of: session,
            entry: transcripts.first { $0.sessionId == session.sessionID },
            rename: store.renames[session.sessionID]
        )
    }

    /// One session of a Reopen all: guard, plan, launch. A session that is
    /// already running is not an error (R27), and one running with no window
    /// gets a window attached instead.
    private func startRestore(_ session: RestorableSession) async -> RestoreStart<String> {
        let (snapshot, _) = freshGuardSnapshot()
        do {
            let started = try await environment.restore(.recorded(session), guardSnapshot: snapshot)
            noteRestoreStarted(session.sessionID)
            return .started(started.launchID)
        } catch let refusal as HistoryResumeRefusal {
            if case .runningDetached(let launchID) = refusal {
                do {
                    if try await attachWindowForLedgerRow(launchID: launchID) { return .finished(.alreadyRunning) }
                } catch {
                    return .finished(.failed(
                        reason: "It is already running, but a window couldn't be opened for it.", journal: .failed
                    ))
                }
            }
            return .finished(RestoreActions.outcome(for: refusal, sessionID: session.sessionID, ledger: store.ledger))
        } catch {
            return .finished(.failed(reason: Self.describe(error), journal: .failed))
        }
    }

    /// Waits for a restore to register (or fail) the way the ledger sees it:
    /// "No conversation found" cannot be read, but a resume that does not come
    /// up inside the launch timeout is a quiet per-session failure with the
    /// ledger's reason, and the session stays where it was.
    private func awaitRegistration(launchID: String) async -> RestoreItemOutcome {
        let deadline = Date().addingTimeInterval(RestoreActions.settleTimeout)
        while true {
            switch RestoreActions.registration(of: store.ledger.row(launchID: launchID)) {
            case .registered:
                return .reopened
            case .failed(let reason):
                return .failed(reason: reason, journal: .failed)
            case .waiting:
                if Date() >= deadline {
                    return .failed(reason: RestoreActions.restoreFailure(LaunchLedger.timeoutReason), journal: .failed)
                }
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
        }
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    /// The typed command has not registered yet: keep the session out of the
    /// guard's reach until it does, or for `InFlightResumes.expiry`.
    private func noteRestoreStarted(_ sessionID: String) {
        inFlight.begin(sessionID, now: Date())
        scheduleInFlightExpiry()
    }

    /// What the guard must see, read fresh from the registry rather than the
    /// last list delivered: the guard exists to stop a second process on one
    /// transcript, and a session that started a moment ago is the one it has to
    /// see (KTD13).
    private func freshGuardSnapshot() -> (snapshot: RestoreGuardSnapshot, live: [LiveSession]) {
        let registry = host.liveNow()
        let now = Date()
        // The registry just read is the freshest view there is, so an
        // in-flight launch that has registered is over before the guard looks.
        inFlight.prune(live: registry.liveSessionIDs, now: now)
        let snapshot = RestoreGuardSnapshot(
            liveSessions: registry.sessions,
            otherLiveSessionIDs: registry.liveSessionIDs,
            // Resumes typed a moment ago, and launches the ledger still waits on.
            inFlight: inFlight.ids(now: now).union(tracker.inFlightSessionIDs(now: now)),
            ledger: store.ledger,
            host: tracker.hostSnapshot,
            now: now
        )
        return (snapshot, registry.sessions)
    }

    // MARK: - One restore, from a click or a shortcut

    private enum SingleRestore {
        case launched
        case focused
        case failed(String)

        var closesPopover: Bool {
            if case .failed = self { return false }
            return true
        }
    }

    /// One session through the guard and the owned path. A session that is
    /// already running is brought forward instead of resumed (R27, AE3): a live
    /// row is focused, and an owned one with no window gets one attached (AE2).
    /// Where a failure is said is the Closed row for the session, or its live
    /// row when the session is running.
    private func restoreSingle(source: RestoreSource) async -> SingleRestore {
        let id = source.sessionID
        let closedKey = AccessibilityID.Popover.Sessions.closedRowKey(sessionID: id)
        setMessage(nil, forKey: closedKey)

        /// Records how the attempt ended.
        func finish(_ outcome: JournalData.RestoreOutcome, _ result: SingleRestore) -> SingleRestore {
            HarnessJournal.shared.restoreResult(sessionID: id, outcome: outcome)
            return result
        }
        func fail(_ text: String, on key: String, _ outcome: JournalData.RestoreOutcome) -> SingleRestore {
            setMessage(text, forKey: key)
            return finish(outcome, .failed(text))
        }

        let (snapshot, liveNow) = freshGuardSnapshot()
        do {
            _ = try await environment.restore(source, guardSnapshot: snapshot)
            noteRestoreStarted(id)
            return finish(.launched, .launched)
        } catch let refusal as HistoryResumeRefusal {
            let outcome = JournalData.RestoreOutcome(refusal: refusal)
            // An owned session that is running with no window (the guard says
            // reattach) is the same case as a live row: its row is brought
            // forward, which opens a window attached to it (R8, R27).
            var focusKey: LiveSessionKey?
            if case .alreadyLive(let focus) = refusal { focusKey = focus.first }
            if case .runningDetached(let launchID) = refusal {
                focusKey = liveNow.first { tracker.ownership(of: $0)?.launchID == launchID }?.key
                if focusKey == nil {
                    // No registry row to bring forward: attach a window to
                    // its tmux session directly.
                    do {
                        if try await attachWindowForLedgerRow(launchID: launchID) {
                            dropFromRestoreLists(id)
                            return finish(.focusedLive, .focused)
                        }
                    } catch {
                        return fail("Already running, but a window couldn't be opened for it.", on: closedKey, .failed)
                    }
                }
            }
            if let key = focusKey {
                // The session is already running: bring its terminal forward
                // instead. The journal's "focused live" is recorded only when
                // that happened; when it did not, the live row says why.
                dropFromRestoreLists(id)
                viewState.mode = .live
                rebuild()
                let liveKey = AccessibilityID.Popover.Sessions.liveRowKey(key)
                if let live = liveNow.first(where: { $0.key == key }), await focusLive(live) {
                    return finish(.focusedLive, .focused)
                }
                if rowMessages[liveKey] == nil {
                    setMessage("Already running, but its terminal couldn't be brought forward.", forKey: liveKey)
                }
                return finish(.failed, .failed(rowMessages[liveKey] ?? "Already running."))
            }
            if case .runningElsewhere = refusal { dropFromRestoreLists(id) }
            if case .launchInFlight = refusal, let reason = RestoreActions.recentFailure(of: id, in: store.ledger) {
                return fail("Can't resume: \(reason)", on: closedKey, outcome)
            }
            return fail("Can't resume: \(refusal.description).", on: closedKey, outcome)
        } catch {
            return fail(Self.describe(error), on: closedKey, .failed)
        }
    }

    /// A session that is running is not waiting to be reopened (R27): the
    /// planner drops it at its next look, and this does it now.
    private func dropFromRestoreLists(_ sessionID: String) {
        try? store.updateRestore { $0.restored([sessionID]) }
        tracker.restoreChanged()
    }
}

// MARK: - The registry watchers

/// The registry reader, its vnode watchers and the sweep timer, on one serial
/// queue (KTD9): `RegistryMonitor` is single-threaded by design, and the work
/// it does — directory listings, file reads, a process-table scan — has no
/// business on the main thread every two seconds.
///
/// Not main-actor isolated, and `@unchecked Sendable` for the usual reason:
/// every mutable field is touched only from `queue`.
private final class RegistryHost: @unchecked Sendable {
    private let queue = DispatchQueue(label: "dev.facens.agentmenu.registry", qos: .utility)
    private let deliver: @Sendable ([LiveSession]) -> Void
    private let deliverIDs: @Sendable (Set<String>) -> Void
    private var monitor: RegistryMonitor?
    private var timer: DispatchSourceTimer?
    /// Bumped on every restart, so a late callback from a replaced monitor is
    /// ignored rather than delivered over its successor's list.
    private var generation = 0

    init(
        deliver: @escaping @Sendable ([LiveSession]) -> Void,
        deliverIDs: @escaping @Sendable (Set<String>) -> Void
    ) {
        self.deliver = deliver
        self.deliverIDs = deliverIDs
    }

    deinit {
        timer?.cancel()
        monitor?.stop()
    }

    func start(profiles: [RegistryProfile], scanTargets: [AgentScanTarget], terminals: [TerminalManifest]) {
        queue.async { [self] in
            stopOnQueue()
            generation += 1
            let current = generation
            let reader = RegistryReader(
                profiles: profiles,
                scanTargets: scanTargets,
                terminalResolver: TerminalHostResolver(terminals: terminals)
            )
            let monitor = RegistryMonitor(reader: reader, watcher: VnodeWatcher(queue: queue)) { [weak self] sessions in
                self?.changed(sessions, generation: current)
            }
            monitor.onLiveSessionIDsChange = { [weak self] ids in
                guard let self, generation == current else { return }
                deliverIDs(ids)
            }
            self.monitor = monitor
            monitor.start()
        }
    }

    /// Re-reads now, without waiting for the timer. The popover's refresh.
    func sweep() {
        queue.async { [self] in monitor?.sweep() }
    }

    /// Re-reads and returns what is live, blocking until it has: the listed
    /// sessions, and the ids of every live registry row, listed or not. For
    /// the restore guard, which must not decide from a stale list.
    func liveNow() -> (sessions: [LiveSession], liveSessionIDs: Set<String>) {
        queue.sync {
            monitor?.sweep()
            return (monitor?.sessions ?? [], monitor?.liveSessionIDs ?? [])
        }
    }

    // MARK: On the queue

    private func changed(_ sessions: [LiveSession], generation: Int) {
        guard generation == self.generation else { return }
        setSweeping(SweepPolicy.isActive(listedSessions: sessions.count))
        deliver(sessions)
    }

    /// The sweep runs while anything is listed, whether or not the popover is
    /// open: a dead process whose file was never removed would otherwise keep
    /// the badge lit until someone looked.
    private func setSweeping(_ active: Bool) {
        if active, timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + SweepPolicy.interval, repeating: SweepPolicy.interval, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.monitor?.sweep() }
            timer.resume()
            self.timer = timer
        } else if !active, let timer {
            timer.cancel()
            self.timer = nil
        }
    }

    private func stopOnQueue() {
        timer?.cancel()
        timer = nil
        monitor?.stop()
        monitor = nil
    }
}
