// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// Runs the same table as `packaging/version.sh` against
/// `ReleaseChannel(version:)`, so the two implementations of the version
/// grammar (shell for the packaging pipeline, Swift for the app and CLI)
/// cannot drift apart unnoticed.
func runReleaseChannelTests(_ t: TestRunner) {
    t.suite("ReleaseChannel")

    let accepted: [(version: String, channel: ReleaseChannel)] = [
        ("0.2.0", .stable),
        ("0.2.0-beta.1", .beta),
        ("0.2.0-beta.99", .beta),
        ("0.2.0-alpha", .alpha),
    ]
    for entry in accepted {
        t.expectEqual(ReleaseChannel(version: entry.version), entry.channel, "\(entry.version) parses as \(entry.channel)")
    }

    let rejected = [
        "0.2.0-beta.0", "0.2.0-beta.100", "0.2.0-rc1", "0.2.0-alpha.1",
        "v0.2.0", "0.2", "1.2.3.4", "abc", "0.2.0\n", "0.2.0-beta.1\n",
    ]
    for version in rejected {
        t.expectEqual(ReleaseChannel(version: version), nil, "\(version) is rejected")
    }
}
