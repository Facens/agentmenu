// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A parse failure, naming the 1-based source line it occurred on.
public struct TOMLError: Error, CustomStringConvertible, Equatable {
    public let line: Int
    public let reason: String

    public init(line: Int, reason: String) {
        self.line = line
        self.reason = reason
    }

    public var description: String { "line \(line): \(reason)" }
}

/// A parsed TOML document: an order-preserving root table, plus the ability
/// to turn back into text.
public struct TOMLDocument {
    public var root: TOMLTable

    public init(root: TOMLTable = TOMLTable()) {
        self.root = root
    }

    public static func parse(_ text: String) throws -> TOMLDocument {
        var scanner = TOMLScanner(text)
        let root = try scanner.parseDocument()
        return TOMLDocument(root: root)
    }

    public static func parse(contentsOf url: URL) throws -> TOMLDocument {
        let text = try String(contentsOf: url, encoding: .utf8)
        return try parse(text)
    }
}

/// Recursive-descent scanner for the TOML subset. Operates on the whole
/// document as a `[Character]` array so string escapes and multi-line
/// constructs can look arbitrarily far ahead without re-slicing the input.
struct TOMLScanner {
    private let chars: [Character]
    private var pos = 0
    private var line = 1

    private var root = TOMLTable()
    /// The dotted path of the table that plain `key = value` lines currently
    /// write into — the most recently opened `[header]` or `[[header]]`.
    private var currentPath: [String] = []
    /// True when `currentPath` names an array of tables, so writes target its
    /// last element rather than the table directly.
    private var currentIsArrayTable = false
    /// Header paths already opened with `[path]`, to catch duplicates. Array-
    /// of-table headers are expected to repeat, so they are not tracked here.
    private var declaredTables: Set<[String]> = []
    /// Header paths opened with `[[path]]`, so a later `[path]` can be
    /// rejected as colliding with an array of tables.
    private var declaredArrayTables: Set<[String]> = []

    init(_ text: String) {
        chars = Array(text)
    }

    mutating func parseDocument() throws -> TOMLTable {
        skipWhitespaceAndComments(acrossLines: true)
        while pos < chars.count {
            if peek() == "[" {
                try parseTableHeader()
            } else {
                try parseKeyValueLine()
            }
            skipWhitespaceAndComments(acrossLines: true)
        }
        return root
    }

    // MARK: - Cursor

    private func peek(_ offset: Int = 0) -> Character? {
        let i = pos + offset
        return i < chars.count ? chars[i] : nil
    }

    private mutating func advance() {
        guard pos < chars.count else { return }
        if chars[pos] == "\n" { line += 1 }
        pos += 1
    }

    private mutating func skipInlineWhitespace() {
        while let c = peek(), c == " " || c == "\t" {
            advance()
        }
    }

    private mutating func skipWhitespaceAndComments(acrossLines: Bool) {
        while let c = peek() {
            if c == " " || c == "\t" || c == "\r" {
                advance()
            } else if c == "\n" {
                if !acrossLines { return }
                advance()
            } else if c == "#" {
                skipToEndOfLine()
            } else {
                return
            }
        }
    }

    private mutating func skipToEndOfLine() {
        while let c = peek(), c != "\n" {
            advance()
        }
    }

    /// After a value or a header, only inline whitespace, an optional
    /// comment, and then a newline/EOF may follow.
    private mutating func expectLineEnd() throws {
        skipInlineWhitespace()
        if peek() == "#" {
            skipToEndOfLine()
        }
        guard peek() == nil || peek() == "\n" || peek() == "\r" else {
            throw TOMLError(line: line, reason: "unexpected content after value")
        }
        if peek() == "\r" { advance() }
        if peek() == "\n" { advance() }
    }

    // MARK: - Table headers

    private mutating func parseTableHeader() throws {
        let startLine = line
        advance() // consume '['
        var isArray = false
        if peek() == "[" {
            isArray = true
            advance()
        }
        skipInlineWhitespace()
        let path = try parseDottedKey()
        if path.isEmpty {
            throw TOMLError(line: startLine, reason: "empty table header")
        }
        skipInlineWhitespace()
        guard peek() == "]" else {
            throw TOMLError(line: line, reason: "expected ']' to close table header")
        }
        advance()
        if isArray {
            guard peek() == "]" else {
                throw TOMLError(line: line, reason: "expected ']]' to close array-of-tables header")
            }
            advance()
        }
        try expectLineEnd()
        if isArray {
            try openArrayTable(path: path, line: startLine)
        } else {
            try openTable(path: path, line: startLine)
        }
    }

    private mutating func openTable(path: [String], line errLine: Int) throws {
        if declaredTables.contains(path) {
            throw TOMLError(line: errLine, reason: "duplicate table header [\(Self.displayPath(path))]")
        }
        if declaredArrayTables.contains(path) {
            throw TOMLError(line: errLine, reason: "[\(Self.displayPath(path))] collides with an array of tables")
        }
        try Self.ensureTablePath(&root, path: path, line: errLine)
        declaredTables.insert(path)
        currentPath = path
        currentIsArrayTable = false
    }

    private mutating func openArrayTable(path: [String], line errLine: Int) throws {
        if declaredTables.contains(path) {
            throw TOMLError(line: errLine, reason: "[[\(Self.displayPath(path))]] collides with an existing table")
        }
        try Self.appendArrayTableEntry(&root, path: path, line: errLine)
        declaredArrayTables.insert(path)
        currentPath = path
        currentIsArrayTable = true
    }

    /// Creates (or reuses) tables along `path`, erroring if a segment is
    /// already a non-table value.
    private static func ensureTablePath(_ table: inout TOMLTable, path: [String], line errLine: Int) throws {
        let key = path[0]
        let rest = Array(path.dropFirst())
        if let existing = table[key] {
            guard case .table(var nested) = existing else {
                throw TOMLError(line: errLine, reason: "table [\(key)] collides with an existing non-table value")
            }
            if !rest.isEmpty {
                try ensureTablePath(&nested, path: rest, line: errLine)
                table[key] = .table(nested)
            }
        } else {
            var nested = TOMLTable()
            if !rest.isEmpty {
                try ensureTablePath(&nested, path: rest, line: errLine)
            }
            table[key] = .table(nested)
        }
    }

    /// Navigates to `path`'s parent (creating tables as needed) and appends a
    /// fresh empty table to the array named by the last path segment.
    private static func appendArrayTableEntry(_ table: inout TOMLTable, path: [String], line errLine: Int) throws {
        let key = path[0]
        let rest = Array(path.dropFirst())
        if rest.isEmpty {
            if let existing = table[key] {
                guard case .array(var elements) = existing else {
                    throw TOMLError(line: errLine, reason: "key '\(key)' is not an array of tables")
                }
                elements.append(.table(TOMLTable()))
                table[key] = .array(elements)
            } else {
                table[key] = .array([.table(TOMLTable())])
            }
            return
        }
        if let existing = table[key] {
            guard case .table(var nested) = existing else {
                throw TOMLError(line: errLine, reason: "key '\(key)' is not a table")
            }
            try appendArrayTableEntry(&nested, path: rest, line: errLine)
            table[key] = .table(nested)
        } else {
            var nested = TOMLTable()
            try appendArrayTableEntry(&nested, path: rest, line: errLine)
            table[key] = .table(nested)
        }
    }

    private static func displayPath(_ path: [String]) -> String {
        path.joined(separator: ".")
    }

    // MARK: - Key/value lines

    private mutating func parseKeyValueLine() throws {
        let startLine = line
        let keyPath = try parseDottedKey()
        if keyPath.isEmpty {
            throw TOMLError(line: startLine, reason: "malformed key")
        }
        skipInlineWhitespace()
        guard peek() == "=" else {
            throw TOMLError(line: line, reason: "expected '=' after key")
        }
        advance()
        skipInlineWhitespace()
        let value = try parseValue()
        try expectLineEnd()
        try withCurrentTable(startLine) { table in
            try Self.insertLeaf(&table, path: keyPath, value: value, line: startLine)
        }
    }

    /// Re-navigates from `root` down to the table `currentPath` names (its
    /// last array element, when it names an array of tables), runs `body`
    /// against it, and writes the mutation back.
    private mutating func withCurrentTable(_ errLine: Int, _ body: (inout TOMLTable) throws -> Void) throws {
        try Self.modify(&root, path: currentPath, arrayMode: currentIsArrayTable, line: errLine, body: body)
    }

    private static func modify(
        _ table: inout TOMLTable,
        path: [String],
        arrayMode: Bool,
        line errLine: Int,
        body: (inout TOMLTable) throws -> Void
    ) throws {
        guard let head = path.first else {
            try body(&table)
            return
        }
        let rest = Array(path.dropFirst())
        if !rest.isEmpty {
            guard case .table(var nested)? = table[head] else {
                throw TOMLError(line: errLine, reason: "internal: table '\(head)' missing")
            }
            try modify(&nested, path: rest, arrayMode: arrayMode, line: errLine, body: body)
            table[head] = .table(nested)
            return
        }
        if arrayMode {
            guard case .array(var elements)? = table[head], case .table(var last)? = elements.last else {
                throw TOMLError(line: errLine, reason: "internal: array of tables '\(head)' missing")
            }
            try body(&last)
            elements[elements.count - 1] = .table(last)
            table[head] = .array(elements)
        } else {
            guard case .table(var nested)? = table[head] else {
                throw TOMLError(line: errLine, reason: "internal: table '\(head)' missing")
            }
            try body(&nested)
            table[head] = .table(nested)
        }
    }

    /// Inserts a (possibly dotted) key into `table`, creating intermediate
    /// tables and rejecting a duplicate leaf key or a non-table collision.
    private static func insertLeaf(_ table: inout TOMLTable, path: [String], value: TOMLValue, line errLine: Int) throws {
        let key = path[0]
        let rest = Array(path.dropFirst())
        if rest.isEmpty {
            if table[key] != nil {
                throw TOMLError(line: errLine, reason: "duplicate key '\(key)'")
            }
            table[key] = value
            return
        }
        if let existing = table[key] {
            guard case .table(var nested) = existing else {
                throw TOMLError(line: errLine, reason: "key '\(key)' is not a table")
            }
            try insertLeaf(&nested, path: rest, value: value, line: errLine)
            table[key] = .table(nested)
        } else {
            var nested = TOMLTable()
            try insertLeaf(&nested, path: rest, value: value, line: errLine)
            table[key] = .table(nested)
        }
    }

    // MARK: - Keys

    private mutating func parseDottedKey() throws -> [String] {
        var parts: [String] = [try parseKeySegment()]
        skipInlineWhitespace()
        while peek() == "." {
            advance()
            skipInlineWhitespace()
            parts.append(try parseKeySegment())
            skipInlineWhitespace()
        }
        return parts
    }

    private mutating func parseKeySegment() throws -> String {
        guard let c = peek() else {
            throw TOMLError(line: line, reason: "expected a key")
        }
        if c == "\"" {
            return try parseBasicString(multilineAllowed: false)
        }
        if c == "'" {
            return try parseLiteralString(multilineAllowed: false)
        }
        if isBareTOMLKeyChar(c) {
            var s = ""
            while let c = peek(), isBareTOMLKeyChar(c) {
                s.append(c)
                advance()
            }
            return s
        }
        throw TOMLError(line: line, reason: "malformed key")
    }

    // MARK: - Values

    private mutating func parseValue() throws -> TOMLValue {
        guard let c = peek() else {
            throw TOMLError(line: line, reason: "expected a value")
        }
        switch c {
        case "\"":
            return .string(try parseBasicString(multilineAllowed: true))
        case "'":
            return .string(try parseLiteralString(multilineAllowed: true))
        case "[":
            return try parseArray()
        case "{":
            return try parseInlineTable()
        case "t", "f":
            return try parseBoolean()
        default:
            return try parseNumberOrDate()
        }
    }

    private mutating func parseBoolean() throws -> TOMLValue {
        if matchKeyword("true") { return .boolean(true) }
        if matchKeyword("false") { return .boolean(false) }
        throw TOMLError(line: line, reason: "unsupported value")
    }

    private mutating func matchKeyword(_ word: String) -> Bool {
        let letters = Array(word)
        guard pos + letters.count <= chars.count else { return false }
        for i in 0..<letters.count where chars[pos + i] != letters[i] { return false }
        if let after = peek(letters.count), isBareTOMLKeyChar(after) { return false }
        pos += letters.count
        return true
    }

    private mutating func parseNumberOrDate() throws -> TOMLValue {
        let startLine = line
        var token = ""
        while let c = peek(), isNumberOrDateChar(c) {
            token.append(c)
            advance()
        }
        if token.isEmpty {
            throw TOMLError(line: startLine, reason: "unsupported value")
        }
        if isValidInteger(token) {
            guard let v = Int(token.replacingOccurrences(of: "_", with: "")) else {
                throw TOMLError(line: startLine, reason: "malformed integer '\(token)'")
            }
            return .integer(v)
        }
        if isValidFloat(token) {
            guard let v = Double(token.replacingOccurrences(of: "_", with: "")) else {
                throw TOMLError(line: startLine, reason: "malformed float '\(token)'")
            }
            return .double(v)
        }
        if looksLikeDate(token) {
            throw TOMLError(line: startLine, reason: "datetime values are not supported ('\(token)')")
        }
        throw TOMLError(line: startLine, reason: "unsupported value '\(token)'")
    }

    private func isNumberOrDateChar(_ c: Character) -> Bool {
        c.isASCII && ((c.isNumber && c.isASCII) || "+-.:_eEtTzZ".contains(c))
    }

    /// Advances `i` over a run of ASCII digits with single, non-leading,
    /// non-trailing `_` separators — the shared shape of an integer's digits
    /// and each digit run in a float (mantissa, fraction, exponent).
    private func consumeDigitRun(_ s: String, _ i: inout String.Index) -> Bool {
        let end = s.endIndex
        var any = false
        var prevUnderscore = false
        var first = true
        while i < end, (s[i].isASCII && s[i].isNumber) || s[i] == "_" {
            if s[i] == "_" {
                if first || prevUnderscore { return false }
                prevUnderscore = true
            } else {
                any = true
                prevUnderscore = false
            }
            first = false
            i = s.index(after: i)
        }
        return any && !prevUnderscore
    }

    private func isValidInteger(_ s: String) -> Bool {
        var i = s.startIndex
        if i < s.endIndex, s[i] == "+" || s[i] == "-" { i = s.index(after: i) }
        return consumeDigitRun(s, &i) && i == s.endIndex
    }

    private func isValidFloat(_ s: String) -> Bool {
        if s.contains(where: { ":TtZz".contains($0) }) { return false }
        var i = s.startIndex
        let end = s.endIndex
        if i < end, s[i] == "+" || s[i] == "-" { i = s.index(after: i) }
        guard consumeDigitRun(s, &i) else { return false }
        var hasFracOrExp = false
        if i < end, s[i] == "." {
            i = s.index(after: i)
            hasFracOrExp = true
            guard consumeDigitRun(s, &i) else { return false }
        }
        if i < end, s[i] == "e" || s[i] == "E" {
            i = s.index(after: i)
            hasFracOrExp = true
            if i < end, s[i] == "+" || s[i] == "-" { i = s.index(after: i) }
            guard consumeDigitRun(s, &i) else { return false }
        }
        return hasFracOrExp && i == end
    }

    private func looksLikeDate(_ s: String) -> Bool {
        guard let first = s.first, first.isASCII, first.isNumber else { return false }
        if s.contains(":") { return true }
        return s.dropFirst().contains("-")
    }

    // MARK: - Strings

    private mutating func parseBasicString(multilineAllowed: Bool) throws -> String {
        try parseString(quote: "\"", allowsEscapes: true, multilineAllowed: multilineAllowed)
    }

    private mutating func parseLiteralString(multilineAllowed: Bool) throws -> String {
        try parseString(quote: "'", allowsEscapes: false, multilineAllowed: multilineAllowed)
    }

    /// Shared body for basic and literal strings: same delimiter handling,
    /// same triple-quote multi-line rules; only escape processing differs.
    private mutating func parseString(quote: Character, allowsEscapes: Bool, multilineAllowed: Bool) throws -> String {
        let startLine = line
        advance() // opening quote
        var isMultiline = false
        if multilineAllowed, peek() == quote, peek(1) == quote {
            isMultiline = true
            advance(); advance()
            consumeOpeningNewline()
        }
        var result = ""
        while true {
            guard let c = peek() else {
                throw TOMLError(line: startLine, reason: "unterminated string")
            }
            if c == quote {
                if !isMultiline {
                    advance()
                    return result
                }
                if peek(1) == quote, peek(2) == quote {
                    advance(); advance(); advance()
                    return result
                }
                result.append(c)
                advance()
            } else if allowsEscapes && c == "\\" {
                if isMultiline, let n = peek(1), n == " " || n == "\t" || n == "\n" || n == "\r" {
                    advance() // backslash
                    while let w = peek(), w == " " || w == "\t" || w == "\n" || w == "\r" {
                        advance()
                    }
                    continue
                }
                let escapeLine = line
                advance() // backslash
                result += try parseEscape(line: escapeLine)
            } else if !isMultiline && c == "\n" {
                throw TOMLError(line: startLine, reason: "unterminated string")
            } else {
                result.append(c)
                advance()
            }
        }
    }

    /// A newline immediately after a multi-line string's opening delimiter is
    /// stripped and does not become part of the value.
    private mutating func consumeOpeningNewline() {
        if peek() == "\r", peek(1) == "\n" {
            advance(); advance()
        } else if peek() == "\n" {
            advance()
        }
    }

    private mutating func parseEscape(line escapeLine: Int) throws -> String {
        guard let c = peek() else {
            throw TOMLError(line: escapeLine, reason: "unterminated string")
        }
        switch c {
        case "\"": advance(); return "\""
        case "\\": advance(); return "\\"
        case "n": advance(); return "\n"
        case "t": advance(); return "\t"
        case "r": advance(); return "\r"
        case "0": advance(); return "\0"
        case "b": advance(); return "\u{08}"
        case "f": advance(); return "\u{0C}"
        case "u":
            advance()
            return try parseUnicodeEscape(digits: 4, line: escapeLine)
        case "U":
            advance()
            return try parseUnicodeEscape(digits: 8, line: escapeLine)
        default:
            throw TOMLError(line: escapeLine, reason: "unknown escape sequence '\\\(c)'")
        }
    }

    private mutating func parseUnicodeEscape(digits: Int, line escapeLine: Int) throws -> String {
        var hex = ""
        for _ in 0..<digits {
            guard let c = peek(), c.isHexDigit else {
                throw TOMLError(line: escapeLine, reason: "invalid unicode escape")
            }
            hex.append(c)
            advance()
        }
        guard let scalarValue = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(scalarValue) else {
            throw TOMLError(line: escapeLine, reason: "invalid unicode escape '\\u\(hex)'")
        }
        return String(Character(scalar))
    }

    // MARK: - Arrays and inline tables

    private mutating func parseArray() throws -> TOMLValue {
        let startLine = line
        advance() // consume '['
        var elements: [TOMLValue] = []
        skipArrayWhitespace()
        if peek() == "]" {
            advance()
            return .array(elements)
        }
        while true {
            guard peek() != nil else {
                throw TOMLError(line: startLine, reason: "unterminated array")
            }
            elements.append(try parseValue())
            skipArrayWhitespace()
            guard let c = peek() else {
                throw TOMLError(line: startLine, reason: "unterminated array")
            }
            if c == "," {
                advance()
                skipArrayWhitespace()
                if peek() == "]" {
                    advance()
                    return .array(elements)
                }
                continue
            }
            if c == "]" {
                advance()
                return .array(elements)
            }
            throw TOMLError(line: line, reason: "expected ',' or ']' in array")
        }
    }

    private mutating func skipArrayWhitespace() {
        while let c = peek() {
            if c == " " || c == "\t" || c == "\n" || c == "\r" {
                advance()
            } else if c == "#" {
                skipToEndOfLine()
            } else {
                break
            }
        }
    }

    private mutating func parseInlineTable() throws -> TOMLValue {
        let startLine = line
        advance() // consume '{'
        var table = TOMLTable()
        skipInlineWhitespace()
        if peek() == "}" {
            advance()
            return .table(table)
        }
        while true {
            skipInlineWhitespace()
            let keyPath = try parseDottedKey()
            skipInlineWhitespace()
            guard peek() == "=" else {
                throw TOMLError(line: line, reason: "expected '=' in inline table")
            }
            advance()
            skipInlineWhitespace()
            let value = try parseValue()
            try Self.insertLeaf(&table, path: keyPath, value: value, line: startLine)
            skipInlineWhitespace()
            guard let c = peek() else {
                throw TOMLError(line: startLine, reason: "unterminated inline table")
            }
            if c == "," {
                advance()
                continue
            }
            if c == "}" {
                advance()
                return .table(table)
            }
            throw TOMLError(line: line, reason: "expected ',' or '}' in inline table")
        }
    }
}
