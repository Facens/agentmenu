// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// Parses `text` expecting a `TOMLError` and asserts its `line` and that its
/// `reason` mentions `reasonContains`. `t.expectThrows` alone can't check
/// which line/reason came back, so every rejection scenario goes through
/// this instead.
private func expectTOMLError(
    _ t: TestRunner,
    _ text: String,
    line: Int,
    reasonContains: String,
    _ what: String
) {
    do {
        _ = try TOMLDocument.parse(text)
        t.expect(false, "\(what) — expected a thrown error, none was thrown")
    } catch let error as TOMLError {
        t.expectEqual(error.line, line, "\(what) — line")
        t.expect(
            error.reason.localizedCaseInsensitiveContains(reasonContains),
            "\(what) — reason '\(error.reason)' does not mention '\(reasonContains)'"
        )
    } catch {
        t.expect(false, "\(what) — wrong error type: \(error)")
    }
}

func runTOMLTests(_ t: TestRunner) {
    t.suite("TOML")

    // MARK: 1-2. Round-trip and byte-stable re-serialization

    let doc1Text = """
    name = "agentmenu"
    keep_me = 1

    [model]
    flag = "--model"
    values = ["fable", "opus", "sonnet"]

    [[folders]]
    path = "/a"
    label = "A"

    [[folders]]
    path = "/b"
    """

    if let parsed = t.attempt("doc1", { try TOMLDocument.parse(doc1Text) }) {
        let firstPass = parsed.serialized()
        if let roundTripped = t.attempt("doc1 reparse", { try TOMLDocument.parse(firstPass) }) {
            t.expectEqual(roundTripped.root, parsed.root, "doc1 round-trips through serialize/parse")
        }
        if let secondPass = t.attempt("doc1 second serialize", { try TOMLDocument.parse(firstPass).serialized() }) {
            t.expectEqual(secondPass, firstPass, "doc1 serializing twice is byte-identical")
        }
    }

    // The stronger, input-shape-independent version of (2): re-serializing
    // whatever `serialized()` produced must be byte-identical, even for a
    // document whose original section order the grouped emission changes
    // (array-of-tables before a table header, here).
    let arrayFirstText = """
    [[folders]]
    path = "/a"

    [model]
    flag = "--model"
    """
    if let once = t.attempt("array-first document", { try TOMLDocument.parse(arrayFirstText).serialized() }) {
        if let twice = t.attempt("array-first second serialize", { try TOMLDocument.parse(once).serialized() }) {
            t.expectEqual(twice, once, "array-first document serializes stably on the second pass")
        }
    }

    // MARK: 3. Unknown keys survive a round-trip in position

    let unknownKeyText = """
    alpha = 1
    mystery_key = "untouched"
    beta = 2

    [table]
    known = 1
    also_mystery = 2
    zeta = 3
    """
    if let parsed = t.attempt("unknown-key document", { try TOMLDocument.parse(unknownKeyText) }) {
        t.expectEqual(parsed.root.keys, ["alpha", "mystery_key", "beta", "table"], "root key order preserved")
        t.expectEqual(parsed.root["table"]?.tableValue?.keys, ["known", "also_mystery", "zeta"], "[table] key order preserved")

        if let reparsed = t.attempt("unknown-key document reparse", { try TOMLDocument.parse(parsed.serialized()) }) {
            t.expectEqual(reparsed.root, parsed.root, "unknown keys survive a serialize/parse cycle")
            t.expectEqual(reparsed.root.keys, ["alpha", "mystery_key", "beta", "table"], "root order still intact after rewrite")
        }
    }

    // MARK: 4. String forms

    let basicEscapesText = #"""
    s = "a\"b\\c\nd\te\rf\0g\bh\fié\U0001F600"
    """#
    if let parsed = t.attempt("basic string escapes", { try TOMLDocument.parse(basicEscapesText) }) {
        let expected = "a\"b\\c\nd\te\rf\0g\u{08}h\u{0C}i\u{00E9}\u{1F600}"
        t.expectEqual(parsed.root["s"]?.stringValue, expected, "every basic escape decodes correctly")

        // \0, \b, \f are control characters the serializer re-emits as
        // \uXXXX (basicQuote's fallback) rather than a short escape; confirm
        // parser and serializer agree on that spelling round-trip.
        if let reparsed = t.attempt("escapes reparse", { try TOMLDocument.parse(parsed.serialized()) }) {
            t.expectEqual(reparsed.root, parsed.root, "control-char escapes round-trip through \\uXXXX")
        }
    }

    let literalText = #"s = 'a\nb\"c'"#
    if let parsed = t.attempt("literal string", { try TOMLDocument.parse(literalText) }) {
        t.expectEqual(parsed.root["s"]?.stringValue, #"a\nb\"c"#, "literal string has no escapes, taken verbatim")
    }

    let multilineOpeningNewlineText = "s = \"\"\"\nhello\nworld\"\"\""
    if let parsed = t.attempt("multi-line basic string opening newline", { try TOMLDocument.parse(multilineOpeningNewlineText) }) {
        t.expectEqual(parsed.root["s"]?.stringValue, "hello\nworld", "opening newline stripped, inner newline kept")
    }

    let multilineBackslashText = "s = \"\"\"\nhello \\\n   world\"\"\""
    if let parsed = t.attempt("multi-line basic string line-ending backslash", { try TOMLDocument.parse(multilineBackslashText) }) {
        t.expectEqual(parsed.root["s"]?.stringValue, "hello world", "backslash-newline trims the following whitespace")
    }

    let multilineLiteralText = "s = '''\nraw \\n text'''"
    if let parsed = t.attempt("multi-line literal string", { try TOMLDocument.parse(multilineLiteralText) }) {
        t.expectEqual(parsed.root["s"]?.stringValue, "raw \\n text", "multi-line literal keeps backslashes literal")
    }

    // MARK: 5. Quote/backslash value round-trips exactly

    let literalQuotedText = #"advisor_disable = '{"advisorModel":""}'"#
    if let parsed = t.attempt("value with quotes, no backslash", { try TOMLDocument.parse(literalQuotedText) }) {
        t.expectEqual(parsed.root["advisor_disable"]?.stringValue, #"{"advisorModel":""}"#, "literal-quoted value parses verbatim")
        if let reparsed = t.attempt("quote-bearing value reparse", { try TOMLDocument.parse(parsed.serialized()) }) {
            t.expectEqual(reparsed.root, parsed.root, "quote-bearing value round-trips through serialize/parse")
        }
    }

    var quoteAndBackslashTable = TOMLTable()
    quoteAndBackslashTable["s"] = .string(#"a "quoted" \ value"#)
    let quoteAndBackslashDoc = TOMLDocument(root: quoteAndBackslashTable)
    if let reparsed = t.attempt("value with quote and backslash", { try TOMLDocument.parse(quoteAndBackslashDoc.serialized()) }) {
        t.expectEqual(reparsed.root["s"]?.stringValue, #"a "quoted" \ value"#, "quote-and-backslash value round-trips")
    }

    // MARK: 6. Numbers and booleans

    let numbersText = """
    plain = 42
    negative = -7
    signed_positive = +3
    underscored = 1_000_000
    pi = 3.14
    yes = true
    no = false
    """
    if let parsed = t.attempt("integers, float, booleans", { try TOMLDocument.parse(numbersText) }) {
        t.expectEqual(parsed.root["plain"]?.intValue, 42, "plain integer")
        t.expectEqual(parsed.root["negative"]?.intValue, -7, "negative integer")
        t.expectEqual(parsed.root["signed_positive"]?.intValue, 3, "leading-plus integer")
        t.expectEqual(parsed.root["underscored"]?.intValue, 1_000_000, "underscored integer")
        t.expectEqual(parsed.root["pi"]?.doubleValue, 3.14, "float")
        t.expectEqual(parsed.root["yes"]?.boolValue, true, "true")
        t.expectEqual(parsed.root["no"]?.boolValue, false, "false")
    }

    // MARK: 7. Nested arrays, multi-line array with trailing comma/comment, inline table

    let arraysAndInlineText = """
    nested = [[1, 2], [3, 4]]
    spread = [
        "a",
        # a comment in the middle
        "b",
        "c",
    ]
    inline = { name = "x", count = 2 }
    """
    if let parsed = t.attempt("nested/multi-line arrays, inline table", { try TOMLDocument.parse(arraysAndInlineText) }) {
        let nested = parsed.root["nested"]?.arrayValue?.map { $0.arrayValue?.compactMap(\.intValue) ?? [] }
        t.expectEqual(nested, [[1, 2], [3, 4]], "nested arrays")
        t.expectEqual(parsed.root["spread"]?.stringArrayValue, ["a", "b", "c"], "multi-line array with trailing comma and interior comment")
        t.expectEqual(parsed.root["inline"]?.tableValue?["name"]?.stringValue, "x", "inline table string field")
        t.expectEqual(parsed.root["inline"]?.tableValue?["count"]?.intValue, 2, "inline table int field")
    }

    // MARK: 8. Rejections

    expectTOMLError(t, "[table]\na = 1\na = 2\n", line: 3, reasonContains: "duplicate", "duplicate key in same table")
    expectTOMLError(t, "[table]\nx = 1\n[table]\ny = 2\n", line: 3, reasonContains: "duplicate", "duplicate table header")
    expectTOMLError(t, "x = 1\n[x]\ny = 2\n", line: 2, reasonContains: "non-table", "table header collides with non-table value")
    expectTOMLError(t, "s = \"unterminated\n", line: 1, reasonContains: "unterminated", "unterminated string")
    expectTOMLError(t, "a = [1, 2\n", line: 1, reasonContains: "unterminated", "unterminated array")
    expectTOMLError(t, "a = 1 2\n", line: 1, reasonContains: "unexpected content", "garbage after a value")
    expectTOMLError(t, "d = 1979-05-27\n", line: 1, reasonContains: "datetime", "datetime literal rejected")
    expectTOMLError(t, "d = 07:32:00\n", line: 1, reasonContains: "datetime", "time literal rejected")
    expectTOMLError(t, "= 1\n", line: 1, reasonContains: "key", "malformed key (missing)")
    expectTOMLError(t, "a. = 1\n", line: 1, reasonContains: "key", "malformed key (trailing dot)")
    expectTOMLError(t, "a = bogus\n", line: 1, reasonContains: "unsupported", "value of no supported kind")
    expectTOMLError(t, "s = \"bad \\q escape\"\n", line: 1, reasonContains: "escape", "unknown escape sequence")
    expectTOMLError(t, "s = \"\"\"\nline one\nbad \\q here\"\"\"\n", line: 3, reasonContains: "escape", "unknown escape reports the line it's actually on")

    // MARK: 9. value(at:) / set(_:at:), and position stability on overwrite

    var pathTable = TOMLTable()
    pathTable.set(.string("claude"), at: ["binary"])
    pathTable.set(.array(["fable", "opus", "sonnet"].map(TOMLValue.string)), at: ["model", "values"])
    pathTable.set(.string("--model"), at: ["model", "flag"])

    t.expectEqual(pathTable.value(at: ["binary"])?.stringValue, "claude", "top-level value(at:)")
    t.expectEqual(pathTable.value(at: ["model", "flag"])?.stringValue, "--model", "nested value(at:)")
    t.expectEqual(pathTable.value(at: ["model", "values"])?.stringArrayValue, ["fable", "opus", "sonnet"], "nested array value(at:)")
    t.expectEqual(pathTable.value(at: ["model", "missing"]), nil, "missing nested key is nil")
    t.expectEqual(pathTable.value(at: ["nope", "at", "all"]), nil, "missing top-level path is nil")
    t.expectEqual(pathTable.keys, ["binary", "model"], "set(_:at:) created keys in insertion order")

    // Overwriting an existing leaf keeps its position among siblings.
    pathTable["z_last"] = .integer(1)
    pathTable.set(.string("claude-2"), at: ["binary"])
    t.expectEqual(pathTable.keys, ["binary", "model", "z_last"], "overwriting an existing key keeps its position")
    t.expectEqual(pathTable.value(at: ["binary"])?.stringValue, "claude-2", "overwrite took effect")

    // MARK: 10. The real shipped manifest

    let thisFile = URL(fileURLWithPath: #filePath)
    let manifestURL = thisFile
        .deletingLastPathComponent() // TOMLTests.swift -> AgentMenuKitTests
        .deletingLastPathComponent() // -> Tests
        .deletingLastPathComponent() // -> repository root
        .appendingPathComponent("Resources/agents/claude-code.toml")

    if let doc = t.attempt("shipped claude-code.toml", { try TOMLDocument.parse(contentsOf: manifestURL) }) {
        t.expectEqual(doc.root["id"]?.stringValue, "claude-code", "manifest id")
        t.expectEqual(doc.root["binary"]?.stringValue, "claude", "manifest binary")
        t.expectEqual(
            doc.root.value(at: ["model", "values"])?.stringArrayValue,
            ["fable", "opus", "sonnet"],
            "manifest model.values"
        )
        t.expectEqual(
            doc.root.value(at: ["permission_mode", "bypass_values"])?.stringArrayValue,
            ["bypassPermissions", "dontAsk"],
            "manifest permission_mode.bypass_values — dontAsk added (security review finding 5): its name is"
                + " unambiguous (\"don't ask\") and nothing in --help or research-notes.md contradicts it;"
                + " acceptEdits/auto/manual stay unmarked because their prompting behaviour was never established"
        )
        let disableArgs = doc.root.value(at: ["advisor", "disable_args"])?.stringArrayValue
        t.expectEqual(disableArgs?.count, 2, "manifest advisor.disable_args has two elements")
        t.expectEqual(disableArgs?[1], #"{"advisorModel":""}"#, "manifest advisor.disable_args[1] is the empty-advisor-model settings blob")

        // The manifest is the actual production path (the app rewrites the
        // user's config), and it's the only fixture that exercises an empty
        // array (`extra_args = []`) and a literal-quoted string nested inside
        // an array literal (`disable_args`'s second element) at once.
        let once = doc.serialized()
        if let reparsed = t.attempt("manifest reparse", { try TOMLDocument.parse(once) }) {
            t.expectEqual(reparsed.root, doc.root, "shipped manifest round-trips")
            t.expectEqual(reparsed.serialized(), once, "shipped manifest re-serializes byte-identically")
        }
    }
}
