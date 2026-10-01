//
//  FolderTools.swift
//  osaurus
//
//  Folder-context tools for file operations, code editing, and git
//  integration. Registered by FolderToolManager whenever a working folder
//  is selected; agents use them to operate directly on the host folder.
//

import Darwin
import Foundation

// MARK: - Tool Errors

enum FolderToolError: LocalizedError {
    case invalidArguments(String)
    case pathOutsideRoot(String)
    case fileNotFound(String)
    case directoryNotFound(String)
    case operationFailed(String)
    /// File at `path` is binary (or otherwise not decodable as text).
    /// `ext` is the lowercased file extension when available; `detail`
    /// is a structured reason the envelope mapper folds into the model-
    /// facing message so the agent sees a single non-retryable signal
    /// instead of opaque `NSCocoaError` text.
    case binaryContent(path: String, ext: String?, detail: BinaryDetail)

    /// Sub-classification on `binaryContent`. Each case carries a tailored
    /// pivot hint (`pivotHint`) so the model gets a concrete next step
    /// instead of a generic "this is binary" message.
    enum BinaryDetail: Sendable {
        /// First-chunk NUL-byte sniff matched.
        case nulByte
        /// Bytes weren't valid UTF-8.
        case decodeFailed
        /// `DocumentParser` returned an image-only PDF (no text layer).
        case imageOnlyPdf
        /// `DocumentParser` threw `.readFailed` / `.unsupportedFormat` /
        /// `.fileTooLarge`.
        case parseFailed
        /// An image with no legible text (OCR found nothing).
        case imageWithoutText

        var pivotHint: String? {
            switch self {
            case .imageOnlyPdf:
                return
                    "The PDF has no text layer and on-device text recognition found no legible text in it."
            case .imageWithoutText:
                return
                    "The image has no legible text. This chat's models can't see images, so describe what you need from it or ask the user."
            case .parseFailed:
                return
                    "The document couldn't be parsed — it may be encrypted, password-protected, or malformed."
            case .nulByte, .decodeFailed:
                return nil
            }
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidArguments(let msg): return "Invalid arguments: \(msg)"
        case .pathOutsideRoot(let path): return "Path is outside working directory: \(path)"
        case .fileNotFound(let path): return "File not found: \(path)"
        case .directoryNotFound(let path): return "Directory not found: \(path)"
        case .operationFailed(let msg): return "Operation failed: \(msg)"
        case .binaryContent(let path, let ext, _):
            if let ext, !ext.isEmpty {
                return "Binary content at \(path) (.\(ext))"
            }
            return "Binary content at \(path)"
        }
    }
}

// MARK: - Tool Helpers

/// Shared utilities for folder tools
enum FolderToolHelpers {
    /// Lines of file content, not separator-delimited fields (upstream
    /// #2894). A final line terminator does not introduce another empty
    /// line, and CRLF is one newline (`components(separatedBy: .newlines)`
    /// counted it as two, shifting every later line number). An empty file
    /// stays one empty line.
    static func contentLines(_ text: String) -> [String] {
        var lines = text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            .map(String.init)
        if text.last?.isNewline == true, lines.count > 1 {
            lines.removeLast()
        }
        return lines
    }

    /// Runtime tools carry no global folder. Directly constructed test tools
    /// may provide a fixed root; otherwise the executing chat's TaskLocal root
    /// is authoritative.
    static func resolveRoot(fixed: URL?) -> URL? {
        fixed ?? ChatExecutionContext.currentFolderRoot
    }

    /// `payload` plus the file history `operation_id` of the executing call
    /// (bound by the registry's journal capture), so `file_undo` can target
    /// exactly this call (upstream reports it on every mutating result).
    static func withOperationId(_ payload: [String: Any]) -> [String: Any] {
        guard let setId = ChatExecutionContext.currentChangeSetId else { return payload }
        var payload = payload
        payload["operation_id"] = setId.uuidString
        return payload
    }

    static func requireRoot(fixed: URL?) throws -> URL {
        guard let root = resolveRoot(fixed: fixed) else {
            throw FolderToolError.operationFailed(
                "No working folder is selected for this chat."
            )
        }
        return root
    }

    /// Resolve a tool's `path` argument under the working folder.
    /// Accepts a relative path under root (e.g. `src/app.py`) or an
    /// absolute path that lives inside root (e.g. `/Users/x/proj/src/app.py`
    /// when root is `/Users/x/proj`). After `..`/`.` standardisation the
    /// resolved path must equal root or be a strict child (`root + "/"`)
    /// so traversal and sibling directories like `<root>-other` cannot slip
    /// through a substring match.
    ///
    /// Intel: containment is then re-checked on symlink-resolved paths, so a
    /// link inside the folder (`link -> /etc`, `notes.txt -> ~/.ssh/id_rsa`)
    /// can't carry a read or write outside it. An absolute path may also use
    /// another spelling of the root, such as `/private/var/...` for a root
    /// under `/var/...`.
    static func resolvePath(_ relativePath: String, rootPath: URL) throws -> URL {
        let rootStandardized = rootPath.standardized.path
        let realRoot = symlinkResolvedPath(rootStandardized)
        func isPhysicallyWithinRoot(_ url: URL) -> Bool {
            guard let realRoot, let realPath = symlinkResolvedPath(url.path) else { return false }
            return isPath(realPath, within: realRoot)
        }

        let resolvedURL: URL
        if relativePath.hasPrefix("/") {
            resolvedURL = URL(fileURLWithPath: relativePath).standardized
            guard isPhysicallyWithinRoot(resolvedURL) else {
                if isPath(resolvedURL.path, within: rootStandardized) {
                    throw FolderToolError.pathOutsideRoot(relativePath)
                }
                throw FolderToolError.invalidArguments(
                    "path must be relative to the working directory or absolute under it "
                        + "(got '\(relativePath)'). Pass just the file or directory name — "
                        + "e.g. 'README.md' or 'src/app.py'."
                )
            }
            return resolvedURL
        }

        resolvedURL = rootPath.appendingPathComponent(relativePath).standardized
        guard isPath(resolvedURL.path, within: rootStandardized),
            isPhysicallyWithinRoot(resolvedURL)
        else {
            throw FolderToolError.pathOutsideRoot(relativePath)
        }
        return resolvedURL
    }

    /// `path` is `root` or lies beneath it (never a sibling such as
    /// `<root>-other`).
    static func isPath(_ path: String, within root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }

    /// Links followed before giving up, matching the kernel's `MAXSYMLINKS`.
    private static let maxSymlinkHops = 32

    /// Absolute `path` with every symbolic link expanded, one component at a
    /// time, the way the kernel follows it. Unlike `realpath(3)` it accepts a
    /// tail that doesn't exist yet, and unlike `URL.resolvingSymlinksInPath()`
    /// it never strips `/private` and it follows dangling links to their
    /// target text, so a link to a file that doesn't exist yet can't be used
    /// to create one elsewhere. `..` inside a link target is applied after the
    /// link is expanded. Returns nil for a link loop or an unreadable link.
    static func symlinkResolvedPath(_ path: String) -> String? {
        var resolved: [String] = []
        var pending = Array(path.split(separator: "/").map(String.init).reversed())
        var hops = 0
        let fm = FileManager.default
        while let component = pending.popLast() {
            if component == "." { continue }
            if component == ".." {
                _ = resolved.popLast()
                continue
            }
            let candidate = "/" + (resolved + [component]).joined(separator: "/")
            var info = stat()
            guard lstat(candidate, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK else {
                resolved.append(component)
                continue
            }
            hops += 1
            guard hops <= maxSymlinkHops,
                let target = try? fm.destinationOfSymbolicLink(atPath: candidate)
            else { return nil }
            if target.hasPrefix("/") { resolved.removeAll() }
            pending.append(contentsOf: target.split(separator: "/").map(String.init).reversed())
        }
        return "/" + resolved.joined(separator: "/")
    }

    /// Root-relative display path for a URL produced by walking the folder.
    /// FileManager enumerators hand back physical paths (`/private/var/...`)
    /// even when the root was given as `/var/...`, so fall back to comparing
    /// symlink-resolved paths before settling for the bare file name.
    static func displayPath(for url: URL, under rootPath: URL) -> String {
        let root = rootPath.standardized.path
        let path = url.standardized.path
        if let relative = relativePath(path, under: root) { return relative }
        if let realRoot = symlinkResolvedPath(root),
            let realPath = symlinkResolvedPath(path),
            let relative = relativePath(realPath, under: realRoot)
        {
            return relative
        }
        return url.lastPathComponent
    }

    private static func relativePath(_ path: String, under root: String) -> String? {
        guard isPath(path, within: root) else { return nil }
        if path == root { return "." }
        return String(path.dropFirst(root.hasSuffix("/") ? root.count : root.count + 1))
    }

    /// Parse JSON arguments to dictionary
    static func parseArguments(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8),
            let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            throw FolderToolError.invalidArguments("Failed to parse JSON")
        }
        return dict
    }

    /// Detect project type from root path
    static func detectProjectType(_ url: URL) -> ProjectType {
        let fm = FileManager.default
        for projectType in ProjectType.allCases where projectType != .unknown {
            for manifestFile in projectType.manifestFiles {
                if fm.fileExists(atPath: url.appendingPathComponent(manifestFile).path) {
                    return projectType
                }
            }
        }
        return .unknown
    }

    /// Check if pattern matches filename
    static func matchesPattern(_ name: String, pattern: String) -> Bool {
        if pattern.contains("*") {
            let regex = pattern.replacingOccurrences(of: ".", with: "\\.")
                .replacingOccurrences(of: "*", with: ".*")
            return name.range(of: "^\(regex)$", options: .regularExpression) != nil
        }
        return name == pattern
    }

    /// Check if name should be ignored based on patterns
    static func shouldIgnore(_ name: String, patterns: [String]) -> Bool {
        patterns.contains { matchesPattern(name, pattern: $0) }
    }

    /// Run a process and wait for completion asynchronously without blocking the main thread.
    /// The termination handler is set before running to avoid race conditions.
    static func runProcessAsync(_ process: Process) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { _ in
                continuation.resume()
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    /// Run a git command and return the output.
    /// A 30-second timeout prevents indefinite hangs (e.g. credential prompts, network issues).
    static func runGitCommand(
        arguments: [String],
        in directory: URL,
        timeout: Int = 30
    ) async throws -> (output: String, exitCode: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = directory

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        // Set up timeout to terminate hung git processes
        let timeoutTask = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout) * 1_000_000_000)
            if process.isRunning {
                process.terminate()
            }
        }

        defer {
            timeoutTask.cancel()
        }

        try await runProcessAsync(process)

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        return (output, process.terminationStatus)
    }
}

// MARK: - Core Tools

// MARK: File Tree Tool

struct FileTreeTool: OsaurusTool {
    let name = "file_tree"
    let description =
        "List the directory structure of the working directory or a subdirectory. **Use this instead "
        + "of `ls` / `tree` in `shell_run`.** Returns a tree view of files and folders. Skips hidden "
        + "files and truncates at 300 files."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional relative path to list (default: root). Use '.' for current directory."
                ),
            ]),
            "max_depth": .object([
                "type": .string("integer"),
                "description": .string("Maximum depth to traverse (default: 3)"),
            ]),
        ]),
        "required": .array([]),
    ])

    private let fixedRootPath: URL?

    init(rootPath: URL? = nil) {
        self.fixedRootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let rootPath = try FolderToolHelpers.requireRoot(fixed: fixedRootPath)
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        // `path` is optional (defaults to root). Coercion already drops
        // empty-string fillers, so a missing or absent value cleanly
        // falls back to ".".
        let relativePath = (args["path"] as? String) ?? "."
        let maxDepth = coerceInt(args["max_depth"]) ?? 3

        let targetURL = try FolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else {
            throw FolderToolError.directoryNotFound(relativePath)
        }

        return ToolEnvelope.success(
            tool: name,
            text: buildTree(targetURL, maxDepth: maxDepth, rootPath: rootPath))
    }

    private func buildTree(_ url: URL, maxDepth: Int, rootPath: URL) -> String {
        var result = "./\n"
        var fileCount = 0
        let maxFiles = 300
        let ignorePatterns = FolderToolHelpers.detectProjectType(rootPath).ignorePatterns

        func traverse(_ currentURL: URL, depth: Int, prefix: String) {
            guard depth <= maxDepth, fileCount < maxFiles else { return }

            let fm = FileManager.default
            guard
                let contents = try? fm.contentsOfDirectory(
                    at: currentURL,
                    includingPropertiesForKeys: [.isDirectoryKey],
                    options: [.skipsHiddenFiles]
                )
            else { return }

            let sorted = contents.sorted { a, b in
                let aIsDir = (try? a.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let bIsDir = (try? b.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                if aIsDir != bIsDir { return aIsDir }
                return a.lastPathComponent.lowercased() < b.lastPathComponent.lowercased()
            }

            for (index, item) in sorted.enumerated() {
                guard fileCount < maxFiles else {
                    result += "\(prefix)... (truncated)\n"
                    return
                }

                let name = item.lastPathComponent
                if FolderToolHelpers.shouldIgnore(name, patterns: ignorePatterns) { continue }

                let isLast = index == sorted.count - 1
                let connector = isLast ? "└── " : "├── "
                let childPrefix = isLast ? "    " : "│   "
                // Resource values describe a symlink itself (never a
                // directory), so a linked folder is listed by name and not
                // descended into, even when it points outside the root.
                let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false

                if isDir {
                    result += "\(prefix)\(connector)\(name)/\n"
                    if depth < maxDepth {
                        traverse(item, depth: depth + 1, prefix: prefix + childPrefix)
                    }
                } else {
                    result += "\(prefix)\(connector)\(name)\n"
                    fileCount += 1
                }
            }
        }

        traverse(url, depth: 1, prefix: "")
        return result
    }
}

// MARK: File Read Tool

struct FileReadTool: OsaurusTool {
    let name = "file_read"
    let description =
        "Read a file from the working folder: "
        + WorkspaceFileFormatPolicy.readableFormatsSummary
        + ". Documents come back as extracted text; images and scanned PDFs as text recognized "
        + "on this Mac (OCR). **Use this instead of `cat` / `head` / `tail` or pandoc/pdftotext in "
        + "`shell_run`.** Optionally specify start_line and end_line for partial reads. Line numbers "
        + "are 1-indexed. Pass `mode: \"structure\"` on a .docx/.xlsx/.pptx/.pdf to get the numbered "
        + "paragraphs, cells, slides/shapes, or pages (and form fields) that `file_edit` `operations` address."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Relative path to the file from the working directory"),
            ]),
            "start_line": .object([
                "type": .string("integer"),
                "description": .string("Optional start line number (1-indexed, inclusive)"),
            ]),
            "end_line": .object([
                "type": .string("integer"),
                "description": .string("Optional end line number (1-indexed, inclusive)"),
            ]),
            "mode": .object([
                "type": .string("string"),
                "enum": .array([.string("content"), .string("structure")]),
                "description": .string(
                    "Optional. `structure` returns a .docx/.xlsx/.pptx/.pdf outline with the ids `file_edit` operations use (default: content)"
                ),
            ]),
        ]),
        "required": .array([.string("path")]),
    ])

    private let fixedRootPath: URL?

    init(rootPath: URL? = nil) {
        self.fixedRootPath = rootPath
    }

    /// Maximum characters for file_read output to prevent context window exhaustion.
    /// Consistent with truncation limits on shell_run (10k) and git_diff (20k).
    private static let maxOutputChars = 15_000

    /// File extensions that `DocumentParser` (PDFKit + `NSAttributedString`)
    /// already extracts plain text from. For these we route through the
    /// parser instead of attempting a UTF-8 decode that would fail with
    /// `NSCocoaError 264` ("isn't in the correct format").
    private static let richDocumentExtensions: Set<String> = [
        "pdf", "docx", "doc", "rtf", "rtfd", "html", "htm",
    ]

    /// First-chunk byte budget for the NUL-byte binary sniff. Catches
    /// off-extension binaries whose UTF-8 decode happens to succeed by
    /// luck. Matches the size most editors / `file(1)` use for the same
    /// heuristic.
    private static let binarySniffBytes = 4096

    func execute(argumentsJSON: String) async throws -> String {
        let rootPath = try FolderToolHelpers.requireRoot(fixed: fixedRootPath)
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let pathReq = requireString(
            args,
            "path",
            expected: "relative path under the working folder (e.g. `src/app.py`)",
            tool: name
        )
        guard case .value(let relativePath) = pathReq else {
            return pathReq.failureEnvelope ?? ""
        }

        let fileURL = try FolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw FolderToolError.fileNotFound(relativePath)
        }

        let ext = fileURL.pathExtension.lowercased()
        // Upstream #2907: an outline of what `file_edit` operations address.
        if let mode = (args["mode"] as? String)?.lowercased(), mode == "structure" {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory)
            guard DocumentEditService.isEditable(ext), !isDirectory.boolValue else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "`mode: \"structure\"` outlines .docx, .xlsx, .pptx and .pdf files; read other files normally.",
                    field: "mode",
                    expected: "a .docx/.xlsx/.pptx/.pdf path, or omit `mode`",
                    tool: name
                )
            }
            do {
                var outline = try await DocumentEditService.structure(of: fileURL)
                outline["path"] = relativePath
                return ToolEnvelope.success(tool: name, result: outline)
            } catch {
                return ToolEnvelope.failure(
                    kind: .executionError,
                    message: "Couldn't outline \(relativePath): \(error.localizedDescription)",
                    field: "path",
                    tool: name
                )
            }
        }
        // Upstream #91: recognised document formats without a built-in
        // reader get an honest message naming the sibling format that works.
        if case .unsupportedDocument(let family) = WorkspaceFileFormatPolicy.readSupport(for: ext) {
            let alternative = family.supportedAlternative.map { " Save it as \($0) and read that instead." } ?? ""
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "`\(relativePath)` is a \(family.label) format file_read can't open. It reads "
                    + WorkspaceFileFormatPolicy.readableFormatsSummary + "." + alternative,
                field: "path",
                tool: name,
                retryable: false
            )
        }
        let content = try await loadFileContent(
            url: fileURL,
            relativePath: relativePath,
            ext: ext
        )
        let lines = FolderToolHelpers.contentLines(content)

        let startLine = coerceInt(args["start_line"]) ?? 1
        let endLine = coerceInt(args["end_line"]) ?? lines.count
        let validStart = max(1, min(startLine, lines.count))
        let validEnd = max(validStart, min(endLine, lines.count))

        var output = ""
        var lastLineIncluded = validStart - 1
        for i in (validStart - 1) ..< validEnd {
            let line = String(format: "%6d| %@\n", i + 1, lines[i])
            if output.count + line.count > Self.maxOutputChars {
                break
            }
            output += line
            lastLineIncluded = i + 1
        }

        if output.isEmpty {
            return ToolEnvelope.success(tool: name, text: "(empty file)")
        }

        // If truncated, inform the model and suggest using line ranges
        if lastLineIncluded < validEnd {
            output +=
                "\n... (truncated at \(lastLineIncluded) of \(lines.count) lines — use start_line/end_line for specific ranges)"
        }

        let text: String
        if validStart > 1 || validEnd < lines.count {
            text = "Lines \(validStart)-\(validEnd) of \(lines.count):\n" + output
        } else {
            text = output
        }
        let contentEnd = max(validStart - 1, lastLineIncluded)
        let rawContent: String
        if contentEnd > validStart - 1 {
            rawContent = lines[(validStart - 1) ..< contentEnd].joined(separator: "\n")
        } else {
            rawContent = ""
        }
        return ToolEnvelope.success(
            tool: name,
            result: [
                "text": text,
                "content": rawContent,
                "path": relativePath,
                "start_line": validStart,
                "end_line": lastLineIncluded,
                "total_lines": lines.count,
                "truncated": lastLineIncluded < validEnd,
            ]
        )
    }

    /// Pull text out of the file at `url`, throwing `binaryContent` when
    /// the file is not decodable as text. Two branches:
    ///   - rich extensions go through `DocumentParser` (PDFKit /
    ///     `NSAttributedString`);
    ///   - other extensions read raw bytes, NUL-sniff the first 4KB,
    ///     then UTF-8 decode. The byte-first ordering catches binaries
    ///     whose UTF-8 prefix happens to be valid by coincidence.
    private func loadFileContent(
        url: URL,
        relativePath: String,
        ext: String
    ) async throws -> String {
        if Self.richDocumentExtensions.contains(ext) {
            return try await extractRichDocumentText(
                url: url,
                relativePath: relativePath,
                ext: ext
            )
        }
        switch WorkspaceFileFormatPolicy.readSupport(for: ext) {
        case .workbook, .extractedText:
            // PowerPoint / Excel (upstream #91) through the registered
            // document adapters.
            return try await extractWithDocumentAdapter(url: url, relativePath: relativePath, ext: ext)
        case .image:
            return try await recognizeImageText(url: url, relativePath: relativePath, ext: ext)
        case .rawText, .unsupportedDocument:
            break
        }

        let data = try Data(contentsOf: url)
        if data.prefix(Self.binarySniffBytes).contains(0) {
            throw binaryError(path: relativePath, ext: ext, detail: .nulByte)
        }
        if let text = String(data: data, encoding: .utf8) {
            return text
        }
        throw binaryError(path: relativePath, ext: ext, detail: .decodeFailed)
    }

    /// Run `DocumentParser.parse(url:)` on a detached task so the
    /// parser's internal `runBlocking` semaphore can't starve the
    /// cooperative thread pool. Matches the production pattern in
    /// `FloatingInputCard`.
    private func extractRichDocumentText(
        url: URL,
        relativePath: String,
        ext: String
    ) async throws -> String {
        let attachment: Attachment
        do {
            attachment = try await Task.detached(priority: .userInitiated) {
                try DocumentParser.parse(url: url)
            }.value
        } catch let err as DocumentParser.ParseError {
            switch err {
            case .emptyContent:
                // Empty rich doc — surface as empty string; downstream
                // slicing produces the same "(empty)" output the plain-
                // text path would for a zero-byte `.txt`.
                return ""
            case .unsupportedFormat, .readFailed, .fileTooLarge:
                throw binaryError(path: relativePath, ext: ext, detail: .parseFailed)
            }
        }
        if case .document(_, let text, _) = attachment.kind {
            return text
        }
        // Image-only (scanned) PDF: DocumentParser falls back to page
        // images. Recognize their text on-device (upstream #91); only when
        // nothing is legible does the model get the image-only-PDF error.
        if ext == "pdf", let ocr = await FileReadImageSupport.ocrImageOnlyPDF(url: url) {
            let scope =
                ocr.pagesScanned < ocr.totalPages
                ? "pages 1–\(ocr.pagesScanned) of \(ocr.totalPages)" : "\(ocr.totalPages) pages"
            return "(Scanned PDF — text recognized by OCR, \(scope).)\n" + ocr.text
        }
        throw binaryError(path: relativePath, ext: ext, detail: .imageOnlyPdf)
    }

    /// PowerPoint / Excel text via `DocumentFormatRegistry` (upstream #91).
    private func extractWithDocumentAdapter(url: URL, relativePath: String, ext: String) async throws -> String {
        DocumentAdaptersBootstrap.registerBuiltIns()
        guard let adapter = DocumentFormatRegistry.shared.adapter(for: url) else {
            throw binaryError(path: relativePath, ext: ext, detail: .parseFailed)
        }
        do {
            let document = try await adapter.parse(url: url, sizeLimit: Int64(FileReadImageSupport.maxSourceBytes))
            return document.textFallback
        } catch DocumentAdapterError.emptyContent {
            return ""
        } catch {
            throw binaryError(path: relativePath, ext: ext, detail: .parseFailed)
        }
    }

    /// Images: Intel chat is text-only, so recognize the image's text with
    /// the Vision framework (upstream #91's text-only-model path). A blank
    /// image is refused honestly rather than returned as empty.
    private func recognizeImageText(url: URL, relativePath: String, ext: String) async throws -> String {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        guard size <= FileReadImageSupport.maxSourceBytes, let data = try? Data(contentsOf: url) else {
            throw binaryError(path: relativePath, ext: ext, detail: .parseFailed)
        }
        let lines = await FileReadImageSupport.recognizeTextLines(in: data)
            .filter { $0.contains(where: { !$0.isWhitespace }) }
        guard !lines.isEmpty else {
            throw binaryError(path: relativePath, ext: ext, detail: .imageWithoutText)
        }
        return "(Image — text recognized by OCR; layout and graphics are not described.)\n"
            + lines.joined(separator: "\n")
    }

    /// Construct a `binaryContent` error, normalising an empty extension
    /// to `nil` so the envelope mapper doesn't emit a bare `(.)` label.
    private func binaryError(
        path: String,
        ext: String,
        detail: FolderToolError.BinaryDetail
    ) -> FolderToolError {
        .binaryContent(
            path: path,
            ext: ext.isEmpty ? nil : ext,
            detail: detail
        )
    }
}

// MARK: File Write Tool

struct FileWriteTool: OsaurusTool, PermissionedTool {
    let name = "file_write"
    let description =
        "Create a new file or overwrite an existing file with the provided content: "
        + WorkspaceFileFormatPolicy.writableFormatsSummary
        + ". The extension picks the format; document generation is built in, so never shell out to "
        + "pandoc or Python for it. **Use this instead of `echo` / `cat` heredoc in `shell_run`.** "
        + "Parent directories will be created if they don't exist. You MUST provide the file "
        + "contents in the `content` parameter. Pass `dry_run: true` to preview a document without "
        + "writing it."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Relative path for the file"),
            ]),
            "content": .object([
                "type": .string("string"),
                "description": .string(
                    "Content to write. For .docx/.pdf: Markdown or HTML. For .xlsx: CSV/TSV text or JSON rows. For .pptx: Markdown (each `#`/`##` heading starts a slide)."
                ),
            ]),
            "dry_run": .object([
                "type": .string("boolean"),
                "description": .string("Preview a document target (.docx/.pdf/.xlsx) without writing it."),
            ]),
        ]),
        "required": .array([.string("path"), .string("content")]),
    ])

    var requirements: [String] { [] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .auto }
    var mutatesHostFolder: Bool { true }

    func declaredMutationTargets(argumentsJSON: String) -> [String]? {
        FileChangeCapture.declaredPaths(argumentsJSON, keys: ["path"])
    }

    private let fixedRootPath: URL?

    init(rootPath: URL? = nil) {
        self.fixedRootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let rootPath = try FolderToolHelpers.requireRoot(fixed: fixedRootPath)
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let pathReq = requireString(
            args,
            "path",
            expected: "relative path under the working folder (e.g. `src/app.py`)",
            tool: name
        )
        guard case .value(let relativePath) = pathReq else {
            return pathReq.failureEnvelope ?? ""
        }

        // `content: ""` is legitimate (truncate-to-zero), so allow empty.
        let contentReq = requireString(
            args,
            "content",
            expected: "string of file contents (use `\"\"` for an empty file)",
            tool: name,
            allowEmpty: true
        )
        guard case .value(let content) = contentReq else {
            return contentReq.failureEnvelope ?? ""
        }

        let fileURL = try FolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)
        let ext = fileURL.pathExtension.lowercased()
        let dryRun = (args["dry_run"] as? Bool) ?? false

        // Upstream #91: document targets render through the built-in
        // emitters; recognised document formats we can't produce are
        // refused instead of getting Markdown bytes under a binary extension.
        let documentTarget = FileWriteDocumentRouting.target(forExtension: ext)
        if documentTarget == nil, WorkspaceFileFormatPolicy.prefersDocumentExtraction(ext) {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "file_write can't produce .\(ext) files. It writes "
                    + WorkspaceFileFormatPolicy.writableFormatsSummary
                    + ". Pick one of those extensions.",
                field: "path",
                tool: name,
                retryable: false
            )
        }
        // Upstream #2914: `content` that is a `file_edit` operations array
        // would replace the document with that JSON as text. Point at
        // `file_edit` instead; nothing is written.
        if let operations = Self.fileEditOperationsPayload(content) {
            let opNames = operations.compactMap { $0["op"] as? String }
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "`content` is a list of `file_edit` operations (\(opNames.joined(separator: ", "))), not a document body — writing it would replace '\(relativePath)' with that JSON as text. "
                    + "Call `file_edit` with {\"path\": \"\(relativePath)\", \"operations\": \(Self.compactJSON(operations))} instead; the file was not changed.",
                field: "content",
                expected: "the document body, or use file_edit for operations",
                tool: name,
                retryable: false,
                metadata: ["retry_with": ["path": relativePath, "operations": operations]]
            )
        }
        var documentPlan: FileWriteDocumentRouting.Plan?
        if let documentTarget {
            do {
                documentPlan = try FileWriteDocumentRouting.plan(
                    target: documentTarget, content: content, filename: fileURL.lastPathComponent)
            } catch {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "Couldn't build the .\(ext) document: \(error.localizedDescription). "
                        + "Expected content: \(documentTarget.contentHint).",
                    field: "content",
                    tool: name,
                    retryable: true
                )
            }
            if dryRun, let plan = documentPlan {
                return ToolEnvelope.success(
                    tool: name,
                    result: [
                        "dry_run": true, "path": relativePath, "format": documentTarget.rawValue,
                        "summary": plan.summary,
                    ])
            }
        }

        // Undo: the registry's file history capture snapshots the previous
        // bytes (binary-safe) before this call runs (upstream #2907 part A).
        let existed = FileManager.default.fileExists(atPath: fileURL.path)

        if let plan = documentPlan {
            let written = try await FileWriteDocumentRouting.write(plan, to: fileURL)
            var result: [String: Any] = [
                "kind": "document_write_result",
                "path": relativePath,
                "format": plan.target.rawValue,
                "bytes_written": written.bytesWritten,
                "summary": plan.summary,
                "action": existed ? "updated" : "created",
            ]
            for (key, value) in written.extra { result[key] = value }
            return ToolEnvelope.success(tool: name, result: FolderToolHelpers.withOperationId(result))
        }

        // Create parent directories if needed
        let parentDir = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentDir,
            withIntermediateDirectories: true,
            attributes: nil
        )

        // Write content
        try content.write(to: fileURL, atomically: true, encoding: .utf8)

        let lineCount = FolderToolHelpers.contentLines(content).count
        let action = existed ? "Updated" : "Created"
        return ToolEnvelope.success(
            tool: name,
            result: FolderToolHelpers.withOperationId([
                "text": "\(action) \(relativePath) (\(lineCount) lines, \(content.count) characters)"
            ])
        )
    }

    /// `content` parsed as a `file_edit` operations array (upstream #2914): a
    /// JSON array (optionally `{"operations": [...]}`) whose every element has
    /// an `op` the document editors know. Anything else — including a bare
    /// array of rows for `.xlsx` — is nil.
    static func fileEditOperationsPayload(_ content: String) -> [[String: Any]]? {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("[") || trimmed.hasPrefix("{"),
            let data = trimmed.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        let list: [[String: Any]]?
        if let array = object as? [[String: Any]] {
            list = array
        } else if let dict = object as? [String: Any], dict.count == 1 {
            list = dict["operations"] as? [[String: Any]]
        } else {
            list = nil
        }
        guard let list, !list.isEmpty else { return nil }
        let known = Set(DocumentEditService.allOperationNames)
        guard list.allSatisfy({ ($0["op"] as? String).map(known.contains) == true }) else { return nil }
        return list
    }

    static func compactJSON(_ value: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: .osaurusCanonical),
            let text = String(data: data, encoding: .utf8)
        else { return "[…]" }
        return text.count > 400 ? String(text.prefix(400)) + "…" : text
    }
}

// MARK: - Coding Tools
//
// `file_move`, `file_copy`, `file_delete`, `dir_create` were dropped in
// favour of `shell_run` (`mv`, `cp`, `rm`, `mkdir`) so the model has one
// tool to learn for filesystem mutations rather than four. Removal also
// trims the schema by ~1KB tokens per turn.

// MARK: File Edit Tool

struct FileEditTool: OsaurusTool, PermissionedTool {
    let name = "file_edit"
    let description =
        "Edit a file by replacing specific text. **Use this instead of `sed` / `awk` in "
        + "`shell_run`.** `old_string` must uniquely match exactly one location in the file — "
        + "include surrounding context lines if needed to ensure uniqueness. Copy the RAW file "
        + "text only: never include the `N|` line-number prefixes shown in `file_read` output. "
        + "Small drift is tolerated when the match stays unique — indentation, tabs vs spaces, "
        + "blank-line count, curly vs straight quotes — and the result reports `match_strategy` "
        + "(\"exact\" when it matched byte-for-byte); the file's own whitespace is kept for "
        + "unchanged lines. Fails if `old_string` is not found or matches multiple locations; "
        + "pass `replace_all: true` to replace every occurrence. You MUST provide the strings "
        + "in the parameters. "
        + "Documents (.docx/.xlsx/.pptx/.pdf) are edited in place with `operations` (formatting, styles, media and "
        + "untouched content are kept): call `file_read` with `mode: \"structure\"` first to get paragraph numbers, "
        + "cells, slides/shapes, or pages and form fields. For .docx/.pptx, `old_string`/`new_string` also works "
        + "(text is matched across formatting runs). Pass `dry_run: true` to preview a document edit."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Relative path to the file"),
            ]),
            "old_string": .object([
                "type": .string("string"),
                "description": .string(
                    "The exact text to find and replace (must uniquely match one location in the file)"
                ),
            ]),
            "new_string": .object([
                "type": .string("string"),
                "description": .string(
                    "The replacement text"
                ),
            ]),
            "replace_all": .object([
                "type": .string("boolean"),
                "description": .string(
                    "Replace every occurrence of old_string instead of requiring a unique match (default false)"
                ),
            ]),
            "operations": .object([
                "type": .string("array"),
                "description": .string(
                    "Document edits for .docx/.xlsx/.pptx/.pdf, applied in order and atomically (all or nothing), each {\"op\": name, …}; `op` may be left out when the keys name a content edit (e.g. {old_string, new_string} or {cells}). "
                        + "`sheet`, `slide`, `cells`, `page` and every other operation key go INSIDE the operation object, never at the top level of the call. "
                        + ".docx: replace_text {old_string, new_string, replace_all?}, insert_paragraph {text, after|before, style?}, delete_paragraph {index}, "
                        + "set_table_cell {table, row, column, text}, append_markdown {markdown}. "
                        + "Example: {\"path\": \"brief.docx\", \"operations\": [{\"op\": \"replace_text\", \"old_string\": \"Q3\", \"new_string\": \"Q4\", \"replace_all\": true}]}. "
                        + ".xlsx: set_cells {sheet?, cells: {\"B3\": 42, \"C3\": \"=SUM(B1:B2)\", \"D3\": null}}, insert_rows / delete_rows {sheet?, at, count?}, "
                        + "add_sheet {name}, rename_sheet {sheet, name}, delete_sheet {sheet}. "
                        + "Example: {\"path\": \"q3.xlsx\", \"operations\": [{\"op\": \"set_cells\", \"sheet\": \"Summary\", \"cells\": {\"B2\": 1200, \"B3\": \"=B2*1.1\"}}]}. "
                        + ".pptx: replace_text {old_string, new_string, replace_all?, slide?}, set_slide_text {slide, shape: title|subtitle|body|number, text}, "
                        + "duplicate_slide {slide}, delete_slide {slide}, reorder_slides {order}. "
                        + "Example: {\"path\": \"deck.pptx\", \"operations\": [{\"op\": \"set_slide_text\", \"slide\": 2, \"shape\": \"title\", \"text\": \"Roadmap\"}]}. "
                        + ".pdf: delete_pages {pages}, reorder_pages {order}, rotate_pages {pages?, degrees}, merge {files}, fill_form {fields: {\"Name\": \"Ada\", \"Agree\": true, \"Plan\": \"Pro\"}} (`file_read` mode \"structure\" lists form_fields with types and options), "
                        + "add_text {page, text, x?, y?}, add_note {page, text}, highlight {text, page?}. "
                        + "Example: {\"path\": \"intake.pdf\", \"operations\": [{\"op\": \"fill_form\", \"fields\": {\"Name\": \"Ada Lovelace\", \"Agree\": true}}]}. Numbers are 1-based."
                ),
                // Free-form on purpose: see `DocumentEditService.operationItemSchema`
                // (schema-constrained decoders drop undeclared keys otherwise).
                "items": DocumentEditService.operationItemSchema,
            ]),
            "dry_run": .object([
                "type": .string("boolean"),
                "description": .string("Documents: preview the edit (with a text diff) without writing it"),
            ]),
        ]),
        "required": .array([.string("path")]),
    ])

    var requirements: [String] { [] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .auto }
    var mutatesHostFolder: Bool { true }

    func declaredMutationTargets(argumentsJSON: String) -> [String]? {
        FileChangeCapture.declaredPaths(argumentsJSON, keys: ["path"])
    }

    private let fixedRootPath: URL?

    init(rootPath: URL? = nil) {
        self.fixedRootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let rootPath = try FolderToolHelpers.requireRoot(fixed: fixedRootPath)
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let pathReq = requireString(
            args,
            "path",
            expected: "relative path under the working folder (e.g. `src/app.py`)",
            tool: name
        )
        guard case .value(let relativePath) = pathReq else {
            return pathReq.failureEnvelope ?? ""
        }

        // Upstream #2907/#2914: documents are edited in place.
        let documentExtension = URL(fileURLWithPath: relativePath).pathExtension.lowercased()
        if DocumentEditService.isEditable(documentExtension) {
            return try await editDocument(
                args: args, relativePath: relativePath, ext: documentExtension, rootPath: rootPath,
                dryRun: coerceBool(args["dry_run"]) ?? false,
                replaceAll: coerceBool(args["replace_all"]) ?? false)
        }
        if args["operations"] != nil {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "`operations` edits .docx, .xlsx, .pptx and .pdf documents. For this file use `old_string`/`new_string`.",
                field: "operations",
                expected: "old_string/new_string for text files",
                tool: name
            )
        }

        // Empty `old_string` is ambiguous — `requireString` (default
        // `allowEmpty: false`) rejects it with a pointed envelope that
        // matches `sandbox_edit_file`.
        let oldReq = requireString(
            args,
            "old_string",
            expected: "non-empty exact text that uniquely matches one location in the file",
            tool: name
        )
        guard case .value(let oldString) = oldReq else {
            return oldReq.failureEnvelope ?? ""
        }

        // Empty `new_string` is the supported delete-the-match form.
        let newReq = requireString(
            args,
            "new_string",
            expected: "replacement text (use `\"\"` to delete the match)",
            tool: name,
            allowEmpty: true
        )
        guard case .value(let newString) = newReq else {
            return newReq.failureEnvelope ?? ""
        }

        let fileURL = try FolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)
        // Other binary documents (legacy .doc/.xls/.ppt, .rtf, …) can't be
        // text-edited: they are regenerated with file_write.
        let editExt = fileURL.pathExtension.lowercased()
        if FileWriteDocumentRouting.target(forExtension: editExt) != nil
            || WorkspaceFileFormatPolicy.prefersDocumentExtraction(editExt)
        {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "file_edit changes text files and .docx/.xlsx/.pptx/.pdf documents; `\(relativePath)` is a .\(editExt) file. "
                    + "Read it with file_read, then write the whole updated document with file_write "
                    + "(" + WorkspaceFileFormatPolicy.writableFormatsSummary + ").",
                field: "path",
                tool: name,
                retryable: false
            )
        }

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw FolderToolError.fileNotFound(relativePath)
        }

        // Capture pre-edit contents for the operation log (undo support).
        let originalContent = try String(contentsOf: fileURL, encoding: .utf8)
        let replaceAll = coerceBool(args["replace_all"]) ?? false

        // Upstream #2914: exact → whitespace → blank lines → unicode
        // punctuation cascade, byte-preserving outside the match; relaxed
        // matches only when unique (or `replace_all`).
        let applied: FileEditMatcher.Applied
        switch FileEditMatcher.apply(
            oldString: oldString, newString: newString, to: originalContent, replaceAll: replaceAll)
        {
        case .noOp:
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "`old_string` and `new_string` are identical in \(relativePath) — there is nothing to change. "
                    + "If the file already has the intended text, the edit is done; otherwise fix `new_string`.",
                field: "new_string",
                expected: "replacement text that differs from old_string",
                tool: name
            )
        case .notFound:
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "Could not find `old_string` in \(relativePath). "
                    + Self.noMatchDiagnosis(oldString: oldString, content: originalContent),
                field: "old_string",
                expected: "exact non-empty text present in the target file",
                tool: name
            )
        case .ambiguous(let count, let strategy):
            let how = strategy.isRelaxed ? " (matching \(strategy.explanation))" : ""
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "Found \(count) matches for `old_string` in \(relativePath)\(how). "
                    + "To replace EVERY occurrence, retry the same call with the added argument "
                    + "\"replace_all\": true. To replace only one occurrence, include more surrounding "
                    + "context in `old_string`.",
                field: "old_string",
                expected: "the same call plus \"replace_all\": true (or a uniquely matching old_string)",
                tool: name,
                metadata: ["retry_with": ["replace_all": true]]
            )
        case .applied(let result):
            applied = result
        }
        try applied.content.write(to: fileURL, atomically: true, encoding: .utf8)

        let beforeLines = FolderToolHelpers.contentLines(oldString).count
        let afterLines = FolderToolHelpers.contentLines(newString).count
        let lineLabels = applied.matchedLines.map {
            $0.lowerBound == $0.upperBound ? "\($0.lowerBound)" : "\($0.lowerBound)-\($0.upperBound)"
        }
        var warnings: [String] = []
        if applied.strategy.isRelaxed {
            let where_ = applied.matchedLines.first.map { range in
                range.lowerBound == range.upperBound
                    ? "line \(range.lowerBound)" : "lines \(range.lowerBound)-\(range.upperBound)"
            } ?? "the matched region"
            var note =
                "`old_string` did not match the file byte-for-byte; it was matched at \(where_) "
                + "with \(applied.strategy.explanation). The file's own indentation, blank lines and line "
                + "endings were kept for unchanged lines"
            if applied.replacements > 1 { note += " (\(applied.replacements) occurrences)" }
            note += "."
            if let matched = applied.matchedText {
                note += " The file text there was:\n\(Self.boundedQuote(matched))"
            }
            warnings.append(note)
        }
        let occurrences = applied.replacements > 1 ? " in \(applied.replacements) places" : ""
        return ToolEnvelope.success(
            tool: name,
            result: FolderToolHelpers.withOperationId([
                "text":
                    "Edited \(relativePath): replaced \(beforeLines) line(s) with \(afterLines) line(s)\(occurrences)",
                "match_strategy": applied.strategy.rawValue,
                "replacements": applied.replacements,
                "matched_lines": lineLabels,
            ]),
            warnings: warnings
        )
    }

    /// In-place document edit (upstream #2907/#2914 `editDocument`, Intel
    /// host-folder version): prepare on a staged copy, re-open it with the
    /// app's own parsers, diff the text, then swap atomically. Undo comes from
    /// the registry's file history capture around the call.
    private func editDocument(
        args: [String: Any], relativePath: String, ext: String, rootPath: URL,
        dryRun: Bool, replaceAll: Bool
    ) async throws -> String {
        let fileURL = try FolderToolHelpers.resolvePath(relativePath, rootPath: rootPath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw FolderToolError.fileNotFound(relativePath)
        }

        let operations: [[String: Any]]
        if let raw = args["operations"] {
            guard let list = raw as? [[String: Any]], !list.isEmpty else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "`operations` must be a non-empty array of {\"op\": …} objects.",
                    field: "operations", expected: "array of operation objects", tool: name)
            }
            operations = list
        } else if args["old_string"] != nil {
            guard ext == "docx" || ext == "pptx" else {
                let hint =
                    ext == "pdf"
                    ? "PDF body text can't be rewritten in place. Edit the source document and export again, or regenerate with `file_write`; `operations` can still delete/reorder/rotate pages, fill forms, and add text boxes or highlights."
                    : "Use `operations` with `set_cells` (e.g. {\"op\": \"set_cells\", \"cells\": {\"B3\": 42}}); `file_read` with `mode: \"structure\"` lists the cells."
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "old_string/new_string text edits aren't supported for .\(ext). \(hint)",
                    field: "old_string", expected: "`operations` for .\(ext)", tool: name)
            }
            guard let old = args["old_string"] as? String, !old.isEmpty, let new = args["new_string"] as? String else {
                // Only an empty old_string WITH new text is an insert; name the
                // operations that add text in that case alone (upstream).
                let isInsert = (args["old_string"] as? String)?.isEmpty == true && args["new_string"] is String
                let insertHint = !isInsert ? "" :
                    ext == "docx"
                    ? " To add text without replacing any, use `operations`: {\"op\": \"append_markdown\", \"markdown\": \"## Heading\\n- item\"} or {\"op\": \"insert_paragraph\", \"text\": \"…\", \"after\": N} (`file_read` mode \"structure\" numbers paragraphs)."
                    : " To add text without replacing any, use `operations` with `set_slide_text` (or `duplicate_slide` then `set_slide_text`)."
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "Pass a non-empty `old_string` and a `new_string`." + insertHint,
                    field: "old_string", expected: "document text to replace", tool: name)
            }
            operations = [["op": "replace_text", "old_string": old, "new_string": new, "all": replaceAll]]
        } else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    (ext == "docx" || ext == "pptx"
                        ? "Nothing to apply: pass `old_string` + `new_string` (text is matched across runs) or `operations` "
                        : "Pass `operations` ")
                    + "to edit this .\(ext) (\(DocumentEditService.operationNames(for: ext).joined(separator: ", "))). "
                    + "Call `file_read` with `mode: \"structure\"` to see what can be addressed.",
                field: "operations", expected: "`operations` array", tool: name)
        }

        let prepared: DocumentEditService.PreparedEdit
        do {
            prepared = try await DocumentEditService.prepare(
                fileURL: fileURL,
                displayPath: relativePath,
                operations: operations,
                resolvePath: { try FolderToolHelpers.resolvePath($0, rootPath: rootPath) }
            )
        } catch let error as DocumentEditError {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: error.message + (error.message.contains("unchanged") ? "" : " Nothing was changed."),
                field: "operations", expected: "operations valid for this document", tool: name)
        }

        var payload: [String: Any] = [
            "path": relativePath,
            "format": ext,
            "action": "update",
            "dry_run": dryRun,
            "operations_applied": prepared.summaries,
        ]
        if let diff = prepared.diffText {
            payload["diff"] = diff
            payload["diff_truncated"] = prepared.diffTruncated
        }
        var warnings = prepared.warnings
        if dryRun {
            prepared.discard()
            warnings.append(
                "PREVIEW ONLY - nothing was written. The document is unchanged. Repeat the same call WITHOUT dry_run to apply it.")
            return ToolEnvelope.success(tool: name, result: payload, warnings: warnings)
        }
        do {
            try prepared.commit()
        } catch let error as DocumentEditError {
            return ToolEnvelope.failure(kind: .executionError, message: error.message, field: "path", tool: name)
        }
        return ToolEnvelope.success(tool: name, result: FolderToolHelpers.withOperationId(payload), warnings: warnings)
    }

    /// Truthful diagnosis for a 0-match `old_string` (upstream #2914). The
    /// generic "make sure it matches" message left models re-issuing the
    /// identical failing call.
    static func noMatchDiagnosis(oldString: String, content: String) -> String {
        let fallback = "Make sure it exactly matches the file content."
        let oldLines = oldString.components(separatedBy: "\n")

        // 1. Line-number prefix contamination (`   42|item 042 ...`).
        let prefixPattern = #"^\s*\d+\|"#
        if oldLines.contains(where: { $0.range(of: prefixPattern, options: .regularExpression) != nil }) {
            return "Your `old_string` contains `N|` line-number prefixes from file_read output — "
                + "those prefixes are display metadata, not file content. Copy the raw file text only."
        }

        let contentLines = content.components(separatedBy: "\n")
        let trimmedOldLines = oldLines.map { $0.trimmingCharacters(in: .whitespaces) }

        // 2. Closest-line anchor: quote the most similar file line when it is
        // a plausible anchor (the line changed after the model last read it).
        if let needle = trimmedOldLines.first(where: { !$0.isEmpty }), needle.count >= 4 {
            let needleLower = needle.lowercased()
            var best: (index: Int, line: String, score: Int)?
            for (index, line) in contentLines.enumerated() {
                let trimmedLine = line.trimmingCharacters(in: .whitespaces)
                guard !trimmedLine.isEmpty else { continue }
                let lineLower = trimmedLine.lowercased()
                let score: Int
                if lineLower.contains(needleLower) || needleLower.contains(lineLower) {
                    score = min(needle.count, trimmedLine.count)
                } else {
                    score = zip(needleLower, lineLower).prefix(while: { $0 == $1 }).count
                }
                if score > (best?.score ?? 0) { best = (index, line, score) }
            }
            let minScore = max(4, needle.count / 2)
            if let best, best.score >= minScore {
                return "The closest matching line in the file is line \(best.index + 1):\n"
                    + "\(Self.boundedQuote(best.line))\n"
                    + "Compare it against your `old_string` — they differ. \(fallback)"
            }
        }
        return fallback
    }

    private static func boundedQuote(_ text: String, cap: Int = 600) -> String {
        guard text.count > cap else { return text }
        return String(text.prefix(cap)) + "… (excerpt truncated)"
    }
}

// MARK: File Operation History Tool

struct FileOperationHistoryTool: OsaurusTool {
    let name = "file_operation_history"
    let description =
        "Show recent file changes made by this chat session, newest first: one entry per tool call "
        + "with every file it created, modified, or deleted. Use this before undo/review or after "
        + "multi-file work to inspect what changed. Optional `path` filters to one file."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Optional relative file path to filter history"),
            ]),
            "limit": .object([
                "type": .string("integer"),
                "description": .string("Maximum entries to return (default: 20, max: 100)"),
            ]),
        ]),
        "required": .array([]),
    ])

    private let fixedRootPath: URL?
    private let journal: FileChangeJournal

    init(rootPath: URL? = nil, journal: FileChangeJournal = .shared) {
        self.fixedRootPath = rootPath
        self.journal = journal
    }

    func execute(argumentsJSON: String) async throws -> String {
        guard let sessionId = ChatExecutionContext.currentSessionId, !sessionId.isEmpty else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: "`file_operation_history` requires an active chat session.",
                tool: name,
                retryable: false
            )
        }

        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let rootPath = FolderToolHelpers.resolveRoot(fixed: fixedRootPath)
        let pathFilter = (args["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let limit = min(max(coerceInt(args["limit"]) ?? 20, 1), 100)
        let sets = await journal.changeSets(for: sessionId)
        let filtered =
            pathFilter.flatMap { $0.isEmpty ? nil : $0 }.map { raw in
                sets.filter { set in
                    set.entries.contains { Self.matches($0, raw: raw, rootPath: rootPath) }
                }
            } ?? sets
        let recent = Array(filtered.suffix(limit).reversed())
        var payload: [String: Any] = [
            "kind": "file_operation_history",
            "session_id": sessionId,
            "entries": recent.map(Self.historyEntry),
            "operation_count": filtered.count,
            "returned_count": recent.count,
            "limit": limit,
        ]
        if let pathFilter, !pathFilter.isEmpty {
            payload["path"] = pathFilter
        }
        let warnings =
            filtered.count > limit
            ? ["History truncated to the \(limit) most recent matching operations."]
            : nil
        return ToolEnvelope.success(tool: name, result: payload, warnings: warnings)
    }

    /// Whether `entry` is the file the model named: a path relative to
    /// (or absolute under) the host folder, or a sandbox display path.
    static func matches(_ entry: FileChangeEntry, raw: String, rootPath: URL?) -> Bool {
        if entry.displayPath == raw || entry.path == FileChangeJournal.normalize(raw) {
            return true
        }
        if entry.rootKind == .hostFolder, let rootPath,
            case .path(let rel) = FileChangeCapture.resolveHost(raw, folder: rootPath)
        {
            return entry.path == rel
        }
        return false
    }

    static func historyEntry(_ set: FileChangeSet) -> [String: Any] {
        var entry: [String: Any] = [
            "id": set.id.uuidString,
            "tool": set.toolName,
            "origin": set.origin.rawValue,
            "status": set.status.rawValue,
            "timestamp": ISO8601DateFormatter().string(from: set.createdAt),
            "can_undo": set.isRevertible && set.status != .reverted,
            "files": set.entries.map { e -> [String: Any] in
                var file: [String: Any] = [
                    "path": e.rootKind == .hostFolder ? e.path : e.displayPath,
                    "change": e.kind.rawValue,
                    "state": e.state.rawValue,
                ]
                if let from = e.fromPath { file["renamed_from"] = from }
                if e.entryType != .file { file["type"] = e.entryType.rawValue }
                return file
            },
        ]
        if let note = set.note { entry["note"] = note }
        return entry
    }
}

// MARK: File Undo Tool

struct FileUndoTool: OsaurusTool, PermissionedTool {
    let name = "file_undo"
    let description =
        "Revert file changes made by this chat session. With no arguments it undoes the most "
        + "recent change; pass `operation_id` (from `file_operation_history` or a write result) to "
        + "undo one specific tool call, or `path` to restore one file to how it was before this "
        + "chat touched it. If both are given, `operation_id` wins (path is checked against that "
        + "operation's files). Files changed again since (by the user or another chat) are left "
        + "untouched and reported. Check `file_operation_history` first when unsure what would be undone."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "operation_id": .object([
                "type": .string("string"),
                "description": .string(
                    "ID of one specific operation to undo (from `file_operation_history`)"
                ),
            ]),
            "path": .object([
                "type": .string("string"),
                "description": .string(
                    "Relative file path: restore this file to its state before this chat changed it"
                ),
            ]),
        ]),
        "required": .array([]),
    ])

    var requirements: [String] { [] }
    /// Mutates the working folder — same gate class as `file_write`.
    var defaultPermissionPolicy: ToolPermissionPolicy { .auto }
    // Not a registry-captured mutation: the journal records each revert
    // as its own change set (so an undo can itself be undone).

    private let fixedRootPath: URL?
    private let journal: FileChangeJournal

    init(rootPath: URL? = nil, journal: FileChangeJournal = .shared) {
        self.fixedRootPath = rootPath
        self.journal = journal
    }

    func execute(argumentsJSON: String) async throws -> String {
        guard let sessionId = ChatExecutionContext.currentSessionId, !sessionId.isEmpty else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: "`file_undo` requires an active chat session.",
                tool: name,
                retryable: false
            )
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let rootPath = FolderToolHelpers.resolveRoot(fixed: fixedRootPath)
        let operationIdRaw = (args["operation_id"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let rawPath = (args["path"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let sets = await journal.changeSets(for: sessionId)

        let scope: FileChangeJournal.RevertScope
        var undoneSet: FileChangeSet?
        if let operationIdRaw, !operationIdRaw.isEmpty {
            guard let operationId = UUID(uuidString: operationIdRaw) else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "`operation_id` is not a valid operation ID.",
                    field: "operation_id",
                    expected: "UUID from `file_operation_history`",
                    tool: name
                )
            }
            guard let set = sets.first(where: { $0.id == operationId }) else {
                return ToolEnvelope.failure(
                    kind: .notFound,
                    message: "No operation `\(operationIdRaw)` in this session's file history.",
                    field: "operation_id",
                    tool: name
                )
            }
            // Both args together are fine when they AGREE — models
            // routinely echo the path alongside the id (observed live:
            // gemma-4-12B sent `{"operation_id": …, "path":
            // "CHANGELOG.md"}`, got the old "not both" rejection, and
            // spiralled into a blind rewrite instead of the undo).
            // Only an actual DISAGREEMENT is ambiguous and refused.
            if let rawPath, !rawPath.isEmpty,
                !set.entries.contains(where: {
                    FileOperationHistoryTool.matches($0, raw: rawPath, rootPath: rootPath)
                })
            {
                let files = set.entries.map(\.path).joined(separator: "`, `")
                return ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message:
                        "`operation_id` \(operationIdRaw) is an operation on `\(files)`, not "
                        + "`\(rawPath)`. Pass just the `operation_id`, or just `path` to restore "
                        + "that file.",
                    field: "path",
                    expected: "arguments that refer to the same file",
                    tool: name
                )
            }
            guard set.status != .reverted else {
                return ToolEnvelope.failure(
                    kind: .rejected,
                    message: "Operation `\(operationIdRaw)` was already undone.",
                    field: "operation_id",
                    tool: name,
                    retryable: false
                )
            }
            scope = .set(operationId)
            undoneSet = set
        } else if let rawPath, !rawPath.isEmpty {
            let key = sets.flatMap(\.entries)
                .last { FileOperationHistoryTool.matches($0, raw: rawPath, rootPath: rootPath) }?
                .pathKey
            guard let key else {
                return ToolEnvelope.failure(
                    kind: .notFound,
                    message: "No logged operations found for `\(rawPath)` in this session — nothing to undo.",
                    field: "path",
                    tool: name
                )
            }
            scope = .file(key)
        } else {
            guard let latest = await journal.latestRevertibleAgentSet(sessionId: sessionId) else {
                return ToolEnvelope.failure(
                    kind: .notFound,
                    message: "No logged file operations in this session — nothing to undo.",
                    tool: name
                )
            }
            scope = .set(latest.id)
            undoneSet = latest
        }

        let preview = await journal.previewRevert(scope, sessionId: sessionId)
        let summary = await journal.revert(scope, sessionId: sessionId)
        if let blocked = summary.blockedReason {
            return ToolEnvelope.failure(kind: .unavailable, message: blocked, tool: name, retryable: true)
        }
        let conflicted = preview.items.filter(\.isConflict).map { $0.key.displayPath }
        if summary.restored == 0, summary.conflicted + summary.failed > 0 {
            var message = "Nothing was undone."
            if !conflicted.isEmpty {
                message +=
                    " These files changed after this chat's edit and were left untouched: "
                    + conflicted.joined(separator: ", ")
                    + ". Ask the user before overwriting them."
            }
            if !summary.failures.isEmpty { message += " " + summary.failures.joined(separator: "; ") }
            return ToolEnvelope.failure(kind: .executionError, message: message, tool: name, retryable: false)
        }
        var warnings: [String] = []
        if !conflicted.isEmpty {
            warnings.append(
                "Left untouched (changed after this chat's edit): " + conflicted.joined(separator: ", "))
        }
        warnings += summary.failures
        var result: [String: Any] = [
            "kind": "file_undo",
            "undone_count": summary.restored,
            // What actually changed on disk, not what the preview planned.
            "undone": summary.restoredPaths.map {
                ["path": $0.rootKind == .hostFolder ? $0.path : $0.displayPath]
            },
        ]
        if let undoneSet {
            result["undone_operation_id"] = undoneSet.id.uuidString
            result["undone_tool"] = undoneSet.toolName
        }
        if let revertId = summary.revertSetId {
            result["revert_operation_id"] = revertId.uuidString
        }
        return ToolEnvelope.success(tool: name, result: result, warnings: warnings.isEmpty ? nil : warnings)
    }
}

// MARK: File Search Tool

struct FileSearchTool: OsaurusTool {
    let name = "file_search"
    let description =
        "Search for text in files using case-insensitive substring matching, including inside PDF, "
        + "Word, PowerPoint and Excel files. **Use this instead of `grep` / `rg` / `find` in "
        + "`shell_run`.** Returns matching lines with file paths and line numbers (documents show "
        + "a page, slide, sheet or paragraph instead)."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "pattern": .object([
                "type": .string("string"),
                "description": .string("Text to search for (case-insensitive substring match)"),
            ]),
            "path": .object([
                "type": .string("string"),
                "description": .string(
                    "Optional directory or file path to search in (default: entire working directory)"
                ),
            ]),
            "file_pattern": .object([
                "type": .string("string"),
                "description": .string("Optional file name pattern (e.g., '*.swift', '*.ts')"),
            ]),
            "max_results": .object([
                "type": .string("integer"),
                "description": .string("Maximum number of results to return (default: 50)"),
            ]),
        ]),
        "required": .array([.string("pattern")]),
    ])

    private let fixedRootPath: URL?

    init(rootPath: URL? = nil) {
        self.fixedRootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let rootPath = try FolderToolHelpers.requireRoot(fixed: fixedRootPath)
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let patternReq = requireString(
            args,
            "pattern",
            expected: "search text (case-insensitive substring, e.g. `TODO`)",
            tool: name
        )
        guard case .value(let pattern) = patternReq else {
            return patternReq.failureEnvelope ?? ""
        }

        let searchPath = (args["path"] as? String) ?? "."
        let filePattern = args["file_pattern"] as? String
        let maxResults = coerceInt(args["max_results"]) ?? 50

        let searchURL = try FolderToolHelpers.resolvePath(searchPath, rootPath: rootPath)

        var results: [String] = []
        var totalMatches = 0
        var skippedDocuments = 0

        // Determine if searching a file or directory
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: searchURL.path, isDirectory: &isDirectory)
        else {
            throw FolderToolError.fileNotFound(searchPath)
        }

        if isDirectory.boolValue {
            // Search directory recursively
            let enumerator = FileManager.default.enumerator(
                at: searchURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )

            while let fileURL = enumerator?.nextObject() as? URL {
                guard totalMatches < maxResults else { break }

                // Check if regular file. A symlink reports false here and
                // the enumerator doesn't descend into linked folders, so the
                // walk never reads outside the root.
                guard
                    let resourceValues = try? fileURL.resourceValues(forKeys: [.isRegularFileKey]),
                    resourceValues.isRegularFile == true
                else { continue }

                // Check file pattern
                if let pattern = filePattern {
                    let regex = pattern.replacingOccurrences(of: ".", with: "\\.")
                        .replacingOccurrences(of: "*", with: ".*")
                    if fileURL.lastPathComponent.range(of: "^\(regex)$", options: .regularExpression)
                        == nil
                    {
                        continue
                    }
                }

                // Search file (documents through extracted text, upstream #91)
                let matches: [String]?
                if DocumentTextExtractionCache.isSearchableDocument(extension: fileURL.pathExtension) {
                    matches = await searchDocument(
                        fileURL, pattern: pattern, maxResults: maxResults - totalMatches,
                        rootPath: rootPath, skipped: &skippedDocuments)
                } else {
                    matches = searchFile(
                        fileURL, pattern: pattern,
                        maxResults: maxResults - totalMatches,
                        rootPath: rootPath
                    )
                }
                if let matches {
                    results.append(contentsOf: matches)
                    totalMatches += matches.count
                }
            }
        } else {
            // Search single file
            let matches: [String]?
            if DocumentTextExtractionCache.isSearchableDocument(extension: searchURL.pathExtension) {
                matches = await searchDocument(
                    searchURL, pattern: pattern, maxResults: maxResults, rootPath: rootPath,
                    skipped: &skippedDocuments)
            } else {
                matches = searchFile(searchURL, pattern: pattern, maxResults: maxResults, rootPath: rootPath)
            }
            if let matches {
                results.append(contentsOf: matches)
                totalMatches = matches.count
            }
        }

        let skippedNote =
            skippedDocuments > 0
            ? "\n(\(skippedDocuments) document(s) couldn't be searched — too large, encrypted or damaged.)" : ""
        if results.isEmpty {
            return ToolEnvelope.success(
                tool: name,
                text: "No matches found for '\(pattern)'" + skippedNote
            )
        }

        var output = "Found \(totalMatches) match(es):\n\n"
        output += results.joined(separator: "\n")

        if totalMatches >= maxResults {
            output += "\n\n(results truncated at \(maxResults))"
        }
        output += skippedNote

        return ToolEnvelope.success(tool: name, text: output)
    }

    /// Matches inside a document's extracted text (upstream #91), located by
    /// page / slide / sheet row / paragraph.
    private func searchDocument(
        _ url: URL, pattern: String, maxResults: Int, rootPath: URL, skipped: inout Int
    ) async -> [String]? {
        guard maxResults > 0 else { return nil }
        DocumentAdaptersBootstrap.registerBuiltIns()
        let extracted: ExtractedDocumentText
        do {
            extracted = try await DocumentTextExtractionCache.shared.units(for: url)
        } catch {
            skipped += 1
            return nil
        }
        var matches: [String] = []
        let displayPath = FolderToolHelpers.displayPath(for: url, under: rootPath)
        outer: for unit in extracted.units {
            for line in unit.text.components(separatedBy: .newlines)
            where line.localizedCaseInsensitiveContains(pattern) {
                matches.append("\(displayPath) [\(unit.locator)]: \(line.trimmingCharacters(in: .whitespaces))")
                if matches.count >= maxResults { break outer }
            }
        }
        return matches.isEmpty ? nil : matches
    }

    private func searchFile(
        _ url: URL, pattern: String, maxResults: Int, rootPath: URL
    ) -> [String]? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }

        let lines = FolderToolHelpers.contentLines(content)
        var matches: [String] = []
        var relativePath: String?

        for (index, line) in lines.enumerated() {
            guard matches.count < maxResults else { break }

            if line.localizedCaseInsensitiveContains(pattern) {
                let lineNum = index + 1
                // Resolved on the first hit only; the fallback walks symlinks.
                let displayPath =
                    relativePath ?? FolderToolHelpers.displayPath(for: url, under: rootPath)
                relativePath = displayPath
                matches.append("\(displayPath):\(lineNum): \(line.trimmingCharacters(in: .whitespaces))")
            }
        }

        return matches.isEmpty ? nil : matches
    }
}

// MARK: Shell Run Tool

struct ShellRunTool: OsaurusTool, PermissionedTool {
    let name = "shell_run"
    let description =
        "Run a shell command in the working directory. **Reserve this for builds, tests, "
        + "git, processes, network calls, and filesystem mutations (`mv`/`cp`/`rm`/`mkdir`).** "
        + "For file IO, search, edit, write, and directory listing, prefer the dedicated "
        + "`file_*` tools — each one's description states the `shell_run` pattern it "
        + "replaces. This action requires approval. Long-running commands stream their "
        + "output live to the chat — the user sees it as it happens and can press [Terminate] "
        + "at any time. Final stdout truncated to 10,000 characters. No built-in timeout: "
        + "pass `timeout: <seconds>` ONLY if you want a hard idle ceiling (kill the process "
        + "if no output for N seconds). Avoid `2>/dev/null` in pipelines — pipefail is on "
        + "and suppressing stderr will trigger an empty-output warning."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "command": .object([
                "type": .string("string"),
                "description": .string("The shell command to execute"),
            ]),
            "timeout": .object([
                "type": .string("integer"),
                "description": .string(
                    "Optional idle timeout in seconds. Kills the process if it produces no "
                        + "output for this many seconds. Omit to run to completion (the user "
                        + "terminates from the chat card if needed)."
                ),
            ]),
        ]),
        "required": .array([.string("command")]),
    ])

    var requirements: [String] { ["permission:shell"] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .ask }
    var mutatesHostFolder: Bool { true }

    /// Opaque (full before/after scan); when the folder is too large to
    /// scan, a simple `mv`/`cp`/`rm`/`mkdir` still names its paths.
    func fallbackMutationTargets(argumentsJSON: String) -> [String]? {
        guard let command = FileChangeCapture.declaredPaths(argumentsJSON, keys: ["command"])?.first,
            let root = ChatExecutionContext.currentFolderRoot
        else { return nil }
        return ShellMutationPlanner.targets(command: command, rootPath: root)
    }

    /// Streaming exec opts out of the registry's wall-clock cap. Long
    /// commands rely on the user's [Terminate] button + the optional
    /// `timeout` (idle ceiling) as the safety net.
    var bypassRegistryTimeout: Bool { true }

    private let fixedRootPath: URL?

    init(rootPath: URL? = nil) {
        self.fixedRootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let rootPath = try FolderToolHelpers.requireRoot(fixed: fixedRootPath)
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let cmdReq = requireString(
            args,
            "command",
            expected: "shell command string (e.g. `ls -la`)",
            tool: name
        )
        guard case .value(let command) = cmdReq else {
            return cmdReq.failureEnvelope ?? ""
        }

        // Optional idle ceiling; nil = run forever (user terminates).
        let idleTimeout: TimeInterval? = coerceInt(args["timeout"]).map(TimeInterval.init)

        // `set -o pipefail` wrapping so a real upstream pipeline
        // failure surfaces as the rightmost non-zero exit instead of
        // being masked by `head` / `tee` / `cat`. zsh honours pipefail
        // identically to bash.
        let prefixedCommand = "set -o pipefail; \(command)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", prefixedCommand]
        process.currentDirectoryURL = rootPath

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        // Live streaming wiring: incrementally read from both pipes,
        // appending to a per-stream buffer (for the model's final
        // result) AND broadcasting to a LiveExecSink (for the chat UI).
        // `lastActivity` powers the optional idle-timeout watchdog.
        let collector = ShellRunOutputCollector()
        let sink = LiveExecSink()

        installPipeReader(
            pipe: stdoutPipe,
            collector: collector,
            isStderr: false,
            sink: sink
        )
        installPipeReader(
            pipe: stderrPipe,
            collector: collector,
            isStderr: true,
            sink: sink
        )

        // Register the live entry BEFORE starting the process so the
        // chat card can mount its viewer immediately.
        let toolCallId = ChatExecutionContext.currentToolCallId ?? UUID().uuidString
        let processBox = ShellRunProcessBox(process: process)
        let terminate: @Sendable (Int) async -> Void = { graceSeconds in
            sink.requestTerminate()
            await processBox.terminateWithGrace(graceSeconds: graceSeconds)
        }

        await LiveExecRegistry.shared.register(
            LiveExecRegistry.Entry(
                toolCallId: toolCallId,
                pid: "",
                command: command,
                startedAt: Date(),
                outputPublisher: sink.outputPublisher,
                statusPublisher: sink.statusPublisher,
                currentStatus: { sink.currentStatus },
                seed: { await sink.bufferedSnapshot() },
                terminate: terminate
            )
        )

        // Idle-timeout watchdog. Only runs when `idleTimeout` is set;
        // resets implicitly on every chunk via `collector.lastActivity`.
        let idleWatcher: Task<Void, Never>?
        if let idleTimeout {
            idleWatcher = Task.detached { @Sendable in
                let pollNanos: UInt64 = 1_000_000_000
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: pollNanos)
                    if Task.isCancelled { return }
                    let last = collector.lastActivity
                    if Date().timeIntervalSince(last) >= idleTimeout {
                        await processBox.terminate()
                        return
                    }
                }
            }
        } else {
            idleWatcher = nil
        }

        defer {
            idleWatcher?.cancel()
        }

        do {
            try await FolderToolHelpers.runProcessAsync(process)
        } catch {
            sink.markExited(code: -1)
            await LiveExecRegistry.shared.unregister(toolCallId: toolCallId)
            throw FolderToolError.operationFailed("Failed to execute command: \(error)")
        }

        // Drain anything buffered in the pipes after exit (the
        // readabilityHandlers stop firing once the process closes its
        // end). `availableData` returns the residual bytes.
        collector.appendDrain(
            stdoutData: stdoutPipe.fileHandleForReading.availableData,
            stderrData: stderrPipe.fileHandleForReading.availableData,
            sink: sink
        )

        // Stop the readabilityHandlers — Foundation leaves them wired
        // even after the process exits, which keeps the FileHandle
        // alive.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil

        let exitCode = process.terminationStatus
        sink.markExited(code: exitCode)
        await LiveExecRegistry.shared.unregister(toolCallId: toolCallId)

        let (stdoutText, stderrText) = collector.snapshot()
        let trimmedStdout = stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedStderr = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)

        var payload: [String: Any] = [
            "stdout": truncateOutput(trimmedStdout),
            "stderr": truncateOutput(trimmedStderr),
            "exit_code": Int(exitCode),
        ]
        if sink.terminationReason == .user {
            payload["killed_by"] = "user"
        }
        let warnings = diagnosticWarnings(
            command: command,
            exitCode: exitCode,
            stdout: trimmedStdout,
            stderr: trimmedStderr
        )
        return ToolEnvelope.success(
            tool: name,
            result: FolderToolHelpers.withOperationId(payload),
            warnings: warnings.isEmpty ? nil : warnings
        )
    }

    /// Install a `readabilityHandler` that streams every chunk into
    /// the collector AND the sink. Closes both sides cleanly on EOF
    /// so the FileHandle isn't leaked.
    ///
    /// Both sinks here are non-blocking and synchronous: `sink.write`
    /// just hits a PassthroughSubject; `collector.append` is a single
    /// lock-guarded Data append. We deliberately AVOID `Task { … }`
    /// per chunk — on a chatty pipe that fires the handler thousands
    /// of times a second the per-Task overhead dominates the actual
    /// work, swamping the cooperative thread pool and starving the
    /// process drain that actually frees the pipe.
    private func installPipeReader(
        pipe: Pipe,
        collector: ShellRunOutputCollector,
        isStderr: Bool,
        sink: LiveExecSink
    ) {
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            try? sink.write(chunk)
            collector.append(chunk, isStderr: isStderr)
        }
    }

    private func truncateOutput(_ output: String, maxLength: Int = 10000) -> String {
        if output.count > maxLength {
            return String(output.prefix(maxLength)) + "\n... (truncated)"
        }
        return output
    }
}

/// Per-call output collector for `ShellRunTool`. Splits the streaming
/// chunks back into stdout / stderr (the underlying `Pipe`s feed two
/// separate `readabilityHandler`s on Foundation's IO queue).
///
/// Was an `actor` originally, which serialised updates cleanly but
/// forced every `installPipeReader` callback to spawn a `Task` per
/// chunk. On a chatty pipe (think `cargo build` or `npm install`)
/// that's hundreds of Tasks per second — enough to swamp the
/// cooperative thread pool and starve the process drain. A plain
/// `NSLock` guards the same data with no scheduling overhead, and
/// every callsite is already short and non-blocking.
final class ShellRunOutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdoutBuf = Data()
    private var stderrBuf = Data()
    private var _lastActivity = Date()

    var lastActivity: Date {
        lock.withLock { _lastActivity }
    }

    func append(_ chunk: Data, isStderr: Bool) {
        lock.withLock {
            if isStderr {
                stderrBuf.append(chunk)
            } else {
                stdoutBuf.append(chunk)
            }
            _lastActivity = Date()
        }
    }

    /// Append the residual bytes drained from the pipes after process
    /// exit, also pushing them through the live sink so the chat card
    /// sees the final flush. `availableData` may return empty data on
    /// each pipe; we no-op in that case.
    func appendDrain(stdoutData: Data, stderrData: Data, sink: LiveExecSink) {
        lock.withLock {
            if !stdoutData.isEmpty {
                stdoutBuf.append(stdoutData)
                try? sink.write(stdoutData)
            }
            if !stderrData.isEmpty {
                stderrBuf.append(stderrData)
                try? sink.write(stderrData)
            }
        }
    }

    func snapshot() -> (stdout: String, stderr: String) {
        lock.withLock {
            (
                String(data: stdoutBuf, encoding: .utf8) ?? "",
                String(data: stderrBuf, encoding: .utf8) ?? ""
            )
        }
    }
}

/// Lightweight Sendable wrapper around the host `Process` so the
/// terminate closure (which crosses task boundaries) can signal it
/// without tripping strict-concurrency on `Process` itself.
private actor ShellRunProcessBox {
    private let process: Process

    init(process: Process) {
        self.process = process
    }

    /// Send SIGTERM only — used by the idle-timeout watchdog where the
    /// "graceful then kill" escalation is overkill.
    func terminate() {
        guard process.isRunning else { return }
        process.terminate()  // SIGTERM
    }

    /// SIGTERM → grace → SIGKILL. Mirrors `ProcessHandleBox` for
    /// `sandbox_exec` so terminate-from-the-chat-card behaves the
    /// same across both tools.
    func terminateWithGrace(graceSeconds: Int) async {
        guard process.isRunning else { return }
        process.terminate()  // SIGTERM
        if graceSeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(graceSeconds) * 1_000_000_000)
        }
        guard process.isRunning else { return }
        // Foundation has no SIGKILL helper; fall back to the POSIX
        // syscall via the process identifier.
        Darwin.kill(process.processIdentifier, SIGKILL)
    }
}

// MARK: - Git Tools

// MARK: Git Status Tool

struct GitStatusTool: OsaurusTool {
    let name = "git_status"
    let description = "Show the current git status including branch name and uncommitted changes."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([:]),
        "required": .array([]),
    ])

    private let fixedRootPath: URL?

    init(rootPath: URL? = nil) {
        self.fixedRootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let rootPath = try FolderToolHelpers.requireRoot(fixed: fixedRootPath)
        let (output, exitCode) = try await FolderToolHelpers.runGitCommand(
            arguments: ["status"],
            in: rootPath
        )

        if exitCode != 0 {
            throw FolderToolError.operationFailed("git status failed: \(output)")
        }

        return ToolEnvelope.success(
            tool: name,
            text: output.isEmpty ? "No changes" : output
        )
    }
}

// MARK: Git Diff Tool

struct GitDiffTool: OsaurusTool {
    let name = "git_diff"
    let description =
        "Show git diff for files. Can show staged changes, unstaged changes, or diff between commits."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Optional file path to diff (default: all files)"),
            ]),
            "staged": .object([
                "type": .string("boolean"),
                "description": .string("Show staged changes only (default: false)"),
            ]),
            "commit": .object([
                "type": .string("string"),
                "description": .string("Optional commit hash or range to diff against"),
            ]),
        ]),
        "required": .array([]),
    ])

    private let fixedRootPath: URL?

    init(rootPath: URL? = nil) {
        self.fixedRootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let rootPath = try FolderToolHelpers.requireRoot(fixed: fixedRootPath)
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        // All three are optional; the preflight already drops empty-string
        // fillers (`path: ""`, `commit: ""`) so a plain `as? String` cleanly
        // yields nil when the model didn't intend to specify them.
        let filePath = args["path"] as? String
        let staged = coerceBool(args["staged"]) ?? false
        let commit = args["commit"] as? String

        // Validate `path` through the same resolver every other folder
        // tool uses. Previously the path went straight to `git diff --`,
        // which silently accepted absolute paths and `..`-style traversal.
        // The resolver throws `FolderToolError.invalidArguments` /
        // `pathOutsideRoot` so the model gets the standard message on a
        // bad path.
        if let filePath {
            _ = try FolderToolHelpers.resolvePath(filePath, rootPath: rootPath)
        }

        var arguments = ["diff"]
        if staged { arguments.append("--cached") }
        if let commit = commit {
            // A leading dash would be parsed as an option, and `git diff
            // --output=<file>` writes anywhere on disk without approval.
            guard !commit.hasPrefix("-") else {
                throw FolderToolError.invalidArguments(
                    "commit must be a commit hash or range such as 'HEAD~1..HEAD' (got '\(commit)')."
                )
            }
            arguments.append(commit)
        }
        if let filePath = filePath { arguments.append(contentsOf: ["--", filePath]) }

        let (output, exitCode) = try await FolderToolHelpers.runGitCommand(
            arguments: arguments,
            in: rootPath
        )

        if exitCode != 0 {
            throw FolderToolError.operationFailed("git diff failed: \(output)")
        }

        // Truncate if too long
        let text: String
        if output.count > 20000 {
            text = String(output.prefix(20000)) + "\n... (diff truncated)"
        } else {
            text = output.isEmpty ? "No differences" : output
        }
        return ToolEnvelope.success(tool: name, text: text)
    }
}

// MARK: Git Commit Tool

struct GitCommitTool: OsaurusTool, PermissionedTool {
    let name = "git_commit"
    let description =
        "Stage and commit changes to git. This action requires approval. Optionally specify files to stage, otherwise runs `git add -A` to stage all tracked and untracked changes."
    let parameters: JSONValue? = .object([
        "type": .string("object"),
        "additionalProperties": .bool(false),
        "properties": .object([
            "message": .object([
                "type": .string("string"),
                "description": .string("Commit message"),
            ]),
            "files": .object([
                "type": .string("array"),
                "items": .object([
                    "type": .string("string")
                ]),
                "description": .string(
                    "Optional array of file paths to stage (default: all changes)"
                ),
            ]),
        ]),
        "required": .array([.string("message")]),
    ])

    var requirements: [String] { ["permission:git"] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .ask }

    private let fixedRootPath: URL?

    init(rootPath: URL? = nil) {
        self.fixedRootPath = rootPath
    }

    func execute(argumentsJSON: String) async throws -> String {
        let rootPath = try FolderToolHelpers.requireRoot(fixed: fixedRootPath)
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }

        let messageReq = requireString(
            args,
            "message",
            expected: "non-empty commit message",
            tool: name
        )
        guard case .value(let message) = messageReq else {
            return messageReq.failureEnvelope ?? ""
        }

        let files = coerceStringArray(args["files"])

        // Validate every staged path through the resolver — same security
        // boundary as the rest of the folder tools. `git add` would
        // otherwise silently accept absolutes / traversal.
        if let files {
            for file in files {
                _ = try FolderToolHelpers.resolvePath(file, rootPath: rootPath)
            }
        }

        // Stage files
        let stageArgs = (files != nil && !files!.isEmpty) ? ["add", "--"] + files! : ["add", "-A"]
        let (stageOutput, stageExitCode) = try await FolderToolHelpers.runGitCommand(
            arguments: stageArgs,
            in: rootPath
        )

        if stageExitCode != 0 {
            throw FolderToolError.operationFailed("git add failed: \(stageOutput)")
        }

        // Commit
        let (commitOutput, commitExitCode) = try await FolderToolHelpers.runGitCommand(
            arguments: ["commit", "-m", message],
            in: rootPath
        )

        if commitExitCode != 0 {
            if commitOutput.contains("nothing to commit") {
                return ToolEnvelope.success(tool: name, text: "Nothing to commit")
            }
            throw FolderToolError.operationFailed("git commit failed: \(commitOutput)")
        }

        return ToolEnvelope.success(
            tool: name,
            text: "Committed successfully:\n\(commitOutput)"
        )
    }
}

// MARK: - Tool Factory

/// Factory for creating folder tool instances
enum FolderToolFactory {
    /// Build all core file tools. `share_artifact` is NOT here — it's a
    /// global built-in (registered in `ToolRegistry.registerBuiltInTools`)
    /// so it works in plain chat / folder / sandbox alike.
    ///
    /// Lean by design: filesystem mutations (`mv`, `cp`, `rm`, `mkdir`)
    /// go through `shell_run` rather than discrete `file_move` /
    /// `file_delete` / `dir_create` tools so the model
    /// picks "shell command" once instead of differentiating four
    /// near-identical tool names. `shell_run` is loaded on every folder
    /// mount (not gated on a detected project type) so the prompt's
    /// "use `shell_run` for `mv`/`cp`/`rm`/`mkdir`" advice always
    /// matches the schema. Multi-step orchestration goes through
    /// `shell_run` chains or — when the chat is sandbox-mode —
    /// `sandbox_execute_code`.
    static func buildCoreTools(rootPath: URL? = nil) -> [OsaurusTool] {
        return [
            FileTreeTool(rootPath: rootPath),
            FileReadTool(rootPath: rootPath),
            FileWriteTool(rootPath: rootPath),
            FileEditTool(rootPath: rootPath),
            FileOperationHistoryTool(rootPath: rootPath),
            FileUndoTool(rootPath: rootPath),
            FileCopyTool(rootPath: rootPath),
            FileSearchTool(rootPath: rootPath),
            ShellRunTool(rootPath: rootPath),
        ]
    }

    /// Build git tools. Installed when the working folder is a git repo.
    static func buildGitTools(rootPath: URL? = nil) -> [OsaurusTool] {
        return [
            GitStatusTool(rootPath: rootPath),
            GitDiffTool(rootPath: rootPath),
            GitCommitTool(rootPath: rootPath),
        ]
    }
    // Note: no `allToolNames` helper — the live tool list is the source of
    // truth (via `FolderToolManager.folderToolNames`). A hand-maintained
    // mirror would silently go stale every time a tool is added, renamed,
    // or moved between Core/Git groups.
}

// MARK: - String Extension

extension String {
    func ranges(of searchString: String) -> [Range<String.Index>] {
        var ranges: [Range<String.Index>] = []
        var start = self.startIndex
        while start < self.endIndex, let range = self.range(of: searchString, range: start ..< self.endIndex) {
            ranges.append(range)
            start = range.upperBound
        }
        return ranges
    }
}
