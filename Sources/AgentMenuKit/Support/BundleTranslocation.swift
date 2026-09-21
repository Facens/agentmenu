// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Detects Gatekeeper's App Translocation from a bundle's own path (R26).
///
/// macOS runs a freshly downloaded, still-quarantined `.app` from a
/// randomized read-only copy under `/private/var/folders/.../
/// AppTranslocation/<uuid>/d/AgentMenu.app` rather than from where it
/// actually sits — so anything this process resolves relative to its own
/// bundle or executable (the nested CLI's path, in particular) is only good
/// for this one launch. Moving the bundle to `/Applications`, or simply
/// launching it from there in the first place, drops the translocation and
/// the path becomes stable.
///
/// The system's own answer is `SecTranslocateIsTranslocatedURL` in
/// Security.framework, and the app could call it directly. This uses a
/// string test instead for two reasons that both come down to
/// `packaging/check-source.sh`'s layering rule: AgentMenuKit is the only
/// place this logic can be unit-tested (the app target is not linked into
/// the test runner), and the Kit stays free of every framework beyond
/// Foundation so it keeps linking into the CLI and the test runner without
/// pulling in anything UI-adjacent. A path is also already what every call
/// site has in hand (`Bundle.main.bundleURL.path`), so the substring test
/// costs nothing a framework call would have bought back.
public enum BundleTranslocation {
    /// `true` when `bundlePath` sits under a translocation mount.
    public static func isTranslocated(bundlePath: String) -> Bool {
        bundlePath.contains("/AppTranslocation/")
    }
}
