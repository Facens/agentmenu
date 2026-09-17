// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AgentMenuKit

/// The preset rows shared by the folder pane and the defaults pane.
///
/// Everything is a plain `Picker` in a grouped `Form`: system accent, system
/// metrics, nothing branded. A settings window that expresses a brand is a
/// settings window people have to learn.
struct PresetEditor: View {
    @Binding var preset: Preset
    let options: PresetOptions
    /// What an unset field falls back to. nil in the defaults pane, where
    /// nothing is inherited.
    var inherited: Preset?
    /// The terminal is chosen once, centrally: which application opens is a
    /// property of the machine, not of a project folder. Only the defaults pane
    /// shows it.
    var showsTerminal: Bool = false

    var body: some View {
        if let values = options.model {
            row("Model", values: values, selection: $preset.model, inherited: inherited?.model)
        }
        if let values = options.effort {
            row("Effort", values: values, selection: $preset.effort, inherited: inherited?.effort)
        }
        if let values = options.permissionMode {
            row("Permission", values: values, selection: $preset.permissionMode, inherited: inherited?.permissionMode)
            if let mode = preset.permissionMode ?? inherited?.permissionMode, options.isBypassing(mode) {
                Label(
                    "This target launches without the agent's permission prompts. The row in the menu is marked before the click.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        if let values = options.advisor {
            advisorRow(values)
        }
        if !options.agents.isEmpty {
            row("Agent", values: options.agents.map(\.id), selection: $preset.agent,
                inherited: inherited?.agent, names: Dictionary(uniqueKeysWithValues: options.agents.map { ($0.id, $0.name) }))
        }
        if showsTerminal, !options.terminals.isEmpty {
            row("Terminal", values: options.terminals.map(\.id), selection: $preset.terminal,
                inherited: inherited?.terminal, names: Dictionary(uniqueKeysWithValues: options.terminals.map { ($0.id, $0.name) }))
        }
    }

    private func row(
        _ label: String,
        values: [String],
        selection: Binding<String?>,
        inherited: String?,
        names: [String: String] = [:]
    ) -> some View {
        Picker(label, selection: selection) {
            Text(inheritLabel(inherited, names: names)).tag(String?.none)
            ForEach(values, id: \.self) { value in
                Text(names[value] ?? value).tag(String?.some(value))
            }
        }
    }

    private func advisorRow(_ values: [String]) -> some View {
        Picker("Advisor", selection: $preset.advisor) {
            Text(advisorInheritLabel).tag(AdvisorSetting?.none)
            if options.canDisableAdvisor {
                Text("Off").tag(AdvisorSetting?.some(.off))
            }
            ForEach(values, id: \.self) { value in
                Text(value).tag(AdvisorSetting?.some(.model(value)))
            }
        }
    }

    private func inheritLabel(_ inherited: String?, names: [String: String]) -> String {
        guard let inherited else { return self.inherited == nil ? "Not set" : "Inherit" }
        return "Inherit (\(names[inherited] ?? inherited))"
    }

    private var advisorInheritLabel: String {
        switch inherited?.advisor {
        case .none: return inherited == nil ? "Not set" : "Inherit"
        case .off: return "Inherit (off)"
        case .model(let model): return "Inherit (\(model))"
        }
    }
}
