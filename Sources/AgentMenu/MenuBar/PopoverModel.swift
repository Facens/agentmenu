// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import Combine
import Foundation
import SwiftUI
import AgentMenuKit

/// What the popover can ask the rest of the app to do.
///
/// The views never build a command themselves: AgentMenuKit owns that, and this
/// protocol is the seam, so the popover can be exercised without a terminal or
/// an agent binary present.
@MainActor
protocol LaunchServicing {
    /// Starts an agent session. Throws with a reason the popover shows (R6).
    ///
    /// `async` because it spawns a process and waits for the answer, and the
    /// caller is the main thread: waiting there froze the popover for as long
    /// as the terminal took to reply — up to the whole wait cap, with the
    /// window drawn but dead under the pointer.
    func launch(target: LaunchTarget, profileID: String?, oneShot: Preset) async throws
    /// Opens a plain terminal in the folder, starting no agent (R5).
    func openTerminal(target: LaunchTarget, oneShot: Preset) async throws
    /// The three layers merged and checked against the agent's manifest. The
    /// popover shows exactly what a launch would use, because it asks the same
    /// resolver the launch does.
    func resolvedPreset(for target: LaunchTarget, oneShot: Preset) -> ResolvedPreset
    /// The values the active agent and terminal declare, for the given preset.
    func options(for preset: Preset) -> PresetOptions
    /// The snapshot reading for a profile, or `.unavailable`.
    func usage(forProfile profile: Profile) -> UsageReading
    /// The burn-rate projector for a profile, or nil when there is no history
    /// to project from.
    func projector(forProfile profile: Profile) -> UsageProjector?
}

/// The popover's state.
///
/// Everything the dropdown shows is derived here so the views stay layout only:
/// which profile is active, which target's override panel is open, the one-shot
/// values that have not been saved, and the last failure.
@MainActor
final class PopoverModel: ObservableObject {
    /// A window onto the one configuration (see `AppEnvironment.config`).
    var config: Config { environment.config }
    @Published var activeProfileID: String?
    @Published private(set) var expandedTargetID: String?
    @Published private(set) var finderPath: String?
    @Published private(set) var usageReading: UsageReading = .unavailable
    @Published private(set) var usageProjector: UsageProjector?
    @Published var failure: String?
    /// The target a launch is in flight for, so the row can say so. A launch
    /// is no longer instantaneous from the popover's point of view — it never
    /// was, it just used to block the main thread instead of admitting it.
    @Published private(set) var launching: String?
    @Published var pendingGlobalSave: Preset?

    /// One-shot overrides, keyed by target id. Discarded on launch unless saved (R9).
    @Published private(set) var oneShot: [String: Preset] = [:]

    private unowned let environment: AppEnvironment
    private let service: LaunchServicing
    private var cancellables: Set<AnyCancellable> = []

    init(environment: AppEnvironment, service: LaunchServicing) {
        self.environment = environment
        self.service = service
        self.activeProfileID = environment.config.activeProfileID ?? environment.config.profiles.first?.id
        environment.$config
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // A configuration that could not be written is news here too: the
        // settings window may never have been opened.
        environment.$saveFailure
            .sink { [weak self] failure in if let failure { self?.failure = failure } }
            .store(in: &cancellables)
        // An update that finished downloading while the popover was closed
        // is exactly the case the footer row exists for, so the view has to
        // be told when it lands (R18).
        environment.$updatePending
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
    }

    // MARK: - Updates (U11)

    /// An update is downloaded and waiting for the user to act (R18).
    var updatePending: Bool { environment.updatePending }

    /// Whether this app may update itself at all — false for a local alpha
    /// build and for one that carries no signing key, which is what keeps
    /// the footer from offering a check that can never find anything.
    var canCheckForUpdates: Bool { environment.updater.refusal == nil }

    func checkForUpdates() { environment.updater.checkForUpdates() }

    /// True while Gatekeeper is running this copy from its randomized
    /// read-only mount. Sparkle cannot replace a bundle there, and the
    /// status-line bridge cannot be written from there either (R26) — so
    /// the popover says so, permanently, until the app is moved.
    var isTranslocated: Bool {
        BundleTranslocation.isTranslocated(bundlePath: Bundle.main.bundleURL.path)
    }

    // MARK: Derived state

    /// The profile switch is chrome only when there is something to switch
    /// between (R16).
    var showsProfileSwitch: Bool { config.profiles.count > 1 }

    var activeProfile: Profile? {
        guard let id = activeProfileID else { return config.profiles.first }
        return config.profile(id: id) ?? config.profiles.first
    }

    /// Only the active profile's folders (R17). A folder with no profile of its
    /// own belongs to whichever profile the header shows, so it is never hidden
    /// from every list.
    var folderTargets: [LaunchTarget] {
        let active = activeProfile?.id
        return config.folders
            .filter { $0.profileID == nil || $0.profileID == active }
            .map(LaunchTarget.folder)
    }

    var finderTarget: LaunchTarget? {
        finderPath.map(LaunchTarget.finderWindow)
    }

    var homeTarget: LaunchTarget { .home() }

    func isExpanded(_ target: LaunchTarget) -> Bool { expandedTargetID == target.id }

    /// The saved preset for a target, with the global default under it.
    func effectivePreset(for target: LaunchTarget) -> Preset {
        config.defaults.overlaid(with: target.preset)
    }

    /// What the launch would actually use, including anything typed into the
    /// open override panel — and with any value the agent does not support
    /// already removed, so the row cannot promise a flag that will not be sent.
    func launchPreset(for target: LaunchTarget) -> Preset {
        resolved(for: target).preset
    }

    func resolved(for target: LaunchTarget) -> ResolvedPreset {
        service.resolvedPreset(for: target, oneShot: oneShotPreset(for: target))
    }

    /// Values the active agent's manifest does not declare. Shown rather than
    /// sent (R13).
    func unsupported(for target: LaunchTarget) -> [UnsupportedValue] {
        resolved(for: target).unsupported
    }

    func options(for target: LaunchTarget) -> PresetOptions {
        state(for: target).options
    }

    /// Everything a row needs, resolved once.
    ///
    /// The list body used to ask for the effective preset, the options, the
    /// overridden fields and the bypass flag separately, and each of those
    /// re-ran the three-layer merge and re-walked the manifest registry — four
    /// resolutions and two availability sweeps per row, on every render.
    struct TargetState: Equatable {
        let resolved: ResolvedPreset
        let options: PresetOptions
        let overridden: Set<PresetField>
        let bypasses: Bool
    }

    func state(for target: LaunchTarget) -> TargetState {
        let resolved = self.resolved(for: target)
        let options = service.options(for: resolved.preset)
        let bypasses = resolved.preset.permissionMode.map { options.isBypassing($0) } ?? false
        return TargetState(
            resolved: resolved,
            options: options,
            overridden: overriddenFields(for: target),
            bypasses: bypasses
        )
    }

    /// Which fields this target sets itself — its own preset or the one-shot
    /// layer — rather than inheriting from the global default. The row renders
    /// those in the accent, so a customised target still reads at a glance.
    func overriddenFields(for target: LaunchTarget) -> Set<PresetField> {
        let own = target.preset
        let shot = oneShotPreset(for: target)
        var fields: Set<PresetField> = []
        if own.model != nil || shot.model != nil { fields.insert(.model) }
        if own.effort != nil || shot.effort != nil { fields.insert(.effort) }
        if own.permissionMode != nil || shot.permissionMode != nil { fields.insert(.permissionMode) }
        if own.advisor != nil || shot.advisor != nil { fields.insert(.advisor) }
        if own.agent != nil || shot.agent != nil { fields.insert(.agent) }
        if own.terminal != nil || shot.terminal != nil { fields.insert(.terminal) }
        return fields
    }

    /// Sets one field of the one-shot layer from the row itself, so the two
    /// values that change most often need no disclosure.
    func setOneShotModel(_ value: String?, for target: LaunchTarget) {
        var preset = oneShotPreset(for: target)
        preset.model = value
        setOneShot(preset, for: target)
    }

    func setOneShotEffort(_ value: String?, for target: LaunchTarget) {
        var preset = oneShotPreset(for: target)
        preset.effort = value
        setOneShot(preset, for: target)
    }

    /// R37: marked on the *effective* value, inherited or not. A row that
    /// inherits a bypassing default is exactly the case where showing nothing
    /// would hide the danger.
    func bypasses(_ target: LaunchTarget) -> Bool {
        state(for: target).bypasses
    }

    // MARK: Intents

    /// Refreshes without blocking the popover's first paint.
    ///
    /// Opening a menu-bar popover has to feel instant, so this paints whatever
    /// was already known and replaces it as the answers arrive. The Finder query
    /// is an Apple Event to another process — ~280 ms cold, ~25 ms warm — and
    /// putting it in `onAppear` synchronously is exactly the delay between the
    /// click and the window appearing.
    func refresh() {
        // The configuration has one owner in this process, so there is nothing
        // to re-read from it — only an edit made to the file by hand, which is
        // a stat rather than a parse.
        environment.reloadIfChangedOnDisk()

        FinderTarget.frontWindowPath { [weak self] path in
            self?.finderPath = path
        }

        guard let profile = activeProfile else {
            usageReading = .unavailable
            usageProjector = nil
            return
        }
        usageReading = service.usage(forProfile: profile)
        // Reading and profiling the history is cheap (microseconds for a 28-day
        // file), but it is only needed when the strip is actually shown.
        if case .available = usageReading {
            usageProjector = service.projector(forProfile: profile)
        } else {
            usageProjector = nil
        }
    }

    /// Opening one panel closes any other (R39).
    func toggleExpanded(_ target: LaunchTarget) {
        expandedTargetID = expandedTargetID == target.id ? nil : target.id
    }

    func oneShotPreset(for target: LaunchTarget) -> Preset { oneShot[target.id] ?? Preset() }

    func setOneShot(_ preset: Preset, for target: LaunchTarget) {
        oneShot[target.id] = preset
    }

    /// Returns true when the popover should close (R41).
    func launch(_ target: LaunchTarget) async -> Bool {
        launching = target.id
        defer { launching = nil }
        do {
            try await service.launch(target: target, profileID: profileID(for: target), oneShot: oneShotPreset(for: target))
            oneShot[target.id] = nil
            failure = nil
            return true
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return false
        }
    }

    func openTerminal(_ target: LaunchTarget) async -> Bool {
        launching = target.id
        defer { launching = nil }
        do {
            try await service.openTerminal(target: target, oneShot: oneShotPreset(for: target))
            failure = nil
            return true
        } catch {
            failure = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return false
        }
    }

    // MARK: Reordering

    /// Only a real configured folder can be moved. `$HOME` is synthesised when
    /// nothing in the configuration names it (R48) and the Finder target is
    /// whatever window is in front — neither has a `[[folders]]` entry to
    /// reorder.
    func canReorder(_ target: LaunchTarget) -> Bool { target.folderID != nil }

    /// Puts the dragged folder immediately before `targetFolderID`.
    ///
    /// Matched by id against the real array rather than by offset into the
    /// visible list: the popover shows the folders of one account, which is a
    /// filtered subsequence of `config.folders`, and an offset into it
    /// addresses a different entry in the array it would be written back to.
    /// Working in ids sidesteps the arithmetic entirely — and the folders this
    /// account does not show keep their own relative order, untouched.
    func moveFolder(_ draggedFolderID: String, before targetFolderID: String) {
        guard draggedFolderID != targetFolderID else { return }
        environment.update { config in
            guard let from = config.folders.firstIndex(where: { $0.id == draggedFolderID }) else { return }
            let moved = config.folders.remove(at: from)
            let insertAt = config.folders.firstIndex(where: { $0.id == targetFolderID }) ?? config.folders.count
            config.folders.insert(moved, at: insertAt)
        }
    }

    /// The Finder and home targets launch on the profile the header shows (R42).
    func profileID(for target: LaunchTarget) -> String? {
        target.profileID ?? activeProfileID
    }

    func saveToFolder(_ target: LaunchTarget) {
        guard target.kind == .folder else { return }
        let merged = target.preset.overlaid(with: oneShotPreset(for: target))
        // By id, not by path: two entries may name one folder, and saving an
        // override on the second row must not land on the first.
        guard let id = target.folderID,
              let index = config.folders.firstIndex(where: { $0.id == id }) else { return }
        environment.update { $0.folders[index].preset = merged }
        oneShot[target.id] = nil
    }

    /// Saving to the global default changes every folder that inherits, so it
    /// confirms first (R40). This stages it; the view runs the confirmation.
    func requestGlobalSave(_ target: LaunchTarget) {
        pendingGlobalSave = config.defaults.overlaid(with: launchPreset(for: target))
    }

    func confirmGlobalSave() {
        guard let preset = pendingGlobalSave else { return }
        environment.update { $0.defaults = preset }
        pendingGlobalSave = nil
    }

    func setActiveProfile(_ id: String) {
        activeProfileID = id
        environment.update { $0.activeProfileID = id }   // R43: survives a restart
        refresh()
    }

}
