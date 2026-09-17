// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI

/// The settings window, owned by this app rather than by a SwiftUI scene.
///
/// It used to be a `Settings` scene opened through the private
/// `showSettingsWindow:` selector. In an app whose shell is AppKit that
/// selector has nothing to answer it, so the gear silently did nothing —
/// silently, because the call site treated "no responder" as an acceptable
/// outcome. Owning the window makes opening it a call rather than a wish, and
/// gives the activation policy somewhere honest to live: an accessory app has
/// no menu bar of its own, so it becomes a regular app while the window is up
/// and goes back when it closes.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let environment: AppEnvironment

    init(environment: AppEnvironment) {
        self.environment = environment
        super.init()
    }

    func show() {
        if window == nil {
            let hosting = NSHostingController(
                rootView: SettingsWindow(
                    model: environment.settings,
                    registry: environment.registry,
                    options: { [environment] in environment.options(for: $0) },
                    resolveBinary: { [environment] in environment.resolveBinary($0) }
                )
            )
            let window = NSWindow(contentViewController: hosting)
            window.title = "AgentMenu Settings"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 720, height: 560))
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Back to a menu-bar-only app: no Dock icon, no menu of its own.
        NSApp.setActivationPolicy(.accessory)
    }
}
