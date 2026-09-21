// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import AgentMenuKit

/// The dropdown.
///
/// Fixed chrome, one scrolling list (R38): the header, the rate-limit strip,
/// the Finder row and the footer stay put while only the folder list scrolls,
/// and the whole popover is capped against the screen so ten folders and an
/// open panel cannot push the actions out of reach (R29).
struct PopoverView: View {
    @ObservedObject var model: PopoverModel
    @ObservedObject var setup: SetupModel
    /// Closes the popover. The host owns the window, so dismissal is a call
    /// rather than an environment action.
    let close: () -> Void
    @Environment(\.colorScheme) private var scheme

    private let width: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            profileSwitch
            usage
            // In the fixed chrome, above the scrolling list, and not
            // dismissible: it is the reason updates are silently not
            // arriving, and a banner the user can close is a banner they
            // close once and never think about again (R26).
            if model.isTranslocated {
                translocationBanner
            }
            finderRow
            if setup.isNeeded {
                SetupCard(model: setup, done: {})
            } else {
                list
            }
            footer
        }
        .frame(width: width)
        .confirmationDialog(
            "Save these values as the global default?",
            isPresented: Binding(
                get: { model.pendingGlobalSave != nil },
                set: { if !$0 { model.pendingGlobalSave = nil } }
            )
        ) {
            Button("Save as default") { model.confirmGlobalSave() }
            Button("Cancel", role: .cancel) { model.pendingGlobalSave = nil }
        } message: {
            Text("Every folder that does not override these fields will follow the new default.")
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(spacing: 8) {
            BrandMark()
            Text("AgentMenu")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button {
                AppDelegate.shared?.showSettings()
                close()
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Open AgentMenu settings")
            .accessibilityIdentifier(AccessibilityID.Popover.gear)
        }
        .padding(.horizontal, 12)
        .padding(.top, 11)
        .padding(.bottom, 8)
    }

    /// Hidden entirely when there is only one profile (R16).
    @ViewBuilder
    private var profileSwitch: some View {
        if model.showsProfileSwitch {
            let picker = Picker("Profile", selection: Binding(
                get: { model.activeProfileID ?? model.config.profiles.first?.id ?? "" },
                set: { model.setActiveProfile($0) }
            )) {
                ForEach(model.config.profiles, id: \.id) { profile in
                    // Applied to the label rather than to the Picker as a
                    // whole, on the theory that a segmented control turns
                    // each option into its own AX element and the label
                    // inside it is what carries the identifier through to
                    // that segment — unverified: this is exactly the kind of
                    // question the deferred probe (U5's "Execution note")
                    // answers on the built app, not something a typecheck
                    // can confirm. If the probe finds this does not reach
                    // System Events, `.menu` style (the >3-profile case just
                    // below) is the more likely one to work, since it is a
                    // real NSMenu with real NSMenuItems.
                    Text(profile.name.isEmpty ? profile.id : profile.name)
                        .tag(profile.id)
                        .accessibilityIdentifier(AccessibilityID.Popover.profile(profile.id))
                }
            }
            .labelsHidden()

            // Segmented while the names fit in 400pt, a pop-up button once
            // they do not: a segmented control splits its width evenly, so
            // past three accounts every label truncates and the control stops
            // saying which account is active — the one thing it exists to say.
            Group {
                if model.config.profiles.count > 3 {
                    picker.pickerStyle(.menu)
                } else {
                    picker.pickerStyle(.segmented)
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 10)
        }
    }

    @ViewBuilder
    private var usage: some View {
        let strip = UsageStrip(reading: model.usageReading, projector: model.usageProjector)
        if case .available = model.usageReading {
            strip
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private var finderRow: some View {
        Group {
            if let target = model.finderTarget {
                targetCard(target)
            } else {
                HStack(spacing: 9) {
                    Image(systemName: "folder")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    Text("No Finder window open on a folder")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 10)
                .frame(height: 34)
                .cardSurface()
            }
        }
        .padding(.horizontal, 12)
        .padding(.bottom, 10)
    }

    private func targetCard(_ target: LaunchTarget) -> some View {
        // Only ever called for the Finder target (see `finderRow` below) — a
        // second real row, outside the `FolderRow` list, with the same two
        // controls a scenario needs from any row: launch and expand.
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "folder")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.brandAccent(scheme))
                Button { launch(target) } label: {
                    HStack(spacing: 8) {
                        Text(target.label).lineLimit(1)
                        if model.launching == target.id {
                            ProgressView().controlSize(.mini).scaleEffect(0.6)
                        }
                        Spacer(minLength: 8)
                        Text(PathDisplay.abbreviated(target.path))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.head)
                            .layoutPriority(0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.Popover.rowLaunch(target))
                if model.state(for: target).bypasses {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.brandWarning(scheme))
                }
                Button { model.toggleExpanded(target) } label: {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(model.isExpanded(target) ? 90 : 0))
                        .frame(width: 16, height: 22)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier(AccessibilityID.Popover.rowExpand(target))
            }
            .accessibilityElement(children: .contain)
            .padding(.horizontal, 10)
            .frame(height: 34)

            if model.isExpanded(target) {
                Divider().padding(.leading, 10)
                disclosure(target)
            }
        }
        .cardSurface()
    }

    // MARK: The one scrolling region

    /// `$HOME` alone is the empty state, not a configured launcher (R48).
    private var hasOnlyHome: Bool {
        targets.allSatisfy { $0.kind != .folder }
    }

    /// The folder a drop would land before, while a drag is over it.
    @StateObject private var dropTarget = DropTargetState()
    private var dropTargetID: String? {
        get { dropTarget.id }
        nonmutating set { dropTarget.id = newValue }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text("Projects")
                    .font(.system(size: 10, weight: .semibold))
                    .kerning(0.6)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("click to launch · › for options")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 4)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(targets) { target in
                            let state = model.state(for: target)
                            VStack(alignment: .leading, spacing: 0) {
                                FolderRow(
                                    target: target,
                                    effective: state.resolved.preset,
                                    options: state.options,
                                    overridden: state.overridden,
                                    bypasses: state.bypasses,
                                    isExpanded: model.isExpanded(target),
                                    isLaunching: model.launching == target.id,
                                    isDraggable: model.canReorder(target),
                                    subtitle: target.kind == .home ? PathDisplay.abbreviated(target.path) : nil,
                                    setModel: { model.setOneShotModel($0, for: target) },
                                    setEffort: { model.setOneShotEffort($0, for: target) },
                                    launch: { launch(target) },
                                    toggle: {
                                        model.toggleExpanded(target)
                                        // R39: the target's own actions come into view with it.
                                        if model.isExpanded(target) {
                                            withAnimation { proxy.scrollTo(target.id, anchor: .bottom) }
                                        }
                                    }
                                )
                                if model.isExpanded(target) {
                                    disclosure(target, state: state)
                                        .background(
                                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                                .fill(Color.primary.opacity(scheme == .dark ? 0.05 : 0.035))
                                        )
                                }
                            }
                            .id(target.id)
                            // A line above the row the drop would land on,
                            // drawn in the row's own padding so nothing moves
                            // while the pointer travels.
                            .overlay(alignment: .top) {
                                if dropTargetID == target.folderID, target.folderID != nil {
                                    Rectangle()
                                        .fill(Color.brandAccent(scheme))
                                        .frame(height: 2)
                                }
                            }
                            .dropDestination(for: String.self) { ids, _ in
                                guard let dragged = ids.first, let destination = target.folderID else { return false }
                                model.moveFolder(dragged, before: destination)
                                return true
                            } isTargeted: { targeted in
                                dropTargetID = targeted ? target.folderID : nil
                            }
                        }
                    }
                    .padding(.horizontal, 8)
                }
                // A ScrollView takes whatever height it is offered, so a
                // maximum alone makes four folders sit in a 320pt box that
                // scrolls for no reason. It gets the height of its content,
                // capped (R29, R38).
                .frame(height: min(listContentHeight, 320))
            }

            if let failure = model.failure {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(Color.brandWarning(scheme))
                    Text(failure)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 16)
                .padding(.top, 6)
            }
        }
    }

    /// Rows are a fixed height, and an open panel adds a known block — enough
    /// to size the list without measuring it.
    private var listContentHeight: CGFloat {
        let rows = CGFloat(targets.count) * 30
        let panel: CGFloat = model.expandedTargetID == nil ? 0 : 210
        return max(30, rows + panel)
    }

    /// The configured folders plus `$HOME`, which is a target from the first
    /// run, before any configuration exists (R3).
    private var targets: [LaunchTarget] {
        var targets = model.folderTargets
        if !targets.contains(where: { $0.path == model.homeTarget.path }) {
            targets.append(model.homeTarget)
        }
        return targets
    }

    private func disclosure(_ target: LaunchTarget, state: PopoverModel.TargetState? = nil) -> some View {
        let state = state ?? model.state(for: target)
        return OverrideDisclosure(
            target: target,
            effective: model.effectivePreset(for: target),
            options: state.options,
            oneShot: Binding(
                get: { model.oneShotPreset(for: target) },
                set: { model.setOneShot($0, for: target) }
            ),
            launch: { launch(target) },
            openTerminal: {
                Task { if await model.openTerminal(target) { close() } }
            },
            saveToFolder: { model.saveToFolder(target) },
            saveAsDefault: { model.requestGlobalSave(target) }
        )
    }

    /// The app is running from Gatekeeper's randomized read-only copy.
    /// Naming the fix rather than the symptom: "move it to Applications" is
    /// the whole remedy, and it is the same sentence the README opens with.
    private var translocationBanner: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("AgentMenu is running from a temporary copy. Move it to your Applications folder — until you do, it cannot update itself and the status-line bridge cannot be installed.")
                .font(.system(size: 11))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .accessibilityIdentifier(AccessibilityID.Popover.translocationBanner)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Text("AgentMenu \(agentMenuVersion)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
            // R13: the manual check, beside the version it would replace.
            // Sparkle's own window opening over this popover does not
            // dismiss it — the popover is .applicationDefined, which is
            // also why AgentMenu can carry menus inside it.
            if model.canCheckForUpdates {
                Button(model.updatePending ? "Install Update…" : "Check for Updates") {
                    model.checkForUpdates()
                }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .accessibilityIdentifier(AccessibilityID.Popover.checkForUpdates)
            }
            // The plan's footer has carried "Settings, Quit" since the
            // layout diagram, and the mockup puts Quit here, rightmost.
            // Without it an accessory app has no way out at all: no Dock
            // icon to right-click, no main menu, so no Cmd-Q — only Force
            // Quit or Activity Monitor.
            //
            // `NSApp.terminate` rather than `exit`: termination is what
            // runs `applicationWillTerminate`, and that is where the
            // pending save is flushed. A preset changed a moment before
            // this click is at most 0.4 s from being written, and exiting
            // under it would lose the change silently.
            Button("Quit") { NSApp.terminate(nil) }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .help("Quit AgentMenu")
                .accessibilityIdentifier(AccessibilityID.Popover.quit)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .overlay(alignment: .top) {
            Divider().padding(.horizontal, 12)
        }
    }

    /// A successful launch closes the popover; a failure leaves it open with
    /// the reason (R41).
    private func launch(_ target: LaunchTarget) {
        Task { if await model.launch(target) { close() } }
    }
}

/// One optional id. An object rather than `@State`, which the SwiftUI in the
/// macOS 26 SDK declares as a macro whose plugin ships only with Xcode — see
/// the comment on `FolderRow.hover`.
final class DropTargetState: ObservableObject {
    @Published var id: String?
}
