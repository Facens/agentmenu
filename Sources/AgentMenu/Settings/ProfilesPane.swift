// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import AgentMenuKit

/// Accounts. A profile is a name plus the configuration directory the agent
/// runs against (R14, R15).
struct ProfilesPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VSplitView {
            list
                .frame(minHeight: 130)
                .padding(.bottom, 8)
            if let index = profileIndex {
                detail(index: index)
                    .frame(minHeight: 170)
                    .padding(.top, 8)
            }
        }
        .padding(20)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 7) {
            Table(model.config.profiles, selection: $model.selectedProfile) {
                TableColumn("Account") { profile in
                    Text(profile.name.isEmpty ? profile.id : profile.name)
                }
                TableColumn("Configuration directory") { profile in
                    Text(profile.configDirectory)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(profile.configDirectory)
                }
            }
            .tableStyle(.bordered(alternatesRowBackgrounds: true))
            .frame(minHeight: 100, maxHeight: .infinity)

            HStack(spacing: 6) {
                Button { model.addProfile() } label: { Image(systemName: "plus") }
                    .help("Add an account")
                Button {
                    if let id = model.selectedProfile { model.removeProfile(id: id) }
                } label: { Image(systemName: "minus") }
                    .disabled(model.selectedProfile == nil || model.config.profiles.count < 2)
                    .help("Remove the selected account. Folders on it move to the first remaining one.")
                Spacer()
            }
            .controlSize(.small)
        }
    }

    private func detail(index: Int) -> some View {
        Form {
            Section {
                TextField("Name", text: $model.config.profiles[index].name)
                LabeledContent("Configuration directory") {
                    HStack {
                        Text(model.config.profiles[index].configDirectory)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(model.config.profiles[index].configDirectory)
                        Spacer(minLength: 8)
                        Button("Choose…") { chooseDirectory(index: index) }
                            .controlSize(.small)
                            .fixedSize()
                    }
                }
                LabeledContent("Identifier") {
                    Text(model.config.profiles[index].id)
                        .foregroundStyle(.secondary)
                }
            } footer: {
                Text("The agent runs with this directory as its configuration, which is what keeps two accounts apart. AgentMenu reads it and never writes to it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            // R29 / R47: the status-line bridge is installed from here and
            // nowhere else — the bundled CLI is not on PATH, and the popover's
            // setup card deliberately does not offer a write into the agent's
            // own directory. The exception to "never writes to it" above.
            Section {
                LabeledContent("Rate-limit readout") {
                    Button("Install status-line bridge…") { installBridge(index: index) }
                        .controlSize(.small)
                        .fixedSize()
                }
                if let report = model.bridgeInstallReport[model.config.profiles[index].id] {
                    Text(report)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } footer: {
                Text("Writes agentmenu-statusline.sh into this directory and points statusLine in its settings.json at it, so the readout can see the rate limits Claude Code reports. A status line you already have keeps running: the bridge chains to it.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Names the file and the key before anything is written (R47), then
    /// lets the CLI do the writing and shows what it said.
    private func installBridge(index: Int) {
        let profile = model.config.profiles[index]
        let alert = NSAlert()
        alert.messageText = "Install the status-line bridge for \u{201C}\(profile.name.isEmpty ? profile.id : profile.name)\u{201D}?"
        alert.informativeText = "AgentMenu writes agentmenu-statusline.sh into \(profile.configDirectory) and sets statusLine.command in \(profile.configDirectory)/settings.json to run it. Every other key in that file is left as it is. If a status line is already configured, the bridge calls it and passes its output through."
        alert.addButton(withTitle: "Install")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.installStatusLineBridge(profileID: profile.id)
    }

    private var profileIndex: Int? {
        guard let id = model.selectedProfile else { return nil }
        return model.config.profiles.firstIndex { $0.id == id }
    }

    private func chooseDirectory(index: Int) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.config.profiles[index].configDirectory = PathDisplay.abbreviated(url.path)
    }
}
