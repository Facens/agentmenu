// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import ServiceManagement

/// The login item, as the one question the user actually asks about it: is it
/// on, and make it so.
///
/// `SMAppService.mainApp` rather than a `LaunchAgents` plist: macOS 13 and
/// later register the app bundle itself, and the app appears in System
/// Settings › General › Login Items under its own name, where the user can
/// turn it off without coming back here.
///
/// Ported from MeetingHop's `LaunchAtLogin` (Sources/MeetingHop/Support/Support.swift)
/// so the two apps answer this the same way, error handling included.
enum LaunchAtLogin {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Logs rather than throws. Registration fails for reasons the user
    /// cannot act on from a toggle — an ad-hoc-signed build, a translocated
    /// copy — and the caller re-reads `isEnabled` afterwards, so a refusal
    /// shows up as the switch sliding back rather than as an alert.
    static func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            FileHandle.standardError.write(Data(
                "AgentMenu: launch at login \(enabled ? "register" : "unregister") failed: \(error.localizedDescription)\n".utf8
            ))
        }
    }
}
