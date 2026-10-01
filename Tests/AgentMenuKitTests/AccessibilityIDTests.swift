// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// KTD9: the enum's raw values are unique and non-empty, and no dynamic
/// identifier embeds a raw path, a username, or a home directory. This lives
/// in `AgentMenuKitTests` rather than under `Tests/` for the app target —
/// there is no such target; `Tests/AgentMenuKitTests` is the only suite this
/// project has, and it is a plain executable that depends on `AgentMenuKit`
/// alone (see `Package.swift`), which is exactly why the builders under test
/// live in `AgentMenuKit` and not in `Sources/AgentMenu/Support/
/// AccessibilityID.swift` — see the comment at the top of
/// `Sources/AgentMenuKit/Support/AccessibilityID.swift`.
///
/// The `Popover` row/override builders take an already-resolved `rowKey`,
/// not a path: `Sources/AgentMenu/Support/AccessibilityID.swift` computes
/// that key from a `LaunchTarget` (hashing `folderID ?? path` for a folder
/// row, or a fixed literal for `$HOME`/Finder) before calling down into
/// these builders, because several `[[folders]]` entries may name one
/// folder — see the long comment on `Popover.rowLaunch` in the Kit file.
/// Tests here that want to exercise the no-raw-value rule on those builders
/// route a path through `AccessibilityID.pathHash` first, the same way the
/// app does, rather than passing a raw path as `rowKey` — that would only
/// prove the interpolation works, not that the real call path is safe.
func runAccessibilityIDTests(_ t: TestRunner) {
    t.suite("AccessibilityID")

    let agentA = "claude-code"
    let agentB = "codex"
    let profileA = "personal"
    let profileB = "work"
    let folderA = "/Users/andrea/Code/agentmenu"
    let folderB = "/Users/andrea/Code/meetinghop"
    let rowKeyA = AccessibilityID.pathHash(folderA)
    let rowKeyB = AccessibilityID.pathHash(folderB)

    // MARK: Happy path — every raw value a representative sweep of the app
    // produces is non-empty, and no two of them collide.

    let representative: [String] = [
        // Setup
        AccessibilityID.Setup.agentToggle(agentA),
        AccessibilityID.Setup.agentToggle(agentB),
        AccessibilityID.Setup.agentMakeDefault(agentA),
        AccessibilityID.Setup.agentMakeDefault(agentB),
        AccessibilityID.Setup.folderToggle(path: folderA),
        AccessibilityID.Setup.folderToggle(path: folderB),
        AccessibilityID.Setup.launchAtLogin,
        AccessibilityID.Setup.addFolder,
        AccessibilityID.Setup.done,

        // Popover
        AccessibilityID.Popover.statusItem,
        AccessibilityID.Popover.container,
        AccessibilityID.Popover.gear,
        AccessibilityID.Popover.profile(profileA),
        AccessibilityID.Popover.profile(profileB),
        AccessibilityID.Popover.rowLaunch(rowKey: rowKeyA),
        AccessibilityID.Popover.rowLaunch(rowKey: rowKeyB),
        AccessibilityID.Popover.rowLaunch(rowKey: "home"),
        AccessibilityID.Popover.rowLaunch(rowKey: "finder"),
        // `$HOME` and the Finder row are singletons — one of each per
        // popover — but every row builder still composes with their fixed
        // literal row keys, since `rowModel`/`rowEffort` gate only on
        // `options.model`/`options.effort`, not on the target's kind.
        AccessibilityID.Popover.rowModel(rowKey: "home"),
        AccessibilityID.Popover.rowEffort(rowKey: "home"),
        AccessibilityID.Popover.rowExpand(rowKey: "finder"),
        AccessibilityID.Popover.rowExpand(rowKey: rowKeyA),
        AccessibilityID.Popover.rowModel(rowKey: rowKeyA),
        AccessibilityID.Popover.rowEffort(rowKey: rowKeyA),
        AccessibilityID.Popover.rowReorder(rowKey: rowKeyA),
        AccessibilityID.Popover.overrideModel(rowKey: rowKeyA),
        AccessibilityID.Popover.overrideEffort(rowKey: rowKeyA),
        AccessibilityID.Popover.overridePermission(rowKey: rowKeyA),
        AccessibilityID.Popover.overrideAdvisor(rowKey: rowKeyA),
        AccessibilityID.Popover.overrideKeepRunning(rowKey: rowKeyA),
        AccessibilityID.Popover.overrideAgent(rowKey: rowKeyA),
        AccessibilityID.Popover.overrideLaunch(rowKey: rowKeyA),
        AccessibilityID.Popover.overrideTerminal(rowKey: rowKeyA),
        AccessibilityID.Popover.overrideSaveToFolder(rowKey: rowKeyA),
        AccessibilityID.Popover.overrideSaveAsDefault(rowKey: rowKeyA),
        AccessibilityID.Popover.usageWindow("five_hour"),
        AccessibilityID.Popover.usageWindow("seven_day"),

        // Settings
        AccessibilityID.Settings.window,
        AccessibilityID.Settings.tab("folders"),
        AccessibilityID.Settings.tab("defaults"),
        AccessibilityID.Settings.tab("accounts"),
        AccessibilityID.Settings.tab("agents"),
        AccessibilityID.Settings.launchAtLogin,
        AccessibilityID.Settings.reopenAtLogin,
        AccessibilityID.Settings.notifyNeedsYou,
        AccessibilityID.Settings.notifyYourTurn,
        AccessibilityID.Settings.notificationsDenied,
        AccessibilityID.Settings.preset("defaults", "model"),
        AccessibilityID.Settings.preset("defaults", "effort"),
        AccessibilityID.Settings.preset("defaults", "permission"),
        AccessibilityID.Settings.preset("defaults", "advisor"),
        AccessibilityID.Settings.preset("defaults", "keepRunning"),
        AccessibilityID.Settings.preset("defaults", "agent"),
        AccessibilityID.Settings.preset("defaults", "terminal"),
        AccessibilityID.Settings.preset("folders.preset", "model"),
        AccessibilityID.Settings.preset("folders.preset", "effort"),
        AccessibilityID.Settings.preset("folders.preset", "permission"),
        AccessibilityID.Settings.preset("folders.preset", "advisor"),
        AccessibilityID.Settings.preset("folders.preset", "keepRunning"),
        AccessibilityID.Settings.preset("folders.preset", "agent"),
        AccessibilityID.Settings.Accounts.add,
        AccessibilityID.Settings.Accounts.remove,
        AccessibilityID.Settings.Accounts.chooseDirectory,
        AccessibilityID.Settings.Accounts.name,
        AccessibilityID.Settings.Accounts.installBridge,
        AccessibilityID.Settings.Accounts.removeBridge,
        AccessibilityID.Settings.Agents.path(agentA),
        AccessibilityID.Settings.Agents.path(agentB),
        AccessibilityID.Settings.Agents.find(agentA),
        AccessibilityID.Settings.Agents.enabled(agentA),
        AccessibilityID.Settings.Agents.trusted(agentA),
        AccessibilityID.Settings.Terminals.enabled("terminal-app"),
        AccessibilityID.Settings.Terminals.trusted("terminal-app"),
        AccessibilityID.Settings.Folders.add,
        AccessibilityID.Settings.Folders.remove,
        AccessibilityID.Settings.Folders.duplicate,
        AccessibilityID.Settings.Folders.accountTab(profileA),
        AccessibilityID.Settings.Folders.accountTab(profileB),
        AccessibilityID.Settings.Folders.accountTab("unassigned"),
        AccessibilityID.Settings.Folders.row(folderID: "folder-id-1"),
        AccessibilityID.Settings.Folders.row(folderID: "folder-id-2"),
        AccessibilityID.Settings.Folders.detailLabel,
        AccessibilityID.Settings.Folders.detailChooseFolder,
        AccessibilityID.Settings.Folders.detailAccountPicker,

        // Launch-at-login prompt
        AccessibilityID.LaunchAtLoginPrompt.accept,
        AccessibilityID.LaunchAtLoginPrompt.decline,
        AccessibilityID.QuitPrompt.confirm,
        AccessibilityID.QuitPrompt.cancel,
    ] + sessionsRepresentative(
        liveKeys: [
            LiveSessionKey(configDirectory: "/Users/andrea/.claude", pid: 4101, procStart: 1_790_000_000),
            LiveSessionKey(configDirectory: "/Users/andrea/.claude-work", pid: 4101, procStart: 1_790_000_000),
            LiveSessionKey(configDirectory: "/Users/andrea/.claude", pid: 4101, procStart: 1_790_000_999),
            LiveSessionKey(configDirectory: nil, pid: 4101, procStart: 1_790_000_000),
        ],
        closedSessionIDs: ["0b6f3a52-7c1e-4d0a-9a43-5f1e2c7d8b90", "5d2c9e14-31aa-4b7e-8c60-9a1f3b2d4e77"],
        foldIDs: ["collect-invoices\u{0}/Users/andrea/Code/agentmenu", "collect-invoices\u{0}/Users/andrea/Code/meetinghop"],
        profileIDs: [profileA, profileB, "all"]
    )

    for id in representative {
        t.expect(!id.isEmpty, "identifier is non-empty: '\(id)'")
    }
    t.expectEqual(
        Set(representative).count, representative.count,
        "every raw value in a representative sweep of the app is unique — \(representative.count - Set(representative).count) collision(s)"
    )

    // MARK: Edge — a row with two controls (launch, expand) exposes two
    // identifiers, not one merged element. `.accessibilityElement(children:
    // .contain)` on the row is what makes that true at runtime (applied in
    // FolderRow.swift, OverrideDisclosure.swift and PopoverView.swift's
    // Finder card); what a plain string builder can assert is the half of
    // the contract it owns — that the two controls were never going to
    // share one identifier to begin with.
    t.expect(
        AccessibilityID.Popover.rowLaunch(rowKey: rowKeyA) != AccessibilityID.Popover.rowExpand(rowKey: rowKeyA),
        "a folder row's launch and expand controls carry different identifiers"
    )
    t.expect(
        AccessibilityID.Popover.rowModel(rowKey: rowKeyA) != AccessibilityID.Popover.rowEffort(rowKey: rowKeyA),
        "a folder row's model and effort pills carry different identifiers"
    )

    // MARK: Regression — two `[[folders]]` entries that name the SAME path
    // (FoldersPane's "Duplicate" button makes exactly this) must not collide
    // on one row identifier. `Config.swift`'s own comment on
    // `FolderTarget.id` is the reason: "an entry's identity is its own id,
    // never its path." The row key has to come from the entry id, not the
    // path, or `ax.applescript`'s `findByIdentifier` — which returns the
    // first match — would silently drive the wrong row.
    let entryID1 = AccessibilityID.pathHash("first-entry-id")
    let entryID2 = AccessibilityID.pathHash("second-entry-id")
    t.expect(
        AccessibilityID.Popover.rowLaunch(rowKey: entryID1) != AccessibilityID.Popover.rowLaunch(rowKey: entryID2),
        "two folder entries that share one path still get different row identifiers, because the key is the entry id"
    )
    t.expect(
        AccessibilityID.Settings.Folders.row(folderID: "first-entry-id")
            != AccessibilityID.Settings.Folders.row(folderID: "second-entry-id"),
        "the Folders pane's list row identifier is keyed the same way, for the same reason"
    )

    // MARK: pathHash — deterministic, tilde-aware, and never the path itself

    t.expectEqual(
        AccessibilityID.pathHash(folderA), AccessibilityID.pathHash(folderA),
        "pathHash is deterministic for the same path"
    )
    t.expect(
        AccessibilityID.pathHash(folderA) != AccessibilityID.pathHash(folderB),
        "two different folders hash differently"
    )

    let home = FileManager.default.homeDirectoryForCurrentUser.path
    t.expectEqual(
        AccessibilityID.pathHash("~/Code/agentmenu"), AccessibilityID.pathHash(home + "/Code/agentmenu"),
        "a `~`-prefixed path and its explicit expansion hash the same way"
    )

    let hash = AccessibilityID.pathHash(folderA)
    t.expectEqual(hash.count, 12, "pathHash truncates to 12 hex characters")
    t.expect(
        hash.allSatisfy { $0.isHexDigit && !$0.isUppercase },
        "pathHash is lowercase hex — got '\(hash)'"
    )

    // MARK: No raw value — the hard requirement. Feed the builders a path
    // that carries both the maintainer's home directory and a project name a
    // scenario has no business leaking, and confirm neither survives into
    // any identifier a folder-keyed builder produces. For the `Popover` row
    // builders that means hashing first, the way
    // `Sources/AgentMenu/Support/AccessibilityID.swift` actually does it —
    // see the note at the top of this file.
    let maintainerPath = "/Users/andrea.giannangelo/Documents/super-secret-project"
    let usernameFragment = "andrea.giannangelo"
    let projectFragment = "super-secret-project"
    let maintainerRowKey = AccessibilityID.pathHash(maintainerPath)

    let dynamicIdentifiers: [(String, String)] = [
        ("Setup.folderToggle", AccessibilityID.Setup.folderToggle(path: maintainerPath)),
        ("Popover.rowLaunch", AccessibilityID.Popover.rowLaunch(rowKey: maintainerRowKey)),
        ("Popover.rowExpand", AccessibilityID.Popover.rowExpand(rowKey: maintainerRowKey)),
        ("Popover.overrideSaveAsDefault", AccessibilityID.Popover.overrideSaveAsDefault(rowKey: maintainerRowKey)),
        ("Settings.Folders.row", AccessibilityID.Settings.Folders.row(folderID: maintainerPath)),
    ]

    // KTD16: the Sessions identifiers hash their row key and never carry a
    // title or a path. The fixtures below put a secret in every field a row
    // could be built from.
    let secretFolder = "/Users/andrea.giannangelo/Documents/super-secret-project"
    let secretSkill = "collect-secret-invoices"
    let secretKey = LiveSessionKey(configDirectory: "/Users/andrea.giannangelo/.claude-secret", pid: 77, procStart: 1_790_000_000)
    let secretFold = "\(secretSkill)\u{0}\(secretFolder)"
    let sessionsIdentifiers: [(String, String)] = [
        ("Sessions.liveRow", AccessibilityID.Popover.Sessions.liveRow(secretKey)),
        ("Sessions.liveRowMenu", AccessibilityID.Popover.Sessions.liveRowMenu(secretKey)),
        ("Sessions.liveRowQuit", AccessibilityID.Popover.Sessions.liveRowQuit(secretKey)),
        ("Sessions.closedRow", AccessibilityID.Popover.Sessions.closedRow(sessionID: secretFolder)),
        ("Sessions.closedRowMenu", AccessibilityID.Popover.Sessions.closedRowMenu(sessionID: secretFolder)),
        ("Sessions.foldRow", AccessibilityID.Popover.Sessions.foldRow(foldID: secretFold)),
        ("Sessions.liveRowRename", AccessibilityID.Popover.Sessions.liveRowRename(secretKey)),
        ("Sessions.closedRowRename", AccessibilityID.Popover.Sessions.closedRowRename(sessionID: secretFolder)),
        ("Sessions.closedRowPendingTag", AccessibilityID.Popover.Sessions.closedRowPendingTag(sessionID: secretFolder)),
        ("Sessions.pendingRow", AccessibilityID.Popover.Sessions.pendingRow(launchID: secretFolder)),
        ("Sessions.pendingQuit", AccessibilityID.Popover.Sessions.pendingQuit(launchID: secretFolder)),
        ("Sessions.pendingRetry", AccessibilityID.Popover.Sessions.pendingRetry(launchID: secretFolder)),
        ("Sessions.pendingDismiss", AccessibilityID.Popover.Sessions.pendingDismiss(launchID: secretFolder)),
        // A fixed identifier, so nothing a user typed can be in it; listed so
        // a later change that keys it by folder name trips the same sweep.
        ("Sessions.needsYouHeader", AccessibilityID.Popover.Sessions.needsYouHeader),
    ]
    for (label, id) in sessionsIdentifiers {
        for fragment in [usernameFragment, projectFragment, secretSkill, "secret", "Users", ".claude", secretFolder] {
            t.expect(!id.localizedCaseInsensitiveContains(fragment), "\(label) does not embed '\(fragment)' — got '\(id)'")
        }
        t.expect(!id.contains("\u{0}"), "\(label) carries no control character — got '\(id)'")
    }
    t.expectEqual(
        AccessibilityID.Popover.Sessions.liveRow(secretKey), AccessibilityID.Popover.Sessions.liveRow(secretKey),
        "a live row's identifier is deterministic, so a scenario can predict it"
    )
    t.expectEqual(
        AccessibilityID.Popover.Sessions.liveRowKey(secretKey).count, 12,
        "a live row key is the same 12-character hash every other row key is"
    )
    t.expect(
        AccessibilityID.Popover.Sessions.liveRow(secretKey) != AccessibilityID.Popover.Sessions.liveRowMenu(secretKey),
        "a live row and its menu carry different identifiers"
    )
    t.expect(
        AccessibilityID.Popover.Sessions.closedRowKey(sessionID: "abc") != AccessibilityID.Popover.Sessions.foldRowKey(foldID: "abc"),
        "a closed row and a fold with the same raw id still hash apart"
    )
    t.expect(
        AccessibilityID.Popover.Sessions.pill(.all) != AccessibilityID.Popover.Sessions.pill(.profile("all")),
        "the All pill and a profile that happens to be called all do not collide"
    )

    for (label, id) in dynamicIdentifiers {
        t.expect(!id.contains(maintainerPath), "\(label) does not embed the raw path — got '\(id)'")
        t.expect(!id.localizedCaseInsensitiveContains(usernameFragment), "\(label) does not embed the username — got '\(id)'")
        t.expect(!id.localizedCaseInsensitiveContains(projectFragment), "\(label) does not embed the folder name — got '\(id)'")
        t.expect(!id.localizedCaseInsensitiveContains("Users"), "\(label) does not embed '/Users' — got '\(id)'")
    }

    // Profile and agent ids are the config's own stable ids (KTD9's
    // exception): they are expected to appear verbatim, unlike a path.
    t.expect(
        AccessibilityID.Popover.profile(profileA).contains(profileA),
        "a profile id is carried verbatim, not hashed — it is not user-supplied free text"
    )
    t.expect(
        AccessibilityID.Setup.agentToggle(agentA).contains(agentA),
        "an agent id is carried verbatim, not hashed — it is not user-supplied free text"
    )
}

/// The Sessions tab's identifiers over a representative set of keys, for the
/// uniqueness sweep: every fixed one once, and every keyed one for each key.
private func sessionsRepresentative(
    liveKeys: [LiveSessionKey], closedSessionIDs: [String], foldIDs: [String], profileIDs: [String]
) -> [String] {
    typealias Sessions = AccessibilityID.Popover.Sessions
    var ids: [String] = [
        AccessibilityID.Popover.tabLaunch,
        AccessibilityID.Popover.tabSessions,
        Sessions.toggleLive,
        Sessions.toggleClosed,
        Sessions.pill(.all),
        Sessions.needsYouHeader,
        Sessions.headerMenu,
        Sessions.quitAll,
        Sessions.reopenAll,
        Sessions.reopenLastClosed,
        Sessions.closedSearch,
        Sessions.emptyLive,
        Sessions.emptyNoMatches,
        Sessions.closedIndexing,
        Sessions.reopenStrip,
        Sessions.reopenStripDismiss,
        Sessions.reopenProgress,
        Sessions.notificationsDenied,
        // U14: the banner above the tabs and its two controls.
        AccessibilityID.Popover.restoreBanner,
        AccessibilityID.Popover.restoreBannerReopenAll,
        AccessibilityID.Popover.restoreBannerDismiss,
        AccessibilityID.Popover.restoreBannerQuestion,
        AccessibilityID.Popover.restoreBannerReopenAtLogin,
        AccessibilityID.Popover.restoreBannerNotAtLogin,
    ]
    ids += profileIDs.map { Sessions.pill(.profile($0)) }
    for key in liveKeys {
        ids.append(Sessions.liveRow(key))
        ids.append(Sessions.liveRowMenu(key))
        ids.append(Sessions.liveRowQuit(key))
        ids.append(Sessions.liveRowRename(key))
    }
    for id in closedSessionIDs {
        ids.append(Sessions.closedRow(sessionID: id))
        ids.append(Sessions.closedRowMenu(sessionID: id))
        ids.append(Sessions.closedRowRename(sessionID: id))
        ids.append(Sessions.closedRowPendingTag(sessionID: id))
        ids.append(Sessions.pendingRow(launchID: id))
        ids.append(Sessions.pendingQuit(launchID: id))
        ids.append(Sessions.pendingRetry(launchID: id))
        ids.append(Sessions.pendingDismiss(launchID: id))
    }
    ids += foldIDs.map { Sessions.foldRow(foldID: $0) }
    return ids
}
