// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import Foundation
@preconcurrency import UserNotifications
import AgentMenuKit

/// The app half of Needs-you notifications (R32, KTD15): everything
/// `NotificationPlanner` leaves to its caller because it needs AppKit or
/// `UserNotifications`, and nothing else. What to post and when is the
/// planner's; this class feeds it, does what it says, and answers the two
/// questions it asks.
///
/// - **Feeding.** `SessionsModel` hands over each list the registry reports
///   (`sessionsChanged`), and a timer re-evaluates when the planner's next
///   hold-down expires, since a session that stays in Needs you changes no
///   registry file at all.
/// - **Authorization.** Asked on a user action — the first launch AgentMenu
///   makes, or the first open of the Sessions tab — never at app start, where a
///   menu-bar app's prompt can land behind a window. `notifications_asked`
///   records that it was asked. Read back with `getNotificationSettings`, which
///   never prompts.
/// - **Frontmost (KTD10's exception).** When the planner asks whether a
///   session's tab is on screen, the terminal is asked once through its
///   `frontmost_tty_applescript` — and only if `NSWorkspace` says it is the
///   frontmost app and macOS has already granted the Automation access, so no
///   Apple Event is sent to an app that is not running and no permission sheet
///   comes from a timer.
/// - **Startup.** Nothing is evaluated until the first registry list *and* the
///   delivered notifications have both arrived: notifications outlive the app,
///   and the planner reconciles what an earlier run left on screen against that
///   first list.
///
/// Not available when the process is not an app bundle (`swift run`):
/// `UNUserNotificationCenter.current()` raises there.
@MainActor
final class SessionNotifier: NSObject, ObservableObject {
    /// What macOS says. `.notDetermined` until it has been read.
    @Published private(set) var authorization: NotificationAuthorization = .notDetermined

    private unowned let environment: AppEnvironment
    private var planner = NotificationPlanner()
    private var latestLive: [LiveSession]?
    /// The delivered notifications and the authorization status have been read.
    private var startupLoaded = false
    private var started = false
    private var notifyNeedsYou = true
    private var notifyYourTurn = true
    /// Sessions AgentMenu launched (U11): the only ones that get a Your-turn
    /// notification (R33).
    private var owned: Set<LiveSessionKey> = []
    private var answers: [String: FrontmostAnswer] = [:]
    private var timer: Timer?
    private var cancellables: Set<AnyCancellable> = []

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init()
    }

    /// `UserNotifications` needs a real bundle. Under `swift run` there is none.
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    private var center: UNUserNotificationCenter? {
        Self.isAvailable ? UNUserNotificationCenter.current() : nil
    }

    // MARK: - Launch

    /// From `applicationWillFinishLaunching`: the delegate has to be in place
    /// before launch completes, or a click that launched the app is lost.
    func installDelegate() {
        center?.delegate = self
        registerCategories()
    }

    /// The host-death notification's category, with its one action (R34):
    /// categories are registered before any notification is posted, and survive
    /// the app, so a click on the action after a relaunch still lands here.
    private func registerCategories() {
        let reopenAll = UNNotificationAction(
            identifier: HostDeathNotification.reopenAllActionIdentifier,
            title: HostDeathNotification.reopenAllTitle,
            options: []
        )
        let category = UNNotificationCategory(
            identifier: HostDeathNotification.categoryIdentifier,
            actions: [reopenAll],
            intentIdentifiers: [],
            options: []
        )
        center?.setNotificationCategories([category])
    }

    /// From launch, before the registry watchers start.
    func start() {
        guard !started else { return }
        started = true
        // The sink's own parameter, never `environment.config`: `@Published`
        // fires before the new value is stored.
        environment.$config
            .sink { [weak self] config in
                MainActor.assumeIsolated {
                    self?.notifyNeedsYou = config.notifyNeedsYou
                    self?.notifyYourTurn = config.notifyYourTurn
                    self?.evaluate()
                }
            }
            .store(in: &cancellables)
        // The user fixes a denial in System Settings and comes back: the
        // guidance must go without anyone reopening a tab.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.refreshAuthorization() } }
            .store(in: &cancellables)
        loadStartupState()
    }

    private func loadStartupState() {
        guard let center else { return }
        center.getNotificationSettings { [weak self] settings in
            let status = Self.authorization(from: settings.authorizationStatus)
            center.getDeliveredNotifications { [weak self] delivered in
                let parsed = delivered.compactMap { note -> DeliveredNotification? in
                    let info = note.request.content.userInfo as? [String: String] ?? [:]
                    return DeliveredNotification(identifier: note.request.identifier, userInfo: info)
                }
                Task { @MainActor [weak self] in self?.startupRead(status: status, delivered: parsed) }
            }
        }
    }

    private func startupRead(status: NotificationAuthorization, delivered: [DeliveredNotification]) {
        authorization = status
        planner.seed(delivered: delivered)
        startupLoaded = true
        evaluate()
    }

    private nonisolated static func authorization(from status: UNAuthorizationStatus) -> NotificationAuthorization {
        switch status {
        case .authorized, .provisional, .ephemeral: return .authorized
        case .denied: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notDetermined
        }
    }

    // MARK: - Authorization (KTD15)

    /// Puts the question to macOS if it has not been put. Called from the two
    /// user actions, and from the Settings toggle being turned on.
    func requestAuthorizationIfNeeded() {
        guard Self.isAvailable, NotificationAuthorizationPolicy.shouldRequest(config: environment.config) else { return }
        // Recorded before the answer, so a second action while the prompt is
        // up cannot ask again, and so a crash under it does not leave the
        // question to be asked twice.
        environment.update { $0.notificationsAsked = true }
        environment.flushPendingSave()
        center?.requestAuthorization(options: [.alert]) { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshAuthorization() }
        }
    }

    /// Re-reads what macOS says. Never prompts.
    func refreshAuthorization() {
        guard let center else { return }
        center.getNotificationSettings { [weak self] settings in
            let status = Self.authorization(from: settings.authorizationStatus)
            Task { @MainActor in
                guard let self else { return }
                if self.authorization != status { self.authorization = status }
                self.evaluate()
            }
        }
    }

    // MARK: - Feeding the planner

    func sessionsChanged(_ live: [LiveSession]) {
        latestLive = live
        evaluate()
    }

    /// Which live sessions AgentMenu owns changed (a launch registered, one
    /// ended). Evaluated again only when it differs: this follows every
    /// reconcile.
    func ownedChanged(_ keys: Set<LiveSessionKey>) {
        guard keys != owned else { return }
        owned = keys
        evaluate()
    }

    private func evaluate() {
        guard Self.isAvailable, startupLoaded, let live = latestLive else { return }
        let sessions = environment.sessions
        let input = NotificationInput(
            now: Date(),
            live: live,
            // Your turn is for sessions AgentMenu launched, after a turn of at
            // least 30 seconds; the planner holds both rules (R33).
            owned: owned,
            settings: NotificationSettings(needsYou: notifyNeedsYou, yourTurn: notifyYourTurn),
            authorization: authorization,
            frontmost: answers,
            title: { sessions.notificationTitle(for: $0) }
        )
        answers = [:]
        perform(planner.evaluate(input))
    }

    private func perform(_ plan: NotificationPlan) {
        if let center {
            if !plan.withdrawals.isEmpty {
                // Delivered ones leave the centre; pending ones cannot exist
                // for an immediate trigger, but costs nothing to clear.
                center.removeDeliveredNotifications(withIdentifiers: plan.withdrawals)
                center.removePendingNotificationRequests(withIdentifiers: plan.withdrawals)
            }
            for note in plan.posts { post(note, to: center) }
        }
        for check in plan.frontmostChecks { askFrontmost(check) }
        schedule(deadline: plan.nextDeadline)
    }

    private func post(_ note: PlannedNotification, to center: UNUserNotificationCenter) {
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        content.threadIdentifier = note.threadID
        content.userInfo = note.userInfo
        center.add(UNNotificationRequest(identifier: note.identifier, content: content, trigger: nil)) { error in
            if let error { FileHandle.standardError.write(Data("agentmenu: notification not posted: \(error)\n".utf8)) }
        }
    }

    /// One timer, for the earliest hold-down still running.
    private func schedule(deadline: Date?) {
        timer?.invalidate()
        timer = nil
        guard let deadline else { return }
        // A hair past the deadline, so the clock the planner reads is not
        // still a hair before it.
        let timer = Timer(fire: deadline.addingTimeInterval(0.05), interval: 0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - The host died (R34)

    /// The one notification that follows a host death: how many sessions
    /// ended, with Reopen all as its action. Clicking its body opens the
    /// Sessions tab. Nothing is restored here: a crash mid-turn deserves the
    /// user's eyes first. Not posted when macOS has notifications turned off
    /// for AgentMenu; the banner above the tabs offers the same Reopen all.
    func postHostDeath(_ notice: HostDeathNotice) {
        guard let center, authorization != .denied, let note = HostDeathNotification.make(for: notice) else { return }
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        content.categoryIdentifier = HostDeathNotification.categoryIdentifier
        content.userInfo = note.userInfo
        content.threadIdentifier = HostDeathNotification.identifier
        center.add(UNNotificationRequest(identifier: HostDeathNotification.identifier, content: content, trigger: nil)) { error in
            if let error { FileHandle.standardError.write(Data("agentmenu: notification not posted: \(error)\n".utf8)) }
        }
    }

    /// The sessions it offered are back (or dismissed): the offer goes.
    func withdrawHostDeath() {
        center?.removeDeliveredNotifications(withIdentifiers: [HostDeathNotification.identifier])
    }

    // MARK: - Which tab is on screen (KTD10's exception)

    private func askFrontmost(_ check: FrontmostCheck) {
        let terminalID = check.terminalID
        let terminals = environment.registry.terminals
        // Read here, on the main thread, at the moment the hold-down expired —
        // not after a script has run and the user has moved on.
        let frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        Task.detached(priority: .userInitiated) { [weak self] in
            let answer: FrontmostAnswer
            if let request = FrontmostTTYProbe.request(terminalID: terminalID, terminals: terminals) {
                // Seconds, not the focus path's two minutes: this runs from a
                // timer, and a banner that arrives late is a banner for a
                // prompt already answered.
                answer = FrontmostTTYProbe(
                    runner: TerminalFocus.systemRunner(exitTimeout: 3),
                    automationGranted: { Self.automationGranted(bundleID: $0) }
                ).answer(request, frontmostBundleID: frontmostBundleID)
            } else {
                answer = .notFrontmost
            }
            await self?.frontmostAnswered(terminalID, answer)
        }
    }

    private func frontmostAnswered(_ terminalID: String, _ answer: FrontmostAnswer) {
        answers[terminalID] = answer
        evaluate()
    }

    /// Whether macOS already lets AgentMenu control this app, asked without
    /// prompting (`AutomationConsent.query` passes `askUserIfNeeded: false`).
    /// Only a granted answer counts: pending, denied and not-running all skip
    /// the probe, so this timer can never raise the consent prompt.
    private nonisolated static func automationGranted(bundleID: String) -> Bool {
        AutomationConsent.query(bundleID: bundleID) == .granted
    }

    // MARK: - A click (R32, R8)

    /// The Reopen all action of the host-death notification: the same Reopen all
    /// as the header menu and the banner, through the same guard. A click that
    /// launched the app arrives before the first registry list, so it waits for
    /// that like any click.
    fileprivate func handleReopenAll() async {
        let sessions = environment.sessions
        await sessions.waitForFirstList(timeout: 2)
        await sessions.reopenAll()
    }

    /// Brings the session's terminal forward, exactly as a click on its row
    /// does; a session that has ended sends the user to Closed instead.
    fileprivate func handleClick(userInfo: [String: String]) async {
        let sessions = environment.sessions
        // A click that launched the app arrives before the first registry
        // list does: resolving against an empty list would call every such
        // session ended.
        await sessions.waitForFirstList(timeout: 2)
        let live = sessions.liveNow()
        switch NotificationClick.resolve(userInfo: userInfo, live: live) {
        case .focus(let key):
            guard let session = live.first(where: { $0.key == key }) else {
                AppDelegate.shared?.showSessions(mode: .closed)
                return
            }
            if await sessions.focusForNotification(session) { return }
            // The row says why it failed, and the popover is where it says it.
            AppDelegate.shared?.showSessions(mode: .live)
        case .showClosed:
            AppDelegate.shared?.showSessions(mode: .closed)
        case .showLive:
            AppDelegate.shared?.showSessions(mode: .live)
        }
    }
}

// MARK: - The delegate

extension SessionNotifier: UNUserNotificationCenterDelegate {
    /// A banner even while AgentMenu is frontmost — it is an accessory app and
    /// is "frontmost" whenever its popover is open — and kept in Notification
    /// Center, which is where the startup reconciliation reads from.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list]
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        if response.actionIdentifier == HostDeathNotification.reopenAllActionIdentifier {
            await self.handleReopenAll()
            return
        }
        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier else { return }
        let userInfo = response.notification.request.content.userInfo as? [String: String] ?? [:]
        await self.handleClick(userInfo: userInfo)
    }
}
