//
//  PathSafety.swift
//  OsaurusPluginKit
//
//  Canonical component-aware path containment and atomic file writes,
//  consolidated from the osaurus-images / osaurus-vision / osaurus-pptx /
//  osaurus-xlsx variants.
//

import Foundation

public enum PathSafetyError: Error, CustomStringConvertible {
    /// The replace destination is an existing directory. Refusing protects
    /// directory trees from being clobbered by a single-file write —
    /// `FileManager.replaceItemAt` would otherwise happily swap a whole
    /// directory out for a file.
    case destinationIsDirectory(String)

    public var description: String {
        switch self {
        case .destinationIsDirectory(let path):
            return "Destination is an existing directory: \(path)"
        }
    }
}

public enum PathSafety {

    // MARK: - Canonicalization & containment

    /// Canonicalizes a path: tilde expansion, standardization (`.`/`..`
    /// removal), and symlink resolution on the DEEPEST EXISTING ancestor,
    /// so containment checks hold for paths that do not exist yet.
    public static func canonicalize(_ path: String) -> String {
        var url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
        var missing: [String] = []
        let fm = FileManager.default
        while (try? fm.attributesOfItem(atPath: url.path)) == nil, url.pathComponents.count > 1 {
            missing.append(url.lastPathComponent)
            url = url.deletingLastPathComponent()
        }
        var resolved = url.resolvingSymlinksInPath()
        for component in missing.reversed() {
            resolved.appendPathComponent(component)
        }
        return resolved.standardizedFileURL.path
    }

    /// Component-aware containment: true when `path` canonicalizes to
    /// `root` itself or to a descendant of it. Prefix-sibling paths
    /// (`/tmp/foo` vs `/tmp/foobar`) and symlink escapes are rejected.
    public static func isContained(_ path: String, in root: String) -> Bool {
        let p = canonicalize(path)
        let r = canonicalize(root)
        return p == r || p.hasPrefix(r.hasSuffix("/") ? r : r + "/")
    }

    // MARK: - Atomic writes

    /// Writes `data` to `path` atomically: stages a temp file in the
    /// destination's directory (same filesystem, so the final step is a
    /// rename) and swaps it in. On failure the prior file — if any — is
    /// left untouched and the temp file is removed.
    public static func atomicWrite(data: Data, to path: String) throws {
        let destination = URL(fileURLWithPath: path)
        let directory = destination.deletingLastPathComponent()
        let temp = directory.appendingPathComponent(
            ".\(destination.lastPathComponent).tmp-\(UUID().uuidString)")
        try data.write(to: temp)
        do {
            try atomicReplace(at: destination.path, withItemAt: temp.path)
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }
    }

    /// Moves the item at `source` over `destination` atomically. When the
    /// destination exists it is replaced via `FileManager.replaceItemAt`
    /// (rename-based); otherwise the source is simply moved into place.
    /// The source item is consumed on success. A destination that is an
    /// existing DIRECTORY is refused (`PathSafetyError`) so a file write
    /// can never clobber a directory tree.
    public static func atomicReplace(at destination: String, withItemAt source: String) throws {
        let fm = FileManager.default
        let destinationURL = URL(fileURLWithPath: destination)
        let sourceURL = URL(fileURLWithPath: source)
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: destination, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                throw PathSafetyError.destinationIsDirectory(destination)
            }
            _ = try fm.replaceItemAt(destinationURL, withItemAt: sourceURL)
        } else {
            try fm.moveItem(at: sourceURL, to: destinationURL)
        }
    }
}
