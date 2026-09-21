// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

func runBundleTranslocationTests(_ t: TestRunner) {
    t.suite("BundleTranslocation")

    t.expect(
        BundleTranslocation.isTranslocated(
            bundlePath: "/private/var/folders/zz/abc123/T/AppTranslocation/9C4D2A1E-1/d/AgentMenu.app"
        ),
        "a path under a translocation mount is detected"
    )
    t.expect(
        !BundleTranslocation.isTranslocated(bundlePath: "/Applications/AgentMenu.app"),
        "an ordinary /Applications path is not translocated"
    )
    t.expect(
        !BundleTranslocation.isTranslocated(bundlePath: "/Users/x/Applications/AgentMenu.app"),
        "a per-user Applications path is not translocated"
    )
    t.expect(
        !BundleTranslocation.isTranslocated(bundlePath: "/Users/x/Downloads/AgentMenu.app"),
        "an ordinary Downloads path — not yet translocated, or Gatekeeper's quarantine bit already cleared — is not translocated"
    )
    t.expect(
        !BundleTranslocation.isTranslocated(bundlePath: ""),
        "an empty path is not translocated"
    )
}
