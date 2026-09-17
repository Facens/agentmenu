// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// `agentmenu resolve <dir> [--profile|--config-dir|--command]` (R30): the
/// one source of truth the shell asks instead of keeping its own copy of the
/// folder->account mapping. Exit codes: `2` is a usage error (bad flags,
/// missing argument); `1` means "nothing to print" — the directory is not
/// configured, or what it names cannot be resolved — so a shell function can
/// fall back to its own default without misreading a real answer; `0` is
/// success, with the answer on stdout and nothing else there.
func runResolve(_ args: [String], configStore: ConfigStore) -> Int32 {
    enum Mode { case profile, configDir, command }

    var mode: Mode = .profile
    var directory: String?
    for arg in args {
        switch arg {
        case "--profile": mode = .profile
        case "--config-dir": mode = .configDir
        case "--command": mode = .command
        default:
            guard directory == nil, !arg.hasPrefix("--") else {
                fail("agentmenu resolve: unknown argument '\(arg)'")
                return 2
            }
            directory = arg
        }
    }
    guard let directory else {
        fail("agentmenu resolve: usage: agentmenu resolve <dir> [--profile|--config-dir|--command]")
        return 2
    }

    let config: Config
    do {
        config = (try configStore.load()) ?? Config()
    } catch {
        fail("agentmenu resolve: \(error)")
        return 2
    }

    guard let folder = config.folder(forPath: directory) else {
        return 1
    }

    // The folder's own profile wins, then the global default's (KTD6's
    // preset merge — `config.defaults.profile` is part of that chain even
    // though nothing in the app reads it yet). Deliberately NOT falling
    // through to `config.activeProfileID` here: an unpinned folder is
    // exactly the case `claude-id` itself defers past folders.conf to its
    // own map/default layers (`FoldersConfImport` leaves such a folder's
    // profile nil on purpose, see its doc comment) — answering with
    // whichever profile the popover happens to have active right now would
    // reintroduce, from this resolver, the silent wrong-account failure
    // mode `docs/migrating-from-cc-launcher.md` warns the migration itself
    // can cause.
    let pinnedProfileID = folder.preset.profile ?? config.defaults.profile

    switch mode {
    case .profile:
        guard let pinnedProfileID else { return 1 }
        print(pinnedProfileID)
        return 0

    case .configDir:
        guard let pinnedProfileID, let profile = config.profile(id: pinnedProfileID) else { return 1 }
        print(profile.expandedConfigDirectory.path)
        return 0

    case .command:
        // Unlike --profile/--config-dir, this mode's contract is "what the
        // popover would launch" — so it must match `PopoverModel
        // .profileID(for:)` exactly, not reuse `pinnedProfileID` above.
        // `profileID(for:)` is `target.profileID ?? activeProfileID`, and
        // `LaunchTarget.profileID` for a folder is the folder's *own* raw
        // pin (`folder.preset.profile`) — the app never folds
        // `config.defaults.profile` into which profile launches, only into
        // which model/effort/etc. do (`PresetResolver`'s merge is a
        // separate thing from profile selection). Routing this mode through
        // `pinnedProfileID` would silently disagree with the popover
        // whenever a folder has no pin of its own but the global default
        // does — the exact divergence the "launch parity" contract this
        // mode claims must not have.
        //
        // `activeProfileID` itself needs one more fallback to stay in sync:
        // a freshly-launched popover that has never had a profile switched
        // seeds its in-memory `activeProfileID` from
        // `environment.config.activeProfileID ?? environment.config.profiles.first?.id`
        // (`PopoverModel.init`) and only persists a switch back to
        // `config.activeProfileID` when one actually happens
        // (`PopoverModel.setActiveProfile`, R43). Reading `config.toml`
        // fresh and applying that same two-step fallback reproduces exactly
        // what that popover session would compute from the same file.
        let launchProfileID = folder.preset.profile ?? config.activeProfileID ?? config.profiles.first?.id
        return resolveCommand(folder: folder, config: config, profileID: launchProfileID)
    }
}

/// The `--command` branch: builds the exact `LaunchCommand` the popover
/// would use for this folder, through `PresetResolver`/`CommandBuilder` —
/// never assembled by hand, so `resolve --command` and the popover's own
/// launch can never drift apart (the plan's "launch parity" gate compares
/// this string against what the popover launches).
private func resolveCommand(folder: FolderTarget, config: Config, profileID: String?) -> Int32 {
    let registry = ManifestRegistry(
        bundledRoot: ResourceRoot.bundled(),
        userRoot: resolvedManifestUserRoot()
    )
    registry.load()

    let mergedForAgent = config.defaults.overlaid(with: folder.preset)
    let agentID = mergedForAgent.agent
    let agent = agentID.flatMap { registry.agent(id: $0) } ?? registry.agents.first { $0.enabled && !$0.unverified }
    guard let agent else {
        fail("agentmenu resolve: no agent is configured or available")
        return 1
    }

    let resolved = PresetResolver.resolve(global: config.defaults, folder: folder.preset, oneShot: Preset(), agent: agent)
    let profile = profileID.flatMap { config.profile(id: $0) }

    do {
        let binaryPath = try BinaryResolver().resolve(agent.binary, cached: config.binaries[agent.binary])

        // R44/R6-of-this-review: a manifest is an executable specification —
        // it names a binary, an environment variable, and static arguments —
        // so a user overlay in `~/.config/agentmenu/agents/` that shadows a
        // bundled id (KTD3: same id, last-loaded wins) must not be used
        // until the user has confirmed it in Settings, same as the app.
        // Without this gate, `resolve --command` printed — and every caller
        // of it then ran — an unverified manifest's command the moment its
        // binary happened to resolve, with no trust check at all.
        // `binaryPath` must be resolved first: `availability` reports
        // `.binaryMissing` for a nil path unconditionally, so calling it
        // before resolution could never answer `.available` even for a
        // perfectly trusted agent.
        let availability = registry.availability(of: agent, config: config, binaryPath: binaryPath)
        guard availability == .available else {
            fail("agentmenu resolve: agent '\(agent.id)' is not available (\(describeUnavailable(availability)))")
            return 1
        }

        let command = try CommandBuilder.build(
            agent: agent,
            resolved: resolved,
            profile: profile,
            directory: folder.expandedPath.path,
            binaryPath: binaryPath
        )
        print(command.shellCommand)
        return 0
    } catch {
        fail("agentmenu resolve: \(error)")
        return 1
    }
}

/// `~/.config/agentmenu`, or the directory named by
/// `AGENTMENU_MANIFESTS_USER_ROOT` when set — the same testability escape
/// hatch `AGENTMENU_CONFIG` (main.swift) is for config.toml, so a test can
/// point `resolve --command` at a scratch overlay directory instead of the
/// maintainer's real `~/.config/agentmenu/agents/`. Not documented in
/// `--help`, matching `AGENTMENU_CONFIG`'s own precedent.
private func resolvedManifestUserRoot() -> URL {
    if let override = ProcessInfo.processInfo.environment["AGENTMENU_MANIFESTS_USER_ROOT"], !override.isEmpty {
        return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
    }
    return ManifestRegistry.defaultUserRoot
}

private func describeUnavailable(_ availability: Availability) -> String {
    switch availability {
    case .available:
        return "available"
    case .binaryMissing(let binary):
        return "its binary '\(binary)' could not be resolved"
    case .applicationMissing(let bundleID):
        return "its application '\(bundleID)' is not installed"
    case .disabledByManifest:
        return "it is disabled"
    case .needsConfirmation:
        return "it is an unconfirmed user manifest — confirm it in Settings first"
    }
}

func fail(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
}
