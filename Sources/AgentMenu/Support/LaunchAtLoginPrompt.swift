// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import AgentMenuKit

/// The one-time "launch at login?" ask for an install that reaches this
/// build with first run already behind it.
///
/// A brand-new install gets asked inside the setup card instead
/// (`SetupCard.swift`'s own checkbox, next to Done) — that flow already
/// stops a fresh install and asks it two questions, and folding a third one
/// in there is one control, not one more interruption. An install that
/// finished first run before this question existed has no such flow left to
/// reach: `SetupModel.isNeeded` only brings the card back when the folder
/// list goes empty again, which is not a launch this feature has any
/// business waiting for. So it gets a plain, one-shot `NSAlert` here
/// instead — default button "Launch at Login", secondary "Not Now" —
/// mirroring `ProfilesPane.installBridge`'s own alert (Install / Cancel,
/// first button default) down to the button order, since that is the one
/// alert this codebase already ships and the harness already proves it can
/// drive.
enum LaunchAtLoginPrompt {
    /// Shown at most once per configuration, ever. `AppDelegate` calls this
    /// after the status item exists, so the menu bar icon is already up
    /// before the alert takes focus — the same ordering a person would get
    /// from any other app that asks something on first launch after an
    /// update.
    ///
    /// `runModal()` blocks the calling thread until the alert is dismissed,
    /// same as `ProfilesPane.installBridge`'s; that is a deliberate choice
    /// there and stays one here — a question this app is only ever going to
    /// ask once is allowed to hold the floor until it gets an answer.
    @MainActor
    static func presentIfNeeded(environment: AppEnvironment) {
        guard LaunchAtLoginQuestion.surface(for: environment.config) == .launchAlert else { return }

        let alert = NSAlert()
        alert.messageText = "Launch AgentMenu at login?"
        alert.informativeText = "Start automatically when you log in. You can change this anytime in Settings › General."
        alert.addButton(withTitle: "Launch at Login").setAccessibilityIdentifier(AccessibilityID.LaunchAtLoginPrompt.accept)
        alert.addButton(withTitle: "Not Now").setAccessibilityIdentifier(AccessibilityID.LaunchAtLoginPrompt.decline)

        // `SMAppService.mainApp.register()` failing, or landing in
        // `.requiresApproval`, is handled exactly the way the Settings
        // toggle handles it (`LaunchAtLogin.set`, `SettingsModel.
        // launchAtLogin`): logged rather than surfaced here, because there
        // is nothing this one-shot alert could usefully do about a
        // translocated copy or an unapproved login item that the toggle in
        // Settings cannot also do later. The journal tap that records this
        // question's answer re-reads `LaunchAtLogin.isEnabled` afterwards
        // rather than trusting the click, for the same reason.
        // An NSAlert takes its icon from `NSApp.applicationIconImage`, which
        // this early in an accessory app's launch can still be empty: the
        // v0.2.2-beta.1 gate run showed the dashed placeholder instead of
        // the app icon. Asking the workspace for the bundle's own icon does
        // not depend on that timing.
        alert.icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        // A menu-bar app is not active at launch, and an alert from an
        // inactive app draws its default button grey, the same as the other
        // one. Activating first is what makes "Launch at Login" read as the
        // default it is.
        NSApp.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            LaunchAtLogin.set(true)
        }
        environment.update { $0.launchAtLoginAsked = true }
        environment.flushPendingSave()
    }
}
