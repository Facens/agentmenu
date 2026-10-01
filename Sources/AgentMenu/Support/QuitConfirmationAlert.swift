// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import AgentMenuKit

/// The question Quit and Quit all ask when a session they would end is Working
/// (U12, R21). The wording is `QuitPolicy`'s; this only shows it.
///
/// `runModal()` for the reason `LaunchAtLoginPrompt` documents: the user has
/// just clicked Quit and is waiting for it, so the answer is what the click
/// does next. The app is activated first, as there: a menu-bar app is not
/// active, and an alert in an inactive app draws its default button grey.
enum QuitConfirmationAlert {
    @MainActor
    static func confirm(_ confirmation: QuitConfirmation) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = confirmation.title
        alert.informativeText = confirmation.message
        alert.addButton(withTitle: confirmation.confirmTitle).setAccessibilityIdentifier(AccessibilityID.QuitPrompt.confirm)
        alert.addButton(withTitle: confirmation.cancelTitle).setAccessibilityIdentifier(AccessibilityID.QuitPrompt.cancel)
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertFirstButtonReturn
    }
}
