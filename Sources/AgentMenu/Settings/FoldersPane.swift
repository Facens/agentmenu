// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import SwiftUI
import AgentMenuKit

/// Add, edit, reorder and remove launch targets.
///
/// One tab per account, because the account is the thing a folder must not be
/// wrong about: a work folder launched on the personal account is the mistake
/// this app exists to prevent, and a flat list with an Account column made
/// that a value to read rather than a place to stand. Filtering by account
/// also retires the column — which is what lets the list be a `List` and
/// therefore drag-reorderable, the affordance the design mockup captioned and
/// the shipped `Table` could not offer.
struct FoldersPane: View {
    @ObservedObject var model: SettingsModel
    let options: (Preset) -> PresetOptions

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            accountTabs
            // A split, not a stack: the list and the form both want height,
            // the form is taller than any window height chosen up front, and
            // a stack resolved that by clipping whichever lost. The divider
            // hands that choice to the person who knows which half they are
            // working in.
            VSplitView {
                list
                    .frame(minHeight: 150)
                    .padding(.bottom, 8)
                detail
                    .frame(minHeight: 180)
                    .padding(.top, 8)
            }
        }
        .padding(20)
    }

    // MARK: Accounts

    /// A segmented control while the accounts fit across it, a pop-up button
    /// once they do not. A segmented control divides its width by the number
    /// of segments, so past a handful every label truncates to nothing and the
    /// control stops naming what it selects.
    @ViewBuilder
    private var accountTabs: some View {
        let tabs = model.accountTabs
        let picker = Picker("Account", selection: $model.folderAccountTab) {
            ForEach(tabs, id: \.self) { tab in
                Text(model.accountTabTitle(tab))
                    .tag(tab)
                    .accessibilityIdentifier(AccessibilityID.Settings.Folders.accountTab(Self.tabID(tab)))
            }
        }
        .labelsHidden()
        // Two styles, not one style computed: `pickerStyle` is typed on the
        // style, so the choice has to be made in the view tree rather than in
        // the argument.
        Group {
            if tabs.count > 4 {
                picker.pickerStyle(.menu)
            } else {
                // Sized to its labels. Stretched across the pane, two accounts
                // become two half-window slabs — the control stops reading as
                // a row of tabs and starts reading as the pane's title.
                picker.pickerStyle(.segmented)
            }
        }
        .fixedSize()
        .frame(maxWidth: .infinity, alignment: .center)
    }

    // MARK: The list

    private var list: some View {
        VStack(alignment: .leading, spacing: 7) {
            List(selection: $model.selectedFolder) {
                ForEach(model.visibleFolders, id: \.id) { folder in
                    row(folder)
                }
                .onMove { source, destination in
                    model.moveVisibleFolders(from: source, to: destination)
                }
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
            // Flexible, not pinned: the window is resizable now, and a fixed
            // height would hand every extra point to the detail form and none
            // to the list the user is dragging rows around in.
            .frame(minHeight: 140, maxHeight: .infinity)

            if model.visibleFolders.isEmpty {
                Text("No folders on this account yet. Add one with +.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Button {
                    chooseFolder()
                } label: {
                    Image(systemName: "plus")
                }
                .help("Add a folder to this account")
                .accessibilityIdentifier(AccessibilityID.Settings.Folders.add)

                Button {
                    model.removeSelectedFolder()
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(model.folderIndex == nil)
                .help("Remove the selected folder")
                .accessibilityIdentifier(AccessibilityID.Settings.Folders.remove)

                Button {
                    model.duplicateSelectedFolder()
                } label: {
                    Image(systemName: "plus.square.on.square")
                }
                .disabled(model.folderIndex == nil)
                .help("Add another entry for the same folder, preset and all")
                .accessibilityIdentifier(AccessibilityID.Settings.Folders.duplicate)

                Text("Drag to reorder. The order here is the order in the menu.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .layoutPriority(-1)
                Spacer(minLength: 0)
            }
            .controlSize(.small)

            if let failure = model.failure {
                Text(failure)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ folder: FolderTarget) -> some View {
        HStack(spacing: 6) {
            if !model.exists(folder) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("This folder no longer exists.")
            }
            Text(folder.label.isEmpty ? folder.path : folder.label)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            // The middle of a deep path is the part that repeats; the head
            // says which account's storage it is under and the tail says which
            // folder it is, and both matter more than what sits between them.
            Text(PathDisplay.abbreviated(folder.path))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(folder.path)
                .layoutPriority(-1)
        }
        .accessibilityIdentifier(AccessibilityID.Settings.Folders.row(folder))
    }

    // MARK: The detail form

    @ViewBuilder
    private var detail: some View {
        if let index = model.folderIndex {
            form(index: index)
        } else {
            Text("Select a folder to edit it, or add one.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
        }
    }

    private func form(index: Int) -> some View {
        Form {
            Section {
                TextField("Label", text: $model.config.folders[index].label)
                    .accessibilityIdentifier(AccessibilityID.Settings.Folders.detailLabel)
                LabeledContent("Folder") {
                    HStack {
                        Text(abbreviate(model.config.folders[index].path))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(model.config.folders[index].path)
                        Spacer(minLength: 8)
                        Button("Choose…") { chooseFolder(replacing: index) }
                            .controlSize(.small)
                            .fixedSize()
                            .accessibilityIdentifier(AccessibilityID.Settings.Folders.detailChooseFolder)
                    }
                }
                // The inherit option is a real value, not a placeholder: an
                // entry with no account of its own launches on whichever
                // account the menu's header shows (R42), and the picker used
                // to display the first profile's name for that case while
                // storing nothing — so a folder the user believed was pinned
                // to an account followed the header instead, into a different
                // CLAUDE_CONFIG_DIR.
                Picker("Account", selection: Binding<String?>(
                    get: { model.config.folders[index].profileID },
                    set: { newValue in
                        model.config.folders[index].profileID = newValue
                        // Changing the account moves the folder to another
                        // tab. Following it there keeps the form editing what
                        // the user is looking at, instead of the row vanishing
                        // from under the cursor.
                        model.showTab(for: model.config.folders[index])
                    }
                )) {
                    Text(Self.inheritedAccountLabel).tag(String?.none)
                    ForEach(model.config.profiles, id: \.id) { profile in
                        Text(profile.name.isEmpty ? profile.id : profile.name).tag(String?.some(profile.id))
                    }
                }
                .accessibilityIdentifier(AccessibilityID.Settings.Folders.detailAccountPicker)
            }
            Section {
                PresetEditor(
                    preset: $model.config.folders[index].preset,
                    // The folder's own effective preset decides which agent's
                    // capabilities are on offer here.
                    options: options(model.config.defaults.overlaid(with: model.config.folders[index].preset)),
                    inherited: model.config.defaults,
                    showsTerminal: false,
                    // Distinguishes this Model/Effort/… picker from the one
                    // DefaultsPane shows for the same fields — one `Preset`
                    // form, two identifier scopes.
                    idScope: "folders.preset"
                )
            } header: {
                Text("Preset")
            } footer: {
                Text("Anything left on Inherit follows the global default.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    static let inheritedAccountLabel = "Follows the menu"

    /// `SettingsModel.AccountTab` flattened to the string the identifier
    /// builder wants — a profile id or the literal `"unassigned"`, never
    /// free text, since a profile id is one of `Config.swift`'s own stable
    /// ids (see the comment on `AccessibilityID.Settings.Folders.accountTab`).
    private static func tabID(_ tab: SettingsModel.AccountTab) -> String {
        switch tab {
        case .profile(let id): return id
        case .unassigned: return "unassigned"
        }
    }

    private func abbreviate(_ path: String) -> String { PathDisplay.abbreviated(path) }

    private func chooseFolder(replacing index: Int? = nil) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let index {
            model.config.folders[index].path = PathDisplay.abbreviated(url.path)
        } else {
            model.addFolder(path: PathDisplay.abbreviated(url.path))
        }
    }
}
