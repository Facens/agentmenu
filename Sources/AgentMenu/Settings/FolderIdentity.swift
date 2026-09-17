// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation
import AgentMenuKit

/// `FolderTarget` already carries its own id, and that is what the table keys
/// rows by: two entries may name one folder — the same project on two accounts
/// — and rows keyed by path would collapse into one another.
extension FolderTarget: Identifiable {}

/// A profile's identity is its id, which the store already guarantees unique.
extension Profile: Identifiable {}
