// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// `agentmenu resolve <dir> [--profile|--config-dir|--command|--keep-running]` (R30): the
/// one source of truth the shell asks instead of keeping its own copy of the
/// folder->account mapping. Exit codes: `2` is a usage error (bad flags,
/// missing argument); `1` means "nothing to print" — the directory is not
/// configured, or what it names cannot be resolved — so a shell function can
/// fall back to its own default without misreading a real answer; `0` is
/// success, with the answer on stdout and nothing else there.
///
/// `--keep-running` (R15) prints the resolved "keep running when window
/// closes" value for the folder: `true`, `false`, or `n/a` when the folder's
/// agent or terminal cannot keep a session running. It is a mode of its own,
/// so what the other three print is untouched.
func runResolve(_ args: [String], configStore: ConfigStore) -> Int32 {
    enum Mode { case profile, configDir, command, keepRunning }

    var mode: Mode = .profile
    var directory: String?
    for arg in args {
        switch arg {
        case "--profile": mode = .profile
        case "--config-dir": mode = .configDir
        case "--command": mode = .command
        case "--keep-running": mode = .keepRunning
        default:
            guard directory == nil, !arg.hasPrefix("--") else {
                fail("agentmenu resolve: unknown argument '\(arg)'")
                return 2
            }
            directory = arg
        }
    }
    guard let directory else {
        fail("agentmenu resolve: usage: agentmenu resolve <dir> [--profile|--config-dir|--command|--keep-running]")
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
    // through to `config.activeProfileID` here: an unpinned folder is one
    // no profile has ever been recorded for. Answering with whichever
    // profile the popover happens to have active right now would silently
    // pick an account for a folder that was never configured to use it,
    // turning "not configured" into a wrong-account launch instead of the
    // honest failure this resolver otherwise reports.
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

    case .keepRunning:
        return resolveKeepRunning(folder: folder, config: config)
    }
}

/// What both the `--keep-running` and `--command` branches start from: the
/// loaded manifest registry, the merged global+folder preset, and the agent
/// that preset names (else the first enabled, verified one). Prints the "no
/// agent" failure and returns nil when there is none, so a caller only has to
/// answer `1`.
private func loadRegistryAndAgent(
    folder: FolderTarget,
    config: Config
) -> (registry: ManifestRegistry, merged: Preset, agent: AgentManifest)? {
    let registry = ManifestRegistry(
        bundledRoot: ResourceRoot.bundled(),
        userRoot: resolvedManifestUserRoot()
    )
    registry.load()

    let merged = config.defaults.overlaid(with: folder.preset)
    let agent = merged.agent.flatMap { registry.agent(id: $0) } ?? registry.agents.first { $0.enabled && !$0.unverified }
    guard let agent else {
        fail("agentmenu resolve: no agent is configured or available")
        return nil
    }
    return (registry, merged, agent)
}

/// The `--keep-running` branch: the same `PresetResolver` call the popover's
/// `resolvedPreset(for:oneShot:)` makes, so this prints what a launch from the
/// popover would carry. The terminal follows `AppEnvironment.terminalManifest`:
/// the merged preset's own, else the first enabled, verified one — "enabled"
/// read the way `ManifestRegistry.availability` reads it (the configuration's
/// `[terminals.<id>]` state, else the manifest's own flag) — without the
/// availability check's installed-application probe, which the CLI does not run.
private func resolveKeepRunning(folder: FolderTarget, config: Config) -> Int32 {
    guard let (registry, merged, agent) = loadRegistryAndAgent(folder: folder, config: config) else { return 1 }
    let terminalID = merged.terminal ?? registry.terminals.first {
        (config.terminalState[$0.id]?.enabled ?? $0.enabled) && !$0.unverified
    }?.id

    let resolved = PresetResolver.resolve(
        global: config.defaults, folder: folder.preset, oneShot: Preset(), agent: agent, terminalID: terminalID
    )
    switch resolved.keepRunning {
    case .some(let value): print(value ? "true" : "false")
    case .none: print("n/a")
    }
    return 0
}

/// The `--command` branch: builds the exact `LaunchCommand` the popover
/// would use for this folder, through `PresetResolver`/`CommandBuilder` —
/// never assembled by hand, so `resolve --command` and the popover's own
/// launch can never drift apart (the plan's "launch parity" gate compares
/// this string against what the popover launches).
///
/// One difference is by design: every fresh launch the app makes is pinned to a
/// new random id (`--session-id <uuid>`, U11), which a command run from outside
/// cannot reproduce, so this prints the launched command *without* that pair —
/// `CommandBuilder` is called without a `sessionID` — and the output is
/// identical from one call to the next. Everything else, in the same order,
/// is what the popover types (`CommandBuilder.build`'s documented flag order).
private func resolveCommand(folder: FolderTarget, config: Config, profileID: String?) -> Int32 {
    guard let (registry, _, agent) = loadRegistryAndAgent(folder: folder, config: config) else { return 1 }

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
///
/// Delegates to `Overrides.forCLI()` (U7) — see `resolvedConfigURL()` in
/// main.swift for why this reader is unconditional.
private func resolvedManifestUserRoot() -> URL {
    Overrides.forCLI().manifestsUserRoot ?? ManifestRegistry.defaultUserRoot
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
