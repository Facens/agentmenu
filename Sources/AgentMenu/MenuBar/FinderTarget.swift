// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation

/// The folder of the front Finder window (R2).
///
/// The AppleScript is the one the SwiftBar plugin this app replaces has used
/// since 2026-07: it returns an empty string rather than raising when the front
/// window has no POSIX path — Recents, a tag, a network location — so "no
/// usable folder" is a normal answer and not an error the caller has to parse.
enum FinderTarget {
    /// AppleScript is not thread-safe, and the call is an Apple Event round trip
    /// to another process: measured at ~280 ms on the first call in a process and
    /// ~25 ms warm. That is far too slow to sit on the path between clicking the
    /// menu-bar icon and the popover painting, so every caller goes through this
    /// queue and nobody waits on the main thread.
    private static let queue = DispatchQueue(label: "dev.facens.agentmenu.finder")

    private static let script = """
    tell application "Finder"
        if (count of Finder windows) is 0 then return ""
        try
            return POSIX path of (target of front Finder window as alias)
        on error
            return ""
        end try
    end tell
    """

    /// Asks Finder off the main thread and delivers the answer on it.
    static func frontWindowPath(completion: @escaping (String?) -> Void) {
        queue.async {
            let path = frontWindowPath()
            DispatchQueue.main.async { completion(path) }
        }
    }

    /// Pays the first-call cost — Apple Event setup, and the Automation consent
    /// prompt on a fresh install — while the user is not waiting for anything.
    static func warmUp() {
        queue.async { _ = frontWindowPath() }
    }

    /// nil when there is no front Finder window, or it has no folder path.
    /// Blocking: call it from `queue`, never from the main thread.
    static func frontWindowPath() -> String? {
        guard let apple = NSAppleScript(source: script) else { return nil }
        var error: NSDictionary?
        let result = apple.executeAndReturnError(&error)
        if error != nil { return nil }
        guard var path = result.stringValue, !path.isEmpty else { return nil }
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

}
