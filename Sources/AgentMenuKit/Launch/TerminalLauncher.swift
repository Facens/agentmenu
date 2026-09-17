// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Everything that can go wrong actually running a terminal's process, once
/// its binary/AppleScript is already known — as opposed to
/// `CommandBuilderError`, which covers "the launch could not even be
/// assembled" (a missing binary, a missing directory). R6 names "terminal
/// not running" as a failure that must be reported with its reason, distinct
/// from "AgentMenu could not find the binary" — a user acts on the two
/// differently, so they get different cases rather than one reused for both.
public enum TerminalLauncherError: Error, CustomStringConvertible, Equatable {
    /// The terminal's own process (`osascript`, or an `argv` terminal's
    /// resolved binary) exited non-zero within the wait cap
    /// `TerminalLauncher.systemRunner`'s `waitTimeout` allows — the terminal
    /// refused the command, not "AgentMenu could not find it." `stderrOutput`
    /// is whatever the process wrote there, trimmed; empty when it wrote
    /// nothing.
    case terminalFailed(exitCode: Int32, stderrOutput: String)

    /// macOS refused the Apple Event because this app is not allowed to
    /// control the terminal. Distinct from `terminalFailed` because the fix
    /// is in System Settings, not in anything AgentMenu can change — and
    /// because an ad-hoc signed build earns a fresh refusal every time it is
    /// rebuilt, the permission being remembered against the exact code hash
    /// of the build that asked for it.
    case automationDenied(detail: String)

    /// A process whose exit status was the answer never produced one inside
    /// the cap. Reported rather than swallowed: a launch nobody can confirm
    /// is not a launch that worked.
    case terminalDidNotAnswer(seconds: TimeInterval)

    public var description: String {
        switch self {
        case .terminalFailed(let exitCode, let stderrOutput):
            let detail = stderrOutput.isEmpty ? "" : ": \(stderrOutput)"
            return "the terminal exited with status \(exitCode)\(detail)"
        case .automationDenied:
            return "macOS has not allowed AgentMenu to control your terminal. "
                + "System Settings › Privacy & Security › Automation › AgentMenu, and tick the terminal. "
                + "A rebuilt AgentMenu asks again: the permission is remembered against the build that asked for it."
        case .terminalDidNotAnswer(let seconds):
            return "the terminal did not answer within \(Int(seconds)) seconds, so the launch could not be confirmed"
        }
    }
}

/// Opens a `LaunchCommand` in a terminal, per its manifest's kind.
public struct TerminalLauncher {
    /// Injected so tests can assert what would run without opening a
    /// terminal — `open` never touches `Process` directly, `systemRunner()`
    /// does. A test double simulates a terminal that refused the command by
    /// simply throwing (typically `TerminalLauncherError.terminalFailed`)
    /// from this closure — `open` has nothing extra to do with the error,
    /// it is already `throws` and just propagates it.
    ///
    /// `expectsExit` says which of the two shapes the spawned process has.
    /// `osascript` always runs to completion and its exit status is the only
    /// evidence the terminal accepted the command; an `argv` terminal
    /// typically stays running, so waiting for it to exit would mean waiting
    /// for the user to close the window.
    public typealias Runner = (_ executable: String, _ arguments: [String], _ expectsExit: Bool) throws -> Void

    private let runner: Runner

    public init(runner: @escaping Runner) {
        self.runner = runner
    }

    /// Two caps, because there are two shapes of process here.
    ///
    /// `detachTimeout` bounds the wait for a terminal that is expected to
    /// keep running (`argv` kind): still running at the cap is the ordinary
    /// case — the window is already open — and counts as success.
    ///
    /// `exitTimeout` bounds the wait for a process whose exit status is the
    /// answer (`osascript`). It is generous on purpose. The old single
    /// three-second cap treated "still running" as success for this shape
    /// too, and the thing that most often keeps `osascript` running past
    /// three seconds is macOS holding it while it asks the user whether this
    /// app may control the terminal at all. Calling that success turned the
    /// permission prompt into a launch that reported success and did
    /// nothing.
    ///
    /// Neither cap belongs on the main thread — the caller runs this off it.
    public static func systemRunner(
        exitTimeout: TimeInterval = 120.0,
        detachTimeout: TimeInterval = 3.0
    ) -> Runner {
        { executable, arguments, expectsExit in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments

            let stderrPipe = Pipe()
            process.standardError = stderrPipe

            // Set before `run()`: a `terminationHandler` assigned afterward
            // races a process that exits before the assignment lands.
            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }

            try process.run()

            // `Process.run()` throws only when the executable could not be
            // launched at all — it does not wait, and never looks at
            // `terminationStatus`, so `osascript` exiting non-zero (iTerm
            // not installed, a script error, the terminal refusing the
            // Apple Event) used to reach the caller as silent success. This
            // waits, but only up to `waitTimeout`: the AppleScript path
            // returns quickly once the terminal has the command (`write
            // text` doesn't block on the session staying open), and an argv
            // terminal typically detaches, so a process still running past
            // the cap is the ordinary case — the tab is already open — and
            // is treated as success rather than blocking the caller (the
            // main thread, for the popover) indefinitely. Only a definite
            // non-zero exit observed within the cap is reported as failure.
            let cap = expectsExit ? exitTimeout : detachTimeout
            guard exited.wait(timeout: .now() + cap) == .success else {
                // A process that had to exit and did not is not a success it
                // has yet to report — it is a launch with no evidence behind
                // it, and saying so beats saying nothing.
                if expectsExit {
                    process.terminate()
                    throw TerminalLauncherError.terminalDidNotAnswer(seconds: cap)
                }
                return
            }

            guard process.terminationStatus == 0 else {
                let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if Self.isAppleEventDenial(message) {
                    throw TerminalLauncherError.automationDenied(detail: message)
                }
                throw TerminalLauncherError.terminalFailed(exitCode: process.terminationStatus, stderrOutput: message)
            }
        }
    }

    /// macOS refuses an Apple Event from an app the user has not allowed to
    /// control the target, and `osascript` reports that as `-1743` /
    /// "Not authorized to send Apple events". It is worth telling apart from
    /// every other script failure because the fix is not in this app: it is a
    /// checkbox in System Settings, and nothing the user changes in AgentMenu
    /// will help until it is ticked.
    static func isAppleEventDenial(_ stderrOutput: String) -> Bool {
        stderrOutput.contains("-1743") || stderrOutput.lowercased().contains("not authorized to send apple events")
    }

    /// AppleScript kind: the command and directory are always passed as
    /// `argv` to `osascript -e '<script>' <command> <dir>` — never
    /// interpolated into the script text — so a script written the
    /// recommended way (docs/adding-a-terminal.md, "prefer a script with
    /// `on run argv`") never has to escape anything into it. This is the
    /// same idiom the contract's `osascript - <script> <command> <dir>`
    /// describes, in the form the `Runner` signature can actually carry:
    /// `Runner` is `(executable, [String]) -> Void` with no stdin channel,
    /// so the literal `osascript -` (read script from stdin) can't reach an
    /// injected test runner — `-e '<script>'` delivers the same script text
    /// as a plain argv element instead, and `osascript -e '…' a b` passes
    /// `a`/`b` to `on run argv` exactly like `osascript - a b` would
    /// (verified by hand: `osascript -e 'on run argv
    /// return item 1 of argv
    /// end run' hello world` prints `hello`).
    ///
    /// The doc also names four placeholders a script's own text can use —
    /// `{dir}`, `{command}`, `{dir_applescript}`, `{command_applescript}` —
    /// for a script that must inline the command rather than read `argv`
    /// (`LaunchCommand.appleScriptLiteral` exists precisely for this). Those
    /// are substituted into the script text here, in addition to (not
    /// instead of) passing them as `argv` items 1/2 — a script written the
    /// recommended `on run argv` way contains none of the four literal
    /// substrings, so substitution is a no-op for it.
    ///
    /// argv kind: `{dir}`/`{command}` are substituted into the manifest's
    /// `args`, and the terminal's own resolved binary is spawned.
    public func open(command: LaunchCommand, terminal: TerminalManifest, binaryPath: String?) throws {
        switch terminal.kind {
        case .applescript:
            // Parsing guarantees `applescript` is present for this kind.
            let rawScript = terminal.appleScript ?? ""
            let script = Self.substitutePlaceholders(rawScript, [
                ("{dir_applescript}", ShellQuoting.appleScriptEscaped(command.workingDirectory)),
                ("{command_applescript}", command.appleScriptLiteral),
                ("{dir}", command.workingDirectory),
                ("{command}", command.shellCommand),
            ])
            try runner("/usr/bin/osascript", ["-e", script, command.shellCommand, command.workingDirectory], true)
        case .argv:
            guard let binaryPath else {
                throw CommandBuilderError.binaryNotResolved(terminal.binary ?? terminal.id)
            }
            let arguments = terminal.args.map { arg in
                Self.substitutePlaceholders(arg, [
                    ("{dir}", command.workingDirectory),
                    ("{command}", command.shellCommand),
                ])
            }
            try runner(binaryPath, arguments, false)
        }
    }

    /// Substitutes every `(placeholder, value)` pair into `template` in one
    /// left-to-right scan, so a `value` that happens to contain another
    /// placeholder's literal text — a folder path containing the substring
    /// `{command}`, say — is emitted as-is and never itself rescanned. Two
    /// chained `String.replacingOccurrences` calls (the previous shape) run
    /// the second replacement over the *output* of the first, so a `{dir}`
    /// substitution landing text that spells `{command}` would get
    /// corrupted by the very next line. This is a single pass instead: once
    /// a placeholder is matched at a position, its replacement value is
    /// appended and the scan resumes right after the placeholder in the
    /// *template*, never re-entering the value just inserted.
    static func substitutePlaceholders(_ template: String, _ replacements: [(placeholder: String, value: String)]) -> String {
        var result = ""
        var remaining = Substring(template)
        while !remaining.isEmpty {
            if let match = replacements.first(where: { remaining.hasPrefix($0.placeholder) }) {
                result += match.value
                remaining = remaining.dropFirst(match.placeholder.count)
            } else {
                result.append(remaining.removeFirst())
            }
        }
        return result
    }
}
