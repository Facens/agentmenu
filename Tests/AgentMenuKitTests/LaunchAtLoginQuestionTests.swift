// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// `LaunchAtLoginQuestion.surface(for:)` is the one place all three call
/// sites (`SetupCard`'s checkbox, `SetupModel.finish()`'s commit guard,
/// `LaunchAtLoginPrompt.presentIfNeeded`'s alert guard) ask "does this
/// configuration still owe an answer, and if so, from where" — pulled into
/// `AgentMenuKit` specifically so it can be exercised here, since none of
/// those three call sites live in a target this suite can import (see
/// `AccessibilityID.swift`'s own comment on why the app target is out of
/// reach).
func runLaunchAtLoginQuestionTests(_ t: TestRunner) {
    t.suite("LaunchAtLoginQuestion")

    // MARK: A fresh config — never run before — asks from the setup card.

    do {
        let config = Config()
        t.expectEqual(
            LaunchAtLoginQuestion.surface(for: config), .setupCard,
            "a fresh config (first run not done, never asked) surfaces the question in the setup card"
        )
    }

    // MARK: First run done, never asked — the existing-install shape —
    // asks from the alert.

    do {
        var config = Config()
        config.firstRunCompleted = true
        t.expectEqual(
            LaunchAtLoginQuestion.surface(for: config), .launchAlert,
            "first run already done and the question never asked surfaces it in LaunchAtLoginPrompt's alert"
        )
    }

    // MARK: Asked already asks nothing more, regardless of firstRunCompleted
    // — the flag that matters is `launchAtLoginAsked` alone, and neither the
    // setup card nor the alert may reappear once it is set.

    do {
        var config = Config()
        config.launchAtLoginAsked = true
        t.expectEqual(
            LaunchAtLoginQuestion.surface(for: config), .alreadyAsked,
            "a fresh-looking config that has nonetheless been asked stays asked, even with first run not yet done — a folder-only setup-card re-open must not re-ask it"
        )

        config.firstRunCompleted = true
        t.expectEqual(
            LaunchAtLoginQuestion.surface(for: config), .alreadyAsked,
            "and stays asked once first run also finishes"
        )
    }

    // MARK: The literal shape of a real config.toml written before this
    // question existed — `schema = 1` and `first_run_completed = true`,
    // nothing else — decodes to `.launchAlert`. This is the test that
    // proves "an existing install is asked once, on its next launch," from
    // the file format itself rather than from a `Config` value built by
    // hand in Swift.

    do {
        let dir = TempDir("launch-at-login-question-preexisting")
        defer { dir.cleanup() }
        let path = dir.path("config.toml")
        try? """
        schema = 1
        first_run_completed = true
        """.write(toFile: path, atomically: true, encoding: .utf8)

        let store = ConfigStore(url: URL(fileURLWithPath: path))
        guard let loaded = t.attempt("load a pre-feature config.toml", { try store.load() }),
              let config = loaded else {
            t.expect(false, "config.toml at \(path) failed to load")
            return
        }
        t.expect(!config.launchAtLoginAsked, "the pre-feature file carries no launch_at_login_asked key, and it decodes to false, not true")
        t.expectEqual(
            LaunchAtLoginQuestion.surface(for: config), .launchAlert,
            "an existing install's real config.toml — first run done, this question never mentioned — surfaces it in the alert on next launch"
        )
    }
}
