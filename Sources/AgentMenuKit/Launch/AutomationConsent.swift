// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import ApplicationServices
import Foundation

/// Whether macOS has already decided that AgentMenu may send Apple Events to
/// one app (Automation, in System Settings › Privacy & Security).
///
/// Why this exists: while macOS is asking "AgentMenu wants access to control
/// Terminal", the `osascript` that triggered the question is held. Killing it
/// at a timeout while the sheet is still up makes macOS record a permanent
/// "Don't Allow" for AgentMenu → that terminal, and every later launch then
/// fails with the Automation-denied error. So nothing may time `osascript` out
/// on the usual short cap unless consent is already granted.
///
/// The question is asked through `AEDeterminePermissionToAutomateTarget` with
/// `askUserIfNeeded: false`, which never raises a prompt. It lives in
/// ApplicationServices (the AE framework), not AppKit, so it is allowed in the
/// Kit.
public enum AutomationConsent: Equatable, Sendable {
    /// The user allowed it. A script runs without a prompt.
    case granted
    /// The user refused it (`errAEEventNotPermitted`, -1743). A script fails
    /// at once; only System Settings can change that.
    case denied
    /// Not decided yet (`errAEEventWouldRequireUserConsent`, -1744): the
    /// first Apple Event raises the prompt, and `osascript` waits for the
    /// answer.
    case pending
    /// The app is not running (`procNotFound`, -600), so macOS cannot say. A
    /// script that launches it may still raise the prompt, so this is treated
    /// like `pending`.
    case notRunning
    /// The probe could not be made, or gave an answer this code does not know.
    case unknown

    /// The `osascript` wait cap when consent is already granted.
    public static let grantedExitTimeout: TimeInterval = 120

    /// The `osascript` wait cap when a consent prompt may be on screen. Ten
    /// minutes, deliberately long: a user who walked away from the sheet must
    /// not have it answered for them. The cap exists only so a wedged
    /// `osascript` does not hold a background task for ever.
    public static let promptExitTimeout: TimeInterval = 600

    /// How long `osascript` may take before it is given up on, given what
    /// macOS says about consent. Only a granted state gets the short cap;
    /// every other state may have a prompt up.
    public var exitTimeout: TimeInterval {
        self == .granted ? Self.grantedExitTimeout : Self.promptExitTimeout
    }

    /// Asks macOS, without prompting, whether AgentMenu may control the app
    /// with this bundle id. Safe from any thread.
    public static func query(bundleID: String) -> AutomationConsent {
        var target = AEAddressDesc()
        let bytes = Array(bundleID.utf8)
        let created = bytes.withUnsafeBufferPointer {
            AECreateDesc(DescType(typeApplicationBundleID), $0.baseAddress, $0.count, &target)
        }
        guard created == noErr else { return .unknown }
        defer { AEDisposeDesc(&target) }

        let status = AEDeterminePermissionToAutomateTarget(
            &target, AEEventClass(typeWildCard), AEEventID(typeWildCard), false
        )
        return classify(OSStatus(status))
    }

    /// The `OSStatus` → consent mapping, apart from the call so a test can
    /// cover every code without a terminal.
    public static func classify(_ status: OSStatus) -> AutomationConsent {
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied
        case OSStatus(errAEEventWouldRequireUserConsent): return .pending
        case OSStatus(procNotFound): return .notRunning
        default: return .unknown
        }
    }
}
