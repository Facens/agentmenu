// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

// The Kit halves of everything around `NotificationPlanner` that the app
// target cannot test: when macOS is asked, what the denied guidance says, what
// a click does, and how a terminal is asked which tab is on screen. Each is a
// pure function or takes its side effects as closures, in the way
// `LaunchAtLoginQuestion` and `TerminalFocus` do.

// MARK: - Asking macOS (KTD15)

/// When AgentMenu asks macOS for permission to post notifications.
///
/// On a user action, never at app start: a menu-bar app's prompt can appear
/// behind whatever window has focus. The two actions are the first launch
/// AgentMenu makes and the first open of the Sessions tab; whichever comes
/// first asks, and `notifications_asked` records that it did.
public enum NotificationAuthorizationPolicy {
    /// Whether this is the moment to put the question. False once asked, and
    /// false while the user has both Needs-you and Your-turn notifications
    /// switched off — there is nothing to ask permission for, and turning a
    /// switch on in Settings is itself the user action that asks.
    public static func shouldRequest(config: Config) -> Bool {
        !config.notificationsAsked && (config.notifyNeedsYou || config.notifyYourTurn)
    }
}

/// What the app says when macOS has notifications turned off for it.
public enum NotificationGuidance {
    /// Where the user turns them back on.
    public static let systemSettingsPath = "System Settings › Notifications › AgentMenu"

    /// The strip at the top of the Sessions tab. Nil unless notifications are
    /// denied *and* the user wants Needs-you ones: a denied state under a
    /// switch that is off is not a problem worth a banner.
    public static func sessionsTab(authorization: NotificationAuthorization, notifyNeedsYou: Bool) -> String? {
        guard authorization == .denied, notifyNeedsYou else { return nil }
        return "AgentMenu can't notify you when a session needs you. Turn notifications on in \(systemSettingsPath)."
    }

    /// The note next to the Settings toggle, shown whenever macOS refuses, so
    /// the toggle never reads as working when it cannot.
    public static func settings(authorization: NotificationAuthorization) -> String? {
        guard authorization == .denied else { return nil }
        return "macOS is blocking notifications from AgentMenu. Allow them in \(systemSettingsPath)."
    }
}

// MARK: - A click (R32, R8)

/// Where a click on a notification goes.
public enum NotificationClickTarget: Equatable, Sendable {
    /// The session is still running: bring its terminal tab forward, as a
    /// click on its row does (R8).
    case focus(LiveSessionKey)
    /// The session has ended since the banner was posted. Failing silently
    /// would be the worst answer; the Closed list is where it went.
    case showClosed
    /// A summary, or a banner this build cannot read: the Sessions tab.
    case showLive
}

public enum NotificationClick {
    /// Maps a notification's `userInfo` to a target against a *fresh* list of
    /// live sessions — not one delivered before the click, which a click that
    /// launched the app would not have yet.
    public static func resolve(userInfo: [String: String], live: [LiveSession]) -> NotificationClickTarget {
        // The host-death offer (R34) is about sessions that are no longer
        // running, and its body opens the Sessions tab, where Reopen all is.
        if userInfo["kind"] == HostDeathNotification.kind { return .showLive }
        guard let note = DeliveredNotification(identifier: "", userInfo: userInfo) else { return .showLive }
        switch note.kind {
        case .needsYouSummary:
            return .showLive
        case .needsYou, .yourTurn:
            guard let token = note.rowTokens.first else { return .showLive }
            if let session = live.first(where: { NotificationPlanner.token($0.key) == token }) {
                return .focus(session.key)
            }
            return .showClosed
        }
    }
}

// MARK: - Which tab is on screen (KTD10's exception)

/// One question to one terminal: which tab is selected in the front window?
public struct FrontmostTTYRequest: Equatable, Sendable {
    public let terminalID: String
    public let terminalName: String
    public let bundleID: String
    public let script: String

    public init(terminalID: String, terminalName: String, bundleID: String, script: String) {
        self.terminalID = terminalID
        self.terminalName = terminalName
        self.bundleID = bundleID
        self.script = script
    }
}

/// Asks a terminal for its selected tab's tty, through the optional
/// `frontmost_tty_applescript` manifest key.
///
/// Every way of not getting an answer is the same answer, `.notFrontmost`,
/// and the notification posts: the terminal is not frontmost, it has no such
/// key, AgentMenu has no Automation grant for it, the script failed, or its
/// output is not a tty. And no Apple Event is sent unless the terminal is the
/// frontmost app — which also means it is running, so asking can never launch
/// it.
public struct FrontmostTTYProbe {
    private let runner: TerminalFocus.Runner
    private let automationGranted: (_ bundleID: String) -> Bool

    /// - Parameters:
    ///   - runner: `osascript`'s arguments in, its output out. The real one is
    ///     `TerminalFocus.systemRunner(exitTimeout:)`, with a timeout of
    ///     seconds: this runs from a timer and must not wait out a prompt.
    ///   - automationGranted: whether macOS already lets AgentMenu control
    ///     this app, asked *without* prompting. A background timer must never
    ///     raise a permission sheet; focusing a row, which the user asked for,
    ///     is what does.
    public init(runner: @escaping TerminalFocus.Runner, automationGranted: @escaping (_ bundleID: String) -> Bool) {
        self.runner = runner
        self.automationGranted = automationGranted
    }

    /// The request for a terminal, or nil when it cannot be asked (no such
    /// manifest, no key, no bundle id).
    public static func request(terminalID: String, terminals: [TerminalManifest]) -> FrontmostTTYRequest? {
        guard let manifest = terminals.first(where: { $0.id == terminalID }),
              let script = manifest.frontmostTTYAppleScript,
              let bundleID = manifest.bundleID
        else { return nil }
        return FrontmostTTYRequest(terminalID: manifest.id, terminalName: manifest.displayName, bundleID: bundleID, script: script)
    }

    /// - Parameter frontmostBundleID: what `NSWorkspace` says is frontmost
    ///   right now.
    public func answer(_ request: FrontmostTTYRequest, frontmostBundleID: String?) -> FrontmostAnswer {
        guard frontmostBundleID == request.bundleID else { return .notFrontmost }
        guard automationGranted(request.bundleID) else { return .notFrontmost }
        guard let output = try? runner("/usr/bin/osascript", ["-e", request.script]) else { return .notFrontmost }
        guard let tty = TerminalFocus.deviceForm(output) else { return .notFrontmost }
        return .selectedTTY(tty)
    }
}
