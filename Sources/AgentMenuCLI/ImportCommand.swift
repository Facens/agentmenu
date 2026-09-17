// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// `agentmenu import [--from <path>] [--dry-run]` (R30, R31): reads
/// `~/.config/cc-launcher/folders.conf` and folds it into `config.toml`. All
/// the parsing and planning lives in `AgentMenuKit.FoldersConfImport` — the
/// app's first-run flow uses the same functions, so this command is just
/// argument handling plus a report.
func runImport(_ args: [String], configStore: ConfigStore) -> Int32 {
    var sourcePath = FoldersConfImport.defaultSourcePath
    var dryRun = false

    var index = 0
    while index < args.count {
        switch args[index] {
        case "--from":
            index += 1
            guard index < args.count else {
                fail("agentmenu import: --from requires a path")
                return 2
            }
            sourcePath = args[index]
        case "--dry-run":
            dryRun = true
        default:
            fail("agentmenu import: unknown argument '\(args[index])'")
            return 2
        }
        index += 1
    }

    guard let text = FoldersConfImport.readSource(at: sourcePath) else {
        fail("agentmenu import: could not read '\(sourcePath)'")
        return 1
    }

    var config: Config
    do {
        config = (try configStore.load()) ?? Config()
    } catch {
        fail("agentmenu import: \(error)")
        return 2
    }

    let parsed = FoldersConfImport.parse(text)
    let plan = FoldersConfImport.plan(parsed, into: config)

    for planEntry in plan.entries {
        switch planEntry.action {
        case .add(let folder, let createsProfile):
            var line = "+ \(folder.label) (\(folder.path))"
            if let createsProfile {
                line += " -> profile '\(createsProfile.id)' (created, \(createsProfile.configDirectory))"
            } else if let profileID = folder.profileID {
                line += " -> profile '\(profileID)'"
            } else {
                line += " -> no profile (none declared)"
            }
            print(line)
        case .skip(let reason):
            print("- \(planEntry.entry.label) (\(planEntry.entry.path)): skipped — \(reason)")
        }
    }
    for bad in plan.malformed {
        fail("agentmenu import: line \(bad.line): malformed entry: \(bad.text)")
    }

    let addedCount = plan.toAdd.count
    let skippedCount = plan.toSkip.count
    print("\(addedCount) imported, \(skippedCount) skipped, \(plan.malformed.count) malformed")

    if dryRun {
        print("(dry run — config.toml not written)")
        return 0
    }

    FoldersConfImport.apply(plan, to: &config)
    do {
        try configStore.save(config)
    } catch {
        fail("agentmenu import: \(error)")
        return 1
    }
    return 0
}
