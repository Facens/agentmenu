// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import SwiftUI
import AgentMenuKit

/// Owns the app's runtime objects and the status item.
///
/// An `LSUIElement` app has no windows of its own until it makes one, so the
/// delegate is where the menu-bar item is created and where first run is offered.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let environment = AppEnvironment()
    private var statusItem: StatusItemController?
    private lazy var settingsWindow = SettingsWindowController(environment: environment)

    /// The one instance, so the popover and the delegate open the same window.
    static private(set) weak var shared: AppDelegate?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        // Defaults first: a launcher that shows only $HOME until a wizard is
        // finished is a blank page, and the window can be closed.
        environment.seedIfMissing()
        // The read-only state hook (KTD3, R13). Inert unless a defaults key
        // names a journal file, and after the seeding above so the fixture
        // echo carries the configuration this launch actually ended up with —
        // a failure to write it is replayed to the tap either way.
        //
        // `environment.overrides` is what `AppEnvironment.init` already
        // resolved from the argument domain and the environment (U7, KTD4) —
        // read back here rather than re-resolved, so the roots the journal
        // echoes can never disagree with the roots the store and the
        // manifest registry actually used.
        let overrides = environment.overrides
        HarnessJournal.shared.activate(
            environment: environment,
            defaults: Overrides.defaults(forSuite: overrides.defaultsSuite),
            directory: overrides.harnessDirectory ?? Journal.defaultDirectory,
            defaultsSuite: overrides.defaultsSuite,
            manifestsRoot: overrides.manifestsUserRoot ?? ManifestRegistry.defaultUserRoot,
            profileRoot: overrides.profileRoot
        )
        // U10: re-validate every profile's status-line bridge on this
        // launch rather than trusting a path some earlier launch baked in —
        // see `revalidateStatuslineBridges()`. After `activate(...)` above,
        // not before: a stale, non-translocated bridge is rewritten by
        // running the bundled CLI, which reports through
        // `HarnessJournal.shared.bridgeInstalled(...)` on its own detached
        // task — and that task can outrace `activate(...)` on the main
        // actor if it starts any earlier, landing its event in a journal
        // that has not started listening yet. Hands off to a detached task
        // immediately either way, so this line adds no measurable time to
        // launch.
        environment.revalidateStatuslineBridges()
        // Touching the lazy property is what starts Sparkle: an updater
        // created on the first visit to Settings would never check for
        // anyone who does not open Settings, which is most people (R12).
        // It refuses to start on an alpha build or one with no signing key
        // and says why, in Settings and on stderr.
        _ = environment.updater
        statusItem = StatusItemController(environment: environment)
        // Pay the Apple Event setup cost now rather than on the first click.
        FinderTarget.warmUp()


    }

    /// Opens the settings window. A call, not a wish: the previous route asked
    /// the responder chain for a private selector and accepted silence.
    func showSettings() {
        settingsWindow.show()
    }

    /// The About panel, from the status item's menu.
    ///
    /// AppKit's standard panel rather than a window of our own: it reads the
    /// bundle's name, icon and version itself, so the only thing worth adding
    /// is the licence and where the source is. `activate` first — an accessory
    /// app has no Dock icon to bring it forward, and the panel would open
    /// behind whatever the user was looking at.
    func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        let credits = NSMutableAttributedString(
            string: "Free software under the GPL-3.0-or-later.\nhttps://github.com/Facens/agentmenu",
            attributes: [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]
        )
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    /// Opening the app again when it is already running — from Finder, from
    /// Spotlight, from the Dock — has nowhere obvious to go in a menu-bar app.
    /// Settings is the honest destination, and it doubles as the way in when a
    /// menu-bar manager has hidden the icon.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showSettings()
        return true
    }

    /// A save is at most 0.4 s away from being written, and terminate does not
    /// drain pending work items — so "change a preset, then Quit" is two clicks
    /// a few hundred milliseconds apart that used to lose the change silently.
    func applicationWillTerminate(_ notification: Notification) {
        environment.flushPendingSave()
    }

    /// Nothing to restore: the popover is the app's window.
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }
}
