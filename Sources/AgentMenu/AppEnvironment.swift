// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Combine
import Foundation
import SwiftUI
import AgentMenuKit

/// Everything the app needs at runtime, built once and handed to the scenes.
///
/// The store, the manifest registry and the readers live here rather than in a
/// view, so the popover and the settings window read the same configuration and
/// the same manifests, and so either can be constructed with a different
/// service in a check.
@MainActor
final class AppEnvironment: ObservableObject {
    let store: ConfigStore
    let usageReader: UsageReader
    let registry: ManifestRegistry

    /// The overrides this launch resolved (U7, KTD4): all nil on an
    /// ordinary launch, since `Overrides.forGUI()` — the default this is
    /// constructed with — only reads the environment when `-AgentMenuHarness
    /// YES` was in the argument domain. `AppDelegate` reads this back after
    /// construction to pass the defaults suite, harness directory, manifests
    /// root and profile root into `HarnessJournal.shared.activate(…)`, so
    /// there is exactly one place — this struct — that decided what took
    /// effect.
    let overrides: Overrides

    /// The one copy of the configuration in this process.
    ///
    /// It used to be three — this object plus a copy captured inside each view
    /// model — and they drifted: first run wrote a real configuration while the
    /// settings window still held the empty one it was built with at launch, so
    /// its first edit saved that empty one back over the file. Everything now
    /// reads and writes through here.
    @Published private(set) var config: Config

    /// When this process last wrote the file, so an edit made by hand outside
    /// the app can be told from our own write.
    private var lastWrittenAt: Date?
    private var pendingSave: DispatchWorkItem?

    /// Which agents and terminals can be used right now. It is the same answer
    /// for every row in the popover and it probes Launch Services, so it is
    /// computed once and thrown away when the configuration changes.
    private var componentOptionsCache: (agents: [(id: String, name: String)], terminals: [(id: String, name: String)])?

    private(set) lazy var popover = PopoverModel(environment: self, service: self)
    private(set) lazy var settings = SettingsModel(environment: self)
    private(set) lazy var setup = SetupModel(environment: self)

    /// Set when a save fails, so a surface can show it rather than losing the
    /// change silently.
    @Published var saveFailure: String?

    /// `overrides` defaults to `Overrides.forGUI()` rather than an all-nil
    /// value: that is the one call in the app that decides, from the real
    /// argument domain, whether this launch is the harness's or a real
    /// one — every other initializer parameter stays inert unless it says
    /// so. `store`, when given explicitly, wins over `overrides.config`, the
    /// same "explicit beats resolved" precedence `ConfigStore`'s own
    /// callers already expect.
    init(store: ConfigStore? = nil, overrides: Overrides = .forGUI()) {
        self.overrides = overrides
        let store = store ?? ConfigStore(url: overrides.config ?? ConfigStore.defaultURL)
        self.store = store
        self.usageReader = UsageReader()
        self.config = (try? store.load()) ?? Config()
        // Without this the first `reloadIfChangedOnDisk` always reloads and
        // drops the availability cache, so the first popover open of every
        // launch pays a live Launch Services probe — the one click where it is
        // most visible.
        self.lastWrittenAt = (try? FileManager.default.attributesOfItem(atPath: store.url.path))
            .flatMap { $0[.modificationDate] as? Date }
        self.registry = ManifestRegistry(
            bundledRoot: ResourceRoot.bundled(),
            userRoot: overrides.manifestsUserRoot ?? ManifestRegistry.defaultUserRoot
        )
        registry.load()
    }

    /// The only way the configuration changes. Every caller goes through it, so
    /// there is one place that knows a change has to be persisted.
    ///
    /// Saves are coalesced: a text field in the settings window fires on every
    /// keystroke, and a full TOML re-serialisation plus an atomic write per
    /// character is work nobody asked for. A pending save is flushed before the
    /// app can lose it.
    func update(_ transform: (inout Config) -> Void) {
        transform(&config)
        componentOptionsCache = nil
        scheduleSave()
    }

    func scheduleSave(delay: TimeInterval = 0.4) {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func flushPendingSave() {
        guard pendingSave != nil else { return }
        pendingSave?.cancel()
        pendingSave = nil
        saveNow()
    }

    private func saveNow() {
        pendingSave = nil
        do {
            try store.save(config)
            lastWrittenAt = Date()
            saveFailure = nil
        } catch {
            saveFailure = "Could not save the configuration: \(error)"
        }
    }

    /// Writes a configuration that works, the first time the app runs.
    ///
    /// The setup window can be closed, and a launcher whose whole content is
    /// `$HOME` is not a launcher — so the defaults do not wait for the wizard
    /// to be finished. This seeds what the machine already has: the agent whose
    /// binary resolves, the terminal that is installed, the profiles whose
    /// directories exist, and `$HOME` as a target (R3). Everything else is what
    /// the wizard is for.
    ///
    /// It runs only when there is no configuration file at all, so it can never
    /// overwrite a choice the user made.
    func seedIfMissing() {
        guard !store.exists else { return }

        var seeded = Config()
        let probes = registry.agents.map { (id: $0.id, binary: $0.binary) }
        let paths = Detection.binaries(for: probes, cache: [:])
        seeded.binaries = Dictionary(
            uniqueKeysWithValues: registry.agents.compactMap { manifest in
                paths[manifest.id].map { (manifest.binary, $0) }
            }
        )

        if let agent = registry.agents.first(where: { paths[$0.id] != nil && $0.enabled && !$0.unverified })
            ?? registry.agents.first(where: { paths[$0.id] != nil }) {
            seeded.defaults.agent = agent.id
        }
        for terminal in registry.terminals where terminal.enabled && !terminal.unverified {
            let installed = registry.availability(of: terminal, config: seeded, binaryPath: nil)
            if installed == .available || installed == .needsConfirmation {
                seeded.defaults.terminal = terminal.id
                break
            }
        }

        // Every agent that is actually installed is enabled, not just the one
        // that becomes the default: a machine with two agents is a machine
        // whose owner may want either, per folder.
        for manifest in registry.agents where paths[manifest.id] != nil {
            var state = seeded.agentState[manifest.id] ?? ComponentState()
            state.enabled = true
            seeded.agentState[manifest.id] = state
        }

        seeded.profiles = Detection.profiles(
            for: seeded.defaults.agent.flatMap { registry.agent(id: $0) },
            profileRoot: overrides.profileRoot
        )
        seeded.activeProfileID = seeded.profiles.first?.id
        seeded.folders = [FolderTarget(label: "Home", path: "~", profileID: seeded.profiles.first?.id)]

        // R11: start on the values already in use, read once and never written.
        if let agentID = seeded.defaults.agent,
           let agent = registry.agent(id: agentID),
           let profile = seeded.profiles.first {
            seeded.defaults = Detection.seedPreset(seeded.defaults, from: agent, profile: profile)
        }

        config = seeded
        componentOptionsCache = nil
        saveNow()
    }

    /// Re-reads the configuration after another surface wrote it.
    func reload() {
        flushPendingSave()
        config = (try? store.load()) ?? config
        componentOptionsCache = nil
        popover.refresh()
    }

    /// Picks up an edit made to the file by hand. The file is meant to be
    /// hand-editable (KTD2), so the app cannot assume it is the only writer —
    /// but it also must not clobber its own unsaved work, hence the comparison
    /// against our own last write.
    func reloadIfChangedOnDisk() {
        guard pendingSave == nil,
              let attributes = try? FileManager.default.attributesOfItem(atPath: store.url.path),
              let modified = attributes[.modificationDate] as? Date else { return }
        if let lastWrittenAt, modified <= lastWrittenAt { return }
        if let fresh = try? store.load() {
            config = fresh
            componentOptionsCache = nil
            lastWrittenAt = modified
        }
    }

    /// The agent a preset selects, or the one the global default names —
    /// **only if it may actually be used**.
    ///
    /// The availability check is the enforcement point for R44, and it belongs
    /// here rather than at each call site: a manifest names the binary, the
    /// environment and the arguments of a process about to run, and a user file
    /// in `~/.config/agentmenu/agents/` shadows a bundled one by id, so the id
    /// already stored in the configuration keeps resolving — to the new file.
    /// Resolving by id alone made the "needs confirmation" badge decorative.
    func agentManifest(for preset: Preset) -> AgentManifest? {
        let id = preset.agent ?? config.defaults.agent
        let named = id.flatMap { registry.agent(id: $0) }
        if let named, isUsable(named) { return named }
        return registry.agents.first { $0.enabled && !$0.unverified && isUsable($0) }
    }

    func terminalManifest(for preset: Preset) -> TerminalManifest? {
        let id = preset.terminal ?? config.defaults.terminal
        let named = id.flatMap { registry.terminal(id: $0) }
        if let named, isUsable(named) { return named }
        return registry.terminals.first { $0.enabled && !$0.unverified && isUsable($0) }
    }

    /// A manifest the user has not confirmed, or one that is disabled or whose
    /// program is missing, is not a candidate for anything.
    func isUsable(_ agent: AgentManifest) -> Bool {
        registry.availability(of: agent, config: config, binaryPath: config.binaries[agent.binary]) == .available
    }

    func isUsable(_ terminal: TerminalManifest) -> Bool {
        registry.availability(
            of: terminal,
            config: config,
            binaryPath: terminal.binary.flatMap { config.binaries[$0] }
        ) == .available
    }

    /// R47: the write into an agent's configuration directory happens in one
    /// place, the CLI, and the app only ever asks for it. Running the installed
    /// binary rather than linking its code keeps that true even here.
    ///
    /// Not main-actor work: the CLI is drained and waited on off the main
    /// thread, with a bound, so a stalled child or one that writes more than
    /// the pipe buffer holds can never freeze the settings window. The same
    /// two hazards `StatuslineBridgeCommand` guards against on its own side.
    nonisolated static func installStatusLine(for profile: Profile) -> String {
        guard let cli = cliPath() else {
            return "The bundled command-line tool is missing from this build. Reinstall AgentMenu from a release."
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cli)
        process.arguments = ["install-statusline", "--profile", profile.id]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return "Could not run the command-line tool: \(error.localizedDescription)"
        }

        // Read to EOF on another queue so the child is never blocked on a
        // full pipe while this thread is blocked waiting for it to exit.
        let outputGroup = DispatchGroup()
        var collected = Data()
        outputGroup.enter()
        DispatchQueue.global().async {
            collected = pipe.fileHandleForReading.readDataToEndOfFile()
            outputGroup.leave()
        }

        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            process.waitUntilExit()
            exited.signal()
        }
        if exited.wait(timeout: .now() + 15) != .success {
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
            return "The command-line tool did not finish within 15 seconds and was stopped. Nothing was reported as written; check \(profile.configDirectory)/settings.json before trying again."
        }
        outputGroup.wait()

        let output = String(data: collected, encoding: .utf8) ?? ""
        // The only path on which the CLI can have written anything (KTD3),
        // and its own report is what names the files it wrote.
        HarnessJournal.shared.bridgeInstalled(
            profile: profile,
            ok: process.terminationStatus == 0,
            report: output
        )

        return output.isEmpty ? "Installed." : output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `Contents/Resources/bin/agentmenu` beside the running app (KTD8).
    nonisolated static func cliPath() -> String? {
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "").resolvingSymlinksInPath()
        let candidate = executable
            .deletingLastPathComponent()          // MacOS
            .deletingLastPathComponent()          // Contents
            .appendingPathComponent("Resources/bin/agentmenu")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate.path : nil
    }



    /// Resolves a binary through a login shell once and caches it (KTD5, R22).
    /// Used by the settings pane's "Find" button and by first run; a launch goes
    /// through `resolveOrReport`, which also reports the failure.
    func resolveBinary(_ name: String) -> String? {
        guard let path = try? BinaryResolver().resolve(name, cached: config.binaries[name]) else {
            return nil
        }
        update { $0.binaries[name] = path }
        return path
    }
}

/// Errors the popover reports verbatim (R6).
enum LaunchError: LocalizedError {
    case noAgentSelected
    case agentUnavailable(String)
    case terminalUnavailable(String)
    case folderMissing(String)
    case binaryMissing(String)

    var errorDescription: String? {
        switch self {
        case .noAgentSelected:
            return "No agent is selected. Open Settings and choose one."
        case .agentUnavailable(let id):
            return "The agent “\(id)” is not available."
        case .terminalUnavailable(let id):
            return "The terminal “\(id)” is not available."
        case .folderMissing(let path):
            return "That folder is gone: \(path)"
        case .binaryMissing(let binary):
            return "Could not find the “\(binary)” binary. Set its path in Settings."
        }
    }
}

extension AppEnvironment: LaunchServicing {
    /// The three layers, merged and checked against the agent's manifest.
    /// Everything that renders a value — the row pills, the override panel, the
    /// launch itself — comes through here, so what the popover shows and what
    /// the command carries cannot disagree.
    func resolvedPreset(for target: LaunchTarget, oneShot: Preset) -> ResolvedPreset {
        PresetResolver.resolve(
            global: config.defaults,
            folder: target.preset,
            oneShot: oneShot,
            agent: agentManifest(for: target.preset.overlaid(with: oneShot))
        )
    }

    func launch(target: LaunchTarget, profileID: String?, oneShot: Preset) async throws {
        let resolved = resolvedPreset(for: target, oneShot: oneShot)
        guard let agent = agentManifest(for: resolved.preset) else { throw LaunchError.noAgentSelected }
        guard let terminal = terminalManifest(for: resolved.preset) else {
            throw LaunchError.terminalUnavailable(resolved.preset.terminal ?? "none selected")
        }

        let binaryPath = try resolveOrReport(agent.binary)
        let profile = (profileID ?? resolved.preset.profile).flatMap { config.profile(id: $0) }
        let command = try CommandBuilder.build(
            agent: agent,
            resolved: resolved,
            profile: profile,
            directory: target.expandedPath,
            binaryPath: binaryPath
        )
        // The command is built here and nowhere else, so this is the only
        // place the hook can record what a launch is about to run (KTD3).
        HarnessJournal.shared.launchRequested(
            target: target,
            command: command,
            agent: agent.id,
            terminal: terminal.id,
            preset: resolved.preset
        )
        do {
            try await open(command, in: terminal)
        } catch {
            HarnessJournal.shared.launchResult(target: target, kind: "agent", error: error)
            throw error
        }
        HarnessJournal.shared.launchResult(target: target, kind: "agent", error: nil)
    }

    func openTerminal(target: LaunchTarget, oneShot: Preset) async throws {
        let resolved = resolvedPreset(for: target, oneShot: oneShot)
        guard let terminal = terminalManifest(for: resolved.preset) else {
            throw LaunchError.terminalUnavailable(resolved.preset.terminal ?? "none selected")
        }
        guard FileManager.default.fileExists(atPath: target.expandedPath) else {
            throw LaunchError.folderMissing(target.path)
        }
        // A plain terminal is a launch too (R5): the end state a scenario
        // asserts is a terminal window on that folder, and it needs the same
        // evidence as an agent session.
        let command = CommandBuilder.terminalOnly(directory: target.expandedPath)
        HarnessJournal.shared.launchRequested(
            target: target,
            command: command,
            agent: nil,
            terminal: terminal.id,
            preset: resolved.preset
        )
        do {
            try await open(command, in: terminal)
        } catch {
            HarnessJournal.shared.launchResult(target: target, kind: "terminal", error: error)
            throw error
        }
        HarnessJournal.shared.launchResult(target: target, kind: "terminal", error: nil)
    }

    /// Everything that reads configuration stays on the main actor; the part
    /// that spawns a process and waits for it is handed to a detached task.
    /// `osascript` can take seconds to answer — longer still while macOS asks
    /// the user whether this app may control the terminal — and every one of
    /// those seconds used to be a frozen popover.
    private func open(_ command: LaunchCommand, in terminal: TerminalManifest) async throws {
        let binaryPath = try terminal.binary.map { try resolveOrReport($0) }
        try await Task.detached(priority: .userInitiated) {
            try TerminalLauncher(runner: TerminalLauncher.systemRunner())
                .open(command: command, terminal: terminal, binaryPath: binaryPath)
        }.value
    }

    /// KTD5 and R22: the cached path when it still points at something
    /// executable, otherwise one login-shell lookup, and the answer is cached so
    /// the next launch does not pay for it. A second failure names the binary
    /// (AE5) rather than failing silently.
    private func resolveOrReport(_ binary: String) throws -> String {
        do {
            let path = try BinaryResolver().resolve(binary, cached: config.binaries[binary])
            if config.binaries[binary] != path {
                update { $0.binaries[binary] = path }
            }
            return path
        } catch {
            throw LaunchError.binaryMissing(binary)
        }
    }

    /// What the active agent and terminal declare. A capability the manifest
    /// omits is absent here too, so the control disappears rather than being
    /// shown disabled (R13).
    func options(for preset: Preset) -> PresetOptions {
        var options = PresetOptions()
        let components = componentOptions()
        options.agents = components.agents
        options.terminals = components.terminals

        guard let agent = agentManifest(for: preset) else { return options }
        options.model = agent.model?.values
        options.effort = agent.effort?.values
        options.permissionMode = agent.permissionMode?.values
        options.permission = agent.permissionMode
        options.advisor = agent.advisor?.values
        options.canDisableAdvisor = agent.advisor?.canDisable ?? false
        return options
    }

    private func componentOptions() -> (agents: [(id: String, name: String)], terminals: [(id: String, name: String)]) {
        if let cached = componentOptionsCache { return cached }
        let agents = registry.agents
            .filter { isUsable($0) }
            .map { (id: $0.id, name: $0.displayName) }
        let terminals = registry.terminals
            .filter { isUsable($0) }
            .map { (id: $0.id, name: $0.displayName) }
        let computed = (agents: agents, terminals: terminals)
        componentOptionsCache = computed
        return computed
    }

    /// Which snapshot file to read comes from the agent's manifest, so a
    /// profile with no agent resolved simply has no readout (R25).
    ///
    /// Reads through `Overrides.resolveProfileDirectory` rather than
    /// `profile.expandedConfigDirectory` directly: R3 forbids the app-fresh
    /// tier from *reading* the maintainer's own Claude Code directories, not
    /// only writing them, and a profile seeded with a `~`-prefixed
    /// directory would otherwise read the real home's usage snapshot
    /// regardless of `AGENTMENU_PROFILE_ROOT`.
    func usage(forProfile profile: Profile) -> UsageReading {
        guard let template = snapshotTemplate else { return .unavailable }
        let directory = Overrides.resolveProfileDirectory(profile.configDirectory, profileRoot: overrides.profileRoot)
        return usageReader.read(template: template, profileDirectory: directory)
    }

    /// The projection reads the history the status-line bridge appends to. No
    /// history, no projection — the same self-hiding rule as the readout, which
    /// is why it needs no setting of its own. Same profile-root routing as
    /// `usage(forProfile:)`, for the same reason.
    func projector(forProfile profile: Profile) -> UsageProjector? {
        guard let template = snapshotTemplate else { return nil }
        let directory = Overrides.resolveProfileDirectory(profile.configDirectory, profileRoot: overrides.profileRoot)
        let url = UsageHistory.path(snapshotTemplate: template, profileDirectory: directory)
        guard let history = UsageHistory.read(at: url) else { return nil }
        return UsageProjector(history: history)
    }

    private var snapshotTemplate: String? {
        agentManifest(for: config.defaults)?.usageSnapshot
    }
}
