// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import SwiftUI
import AgentMenuKit

/// The settings window's content.
///
/// Content only, deliberately: the scene that presents it lives in
/// `AgentMenuApp`, so swapping the `Settings` scene for an explicitly managed
/// `NSWindow` — should the activation behaviour require it — changes one call
/// site and nothing in here.
struct SettingsWindow: View {
    @ObservedObject var model: SettingsModel
    let registry: ManifestRegistry
    /// Asked per preset rather than once: a folder can override the agent, and
    /// a different agent declares different model, effort and permission values.
    /// One snapshot taken from the global default would show the wrong lists on
    /// exactly the folder that customised the most.
    let options: (Preset) -> PresetOptions
    let resolveBinary: (String) -> String?

    var body: some View {
        TabView {
            FoldersPane(model: model, options: options)
                .tabItem { Label("Folders", systemImage: "folder") }
            DefaultsPane(model: model, options: options)
                .tabItem { Label("Defaults", systemImage: "slider.horizontal.3") }
            ProfilesPane(model: model)
                .tabItem { Label("Accounts", systemImage: "person.crop.circle") }
            AgentsPane(model: model, registry: registry, resolveBinary: resolveBinary)
                .tabItem { Label("Agents", systemImage: "terminal") }
        }
        // A minimum, not a size. The panes hold paths, and a path under
        // CloudStorage is longer than any width chosen up front — a window
        // that cannot grow turns that into a clipped label with nowhere to go.
        .frame(minWidth: 720, minHeight: 560)
    }
}
