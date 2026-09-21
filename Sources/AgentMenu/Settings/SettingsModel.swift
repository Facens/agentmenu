// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Combine
import Foundation
import SwiftUI
import AgentMenuKit

/// The settings window's state.
///
/// It edits a copy of the configuration and writes through on every change, so
/// the popover and the settings window cannot drift apart while both are open.
@MainActor
final class SettingsModel: ObservableObject {
    /// A window onto the one configuration, not a copy of it. Writing through
    /// here is what keeps the settings window and the popover from disagreeing
    /// — and what stops an edit made here from saving a configuration captured
    /// at launch.
    var config: Config {
        get { environment.config }
        set { environment.update { $0 = newValue } }
    }

    /// Sparkle's own preference, not a copy of it: read and written through
    /// the updater so the window and Sparkle cannot disagree (KTD8). The
    /// `objectWillChange` is manual because the value lives in Sparkle, not
    /// in a `@Published` here — nothing else would tell the view it moved.
    var automaticUpdateChecks: Bool {
        get { updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// The login item. Not a stored preference: `SMAppService` is the only
    /// copy of this answer, the same way Sparkle owns the automatic-check
    /// preference above (KTD8), and the user can turn it off in System
    /// Settings without this app hearing about it. So it is read back on
    /// every access, and the write re-reads it — a refusal (an ad-hoc build,
    /// a translocated copy) then shows as the toggle sliding back rather
    /// than as a switch that lies.
    var launchAtLogin: Bool {
        get { LaunchAtLogin.isEnabled }
        set {
            objectWillChange.send()
            LaunchAtLogin.set(newValue)
        }
    }

    /// `[updates] beta` in config.toml, which is the only copy of this
    /// answer — Sparkle persists no channel preference (KTD20).
    /// Shows the preference as it stands — the user's choice, or the
    /// default this build implies — and writes a decision the moment the
    /// toggle moves, which is what turns nil into a stored value.
    var betaUpdates: Bool {
        get { UpdatePolicy.betaEnabled(preference: config.betaUpdates, version: agentMenuVersion) }
        set { config.betaUpdates = newValue }
    }

    var updater: UpdaterController { environment.updater }

    @Published var selectedFolder: String?
    @Published var selectedProfile: String?
    @Published var failure: String?
    /// What the last status-line bridge install reported, per account, so the
    /// Accounts pane can show the CLI's own account of the file and key it
    /// touched next to the button that asked for it.
    @Published var bridgeInstallReport: [String: String] = [:]
    /// Which account's folders the Folders pane is showing. Stored here
    /// rather than in the view so it survives the view being rebuilt — which
    /// it is on every edit, since `config` writes through.
    @Published var folderAccountTab: AccountTab = .unassigned {
        didSet { reconcileFolderSelection() }
    }

    private unowned let environment: AppEnvironment
    private var cancellables: Set<AnyCancellable> = []

    init(environment: AppEnvironment) {
        self.environment = environment
        self.selectedFolder = environment.config.folders.first?.id
        self.selectedProfile = environment.config.profiles.first?.id
        // Open on the tab that actually holds the first folder, so the pane
        // never opens on an account with nothing in it.
        if let first = environment.config.folders.first {
            self.folderAccountTab = first.profileID.map(AccountTab.profile) ?? .unassigned
        } else if let profile = environment.config.profiles.first {
            self.folderAccountTab = .profile(profile.id)
        }
        // `config` is computed, so the views watching this object have to be
        // told when the thing it reads through changes.
        environment.$config
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        environment.$saveFailure
            .sink { [weak self] failure in if let failure { self?.failure = failure } }
            .store(in: &cancellables)
    }

    // MARK: Folders

    /// One tab per account, plus the one for folders that pin no account at
    /// all. Unpinned is a real state, not an empty case: such a folder
    /// launches on whichever account the menu header shows, so it has to be
    /// reachable somewhere, and putting it under an account it does not
    /// actually name would be a lie the user could not see.
    enum AccountTab: Hashable {
        case profile(String)
        case unassigned
    }

    /// The tabs to show, in profile order, with Unassigned last and only when
    /// something is actually unassigned — an empty tab teaches nothing.
    var accountTabs: [AccountTab] {
        var tabs = config.profiles.map { AccountTab.profile($0.id) }
        if config.folders.contains(where: { $0.profileID == nil }) || folderAccountTab == .unassigned {
            tabs.append(.unassigned)
        }
        return tabs
    }

    func accountTabTitle(_ tab: AccountTab) -> String {
        switch tab {
        case .unassigned:
            return "Unassigned"
        case .profile(let id):
            guard let profile = config.profile(id: id) else { return id }
            return profile.name.isEmpty ? profile.id : profile.name
        }
    }

    /// The positions in `config.folders` — the real array, not a filtered copy
    /// — of the folders the current tab shows, in menu order. Every mutation
    /// the pane performs goes through these, because an index taken from a
    /// filtered list addresses a different folder in the array it is written
    /// back to.
    var visibleFolderIndices: [Int] {
        config.folders.indices.filter { index in
            switch folderAccountTab {
            case .unassigned: return config.folders[index].profileID == nil
            case .profile(let id): return config.folders[index].profileID == id
            }
        }
    }

    var visibleFolders: [FolderTarget] { visibleFolderIndices.map { config.folders[$0] } }

    /// Keeps the selection inside the tab being shown: a folder selected on
    /// one account is not the folder the detail form should be editing after
    /// switching to another.
    func reconcileFolderSelection() {
        let visible = visibleFolders
        if let selected = selectedFolder, visible.contains(where: { $0.id == selected }) { return }
        selectedFolder = visible.first?.id
    }

    /// Puts the tab on the account the given folder belongs to, so a folder
    /// that was just added or duplicated is visible rather than filtered away.
    func showTab(for folder: FolderTarget) {
        folderAccountTab = folder.profileID.map(AccountTab.profile) ?? .unassigned
    }

    var folderIndex: Int? {
        guard let selected = selectedFolder else { return nil }
        return config.folders.firstIndex { $0.id == selected }
    }

    /// A folder already in the list is added again rather than refused: two
    /// entries for one folder, differing in an account or a model, is a thing
    /// people want — it is what the duplicate button is for — and each entry
    /// carries its own id, so nothing collides.
    func addFolder(path: String) {
        var candidate = FolderTarget(label: (path as NSString).lastPathComponent, path: path)
        // Added from a tab that names an account, the new folder gets that
        // account — adding on the Personal tab and having the entry land
        // somewhere else would be the pane lying about what it is showing.
        if case .profile(let id) = folderAccountTab { candidate.profileID = id }
        config.folders.append(candidate)
        selectedFolder = candidate.id
        failure = nil
    }

    func removeSelectedFolder() {
        guard let index = folderIndex else { return }
        config.folders.remove(at: index)
        selectedFolder = nil
        reconcileFolderSelection()
    }

    /// Duplicating keeps the folder and the preset and changes only the id:
    /// the copy exists to have one value changed on it — the account, or the
    /// model — and asking for a different folder first would defeat that.
    func duplicateSelectedFolder() {
        guard let index = folderIndex else { return }
        let original = config.folders[index]
        let copy = FolderTarget(
            label: original.label.isEmpty ? original.label : "\(original.label) copy",
            path: original.path,
            preset: original.preset
        )
        config.folders.insert(copy, at: index + 1)
        selectedFolder = copy.id
        failure = nil
    }

    /// Reorders the folders the current tab is showing.
    ///
    /// `source` and `destination` are offsets into the *visible* list, and
    /// `config.folders` holds every account's folders in one array, so the
    /// offsets cannot be passed to `move(fromOffsets:toOffset:)` directly —
    /// doing that reorders whichever folders happen to sit at those positions
    /// globally, silently and invisibly. Instead the visible entries are
    /// permuted among the array slots they already occupy, which leaves every
    /// folder this tab is not showing exactly where it was.
    func moveVisibleFolders(from source: IndexSet, to destination: Int) {
        let slots = visibleFolderIndices
        guard !slots.isEmpty else { return }
        var permuted = slots
        permuted.move(fromOffsets: source, toOffset: destination)
        let reordered = permuted.map { config.folders[$0] }
        var folders = config.folders
        for (slot, folder) in zip(slots, reordered) { folders[slot] = folder }
        config.folders = folders
    }

    /// A folder whose path no longer exists is marked and stays editable — it is
    /// never dropped behind the user's back.
    func exists(_ folder: FolderTarget) -> Bool {
        FileManager.default.fileExists(atPath: folder.expandedPath.path)
    }

    // MARK: Profiles

    /// R47: the one write into an agent's configuration directory the app
    /// ever asks for. The bundled CLI does the writing and names what it
    /// changes; this runs it for the chosen account, off the main actor,
    /// and keeps its answer. The pane shows "Installing…" until it lands.
    func installStatusLineBridge(profileID: String) {
        guard let profile = config.profile(id: profileID) else { return }
        bridgeInstallReport[profileID] = "Installing…"
        Task.detached(priority: .userInitiated) {
            let report = AppEnvironment.installStatusLine(for: profile)
            await MainActor.run { self.bridgeInstallReport[profileID] = report }
        }
    }

    func addProfile() {
        let base = "profile"
        var id = base
        var suffix = 2
        while config.profiles.contains(where: { $0.id == id }) {
            id = "\(base)-\(suffix)"
            suffix += 1
        }
        config.profiles.append(Profile(id: id, name: "New profile", configDirectory: "~/.claude"))
        selectedProfile = id
    }

    /// Removing a profile that folders still point at would leave those folders
    /// pointing at nothing, so the folders are reassigned to the first
    /// remaining profile instead.
    func removeProfile(id: String) {
        guard config.profiles.count > 1 else {
            failure = "At least one profile has to exist."
            return
        }
        config.profiles.removeAll { $0.id == id }
        let fallback = config.profiles.first?.id
        for index in config.folders.indices where config.folders[index].profileID == id {
            config.folders[index].profileID = fallback
        }
        if config.activeProfileID == id { config.activeProfileID = fallback }
        // The Folders pane may be standing on the tab that just stopped
        // existing. Left alone, its picker holds a selection no tab matches,
        // the list filters to nothing, and the pane offers no way back.
        if folderAccountTab == .profile(id) {
            folderAccountTab = fallback.map(AccountTab.profile) ?? .unassigned
        }
        selectedProfile = fallback
    }

}
