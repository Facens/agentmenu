// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Darwin
import Foundation

/// Which boot of the Mac this is (KTD12): what the session store remembers
/// from the last run so a relaunch can tell "the Mac restarted" from "AgentMenu
/// was only quit".
///
/// `kern.bootsessionuuid` is the identifier: one UUID per boot, untouched by a
/// clock that steps. Where the kernel does not offer it, `kern.boottime` is
/// the fallback. That one is derived from the wall clock and can move when the
/// clock is set, so two readings of it are the same boot unless they differ by
/// more than `boottimeTolerance`.
public enum BootID {
    /// A clock step smaller than this is not a restart: no Mac boots, runs
    /// long enough for AgentMenu to record it, and boots again within it.
    public static let boottimeTolerance = 60

    private static let uuidPrefix = "uuid:"
    private static let boottimePrefix = "boottime:"

    /// This boot's identifier, or nil when the kernel gives neither value.
    public static func current() -> String? {
        if let uuid = stringValue(named: "kern.bootsessionuuid"), !uuid.isEmpty {
            return uuidPrefix + uuid
        }
        if let seconds = bootTimeSeconds() { return boottimePrefix + String(seconds) }
        return nil
    }

    /// Whether `current` is a different boot from `stored`. Unknown when
    /// either is missing, or when they are of different kinds (a build that
    /// stored one kind and a Mac that now answers with the other): never a
    /// reason to say the Mac restarted.
    public static func hasChanged(from stored: String?, to current: String?) -> Bool {
        guard let stored, let current else { return false }
        if stored.hasPrefix(uuidPrefix), current.hasPrefix(uuidPrefix) { return stored != current }
        if stored.hasPrefix(boottimePrefix), current.hasPrefix(boottimePrefix),
           let before = Int(stored.dropFirst(boottimePrefix.count)),
           let now = Int(current.dropFirst(boottimePrefix.count)) {
            return abs(now - before) > boottimeTolerance
        }
        return false
    }

    private static func stringValue(named name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }

    private static func bootTimeSeconds() -> Int? {
        var value = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0 else { return nil }
        return Int(value.tv_sec)
    }
}
