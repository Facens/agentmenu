// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import AgentMenuKit

/// The app half of focusing a session's terminal (KTD10): the two things
/// `TerminalFocus` leaves to its caller, which AgentMenuKit may not do
/// itself because they need AppKit.
///
/// - Whether the terminal is running comes from `NSRunningApplication`,
///   asked by bundle id. It has to be asked before any Apple Event, because
///   telling an app that is not running to do anything starts it.
/// - The script runs through `osascript` off the main thread: it can take
///   seconds, and longer while macOS asks whether AgentMenu may control the
///   terminal at all.
///
/// Listing sessions never comes through here and never sends an Apple
/// Event; only a click does.
enum FocusService {
    /// An app counts as running when a live, not-yet-terminated instance has
    /// the bundle id. `NSRunningApplication` is safe to ask from any thread.
    static func isRunning(bundleID: String) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .contains { !$0.isTerminated }
    }

    static func focus(_ request: FocusRequest) async -> FocusOutcome {
        await Task.detached(priority: .userInitiated) {
            TerminalFocus(
                timedRunner: TerminalFocus.systemTimedRunner(),
                isRunning: { isRunning(bundleID: $0) },
                consent: AutomationConsent.query(bundleID:)
            )
                .focus(request)
        }.value
    }
}
