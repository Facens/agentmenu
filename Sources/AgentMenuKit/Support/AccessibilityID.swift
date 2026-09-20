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
        public static let addFolder = "setup.addFolder"
        public static let done = "setup.done"
    }

    // MARK: Popover

    /// The dropdown itself: its chrome, its scrolling row list, and the panel
    /// each row's chevron opens (`PopoverView.swift`, `FolderRow.swift`,
    /// `OverrideDisclosure.swift`, `StatusItemController.swift`).
    public enum Popover {
        /// The menu-bar button that opens and closes the popover.
        public static let statusItem = "popover.statusItem"
        /// The popover's own hosting content view — what makes it a
        /// findable "window" to System Events rather than an anonymous one.
        public static let container = "popover.container"
        public static let gear = "popover.gear"
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
        }

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
}
