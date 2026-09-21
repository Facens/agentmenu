// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Sparkle
import AgentMenuKit

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

    /// Called when a scheduled update is waiting for the user to notice it,
    /// and again with `false` once it is no longer waiting. Drives the
    /// status-item badge and the popover's own row (R18) — a menu-bar app
    /// with no Dock icon cannot rely on Sparkle's alert being seen.
    private let updatePending: (Bool) -> Void

    init(
        version: String = agentMenuVersion,
        publicKey: String? = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String,
        betaEnabled: @escaping () -> Bool,
        updatePending: @escaping (Bool) -> Void
    ) {
        self.betaEnabled = betaEnabled
        self.updatePending = updatePending
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

    /// The popover's manual check (R13). Sparkle drives its own window from
    /// here; AgentMenu's popover is `.applicationDefined`, so that window
    /// appearing over it does not dismiss it.
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
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
            updatePending(!handleShowingUpdate)
        }
    }

    nonisolated func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        MainActor.assumeIsolated { updatePending(false) }
    }

    nonisolated func standardUserDriverWillFinishUpdateSession() {
        MainActor.assumeIsolated { updatePending(false) }
    }
}
