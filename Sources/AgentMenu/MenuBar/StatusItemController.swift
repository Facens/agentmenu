// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import SwiftUI
import AgentMenuKit

/// The menu-bar item and the popover hanging off it.
///
/// AppKit rather than `MenuBarExtra(.window)`, for three reasons that only show
/// up once the thing is in front of you: `NSPopover` draws the arrow that points
/// at the icon, it closes on demand (`performClose`) which is what a successful
/// launch needs, and a `Menu` inside it — the model and effort pills — opens
/// without fighting the window underneath. The SwiftUI content is unchanged;
/// only its host is different.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let environment: AppEnvironment
    private var outsideClickMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    /// The indicator has to be right while the popover is closed — that is the
    /// whole point of putting it in the menu bar — and the only thing that
    /// changes it is a file another process writes. So it is polled, at the
    /// rate that file is written: the status-line bridge throttles itself to
    /// once a minute, and reading faster than it writes buys nothing.
    private var indicatorTimer: Timer?
    private var cancellables: Set<AnyCancellable> = []
    /// Used to anchor the popover when the status item's own window is not
    /// somewhere a popover can point at. See `anchor()`.
    private lazy var positioningWindow: NSWindow = {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .statusBar
        return window
    }()

    init(environment: AppEnvironment) {
        self.environment = environment
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        if let button = statusItem.button {
            button.image = MenuBarIcon.image()
            button.image?.isTemplate = true
            button.toolTip = "AgentMenu — start an agent session"
            button.action = #selector(click)
            button.target = self
            // A status button sends its action on `.leftMouseUp` alone, which
            // is why a right-click on the icon did nothing at all. Both, and
            // the handler tells them apart.
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            // U5/KTD9: the one control System Events has to find before it can
            // find anything else the app draws — nothing is reachable until
            // this button is clicked open.
            button.setAccessibilityIdentifier(AccessibilityID.Popover.statusItem)
        }

        refreshIndicator()
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshIndicator() }
        }
        // `.common` so it keeps firing while a menu is open or the popover is
        // being dragged — a timer on the default mode stops during exactly the
        // moments the user is looking at the thing.
        RunLoop.main.add(timer, forMode: .common)
        indicatorTimer = timer

        // A pending update has to reach the bar when it lands, not on the
        // next minute tick: the whole point of the badge is that it appears
        // while the user is looking at something else (R18).
        environment.$updatePending
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshIndicator() }
            }
            .store(in: &cancellables)

        // Switching account in the popover changes which account the bar is
        // reporting on, and waiting up to a minute to catch up would show the
        // wrong account's number in the meantime.
        environment.$config
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshIndicator() }
            }
            .store(in: &cancellables)

        popover.behavior = .applicationDefined   // dismissal is ours, see below
        popover.animates = false                 // a menu-bar popover should feel instant
        popover.delegate = self
        let popoverContent = NSHostingController(
            rootView: PopoverView(
                model: environment.popover,
                setup: environment.setup,
                close: { [weak self] in self?.close() }
            )
        )
        // The plan's execution note flags this as the unit's real risk: an
        // NSPopover's content sits in a window System Events may or may not
        // address the way a normal document window does. Setting the
        // identifier here is what the deferred probe (U5's "Execution note")
        // checks against a running app; wiring it now leaves that probe
        // something to find rather than nothing.
        popoverContent.view.setAccessibilityIdentifier(AccessibilityID.Popover.container)
        popover.contentViewController = popoverContent

        // `.applicationDefined` hands every dismissal to us, and switching away
        // with Cmd-Tab is one: without this the popover floats over whatever
        // the user switched to until they click somewhere.
        //
        // Not under the harness, though. Every accessibility query runs
        // inside `tell application "System Events"`, which takes the active
        // application away from this one — so the popover closed part-way
        // through the driver's own walk of it, and which identifiers the
        // walk had reached by then decided what a scenario could find. That
        // is why `popover.checkForUpdates` and `popover.quit`, both at the
        // bottom of the popover, were never findable while
        // `popover.gear` near the top usually was.
        //
        // Gated on `Overrides.harnessFlagKey`, the same argument-domain
        // flag that opens KTD4's escape hatches (`-AgentMenuHarness YES`,
        // which only a launch argument can supply), so a shipped copy still
        // dismisses on Cmd-Tab exactly as before.
        let harnessDriven = UserDefaults.standard.bool(forKey: Overrides.harnessFlagKey)
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard !harnessDriven else { return }
            MainActor.assumeIsolated { self?.close() }
        }
    }

    deinit {
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        indicatorTimer?.invalidate()
    }

    /// Puts the worst window of the active account in the menu bar, or nothing
    /// at all below the first threshold (R23-R25 still hold: a rolled-over
    /// window raises no alarm, and an old reading says how old it is rather
    /// than passing for current).
    func refreshIndicator() {
        guard let button = statusItem.button else { return }
        let config = environment.config
        let profile = config.profiles.first { $0.id == config.activeProfileID } ?? config.profiles.first

        guard let profile,
              case .available(let snapshot) = environment.usage(forProfile: profile),
              let alert = UsageAlert.worst(in: snapshot, staleAfter: UsageReader.defaultStaleAfter) else {
            button.attributedTitle = updateBadge(before: NSAttributedString(string: ""))
            button.toolTip = tooltip(base: "AgentMenu — start an agent session")
            return
        }

        let name = profile.name.isEmpty ? profile.id : profile.name
        button.attributedTitle = updateBadge(before: MenuBarIcon.badge(for: alert, snapshot: snapshot))
        button.toolTip = tooltip(base: MenuBarIcon.tooltip(for: alert, profileName: name))
    }

    /// R18: an app with no Dock icon cannot rely on Sparkle's alert being
    /// noticed, so a waiting update marks the status item itself.
    ///
    /// Composed with the usage meter rather than replacing it — the meter is
    /// the thing this status item exists to show, and a pending update is
    /// not worth hiding it for. The dot goes in front, where it reads as an
    /// annotation on the number rather than part of it.
    private func updateBadge(before title: NSAttributedString) -> NSAttributedString {
        guard environment.updatePending else { return title }
        let dot = NSMutableAttributedString(string: "•\u{2009}", attributes: [
            .foregroundColor: NSColor.controlAccentColor,
            .font: NSFont.systemFont(ofSize: 11, weight: .bold),
        ])
        dot.append(title)
        return dot
    }

    private func tooltip(base: String) -> String {
        environment.updatePending ? base + "\nAn update is ready to install." : base
    }

    /// Left-click opens the popover, right-click (and control-click, the same
    /// gesture with one hand) opens the short menu every menu-bar app is
    /// expected to have: Settings, About, Quit.
    @objc private func click() {
        let event = NSApp.currentEvent
        let secondary = event?.type == .rightMouseUp
            || event?.modifierFlags.contains(.control) == true
        guard secondary else {
            toggle()
            return
        }
        // The outside-click monitor is a *global* monitor, and a global
        // monitor never sees events in this app's own windows — the status
        // button is one of ours, so nothing else is going to close the
        // popover before the menu opens over it.
        close()
        showStatusMenu()
    }

    private func toggle() {
        popover.isShown ? close() : show()
    }

    /// Hands the menu to the status item and clicks it, rather than calling
    /// `popUp(positioning:at:in:)` on the button.
    ///
    /// Same reason `anchor(for:)` exists further down: a menu-bar manager
    /// moves the real button off every screen, and anything positioned
    /// relative to it lands nowhere near the icon the user clicked.
    /// `NSStatusItem.menu` leaves the placement to AppKit, which knows where
    /// the item actually is. `performClick` blocks for as long as the menu is
    /// tracking, so the item is handed its menu only for that moment — a
    /// permanently assigned menu would swallow the left-click the popover
    /// needs.
    private func showStatusMenu() {
        guard let button = statusItem.button else { return }
        statusItem.menu = statusMenu()
        button.performClick(nil)
        statusItem.menu = nil
    }

    private func statusMenu() -> NSMenu {
        let menu = NSMenu()
        // Every item carries an explicit target. With a nil target AppKit
        // looks for a handler on the responder chain, and an accessory app
        // with no key window has none — `autoenablesItems` then draws the
        // whole menu greyed out.
        menu.addItem(item(title: "Settings…", action: #selector(openSettings), key: ","))
        menu.addItem(item(title: "About AgentMenu", action: #selector(openAbout), key: ""))
        menu.addItem(.separator())
        menu.addItem(item(title: "Quit AgentMenu", action: #selector(quit), key: "q"))
        return menu
    }

    private func item(title: String, action: Selector, key: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func openSettings() {
        AppDelegate.shared?.showSettings()
    }

    @objc private func openAbout() {
        AppDelegate.shared?.showAbout()
    }

    /// `terminate` rather than `exit`, for the reason the footer's Quit gives:
    /// `applicationWillTerminate` is where the pending save is flushed.
    @objc private func quit() {
        NSApp.terminate(nil)
    }

    func show() {
        guard let button = statusItem.button else { return }

        environment.popover.refresh()
        refreshIndicator()
        let (anchorView, anchorRect) = anchor(for: button)
        // An accessory app that never activates gets no mouse-moved events, and
        // a tooltip is delivered by exactly those — so every `.help` in the
        // popover (the bypass warning's explanation among them) silently
        // explained nothing. Activating also gives the popover the keyboard,
        // which its pills and disclosure rows want anyway; the
        // `didResignActive` observer above still closes it the moment focus
        // leaves.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: anchorRect, of: anchorView, preferredEdge: .maxY)
        // The popover is key, so its own controls work; anything clicked outside
        // it closes it, which is what `.transient` would do — except `.transient`
        // also treats the menus inside the pills as an outside click.
        popover.contentViewController?.view.window?.makeKey()
        clampBelowMenuBar()
        installOutsideClickMonitor()
    }

    /// Puts the popover's top edge against the bottom of the menu bar.
    ///
    /// The status item's window is taller than the button inside it, so a
    /// popover anchored to the button's bounds is placed from the wrong line —
    /// and which way it lands depends on how the item was placed. MeetingHop,
    /// which ports this file, measured a gap *below* the bar; here, with the
    /// item parked off-screen and the anchor rebuilt under the pointer, the
    /// window's top ended up 22 points *above* the screen's visible area.
    ///
    /// One correction covers both: snap the top edge to the bar, in whichever
    /// direction it drifted.
    private func clampBelowMenuBar() {
        guard let window = popover.contentViewController?.view.window,
              let screen = window.screen ?? NSScreen.main else { return }
        var frame = window.frame
        let drift = screen.visibleFrame.maxY - frame.maxY
        guard abs(drift) > 0.5 else { return }
        frame.origin.y += drift
        window.setFrame(frame, display: false)
    }

    /// Where to point the popover.
    ///
    /// Normally that is the status item's own button. But a menu-bar manager
    /// (Ice, Bartender) moves items it has taken over: measured on this
    /// machine, the real button window sits at x = -4045, three points wide,
    /// while the icon the user clicks is drawn by the manager somewhere else
    /// entirely. Anchoring to the button then puts the popover nowhere near the
    /// thing that was clicked.
    ///
    /// So when the button is not on any screen, the popover is anchored to a
    /// one-point transparent window placed under the pointer at the top of the
    /// screen the pointer is on — which is where the click just happened.
    private func anchor(for button: NSStatusBarButton) -> (NSView, NSRect) {
        let frame = button.window?.frame ?? .zero
        // Three points wide and off every screen is what a menu-bar manager
        // leaves behind when it takes an item over.
        if NSScreen.screens.contains(where: { $0.frame.intersects(frame) }), frame.width > 8 {
            return (button, button.bounds)
        }

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let top = (screen?.frame.maxY ?? mouse.y) - (screen.map { $0.frame.maxY - $0.visibleFrame.maxY } ?? 0)
        positioningWindow.setFrame(NSRect(x: mouse.x, y: top, width: 1, height: 1), display: false)
        positioningWindow.orderFront(nil)
        return (positioningWindow.contentView ?? button, positioningWindow.contentView?.bounds ?? button.bounds)
    }

    func close() {
        popover.performClose(nil)
        positioningWindow.orderOut(nil)
        removeOutsideClickMonitor()
    }

    private func installOutsideClickMonitor() {
        removeOutsideClickMonitor()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            Task { @MainActor in self?.close() }
        }
    }

    private func removeOutsideClickMonitor() {
        if let monitor = outsideClickMonitor { NSEvent.removeMonitor(monitor) }
        outsideClickMonitor = nil
    }

    func popoverDidClose(_ notification: Notification) {
        removeOutsideClickMonitor()
    }
}
