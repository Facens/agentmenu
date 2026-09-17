// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// Root of the repository's `Resources/` directory. Duplicated from
/// `ManifestRegistryTests.swift` rather than shared — each test file is a
/// private, self-contained top-level scope, and this one is only used by
/// scenario 9, which specifically needs the real `claude-code.toml`, not a
/// synthetic stand-in.
private var repositoryResourcesRoot: URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // CommandBuilderTests.swift -> AgentMenuKitTests
        .deletingLastPathComponent()  // -> Tests
        .deletingLastPathComponent()  // -> repository root
        .appendingPathComponent("Resources")
}

private func loadClaudeCodeManifest() throws -> AgentManifest {
    let url = repositoryResourcesRoot.appendingPathComponent("agents/claude-code.toml")
    let text = try String(contentsOf: url, encoding: .utf8)
    return try AgentManifest.parse(text, origin: .bundled)
}

private func loadITerm2Manifest() throws -> TerminalManifest {
    let url = repositoryResourcesRoot.appendingPathComponent("terminals/iterm2.toml")
    let text = try String(contentsOf: url, encoding: .utf8)
    return try TerminalManifest.parse(text, origin: .bundled)
}

/// An agent fixture that exercises every part of `CommandBuilder.build`'s
/// argument order in one shot: a flag-mechanism profile (claude-code's own
/// profile is an environment variable, so this covers the branch it does
/// not), model, effort, permission mode, advisor, static extra args, and a
/// positional project argument.
private func shapeAgent() -> AgentManifest {
    AgentManifest(
        id: "shapecheck",
        displayName: "Shape Check",
        binary: "shapecheck",
        projectArgument: .positional,
        extraArgs: ["--extra-flag", "extra-value"],
        profileMechanism: .flag("--profile-dir"),
        model: FlagSpec(flag: "--model", values: ["opus"]),
        effort: FlagSpec(flag: "--effort", values: ["medium"]),
        permissionMode: PermissionSpec(flag: "--permission-mode", values: ["manual"]),
        advisor: AdvisorSpec(flag: "--advisor", values: ["opus"], disableArgs: ["--no-advisor"]),
        origin: .bundled
    )
}

private func resolved(_ preset: Preset) -> ResolvedPreset {
    ResolvedPreset(preset: preset, unsupported: [])
}

func runCommandBuilderTests(_ t: TestRunner) {
    t.suite("CommandBuilder")

    // Loaded once, used by scenarios 4 and 9 via `if let` rather than a
    // `guard ... else { return }` in each — a `return` there would silently
    // skip every later scenario in this function (quoting, BinaryResolver,
    // TerminalLauncher) if this one file ever moved or failed to parse,
    // reporting only the one failure that caused it.
    let claudeCodeManifest = t.attempt("load the real claude-code manifest", { try loadClaudeCodeManifest() })

    // MARK: 1. ShellQuoting.singleQuoted — the embedded-quote dance

    do {
        t.expectEqual(ShellQuoting.singleQuoted("simple"), "'simple'", "a plain value is just wrapped")
        t.expectEqual(ShellQuoting.singleQuoted("it's"), "'it'\\''s'", "an embedded quote is closed, escaped, reopened")
        t.expectEqual(ShellQuoting.singleQuoted("$HOME and `cmd`"), "'$HOME and `cmd`'", "$ and backticks need no special handling inside single quotes")
        t.expectEqual(ShellQuoting.singleQuoted(""), "''", "an empty value quotes to an empty pair")
    }

    // MARK: 2. ShellQuoting.appleScriptEscaped — backslash and double quote, character for character

    do {
        t.expectEqual(ShellQuoting.appleScriptEscaped("plain"), "plain", "nothing to escape")
        t.expectEqual(ShellQuoting.appleScriptEscaped("a\"b"), "a\\\"b", "a double quote gets one backslash ahead of it")
        t.expectEqual(ShellQuoting.appleScriptEscaped("a\\b"), "a\\\\b", "a backslash gets one backslash ahead of it")
        t.expectEqual(
            ShellQuoting.appleScriptEscaped("say \"hi\\bye\""),
            "say \\\"hi\\\\bye\\\"",
            "both characters in one string are each escaped independently, left to right"
        )
    }

    // MARK: 3. Scenario 10 — a known configuration's built command matches the documented shape exactly, including flag order

    do {
        let dir = TempDir("shape-check-dir")
        defer { dir.cleanup() }
        let folderPath = dir.path("project")
        t.expectNoThrow("create the project folder") {
            try FileManager.default.createDirectory(atPath: folderPath, withIntermediateDirectories: true)
        }

        let preset = Preset(model: "opus", effort: "medium", permissionMode: "manual", advisor: .model("opus"))
        let profile = Profile(id: "p1", name: "P1", configDirectory: "/Users/x/.shapecheck")

        let built = t.attempt("build the shape-check command") {
            try CommandBuilder.build(
                agent: shapeAgent(), resolved: resolved(preset), profile: profile,
                directory: folderPath, binaryPath: "/usr/local/bin/shapecheck"
            )
        }
        if let command = built {
            t.expectEqual(
                command.arguments,
                [
                    "--profile-dir", "/Users/x/.shapecheck",
                    "--model", "opus",
                    "--effort", "medium",
                    "--permission-mode", "manual",
                    "--advisor", "opus",
                    "--extra-flag", "extra-value",
                    folderPath,
                ],
                "profile, model, effort, permission, advisor, extra, project — in that order"
            )
            t.expectEqual(command.environment, [:], "a flag-mechanism profile never touches the environment")
            t.expectEqual(command.executable, "/usr/local/bin/shapecheck", "the resolved binary path is used verbatim")

            let expectedShell = "cd \(ShellQuoting.singleQuoted(folderPath)) && "
                + "'/usr/local/bin/shapecheck' '--profile-dir' '/Users/x/.shapecheck' "
                + "'--model' 'opus' '--effort' 'medium' '--permission-mode' 'manual' "
                + "'--advisor' 'opus' '--extra-flag' 'extra-value' \(ShellQuoting.singleQuoted(folderPath))"
            t.expectEqual(command.shellCommand, expectedShell, "the exact shell command, written literally so a change to the shape is deliberate")
        }
    }

    // MARK: 4. Profile mechanism .environment produces exactly that variable, valued as the profile's directory

    do {
        let dir = TempDir("env-profile-dir")
        defer { dir.cleanup() }
        let folderPath = dir.path("project")
        t.expectNoThrow("create the project folder") {
            try FileManager.default.createDirectory(atPath: folderPath, withIntermediateDirectories: true)
        }

        if let claudeCode = claudeCodeManifest {
            let profile = Profile(id: "work", name: "Work", configDirectory: "~/.claude-work")

            let built = t.attempt("build with an environment-mechanism profile") {
                try CommandBuilder.build(
                    agent: claudeCode, resolved: resolved(Preset()), profile: profile,
                    directory: folderPath, binaryPath: "/usr/local/bin/claude"
                )
            }
            if let command = built {
                t.expectEqual(
                    command.environment, ["CLAUDE_CONFIG_DIR": profile.expandedConfigDirectory.path],
                    "exactly the declared variable, valued as the profile's expanded directory — nothing else in the environment"
                )
                t.expectEqual(command.arguments, [], "no preset values set, no extra args, no positional project — no arguments at all")
            }
        }
    }

    // MARK: 5. profile_flag mechanism with no profile given throws profileRequired

    do {
        let dir = TempDir("profile-required-dir")
        defer { dir.cleanup() }
        t.expectThrows("a manifest declaring a profile mechanism with no Profile supplied throws profileRequired") {
            try CommandBuilder.build(
                agent: shapeAgent(), resolved: resolved(Preset()), profile: nil,
                directory: dir.url.path, binaryPath: "/usr/local/bin/shapecheck"
            )
        }
        do {
            _ = try CommandBuilder.build(
                agent: shapeAgent(), resolved: resolved(Preset()), profile: nil,
                directory: dir.url.path, binaryPath: "/usr/local/bin/shapecheck"
            )
            t.expect(false, "should have thrown")
        } catch CommandBuilderError.profileRequired(let agent) {
            t.expectEqual(agent, "shapecheck", "the error names the agent")
        } catch {
            t.expect(false, "wrong error type for a missing profile: \(error)")
        }
    }

    // MARK: 6. A missing folder is reported, not swallowed (R6)

    do {
        do {
            _ = try CommandBuilder.build(
                agent: shapeAgent(), resolved: resolved(Preset()), profile: Profile(id: "p", name: "P", configDirectory: "/tmp/x"),
                directory: "/definitely/not/a/real/path/agentmenu-test", binaryPath: "/usr/local/bin/shapecheck"
            )
            t.expect(false, "a nonexistent directory should throw")
        } catch CommandBuilderError.directoryMissing(let path) {
            t.expectEqual(path, "/definitely/not/a/real/path/agentmenu-test", "the error names the missing folder")
        } catch {
            t.expect(false, "wrong error type for a missing directory: \(error)")
        }
    }

    // MARK: 7. An unresolved binary (empty path) is reported, not swallowed

    do {
        let dir = TempDir("no-binary-dir")
        defer { dir.cleanup() }
        do {
            _ = try CommandBuilder.build(
                agent: shapeAgent(), resolved: resolved(Preset()), profile: Profile(id: "p", name: "P", configDirectory: "/tmp/x"),
                directory: dir.url.path, binaryPath: ""
            )
            t.expect(false, "an empty binary path should throw")
        } catch CommandBuilderError.binaryNotResolved(let binary) {
            t.expectEqual(binary, "shapecheck", "the error names the agent's binary")
        } catch {
            t.expect(false, "wrong error type for an unresolved binary: \(error)")
        }
    }

    // MARK: 8. terminalOnly — a plain shell in the folder, no executable, no agent started (R5)

    do {
        let command = CommandBuilder.terminalOnly(directory: "/Users/x/My Project")
        t.expectEqual(command.executable, "", "no executable — nothing is launched")
        t.expectEqual(command.arguments, [], "no arguments")
        t.expectEqual(command.environment, [:], "no environment")
        t.expectEqual(command.shellCommand, "cd '/Users/x/My Project'", "just a cd, no trailing &&")
    }

    // MARK: 9. Advisor: enabled emits the flag; off emits the manifest's disable_args exactly as declared (scenario 9)

    do {
        let dir = TempDir("advisor-dir")
        defer { dir.cleanup() }
        let folderPath = dir.path("project")
        t.expectNoThrow("create the project folder") {
            try FileManager.default.createDirectory(atPath: folderPath, withIntermediateDirectories: true)
        }

        if let claudeCode = claudeCodeManifest {
            let profile = Profile(id: "work", name: "Work", configDirectory: "/Users/x/.claude-work")

            let enabledBuilt = t.attempt("build with advisor enabled") {
                try CommandBuilder.build(
                    agent: claudeCode, resolved: resolved(Preset(advisor: .model("opus"))), profile: profile,
                    directory: folderPath, binaryPath: "/usr/local/bin/claude"
                )
            }
            if let enabled = enabledBuilt {
                t.expectEqual(enabled.arguments, ["--advisor", "opus"], "the advisor flag and model")
            }

            let disabledBuilt = t.attempt("build with advisor off") {
                try CommandBuilder.build(
                    agent: claudeCode, resolved: resolved(Preset(advisor: .off)), profile: profile,
                    directory: folderPath, binaryPath: "/usr/local/bin/claude"
                )
            }
            if let disabled = disabledBuilt {
                t.expectEqual(
                    disabled.arguments, ["--settings", "{\"advisorModel\":\"\"}"],
                    "claude-code.toml's disable_args, emitted verbatim"
                )
            }
        }
    }

    // MARK: 10. Scenario 5 — a folder with spaces, an apostrophe and a $ produces a correct argv vector and shellCommand

    do {
        let dir = TempDir("weird-folder")
        defer { dir.cleanup() }
        let weirdName = "My Project's $tuff"
        let folderPath = dir.path(weirdName)
        t.expectNoThrow("create the folder with spaces, an apostrophe and a $") {
            try FileManager.default.createDirectory(atPath: folderPath, withIntermediateDirectories: true)
        }

        let built = t.attempt("build against the weird folder") {
            try CommandBuilder.build(
                agent: shapeAgent(), resolved: resolved(Preset()), profile: Profile(id: "p", name: "P", configDirectory: "/tmp/x"),
                directory: folderPath, binaryPath: "/usr/local/bin/shapecheck"
            )
        }
        if let command = built {
            t.expectEqual(command.workingDirectory, folderPath, "the raw path lands unmangled in workingDirectory")
            t.expectEqual(command.arguments.last, folderPath, "the raw, unquoted path is the positional project argument in argv")

            let expectedQuoted = "'" + folderPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
            t.expect(command.shellCommand.hasPrefix("cd \(expectedQuoted) && "), "the folder is correctly single-quoted at the start of shellCommand: \(command.shellCommand)")
            t.expect(command.shellCommand.hasSuffix(expectedQuoted), "the folder is correctly single-quoted again as the trailing positional argument: \(command.shellCommand)")
        }
    }

    // MARK: 11. Scenario 6 — a folder with a double quote and a backslash: correct argv, and an AppleScript literal asserted character for character

    do {
        let dir = TempDir("quote-backslash-folder")
        defer { dir.cleanup() }
        let weirdName = "Weird \"Quoted\" \\Name"
        let folderPath = dir.path(weirdName)
        t.expectNoThrow("create the folder with a double quote and a backslash") {
            try FileManager.default.createDirectory(atPath: folderPath, withIntermediateDirectories: true)
        }

        let built = t.attempt("build against the double-quote/backslash folder") {
            try CommandBuilder.build(
                agent: shapeAgent(), resolved: resolved(Preset()), profile: Profile(id: "p", name: "P", configDirectory: "/tmp/x"),
                directory: folderPath, binaryPath: "/usr/local/bin/shapecheck"
            )
        }
        if let command = built {
            t.expectEqual(command.arguments.last, folderPath, "the raw path, quote and backslash intact, is the positional argument")

            // Shell single-quoting alone does nothing about " or \ — they pass
            // through a single-quoted shell token unescaped. It is
            // appleScriptLiteral, the second layer, that must escape them so
            // the AppleScript string literal terminates in the right place.
            let shell = command.shellCommand
            t.expect(shell.contains(folderPath), "shell quoting leaves \" and \\ untouched inside the single-quoted token")

            // The folder-name suffix, written out character for character
            // (not recomputed): `Weird "Quoted" \Name` sits inside the
            // larger single-quoted path token, with its `"` and `\` each
            // escaped for the AppleScript string literal that will carry it.
            // (The single quotes wrap the *whole* path, from the TempDir
            // prefix onward, not just this suffix — appleScriptEscaped
            // leaves `'` alone, so only the interior is asserted literally.)
            t.expect(
                command.appleScriptLiteral.contains("Weird \\\"Quoted\\\" \\\\Name"),
                "the escaped folder-name suffix appears literally in appleScriptLiteral: \(command.appleScriptLiteral)"
            )

            let expectedLiteral = shell
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            t.expectEqual(
                command.appleScriptLiteral, expectedLiteral,
                "appleScriptLiteral escapes exactly the backslash and double-quote characters, character for character"
            )
            // The order those replacements must be applied in (backslash
            // before quote) is exactly what ShellQuoting.appleScriptEscaped's
            // single left-to-right pass guarantees and a naive two-pass
            // `replacingOccurrences` on the *output* would get wrong if
            // applied quote-then-backslash — spelled out so a future change
            // to the escaping order is caught here, not just eyeballed.
            t.expect(!command.appleScriptLiteral.contains("\\\\\\\""), "no run produced by double-escaping a quote that was already escaped")
        }
    }

    t.suite("BinaryResolver")

    // MARK: 12. lookupArguments — the exact argv this resolver would run
    //
    // Pins the positional-parameter shape (`$1`, never the binary spliced
    // into script text) that closes the shell-injection hole: the earlier
    // shape was `["-ilc", "whence -p \(binary)"]`, which turned
    // `lookupArguments(for: "claude; touch /tmp/pwned")` into a script that
    // ran the injected command. This assertion previously pinned that
    // vulnerable shape and has been updated, not weakened — the old
    // assertion was itself the bug.

    do {
        t.expectEqual(
            BinaryResolver.lookupArguments(for: "claude"),
            ["-ilc", "whence -p -- \"$1\"", "zsh", "claude"],
            "the binary name is $1, never spliced into the script text"
        )
        t.expectEqual(
            BinaryResolver.lookupArguments(for: "claude; touch /tmp/AGENTMENU_PWNED"),
            ["-ilc", "whence -p -- \"$1\"", "zsh", "claude; touch /tmp/AGENTMENU_PWNED"],
            "an injection attempt lands whole inside $1's value, not appended to the script"
        )
    }

    // MARK: 13. A valid cached path is used without shelling out — proved with a shell path that would fail if actually invoked

    do {
        let dir = TempDir("binary-cached")
        defer { dir.cleanup() }
        let executablePath = dir.path("fixture-binary")
        t.expectNoThrow("write a fake executable") {
            try "#!/bin/sh\necho should-not-run\n".write(toFile: executablePath, atomically: true, encoding: .utf8)
        }
        t.expectNoThrow("make it executable") {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executablePath)
        }

        // A shell path that does not exist: if resolve() ever fell through to
        // shelling out, Process.run() would fail to launch it and lookup
        // would return nil, and resolve() would throw .notFound instead of
        // returning the cached path — so a non-throwing result that equals
        // the cached path is proof the shell was never invoked.
        let resolver = BinaryResolver(shell: "/nonexistent/definitely-not-a-shell-xyz")
        let resolvedPath = t.attempt("resolve with a valid cached path and a shell that would fail if invoked") {
            try resolver.resolve("fixture-binary", cached: executablePath)
        }
        if let path = resolvedPath {
            t.expectEqual(path, executablePath, "the cached path is returned as-is")
        }
    }

    // MARK: 14. A missing cached path triggers exactly one re-resolution via the shell

    do {
        let dir = TempDir("binary-stub-shell")
        defer { dir.cleanup() }
        let stubShellPath = dir.path("stub-zsh")
        t.expectNoThrow("write a stub shell that echoes a resolved path, ignoring its arguments") {
            try "#!/bin/sh\necho '/usr/local/bin/stub-resolved'\n".write(toFile: stubShellPath, atomically: true, encoding: .utf8)
        }
        t.expectNoThrow("make the stub shell executable") {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubShellPath)
        }

        let resolver = BinaryResolver(shell: stubShellPath)
        let firstResolved = t.attempt("resolve with no cached path, via the stub shell") {
            try resolver.resolve("whatever", cached: nil)
        }
        if let path = firstResolved {
            t.expectEqual(path, "/usr/local/bin/stub-resolved", "the stub shell's output is parsed and returned")
        }

        // A cached path that no longer exists on disk behaves the same as nil.
        let secondResolved = t.attempt("resolve with a stale cached path, via the stub shell") {
            try resolver.resolve("whatever", cached: dir.path("no-such-file"))
        }
        if let path = secondResolved {
            t.expectEqual(path, "/usr/local/bin/stub-resolved", "a stale cache also falls through to the shell")
        }
    }

    // MARK: 15. AE5 — a second failure (the shell cannot resolve it either) reports the binary name

    do {
        let dir = TempDir("binary-stub-shell-fail")
        defer { dir.cleanup() }
        let stubShellPath = dir.path("stub-zsh-fail")
        t.expectNoThrow("write a stub shell that fails, like whence -p finding nothing") {
            try "#!/bin/sh\nexit 1\n".write(toFile: stubShellPath, atomically: true, encoding: .utf8)
        }
        t.expectNoThrow("make the stub shell executable") {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stubShellPath)
        }

        let resolver = BinaryResolver(shell: stubShellPath)
        do {
            _ = try resolver.resolve("ghost-binary", cached: nil)
            t.expect(false, "a shell that cannot resolve the binary should throw")
        } catch BinaryResolver.Failure.notFound(let binary) {
            t.expectEqual(binary, "ghost-binary", "the failure names the binary that could not be resolved")
        } catch {
            t.expect(false, "wrong error type: \(error)")
        }
    }

    t.suite("TerminalLauncher")

    // MARK: 16. Scenario 11 — an AppleScript terminal carries the command as an argv argument, not interpolated into script text

    do {
        // The real shipped manifest, not a stub — this pins that iterm2.toml's
        // actual script text flows through `open` unchanged into argv.
        let iterm2 = t.attempt("load the real iterm2 manifest", { try loadITerm2Manifest() })
        if let terminal = iterm2 {
            var captured: (executable: String, arguments: [String])?
            let launcher = TerminalLauncher { executable, arguments, _ in
                captured = (executable, arguments)
            }
            let command = LaunchCommand(
                executable: "/usr/local/bin/claude", arguments: ["--model", "opus"],
                environment: [:], workingDirectory: "/Users/x/My Project"
            )

            t.expectNoThrow("open an applescript terminal") { try launcher.open(command: command, terminal: terminal, binaryPath: nil) }

            if let captured {
                t.expectEqual(captured.executable, "/usr/bin/osascript", "osascript is invoked directly")
                t.expectEqual(
                    captured.arguments,
                    ["-e", terminal.appleScript ?? "", command.shellCommand, command.workingDirectory],
                    "iterm2.toml's own script text, the shell-quoted command as argv item 1, and the raw directory as argv item 2"
                )
            } else {
                t.expect(false, "the runner was never called")
            }
        }
    }

    // MARK: 17. An argv terminal substitutes {dir}/{command} and spawns the terminal's own resolved binary

    do {
        var captured: (executable: String, arguments: [String])?
        let launcher = TerminalLauncher { executable, arguments, _ in
            captured = (executable, arguments)
        }
        let terminal = TerminalManifest(
            id: "ghostty", displayName: "Ghostty", kind: .argv,
            binary: "ghostty", args: ["--working-directory={dir}", "-e", "{command}"], origin: .bundled
        )
        let command = LaunchCommand(
            executable: "/usr/local/bin/claude", arguments: ["--model", "opus"],
            environment: [:], workingDirectory: "/Users/x/Project"
        )

        t.expectNoThrow("open an argv terminal") {
            try launcher.open(command: command, terminal: terminal, binaryPath: "/opt/homebrew/bin/ghostty")
        }

        if let captured {
            t.expectEqual(captured.executable, "/opt/homebrew/bin/ghostty", "the terminal's own resolved binary path is spawned")
            t.expectEqual(
                captured.arguments,
                ["--working-directory=/Users/x/Project", "-e", command.shellCommand],
                "{dir} substitutes the raw directory, {command} substitutes the shell-quoted command"
            )
        } else {
            t.expect(false, "the runner was never called")
        }
    }

    // MARK: 18. An argv terminal with no resolved binary throws rather than spawning nothing silently

    do {
        let launcher = TerminalLauncher { _, _, _ in t.expect(false, "the runner should never be called") }
        let terminal = TerminalManifest(id: "ghostty", displayName: "Ghostty", kind: .argv, binary: "ghostty", args: ["{command}"], origin: .bundled)
        let command = LaunchCommand(executable: "/bin/claude", arguments: [], environment: [:], workingDirectory: "/tmp")

        t.expectThrows("an argv terminal with a nil binaryPath throws instead of silently doing nothing") {
            try launcher.open(command: command, terminal: terminal, binaryPath: nil)
        }
    }

    // MARK: 19. An argv terminal's {dir}/{command} substitution is a single
    // pass: a directory whose own path contains the literal text "{command}"
    // is not itself re-substituted by the second placeholder.
    //
    // Two chained `replacingOccurrences` calls (the old shape) run the
    // {command} replacement over the *output* of the {dir} replacement, so
    // once {dir} lands a value containing "{command}", the second pass
    // corrupts it. A single left-to-right scan never re-enters a value it
    // just emitted.

    do {
        var captured: (executable: String, arguments: [String])?
        let launcher = TerminalLauncher { executable, arguments, _ in
            captured = (executable, arguments)
        }
        let terminal = TerminalManifest(
            id: "ghostty", displayName: "Ghostty", kind: .argv,
            binary: "ghostty", args: ["--working-directory={dir}", "-e", "{command}"], origin: .bundled
        )
        let trickyDirectory = "/Users/x/{command} Folder"
        let command = LaunchCommand(
            executable: "/usr/local/bin/claude", arguments: ["--model", "opus"],
            environment: [:], workingDirectory: trickyDirectory
        )

        t.expectNoThrow("open an argv terminal whose directory contains another placeholder's literal text") {
            try launcher.open(command: command, terminal: terminal, binaryPath: "/opt/homebrew/bin/ghostty")
        }

        if let captured {
            t.expectEqual(
                captured.arguments,
                ["--working-directory=/Users/x/{command} Folder", "-e", command.shellCommand],
                "the directory's own literal \"{command}\" text survives untouched; only the standalone {command} argument is substituted"
            )
        } else {
            t.expect(false, "the runner was never called")
        }
    }

    // MARK: 20. AppleScript placeholder substitution: all four documented
    // placeholders ({dir}, {command}, {dir_applescript}, {command_applescript})
    // are live inside a script's own text, in addition to (not instead of)
    // passing the command/dir as argv items 1/2. Before this fix, a script
    // that inlined the command rather than reading `on run argv` got the
    // four literal placeholder strings passed straight to osascript,
    // unsubstituted — `LaunchCommand.appleScriptLiteral` and
    // `ShellQuoting.appleScriptEscaped` were unreachable from production code.

    do {
        var captured: (executable: String, arguments: [String])?
        let launcher = TerminalLauncher { executable, arguments, _ in
            captured = (executable, arguments)
        }
        let scriptTemplate = """
        tell application "Example"
          do script "{command_applescript}" at folder "{dir_applescript}"
          -- raw dir: {dir}
          -- raw command: {command}
        end tell
        """
        let terminal = TerminalManifest(
            id: "example", displayName: "Example", kind: .applescript,
            bundleID: "com.example.terminal", appleScript: scriptTemplate, origin: .bundled
        )
        // A directory with both a double quote and a backslash — the two
        // characters ShellQuoting.appleScriptEscaped exists to handle, and
        // neither of which single-quote shell-escaping does anything about.
        let trickyDirectory = "/Users/x/Say \"Hi\"\\Folder"
        let command = LaunchCommand(
            executable: "/usr/local/bin/claude", arguments: ["--model", "opus"],
            environment: [:], workingDirectory: trickyDirectory
        )

        t.expectNoThrow("open an applescript terminal whose script inlines all four placeholders") {
            try launcher.open(command: command, terminal: terminal, binaryPath: nil)
        }

        if let captured {
            t.expectEqual(captured.executable, "/usr/bin/osascript", "osascript is invoked directly")
            let expectedScript = scriptTemplate
                .replacingOccurrences(of: "{command_applescript}", with: command.appleScriptLiteral)
                .replacingOccurrences(of: "{dir_applescript}", with: ShellQuoting.appleScriptEscaped(command.workingDirectory))
                .replacingOccurrences(of: "{dir}", with: command.workingDirectory)
                .replacingOccurrences(of: "{command}", with: command.shellCommand)
            t.expectEqual(captured.arguments[1], expectedScript, "all four placeholders are substituted into the script body")
            t.expectEqual(
                captured.arguments,
                ["-e", expectedScript, command.shellCommand, command.workingDirectory],
                "the command and directory are still passed as argv items 1/2 too, for an on run argv script"
            )
            t.expect(!captured.arguments[1].contains("{dir_applescript}"), "no literal placeholder text survives in the script")
            t.expect(!captured.arguments[1].contains("{command_applescript}"), "no literal placeholder text survives in the script")
        } else {
            t.expect(false, "the runner was never called")
        }
    }

    // MARK: 21. systemRunner() waits for the process and throws
    // TerminalLauncherError.terminalFailed, with the process's stderr, when
    // it exits non-zero within the wait cap. Before this fix, `Process.run()`
    // not waiting meant osascript exiting non-zero (iTerm not installed, a
    // script error, the terminal refusing the Apple Event) reached the
    // popover as silent success (R6).

    do {
        let runner = TerminalLauncher.systemRunner(exitTimeout: 2.0, detachTimeout: 2.0)
        do {
            try runner("/bin/sh", ["-c", "echo the-terminal-refused >&2; exit 7"], true)
            t.expect(false, "a process that exits non-zero within the wait cap should throw")
        } catch TerminalLauncherError.terminalFailed(let exitCode, let stderrOutput) {
            t.expectEqual(exitCode, 7, "the exit code is carried")
            t.expectEqual(stderrOutput, "the-terminal-refused", "the process's stderr is captured and trimmed")
        } catch {
            t.expect(false, "wrong error type: \(error)")
        }

        t.expectNoThrow("a process that exits 0 within the wait cap does not throw") {
            try runner("/bin/sh", ["-c", "exit 0"], true)
        }
    }

    // MARK: 22. systemRunner() treats a process still running past the wait
    // cap as success rather than blocking indefinitely — for the shape where
    // that is the ordinary case: an `argv` terminal, whose own process stays
    // up for as long as the window does. Waiting for it to exit would mean
    // waiting for the user to close the window.
    //
    // "Doesn't throw" alone would also be true of the pre-fix systemRunner
    // (it never waited at all, so it never threw for any process). What
    // distinguishes "waits, but only up to the cap" from "never waits" is
    // *how long the call takes*: the old shape returns near-instantly no
    // matter how long the child runs; this one genuinely blocks until the
    // semaphore times out. Measuring elapsed time against the cap is what
    // makes this a real regression check rather than one that would also
    // pass against the old code.

    do {
        let waitTimeout: TimeInterval = 0.2
        let runner = TerminalLauncher.systemRunner(exitTimeout: 30.0, detachTimeout: waitTimeout)
        let start = Date()
        t.expectNoThrow("a detaching process still running past a short wait cap is treated as success, not left blocking") {
            try runner("/bin/sh", ["-c", "sleep 3"], false)
        }
        let elapsed = Date().timeIntervalSince(start)
        t.expect(elapsed >= waitTimeout * 0.5, "the call actually waited close to the cap (\(elapsed)s), proving this isn't the old no-wait shape")
        t.expect(elapsed < 2.0, "the call returned well before the child's own 3s sleep — the cap bounds the wait, it does not block for the full child lifetime")
    }

    // MARK: 23. A process whose exit status IS the answer — osascript, the
    // AppleScript kind — is not declared successful just because it is still
    // running at the cap. The thing that most often keeps osascript running
    // is macOS holding it while it asks the user whether this app may control
    // the terminal at all; reporting that as success is how a permission
    // prompt became a launch that claimed to work and did nothing.

    do {
        let runner = TerminalLauncher.systemRunner(exitTimeout: 0.3, detachTimeout: 30.0)
        do {
            try runner("/bin/sh", ["-c", "sleep 5"], true)
            t.expect(false, "a process that had to exit and did not should throw, not report success")
        } catch TerminalLauncherError.terminalDidNotAnswer {
            t.expect(true, "an unanswered launch is reported rather than swallowed")
        } catch {
            t.expect(false, "wrong error type: \(error)")
        }
    }

    // MARK: 24. An Apple Event refused by macOS is told apart from any other
    // script failure, because the fix for it is a checkbox in System Settings
    // and nothing the user changes inside AgentMenu will help.

    do {
        let runner = TerminalLauncher.systemRunner(exitTimeout: 2.0, detachTimeout: 2.0)
        do {
            try runner("/bin/sh", ["-c", "echo 'execution error: Not authorized to send Apple events to iTerm. (-1743)' >&2; exit 1"], true)
            t.expect(false, "a refused Apple Event should throw")
        } catch TerminalLauncherError.automationDenied {
            t.expect(true, "the refusal is reported as a permission problem")
        } catch {
            t.expect(false, "wrong error type: \(error)")
        }

        t.expect(
            TerminalLauncherError.automationDenied(detail: "").description.contains("Privacy & Security"),
            "the message names where the permission lives"
        )
    }
}
