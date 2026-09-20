// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// `~/.config/agentmenu/config.toml`, or the path named by `AGENTMENU_CONFIG`
/// when set. Not documented in `--help` — it exists so a test can point the
/// whole CLI at a `TempDir` instead of the maintainer's real config, the same
/// way this project's own test suite never touches `~/.claude` directly.
///
/// Delegates to `Overrides.forCLI()` (U7): the one place all five of the
/// CLI's env-var overrides are read, unconditionally, with no argument-domain
/// gate — the CLI has no Finder launch to protect (KTD4).
func resolvedConfigURL() -> URL {
    Overrides.forCLI().config ?? ConfigStore.defaultURL
}

let arguments = Array(CommandLine.arguments.dropFirst())
let configStore = ConfigStore(url: resolvedConfigURL())

switch arguments.first {
case "--version", "version":
    print(agentMenuVersion)
case nil, "--help", "-h", "help":
    print("""
    agentmenu \(agentMenuVersion)

    Usage:
      agentmenu resolve <dir> [--profile|--config-dir|--command]
      agentmenu install-statusline [--profile <id>] [--dry-run]
      agentmenu --version
    """)
case "resolve":
    exit(runResolve(Array(arguments.dropFirst()), configStore: configStore))
case "install-statusline":
    exit(runInstallStatusline(Array(arguments.dropFirst()), configStore: configStore))
case "statusline-bridge":
    // Hidden: this is not a command a person types, it is what the script
    // `install-statusline` writes execs on every status-line refresh.
    exit(runStatuslineBridge(Array(arguments.dropFirst())))
case "dump-state":
    // Hidden (U7): a harness cross-check, not a command a person types. See
    // DumpStateCommand.swift.
    exit(runDumpState(Array(arguments.dropFirst())))
default:
    FileHandle.standardError.write(Data("agentmenu: unknown command '\(arguments[0])'\n".utf8))
    exit(2)
}
