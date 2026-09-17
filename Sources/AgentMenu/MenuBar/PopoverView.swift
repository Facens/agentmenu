// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

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
                    Text(profile.name.isEmpty ? profile.id : profile.name).tag(profile.id)
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
            }
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

    private var footer: some View {
        HStack(spacing: 10) {
            Text("AgentMenu \(agentMenuVersion)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer()
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
