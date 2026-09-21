// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// U11's three rules about updating (R12, R20, KTD20). Every one of them has
/// a wrong answer that is invisible until a release goes out — an alpha that
/// replaces the maintainer's working build, a copy checking a feed it cannot
/// verify, a beta tester offered nothing until the final ships — so they are
/// asserted here rather than left to the Sparkle wiring that reads them.
func runUpdatePolicyTests(_ t: TestRunner) {
    t.suite("UpdatePolicy")

    let key = "b8vLtHDaaN4mRn1oUpLCQhoMkG6pBmpNHiuKQhqHxjM="

    // MARK: - Whether to start at all

    t.expect(
        UpdatePolicy.refusal(version: "0.2.0", publicKey: key) == nil,
        "a stable build with a key starts the updater"
    )
    t.expect(
        UpdatePolicy.refusal(version: "0.2.0-beta.1", publicKey: key) == nil,
        "a beta build with a key starts the updater"
    )
    t.expectEqual(
        UpdatePolicy.refusal(version: "0.2.0-alpha", publicKey: key),
        .alphaBuild,
        "an alpha build never starts the updater: `make bundle` is what replaces it"
    )
    t.expectEqual(
        UpdatePolicy.refusal(version: "0.2.0", publicKey: ""),
        .noPublicKey,
        "an empty SUPublicEDKey refuses — a feed with nothing to verify against is a second, weaker acceptance path"
    )
    t.expectEqual(
        UpdatePolicy.refusal(version: "0.2.0", publicKey: nil),
        .noPublicKey,
        "an absent SUPublicEDKey refuses the same way an empty one does"
    )
    t.expectEqual(
        UpdatePolicy.refusal(version: "0.2.0", publicKey: "   \n"),
        .noPublicKey,
        "a key that is only whitespace is no key: the alternative is a signature mismatch hours later, nowhere near its cause"
    )
    t.expectEqual(
        UpdatePolicy.refusal(version: "0.2", publicKey: key),
        .unreadableVersion("0.2"),
        "a version outside the project's grammar refuses rather than guessing a channel"
    )
    t.expect(
        UpdatePolicy.refusal(version: "0.2.0-alpha", publicKey: "").map { $0 == .alphaBuild } ?? false,
        "an alpha with no key reports the alpha, which is the reason the user can act on"
    )

    // MARK: - Which channels

    t.expectEqual(
        UpdatePolicy.allowedChannels(betaEnabled: false),
        [],
        "betas off means the default channel only, which is where finals live"
    )
    t.expectEqual(
        UpdatePolicy.allowedChannels(betaEnabled: true),
        ["beta"],
        "betas on adds the beta channel; it never replaces the default one, so a final still supersedes"
    )

    // MARK: - What the preference defaults to

    t.expect(
        UpdatePolicy.defaultBetaPreference(version: "0.2.0-beta.1"),
        "a beta build defaults to receiving betas: it is already on that channel"
    )
    t.expect(
        !UpdatePolicy.defaultBetaPreference(version: "0.2.0"),
        "a stable build does not"
    )
    t.expect(
        !UpdatePolicy.defaultBetaPreference(version: "0.2.0-alpha"),
        "an alpha build does not, and never checks anyway"
    )

    // MARK: - Resolving the stored tri-state

    t.expect(
        UpdatePolicy.betaEnabled(preference: nil, version: "0.2.0-beta.1"),
        "no decision on a beta build resolves to on"
    )
    t.expect(
        !UpdatePolicy.betaEnabled(preference: nil, version: "0.2.0"),
        "no decision on a stable build resolves to off"
    )
    t.expect(
        !UpdatePolicy.betaEnabled(preference: false, version: "0.2.0-beta.1"),
        "a beta tester who said no stays off — the build does not overrule them"
    )
    t.expect(
        UpdatePolicy.betaEnabled(preference: true, version: "0.2.0"),
        "someone on a final who asked for betas gets them"
    )
}
