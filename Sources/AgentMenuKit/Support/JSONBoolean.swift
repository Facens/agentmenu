// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// `JSONSerialization` decodes both JSON numbers and JSON booleans as
/// `NSNumber`, so an `as? NSNumber` cast (or `as? Double`) alone can't tell
/// them apart — a boolean's `NSNumber` silently succeeds as 1.0/0.0. This
/// checks the underlying `CFNumber`/`CFBoolean` type id instead, which does
/// distinguish them. Shared by `StatuslineBridge` (writing a snapshot) and
/// `UsageReader` (reading one back), so both sides of that file guard the
/// same way.
func isJSONBoolean(_ number: NSNumber) -> Bool {
    CFGetTypeID(number) == CFBooleanGetTypeID()
}
