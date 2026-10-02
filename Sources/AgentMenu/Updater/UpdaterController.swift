// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Sparkle
import AgentMenuKit

/// What the status item and the popover say about a waiting update.
enum PendingUpdate: Equatable {
    case none
    /// Sparkle offered an update it is not showing a window for (R18).
    case offered
    /// Sparkle downloaded an update silently and is holding it for a
    /// relaunch. The popover offers to restart now; the app does it by
    /// itself at a quiet moment.
    case readyToRelaunch
}

/// Everything this app knows about updating itself (U11 / R12, R13, R14,
/// R18). The rules about *whether* to update and *what channel* to accept
/// are `AgentMenuKit.UpdatePolicy`'s, where the test runner can reach them;
/// what is left here is the part that needs Sparkle in the process.
///
/// Held as a stored property by `AppDelegate`, never as a local: a
/// `SPUStandardUpdaterController` that goes out of scope is deallocated and
/// simply stops checking, with no error anywhere — the same silent failure
/// the app already guards against for its status item.
@MainActor
final class UpdaterController: NSObject {

    /// Nil when this build must not update itself, with `refusal` saying
    /// why. Settings reads both: a disabled toggle with no explanation is
    /// indistinguishable from a broken one.
    private(set) var updater: SPUUpdater?
    private(set) var refusal: UpdatePolicy.Refusal?

    /// Kept alive for as long as the updater is: the controller owns the
    /// user driver, and the driver's delegate is this object.
    private var controller: SPUStandardUpdaterController?

    /// Whether this copy has opted into betas. Read through a closure rather
    /// than copied in, because Sparkle asks for the allowed channels on
    /// every check and the answer must be the preference as it stands then,
    /// not as it stood at launch.
    private let betaEnabled: () -> Bool

    /// Called whenever what is waiting changes. Drives the status-item badge
    /// and the popover's own row (R18) — a menu-bar app with no Dock icon
    /// cannot rely on Sparkle's alert being seen.
    private let pendingChanged: (PendingUpdate) -> Void

    /// What the app is doing now, read each time a held install is
    /// considered. See `UpdatePolicy.mayInstallNow`.
    private let moment: () -> UpdatePolicy.Moment

    /// Sparkle's handler for installing a silently downloaded update now and
    /// relaunching. Sparkle would otherwise install it only when the app
    /// quits, and a menu-bar app can run for weeks without quitting. Holding
    /// it also stops Sparkle's update cycle, so it must be run eventually,
    /// or this copy never sees another version. Kept after it runs: Sparkle allows it to
    /// be run again if the termination is cancelled.
    private var heldInstall: (() -> Void)?
    /// Rechecks for a quiet moment while an install is held.
    private var quietTimer: Timer?
    /// Sparkle has offered an update without a window of its own.
    private var offered = false

    init(
        version: String = agentMenuVersion,
        publicKey: String? = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
        betaEnabled: @escaping () -> Bool,
        moment: @escaping () -> UpdatePolicy.Moment,
        pendingChanged: @escaping (PendingUpdate) -> Void
    ) {
        self.betaEnabled = betaEnabled
        self.moment = moment
        self.pendingChanged = pendingChanged
        super.init()

        if let refusal = UpdatePolicy.refusal(version: version, publicKey: publicKey) {
            self.refusal = refusal
            // Standard error, like HarnessJournal's own refusal line: this
            // target has no logging layer, and the one place this matters —
            // a build started from a shell during a rehearsal — is reading
            // stderr anyway. Settings says the same thing to the user.
            note("updater not started: \(refusal.description)")
            return
        }

        // `startingUpdater: false` and an explicit start, so a failure to
        // start is this object's to report rather than a throw inside an
        // initializer nobody can catch.
        let controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        do {
            try controller.updater.start()
        } catch {
            // A feed this build cannot read is not a reason to take the app
            // down, and it is not something the user can act on beyond
            // reinstalling. Say it once, leave `updater` nil, and let
            // Settings show the section as unavailable.
            note("updater failed to start: \(error)")
            return
        }
        self.controller = controller
        self.updater = controller.updater
    }

    /// The manual check (R13). Sparkle drives its own window from here. The
    /// caller closes the popover first: it floats above other windows, so
    /// Sparkle's window opened under it with its default button hidden.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Installs the held update and relaunches, now. Sessions survive it:
    /// they live in the tmux host, not in the app.
    func installNow() {
        guard let heldInstall else { return }
        quietTimer?.invalidate()
        quietTimer = nil
        heldInstall()
    }

    private func publish() {
        pendingChanged(heldInstall != nil ? .readyToRelaunch : offered ? .offered : .none)
    }

    private func hold(_ install: @escaping () -> Void) {
        heldInstall = install
        publish()
        quietTimer?.invalidate()
        // Once a minute is plenty against a ten-minute idle threshold.
        // `.common`, so it keeps firing while a menu is tracking.
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.installIfQuiet() }
        }
        RunLoop.main.add(timer, forMode: .common)
        quietTimer = timer
    }

    private func installIfQuiet() {
        guard UpdatePolicy.mayInstallNow(moment()) else { return }
        installNow()
    }

    /// The Settings toggle (R13). Sparkle owns this preference — it is read
    /// and written through the updater rather than mirrored into
    /// `config.toml`, because two copies of one setting are two settings
    /// (KTD8).
    var automaticallyChecksForUpdates: Bool {
        get { updater?.automaticallyChecksForUpdates ?? false }
        set { updater?.automaticallyChecksForUpdates = newValue }
    }

    /// When the last check happened, for the Settings section to show. Nil
    /// before the first one.
    var lastUpdateCheckDate: Date? { updater?.lastUpdateCheckDate }

    private func note(_ message: String) {
        FileHandle.standardError.write(Data("AgentMenu: \(message)\n".utf8))
    }
}

// MARK: - SPUUpdaterDelegate

extension UpdaterController: SPUUpdaterDelegate {

    /// KTD20: channels are Sparkle channels inside one feed. An empty set is
    /// the default channel — where finals live — and `["beta"]` adds the
    /// beta items to it. A final carries no channel at all, so it supersedes
    /// every beta of its version whatever this returns.
    nonisolated func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        // Sparkle asks off the main actor; the preference read behind this
        // closure is a value copy of a defaults/config read, not UI state.
        MainActor.assumeIsolated { UpdatePolicy.allowedChannels(betaEnabled: betaEnabled()) }
    }

    /// Sparkle downloaded an update silently and would install it at quit.
    /// Returning true takes the install over: the app runs the handler at a
    /// quiet moment, or when the user picks Restart to Update. Sparkle still
    /// installs at quit if neither happens first.
    nonisolated func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        // Sparkle calls its delegate on the main thread, as for the channels
        // above.
        nonisolated(unsafe) let install = immediateInstallHandler
        MainActor.assumeIsolated { hold(install) }
        return true
    }
}

// MARK: - SPUStandardUserDriverDelegate

extension UpdaterController: SPUStandardUserDriverDelegate {

    /// R18. Without this, Sparkle logs a warning and shows its alert in the
    /// ordinary way — which for an app with no Dock icon means an alert
    /// behind whatever the user is doing, for an app they may not remember
    /// is running.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    /// A scheduled update wants attention. `immediateFocus` is true when the
    /// user themselves asked for a check, and then Sparkle's window is the
    /// right answer; otherwise the badge and the popover row are, and the
    /// window waits until they act on one of them.
    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        immediateFocus
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        MainActor.assumeIsolated {
            // Badge whenever Sparkle is not putting its own window in front:
            // that is exactly the case where nothing else on screen says an
            // update is waiting.
            offered = !handleShowingUpdate
            publish()
        }
    }

    // These two clear only Sparkle's offer. A held install stays pending
    // until it runs: picking Install on Quit in Sparkle's window ends the
    // session, and the update is still waiting.
    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated {
            offered = false
            publish()
        }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated {
            offered = false
            publish()
        }
    }
}
