// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Combine
import Foundation
import AgentMenuKit

/// The app's side of the read-only state hook (KTD3, R13): where the journal
/// is turned on, and every tap that writes to it.
///
/// AgentMenu has no logging layer, so there is nothing to attach a sink to.
/// What there is instead is published state — `AppEnvironment.config` and
/// `saveFailure`, `SetupModel.detecting` — and most of this file is Combine
/// subscriptions onto it. That is deliberate: an observer cannot change what
/// the app does, which is the property R13 asks for, and it keeps the taps out
/// of the models themselves. Only the launch path and the status-line bridge
/// needed a line at the call site, because what they report (the command about
/// to run, the profile just written to) exists nowhere else.
///
/// None of it runs unless the journal is active. A normal launch constructs
/// this object, finds no key, subscribes to nothing and leaves no file behind
/// (AE6).
///
/// **The seam U7 uses.** `activate` takes the defaults domain and the harness
/// directory rather than looking either up, and defaults them to
/// `UserDefaults.standard` and `~/Library/Application Support/
/// dev.facens.agentmenu/harness/`. U7 resolves both per KTD4 — the isolated
/// suite named by `AGENTMENU_DEFAULTS_SUITE`, the directory named by
/// `AGENTMENU_HARNESS_DIR`, both only when `-AgentMenuHarness YES` is in the
/// argument domain — and passes them here, along with the config, manifests
/// and profile roots it resolved, without changing anything in this file or in
/// `Journal`. The argument-domain flag and the environment reads are U7's;
/// this unit deliberately implements neither.
///
/// Not main-actor isolated: `AppEnvironment.installStatusLine(for:)` is
/// `nonisolated static` and journals from whatever thread ran the CLI, so the
/// writer has to be reachable from anywhere. The journal itself is internally
/// locked; this adds one lock of its own around the optional.
final class HarnessJournal: @unchecked Sendable {
    /// One per process, always present and inert until `activate` finds a key.
    /// A static rather than something passed down the app's object graph,
    /// because the taps sit in places — a `nonisolated static` helper, a
    /// `catch` inside an `async` launch — that have nothing else to reach it
    /// through.
    static let shared = HarnessJournal()

    private let lock = NSLock()
    private var journal: Journal?

    /// Main-actor state: subscriptions, and the last value of everything a tap
    /// reports on a transition rather than on every publish.
    @MainActor private var observers: Set<AnyCancellable> = []
    @MainActor private var wasDetecting = false
    @MainActor private var wasSetupNeeded: Bool?
    @MainActor private var wasFirstRunCompleted: Bool?
    @MainActor private var wasLaunchAtLoginAsked: Bool?
    /// The last status seen for each live session, so the next list can be
    /// told from it (`SessionJournalDiff`).
    @MainActor private var sessionStatuses: [LiveSessionKey: SessionStatus] = [:]
    /// The last badge count the status item reported drawing; nil until its
    /// first reading, which is always recorded.
    @MainActor private var lastBadgeCount: Int?

    private init() {}

    /// CFBundleVersion: the build the gate matches an asset against, not the
    /// marketing version. Outside a bundle — `swift run` during development —
    /// there is no Info.plist, so the version string stands in.
    private static let build: String = {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? agentMenuVersion
    }()

    // MARK: - Activation

    @MainActor
    func activate(
        environment: AppEnvironment,
        defaults: UserDefaults = .standard,
        directory: URL = Journal.defaultDirectory,
        defaultsSuite: String? = nil,
        manifestsRoot: URL? = ManifestRegistry.defaultUserRoot,
        profileRoot: URL? = nil
    ) {
        switch Journal.activate(defaults: defaults, directory: directory, build: Self.build) {
        case .inert:
            // No key. Any journal a previous run left has already been
            // deleted, and nothing else about this launch changes.
            return

        case .refused(let reason):
            // One line, once, and nothing else — the refusal is the only
            // trace a rejected key may leave (AE11). There is no logging layer
            // to route it through, so it goes where a GUI app's standard error
            // goes: the unified log for a launch from Finder, the terminal for
            // a launch from the harness.
            FileHandle.standardError.write(Data("AgentMenu: \(reason)\n".utf8))

        case .writing(let journal):
            lock.lock()
            self.journal = journal
            lock.unlock()
            journal.start(
                fixture: fixture(
                    environment: environment,
                    directory: directory,
                    defaultsSuite: defaultsSuite,
                    manifestsRoot: manifestsRoot,
                    profileRoot: profileRoot
                )
            )
            observe(environment)
        }
    }

    /// Which roots actually took effect (KTD3), so a report can prove the run
    /// it describes was the isolated one and not the maintainer's own
    /// configuration. Paths only: a scenario checks these against what it set
    /// up, and `agentmenu dump-state` (U7) prints the same shape for the same
    /// config.
    @MainActor
    private func fixture(
        environment: AppEnvironment,
        directory: URL,
        defaultsSuite: String?,
        manifestsRoot: URL?,
        profileRoot: URL?
    ) -> [String: JournalValue] {
        var echo: [String: JournalValue] = [
            "config": .string(environment.store.url.path),
            "harness_dir": .string(directory.path),
            // The standard domain is the normal case and is named rather than
            // left out, so the field is always there to match on.
            "defaults_suite": .string(defaultsSuite ?? "standard"),
            "version": .string(agentMenuVersion),
            // A scalar beside the list: `guest/wait.sh` matches a `--field`
            // through jq's `getpath`, which cannot index an array, so anything
            // a scenario asserts on has to be a plain value under `data`. The
            // list is still there for a scenario that reads the matched line
            // with jq itself.
            "profile_count": .integer(environment.config.profiles.count),
            "profiles": .list(
                environment.config.profiles.map { profile in
                    .object([
                        "id": .string(profile.id),
                        "config_dir": .string(profile.expandedConfigDirectory.path),
                    ])
                }
            ),
        ]
        if let manifestsRoot { echo["manifests_root"] = .string(manifestsRoot.path) }
        // Absent until U7 resolves `AGENTMENU_PROFILE_ROOT`; a field that is
        // not there is a field a scenario cannot match on by accident.
        if let profileRoot { echo["profile_root"] = .string(profileRoot.path) }
        // Where renames would be written, so a report can show a run never
        // touched the maintainer's own store. Absent on an ordinary launch.
        if let sessionStore = environment.overrides.sessionStore { echo["session_store"] = .string(sessionStore.path) }
        return echo
    }

    // MARK: - Taps that observe

    @MainActor
    private func observe(_ environment: AppEnvironment) {
        // Set synchronously, before the `$config` subscription below is even
        // made — not left for that subscription's own replay of the current
        // value, which this tap defers a full run-loop turn with
        // `DispatchQueue.main.async` (see the comment on that subscription).
        // `LaunchAtLoginPrompt.presentIfNeeded`, called later in the same
        // `applicationDidFinishLaunching`, blocks the main thread inside
        // `NSAlert.runModal()`'s own nested run loop — whether a block
        // already queued on the main queue before that call runs during
        // that nested loop or waits for it to end is not something this
        // tap can safely assume either way. Reading the baseline here,
        // synchronously, removes the question entirely: whatever happens
        // to the deferred replay, the transition this tap cares about —
        // `launchAtLoginAsked` going from false to true — is still exactly
        // one flip away from a baseline that was read before either the
        // setup card or the alert had any chance to touch it.
        wasLaunchAtLoginAsked = environment.config.launchAtLoginAsked

        // A configuration that could not be written makes every later
        // assertion meaningless, so it is observed first. `@Published` replays
        // its current value to a new subscriber, which is how a failure during
        // `seedIfMissing()` — which runs before this — is still recorded.
        environment.$saveFailure
            .sink { [weak self] failure in
                guard let failure else { return }
                self?.append(.saveFailed, ["message": .string(failure)])
            }
            .store(in: &observers)

        // `SetupModel.detect()` assigns what it found *before* it clears the
        // flag, so by the time `detecting` publishes false the agents and
        // folders are already there. That ordering is why this tap needs no
        // seam inside SetupModel — and it is load-bearing: reverse those two
        // statements and `detecting finished` starts reporting nothing found.
        let setup = environment.setup
        setup.$detecting
            .sink { [weak self] detecting in
                guard let self, self.wasDetecting != detecting else { return }
                self.wasDetecting = detecting
                guard !detecting else {
                    self.append(.detectingStarted)
                    return
                }
                self.append(.detectingFinished, [
                    "agents": .list(
                        setup.detectedAgents.map { hit in
                            .object(["id": .string(hit.id), "found": .boolean(hit.found)])
                        }
                    ),
                    "found": .integer(setup.detectedAgents.filter(\.found).count),
                    "folders": .list(setup.suggestedFolders.map(JournalValue.string)),
                    "folder_count": .integer(setup.suggestedFolders.count),
                ])
            }
            .store(in: &observers)

        // Sessions (KTD16). The model's list is the source, so a session that
        // was already running at launch is seen too: `@Published` replays its
        // current value, and the diff treats everything in it as new. Only
        // this observer runs the diff, and it exists only while the journal
        // is writing, so a normal launch does none of the work. The list is
        // the sink's parameter, not `environment.sessions.live`, which still
        // holds the previous value at this point.
        environment.sessions.$live
            .sink { [weak self] sessions in
                guard let self else { return }
                let diff = SessionJournalDiff.compare(previous: self.sessionStatuses, current: sessions)
                self.sessionStatuses = diff.statuses
                for session in diff.appeared {
                    self.append(.sessionSeen, JournalData.sessionSeen(session))
                }
                for change in diff.changed {
                    self.append(.sessionStatusChanged, JournalData.sessionStatusChanged(change.session, from: change.from))
                }
            }
            .store(in: &observers)

        // The setup card's two end states both follow from the configuration.
        // `@Published` fires *before* the new value is applied, so the card's
        // own answer is read on the next turn of the run loop rather than
        // recomputed here from a value that would drift out of step with
        // `SetupModel.isNeeded`.
        environment.$config
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.recordSetupState(environment) }
            }
            .store(in: &observers)
    }

    @MainActor
    private func recordSetupState(_ environment: AppEnvironment) {
        let needed = environment.setup.isNeeded
        if needed, wasSetupNeeded != true {
            // `needed` is the card's own answer, not a report that a window is
            // on screen: the popover draws the card the next time it is
            // opened. A scenario that wants the card *visible* screenshots it;
            // this field says only that the app has decided to show it.
            append(.setupShown, [
                "needed": .boolean(true),
                "first_run_completed": .boolean(environment.config.firstRunCompleted),
                "has_project_folder": .boolean(environment.setup.hasProjectFolder),
            ])
        }
        wasSetupNeeded = needed

        // Only a real transition: a launch that finds the flag already set is
        // not a setup anybody just finished, so the first value seen is
        // recorded and not reported.
        let completed = environment.config.firstRunCompleted
        if completed, wasFirstRunCompleted == false {
            append(.setupFinished, [
                "folder_count": .integer(environment.config.folders.count),
                "agent_count": .integer(environment.config.agentState.values.filter { $0.enabled == true }.count),
                "has_project_folder": .boolean(environment.setup.hasProjectFolder),
            ])
        }
        wasFirstRunCompleted = completed

        // One event for both places that can flip this: the setup card's
        // checkbox (`SetupModel.finish()`) and `LaunchAtLoginPrompt`'s alert
        // for an install that skips the card entirely. Observing the
        // configuration rather than tapping each call site is what makes
        // that true without either one having to know the journal exists —
        // the same reasoning `setupShown`/`setupFinished` above already
        // follow. `LaunchAtLogin.isEnabled` re-reads `SMAppService` rather
        // than trusting what was just requested, for the same reason
        // `SettingsModel.launchAtLogin` does: a registration that failed or
        // needs approval shows up here as `enabled: false`, not as a report
        // that lied.
        let launchAtLoginAsked = environment.config.launchAtLoginAsked
        if launchAtLoginAsked, wasLaunchAtLoginAsked == false {
            append(.launchAtLoginAsked, ["enabled": .boolean(LaunchAtLogin.isEnabled)])
        }
        wasLaunchAtLoginAsked = launchAtLoginAsked
    }

    // MARK: - Taps that are called

    /// What a launch is about to run (KTD3): the binary, the working
    /// directory and the *names* of the variables the command sets — never
    /// their values, and never the argument vector. `JournalData` builds that
    /// half in the Kit, where the rule is covered by the test suite.
    func launchRequested(
        target: LaunchTarget,
        command: LaunchCommand,
        agent: String?,
        terminal: String,
        preset: Preset
    ) {
        var data = JournalData.launchRequested(command: command)
        data["kind"] = .string(agent == nil ? "terminal" : "agent")
        data["target"] = .string(target.id)
        data["terminal"] = .string(terminal)
        if let agent { data["agent"] = .string(agent) }
        // The values the popover showed before the click, so a scenario can
        // assert the session started at the model and effort the row promised
        // (R11) rather than inferring it from a screenshot.
        if let model = preset.model { data["model"] = .string(model) }
        if let effort = preset.effort { data["effort"] = .string(effort) }
        if let mode = preset.permissionMode { data["permission_mode"] = .string(mode) }
        append(.launchRequested, data)
    }

    /// Whether the terminal took it. The error text is the same sentence the
    /// popover shows the user (R6), so the journal exposes nothing they could
    /// not already see (R16).
    func launchResult(target: LaunchTarget, kind: String, error: Error?) {
        var data: [String: JournalValue] = [
            "kind": .string(kind),
            "target": .string(target.id),
            "ok": .boolean(error == nil),
        ]
        if let error {
            data["error"] = .string((error as? LocalizedError)?.errorDescription ?? String(describing: error))
        }
        append(.launchResult, data)
    }

    /// AgentMenu asked its session host for a session (U11, KTD16), and
    /// whether it got one. Names nothing the user typed: the launch is the
    /// hash its Starting row's identifier carries, the terminal is a manifest
    /// id.
    func hostLaunch(launchID: String, terminal: String, ok: Bool) {
        append(.hostLaunch, JournalData.hostLaunch(launchID: launchID, terminal: terminal, ok: ok))
    }

    /// How a history resume ended (KTD16): launched, or the reason it was not.
    /// The outcome is a closed vocabulary and the session is named by the hash
    /// its row's identifier carries, so nothing the user typed or any path
    /// reaches the journal.
    func restoreResult(sessionID: String, outcome: JournalData.RestoreOutcome) {
        append(.restoreResult, JournalData.restoreResult(sessionID: sessionID, outcome: outcome))
    }

    /// A Reopen all finished (U14): counts only, so nothing the user typed or
    /// any path reaches the journal. The per-session outcomes are
    /// `restore result` events.
    func reopenAll(total: Int, reopened: Int, failed: Int) {
        append(.reopenAll, JournalData.reopenAll(total: total, reopened: reopened, failed: failed))
    }

    /// The Needs-you count the menu-bar item is drawing (R18), recorded when
    /// it changes. Called by `StatusItemController.refreshIndicator` with the
    /// count of the badge it actually built, 0 when it drew none, rather than
    /// read off the model: the gap this closes is the item not showing what
    /// the model holds. `refreshIndicator` runs on a timer too, so a repeat
    /// of the last value is dropped here.
    @MainActor
    func badgeShown(count: Int) {
        guard lastBadgeCount != count else { return }
        lastBadgeCount = count
        append(.badgeChanged, JournalData.badgeChanged(count: count))
    }

    /// How an attempt to bring a session's terminal forward ended (R8, R37).
    /// The outcome is a closed vocabulary and the row is named by the hash
    /// its identifier carries; `JournalData.focusResult` leaves out the
    /// terminal's name and any script error text.
    func focusResult(key: LiveSessionKey, outcome: FocusOutcome) {
        append(.focusResult, JournalData.focusResult(key: key, outcome: outcome))
    }

    /// The one write into an agent's own configuration directory the app ever
    /// asks for (R47), recorded with the files it named. Journalled once the
    /// CLI has finished, because that is the only path on which anything can
    /// have been written; when the tool could not be run at all there is
    /// nothing to report and the absence of this line is the signal.
    ///
    /// `files` comes out of the CLI's own report rather than out of
    /// `StatuslineBridge`'s constants. The constants would name the two files
    /// an install writes even on a run that wrote neither, and a scenario
    /// asserting "the bridge wrote these" would then pass against a failed
    /// install. An install that succeeded and reported nothing is at least a
    /// visible anomaly.
    func bridgeInstalled(profile: Profile, ok: Bool, report: String) {
        let prefixes = ["wrote ", "updated statusLine.command in "]
        let written = report.split(separator: "\n").compactMap { line -> String? in
            for prefix in prefixes where line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count))
            }
            return nil
        }
        append(.bridgeInstalled, [
            "profile": .string(profile.id),
            "directory": .string(profile.expandedConfigDirectory.path),
            "files": .list(written.map(JournalValue.string)),
            "file_count": .integer(written.count),
            "ok": .boolean(ok),
        ])
    }

    // MARK: - Writing

    private func append(_ event: JournalEvent, _ data: [String: JournalValue] = [:]) {
        lock.lock()
        let journal = self.journal
        lock.unlock()
        journal?.append(event, data)
    }
}
