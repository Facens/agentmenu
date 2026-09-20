// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// `agentmenu dump-state` (hidden, U7): prints what the CLI's overrides
/// resolve to, as one JSON object on stdout — the config path, the resolved
/// profile directories, and every loaded agent's and terminal's
/// availability. Not a command a person types; it exists so a harness
/// scenario can cross-check its own fixture against what the GUI's journal
/// echoed (`harness started`'s fixture, AE8 groundwork) without reading
/// `config.toml` or probing Launch Services itself.
///
/// Reads overrides through `Overrides.forCLI()` — the same unconditional
/// reader `resolve` and `import` use, with no argument-domain gate. That is
/// deliberate, not an oversight of KTD4's gate: `dump-state`, like the rest
/// of the CLI, is invoked deliberately (by a person or by the harness
/// running as the user), never by Finder, the Dock or Spotlight, so there is
/// no real launch for the gate to protect here.
///
/// Field names match `HarnessJournal`'s fixture echo
/// (`Sources/AgentMenu/HarnessJournal.swift`) byte-for-byte wherever both
/// report the same thing — `config`, `manifests_root`, `profile_root`,
/// `profile_count`, `profiles` (each `{id, config_dir}`) — so a harness
/// comparison between the two is a literal field match, never a translation.
///
/// Exit codes follow the rest of the CLI (`ResolveCommand.swift`): `0` with
/// the JSON on stdout; `2` for a usage error, which for this command also
/// covers a `config.toml` that exists but fails to parse — the same
/// treatment `agentmenu resolve` gives that failure. `dump-state` has no
/// case that reaches `1` ("nothing to print"): unlike `resolve`, which
/// answers about one folder that may not be configured, `dump-state`
/// describes whatever overrides it was given, and an empty `Config()` is
/// still a complete, valid answer.
func runDumpState(_ args: [String]) -> Int32 {
    guard args.isEmpty else {
        fail("agentmenu dump-state: unknown argument '\(args[0])'")
        return 2
    }

    let overrides = Overrides.forCLI()
    let configURL = overrides.config ?? ConfigStore.defaultURL
    let manifestsRoot = overrides.manifestsUserRoot ?? ManifestRegistry.defaultUserRoot

    let config: Config
    do {
        config = (try ConfigStore(url: configURL).load()) ?? Config()
    } catch {
        fail("agentmenu dump-state: \(error)")
        return 2
    }

    let registry = ManifestRegistry(bundledRoot: ResourceRoot.bundled(), userRoot: manifestsRoot)
    registry.load()

    var payload: [String: Any] = [
        "config": configURL.path,
        "manifests_root": manifestsRoot.path,
        "profile_count": config.profiles.count,
        "profiles": config.profiles.map { profile -> [String: Any] in
            let directory = Overrides.resolveProfileDirectory(profile.configDirectory, profileRoot: overrides.profileRoot)
            return ["id": profile.id, "config_dir": directory.path]
        },
        // Availability is read from `config.binaries` — the cached path a
        // previous resolve or launch already recorded — never a fresh
        // `BinaryResolver` login-shell probe. That mirrors
        // `AppEnvironment.isUsable`, which is what actually decides what the
        // popover offers, so `dump-state`'s answer predicts the GUI's rather
        // than a differently-computed one that happens to look similar.
        "agents": registry.agents.map { agent in
            describeAvailability(
                id: agent.id,
                availability: registry.availability(of: agent, config: config, binaryPath: config.binaries[agent.binary])
            )
        },
        "terminals": registry.terminals.map { terminal in
            describeAvailability(
                id: terminal.id,
                availability: registry.availability(
                    of: terminal,
                    config: config,
                    binaryPath: terminal.binary.flatMap { config.binaries[$0] }
                )
            )
        },
    ]
    if let profileRoot = overrides.profileRoot {
        payload["profile_root"] = profileRoot.path
    }

    guard let data = try? JSONSerialization.data(
        withJSONObject: payload,
        options: [.sortedKeys, .withoutEscapingSlashes]
    ) else {
        fail("agentmenu dump-state: could not encode the result as JSON")
        return 2
    }
    print(String(decoding: data, as: UTF8.self))
    return 0
}

/// `Availability` folded to the three-word vocabulary the plan names
/// (`available`, `needs_confirmation`, `missing`) under `availability`, with
/// the exact case preserved under `detail` — `Availability` has no
/// "disabled" bucket of its own in the plan's vocabulary, but collapsing
/// `.disabledByManifest` into `missing` without keeping the distinction
/// anywhere would make a fixture that forgot to enable a terminal
/// indistinguishable, in this JSON, from one whose binary is genuinely not
/// installed.
private func describeAvailability(id: String, availability: Availability) -> [String: Any] {
    let bucket: String
    let detail: String
    switch availability {
    case .available:
        bucket = "available"
        detail = "available"
    case .needsConfirmation:
        bucket = "needs_confirmation"
        detail = "needs_confirmation"
    case .disabledByManifest:
        bucket = "missing"
        detail = "disabled_by_manifest"
    case .binaryMissing(let binary):
        bucket = "missing"
        detail = "binary_missing:\(binary)"
    case .applicationMissing(let bundleID):
        bucket = "missing"
        detail = "application_missing:\(bundleID)"
    }
    return ["id": id, "availability": bucket, "detail": detail]
}
