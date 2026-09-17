// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Paths as the user reads them.
///
/// A menu-bar row is 400pt wide and an absolute path under CloudStorage is not,
/// so what gets shown is the tilde form. This lives apart from any one screen
/// because every surface that displays a folder needs it — the popover, the
/// folder list, the profile list, first run.
enum PathDisplay {
    /// `~/dev/agentmenu` rather than the full absolute path.
    static func abbreviated(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}
