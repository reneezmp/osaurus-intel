//
//  FileCopyTool.swift
//  osaurus
//
//  `file_copy` for Intel (docs/INTEL_MISSING_FEATURES_BACKLOG.md). Same
//  contract as upstream's tool — a raw byte copy of one file inside the
//  working folder, `overwrite` to replace, 512 MB cap, staged atomic swap —
//  written for Intel's host-folder tools: upstream's version routes through
//  the VM sandbox bridge and the file-change journal, which Intel does not
//  have. Undo goes through `FileOperationLog` like `file_write`: a new
//  destination is logged as a create (undo deletes it), an overwrite as a
//  binary-safe write (undo restores the previous bytes).
//
//  Before this, Intel removed the tool "by design" in favour of
//  `shell_run cp`, which bypasses undo.
//

import Foundation

struct FileCopyTool: OsaurusTool, PermissionedTool {
    let name = "file_copy"
    let description =
        "Copy one file to a new path as a raw byte copy — binary-safe (PDFs, images, archives, "
        + "generated .docx/.xlsx), nothing passes through the conversation. Use it to duplicate or "
        + "version a file before editing it. Paths are relative to the working folder. Pass "
        + "`overwrite: true` to replace an existing destination (the previous bytes stay undoable). "
        + "Example: {\"source\": \"reports/q3.docx\", \"destination\": \"reports/q3-draft.docx\"}"
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "source": .object([
                "type": .string("string"),
                "description": .string("File to copy, relative to the working folder"),
            ]),
            "destination": .object([
                "type": .string("string"),
                "description": .string(
                    "Where to copy it (including the filename), relative to the working folder"
                ),
            ]),
            "overwrite": .object([
                "type": .string("boolean"),
                "description": .string("Replace the destination if it already exists (default: false)"),
            ]),
        ]),
        "required": .array([.string("source"), .string("destination")]),
    ])

    var requirements: [String] { [] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .auto }

    /// Upstream's cap: far above any document, but stops a runaway copy of a
    /// disk image or model file from filling the disk.
    static let defaultMaxCopyBytes = 512 * 1024 * 1024

    private let fixedRootPath: URL?
    private let maxCopyBytes: Int

    init(rootPath: URL? = nil, maxCopyBytes: Int = FileCopyTool.defaultMaxCopyBytes) {
        self.fixedRootPath = rootPath
        self.maxCopyBytes = maxCopyBytes
    }

    func execute(argumentsJSON: String) async throws -> String {
        let rootPath = try FolderToolHelpers.requireRoot(fixed: fixedRootPath)
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let sourceReq = requireString(args, "source", expected: "file path relative to the working folder", tool: name)
        guard case .value(let source) = sourceReq else { return sourceReq.failureEnvelope ?? "" }
        let destinationReq = requireString(
            args, "destination", expected: "destination file path including the filename", tool: name)
        guard case .value(let destination) = destinationReq else { return destinationReq.failureEnvelope ?? "" }
        let overwrite = coerceBool(args["overwrite"]) ?? false

        let sourceURL = try FolderToolHelpers.resolvePath(source, rootPath: rootPath)
        let destinationURL = try FolderToolHelpers.resolvePath(destination, rootPath: rootPath)
        let fm = FileManager.default

        var sourceIsDirectory: ObjCBool = false
        guard fm.fileExists(atPath: sourceURL.path, isDirectory: &sourceIsDirectory) else {
            throw FolderToolError.fileNotFound(source)
        }
        guard !sourceIsDirectory.boolValue else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`source` '\(source)' is a directory; file_copy copies one file. Use shell_run `cp -R` for folders.",
                field: "source", expected: "a file path", tool: name, retryable: false)
        }
        let sourceBytes = (try? fm.attributesOfItem(atPath: sourceURL.path)[.size] as? Int64) ?? 0
        if sourceBytes > Int64(maxCopyBytes) {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "'\(source)' is larger than the \(maxCopyBytes / (1024 * 1024)) MB copy limit.",
                field: "source", expected: "a smaller file", tool: name, retryable: false)
        }
        if destinationURL.standardizedFileURL.path == sourceURL.standardizedFileURL.path {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`source` and `destination` resolve to the same file.",
                field: "destination", expected: "a path different from `source`", tool: name, retryable: false)
        }
        var destinationIsDirectory: ObjCBool = false
        let destinationExists = fm.fileExists(atPath: destinationURL.path, isDirectory: &destinationIsDirectory)
        if destinationExists, destinationIsDirectory.boolValue {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`destination` '\(destination)' is an existing directory — include the target filename in the path.",
                field: "destination", expected: "a file path including the filename", tool: name, retryable: false)
        }
        if destinationExists, !overwrite {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Destination '\(destination)' already exists. Pass `overwrite: true` to replace it, or choose a different destination.",
                field: "overwrite", expected: "`true` to replace the existing file", tool: name, retryable: false)
        }

        // Undo record before touching the destination (same shape as file_write).
        let previous = FileOperation.encodePreviousContent(
            destinationExists ? try? Data(contentsOf: destinationURL) : nil)
        if let sessionId = ChatExecutionContext.currentSessionId {
            await FileOperationLog.shared.log(
                FileOperation(
                    type: destinationExists ? .write : .create,
                    path: FolderToolHelpers.displayPath(for: destinationURL, under: rootPath),
                    previousContent: previous.content,
                    previousContentEncoding: previous.encoding,
                    sessionId: sessionId,
                    batchId: ChatExecutionContext.currentBatchId
                )
            )
        }

        do {
            try fm.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if destinationExists {
                // Staged copy + atomic swap: a failed copy (disk full, source
                // vanished) can't leave the destination deleted.
                let staging = destinationURL.deletingLastPathComponent()
                    .appendingPathComponent(".\(destinationURL.lastPathComponent).osaurus-copy-\(UUID().uuidString.prefix(8))")
                do {
                    try fm.copyItem(at: sourceURL, to: staging)
                    _ = try fm.replaceItemAt(destinationURL, withItemAt: staging)
                } catch {
                    try? fm.removeItem(at: staging)
                    throw error
                }
            } else {
                try fm.copyItem(at: sourceURL, to: destinationURL)
            }
        } catch {
            throw FolderToolError.operationFailed("Copy failed: \(error.localizedDescription)")
        }

        return ToolEnvelope.success(
            tool: name,
            result: [
                "kind": "file_copy_result",
                "source": source,
                "destination": destination,
                "bytes": sourceBytes,
                "overwrote": destinationExists,
            ]
        )
    }
}
