// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// Something the dropdown can launch into.
///
/// The Finder window and `$HOME` are targets in their own right rather than
/// special cases of a folder: they carry no saved preset, and they follow the
/// profile the header shows (R42), while a configured folder carries its own.
struct LaunchTarget: Identifiable, Equatable {
    enum Kind: Equatable { case folder, finderWindow, home }

    let kind: Kind
    let label: String
    let path: String
    /// The configured entry this came from, for `.folder` targets only. Not
    /// derived from the path: several entries may name one folder, and the
    /// popover has to write an override back to the row that was clicked.
    let folderID: String?
    /// The saved overrides for this target — empty for Finder and `$HOME`.
    var preset: Preset
    /// nil for the Finder and home targets: they inherit the header's profile.
    var profileID: String?

    /// The path with `~` expanded. Configuration keeps what the user wrote; a
    /// command needs the real thing.
    var expandedPath: String {
        NSString(string: path).expandingTildeInPath
    }

    var id: String {
        switch kind {
        case .folder: return "folder:" + (folderID ?? path)
        case .finderWindow: return "finder"
        case .home: return "home"
        }
    }

    static func folder(_ folder: FolderTarget) -> LaunchTarget {
        LaunchTarget(kind: .folder, label: folder.label, path: folder.path, folderID: folder.id,
                     preset: folder.preset, profileID: folder.profileID)
    }

    static func home() -> LaunchTarget {
        LaunchTarget(kind: .home, label: "Home", path: FileManager.default.homeDirectoryForCurrentUser.path,
                     folderID: nil, preset: Preset(), profileID: nil)
    }

    static func finderWindow(path: String) -> LaunchTarget {
        LaunchTarget(kind: .finderWindow, label: "Current Finder folder", path: path,
                     folderID: nil, preset: Preset(), profileID: nil)
    }
}

/// What the active agent and terminal manifests allow, flattened for the UI.
///
/// An absent array means the agent does not declare that capability, so the
/// control is hidden rather than shown disabled (R13). The registry fills this
/// in; the views never read a manifest themselves.
struct PresetOptions: Equatable {
    var model: [String]?
    var effort: [String]?
    var permissionMode: [String]?
    var advisor: [String]?
    var canDisableAdvisor: Bool = false
    var agents: [(id: String, name: String)] = []
    var terminals: [(id: String, name: String)] = []
    /// The manifest's permission spec, so every surface asks it the R37
    /// question — `isBypassing(_:)` — rather than re-deriving the answer from a
    /// set of strings and drifting apart.
    var permission: PermissionSpec?

    /// Whether this value stops the agent asking (R37).
    func isBypassing(_ mode: String) -> Bool {
        permission?.isBypassing(mode) ?? false
    }

    static func == (lhs: PresetOptions, rhs: PresetOptions) -> Bool {
        lhs.model == rhs.model && lhs.effort == rhs.effort
            && lhs.permissionMode == rhs.permissionMode && lhs.advisor == rhs.advisor
            && lhs.canDisableAdvisor == rhs.canDisableAdvisor
            && lhs.agents.map(\.id) == rhs.agents.map(\.id)
            && lhs.terminals.map(\.id) == rhs.terminals.map(\.id)
            && lhs.permission == rhs.permission
    }

}
