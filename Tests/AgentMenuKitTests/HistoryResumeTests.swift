// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

// R30, M1 path: a closed session resumes through the plain launch path, the
// account from the profile whose store holds the transcript and the rest of
// the preset from the folder's launch target, else the global default.
// Transcripts are real JSONL in a temp directory, indexed by the real
// `TranscriptIndex`; the agent is the real bundled Claude Code manifest.

private let sessionX = "7a1c5e90-2b34-4c8d-a0f6-3e9d1b5c7f28"
private let sessionY = "c4e8b2d6-9f10-4a37-8b5e-6d2a0c1f3e49"

private func claudeManifest() throws -> AgentManifest {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/agents/claude-code.toml")
    return try AgentManifest.parse(String(contentsOf: url, encoding: .utf8), origin: .bundled)
}

private func writeTranscript(in store: TempDir, session: String, cwd: String?, withUserRecord: Bool = true) throws {
    var lines: [String] = []
    if withUserRecord {
        var record: [String: Any] = [
            "type": "user", "sessionId": session, "entrypoint": "cli", "isSidechain": false,
            "message": ["role": "user", "content": "look at the invoices"],
            "uuid": UUID().uuidString, "timestamp": "2026-09-30T10:00:00.000Z", "version": "2.1.285",
        ]
        if let cwd { record["cwd"] = cwd }
        let data = try JSONSerialization.data(withJSONObject: record, options: [.withoutEscapingSlashes])
        lines.append(String(decoding: data, as: UTF8.self))
    } else {
        lines.append(#"{"type":"ai-title","aiTitle":"nothing said","sessionId":"\#(session)"}"#)
    }
    try store.write(lines.joined(separator: "\n") + "\n", to: "projects/-proj/\(session).jsonl")
}

private func entry(in store: TempDir, profileID: String, session: String) -> TranscriptEntry? {
    TranscriptIndex()
        .scan(profiles: [TranscriptProfile(id: profileID, directory: store.url)], now: Date())
        .first { $0.sessionId == session }
}

func runHistoryResumeTests(_ t: TestRunner) {
    t.suite("HistoryResume")

    guard let claude = t.attempt("load the real claude-code manifest", { try claudeManifest() }) else { return }

    let personalStore = TempDir("history-personal")
    let workStore = TempDir("history-work")
    let project = TempDir("history-project")
    let elsewhere = TempDir("history-elsewhere")
    defer {
        personalStore.cleanup(); workStore.cleanup(); project.cleanup(); elsewhere.cleanup()
    }

    var config = Config()
    config.defaults = Preset(model: "sonnet", effort: "low")
    config.profiles = [
        Profile(id: "work", name: "Work", configDirectory: workStore.url.path),
        Profile(id: "personal", name: "Personal", configDirectory: personalStore.url.path),
    ]
    // The folder is pinned to Work on opus. The transcript lives under
    // Personal: the account must follow the transcript, the model the folder.
    config.folders = [
        FolderTarget(label: "Project", path: project.url.path, profileID: "work", preset: Preset(model: "opus")),
    ]

    t.expectNoThrow("write the fixtures") {
        try writeTranscript(in: personalStore, session: sessionX, cwd: project.url.path)
        try writeTranscript(in: personalStore, session: sessionY, cwd: elsewhere.url.path)
    }

    let noTerminal: (Preset) -> String? = { _ in nil }
    let none = RestoreGuardSnapshot()

    // The command a history click launches: planned by `RestoreActions`, which
    // is what the app restores through, then built exactly as the owned launch
    // path builds a restore (`--resume`, never `--session-id`, KTD14).
    func restoreCommand(for indexed: TranscriptEntry) throws -> LaunchCommand {
        let planned = RestoreActions.plan(
            source: .history(indexed, recorded: nil), config: config, agent: claude,
            terminalFor: noTerminal, guardSnapshot: none
        )
        switch planned {
        case .success(let launch):
            return try launch.command(binaryPath: "/usr/local/bin/claude", launchID: "5d1c7e0a-3b6e-4d7a-9c21-0e0b7a4d1f33")
        case .failure(let refusal):
            throw NSError(domain: "restore", code: 1, userInfo: [NSLocalizedDescriptionKey: "refused: \(refusal)"])
        }
    }

    // MARK: The M1 command for an unlaunched session (the required test)

    if let indexed = t.attempt("index the unlaunched session", {
        guard let found = entry(in: personalStore, profileID: "personal", session: sessionX) else {
            throw NSError(domain: "fixture", code: 1)
        }
        return found
    }) {
        switch HistoryResume.plan(entry: indexed, config: config, agent: claude, terminalID: noTerminal, guardSnapshot: none) {
        case .failure(let refusal):
            t.expect(false, "an unlaunched restorable session plans a resume — refused: \(refusal)")
        case .success(let plan):
            t.expectEqual(plan.profile.id, "personal", "the account is the profile whose store holds the transcript, not the folder's pin")
            t.expectEqual(plan.folder?.preset.model, "opus", "the launch target on the transcript's folder supplies the rest of the preset")
            t.expectEqual(plan.resolved.preset.profile, "personal", "the resolved preset names the transcript's account")
            t.expectEqual(plan.resolved.preset.agent, "claude-code", "a resume is Claude Code whatever the folder says")
            if let command = t.attempt("build the resume command", { try restoreCommand(for: indexed) }) {
                t.expectEqual(
                    command.environment["CLAUDE_CONFIG_DIR"], personalStore.url.path,
                    "the command selects the transcript's profile through CLAUDE_CONFIG_DIR"
                )
                let args = command.arguments
                t.expectEqual(
                    Array(args.prefix(2)), ["--resume", sessionX], "the session is resumed by id"
                )
                t.expect(zip(args, args.dropFirst()).contains { $0 == "--model" && $1 == "opus" }, "the folder target's model is passed")
                t.expect(zip(args, args.dropFirst()).contains { $0 == "--effort" && $1 == "low" }, "the global default fills what the folder leaves unset")
                t.expect(!args.contains("--session-id"), "M1 history resume never carries --session-id")
                t.expectEqual(command.workingDirectory, project.url.path, "the command runs in the transcript's folder")
            }
        }
    }

    // MARK: A folder that is not a launch target uses the global default

    if let indexed = entry(in: personalStore, profileID: "personal", session: sessionY) {
        switch HistoryResume.plan(entry: indexed, config: config, agent: claude, terminalID: noTerminal, guardSnapshot: none) {
        case .failure(let refusal):
            t.expect(false, "a non-target folder still plans a resume — refused: \(refusal)")
        case .success(let plan):
            t.expect(plan.folder == nil, "no launch target names that folder")
            t.expectEqual(plan.resolved.preset.model, "sonnet", "the global default model applies")
            t.expectEqual(plan.resolved.preset.profile, "personal", "the account still comes from the transcript")
            if let command = t.attempt("build the default-preset resume command", { try restoreCommand(for: indexed) }) {
                t.expect(command.arguments.contains("sonnet"), "the default model reaches the command")
                t.expect(!command.arguments.contains("--session-id"), "no --session-id here either")
            }
        }
    } else {
        t.expect(false, "the second fixture session was indexed")
    }

    // MARK: Two entries on one folder: the one on the transcript's account wins

    do {
        var twin = config
        twin.folders = [
            FolderTarget(label: "Project (work)", path: project.url.path, profileID: "work", preset: Preset(model: "opus")),
            FolderTarget(label: "Project (personal)", path: project.url.path, profileID: "personal", preset: Preset(model: "fable")),
        ]
        if let indexed = entry(in: personalStore, profileID: "personal", session: sessionX),
           case .success(let plan) = HistoryResume.plan(
               entry: indexed, config: twin, agent: claude, terminalID: noTerminal, guardSnapshot: none
           ) {
            t.expectEqual(plan.resolved.preset.model, "fable", "of two targets on one folder, the one pinned to the transcript's account is used")
        } else {
            t.expect(false, "the twin-folder config plans a resume")
        }
    }

    // MARK: Refusals carry a reason and no plan

    do {
        t.expectNoThrow("write the not-restorable fixtures") {
            try writeTranscript(in: workStore, session: sessionY, cwd: nil, withUserRecord: false)
        }
        if let empty = entry(in: workStore, profileID: "work", session: sessionY) {
            let result = HistoryResume.plan(entry: empty, config: config, agent: claude, terminalID: noTerminal, guardSnapshot: none)
            if case .failure(.notRestorable(let reason)) = result {
                t.expect(!reason.isEmpty, "a transcript with nothing to resume gives a reason")
            } else {
                t.expect(false, "a not-restorable transcript yields no plan — got \(result)")
            }
        } else {
            t.expect(false, "the not-restorable fixture was indexed")
        }

        if let indexed = entry(in: personalStore, profileID: "personal", session: sessionX) {
            let live = LiveSession(
                key: LiveSessionKey(configDirectory: workStore.url.path, pid: 5001, procStart: 1_790_000_001),
                agentID: "claude-code", agentDisplayName: "Claude Code", profileID: "work", pid: 5001,
                sessionId: sessionX, status: .working, startedAt: Date()
            )
            let result = HistoryResume.plan(
                entry: indexed, config: config, agent: claude, terminalID: noTerminal,
                guardSnapshot: RestoreGuardSnapshot(liveSessions: [live])
            )
            t.expectEqual(result, .failure(.alreadyLive(focus: [live.key])), "a session live under another profile is focused, never resumed (R27)")

            var orphaned = config
            orphaned.profiles = orphaned.profiles.filter { $0.id != "personal" }
            t.expectEqual(
                HistoryResume.plan(entry: indexed, config: orphaned, agent: claude, terminalID: noTerminal, guardSnapshot: none),
                .failure(.unknownProfile(id: "personal")),
                "a transcript whose profile is no longer configured has no account to resume under"
            )
            t.expectEqual(
                HistoryResume.plan(entry: indexed, config: config, agent: nil, terminalID: noTerminal, guardSnapshot: none),
                .failure(.agentUnavailable),
                "no usable Claude Code, no plan"
            )
            let other = AgentManifest(
                id: "codex", displayName: "Codex", binary: "codex", projectArgument: .none, extraArgs: [],
                profileMechanism: .none, model: nil, effort: nil, permissionMode: nil, advisor: nil, origin: .bundled
            )
            t.expectEqual(
                HistoryResume.plan(entry: indexed, config: config, agent: other, terminalID: noTerminal, guardSnapshot: none),
                .failure(.agentUnavailable),
                "only Claude Code resumes a Claude Code transcript"
            )
        }
    }

    // MARK: A cwd that cannot be typed into a terminal is never resumed

    do {
        let sessionC = "1f2e3d4c-5b6a-4789-8a9b-0c1d2e3f4a5b"
        let sessionN = "2a3b4c5d-6e7f-4081-9293-a4b5c6d7e8f9"
        let sessionR = "3b4c5d6e-7f80-4192-a3b4-c5d6e7f80910"
        t.expectNoThrow("write the unsafe-cwd fixtures") {
            try writeTranscript(in: workStore, session: sessionC, cwd: "/tmp/a\u{03}b")
            try writeTranscript(in: workStore, session: sessionN, cwd: "/tmp/a\nrm -rf ~")
            try writeTranscript(in: workStore, session: sessionR, cwd: "tmp/relative")
        }
        for session in [sessionC, sessionN, sessionR] {
            guard let indexed = entry(in: workStore, profileID: "work", session: session) else {
                t.expect(false, "the unsafe-cwd fixture \(session) was indexed")
                continue
            }
            t.expectEqual(
                HistoryResume.plan(entry: indexed, config: config, agent: claude, terminalID: noTerminal, guardSnapshot: none),
                .failure(.notRestorable(reason: WorkingDirectoryRule.unsafeReason)),
                "a control character or a relative path in the cwd is refused with the shared reason"
            )
        }
    }

    // MARK: A session live where AgentMenu has no row, or already being resumed

    if let indexed = entry(in: personalStore, profileID: "personal", session: sessionX) {
        t.expectEqual(
            HistoryResume.plan(
                entry: indexed, config: config, agent: claude, terminalID: noTerminal,
                guardSnapshot: RestoreGuardSnapshot(otherLiveSessionIDs: [sessionX])
            ),
            .failure(.runningElsewhere),
            "a session live under a host the list does not show is refused (R27)"
        )
        t.expectEqual(
            HistoryResume.plan(
                entry: indexed, config: config, agent: claude, terminalID: noTerminal,
                guardSnapshot: RestoreGuardSnapshot(inFlight: [sessionX])
            ),
            .failure(.launchInFlight),
            "a session whose resume has not registered yet is refused"
        )
    }

    // MARK: Keep-running follows the terminal the launch will use

    if let indexed = entry(in: personalStore, profileID: "personal", session: sessionX) {
        var seen: Preset?
        _ = HistoryResume.plan(
            entry: indexed, config: config, agent: claude,
            terminalID: { preset in seen = preset; return "terminal-app" },
            guardSnapshot: none
        )
        t.expectEqual(seen?.profile, "personal", "the terminal lookup sees the resume's own account layer")
        t.expectEqual(seen?.model, "opus", "and the folder's layer")
    }
}
