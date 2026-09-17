// Copyright (c) 2026 Andrea Giannangelo
// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

/// Atomic file writes shared by `ConfigStore` and `StatuslineBridge`: the new
/// content lands in a temporary file in the same directory, then
/// `FileManager.replaceItemAt` swaps it into place. A reader can only ever
/// see the fully-old or fully-new file, never a partial one. Creates the
/// parent directory when it is missing. Works the same whether or not the
/// destination already exists.
///
/// Deliberate behaviour: `replaceItemAt` preserves the destination file's
/// existing POSIX permissions across the swap (verified empirically — a
/// `chmod`'ed destination keeps its mode, regardless of the temp file's own
/// permissions), unlike a raw `rename(2)`, which would replace them with the
/// temp file's. Preserving them is the better behaviour for a file the plan
/// promises stays hand-editable — a user who has chmod'ed their own config
/// keeps that chmod.
///
/// A destination that is a symlink is followed: the file it points at is
/// what gets written, and the link survives. Two profile directories
/// sharing one `settings.json` through a symlink is an ordinary setup —
/// `StatuslineBridge.bridgeScript` resolves its profile at run time
/// precisely because of it — and `replaceItemAt` on the link itself fails
/// with a "file doesn't exist" error naming a file that plainly does exist
/// (observed installing the status line into a profile whose settings.json
/// was a symlink to another profile's). Following it is also the only
/// behaviour that keeps the arrangement intact: swapping a new regular file
/// into the link's place would quietly split the two profiles apart.
enum AtomicFile {
    static func write(_ data: Data, to url: URL) throws {
        let url = resolvedDestination(url)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tempURL = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: tempURL, options: .atomic)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
        do {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tempURL) ?? url
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    /// The file a destination actually names: a symlink's target when it is
    /// one, the path itself otherwise. Only an existing link is followed — a
    /// path that does not exist yet is left exactly as the caller wrote it,
    /// so a first write still lands where it was asked to.
    private static func resolvedDestination(_ url: URL) -> URL {
        let path = url.path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeSymbolicLink,
              let target = try? FileManager.default.destinationOfSymbolicLink(atPath: path)
        else { return url }
        let resolved = target.hasPrefix("/")
            ? URL(fileURLWithPath: target)
            : url.deletingLastPathComponent().appendingPathComponent(target)
        return resolved.standardizedFileURL
    }
}
