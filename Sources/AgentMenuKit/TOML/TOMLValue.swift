// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// A TOML value: one of the six kinds this subset parser understands.
public enum TOMLValue: Equatable {
    case string(String)
    case integer(Int)
    case double(Double)
    case boolean(Bool)
    case array([TOMLValue])
    case table(TOMLTable)

    public var stringValue: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    public var intValue: Int? {
        if case .integer(let value) = self { return value }
        return nil
    }

    public var doubleValue: Double? {
        if case .double(let value) = self { return value }
        return nil
    }

    public var boolValue: Bool? {
        if case .boolean(let value) = self { return value }
        return nil
    }

    public var arrayValue: [TOMLValue]? {
        if case .array(let value) = self { return value }
        return nil
    }

    public var tableValue: TOMLTable? {
        if case .table(let value) = self { return value }
        return nil
    }

    /// nil unless every element of the array is a string.
    public var stringArrayValue: [String]? {
        guard let elements = arrayValue else { return nil }
        var strings: [String] = []
        strings.reserveCapacity(elements.count)
        for element in elements {
            guard let string = element.stringValue else { return nil }
            strings.append(string)
        }
        return strings
    }
}

/// An order-preserving keyed collection of TOML values.
///
/// Insertion order is significant: AgentMenu rewrites the user's config file
/// in place, and a key it does not recognise must come back out in the same
/// position relative to its siblings — not dropped, not reshuffled.
public struct TOMLTable: Equatable {
    private var storage: [String: TOMLValue] = [:]
    public private(set) var keys: [String] = []

    public init() {}

    public var isEmpty: Bool { keys.isEmpty }

    /// Getting is a plain lookup. Setting appends a new key at the end of
    /// `keys`, or replaces the value in place (keeping position) when the key
    /// already exists. Setting nil removes the key.
    public subscript(key: String) -> TOMLValue? {
        get { storage[key] }
        set {
            if let newValue {
                if storage.updateValue(newValue, forKey: key) == nil {
                    keys.append(key)
                }
            } else if storage.removeValue(forKey: key) != nil {
                keys.removeAll { $0 == key }
            }
        }
    }

    @discardableResult
    public mutating func removeValue(forKey key: String) -> TOMLValue? {
        let old = storage[key]
        self[key] = nil
        return old
    }

    /// Walks a dotted path through nested tables. Returns nil if any
    /// intermediate segment is missing or not a table; the final segment may
    /// be any value.
    public func value(at path: [String]) -> TOMLValue? {
        guard let head = path.first else { return nil }
        guard let value = self[head] else { return nil }
        if path.count == 1 { return value }
        guard let nested = value.tableValue else { return nil }
        return nested.value(at: Array(path.dropFirst()))
    }

    /// Walks a dotted path, creating intermediate tables as needed, and sets
    /// the value at the end of it. Setting an already-present leaf key keeps
    /// its position among its siblings.
    public mutating func set(_ value: TOMLValue, at path: [String]) {
        guard let head = path.first else { return }
        if path.count == 1 {
            self[head] = value
            return
        }
        var nested = self[head]?.tableValue ?? TOMLTable()
        nested.set(value, at: Array(path.dropFirst()))
        self[head] = .table(nested)
    }
}

/// True for the ASCII characters TOML allows in a bare (unquoted) key:
/// `[A-Za-z0-9_-]`. Shared by the parser (to scan keys) and the serializer
/// (to decide whether a key needs quoting).
func isBareTOMLKeyChar(_ c: Character) -> Bool {
    guard c.isASCII, let ascii = c.asciiValue else { return false }
    return (ascii >= 48 && ascii <= 57)   // 0-9
        || (ascii >= 65 && ascii <= 90)   // A-Z
        || (ascii >= 97 && ascii <= 122)  // a-z
        || ascii == 95                    // _
        || ascii == 45                    // -
}
