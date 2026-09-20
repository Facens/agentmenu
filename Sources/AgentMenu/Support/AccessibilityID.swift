// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// The app-facing half of KTD9's identifier contract.
///
/// `AgentMenuKit.AccessibilityID` holds the real string builders — it has to,
/// since `Tests/AgentMenuKitTests/AccessibilityIDTests.swift` can only reach
/// code inside `AgentMenuKit` (see the comment on that file for why). This
/// file adds nothing but convenience: overloads that accept `LaunchTarget`
/// and `FolderTarget`, the types every menu-bar and Settings view already has
/// in hand, and forward straight to the Kit builders. Every raw value a
/// control actually carries is defined exactly once, in the Kit file;
/// nothing here recomputes or duplicates one.
extension AccessibilityID.Popover {
    /// The key a row is addressed by — mirrors `LaunchTarget.id` on purpose.
    /// Several `[[folders]]` entries may name the same folder (the
    /// "Duplicate" button in `FoldersPane.swift`), so the key can never be
    /// the path; it has to be the entry's own id, the one thing that tells
    /// two rows on one folder apart. `$HOME` and the Finder row carry no
    /// `folderID` at all and get the same fixed literals `LaunchTarget.id`
    /// already uses for them.
    private static func rowKey(_ target: LaunchTarget) -> String {
        switch target.kind {
        case .folder: return AccessibilityID.pathHash(target.folderID ?? target.path)
        case .home: return "home"
        case .finderWindow: return "finder"
        }
    }

    static func rowLaunch(_ target: LaunchTarget) -> String { rowLaunch(rowKey: rowKey(target)) }
    static func rowExpand(_ target: LaunchTarget) -> String { rowExpand(rowKey: rowKey(target)) }
    static func rowModel(_ target: LaunchTarget) -> String { rowModel(rowKey: rowKey(target)) }
    static func rowEffort(_ target: LaunchTarget) -> String { rowEffort(rowKey: rowKey(target)) }
    static func rowReorder(_ target: LaunchTarget) -> String { rowReorder(rowKey: rowKey(target)) }

    static func overrideModel(_ target: LaunchTarget) -> String { overrideModel(rowKey: rowKey(target)) }
    static func overrideEffort(_ target: LaunchTarget) -> String { overrideEffort(rowKey: rowKey(target)) }
    static func overridePermission(_ target: LaunchTarget) -> String { overridePermission(rowKey: rowKey(target)) }
    static func overrideAdvisor(_ target: LaunchTarget) -> String { overrideAdvisor(rowKey: rowKey(target)) }
    static func overrideAgent(_ target: LaunchTarget) -> String { overrideAgent(rowKey: rowKey(target)) }
    static func overrideLaunch(_ target: LaunchTarget) -> String { overrideLaunch(rowKey: rowKey(target)) }
    static func overrideTerminal(_ target: LaunchTarget) -> String { overrideTerminal(rowKey: rowKey(target)) }
    static func overrideSaveToFolder(_ target: LaunchTarget) -> String { overrideSaveToFolder(rowKey: rowKey(target)) }
    static func overrideSaveAsDefault(_ target: LaunchTarget) -> String { overrideSaveAsDefault(rowKey: rowKey(target)) }
}

extension AccessibilityID.Settings.Folders {
    /// Keyed by `FolderTarget.id`, for the same duplicate-entry reason as
    /// `AccessibilityID.Popover`'s row key above — two rows in the Folders
    /// pane can name one path, and the id is the only thing that tells them
    /// apart.
    static func row(_ folder: FolderTarget) -> String { row(folderID: folder.id) }
}
