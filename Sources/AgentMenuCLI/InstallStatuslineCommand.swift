// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// `agentmenu install-statusline [--profile <id>] [--dry-run]` (R26, R47):
/// the only command in the whole project that writes into an agent's
/// configuration directory, and only when the user runs it. Writes the
/// bridge script and one key of `settings.json` — `statusLine` — chaining to
/// whatever status-line command was already configured rather than
/// replacing it.
func runInstallStatusline(_ args: [String], configStore: ConfigStore) -> Int32 {
    var profileID: String?
    var dryRun = false

    var index = 0
    while index < args.count {
        switch args[index] {
        case "--profile":
            index += 1
            guard index < args.count else {
                fail("agentmenu install-statusline: --profile requires an id")
                return 2
            }
            profileID = args[index]
        case "--dry-run":
            dryRun = true
        default:
            fail("agentmenu install-statusline: unknown argument '\(args[index])'")
            return 2
        }
        index += 1
    }

    let config: Config
    do {
        config = (try configStore.load()) ?? Config()
    } catch {
        fail("agentmenu install-statusline: \(error)")
        return 2
    }

    let resolvedProfileID = profileID ?? config.activeProfileID ?? config.profiles.first?.id
    guard let resolvedProfileID, let profile = config.profile(id: resolvedProfileID) else {
        fail("agentmenu install-statusline: no profile '\(profileID ?? "(none configured)")' — run 'agentmenu import' or add one in Settings first")
        return 1
    }

    let manifest = claudeCodeManifest()
    let profileDirectory = profile.expandedConfigDirectory
    let settingsURL = manifest?.settingsFileURL(profileDirectory: profileDirectory)
        ?? URL(fileURLWithPath: StatuslineBridge.claudeCodeSettingsFileTemplate.replacingOccurrences(
            of: "{profile_dir}", with: profileDirectory.path
        ))
    let scriptURL = profileDirectory.appendingPathComponent(StatuslineBridge.scriptFilename)

    // R47: name the file and the key before writing anything.
    print("settings file: \(settingsURL.path)")
    print("key: statusLine.command")

    let originalText: String
    if let existing = try? String(contentsOf: settingsURL, encoding: .utf8) {
        originalText = existing
    } else {
        originalText = "{}\n"
    }

    // The chain lives inside whichever bridge script settings.json actually
    // names, which is not always this profile's own: one profile's settings
    // can point at another's script (the script resolves its profile from
    // CLAUDE_CONFIG_DIR at run time, so it works), and reading this
    // profile's path would then find nothing and refuse a recoverable
    // install.
    let existingCommand = currentStatusLineCommand(settingsText: originalText)
    let existingScriptPath = existingCommand
        .flatMap(StatuslineBridge.bridgeScriptPath(inCommand:)) ?? scriptURL.path
    let existingScriptContents = try? String(
        contentsOf: URL(fileURLWithPath: existingScriptPath), encoding: .utf8
    )
    if existingScriptPath != scriptURL.path, existingScriptContents != nil {
        print("statusLine currently runs another profile's bridge (\(existingScriptPath)) — taking its chain and installing this profile's own")
    }

    let update: StatuslineBridge.SettingsUpdate
    do {
        update = try StatuslineBridge.settingsUpdate(
            original: originalText,
            scriptPath: scriptURL.path,
            existingBridgeScriptContents: existingScriptContents
        )
    } catch {
        fail("agentmenu install-statusline: \(error)")
        return 1
    }

    if update.alreadyInstalled {
        print("statusLine already runs the agentmenu bridge — leaving its chain as-is")
    } else if update.chain.isEmpty {
        print("no status line was configured — the bridge will run with nothing to chain to")
    } else {
        print("chaining to the existing status line: \(update.chain)")
    }

    if dryRun {
        print("(dry run — nothing written)")
        return 0
    }

    // `RunningExecutable` resolves the actual running binary rather than
    // trusting `argv[0]` — which, installed the documented way (the
    // Homebrew cask puts `agentmenu` on `PATH`), is the bare name
    // `agentmenu`, resolved against the *cwd at install time* rather than
    // the binary's real location. Baking that into the bridge script made
    // every PATH install exec a path that doesn't exist (finding #2), while
    // `settings.json` had already been repointed at it — a broken status
    // line reported as a successful install. Refuse rather than write a
    // script that cannot exec.
    let cliPath = RunningExecutable.path
    guard FileManager.default.isExecutableFile(atPath: cliPath) else {
        fail("agentmenu install-statusline: could not resolve the running agentmenu binary to an executable file (resolved to '\(cliPath)') — refusing to install a bridge script that would exec a path that doesn't exist")
        return 1
    }
    let scriptContents = StatuslineBridge.bridgeScript(
        cliPath: cliPath, profileDirectory: profileDirectory.path, chain: update.chain
    )

    do {
        guard let scriptData = scriptContents.data(using: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try StatuslineBridge.atomicWrite(scriptData, to: scriptURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        guard let settingsData = update.text.data(using: .utf8) else {
            throw CocoaError(.fileWriteUnknown)
        }
        try StatuslineBridge.atomicWrite(settingsData, to: settingsURL)
    } catch {
        fail("agentmenu install-statusline: \(error)")
        return 1
    }

    print("wrote \(scriptURL.path)")
    print("updated statusLine.command in \(settingsURL.path)")
    return 0
}

/// The `statusLine.command` a settings file currently holds, or nil when it
/// has none (or the file is not an object this can read — `settingsUpdate`
/// reports that properly a moment later, so this just declines to guess).
private func currentStatusLineCommand(settingsText: String) -> String? {
    guard let data = settingsText.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let statusLine = root["statusLine"] as? [String: Any] else { return nil }
    return statusLine["command"] as? String
}

/// Claude Code's own `settings_file` location, read through the bundled
/// manifest via `AgentManifest.settingsFileURL(profileDirectory:)` when it
/// can be found — the same expansion the app's first-run flow already uses
/// — so a future change to that manifest is picked up automatically. Falls
/// back to the raw template mirroring it (there is no manifest to ask) when
/// the manifest cannot be found, or declares `settings_file` without also
/// declaring `usage_snapshot` — matching the all-or-nothing guard this
/// replaced, so a manifest missing one of the pair doesn't silently take the
/// other's live value while the rest of the bridge keeps assuming both
/// constants march together.
private func claudeCodeManifest() -> AgentManifest? {
    let registry = ManifestRegistry(bundledRoot: ResourceRoot.bundled(), userRoot: nil)
    registry.load()
    guard let agent = registry.agent(id: "claude-code"),
          agent.settingsFile != nil, agent.usageSnapshot != nil else { return nil }
    return agent
}
