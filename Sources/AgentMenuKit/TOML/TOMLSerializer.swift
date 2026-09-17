// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension TOMLDocument {
    /// Re-renders the document as TOML text.
    ///
    /// Ordering follows the shape of the data, not the original text: root
    /// scalar/array keys first, then every `[table]` section, then every
    /// `[[array of tables]]` section — each group in the table's own key
    /// order — and the same grouping recurses into every nested table. A
    /// non-empty array whose elements are all tables is always rendered as
    /// `[[path]]` sections rather than an inline array literal; that changes
    /// the array's own syntax but not the value it parses back to, which is
    /// what round-tripping actually requires. Comments are not preserved.
    public func serialized() -> String {
        TOMLSerializer.serialize(root)
    }
}

enum TOMLSerializer {
    static func serialize(_ root: TOMLTable) -> String {
        var rootLines: [String] = []
        var subtableKeys: [String] = []
        var arrayTableKeys: [String] = []
        classify(root, lines: &rootLines, subtableKeys: &subtableKeys, arrayTableKeys: &arrayTableKeys)

        var blocks: [String] = []
        if !rootLines.isEmpty {
            blocks.append(rootLines.joined(separator: "\n") + "\n")
        }
        for key in subtableKeys {
            if case .table(let nested)? = root[key] {
                emitSection(nested, path: [key], isArrayElement: false, blocks: &blocks)
            }
        }
        for key in arrayTableKeys {
            if case .array(let elements)? = root[key] {
                for element in elements {
                    if case .table(let elementTable) = element {
                        emitSection(elementTable, path: [key], isArrayElement: true, blocks: &blocks)
                    }
                }
            }
        }
        return blocks.joined(separator: "\n")
    }

    private static func emitSection(_ table: TOMLTable, path: [String], isArrayElement: Bool, blocks: inout [String]) {
        var lines: [String] = []
        var subtableKeys: [String] = []
        var arrayTableKeys: [String] = []
        classify(table, lines: &lines, subtableKeys: &subtableKeys, arrayTableKeys: &arrayTableKeys)

        let header = isArrayElement ? "[[\(headerPath(path))]]" : "[\(headerPath(path))]"
        var block = header + "\n"
        if !lines.isEmpty {
            block += lines.joined(separator: "\n") + "\n"
        }
        blocks.append(block)

        for key in subtableKeys {
            if case .table(let nested)? = table[key] {
                emitSection(nested, path: path + [key], isArrayElement: false, blocks: &blocks)
            }
        }
        for key in arrayTableKeys {
            if case .array(let elements)? = table[key] {
                for element in elements {
                    if case .table(let elementTable) = element {
                        emitSection(elementTable, path: path + [key], isArrayElement: true, blocks: &blocks)
                    }
                }
            }
        }
    }

    /// Splits a table's keys, in their own order, into plain `key = value`
    /// lines, subtable keys, and array-of-tables keys.
    private static func classify(
        _ table: TOMLTable,
        lines: inout [String],
        subtableKeys: inout [String],
        arrayTableKeys: inout [String]
    ) {
        for key in table.keys {
            guard let value = table[key] else { continue }
            switch value {
            case .table:
                subtableKeys.append(key)
            case .array(let elements) where isArrayOfTables(elements):
                arrayTableKeys.append(key)
            default:
                lines.append("\(quoteKeyIfNeeded(key)) = \(serializeInlineValue(value))")
            }
        }
    }

    private static func isArrayOfTables(_ elements: [TOMLValue]) -> Bool {
        !elements.isEmpty && elements.allSatisfy {
            if case .table = $0 { return true }
            return false
        }
    }

    private static func headerPath(_ path: [String]) -> String {
        path.map(quoteKeyIfNeeded).joined(separator: ".")
    }

    static func serializeInlineValue(_ value: TOMLValue) -> String {
        switch value {
        case .string(let s):
            return quoteString(s)
        case .integer(let i):
            return String(i)
        case .double(let d):
            return String(d)
        case .boolean(let b):
            return b ? "true" : "false"
        case .array(let elements):
            let inner = elements.map(serializeInlineValue).joined(separator: ", ")
            return "[\(inner)]"
        case .table(let t):
            if t.isEmpty { return "{}" }
            let inner = t.keys.compactMap { key -> String? in
                guard let v = t[key] else { return nil }
                return "\(quoteKeyIfNeeded(key)) = \(serializeInlineValue(v))"
            }.joined(separator: ", ")
            return "{ \(inner) }"
        }
    }

    static func quoteKeyIfNeeded(_ key: String) -> String {
        if !key.isEmpty && key.allSatisfy(isBareTOMLKeyChar) {
            return key
        }
        return quoteString(key)
    }

    /// Basic `"..."` for most strings; literal `'...'` when that reads better
    /// — a value with a backslash or a double quote (and no single quote, and
    /// nothing that would need escaping anyway) is exactly the case where a
    /// literal string avoids a wall of escapes, e.g. `{"advisorModel":""}`.
    static func quoteString(_ s: String) -> String {
        let hasBackslashOrQuote = s.contains("\\") || s.contains("\"")
        let hasSingleQuote = s.contains("'")
        let hasControlOrNewline = s.unicodeScalars.contains { $0.value < 0x20 && $0 != "\t" }
        if hasBackslashOrQuote && !hasSingleQuote && !hasControlOrNewline {
            return "'\(s)'"
        }
        return basicQuote(s)
    }

    private static func basicQuote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default:
                if scalar.value < 0x20 || scalar.value == 0x7F {
                    out += String(format: "\\u%04X", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
        return out
    }
}
