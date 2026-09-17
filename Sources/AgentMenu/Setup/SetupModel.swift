// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import Foundation
import AgentMenuKit

/// The state behind the setup card in the popover.
///
/// What used to be a five-step window is two decisions — which agents to use,
/// and which folders — because everything else is detected: the agents on the
/// machine, the accounts the agent has, the git checkouts under the usual code
/// directories. The rest of the configuration is already written before this is
/// ever shown (`AppEnvironment.seedIfMissing`), so this card adds to a working
/// launcher rather than standing between the user and one.
///
/// The things it deliberately does not do live in Settings: renaming accounts,
/// importing an old launcher's list, and installing the status-line bridge —
/// that last one writes into the agent's own configuration directory, which is
/// not something to offer in a menu that closes when you look away.
@MainActor
final class SetupModel: ObservableObject {
    @Published private(set) var detectedAgents: [Detection.AgentHit] = []
    @Published private(set) var suggestedFolders: [String] = []
    @Published private(set) var detecting = false

    private unowned let environment: AppEnvironment
    private var cancellables: Set<AnyCancellable> = []

    init(environment: AppEnvironment) {
        self.environment = environment
        environment.$config
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    var config: Config { environment.config }
    var registry: ManifestRegistry { environment.registry }

    /// The card shows until the user says they are done, and comes back if the
    /// launcher is ever empty again — an empty dropdown is the one state that
    /// always needs an answer.
    var isNeeded: Bool {
        !config.firstRunCompleted || !hasProjectFolder
    }

    var hasProjectFolder: Bool {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return config.folders.contains { $0.expandedPath.path != home }
    }

    // MARK: Detection

    func detect() {
        guard !detecting, detectedAgents.isEmpty else { return }
        detecting = true
        let probes = registry.agents.map { (id: $0.id, binary: $0.binary) }
        let manifests = Dictionary(uniqueKeysWithValues: registry.agents.map { ($0.id, $0) })
        let cache = config.binaries
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let paths = Detection.binaries(for: probes, cache: cache)
            let folders = Detection.projectFolders()
            DispatchQueue.main.async {
                guard let self else { return }
                self.detectedAgents = probes.compactMap { probe in
                    manifests[probe.id].map { Detection.AgentHit(manifest: $0, path: paths[probe.id]) }
                }
                self.suggestedFolders = folders
                self.detecting = false
                self.environment.update { config in
                    for (id, path) in paths {
                        if let manifest = manifests[id] { config.binaries[manifest.binary] = path }
                        var state = config.agentState[id] ?? ComponentState()
                        state.enabled = true
                        config.agentState[id] = state
                    }
                }
            }
        }
    }

    // MARK: The two decisions

    func isChosen(_ id: String) -> Bool {
        guard let manifest = registry.agent(id: id) else { return false }
        return config.agentState[id]?.enabled ?? manifest.enabled
    }

    func toggleAgent(_ id: String, on: Bool) {
        environment.update { config in
            var state = config.agentState[id] ?? ComponentState()
            state.enabled = on
            config.agentState[id] = state
            if on, config.defaults.agent == nil { config.defaults.agent = id }
        }
    }

    func makeDefault(_ id: String) {
        environment.update { $0.defaults.agent = id }
    }

    func isConfigured(_ path: String) -> Bool {
        let normalized = FolderTarget(label: "", path: path).normalizedPath
        return config.folders.contains { $0.normalizedPath == normalized }
    }

    /// Ticking adds, unticking removes. There is no second button to press.
    ///
    /// Unticking removes a single entry, and only when that folder has exactly
    /// one: the settings window can give one folder several entries — the same
    /// project on two accounts — and a checkbox in the setup wizard must not
    /// be able to delete a set of rows the user built by hand there.
    func setFolder(_ path: String, added: Bool) {
        let candidate = FolderTarget(
            label: (path as NSString).lastPathComponent,
            path: path,
            profileID: config.activeProfileID
        )
        environment.update { config in
            let matching = config.folders.filter { $0.normalizedPath == candidate.normalizedPath }
            if added {
                guard matching.isEmpty else { return }
                config.folders.append(candidate)
            } else {
                guard matching.count == 1 else { return }
                config.folders.removeAll { $0.normalizedPath == candidate.normalizedPath }
            }
        }
    }

    func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { setFolder(PathDisplay.abbreviated(url.path), added: true) }
    }

    func finish() {
        environment.update { $0.firstRunCompleted = true }
        environment.flushPendingSave()
    }
}
