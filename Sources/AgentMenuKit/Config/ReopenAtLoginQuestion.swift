// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where — if anywhere — the "reopen sessions at login?" question is asked, and
/// what answering it does (R25).
///
/// The same ask-once shape as `LaunchAtLoginQuestion`, with one difference that
/// follows from what the question is about: this one means nothing before a
/// reopen set exists, so it is not asked at first launch and never from a modal.
/// It lives inside the post-restart banner, the first time that banner is shown
/// for a restart. Until it is answered the setting is off, and a restart only
/// ever offers; it never restores on its own.
///
/// Pure over `Config` and the restore offer, so `AgentMenuKitTests` can cover it:
/// the banner and the General pane (both in the app target, out of that suite's
/// reach) read their decisions from here.
public enum ReopenAtLoginQuestion: Equatable {
    /// Ask it in the banner, under the line that says what is waiting.
    case inBanner
    /// Already answered, either way, or the setting was turned on by hand: it is
    /// not asked.
    case alreadyAsked
    /// There is nothing to reopen after a restart, so the question has no
    /// meaning yet.
    case notOffered

    public static func surface(for config: Config, offer: RestoreOffer) -> ReopenAtLoginQuestion {
        guard !config.reopenAtLoginAsked, !config.reopenAtLogin else { return .alreadyAsked }
        return isRestartSet(offer) ? .inBanner : .notOffered
    }

    /// Whether the offer is the set a restart leaves: sessions that were running
    /// when the Mac went down (`.powerOff`, which is what a changed boot id or a
    /// logout or shutdown notification classifies as). A Quit all (the user's own
    /// act), a host that died (R34) and an unexplained ending are not restarts.
    public static func isRestartSet(_ offer: RestoreOffer) -> Bool {
        offer.pendingCount > 0 && offer.pendingCause == .powerOff
    }

    /// Records an answer. Either answer counts as asked; yes also turns the
    /// setting on, no leaves it off. The setting itself is changed later, from
    /// Settings › General, with `setReopenAtLogin`.
    public static func record(answer reopenAtLogin: Bool, in config: inout Config) {
        config.reopenAtLoginAsked = true
        config.reopenAtLogin = reopenAtLogin
    }

    // MARK: Wording

    /// The line under the banner's message.
    public static let prompt = "Reopen sessions like these automatically at login after a restart?"
    /// Reopens this set now, and turns the setting on.
    public static let yesTitle = "Reopen now and at login"
    /// Turns nothing on and reopens nothing; the banner's own Reopen all is still
    /// there for this time.
    public static let noTitle = "Not at login"
}

extension Config {
    /// The Settings › General toggle. Moving it is an answer to the question too,
    /// so the banner never asks something the user has already decided.
    public mutating func setReopenAtLogin(_ on: Bool) {
        reopenAtLogin = on
        reopenAtLoginAsked = true
    }
}

/// Whether AgentMenu restores the pending set by itself, at startup (R25).
///
/// Decided once per launch, at the first moment the restore state is a fair
/// reading of this launch's own relaunch pass: before that, a set from an
/// earlier run could be taken for this restart's, and after it, a set formed
/// later in the run (a cancelled logout) is not what "at login" means.
public enum ReopenAtLoginStartup {
    /// - Parameters:
    ///   - setting: `config.reopenAtLogin`.
    ///   - bootChangedAtLaunch: the boot id the store held when AgentMenu started
    ///     differs from this boot's (`BootID.hasChanged`). Without it, AgentMenu
    ///     was only restarted, and the sessions it would reopen are ones the user
    ///     closed or that it already offered.
    ///   - launchPassDone: the relaunch classification has run, so the pending
    ///     set is this launch's.
    ///   - offer: what Reopen all would bring back right now.
    public static func shouldRestore(
        setting: Bool, bootChangedAtLaunch: Bool, launchPassDone: Bool, offer: RestoreOffer
    ) -> Bool {
        // A set whose cause is anything but a restart is never restored on its
        // own: a crashed session host deserves the user's eyes first (R34), and a
        // Quit all was the user's own decision.
        setting && bootChangedAtLaunch && launchPassDone && ReopenAtLoginQuestion.isRestartSet(offer)
    }
}
