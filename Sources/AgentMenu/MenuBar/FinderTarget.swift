// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Foundation
import AgentMenuKit

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

    /// Pays the first-call cost — Apple Event setup, and the Automation
    /// consent prompt on a fresh install — while the user is not waiting for
    /// anything. Not from a translocated bundle, though.
    ///
    /// A translocated launch runs from a randomized read-only mount under
    /// `/AppTranslocation/` that will not exist next launch, and the app is
    /// already telling the user so (`PopoverView`'s translocation banner,
    /// R26). Asking for Automation from there contradicts the banner and
    /// buys nothing that survives the move it is asking for. MeetingHop
    /// settled the same question the same way for its calendar request
    /// (`meetinghop@fe7a338`), for the same reason and one more: the first
    /// launch after a download is the one most likely to be killed and
    /// relaunched from `/Applications` — by a person dragging the app there,
    /// or by `harness/lib/scenario.sh`'s `clear_quarantine` — and a consent
    /// sheet whose process dies under it is left on screen belonging to
    /// nobody. The v0.2.0-beta.2 gate photographed exactly that in
    /// `bridge-install`: "AgentMenu wants access to control Finder", still
    /// up, 120s in, over a second unanswered sheet.
    ///
    /// What it deliberately does *not* do is defer the prompt to the first
    /// popover instead. That was tried and is worse: a TCC sheet takes the
    /// active application away, `StatusItemController` closes the popover
    /// when it does, and nothing reopens it — so the menu would vanish under
    /// the user at the exact moment they first opened it. Asking once, at
    /// launch, from a bundle that is where it will stay, is the version that
    /// leaves the menu alone.
    static func warmUp() {
        guard !BundleTranslocation.isTranslocated(bundlePath: Bundle.main.bundlePath) else { return }
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
