// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Where a session's displayed name came from. The UI never needs it to draw a
/// row, but it is what tells "the agent named this" from "we fell back to the
/// first thing you typed", and tests pin the precedence through it.
public enum TitleSource: Equatable {
    /// A rename done in AgentMenu (R3). Beats everything the agent recorded.
    case rename
    case agentName
    /// Written by the CLI's own `/rename`.
    case customTitle
    case aiTitle
    case summary
    case firstPrompt
    /// The first prompt was a slash command, so the skill is the name.
    case skill
    case sessionIdPrefix
}

/// A session's resolved name and the rung of the ladder it came from.
public struct SessionTitle: Equatable {
    public let text: String
    public let source: TitleSource

    public init(text: String, source: TitleSource) {
        self.text = text
        self.source = source
    }
}

/// A slash command found at the start of a prompt, e.g. `/collect-invoices`.
public struct SkillInvocation: Equatable {
    /// The command without its leading slash. A plugin namespace stays whole
    /// (`compound-engineering:ce-plan`), because that is the name people search.
    public let name: String
    /// Whatever followed the command, trimmed. Empty for a bare invocation.
    public let arguments: String

    public init(name: String, arguments: String) {
        self.name = name
        self.arguments = arguments
    }

    /// True when nothing followed the command. Only bare invocations fold in the
    /// Closed list (R29): a scheduled run of `/collect-invoices` is noise, while
    /// `/review-pr 1234` names a piece of work someone will look for again.
    public var isBare: Bool { arguments.isEmpty }

    /// Commands that steer the session rather than start work in it. A
    /// transcript that opens with `/clear` is not "about" `/clear`, so these are
    /// skipped when looking for the prompt that names a session.
    public static let lifecycleCommands: Set<String> = [
        "clear", "compact", "resume", "exit", "help", "model", "config",
        "cost", "status", "context", "login", "logout", "rename",
    ]

    public var isLifecycleCommand: Bool { Self.lifecycleCommands.contains(name) }

    /// Reads a skill invocation out of a prompt, in either of the two shapes a
    /// transcript stores it in: the CLI's wrapper
    /// (`<command-name>/x</command-name><command-args>…</command-args>`, the
    /// form a typed slash command actually takes), and a literal `/x args`
    /// (the form a headless run's argument takes). Nil when the prompt is
    /// neither, which includes a prompt that merely starts with a file path.
    public static func parse(prompt: String) -> SkillInvocation? {
        if let name = between("<command-name>", "</command-name>", in: prompt) {
            let bare = name.hasPrefix("/") ? String(name.dropFirst()) : name
            guard isSkillName(bare) else { return nil }
            let args = between("<command-args>", "</command-args>", in: prompt) ?? ""
            return SkillInvocation(name: bare, arguments: args)
        }

        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("/") else { return nil }
        let body = trimmed.dropFirst()
        let token = body.prefix { !$0.isWhitespace }
        guard isSkillName(String(token)) else { return nil }
        let rest = body.dropFirst(token.count).trimmingCharacters(in: .whitespacesAndNewlines)
        return SkillInvocation(name: String(token), arguments: rest)
    }

    private static func between(_ open: String, _ close: String, in text: String) -> String? {
        guard let start = text.range(of: open),
              let end = text.range(of: close, range: start.upperBound..<text.endIndex)
        else { return nil }
        return text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Letters, digits and `-_:.` only: enough for every skill and plugin name,
    /// and strict enough that `/Users/me/project` is not read as a command.
    private static func isSkillName(_ text: String) -> Bool {
        guard let first = text.first, first.isLetter || first.isNumber else { return false }
        return text.allSatisfy { $0.isLetter || $0.isNumber || "-_:.".contains($0) }
    }
}

/// Picks a session's name from the pieces the transcript index recovered.
public enum SessionTitles {
    /// The longest name a fallback derived from a prompt may have. A first
    /// prompt can be a pasted page; a row has one line.
    public static let maxPromptLength = 80

    /// Agent name, custom title, AI title, summary, first prompt (or the skill
    /// it invoked), then the id prefix. That is the CLI's own order, so a name
    /// here matches the one the CLI shows for the same session. An AgentMenu
    /// rename sits above all of them.
    public static func resolve(
        rename: String? = nil,
        agentName: String? = nil,
        customTitle: String? = nil,
        aiTitle: String? = nil,
        summary: String? = nil,
        firstPrompt: String? = nil,
        skill: SkillInvocation? = nil,
        sessionId: String
    ) -> SessionTitle {
        let ladder: [(String?, TitleSource)] = [
            (rename, .rename),
            (agentName, .agentName),
            (customTitle, .customTitle),
            (aiTitle, .aiTitle),
            (summary, .summary),
        ]
        for (candidate, source) in ladder {
            if let text = candidate.trimmedNonEmpty {
                return SessionTitle(text: text, source: source)
            }
        }
        if let skill {
            return SessionTitle(text: "/\(skill.name)", source: .skill)
        }
        if let firstPrompt, let text = promptTitle(firstPrompt) {
            return SessionTitle(text: text, source: .firstPrompt)
        }
        return SessionTitle(text: String(sessionId.prefix(8)), source: .sessionIdPrefix)
    }

    /// The first non-empty line of a prompt, whitespace collapsed and capped.
    static func promptTitle(_ prompt: String) -> String? {
        guard let line = prompt
            .split(whereSeparator: \.isNewline)
            .map({ $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") })
            .first(where: { !$0.isEmpty })
        else { return nil }
        guard line.count > maxPromptLength else { return line }
        return String(line.prefix(maxPromptLength - 1)) + "…"
    }
}
