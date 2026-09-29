//
//  DatabaseFilePathResolver.swift
//  osaurus
//
//  Path resolution for Agent DB file tools (`db_import`, `db_export`,
//  `db_execute` path mode).
//
//  Intel: upstream resolves against two roots, the Linux sandbox agent dir
//  and the host working folder. Intel has no sandbox, so the only root is
//  the executing chat's working folder (`ChatExecutionContext.currentFolderRoot`).
//  Containment is checked on symlink-resolved paths, so a link inside the
//  folder can't point a read or write outside it.
//

import Foundation

enum DatabaseFilePathResolver {
    enum Scope: String, Sendable {
        case hostFolder
    }

    struct Resolved: Sendable {
        let url: URL
        let scope: Scope
    }

    enum Outcome: Sendable {
        case resolved(Resolved)
        case failed(envelope: String)
    }

    static let noFolderMessageSuffix =
        PromptWorkingFolderTool.attachFolderSteer
        + " Then retry. Fallback for tabular data already in context: one `db_insert` "
        + "with a `rows` array instead of row-by-row inserts."

    /// Resolve a path for reading an existing file (import / SQL script).
    static func resolveForRead(path: String, tool: String) async -> Outcome {
        guard let root = hostWorkingFolderRoot() else {
            return .failed(envelope: noFolderEnvelope(tool: tool, verb: "reads files from"))
        }
        guard let url = containedURL(path, root: root) else {
            return .failed(envelope: outsideEnvelope(path: path, root: root, tool: tool))
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
            !isDirectory.boolValue
        else {
            return .failed(
                envelope: ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "No file at `\(path)` in the working folder `\(root.path)`.",
                    field: "path",
                    tool: tool,
                    retryable: false
                )
            )
        }
        return .resolved(Resolved(url: url, scope: .hostFolder))
    }

    /// Resolve a destination path for writing (export). Creates parent
    /// directories when `createParents` is true.
    static func resolveForWrite(
        path: String,
        tool: String,
        overwrite: Bool,
        createParents: Bool = true
    ) async -> Outcome {
        guard let root = hostWorkingFolderRoot() else {
            return .failed(envelope: noFolderEnvelope(tool: tool, verb: "writes files to"))
        }
        guard let url = containedURL(path, root: root) else {
            return .failed(envelope: outsideEnvelope(path: path, root: root, tool: tool))
        }

        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            if isDirectory.boolValue {
                return .failed(
                    envelope: ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message: "`\(path)` is a folder; give a file name such as `export.csv`.",
                        field: "path",
                        tool: tool,
                        retryable: false
                    )
                )
            }
            if !overwrite {
                return .failed(
                    envelope: ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message:
                            "File already exists at `\(path)`. Pass `overwrite: true` "
                            + "to replace it, or choose a different path.",
                        field: "overwrite",
                        tool: tool,
                        retryable: false
                    )
                )
            }
        }

        if createParents {
            let parent = url.deletingLastPathComponent()
            do {
                try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                return .failed(
                    envelope: ToolEnvelope.failure(
                        kind: .executionError,
                        message: "Could not create directory `\(parent.path)`: \(error.localizedDescription)",
                        tool: tool
                    )
                )
            }
        }

        return .resolved(Resolved(url: url, scope: .hostFolder))
    }

    /// Read file bytes with the shared 64 MiB cap used by import paths.
    enum ReadTextOutcome: Sendable {
        case text(String)
        case failed(envelope: String)
    }

    static func readTextFile(at url: URL, tool: String) -> ReadTextOutcome {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            return .failed(
                envelope: ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "No file at `\(url.path)`.",
                    field: "path",
                    tool: tool,
                    retryable: false
                )
            )
        }
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        if size > DatabaseImport.maxBytes {
            return .failed(
                envelope: ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "File is \(size) bytes; limit is \(DatabaseImport.maxBytes). "
                        + "Split the file or run smaller chunks.",
                    field: "path",
                    tool: tool,
                    retryable: false
                )
            )
        }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else {
                return .failed(
                    envelope: ToolEnvelope.failure(
                        kind: .invalidArgs,
                        message: "File is not valid UTF-8 text.",
                        field: "path",
                        tool: tool,
                        retryable: false
                    )
                )
            }
            return .text(text)
        } catch {
            return .failed(
                envelope: ToolEnvelope.failure(
                    kind: .executionError,
                    message: "Could not read `\(url.path)`: \(error.localizedDescription)",
                    tool: tool
                )
            )
        }
    }

    /// Resolve `path` and read a UTF-8 text script (SQL, CSV, etc.).
    static func loadTextScript(path: String, tool: String) async -> ReadTextOutcome {
        switch await resolveForRead(path: path, tool: tool) {
        case .failed(let envelope):
            return .failed(envelope: envelope)
        case .resolved(let resolved):
            return readTextFile(at: resolved.url, tool: tool)
        }
    }

    // MARK: - Root and containment

    /// The EXECUTING chat's folder root from the TaskLocal execution scope —
    /// folder ownership is per chat session, so a concurrent chat's folder
    /// can never hijack this resolver.
    private static func hostWorkingFolderRoot() -> URL? {
        ChatExecutionContext.currentFolderRoot
    }

    /// Resolve `rawPath` (relative, or absolute under the root) against `root`
    /// and return it only if the symlink-resolved result stays inside the
    /// symlink-resolved root. For paths that don't exist yet, the deepest
    /// existing ancestor is resolved, so a linked parent folder can't escape.
    static func containedURL(_ rawPath: String, root: URL) -> URL? {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let rootURL = canonicalized(root)
        let candidate =
            trimmed.hasPrefix("/")
            ? URL(fileURLWithPath: trimmed)
            : root.appendingPathComponent(trimmed)
        let resolved = canonicalizedExistingPrefix(candidate.standardizedFileURL)
        guard isContained(resolved, in: rootURL), resolved.path != rootURL.path else { return nil }
        return resolved
    }

    private static func canonicalized(_ url: URL) -> URL {
        url.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Resolve symlinks in the longest existing prefix of `url`, then re-append
    /// the components that don't exist yet.
    private static func canonicalizedExistingPrefix(_ url: URL) -> URL {
        var existing = url
        var pending: [String] = []
        let fm = FileManager.default
        while !fm.fileExists(atPath: existing.path), existing.path != "/" {
            pending.insert(existing.lastPathComponent, at: 0)
            existing = existing.deletingLastPathComponent()
        }
        var result = canonicalized(existing)
        for component in pending {
            result.appendPathComponent(component)
        }
        return result.standardizedFileURL
    }

    private static func isContained(_ candidate: URL, in root: URL) -> Bool {
        candidate.path == root.path || candidate.path.hasPrefix(root.path + "/")
    }

    private static func noFolderEnvelope(tool: String, verb: String) -> String {
        ToolEnvelope.failure(
            kind: .unavailable,
            message: "`\(tool)` \(verb) the chat's working folder, but none is selected. "
                + noFolderMessageSuffix,
            tool: tool,
            retryable: false
        )
    }

    private static func outsideEnvelope(path: String, root: URL, tool: String) -> String {
        ToolEnvelope.failure(
            kind: .invalidArgs,
            message:
                "Path `\(path)` is outside the working folder `\(root.path)`. "
                + "Use a path inside it, e.g. `data/books.csv`.",
            field: "path",
            tool: tool,
            retryable: false
        )
    }
}
