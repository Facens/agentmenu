// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AgentMenuKit

/// Which agents and terminals exist, whether they can be used, and the escape
/// hatch for a binary the shell cannot find (R19, R21, R22, R44).
struct AgentsPane: View {
    @ObservedObject var model: SettingsModel
    let registry: ManifestRegistry
    /// Resolves a binary name to an absolute path, or nil when it cannot.
    let resolveBinary: (String) -> String?

    var body: some View {
        Form {
            Section("Agents") {
                ForEach(registry.agents, id: \.id) { agent in
                    agentRow(agent)
                }
            }

            Section("Terminals") {
                ForEach(registry.terminals, id: \.id) { terminal in
                    terminalRow(terminal)
                }
            }

            if !registry.failures.isEmpty {
                Section("Manifests that failed to load") {
                    ForEach(registry.failures, id: \.file) { failure in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(failure.file)
                            Text(String(describing: failure.error))
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func agentRow(_ agent: AgentManifest) -> some View {
        let path = model.config.binaries[agent.binary]
        let availability = registry.availability(of: agent, config: model.config, binaryPath: path)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(agent.displayName)
                badges(unverified: agent.unverified, origin: agent.origin, availability: availability)
                Spacer()
                Text(status(availability))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                TextField(
                    "Path to \(agent.binary)",
                    text: Binding(
                        get: { model.config.binaries[agent.binary] ?? "" },
                        set: { model.config.binaries[agent.binary] = $0.isEmpty ? nil : $0 }
                    )
                )
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11).monospaced())
                .accessibilityIdentifier(AccessibilityID.Settings.Agents.path(agent.id))
                Button("Find") {
                    if let resolved = resolveBinary(agent.binary) {
                        model.config.binaries[agent.binary] = resolved
                    } else {
                        model.failure = "Could not find “\(agent.binary)” from a login shell. Set the path by hand."
                    }
                }
                .controlSize(.small)
                // Asking a login shell to find a binary a manifest names is
                // running that manifest's word, so it waits for confirmation
                // the same way selecting the agent does (R44).
                .disabled(availability == .needsConfirmation)
                .help(availability == .needsConfirmation
                      ? "Confirm this manifest first — it names the program that would be looked up."
                      : "Ask a login shell where this binary is.")
                .accessibilityIdentifier(AccessibilityID.Settings.Agents.find(agent.id))
            }

            HStack(spacing: 14) {
                Toggle("Enabled", isOn: enabledBinding(id: agent.id, keyPath: \.agentState, manifestDefault: agent.enabled))
                    .accessibilityIdentifier(AccessibilityID.Settings.Agents.enabled(agent.id))
                if agent.origin == .user {
                    Toggle("Trusted", isOn: trustedBinding(id: agent.id, keyPath: \.agentState))
                        .help("A manifest you wrote names the binary, the environment and the arguments that will run. Confirm it before it can be selected.")
                        .accessibilityIdentifier(AccessibilityID.Settings.Agents.trusted(agent.id))
                }
            }
            .controlSize(.small)
            .toggleStyle(.checkbox)

            if agent.unverified {
                Text("The flags in this manifest were never executed against the real binary. Enable it if you want to try, and expect to correct the file.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .contain)
        .padding(.vertical, 2)
    }

    private func terminalRow(_ terminal: TerminalManifest) -> some View {
        let path = terminal.binary.flatMap { model.config.binaries[$0] }
        let availability = registry.availability(of: terminal, config: model.config, binaryPath: path)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(terminal.displayName)
                badges(unverified: terminal.unverified, origin: terminal.origin, availability: availability)
                Spacer()
                Text(status(availability))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 14) {
                Toggle("Enabled", isOn: enabledBinding(id: terminal.id, keyPath: \.terminalState, manifestDefault: terminal.enabled))
                    .accessibilityIdentifier(AccessibilityID.Settings.Terminals.enabled(terminal.id))
                if terminal.origin == .user {
                    Toggle("Trusted", isOn: trustedBinding(id: terminal.id, keyPath: \.terminalState))
                        .accessibilityIdentifier(AccessibilityID.Settings.Terminals.trusted(terminal.id))
                }
            }
            .controlSize(.small)
            .toggleStyle(.checkbox)
        }
        .accessibilityElement(children: .contain)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func badges(unverified: Bool, origin: ManifestOrigin, availability: Availability) -> some View {
        HStack(spacing: 5) {
            if unverified { badge("unverified", .orange) }
            if origin == .user { badge("yours", .secondary) }
            if availability == .needsConfirmation { badge("needs confirmation", .orange) }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 10))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private func status(_ availability: Availability) -> String {
        switch availability {
        case .available: return "available"
        case .binaryMissing(let binary): return "binary not found: \(binary)"
        case .applicationMissing(let bundle): return "not installed: \(bundle)"
        case .disabledByManifest: return "disabled"
        case .needsConfirmation: return "confirm before use"
        }
    }

    private func enabledBinding(
        id: String,
        keyPath: WritableKeyPath<Config, [String: ComponentState]>,
        manifestDefault: Bool
    ) -> Binding<Bool> {
        Binding(
            get: { model.config[keyPath: keyPath][id]?.enabled ?? manifestDefault },
            set: { newValue in
                var state = model.config[keyPath: keyPath][id] ?? ComponentState()
                state.enabled = newValue
                model.config[keyPath: keyPath][id] = state
            }
        )
    }

    private func trustedBinding(
        id: String,
        keyPath: WritableKeyPath<Config, [String: ComponentState]>
    ) -> Binding<Bool> {
        Binding(
            get: { model.config[keyPath: keyPath][id]?.trusted ?? false },
            set: { newValue in
                var state = model.config[keyPath: keyPath][id] ?? ComponentState()
                state.trusted = newValue
                model.config[keyPath: keyPath][id] = state
            }
        )
    }
}
