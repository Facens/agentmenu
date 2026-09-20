// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AgentMenuKit

/// The global default preset every folder inherits from (R7).
struct DefaultsPane: View {
    @ObservedObject var model: SettingsModel
    let options: (Preset) -> PresetOptions

    var body: some View {
        Form {
            Section {
                PresetEditor(preset: $model.config.defaults, options: options(model.config.defaults), inherited: nil,
                             showsTerminal: true, idScope: "defaults")
            } header: {
                Text("Global default")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Every folder starts from these values and overrides only what it needs. The shipped default uses the agent's own permission mode — a mode that stops the agent asking is only ever one you set here.")
                    Text("The terminal is set once, here: which application opens is a property of this machine, not of a project. Another terminal — including one AgentMenu has never heard of — is a manifest file in ~/.config/agentmenu/terminals/; see docs/adding-a-terminal.md.")
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 6)
    }
}
