// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

// Automation consent: osascript is never killed on the short cap while a
// consent prompt may be up, because killing it with the sheet on screen makes
// macOS record a permanent "Don't Allow".

private let script = "on run argv\nend run"

private let iterm = TerminalManifest(
    id: "iterm2", displayName: "iTerm2", kind: .applescript,
    bundleID: "com.googlecode.iterm2", appleScript: script,
    focusAppleScript: script, origin: .bundled
)

private let command = LaunchCommand(
    executable: "/usr/local/bin/claude", arguments: [], environment: [:], workingDirectory: "/Users/x/Project"
)

private func focusRequest() -> FocusRequest {
    FocusRequest(terminalID: "iterm2", terminalName: "iTerm2", bundleID: "com.googlecode.iterm2", script: script, tty: "/dev/ttys004")
}

func runAutomationConsentTests(_ t: TestRunner) {
    t.suite("AutomationConsent")

    // MARK: the status mapping and the cap each state earns

    t.expectEqual(AutomationConsent.classify(0), .granted, "noErr is granted")
    t.expectEqual(AutomationConsent.classify(-1743), .denied, "errAEEventNotPermitted is denied")
    t.expectEqual(AutomationConsent.classify(-1744), .pending, "errAEEventWouldRequireUserConsent is pending")
    t.expectEqual(AutomationConsent.classify(-600), .notRunning, "procNotFound is not running")
    t.expectEqual(AutomationConsent.classify(-50), .unknown, "anything else is unknown")
    t.expectEqual(AutomationConsent.granted.exitTimeout, 120, "granted keeps the 120 s cap")
    for state in [AutomationConsent.pending, .notRunning, .unknown] {
        t.expect(state.exitTimeout >= 600, "\(state) gets the long cap, never the short one")
    }
    // The real probe never prompts and never crashes, even for an app that
    // does not exist; it cannot say "granted" for one.
    t.expect(AutomationConsent.query(bundleID: "dev.facens.agentmenu.no-such-app") != .granted, "a missing app is not granted")

    // MARK: the launcher

    func launch(_ state: AutomationConsent) -> (caps: [TimeInterval?], error: Error?) {
        var caps: [TimeInterval?] = []
        var probed: [String] = []
        let launcher = TerminalLauncher(
            timedRunner: { _, _, _, cap in caps.append(cap) },
            consent: { probed.append($0); return state }
        )
        var failure: Error?
        do { try launcher.open(command: command, terminal: iterm, binaryPath: nil) } catch { failure = error }
        t.expectEqual(probed, ["com.googlecode.iterm2"], "the terminal's own bundle id is probed")
        return (caps, failure)
    }

    let granted = launch(.granted)
    t.expectEqual(granted.caps.count, 1, "granted runs the script")
    t.expectEqual(granted.caps.first ?? nil, 120, "granted keeps the 120 s cap")
    for state in [AutomationConsent.pending, .notRunning, .unknown] {
        let result = launch(state)
        t.expectEqual(result.caps.count, 1, "\(state) runs the script")
        t.expectEqual(result.caps.first ?? nil, AutomationConsent.promptExitTimeout, "\(state) waits on the long cap so the prompt is never pre-empted")
    }
    let denied = launch(.denied)
    t.expectEqual(denied.caps.count, 0, "denied never runs the script")
    if let error = denied.error as? TerminalLauncherError, case .automationDenied = error {
        let text = error.description
        t.expect(text.contains("Privacy & Security › Automation › AgentMenu"), "the denial names the Settings path")
        t.expect(text.contains("tccutil reset AppleEvents dev.facens.agentmenu"), "and the tccutil fallback")
    } else {
        t.expect(false, "denied throws automationDenied, got \(String(describing: denied.error))")
    }

    // An argv terminal has no Apple Event and is never probed.
    var probedArgv = false
    let argvLauncher = TerminalLauncher(timedRunner: { _, _, _, _ in }, consent: { _ in probedArgv = true; return .denied })
    let ghostty = TerminalManifest(id: "ghostty", displayName: "Ghostty", kind: .argv, bundleID: "com.mitchellh.ghostty", binary: "ghostty", args: ["{command}"], origin: .bundled)
    t.expectNoThrow("an argv terminal launches without a consent check") {
        try argvLauncher.open(command: command, terminal: ghostty, binaryPath: "/opt/ghostty")
    }
    t.expect(!probedArgv, "no Automation probe for an argv terminal")

    // MARK: the real timed runner honours the per-call cap

    let timed = TerminalLauncher.systemTimedRunner(exitTimeout: 0.2, detachTimeout: 0.2)
    do {
        let start = Date()
        do {
            try timed("/bin/sh", ["-c", "sleep 30"], true, nil)
            t.expect(false, "the default cap should cut off a stuck process")
        } catch TerminalLauncherError.terminalDidNotAnswer {
            t.expect(Date().timeIntervalSince(start) < 5, "the default cap applies when none is given")
        } catch {
            t.expect(false, "wrong error: \(error)")
        }
    }
    t.expectNoThrow("a longer per-call cap outlasts the default one") {
        try timed("/bin/sh", ["-c", "sleep 1"], true, 20)
    }

    // MARK: focus

    func focus(_ state: AutomationConsent) -> (outcome: FocusOutcome, caps: [TimeInterval?]) {
        var caps: [TimeInterval?] = []
        let focus = TerminalFocus(
            timedRunner: { _, _, cap in caps.append(cap); return "focused" },
            isRunning: { _ in true },
            consent: { _ in state }
        )
        return (focus.focus(focusRequest()), caps)
    }
    let focusGranted = focus(.granted)
    t.expectEqual(focusGranted.outcome, .focused, "granted focuses")
    t.expectEqual(focusGranted.caps.first ?? nil, 120, "granted keeps the 120 s cap")
    let focusPending = focus(.pending)
    t.expectEqual(focusPending.outcome, .focused, "pending still focuses once answered")
    t.expectEqual(focusPending.caps.first ?? nil, AutomationConsent.promptExitTimeout, "pending waits on the long cap")
    let focusDenied = focus(.denied)
    t.expectEqual(focusDenied.outcome, .automationDenied(terminalName: "iTerm2"), "denied is reported without running the script")
    t.expectEqual(focusDenied.caps.count, 0, "and no script runs")
    t.expect(focusDenied.outcome.message?.contains("Automation › AgentMenu") == true, "the row names the pane")
    t.expect(focusDenied.outcome.explanation?.contains("tccutil reset AppleEvents dev.facens.agentmenu") == true, "the tooltip carries the tccutil fallback")
}
