// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AgentMenuKit

/// Setup, inside the dropdown it is setting up.
///
/// A menu-bar app that opens a second window to configure itself has two
/// surfaces where it needs one — and the window was mostly empty, because
/// detection had already answered everything except these two questions.
struct SetupCard: View {
    @ObservedObject var model: SetupModel
    let done: () -> Void
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            agents
            folders
            HStack {
                Button("Add another folder…") { model.chooseFolders() }
                    .controlSize(.small)
                    .accessibilityIdentifier(AccessibilityID.Setup.addFolder)
                Spacer()
                Button("Done") {
                    model.finish()
                    done()
                }
                .controlSize(.small)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.hasProjectFolder)
                .accessibilityIdentifier(AccessibilityID.Setup.done)
            }
            if !model.hasProjectFolder {
                Text("Pick at least one folder you work in — a menu with only $HOME in it is not a launcher.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .onAppear { model.detect() }
    }

    // MARK: Agents

    private var agents: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("Agents")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                if model.detecting {
                    ProgressView().controlSize(.small).scaleEffect(0.6).frame(height: 10)
                }
                Spacer()
            }

            ForEach(model.detectedAgents.filter(\.found)) { hit in
                // Two real controls on one line — the toggle and, once
                // chosen, "make default" — so the row states its intent
                // instead of collapsing into a single opaque element.
                HStack(spacing: 7) {
                    Toggle("", isOn: Binding(
                        get: { model.isChosen(hit.manifest.id) },
                        set: { model.toggleAgent(hit.manifest.id, on: $0) }
                    ))
                    .toggleStyle(.checkbox)
                    .labelsHidden()
                    .accessibilityIdentifier(AccessibilityID.Setup.agentToggle(hit.manifest.id))

                    Text(hit.manifest.displayName).font(.system(size: 12))
                    if model.config.defaults.agent == hit.manifest.id {
                        Text("default")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.brandAccent(scheme))
                    } else if model.isChosen(hit.manifest.id) {
                        Button("make default") { model.makeDefault(hit.manifest.id) }
                            .buttonStyle(.plain)
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .accessibilityIdentifier(AccessibilityID.Setup.agentMakeDefault(hit.manifest.id))
                    }
                    if hit.manifest.unverified {
                        Text("unverified").font(.system(size: 10)).foregroundStyle(Color.brandWarning(scheme))
                    }
                    Spacer()
                }
                .accessibilityElement(children: .contain)
            }

            if !model.detecting, model.detectedAgents.allSatisfy({ !$0.found }) {
                Text("No agent found. Install one, or set its path in Settings — the lookup asks a login shell, so an agent your shell cannot see will not appear.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Folders

    @ViewBuilder
    private var folders: some View {
        if !model.suggestedFolders.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Folders found here")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)

                // A ScrollView has no intrinsic height, and this sits inside a
                // popover that sizes itself to its content — so it has to be
                // told how tall to be, or it collapses to nothing and the
                // section renders as a heading with a void under it.
                ScrollView {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(model.suggestedFolders, id: \.self) { path in
                            Toggle(path, isOn: Binding(
                                get: { model.isConfigured(path) },
                                set: { model.setFolder(path, added: $0) }
                            ))
                            .toggleStyle(.checkbox)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .accessibilityIdentifier(AccessibilityID.Setup.folderToggle(path: path))
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: min(CGFloat(model.suggestedFolders.count), 6) * 21)
            }
        }
    }
}
