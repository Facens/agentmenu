// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// `~/.config/agentmenu/config.toml`, or the path named by `AGENTMENU_CONFIG`
/// when set. Not documented in `--help` — it exists so a test can point the
/// whole CLI at a `TempDir` instead of the maintainer's real config, the same
/// way the migration doc's own examples never touch `~/.claude` directly.
/// See `docs/migrating-from-cc-launcher.md`.
func resolvedConfigURL() -> URL {
    if let override = ProcessInfo.processInfo.environment["AGENTMENU_CONFIG"], !override.isEmpty {
        return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
    }
    return ConfigStore.defaultURL
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
      agentmenu import [--from <path>] [--dry-run]
      agentmenu install-statusline [--profile <id>] [--dry-run]
      agentmenu --version
    """)
case "resolve":
    exit(runResolve(Array(arguments.dropFirst()), configStore: configStore))
case "import":
    exit(runImport(Array(arguments.dropFirst()), configStore: configStore))
case "install-statusline":
    exit(runInstallStatusline(Array(arguments.dropFirst()), configStore: configStore))
case "statusline-bridge":
    // Hidden: this is not a command a person types, it is what the script
    // `install-statusline` writes execs on every status-line refresh.
    // Documented in docs/migrating-from-cc-launcher.md, not in --help.
    exit(runStatuslineBridge(Array(arguments.dropFirst())))
default:
    FileHandle.standardError.write(Data("agentmenu: unknown command '\(arguments[0])'\n".utf8))
    exit(2)
}
