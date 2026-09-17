// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit

// The shell is AppKit: an NSStatusItem with an NSPopover, and windows this app
// opens itself. SwiftUI renders every view inside them but owns no scene — a
// SwiftUI `App` needs one, and the only scene left was a settings window whose
// opening mechanism (the private `showSettingsWindow:` selector) does not work
// from an AppKit-driven app.
//
// The delegate is a global on purpose. `NSApplication.delegate` is a weak
// reference, so a local one is released as soon as ARC sees its last use —
// which took the status item down with it and left an app running with nothing
// in the menu bar. A top-level `let` lives as long as the process.
nonisolated(unsafe) let applicationDelegate: AppDelegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    let application = NSApplication.shared
    application.delegate = applicationDelegate
    application.setActivationPolicy(.accessory)
    application.run()
}
