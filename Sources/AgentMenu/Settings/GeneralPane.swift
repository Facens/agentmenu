// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AgentMenuKit

/// The General tab: whether this copy starts with the Mac, and what it does
/// about its own updates (U11 / R13).
///
/// Two toggles that look alike and are stored in two different places, on
/// purpose. Automatic checking is Sparkle's own preference, read and written
/// straight through the updater — copying it into `config.toml` would make
/// two settings out of one (KTD8). The beta channel is not Sparkle's: it
/// persists no channel preference at all, so `[updates] beta` in
/// `config.toml` is the only copy of that answer and this pane is where it
/// is set.
struct GeneralPane: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $model.launchAtLogin)
                    .accessibilityIdentifier(AccessibilityID.Settings.launchAtLogin)
            }

            Section("Updates") {
                if let refusal = model.updater.refusal {
                    // A disabled toggle with no explanation reads as a bug.
                    // This says which of the three reasons applies, in the
                    // words UpdatePolicy already uses.
                    Text("Updates are off: \(refusal.description).")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier(AccessibilityID.Settings.Updates.unavailable)
                }

                Toggle("Check for updates automatically", isOn: $model.automaticUpdateChecks)
                    .accessibilityIdentifier(AccessibilityID.Settings.Updates.automatic)

                Toggle("Receive beta updates", isOn: $model.betaUpdates)
                    .accessibilityIdentifier(AccessibilityID.Settings.Updates.beta)

                HStack {
                    Button("Check Now") { model.updater.checkForUpdates() }
                        .accessibilityIdentifier(AccessibilityID.Settings.Updates.checkNow)
                    if let last = model.updater.lastUpdateCheckDate {
                        Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened))")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                }
            }
            .disabled(model.updater.refusal != nil)

            Section {
                Text("AgentMenu \(agentMenuVersion)")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }
}
