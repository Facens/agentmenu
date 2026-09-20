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
        // The identifier goes on the `Label` inside `.tabItem`, not on the
        // pane, because that is what a click has to land on to switch tabs.
        // It deliberately does NOT also go on the pane's own content: only
        // the selected tab's pane is in the tree at a time, so tagging both
        // the tab button and its pane with the same string would put two
        // elements under one identifier the moment that tab is showing.
        // Whether AppKit's tab control exposes the `Label`'s identifier at
        // all is unverified — the same open question as the profile switch's
        // per-segment labels in `PopoverView.swift`, and one more thing the
        // deferred probe (U5's "Execution note") has to answer on the built
        // app before U9 can rely on it.
        TabView {
            FoldersPane(model: model, options: options)
                .tabItem { tabLabel("Folders", "folder", "folders") }
            DefaultsPane(model: model, options: options)
                .tabItem { tabLabel("Defaults", "slider.horizontal.3", "defaults") }
            ProfilesPane(model: model)
                .tabItem { tabLabel("Accounts", "person.crop.circle", "accounts") }
            AgentsPane(model: model, registry: registry, resolveBinary: resolveBinary)
                .tabItem { tabLabel("Agents", "terminal", "agents") }
        }
        // A minimum, not a size. The panes hold paths, and a path under
        // CloudStorage is longer than any width chosen up front — a window
        // that cannot grow turns that into a clipped label with nowhere to go.
        .frame(minWidth: 720, minHeight: 560)
    }

    private func tabLabel(_ title: String, _ systemImage: String, _ name: String) -> some View {
        Label(title, systemImage: systemImage)
            .accessibilityIdentifier(AccessibilityID.Settings.tab(name))
    }
}
