// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AgentMenuKit

/// The panel under an expanded row: the full override set, then the actions.
///
/// Every control here writes to the one-shot layer, which is discarded on
/// launch unless the user saves it (R9, R10). A control appears only when the
/// active agent declares that capability (R13) — an agent with no effort flag
/// shows no effort control rather than a disabled one.
///
/// The terminal is not here: it is chosen once in settings, because which
/// application opens is a property of the machine rather than of a project.
struct OverrideDisclosure: View {
    let target: LaunchTarget
    let effective: Preset
    let options: PresetOptions
    @Binding var oneShot: Preset
    let launch: () -> Void
    let openTerminal: () -> Void
    let saveToFolder: () -> Void
    let saveAsDefault: () -> Void

    @Environment(\.colorScheme) private var scheme

    private var columns: [GridItem] {
        [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("This launch only — the saved preset stays as it is")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.bottom, 8)

            // `.contain`: five independent pickers plus, below, four action
            // buttons live in this one panel — a scenario needs each on its
            // own, not the panel folded into a single element.
            LazyVGrid(columns: columns, alignment: .leading, spacing: 7) {
                if let values = options.model {
                    control("Model", values: values, selection: $oneShot.model, inherited: effective.model,
                            id: AccessibilityID.Popover.overrideModel(target))
                }
                if let values = options.effort {
                    control("Effort", values: values, selection: $oneShot.effort, inherited: effective.effort,
                            id: AccessibilityID.Popover.overrideEffort(target))
                }
                if let values = options.permissionMode {
                    control("Permission", values: values, selection: $oneShot.permissionMode, inherited: effective.permissionMode,
                            id: AccessibilityID.Popover.overridePermission(target))
                }
                if let values = options.advisor {
                    advisorControl(values)
                }
                if !options.agents.isEmpty {
                    control("Agent", values: options.agents.map(\.id), selection: $oneShot.agent,
                            inherited: effective.agent, names: Dictionary(uniqueKeysWithValues: options.agents.map { ($0.id, $0.name) }),
                            id: AccessibilityID.Popover.overrideAgent(target))
                }
            }
            .accessibilityElement(children: .contain)

            HStack(spacing: 6) {
                Button(action: launch) {
                    HStack(spacing: 5) {
                        Image(systemName: "play.fill").font(.system(size: 10))
                        Text("Launch").fontWeight(.semibold)
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 26)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color.brandAccent(scheme))
                )
                .foregroundStyle(.white)
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier(AccessibilityID.Popover.overrideLaunch(target))

                Button(action: openTerminal) {
                    HStack(spacing: 5) {
                        Image(systemName: "terminal").font(.system(size: 10))
                        Text("Terminal only")
                    }
                    .frame(height: 26)
                    .padding(.horizontal, 10)
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: .controlColor))
                        .shadow(color: .black.opacity(0.12), radius: 0.5, y: 0.5)
                )
                .help("Opens a terminal in this folder and starts no agent.")
                .accessibilityIdentifier(AccessibilityID.Popover.overrideTerminal(target))
            }
            .padding(.top, 11)

            HStack(spacing: 6) {
                Button("Save to folder", action: saveToFolder)
                    .disabled(target.kind != .folder)
                    .help(target.kind == .folder
                          ? "Keep these values for this folder."
                          : "Only a configured folder has a preset to save to.")
                    .accessibilityIdentifier(AccessibilityID.Popover.overrideSaveToFolder(target))
                Button("Save as default…", action: saveAsDefault)
                    .help("Change the global default. Every folder that inherits follows it.")
                    .accessibilityIdentifier(AccessibilityID.Popover.overrideSaveAsDefault(target))
            }
            .controlSize(.small)
            .buttonStyle(.bordered)
            .padding(.top, 6)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 10)
    }

    /// A compact popup that shows the value without being opened (R12), with
    /// the inherited value as the first choice rather than a blank.
    private func control(
        _ label: String,
        values: [String],
        selection: Binding<String?>,
        inherited: String?,
        names: [String: String] = [:],
        id: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Picker(label, selection: selection) {
                Text(inherited.map { "Inherit (\(names[$0] ?? $0))" } ?? "Inherit")
                    .tag(String?.none)
                ForEach(values, id: \.self) { value in
                    Text(names[value] ?? value).tag(String?.some(value))
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityIdentifier(id)
        }
    }

    /// The advisor is three states, not two: inherit, off, or a model. The off
    /// choice only exists when the agent's manifest declares how to turn it off.
    private func advisorControl(_ values: [String]) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text("Advisor")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Picker("Advisor", selection: $oneShot.advisor) {
                Text(inheritedAdvisorLabel).tag(AdvisorSetting?.none)
                if options.canDisableAdvisor {
                    Text("Off").tag(AdvisorSetting?.some(.off))
                }
                ForEach(values, id: \.self) { value in
                    Text(value).tag(AdvisorSetting?.some(.model(value)))
                }
            }
            .labelsHidden()
            .controlSize(.small)
            .accessibilityIdentifier(AccessibilityID.Popover.overrideAdvisor(target))
        }
    }

    private var inheritedAdvisorLabel: String {
        switch effective.advisor {
        case .none: return "Inherit"
        case .off: return "Inherit (off)"
        case .model(let model): return "Inherit (\(model))"
        }
    }
}
