// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Why a row's terminal cannot be brought forward at all, before anything is
/// asked of it. Each case has words for the row, because a click that does
/// nothing and says nothing is the thing R37 forbids.
public enum FocusUnavailableReason: Error, Equatable, Sendable {
    /// The row has no controlling terminal (or one that is not a device
    /// name): there is no tab to look for.
    case noTTY
    /// The host is not a terminal AgentMenu recognises ("Other terminal").
    case unrecognisedTerminal
    /// A recognised terminal whose manifest has no `focus_applescript`: a
    /// user overlay written before the key existed, or a terminal nobody has
    /// written a focus script for.
    case terminalCannotFocus(displayName: String)

    public var message: String {
        switch self {
        case .noTTY:
            return "This session has no terminal to bring forward."
        case .unrecognisedTerminal:
            return "AgentMenu doesn't recognise this terminal, so it can't bring it forward."
        case .terminalCannotFocus(let displayName):
            return "\(displayName) can't be focused from AgentMenu."
        }
    }
}

/// Everything needed to ask a terminal for one tab: which script, which app
/// to check is running first, and the tty to look for.
public struct FocusRequest: Equatable, Sendable {
    public let terminalID: String
    public let terminalName: String
    /// The terminal's bundle id, for the running check that has to come
    /// before any Apple Event: `tell application` launches an app that is not
    /// running.
    public let bundleID: String
    public let script: String
    /// `/dev/ttys004`. One form only, the one both terminals report for a
    /// tab or session (`TerminalFocus.deviceForm`).
    public let tty: String

    public init(terminalID: String, terminalName: String, bundleID: String, script: String, tty: String) {
        self.terminalID = terminalID
        self.terminalName = terminalName
        self.bundleID = bundleID
        self.script = script
        self.tty = tty
    }
}

/// How a focus attempt ended.
public enum FocusOutcome: Equatable, Sendable {
    case focused
    /// Refused before anything ran.
    case unavailable(FocusUnavailableReason)
    /// The terminal is not running. No script was run, so it was not
    /// launched by asking.
    case notRunning(terminalName: String)
    /// The terminal answered that none of its tabs has this tty.
    case windowGone(terminalName: String)
    /// macOS refused the Apple Event (-1743).
    case automationDenied(terminalName: String)
    /// Anything else the script or `osascript` reported.
    case failed(detail: String)

    public var isFocused: Bool { self == .focused }

    /// One line for the row, nil on success. Short enough to be useful when
    /// the row truncates it, and ending in the fix where there is one.
    public var message: String? {
        switch self {
        case .focused:
            return nil
        case .unavailable(let reason):
            return reason.message
        case .notRunning(let name):
            return "\(name) isn't running. Open it to get this session's window back."
        case .windowGone(let name):
            return "\(name) has no tab for this session any more. Its window may have been closed."
        case .automationDenied(let name):
            return "Allow AgentMenu to control \(name): System Settings › Privacy & Security › Automation › AgentMenu."
        case .failed(let detail):
            return detail.isEmpty ? "Couldn't bring the terminal forward." : "Couldn't bring the terminal forward: \(detail)"
        }
    }

    /// The longer explanation for a tooltip, where a line is not enough.
    /// For a denial this is the launcher's own fix text, so the two
    /// features tell the user the same thing.
    public var explanation: String? {
        switch self {
        case .automationDenied:
            return TerminalLauncherError.automationDenied(detail: "").description
        default:
            return message
        }
    }
}

/// Brings the terminal tab that hosts a session to the front (R8, R37, KTD10).
///
/// Two halves. `request(for:terminals:clientTTY:)` decides, from a row and
/// the terminal manifests, whether there is anything to ask and of whom; it
/// is pure. `TerminalFocus.focus(_:)` asks, through injected closures for the
/// running check and for `osascript`, so a test supplies both and no terminal
/// is ever touched.
///
/// The tty is handed to the script as an `osascript` argument, after `--`,
/// and the script text is never altered: there is no placeholder substitution
/// for a focus script. A tty cannot spell a quote or a backslash, but the
/// rule is cheap to keep and means the script a user reads in the manifest is
/// exactly the script that runs.
public struct TerminalFocus {
    /// `osascript`'s arguments in, its standard output out. A non-zero exit
    /// throws, with `TerminalLauncherError.automationDenied` for a denied
    /// Apple Event.
    public typealias Runner = (_ executable: String, _ arguments: [String]) throws -> String
    /// Whether an app with this bundle id is running right now.
    public typealias IsRunning = (_ bundleID: String) -> Bool

    /// What a focus script answers when no tab has the tty.
    public static let notFoundAnswer = "not found"

    /// A `Runner` that is also told how long it may wait (`nil` = its own
    /// default). See `TerminalLauncher.TimedRunner`.
    public typealias TimedRunner = (_ executable: String, _ arguments: [String], _ exitTimeout: TimeInterval?) throws -> String

    private let runner: TimedRunner
    private let isRunning: IsRunning
    private let consent: TerminalLauncher.ConsentProbe?

    public init(runner: @escaping Runner, isRunning: @escaping IsRunning) {
        self.runner = { executable, arguments, _ in try runner(executable, arguments) }
        self.isRunning = isRunning
        self.consent = nil
    }

    /// The real wiring: Automation consent is asked, without prompting, before
    /// the script runs. See `TerminalLauncher.init(timedRunner:consent:)`.
    public init(timedRunner: @escaping TimedRunner, isRunning: @escaping IsRunning, consent: @escaping TerminalLauncher.ConsentProbe) {
        self.runner = timedRunner
        self.isRunning = isRunning
        self.consent = consent
    }

    // MARK: - The request

    /// `/dev/ttys004` for `ttys004` or `/dev/ttys004`; nil for anything that
    /// is not a bare device name. The registry and the process table give
    /// `ttys004`; Terminal.app and iTerm2 report `/dev/ttys004`; the script
    /// compares strings, so the request settles on the second.
    public static func deviceForm(_ tty: String?) -> String? {
        guard var name = tty?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else { return nil }
        if name.hasPrefix("/dev/") { name.removeFirst("/dev/".count) }
        guard !name.isEmpty,
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") })
        else { return nil }
        return "/dev/" + name
    }

    /// The request for a live row, or why there cannot be one.
    ///
    /// - Parameter clientTTY: an owned session's pane has a tty of its own,
    ///   but the window showing it belongs to the tmux client attached to
    ///   it, and that client's tty is what a terminal knows the tab by. When
    ///   the caller has one (U9), it replaces the row's tty.
    /// - Parameter terminalID: the terminal manifest id the ledger recorded
    ///   for a hosted session, which replaces the one found by walking the
    ///   process tree (that walk ends at tmux).
    public static func request(
        for session: LiveSession,
        terminals: [TerminalManifest],
        clientTTY: String? = nil,
        terminalID recordedTerminalID: String? = nil
    ) -> Result<FocusRequest, FocusUnavailableReason> {
        guard let tty = deviceForm(clientTTY ?? session.tty) else { return .failure(.noTTY) }
        // A hosted session's own process tree runs under tmux, not a terminal,
        // so the terminal that holds its window is the one the ledger
        // recorded.
        guard let terminalID = recordedTerminalID ?? session.terminal.id else { return .failure(.unrecognisedTerminal) }
        let manifest = terminals.first { $0.id == terminalID }
        guard let manifest, let script = manifest.focusAppleScript, let bundleID = manifest.bundleID else {
            return .failure(.terminalCannotFocus(displayName: manifest?.displayName ?? session.terminal.displayName))
        }
        return .success(FocusRequest(
            terminalID: manifest.id,
            terminalName: manifest.displayName,
            bundleID: bundleID,
            script: script,
            tty: tty
        ))
    }

    // MARK: - Asking

    /// Runs the request. Blocking (`osascript` can take seconds, and longer
    /// while macOS asks whether AgentMenu may control the terminal), so the
    /// caller keeps it off the main thread.
    public func focus(_ request: FocusRequest) -> FocusOutcome {
        // Before any Apple Event. Telling an app that is not running to do
        // anything starts it, and "bring that window forward" must not
        // answer itself by opening an empty terminal.
        guard isRunning(request.bundleID) else { return .notRunning(terminalName: request.terminalName) }

        // Ask macOS whether consent is already decided, without prompting. A
        // refusal on record fails at once with the fix; a decision still to
        // be made means `osascript` will sit under the consent prompt, and
        // killing it on the short cap with the sheet up would record a
        // permanent refusal, so only a granted state keeps the short cap.
        let state = consent?(request.bundleID)
        if state == .denied { return .automationDenied(terminalName: request.terminalName) }

        let output: String
        do {
            output = try runner("/usr/bin/osascript", ["-e", request.script, "--", request.tty], state?.exitTimeout)
        } catch let error as TerminalLauncherError {
            if case .automationDenied = error { return .automationDenied(terminalName: request.terminalName) }
            return .failed(detail: error.description)
        } catch {
            let text = String(describing: error)
            if TerminalLauncher.isAppleEventDenial(text) { return .automationDenied(terminalName: request.terminalName) }
            return .failed(detail: text)
        }

        // Anything but the script's explicit "not found" is a success: a
        // script a user wrote in a different style still focuses.
        let answer = output.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return answer == Self.notFoundAnswer ? .windowGone(terminalName: request.terminalName) : .focused
    }

    // MARK: - The real runner

    /// `osascript` for real: waits for it, returns what it printed, and maps
    /// a denied Apple Event to `automationDenied` the way the launcher does.
    /// The cap is generous for the launcher's reason: the thing that most
    /// often holds `osascript` is macOS asking whether this app may control
    /// the terminal at all.
    public static func systemRunner(exitTimeout: TimeInterval = 120.0) -> Runner {
        let timed = systemTimedRunner(exitTimeout: exitTimeout)
        return { executable, arguments in try timed(executable, arguments, nil) }
    }

    /// `systemRunner` with the cap chosen per call: a non-nil `exitTimeout`
    /// argument replaces the default one.
    public static func systemTimedRunner(exitTimeout defaultExitTimeout: TimeInterval = 120.0) -> TimedRunner {
        { executable, arguments, exitTimeoutOverride in
            let exitTimeout = exitTimeoutOverride ?? defaultExitTimeout
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr

            let exited = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in exited.signal() }
            try process.run()

            guard exited.wait(timeout: .now() + exitTimeout) == .success else {
                process.terminate()
                throw TerminalLauncherError.terminalDidNotAnswer(seconds: exitTimeout)
            }

            guard process.terminationStatus == 0 else {
                let data = stderr.fileHandleForReading.readDataToEndOfFile()
                let message = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if TerminalLauncher.isAppleEventDenial(message) {
                    throw TerminalLauncherError.automationDenied(detail: message)
                }
                throw TerminalLauncherError.terminalFailed(exitCode: process.terminationStatus, stderrOutput: message)
            }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8) ?? ""
        }
    }
}
