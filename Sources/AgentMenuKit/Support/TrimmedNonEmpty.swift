// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

extension String {
    /// The text with leading and trailing whitespace and newlines removed, or
    /// nil when nothing is left.
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension Optional where Wrapped == String {
    /// `String.trimmedNonEmpty`, and nil for nil.
    var trimmedNonEmpty: String? {
        self?.trimmedNonEmpty
    }
}
