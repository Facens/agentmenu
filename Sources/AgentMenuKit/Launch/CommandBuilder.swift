// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// POSIX shell and AppleScript string-literal quoting. Two separate layers
/// (KTD4): shell single-quoting does nothing about the double quote and the
/// backslash that delimit and escape an AppleScript string literal, and both
/// characters are legal in a macOS filename.
public enum ShellQuoting {
    /// Wraps `value` in single quotes, replacing every embedded `'` with the
    /// close-quote/escaped-quote/reopen-quote dance (`'\''`) POSIX shells
    /// require. Applied unconditionally — every token in `shellCommand` is
    /// quoted this way, not only the ones that need it, so there is exactly
    /// one rule to get right instead of a "quote only if necessary" branch
    /// that has to special-case values like Claude Code's own
    /// `{"advisorModel":""}` disable argument.
    public static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Escapes `\` and `"` for a value that will sit inside an AppleScript
    /// string literal (`"…"`). Single pass, character by character, so an
    /// already-inserted escape is never itself re-escaped.
    public static func appleScriptEscaped(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.count)
        for character in value {
            if character == "\\" || character == "\"" {
                result.append("\\")
            }
            result.append(character)
        }
        return result
    }
}

/// A resolved launch: an absolute-path executable, an argv vector, an
/// environment dictionary, and the working directory (KTD4 — never a shell
/// alias, because a GUI app inherits neither `~/.zshrc` nor `~/.local/bin`).
public struct LaunchCommand: Equatable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String: String]
    public let workingDirectory: String

    public init(executable: String, arguments: [String], environment: [String: String], workingDirectory: String) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
    }

    /// `cd '<dir>' && VAR='value' '/abs/binary' 'arg' …` — every token
    /// single-quoted (see `ShellQuoting.singleQuoted`), ready for
    /// `write text` / `do script` in an interactive login shell. When
    /// `executable` is empty (`CommandBuilder.terminalOnly`) this is just
    /// `cd '<dir>'` — there is nothing to run, so no trailing `&&`.
    public var shellCommand: String {
        let cd = "cd \(ShellQuoting.singleQuoted(workingDirectory))"
        guard !executable.isEmpty else { return cd }

        var rest: [String] = []
        for key in environment.keys.sorted() {
            rest.append("\(key)=\(ShellQuoting.singleQuoted(environment[key]!))")
        }
        rest.append(ShellQuoting.singleQuoted(executable))
        rest.append(contentsOf: arguments.map(ShellQuoting.singleQuoted))

        return cd + " && " + rest.joined(separator: " ")
    }

    /// `shellCommand`, escaped for an AppleScript string literal. Used by the
    /// `{command_applescript}` manifest placeholder — the fallback for a
    /// terminal script that must inline the command as text rather than
    /// receive it as an `on run argv` argument.
    public var appleScriptLiteral: String {
        ShellQuoting.appleScriptEscaped(shellCommand)
    }
}

/// Everything that can go wrong turning a resolved preset into a
/// `LaunchCommand`.
public enum CommandBuilderError: Error, CustomStringConvertible {
    /// No cached or freshly-resolved path exists for this binary name.
    case binaryNotResolved(String)
    /// The launch target's folder does not exist (R6).
    case directoryMissing(String)
    /// The manifest declares a profile mechanism (`profile_env` /
    /// `profile_flag`) but no `Profile` was supplied to carry it.
    case profileRequired(agent: String)

    public var description: String {
        switch self {
        case .binaryNotResolved(let binary):
            return "could not resolve a path for '\(binary)'"
        case .directoryMissing(let path):
            return "the folder '\(path)' does not exist"
        case .profileRequired(let agent):
            return "\(agent) requires a profile, but none was given"
        }
    }
}

/// Turns a launch target plus its resolved preset into a `LaunchCommand`
/// (R4, R7, R8, R9, R13, R22) — the product's core transform.
public enum CommandBuilder {
    /// Flag order is stable and documented because `agentmenu resolve
    /// --command` must print exactly what the popover launches: any
    /// `profileMechanism == .flag` argument first (a profile is an account,
    /// selected before anything else), then model, effort, permission mode,
    /// advisor, the manifest's static `extraArgs`, and finally the project
    /// path when `projectArgument == .positional`.
    public static func build(
        agent: AgentManifest,
        resolved: ResolvedPreset,
        profile: Profile?,
        directory: String,
        binaryPath: String
    ) throws -> LaunchCommand {
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory)
        guard exists, isDirectory.boolValue else {
            throw CommandBuilderError.directoryMissing(directory)
        }
        guard !binaryPath.isEmpty else {
            throw CommandBuilderError.binaryNotResolved(agent.binary)
        }

        var environment: [String: String] = [:]
        var arguments: [String] = []

        switch agent.profileMechanism {
        case .environment(let name):
            guard let profile else { throw CommandBuilderError.profileRequired(agent: agent.id) }
            environment[name] = profile.expandedConfigDirectory.path
        case .flag(let flag):
            guard let profile else { throw CommandBuilderError.profileRequired(agent: agent.id) }
            arguments.append(flag)
            arguments.append(profile.expandedConfigDirectory.path)
        case .none:
            break
        }

        let preset = resolved.preset

        // Every branch below re-checks `spec.accepts(...)` even though
        // `PresetResolver` already stripped unsupported values from
        // `resolved.preset` — R13's "never sent" guarantee should not rest
        // on the caller having gone through the resolver first.
        if let model = preset.model, let spec = agent.model, spec.accepts(model) {
            arguments.append(spec.flag)
            arguments.append(model)
        }
        if let effort = preset.effort, let spec = agent.effort, spec.accepts(effort) {
            arguments.append(spec.flag)
            arguments.append(effort)
        }
        if let mode = preset.permissionMode, let spec = agent.permissionMode, spec.accepts(mode) {
            arguments.append(spec.flag)
            arguments.append(mode)
        }
        if let advisor = preset.advisor, let spec = agent.advisor {
            switch advisor {
            case .model(let model) where spec.accepts(model):
                arguments.append(spec.flag)
                arguments.append(model)
            case .off where spec.canDisable:
                arguments.append(contentsOf: spec.disableArgs)
            default:
                break
            }
        }

        arguments.append(contentsOf: agent.extraArgs)

        if agent.projectArgument == .positional {
            arguments.append(directory)
        }

        return LaunchCommand(
            executable: binaryPath,
            arguments: arguments,
            environment: environment,
            workingDirectory: directory
        )
    }

    /// A plain shell in the folder, starting no agent (R5). `executable` is
    /// empty rather than, say, `/bin/zsh` — this is not "launch a shell
    /// binary", it is "there is nothing to launch"; the terminal's own
    /// default shell takes over once the AppleScript / argv terminal opens
    /// the window and runs `shellCommand` (just `cd '<dir>'`).
    public static func terminalOnly(directory: String) -> LaunchCommand {
        LaunchCommand(executable: "", arguments: [], environment: [:], workingDirectory: directory)
    }
}
