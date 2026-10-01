// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

// U6 — focus by tty and focus failures (R8, R37, KTD10).

private let focusScript = """
on run argv
  return "focused {tty}"
end run
"""

private func terminal(
    id: String = "iterm2",
    name: String = "iTerm2",
    focus: String? = focusScript
) -> TerminalManifest {
    TerminalManifest(
        id: id, displayName: name, kind: .applescript,
        bundleID: "com.example.\(id)", appleScript: "on run argv\nend run",
        focusAppleScript: focus, origin: .bundled
    )
}

private func session(tty: String? = "ttys004", terminal: TerminalIdentity = TerminalIdentity(id: "iterm2", displayName: "iTerm2")) -> LiveSession {
    LiveSession(
        key: LiveSessionKey(configDirectory: nil, pid: 4242, procStart: 1_700_000_000),
        agentID: "claude-code", agentDisplayName: "Claude Code",
        pid: 4242, status: .working, tty: tty, terminal: terminal,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
}

/// What the injected runner saw, and what it answers.
private final class ScriptedRunner {
    var calls: [(executable: String, arguments: [String])] = []
    var answer: Result<String, Error> = .success("focused\n")
    var running = true
    var runningChecks: [String] = []

    func makeFocus() -> TerminalFocus {
        TerminalFocus(
            runner: { [self] executable, arguments in
                calls.append((executable, arguments))
                return try answer.get()
            },
            isRunning: { [self] bundleID in
                runningChecks.append(bundleID)
                return running
            }
        )
    }
}

private func request(_ tty: String = "ttys004", focus: String? = focusScript) -> FocusRequest {
    guard case .success(let request) = TerminalFocus.request(for: session(tty: tty), terminals: [terminal(focus: focus)]) else {
        fatalError("expected a focus request")
    }
    return request
}

private struct PlainError: Error, CustomStringConvertible {
    let description: String
}

func runTerminalFocusTests(_ t: TestRunner) {
    t.suite("TerminalFocus")

    // MARK: the manifest key

    let withKey = """
    schema = 1
    id = "focusable"
    display_name = "Focusable"
    kind = "applescript"
    bundle_id = "com.example.focusable"
    applescript = "on run argv\\nend run"
    focus_applescript = "on run argv\\n  return \\"focused\\"\\nend run"
    """
    let withoutKey = withKey.split(separator: "\n").filter { !$0.hasPrefix("focus_applescript") }.joined(separator: "\n")
    t.expectNoThrow("a manifest with focus_applescript parses") {
        let manifest = try TerminalManifest.parse(withKey, origin: .user)
        t.expectEqual(manifest.focusAppleScript, "on run argv\n  return \"focused\"\nend run", "the script is kept verbatim")
        t.expect(manifest.focusAppleScript != nil, "and the terminal can be focused")
    }
    t.expectNoThrow("a manifest without focus_applescript still parses") {
        let manifest = try TerminalManifest.parse(withoutKey, origin: .user)
        t.expectEqual(manifest.focusAppleScript, nil, "the capability is absent")
        t.expect(manifest.focusAppleScript == nil, "so focus is hidden")
    }
    t.expectThrows("an empty focus_applescript is rejected, not treated as absent") {
        try TerminalManifest.parse(withKey.replacingOccurrences(of: "focus_applescript = \"on run argv\\n  return \\\"focused\\\"\\nend run\"", with: "focus_applescript = \"\""), origin: .user)
    }
    t.expectThrows("a non-string focus_applescript is rejected") {
        try TerminalManifest.parse(withoutKey + "\nfocus_applescript = 3", origin: .user)
    }
    t.expectThrows("an argv terminal cannot carry focus_applescript") {
        try TerminalManifest.parse("""
        schema = 1
        id = "argv-focus"
        display_name = "Argv"
        kind = "argv"
        binary = "tool"
        args = []
        focus_applescript = "on run argv\\nend run"
        """, origin: .user)
    }

    // The two bundled manifests both carry a script that takes a tty.
    let resources = repositoryRoot().appendingPathComponent("Resources/terminals")
    for file in ["iterm2.toml", "terminal-app.toml"] {
        let text = try? String(contentsOf: resources.appendingPathComponent(file), encoding: .utf8)
        let manifest = text.flatMap { try? TerminalManifest.parse($0, origin: .bundled) }
        t.expect(manifest?.focusAppleScript != nil, "\(file) ships a focus script")
        let script = manifest?.focusAppleScript ?? ""
        t.expect(script.contains("on run argv") && script.contains("item 1 of argv"), "\(file)'s focus script reads the tty from argv")
        t.expect(script.contains("\"not found\"") && script.contains("\"focused\""), "\(file)'s focus script answers focused / not found")
        t.expect(!script.contains("{tty}"), "\(file)'s focus script has nothing to substitute")
    }

    // MARK: the tty form

    t.expectEqual(TerminalFocus.deviceForm("ttys004"), "/dev/ttys004", "a bare device name gets /dev/")
    t.expectEqual(TerminalFocus.deviceForm("/dev/ttys004"), "/dev/ttys004", "the device form is left alone")
    t.expectEqual(TerminalFocus.deviceForm(" ttys012\n"), "/dev/ttys012", "whitespace is trimmed")
    t.expectEqual(TerminalFocus.deviceForm(nil), nil, "no tty is no device")
    t.expectEqual(TerminalFocus.deviceForm(""), nil, "an empty tty is no device")
    t.expectEqual(TerminalFocus.deviceForm("/dev/"), nil, "a bare /dev/ is no device")
    t.expectEqual(TerminalFocus.deviceForm("ttys004\"; do shell script \"x"), nil, "a name with quotes or spaces is rejected outright")
    t.expectEqual(TerminalFocus.deviceForm("../etc/passwd"), nil, "a path is not a device name")

    // MARK: the request

    let ok = TerminalFocus.request(for: session(), terminals: [terminal()])
    if case .success(let built) = ok {
        t.expectEqual(built.tty, "/dev/ttys004", "the request carries the tty in device form")
        t.expectEqual(built.terminalID, "iterm2", "for the row's terminal")
        t.expectEqual(built.bundleID, "com.example.iterm2", "with the bundle id the running check needs")
        t.expectEqual(built.script, focusScript, "and the manifest's script, untouched")
    } else {
        t.expect(false, "a row with a tty in a focusable terminal gets a request")
    }
    if case .success(let viaClient) = TerminalFocus.request(for: session(tty: "ttys009"), terminals: [terminal()], clientTTY: "ttys021") {
        t.expectEqual(viaClient.tty, "/dev/ttys021", "a supplied client tty replaces the row's own")
    } else {
        t.expect(false, "a client tty makes a request")
    }
    if case .success(let onlyClient) = TerminalFocus.request(for: session(tty: nil), terminals: [terminal()], clientTTY: "ttys021") {
        t.expectEqual(onlyClient.tty, "/dev/ttys021", "a client tty stands in for a row with none")
    } else {
        t.expect(false, "a client tty makes a request even without a row tty")
    }

    // MARK: unavailable

    t.expectEqual(
        TerminalFocus.request(for: session(tty: nil), terminals: [terminal()]).failureReason, .noTTY,
        "a row with no tty cannot be focused"
    )
    t.expectEqual(
        TerminalFocus.request(for: session(terminal: .other), terminals: [terminal()]).failureReason, .unrecognisedTerminal,
        "an Other-terminal row cannot be focused"
    )
    t.expectEqual(
        TerminalFocus.request(for: session(), terminals: [terminal(focus: nil)]).failureReason,
        .terminalCannotFocus(displayName: "iTerm2"),
        "a terminal whose manifest has no focus script — a user overlay from before the key — hides focus"
    )
    t.expectEqual(
        TerminalFocus.request(for: session(), terminals: []).failureReason,
        .terminalCannotFocus(displayName: "iTerm2"),
        "a terminal with no manifest at all is named by the row's own label"
    )
    t.expect(FocusUnavailableReason.terminalCannotFocus(displayName: "iTerm2").message.contains("can't be focused from AgentMenu"), "the reason is words")
    t.expect(!FocusUnavailableReason.unrecognisedTerminal.message.isEmpty, "Other terminal says why")
    t.expect(!FocusUnavailableReason.noTTY.message.isEmpty, "no tty says why")

    // MARK: running it

    let happy = ScriptedRunner()
    t.expectEqual(happy.makeFocus().focus(request()), .focused, "a script that finds the tab focuses")
    t.expectEqual(happy.calls.count, 1, "one script ran")
    t.expectEqual(happy.calls.first?.executable, "/usr/bin/osascript", "through osascript")
    t.expectEqual(
        happy.calls.first?.arguments ?? [],
        ["-e", focusScript, "--", "/dev/ttys004"],
        "the script text is verbatim, and the tty is the argument after --"
    )
    t.expectEqual(happy.runningChecks, ["com.example.iterm2"], "the running check used the terminal's bundle id")

    // `{tty}` in the script is text, not a placeholder: the argument carries the value.
    let literal = ScriptedRunner()
    _ = literal.makeFocus().focus(request("ttys004", focus: "on run argv\nreturn \"{tty}\"\nend run"))
    t.expect(literal.calls.first?.arguments[1].contains("{tty}") == true, "a {tty} in a focus script is never interpolated")
    t.expect(literal.calls.first?.arguments[1].contains("ttys004") == false, "the tty never enters the script text")

    let hostile = ScriptedRunner()
    _ = hostile.makeFocus().focus(request("/dev/ttys004"))
    t.expectEqual(hostile.calls.first?.arguments.last, "/dev/ttys004", "a tty already in device form is passed as is")

    // Not running: no script at all.
    let notRunning = ScriptedRunner()
    notRunning.running = false
    t.expectEqual(notRunning.makeFocus().focus(request()), .notRunning(terminalName: "iTerm2"), "a terminal that is not running is reported")
    t.expectEqual(notRunning.calls.count, 0, "and no script runs, so the terminal is not launched by asking")
    t.expect(FocusOutcome.notRunning(terminalName: "iTerm2").message?.contains("isn't running") == true, "the row says it isn't running")

    // "not found" → the window is gone.
    let gone = ScriptedRunner()
    gone.answer = .success("not found\n")
    t.expectEqual(gone.makeFocus().focus(request()), .windowGone(terminalName: "iTerm2"), "a script answering not found is a window that is gone")
    let goneLoud = ScriptedRunner()
    goneLoud.answer = .success("  Not Found  ")
    t.expectEqual(goneLoud.makeFocus().focus(request()), .windowGone(terminalName: "iTerm2"), "case and spacing do not matter")
    t.expect(FocusOutcome.windowGone(terminalName: "iTerm2").message != nil, "a gone window says so on the row")
    let quiet = ScriptedRunner()
    quiet.answer = .success("")
    t.expectEqual(quiet.makeFocus().focus(request()), .focused, "a script that returns nothing and does not fail has focused")

    // -1743 → Automation denied, with the System Settings path.
    let denied = ScriptedRunner()
    denied.answer = .failure(PlainError(description: "execution error: Not authorized to send Apple events to iTerm. (-1743)"))
    let deniedOutcome = denied.makeFocus().focus(request())
    t.expectEqual(deniedOutcome, .automationDenied(terminalName: "iTerm2"), "a -1743 from the runner is Automation denied")
    t.expect(deniedOutcome.message?.contains("System Settings") == true, "the row names System Settings")
    t.expect(deniedOutcome.message?.contains("Automation") == true, "and the Automation pane")
    t.expectEqual(
        deniedOutcome.explanation,
        TerminalLauncherError.automationDenied(detail: "").description,
        "the tooltip is the launcher's own fix text"
    )
    let launcherDenied = ScriptedRunner()
    launcherDenied.answer = .failure(TerminalLauncherError.automationDenied(detail: "anything"))
    t.expectEqual(launcherDenied.makeFocus().focus(request()), .automationDenied(terminalName: "iTerm2"), "the real runner's denial maps the same way")

    // Anything else keeps its reason.
    let broken = ScriptedRunner()
    broken.answer = .failure(TerminalLauncherError.terminalFailed(exitCode: 1, stderrOutput: "syntax error"))
    if case .failed(let detail) = broken.makeFocus().focus(request()) {
        t.expect(detail.contains("syntax error"), "a script failure carries the terminal's own words")
    } else {
        t.expect(false, "another failure is a failure")
    }
    t.expect(FocusOutcome.focused.message == nil, "success has nothing to say")
    t.expect(FocusOutcome.focused.isFocused, "and is focused")

    // MARK: the real runner's plumbing, with a stand-in for osascript

    let echo = TerminalFocus.systemRunner(exitTimeout: 5)
    t.expectNoThrow("the system runner returns what the process printed") {
        let out = try echo("/bin/echo", ["not found"])
        t.expectEqual(out.trimmingCharacters(in: .whitespacesAndNewlines), "not found", "standard output comes back")
    }
    t.expectThrows("a non-zero exit throws") { try echo("/usr/bin/false", []) }
    t.expectNoThrow("a denial on stderr is recognised") {
        do {
            _ = try echo("/bin/sh", ["-c", "echo 'Not authorized to send Apple events to iTerm. (-1743)' >&2; exit 1"])
            t.expect(false, "the denial should have thrown")
        } catch let error as TerminalLauncherError {
            if case .automationDenied = error { t.expect(true, "the denial is automationDenied") } else { t.expect(false, "wrong case: \(error)") }
        }
    }

    // A script that never finishes (macOS holding osascript on an Automation
    // prompt) is cut off at the cap, not waited on: the notification path
    // runs this runner with a 3 s cap and must not hang.
    do {
        let slow = TerminalFocus.systemRunner(exitTimeout: 0.3)
        let start = Date()
        do {
            _ = try slow("/bin/sleep", ["30"])
            t.expect(false, "a process that outlives the cap should throw, not return")
        } catch TerminalLauncherError.terminalDidNotAnswer {
            t.expect(true, "an unanswered script is reported as the terminal not answering")
        } catch {
            t.expect(false, "wrong error type: \(error)")
        }
        let elapsed = Date().timeIntervalSince(start)
        t.expect(elapsed < 5.0, "the call returned at the cap (\(elapsed)s), not after the child's own 30 s sleep")
    }
}

private extension Result where Success == FocusRequest, Failure == FocusUnavailableReason {
    var failureReason: FocusUnavailableReason? {
        if case .failure(let reason) = self { return reason }
        return nil
    }
}
