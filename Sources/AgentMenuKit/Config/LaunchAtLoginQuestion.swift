// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where — if anywhere — the "launch at login?" question still needs
/// asking, given a configuration alone.
///
/// Pulled out as a pure function over `Config` rather than left as an
/// inline check at each of its three call sites (`SetupCard.swift`'s
/// checkbox, `SetupModel.finish()`'s commit guard, `LaunchAtLoginPrompt.
/// presentIfNeeded`'s alert guard) for two reasons: it is the one part of
/// "ask once, from the right place" that is testable without the app
/// target at all — `AgentMenuKitTests` cannot import `AgentMenu` (see the
/// long comment atop `Sources/AgentMenuKit/Support/AccessibilityID.swift`
/// for why) — and three separately hand-written copies of the same two-
/// field check are three chances for one of them to drift, which is
/// exactly how a returning setup card or a second alert would slip back in.
public enum LaunchAtLoginQuestion: Equatable {
    /// A fresh install: the setup card's own checkbox asks it, next to Done.
    case setupCard
    /// An install that reaches this build with first run already behind it
    /// — `LaunchAtLoginPrompt`'s one-shot alert asks it instead, since the
    /// setup card itself is never shown again for such a configuration.
    case launchAlert
    /// Already answered, either way — nothing asks it again.
    case alreadyAsked

    public static func surface(for config: Config) -> LaunchAtLoginQuestion {
        guard !config.launchAtLoginAsked else { return .alreadyAsked }
        return config.firstRunCompleted ? .launchAlert : .setupCard
    }
}
