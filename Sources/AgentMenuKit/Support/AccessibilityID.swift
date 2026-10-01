// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import CryptoKit
import Foundation

/// KTD9's "one enum": every stable identifier a harness scenario clicks by,
/// built once, in one place, so a rename is a deliberate change to the
/// control's contract (R12) rather than a UI file drifting out from under the
/// driver that reads it.
///
/// This builder lives in AgentMenuKit rather than under the file the plan
/// names, `Sources/AgentMenu/Support/AccessibilityID.swift` — that file still
/// exists, as the app-facing surface — because `Tests/AgentMenuKitTests` is a
/// plain executable target that depends on `AgentMenuKit` alone (see
/// `Package.swift`); it cannot import the `AgentMenu` app target, so a test
/// asserting uniqueness and the no-raw-value rule has to reach the actual
/// string builders, not a description of them written against types it
/// cannot see. `Sources/AgentMenu/Support/AccessibilityID.swift` is the thin
/// consumer: it adds overloads for `LaunchTarget` and the other app-only
/// types, and every one of them forwards to a builder here.
///
/// Every builder below takes primitive Foundation types and returns a
/// `String`, by construction: a function that accepted a SwiftUI view or an
/// AppKit type could not live in this target, and `packaging/check-source.sh`
/// enforces that `AgentMenuKit` imports neither AppKit nor SwiftUI.
public enum AccessibilityID {

    /// KTD9: a path never reaches an `AXIdentifier` un-hashed. An
    /// `AXIdentifier` sits in the same accessibility tree a screen reader
    /// walks and a leaked UI-automation log can capture wholesale — a raw
    /// path there would put the user's project names and `$HOME` into a
    /// string this app otherwise never exposes outside its own window.
    ///
    /// SHA-256, hex, truncated to 12 characters (48 bits): plenty to make a
    /// collision on one machine a non-concern, short enough to still read as
    /// an identifier rather than a hash dump.
    ///
    /// Named `pathHash` because a raw path (`Setup.folderToggle`, before a
    /// folder even has a `FolderTarget.id`) is its most direct use, but it
    /// also hashes a `FolderTarget.id` wherever one exists — see the row
    /// builders under `Popover` and `Settings.Folders.row` — because
    /// `FolderTarget.derivedID` can itself be a slug of the folder's own
    /// name (`Config.swift`), and that is exactly the kind of user-supplied
    /// free text this function exists to keep out of an AXIdentifier.
    ///
    /// The input is `~`-expanded and nothing more — not symlink-resolved, not
    /// case-normalized. A scenario's fixture predicts this value from the
    /// literal path (or id) it knows; a resolution step the fixture cannot
    /// observe would make the two sides compute different digests for what
    /// is, to the user, the same folder.
    public static func pathHash(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let digest = SHA256.hash(data: Data(expanded.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(12))
    }

    // MARK: Setup

    /// The setup card shown inside the dropdown before the launcher has a
    /// folder to offer (`SetupCard.swift`).
    public enum Setup {
        public static func agentToggle(_ agentID: String) -> String { "setup.agent.\(agentID).toggle" }
        public static func agentMakeDefault(_ agentID: String) -> String { "setup.agent.\(agentID).makeDefault" }
        public static func folderToggle(path: String) -> String { "setup.folder.\(pathHash(path)).toggle" }
        /// The card's own "launch at login?" checkbox — shown only while
        /// `!config.launchAtLoginAsked` (`SetupCard.swift`), so it can be on
        /// this card's first appearance and gone from every later one, folder-
        /// only re-opens included (`SetupModel.isNeeded`).
        public static let launchAtLogin = "setup.launchAtLogin"
        public static let addFolder = "setup.addFolder"
        public static let done = "setup.done"
    }

    // MARK: Popover

    /// The dropdown itself: its chrome, its scrolling row list, and the panel
    /// each row's chevron opens (`PopoverView.swift`, `FolderRow.swift`,
    /// `OverrideDisclosure.swift`, `StatusItemController.swift`).
    public enum Popover {
        /// U11: the manual update check in the footer, and the banner that
        /// says the app is running translocated. Both are drawn by this app,
        /// unlike Sparkle's own window, which carries no identifiers of ours.
        public static let checkForUpdates = "popover.checkForUpdates"
        public static let translocationBanner = "popover.translocationBanner"
        /// U14: the banner above the tabs that offers Reopen all after a restart,
        /// a crash or a host that died, and its two controls. Fixed: the text
        /// names a count, never a session.
        public static let restoreBanner = "popover.restoreBanner"
        public static let restoreBannerReopenAll = "popover.restoreBanner.reopenAll"
        public static let restoreBannerDismiss = "popover.restoreBanner.dismiss"
        /// U15: the once-only "reopen sessions at login?" question inside the
        /// banner, and its two answers.
        public static let restoreBannerQuestion = "popover.restoreBanner.reopenAtLoginQuestion"
        public static let restoreBannerReopenAtLogin = "popover.restoreBanner.reopenAtLogin.yes"
        public static let restoreBannerNotAtLogin = "popover.restoreBanner.reopenAtLogin.no"
        /// The menu-bar button that opens and closes the popover.
        public static let statusItem = "popover.statusItem"
        /// The popover's own hosting content view — what makes it a
        /// findable "window" to System Events rather than an anonymous one.
        public static let container = "popover.container"
        public static let gear = "popover.gear"
        /// The footer's Quit. An accessory app has no Dock icon and no
        /// main menu, so this button is the only way out short of Force
        /// Quit — and the only one a scenario can drive.
        public static let quit = "popover.quit"
        public static func profile(_ profileID: String) -> String { "popover.profile.\(profileID)" }

        // Every row builder below takes `rowKey`, never a path. `Config.swift`
        // says why on `FolderTarget.id`: "several entries may name the same
        // folder... an entry's identity is its own id, never its path" — the
        // same project on two accounts is one `FoldersPane` "Duplicate"
        // click away, and `PopoverModel.saveToFolder` matches by id for
        // exactly this reason ("two entries may name one folder, and saving
        // an override on the second row must not land on the first"). A
        // path-keyed identifier would give both rows the same AXIdentifier;
        // `ax.applescript`'s `findByIdentifier` returns the first match it
        // walks to, so a scenario aimed at the second row would silently
        // drive the first instead. `rowKey` is the caller's job to make
        // unique per row — `Sources/AgentMenu/Support/AccessibilityID.swift`
        // builds it from `FolderTarget.id` (hashed, since a hand-edited
        // config's id can be `FolderTarget.derivedID`, a slug of the
        // folder's own name — not something to put un-hashed into an
        // AXIdentifier) for a real folder, and a fixed literal for `$HOME`
        // and the Finder row, mirroring `LaunchTarget.id` itself.
        public static func rowLaunch(rowKey: String) -> String { "popover.row.\(rowKey).launch" }
        public static func rowExpand(rowKey: String) -> String { "popover.row.\(rowKey).expand" }
        public static func rowModel(rowKey: String) -> String { "popover.row.\(rowKey).model" }
        public static func rowEffort(rowKey: String) -> String { "popover.row.\(rowKey).effort" }
        public static func rowReorder(rowKey: String) -> String { "popover.row.\(rowKey).reorder" }

        public static func overrideModel(rowKey: String) -> String { "popover.row.\(rowKey).override.model" }
        public static func overrideEffort(rowKey: String) -> String { "popover.row.\(rowKey).override.effort" }
        public static func overridePermission(rowKey: String) -> String { "popover.row.\(rowKey).override.permission" }
        public static func overrideAdvisor(rowKey: String) -> String { "popover.row.\(rowKey).override.advisor" }
        public static func overrideKeepRunning(rowKey: String) -> String { "popover.row.\(rowKey).override.keepRunning" }
        public static func overrideAgent(rowKey: String) -> String { "popover.row.\(rowKey).override.agent" }
        public static func overrideLaunch(rowKey: String) -> String { "popover.row.\(rowKey).override.launch" }
        public static func overrideTerminal(rowKey: String) -> String { "popover.row.\(rowKey).override.terminal" }
        public static func overrideSaveToFolder(rowKey: String) -> String { "popover.row.\(rowKey).override.saveToFolder" }
        public static func overrideSaveAsDefault(rowKey: String) -> String { "popover.row.\(rowKey).override.saveAsDefault" }

        /// The rate-limit strip's rows carry no click target — `UsageStrip`
        /// is read-only — but `ax.applescript`'s `read` verb still addresses
        /// an element by `AXIdentifier`, so a scenario that wants to confirm
        /// what the popover displays after a launch needs one of these too.
        /// `kind` is `"fiveHour"` or `"sevenDay"`, never a value read off the
        /// snapshot itself.
        public static func usageWindow(_ kind: String) -> String { "popover.usage.\(kind)" }

        /// The popover's two tabs (KTD16). Launch is selected on every open.
        public static let tabLaunch = "popover.tab.launch"
        public static let tabSessions = "popover.tab.sessions"

        /// The Sessions tab (`SessionsView.swift`, `SessionRow.swift`).
        ///
        /// KTD16: a session identifier hashes its row key and never contains a
        /// title or a path. A live row is keyed by `LiveSessionKey` — never by
        /// session id, for the reason that type documents — a closed row by its
        /// session id, a fold by its own id (a skill name and a folder). All
        /// three go through `pathHash`, so a scenario predicts an identifier
        /// from the key it launched and nothing the user typed can leak into
        /// the accessibility tree.
        public enum Sessions {
            /// The Live | Closed toggle.
            public static let toggleLive = "popover.sessions.toggle.live"
            public static let toggleClosed = "popover.sessions.toggle.closed"

            /// An account pill. A profile id is the config's own stable id
            /// (KTD9's exception) and is carried verbatim; `all` and
            /// `profile.all` cannot collide.
            public static func pill(_ pill: AccountPill) -> String {
                switch pill {
                case .all: return "popover.sessions.pill.all"
                case .profile(let id): return "popover.sessions.pill.profile.\(id)"
                }
            }

            /// The hashed key a live row is addressed by, and the value the
            /// journal's session events carry as `key`, so a scenario can
            /// match a row to its events. Built from the registry directory,
            /// pid and process start — the row's own identity (KTD7).
            public static func liveRowKey(_ key: LiveSessionKey) -> String {
                pathHash("live:\(key.configDirectory ?? "-")|\(key.pid)|\(key.procStart)")
            }

            public static func liveRow(_ key: LiveSessionKey) -> String { "popover.sessions.live.\(liveRowKey(key)).row" }
            public static func liveRowMenu(_ key: LiveSessionKey) -> String { "popover.sessions.live.\(liveRowKey(key)).menu" }
            /// Quit, in a live row's menu (U12).
            public static func liveRowQuit(_ key: LiveSessionKey) -> String { "popover.sessions.live.\(liveRowKey(key)).quit" }

            public static func closedRowKey(sessionID: String) -> String { pathHash("closed:\(sessionID)") }
            public static func closedRow(sessionID: String) -> String { "popover.sessions.closed.\(closedRowKey(sessionID: sessionID)).row" }
            public static func closedRowMenu(sessionID: String) -> String { "popover.sessions.closed.\(closedRowKey(sessionID: sessionID)).menu" }
            /// The small tag on a Closed row that Reopen all would bring back (U14).
            public static func closedRowPendingTag(sessionID: String) -> String { "popover.sessions.closed.\(closedRowKey(sessionID: sessionID)).reopenAllTag" }

            /// A folded run of one skill in one folder, by the fold's own id
            /// (`SkillFold.id`), which carries both.
            public static func foldRowKey(foldID: String) -> String { pathHash("fold:\(foldID)") }
            public static func foldRow(foldID: String) -> String { "popover.sessions.fold.\(foldRowKey(foldID: foldID)).row" }

            /// The Needs-you group's heading on the Live list. Only this group
            /// has one: every other group is a folder, and a folder's name is
            /// a path, which an identifier never carries (KTD16). A scenario
            /// waits for it to know a waiting session is listed where the
            /// user looks for it, not merely somewhere in the list.
            public static let needsYouHeader = "popover.sessions.group.needsYou"

            /// The header menu, visible on Live and Closed with or without
            /// rows, and its three items.
            public static let headerMenu = "popover.sessions.header.menu"
            public static let quitAll = "popover.sessions.header.quitAll"
            public static let reopenAll = "popover.sessions.header.reopenAll"
            public static let reopenLastClosed = "popover.sessions.header.reopenLastClosed"

            /// The inline rename field a row shows while it is being renamed.
            public static func liveRowRename(_ key: LiveSessionKey) -> String { "popover.sessions.live.\(liveRowKey(key)).rename" }
            public static func closedRowRename(sessionID: String) -> String { "popover.sessions.closed.\(closedRowKey(sessionID: sessionID)).rename" }

            /// A launch that has no live row yet (Starting) or never got one
            /// (Failed to start), by the launch's own id. Nothing creates one
            /// before owned launches exist; the view and its identifiers are
            /// ready for them.
            public static func pendingRowKey(launchID: String) -> String { pathHash("pending:\(launchID)") }
            public static func pendingRow(launchID: String) -> String { "popover.sessions.pending.\(pendingRowKey(launchID: launchID)).row" }
            public static func pendingQuit(launchID: String) -> String { "popover.sessions.pending.\(pendingRowKey(launchID: launchID)).quit" }
            public static func pendingRetry(launchID: String) -> String { "popover.sessions.pending.\(pendingRowKey(launchID: launchID)).retry" }
            public static func pendingDismiss(launchID: String) -> String { "popover.sessions.pending.\(pendingRowKey(launchID: launchID)).dismiss" }

            /// The strip a Reopen all leaves at the top of the list, and its
            /// dismiss control.
            public static let reopenStrip = "popover.sessions.reopenStrip"
            public static let reopenStripDismiss = "popover.sessions.reopenStrip.dismiss"
            /// The same place while a Reopen all is still running.
            public static let reopenProgress = "popover.sessions.reopenProgress"

            /// The Closed list's search field.
            public static let closedSearch = "popover.sessions.closed.search"

            /// Empty and waiting states: "No running sessions", "No matches",
            /// and the progress indicator shown while the index builds.
            public static let emptyLive = "popover.sessions.empty.live"
            public static let emptyNoMatches = "popover.sessions.empty.noMatches"
            public static let closedIndexing = "popover.sessions.closed.indexing"

            /// The strip at the top of the tab when macOS has notifications
            /// turned off for AgentMenu, with the System Settings path (R32).
            public static let notificationsDenied = "popover.sessions.notificationsDenied"
        }
    }

    // MARK: Settings

    /// The Settings window and its four panes.
    public enum Settings {
        public static let window = "settings.window"
        public static func tab(_ name: String) -> String { "settings.tab.\(name)" }

        /// `PresetEditor` is shared by `DefaultsPane` and the per-folder form
        /// in `FoldersPane`; `scope` is what keeps the two Model pickers,
        /// say, from colliding on one identifier — `"defaults"` in the first
        /// case, `"folders.preset"` in the second.
        public static func preset(_ scope: String, _ field: String) -> String { "settings.\(scope).\(field)" }

        public enum Accounts {
            public static let add = "settings.accounts.add"
            public static let remove = "settings.accounts.remove"
            public static let chooseDirectory = "settings.accounts.chooseDirectory"
            public static let name = "settings.accounts.name"
            public static let installBridge = "settings.accounts.installBridge"
            public static let removeBridge = "settings.accounts.removeBridge"
        }

        /// U11's General tab. The updater's own window is Sparkle's and
        /// carries no identifiers of ours, so these cover only the controls
        /// this app draws.
        public enum Updates {
            public static let automatic = "settings.updates.automatic"
            public static let beta = "settings.updates.beta"
            public static let checkNow = "settings.updates.checkNow"
            /// The line that says why the section is disabled on a build
            /// that must not update itself — an alpha, or one with no
            /// signing key.
            public static let unavailable = "settings.updates.unavailable"
        }

        /// The login item toggle in the General tab. Same string as
        /// MeetingHop's, so one scenario can drive either app.
        public static let launchAtLogin = "settings.launchAtLoginToggle"
        /// "Reopen sessions at login" in the General tab (R25).
        public static let reopenAtLogin = "settings.reopenAtLoginToggle"

        /// "Notify when a session needs you" in the General tab, and the note
        /// beside it when macOS is blocking notifications (R32).
        public static let notifyNeedsYou = "settings.notifyNeedsYouToggle"
        /// "Notify when a session I launched finishes its turn" (R33).
        public static let notifyYourTurn = "settings.notifyYourTurnToggle"
        public static let notificationsDenied = "settings.notificationsDenied"

        public enum Agents {
            public static func path(_ agentID: String) -> String { "settings.agents.\(agentID).path" }
            public static func find(_ agentID: String) -> String { "settings.agents.\(agentID).find" }
            public static func enabled(_ agentID: String) -> String { "settings.agents.\(agentID).enabled" }
            public static func trusted(_ agentID: String) -> String { "settings.agents.\(agentID).trusted" }
        }

        public enum Terminals {
            public static func enabled(_ terminalID: String) -> String { "settings.terminals.\(terminalID).enabled" }
            public static func trusted(_ terminalID: String) -> String { "settings.terminals.\(terminalID).trusted" }
        }

        public enum Folders {
            public static let add = "settings.folders.add"
            public static let remove = "settings.folders.remove"
            public static let duplicate = "settings.folders.duplicate"
            /// `tabID` is a `SettingsModel.AccountTab` flattened to a
            /// profile id, or the literal `"unassigned"` — neither is a path.
            public static func accountTab(_ tabID: String) -> String { "settings.folders.accountTab.\(tabID)" }
            /// Keyed by `FolderTarget.id`, hashed — not by path, for the same
            /// duplicate-entry reason documented on `Popover.rowLaunch`.
            public static func row(folderID: String) -> String { "settings.folders.row.\(pathHash(folderID))" }
            public static let detailLabel = "settings.folders.detail.label"
            public static let detailChooseFolder = "settings.folders.detail.chooseFolder"
            public static let detailAccountPicker = "settings.folders.detail.accountPicker"
        }
    }

    // MARK: Launch-at-login prompt

    /// `LaunchAtLoginPrompt.swift`'s one-shot native alert, for an install
    /// that reaches a build carrying this question with `firstRunCompleted`
    /// already true — so the setup card's own checkbox (`Setup.launchAtLogin`
    /// above) never gets a chance to ask it. Set on the alert's own buttons
    /// the same way every other control in this app gets an identifier
    /// (KTD9), even though the harness answers this particular alert the way
    /// it already answers `ProfilesPane.installBridge`'s — by process and
    /// text, through the shared `dialogs.applescript`'s `alert` kind — because
    /// that file is byte-identical across both repositories
    /// (harness/SHARED.sha256) and cannot be handed an app-specific
    /// AXIdentifier to look for.
    public enum LaunchAtLoginPrompt {
        public static let accept = "launchAtLoginPrompt.accept"
        public static let decline = "launchAtLoginPrompt.decline"
    }

    // MARK: Quit confirmation

    /// The `NSAlert` Quit and Quit all show when an affected session is
    /// Working (U12, R21). Fixed identifiers: the alert's text names sessions,
    /// the identifiers never do.
    public enum QuitPrompt {
        public static let confirm = "quitPrompt.confirm"
        public static let cancel = "quitPrompt.cancel"
    }
}
