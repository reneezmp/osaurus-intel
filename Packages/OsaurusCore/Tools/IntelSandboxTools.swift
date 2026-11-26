//
//  IntelSandboxTools.swift
//  osaurus
//
//  Intel fork: the host-capable part of upstream Classic's
//  `Tools/BuiltinSandboxTools.swift` (W-seatbelt-sandbox stage 3).
//  Upstream's file is the VM stack (Containerization `Writer`, VirtioFS
//  share, apk, background jobs) and stays excluded. This file keeps its
//  tool vocabulary and envelopes for the pieces that make sense when
//  commands run on the Mac under Seatbelt:
//
//    sandbox_read_file, sandbox_search_files, sandbox_write_file,
//    sandbox_exec (foreground)
//
//  (`sandbox_secret_check` / `sandbox_secret_set` are in
//  IntelSandboxSecretTools.swift.) Background jobs, `sandbox_process`,
//  `sandbox_install` and sandbox plugins are stage 4.
//
//  Owner policy (docs/W_SEATBELT_SANDBOX_PLAN.md): the sandbox only ever
//  restricts. Every tool resolves the calling agent from the request's
//  `ChatExecutionContext.currentAgentId` and refuses unless that agent
//  explicitly opted in (`AutonomousExecConfig.enabled`). Every file
//  operation runs as a confined command (`SandboxManager.execAsAgent`), so
//  a symlink planted in the workspace cannot make the app itself read or
//  write outside it. Network is off unless the agent's own switch is on.
//  Upstream names `/workspace/...` paths; they map to the host workspace
//  through `SeatbeltPathMapper`.
//

import Foundation

// MARK: - Names, registration

enum BuiltinSandboxTools {
    static let readFile = "sandbox_read_file"
    static let searchFiles = "sandbox_search_files"
    static let writeFile = "sandbox_write_file"
    static let exec = "sandbox_exec"
    static let secretCheck = "sandbox_secret_check"
    static let secretSet = "sandbox_secret_set"

    /// Every tool this stage can register. `ToolRegistry.isSandboxTool` and
    /// the opt-in gates key off this fixed set.
    static let allToolNames: Set<String> = [
        readFile, searchFiles, writeFile, exec, secretCheck, secretSet,
    ]

    /// Register the process-wide tools (idempotent). Identity and settings
    /// are resolved from the request at execution time, so one instance
    /// serves every opted-in agent; the registry hides the tools from every
    /// agent that has not opted in (`ToolRegistry.openAISpecs(for:)`) and
    /// refuses their execution (`runtimeCapabilityDenial`).
    @MainActor
    static func register() {
        let registry = ToolRegistry.shared
        guard registry.builtInSandboxToolNames.isEmpty else { return }
        let tools: [OsaurusTool] = [
            SandboxReadFileTool(),
            SandboxSearchFilesTool(),
            SandboxWriteFileTool(),
            SandboxExecTool(),
            SandboxSecretCheckTool(),
            // `sandbox_secret_set` stays unregistered: its prompt marker needs
            // the chat view to intercept it, and Intel's tool loop runs inside
            // `CloudChatEngine`, which does not (docs/W_SEATBELT_SANDBOX_PLAN.md).
        ]
        for tool in tools { registry.registerSandboxTool(tool) }
    }
}

// MARK: - Request context

/// Who is calling and what they may do, resolved from the request.
struct SandboxToolContext: Sendable {
    let agentId: UUID
    let agentName: String
    let home: String
    let config: AutonomousExecConfig

    /// Test seam: tests bind a context (and a temp-workspace manager) instead
    /// of creating agents in the shared stores.
    @TaskLocal static var testingContext: SandboxToolContext?
    @TaskLocal static var testingManager: SandboxManager?

    static var manager: SandboxManager { testingManager ?? SandboxManager.shared }

    /// The calling agent's context, or a ready-to-return refusal envelope.
    static func resolve(tool: String) async -> Result<SandboxToolContext, SandboxToolRefusal> {
        if let testing = testingContext { return .success(testing) }
        guard let agentId = ChatExecutionContext.currentAgentId else {
            return .failure(
                SandboxToolRefusal(
                    envelope: ToolEnvelope.failure(
                        kind: .unavailable,
                        message: "The sandbox needs an agent: no agent is bound to this request.",
                        tool: tool,
                        retryable: false
                    )))
        }
        guard let config = SandboxToolGate.config(for: agentId) else {
            return .failure(
                SandboxToolRefusal(
                    envelope: ToolEnvelope.failure(
                        kind: .unavailable,
                        message:
                            "The sandbox is off for this agent. The user can turn it on in the agent's settings.",
                        tool: tool,
                        retryable: false
                    )))
        }
        let name = SandboxToolRegistrar.hostAgentName(for: agentId.uuidString)
        return .success(
            SandboxToolContext(
                agentId: agentId,
                agentName: name,
                home: OsaurusPaths.inContainerAgentHome(name),
                config: config
            ))
    }

    /// Start the backend and create the agent's home on first use.
    func ensureReady(tool: String) async -> String? {
        do {
            try await Self.manager.startContainer()
            try await Self.manager.ensureAgentUser(agentName)
            let running = await Self.manager.status().isRunning
            if !running {
                return ToolEnvelope.failure(
                    kind: .unavailable,
                    message:
                        "The sandbox is not running. Open the Sandbox page to start it again, then retry.",
                    tool: tool,
                    retryable: false
                )
            }
            return nil
        } catch {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message: "The sandbox could not start: \(error.localizedDescription)",
                tool: tool,
                retryable: true
            )
        }
    }

    /// Run a confined command as this agent. The calling agent's own network
    /// switch decides network access (default off).
    func run(
        _ command: String,
        cwd: String? = nil,
        timeout: TimeInterval? = 60,
        extraEnv: [String: String] = [:],
        onProcessStarted: (@Sendable (ProcessHandle) -> Void)? = nil
    ) async throws -> ContainerExecResult {
        try await Self.manager.exec(
            user: "agent-\(agentName)",
            command: command,
            env: extraEnv,
            cwd: cwd ?? home,
            timeout: timeout,
            networkEnabled: config.sandboxNetworkEnabled,
            onProcessStarted: onProcessStarted
        )
    }
}

struct SandboxToolRefusal: Error, Sendable {
    let envelope: String
}

// MARK: - Shared helpers

private func sandboxSuccess(tool: String, result: Any? = nil, warnings: [String]? = nil) -> String {
    ToolEnvelope.success(tool: tool, result: result, warnings: warnings)
}

private func sandboxExecutionFailure(tool: String, message: String, retryable: Bool = true) -> String {
    ToolEnvelope.failure(kind: .executionError, message: message, tool: tool, retryable: retryable)
}

/// Escape for interpolation inside a single-quoted shell argument.
internal func sandboxShellEscape(_ s: String) -> String {
    s.replacingOccurrences(of: "'", with: "'\\''")
}

/// Validate a path argument against the agent home and `/workspace/shared`.
/// Stricter than `SandboxPathSanitizer.validate` on one point: an absolute
/// path must be the home / shared folder itself or inside it (a bare
/// `hasPrefix(home)` would also admit a sibling agent's `<home>-two`).
internal func requireSandboxPath(
    _ path: String,
    home: String,
    field: String = "path",
    tool: String
) -> ArgumentRequirement<String> {
    func fail(_ reason: String) -> ArgumentRequirement<String> {
        .failure(
            ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Argument `\(field)` rejected: \(reason). Got `\(path)`.",
                field: field,
                expected: "path under the agent home (relative or absolute under `\(home)`) or `/workspace/shared`",
                tool: tool
            ))
    }
    switch SandboxPathSanitizer.validate(path, agentHome: home) {
    case .failure(let rejection):
        return fail(rejection.reason)
    case .success(let resolved):
        if path.hasPrefix("/") {
            let roots = [home, "/workspace/shared"]
            let inside = roots.contains { resolved == $0 || resolved.hasPrefix($0 + "/") }
            guard inside else { return fail(SandboxPathRejection.outsideAllowedRoots.reason) }
        }
        return .value(resolved)
    }
}

/// Cap a stream before it lands in model context (head 40% / tail 60%).
internal func sandboxTruncate(_ text: String, maxChars: Int = ToolOutputCaps.execStdout) -> String {
    HeadTailTruncation.apply(text, cap: maxChars, headFraction: 0.4)
}

/// Kill handle for a running confined process, usable before the process
/// exists (a cancel that races the launch still kills it once it starts).
final class SandboxProcessKill: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: ProcessHandle?
    private var cancelled = false
    private(set) var terminatedByCancel = false

    func set(_ new: ProcessHandle) {
        lock.lock()
        handle = new
        let shouldKill = cancelled
        lock.unlock()
        if shouldKill { terminate(handle: new) }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        terminatedByCancel = true
        let current = handle
        lock.unlock()
        if let current { terminate(handle: current) }
    }

    private func terminate(handle: ProcessHandle) {
        Task {
            try? await handle.kill(SIGTERM)
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            try? await handle.kill(SIGKILL)
        }
    }
}

// MARK: - sandbox_read_file

struct SandboxReadFileTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    let name = BuiltinSandboxTools.readFile
    let description =
        "Read a file's contents from the sandbox. **Use this instead of `cat`/`head`/`tail` in `sandbox_exec`.** "
        + "Text is returned raw. Supports line ranges (`start_line` + `line_count`), log-style tails "
        + "(`tail_lines`), and a per-call character cap (`max_chars`). Pass either a path under the agent home "
        + "(e.g. `notes.txt`) or an absolute path inside the sandbox (e.g. `/workspace/shared/data.csv`). "
        + "Surfaces stderr on failure."

    var requirements: [String] { [] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .auto }

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string(
                        "File path, relative to the agent home or absolute under your home / `/workspace/shared`."
                    ),
                ]),
                "start_line": .object([
                    "type": .string("integer"),
                    "description": .string("1-based starting line to read"),
                ]),
                "line_count": .object([
                    "type": .string("integer"),
                    "description": .string("Number of lines to read from start_line"),
                ]),
                "tail_lines": .object([
                    "type": .string("integer"),
                    "description": .string("Read the last N lines, useful for logs"),
                ]),
                "max_chars": .object([
                    "type": .string("integer"),
                    "description": .string(
                        "Cap returned characters after line selection (default \(ToolOutputCaps.fileRead))"
                    ),
                ]),
            ]),
            "required": .array([.string("path")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let context: SandboxToolContext
        switch await SandboxToolContext.resolve(tool: name) {
        case .failure(let refusal): return refusal.envelope
        case .success(let value): context = value
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let pathReq = requireString(
            args, "path", expected: "file path under the agent home or `/workspace/shared`", tool: name)
        guard case .value(let path) = pathReq else { return pathReq.failureEnvelope ?? "" }
        let resolvedReq = requireSandboxPath(path, home: context.home, tool: name)
        guard case .value(let resolved) = resolvedReq else { return resolvedReq.failureEnvelope ?? "" }
        if let notReady = await context.ensureReady(tool: name) { return notReady }

        let startLine = max(coerceInt(args["start_line"]) ?? 0, 0)
        let lineCount = max(coerceInt(args["line_count"]) ?? 0, 0)
        let tailLines = max(coerceInt(args["tail_lines"]) ?? 0, 0)
        let maxChars = coerceInt(args["max_chars"]).map { max($0, 0) } ?? ToolOutputCaps.fileRead

        let command: String
        if tailLines > 0 {
            command =
                maxChars > 0
                ? "tail -n \(tailLines) '\(resolved)' | head -c \(maxChars)"
                : "tail -n \(tailLines) '\(resolved)'"
        } else if startLine > 0 {
            let endLine = startLine + max(lineCount, 1) - 1
            command =
                maxChars > 0
                ? "sed -n '\(startLine),\(endLine)p' '\(resolved)' | head -c \(maxChars)"
                : "sed -n '\(startLine),\(endLine)p' '\(resolved)'"
        } else {
            command = maxChars > 0 ? "head -c \(maxChars) '\(resolved)'" : "cat '\(resolved)'"
        }

        let result: ContainerExecResult
        do { result = try await context.run(command) } catch {
            return sandboxExecutionFailure(tool: name, message: "Read failed: \(error.localizedDescription)")
        }
        guard result.succeeded else {
            let stderr = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            var message = "Failed to read `\(resolved)`: \(stderr.isEmpty ? "exit code \(result.exitCode)" : stderr)"
            if stderr.lowercased().contains("is a directory") {
                message += " That path is a directory: list it with `sandbox_search_files` (`target=\"files\"`)."
            }
            return sandboxExecutionFailure(tool: name, message: message, retryable: false)
        }
        var payload: [String: Any] = [
            "kind": "file",
            "path": resolved,
            "content": result.stdout,
            "size": result.stdout.count,
        ]
        if startLine > 0 {
            payload["start_line"] = startLine
            payload["line_count"] = max(lineCount, 1)
        }
        if tailLines > 0 { payload["tail_lines"] = tailLines }
        if maxChars > 0 { payload["max_chars"] = maxChars }
        if maxChars > 0, result.stdout.count >= maxChars {
            payload["truncated"] = true
            return sandboxSuccess(
                tool: name,
                result: payload,
                warnings: [
                    "Content truncated at \(maxChars) chars. Read the rest with `start_line`/`line_count`, `tail_lines`, or a larger `max_chars`."
                ]
            )
        }
        return sandboxSuccess(tool: name, result: payload)
    }
}

// MARK: - sandbox_search_files

struct SandboxSearchFilesTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    let name = BuiltinSandboxTools.searchFiles
    let description =
        "Search file contents OR find files by name. **Use this instead of `grep`/`find`/`ls` in "
        + "`sandbox_exec`.** Pass `target=\"content\"` (default) for a regex search inside file bodies "
        + "(extended regex), or `target=\"files\"` to find files by name (case-insensitive substring, e.g. "
        + "`q4`; use `*`/`?` for a glob like `*.py`). Cap output with `max_results` (default 100, max 500). "
        + "Returns `{matches: \"...\"}` for both targets."

    var requirements: [String] { [] }
    var defaultPermissionPolicy: ToolPermissionPolicy { .auto }

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "pattern": .object([
                    "type": .string("string"),
                    "description": .string(
                        "When `target=\"content\"`: extended regex (e.g. `TODO|FIXME`). "
                            + "When `target=\"files\"`: filename to find (case-insensitive substring, "
                            + "e.g. `q4`; use `*`/`?` for a glob like `*.py`)."
                    ),
                ]),
                "target": .object([
                    "type": .string("string"),
                    "enum": .array([.string("content"), .string("files")]),
                    "description": .string(
                        "`content` searches inside file bodies; `files` finds files by name. Default: `content`."
                    ),
                    "default": .string("content"),
                ]),
                "path": .object([
                    "type": .string("string"),
                    "description": .string("Directory to search (default: agent home)"),
                    "default": .string("."),
                ]),
                "include": .object([
                    "type": .string("string"),
                    "description": .string(
                        "File glob filter for content searches (e.g. `*.py`). Ignored when `target=\"files\"`."
                    ),
                ]),
                "context_lines": .object([
                    "type": .string("integer"),
                    "description": .string("Lines of context before/after each match (max 10). Content target only."),
                ]),
                "case_insensitive": .object([
                    "type": .string("boolean"),
                    "description": .string("Enable case-insensitive search. Content target only."),
                    "default": .bool(false),
                ]),
                "max_results": .object([
                    "type": .string("integer"),
                    "description": .string("Maximum lines of output (default 100, max 500)."),
                    "default": .number(100),
                ]),
            ]),
            "required": .array([.string("pattern")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let context: SandboxToolContext
        switch await SandboxToolContext.resolve(tool: name) {
        case .failure(let refusal): return refusal.envelope
        case .success(let value): context = value
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let target = (args["target"] as? String)?.lowercased() ?? "content"
        let patternReq = requireString(
            args, "pattern",
            expected: target == "files" ? "filename glob (e.g. `*.py`)" : "extended regex (e.g. `TODO|FIXME`)",
            tool: name)
        guard case .value(let pattern) = patternReq else { return patternReq.failureEnvelope ?? "" }
        let resolvedReq = requireSandboxPath((args["path"] as? String) ?? ".", home: context.home, tool: name)
        guard case .value(let resolved) = resolvedReq else { return resolvedReq.failureEnvelope ?? "" }
        let cappedMax = max(1, min(coerceInt(args["max_results"]) ?? 100, ToolOutputCaps.searchMaxResults))
        if let notReady = await context.ensureReady(tool: name) { return notReady }

        let command: String
        switch target {
        case "files":
            let namePattern =
                FolderToolHelpers.patternHasGlobMetacharacters(pattern) ? pattern : "*\(pattern)*"
            let predicate = pattern.contains("/") ? "-ipath" : "-iname"
            command =
                "find '\(resolved)' -type f \(predicate) '\(sandboxShellEscape(namePattern))' 2>/dev/null | head -\(cappedMax)"
        case "content":
            // BSD `grep` stands in for upstream's `rg` (not part of macOS).
            var cmd = "grep -rnEI"
            if coerceBool(args["case_insensitive"]) == true { cmd += " -i" }
            if let n = coerceInt(args["context_lines"]), n > 0 { cmd += " -C \(min(n, 10))" }
            if let include = args["include"] as? String, !include.isEmpty {
                cmd += " --include='\(sandboxShellEscape(include))'"
            }
            cmd += " -e '\(sandboxShellEscape(pattern))' '\(resolved)' 2>/dev/null | head -\(cappedMax)"
            command = cmd
        default:
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Unsupported `target`: `\(target)`. Use `content` or `files`.",
                field: "target",
                expected: "one of `content`, `files`",
                tool: name
            )
        }
        let result: ContainerExecResult
        do { result = try await context.run(command) } catch {
            return sandboxExecutionFailure(tool: name, message: "Search failed: \(error.localizedDescription)")
        }
        let lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: true).count
        var payload: [String: Any] = [
            "pattern": pattern, "target": target, "path": resolved, "matches": result.stdout,
        ]
        var warnings: [String] = []
        if lines >= cappedMax {
            payload["truncated"] = true
            warnings.append(
                "Results truncated at \(cappedMax) lines — more matches exist. Narrow with a more specific `pattern` or a deeper `path`."
            )
        }
        return sandboxSuccess(tool: name, result: payload, warnings: warnings.isEmpty ? nil : warnings)
    }
}

// MARK: - sandbox_write_file

struct SandboxWriteFileTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    let name = BuiltinSandboxTools.writeFile
    let description =
        "Write a file, or edit it in place — always pass `path` as the FIRST argument. Provide `content` to "
        + "write/replace the whole file (`mode: \"append\"` adds to the end); provide `old_string` (+`new_string`) "
        + "to replace one match, or `edits` (array of {old_string, new_string}) to apply several replacements "
        + "atomically. **Use this instead of `echo`/heredoc/`sed` in `sandbox_exec`.** Creates parent "
        + "directories. An edit fails if `old_string` is missing or matches several places (pass "
        + "`replace_all: true` to change every occurrence). Text files only (UTF-8)."

    var requirements: [String] { [] }
    /// Writes change files, so the user is asked unless they set Auto.
    var defaultPermissionPolicy: ToolPermissionPolicy { .ask }
    var preservedEmptyStringArguments: Set<String> { ["content", "new_string"] }

    /// Largest single payload sent per confined command (base64 characters).
    static let partChars = 180_000
    static let maxEditableBytes = 2_000_000
    static let maxBatchEdits = 50

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "path": .object([
                    "type": .string("string"),
                    "description": .string(
                        "File path, relative to the agent home or absolute under your home / `/workspace/shared`."
                    ),
                ]),
                "content": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Whole-file contents. Pass `\"\"` for an empty file. Omit when editing via `old_string`."),
                ]),
                "mode": .object([
                    "type": .string("string"),
                    "enum": .array([.string("overwrite"), .string("append")]),
                    "description": .string("Whole-file write mode (default: overwrite)."),
                ]),
                "old_string": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Exact text to find and replace. Present means an in-place edit instead of a whole-file write."
                    ),
                ]),
                "new_string": .object([
                    "type": .string("string"),
                    "description": .string("Replacement text for the `old_string` edit. Use `\"\"` to delete the match."),
                ]),
                "edits": .object([
                    "type": .string("array"),
                    "description": .string(
                        "Batch of {old_string, new_string} edits applied in order, atomically (max \(Self.maxBatchEdits))."
                    ),
                    "items": .object([
                        "type": .string("object"),
                        "properties": .object([
                            "old_string": .object(["type": .string("string")]),
                            "new_string": .object(["type": .string("string")]),
                        ]),
                        "required": .array([.string("old_string"), .string("new_string")]),
                    ]),
                ]),
                "replace_all": .object([
                    "type": .string("boolean"),
                    "description": .string("Edit only: replace every occurrence (default false)."),
                ]),
            ]),
            "required": .array([.string("path")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let context: SandboxToolContext
        switch await SandboxToolContext.resolve(tool: name) {
        case .failure(let refusal): return refusal.envelope
        case .success(let value): context = value
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(var args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        // An empty `edits` array next to `content` is a decoder artifact.
        if args["content"] != nil, let edits = args["edits"],
            edits is NSNull || (edits as? [Any])?.isEmpty == true
        {
            args.removeValue(forKey: "edits")
        }
        let pathReq = requireString(
            args, "path", expected: "file path under the agent home or `/workspace/shared`", tool: name)
        guard case .value(let path) = pathReq else { return pathReq.failureEnvelope ?? "" }
        let resolvedReq = requireSandboxPath(path, home: context.home, tool: name)
        guard case .value(let resolved) = resolvedReq else { return resolvedReq.failureEnvelope ?? "" }
        if let notReady = await context.ensureReady(tool: name) { return notReady }

        if args["old_string"] != nil || args["edits"] != nil {
            return await editInPlace(context: context, args: args, resolved: resolved)
        }
        guard args["content"] != nil else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "Provide `content` to write the whole file, or `old_string` (+`new_string`) / `edits` to edit in place.",
                field: "content",
                expected: "`content` or `old_string` + `new_string` / `edits`",
                tool: name
            )
        }
        let contentReq = requireString(
            args, "content", expected: "string of file contents (use `\"\"` for an empty file)", tool: name,
            allowEmpty: true)
        guard case .value(let content) = contentReq else { return contentReq.failureEnvelope ?? "" }
        let mode = (args["mode"] as? String) ?? "overwrite"
        guard mode == "overwrite" || mode == "append" else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "`mode` must be `overwrite` or `append`.", field: "mode",
                expected: "`overwrite` or `append`", tool: name)
        }
        do {
            try await writeFile(context: context, resolved: resolved, content: content, append: mode == "append")
        } catch let failure as SandboxToolRefusal {
            return failure.envelope
        } catch {
            return sandboxExecutionFailure(tool: name, message: "Write failed: \(error.localizedDescription)")
        }
        return sandboxSuccess(
            tool: name,
            result: [
                "kind": "sandbox_file", "path": resolved, "mode": mode, "bytes": content.utf8.count,
            ])
    }

    /// Write through a confined command. Content travels base64-encoded so
    /// quoting never alters it and `/workspace` inside the text is not
    /// rewritten by the path mapper.
    private func writeFile(
        context: SandboxToolContext, resolved: String, content: String, append: Bool
    ) async throws {
        let dir = (resolved as NSString).deletingLastPathComponent
        let mkdir = try await context.run("mkdir -p '\(dir)'")
        guard mkdir.succeeded else {
            throw SandboxToolRefusal(
                envelope: sandboxExecutionFailure(
                    tool: name,
                    message: "Could not create `\(dir)`: \(mkdir.stderr.trimmingCharacters(in: .whitespacesAndNewlines))",
                    retryable: false))
        }
        let encoded = Data(content.utf8).base64EncodedString()
        var parts: [String] = []
        var index = encoded.startIndex
        while index < encoded.endIndex {
            let end = encoded.index(index, offsetBy: Self.partChars, limitedBy: encoded.endIndex) ?? encoded.endIndex
            parts.append(String(encoded[index..<end]))
            index = end
        }
        if parts.isEmpty { parts = [""] }
        for (offset, part) in parts.enumerated() {
            let redirect = (append || offset > 0) ? ">>" : ">"
            let result = try await context.run("printf '%s' '\(part)' | base64 -D \(redirect) '\(resolved)'")
            guard result.succeeded else {
                throw SandboxToolRefusal(
                    envelope: sandboxExecutionFailure(
                        tool: name,
                        message:
                            "Failed to write `\(resolved)`: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))",
                        retryable: false))
            }
        }
    }

    private func editInPlace(
        context: SandboxToolContext, args: [String: Any], resolved: String
    ) async -> String {
        var edits: [(old: String, new: String)] = []
        if let batch = args["edits"] as? [[String: Any]] {
            guard !batch.isEmpty, batch.count <= Self.maxBatchEdits else {
                return ToolEnvelope.failure(
                    kind: .invalidArgs, message: "`edits` needs 1 to \(Self.maxBatchEdits) entries.", field: "edits",
                    expected: "array of {old_string, new_string}", tool: name)
            }
            for entry in batch {
                guard let old = entry["old_string"] as? String, !old.isEmpty,
                    let new = entry["new_string"] as? String
                else {
                    return ToolEnvelope.failure(
                        kind: .invalidArgs, message: "Each edit needs a non-empty `old_string` and a `new_string`.",
                        field: "edits", expected: "{old_string, new_string}", tool: name)
                }
                edits.append((old, new))
            }
        } else if let old = args["old_string"] as? String, !old.isEmpty, let new = args["new_string"] as? String {
            edits.append((old, new))
        } else {
            return ToolEnvelope.failure(
                kind: .invalidArgs, message: "An edit needs a non-empty `old_string` and a `new_string`.",
                field: "old_string", expected: "`old_string` + `new_string`", tool: name)
        }
        let replaceAll = coerceBool(args["replace_all"]) ?? false

        let read: ContainerExecResult
        do { read = try await context.run("head -c \(Self.maxEditableBytes + 1) '\(resolved)'") } catch {
            return sandboxExecutionFailure(tool: name, message: "Read failed: \(error.localizedDescription)")
        }
        guard read.succeeded else {
            return sandboxExecutionFailure(
                tool: name,
                message:
                    "Failed to read `\(resolved)` for editing: \(read.stderr.trimmingCharacters(in: .whitespacesAndNewlines))",
                retryable: false)
        }
        guard read.stdout.utf8.count <= Self.maxEditableBytes else {
            return sandboxExecutionFailure(
                tool: name, message: "`\(resolved)` is too large to edit in place; rewrite it with `content`.",
                retryable: false)
        }
        var text = read.stdout
        for (offset, edit) in edits.enumerated() {
            let count = text.components(separatedBy: edit.old).count - 1
            guard count > 0 else {
                return sandboxExecutionFailure(
                    tool: name,
                    message:
                        "Edit \(offset + 1): `old_string` was not found in `\(resolved)`. Nothing was changed; read the file and retry with exact text.",
                    retryable: false)
            }
            guard count == 1 || replaceAll else {
                return sandboxExecutionFailure(
                    tool: name,
                    message:
                        "Edit \(offset + 1): `old_string` matches \(count) places. Add surrounding context or pass `replace_all: true`. Nothing was changed.",
                    retryable: false)
            }
            text = text.replacingOccurrences(of: edit.old, with: edit.new)
        }
        do {
            try await writeFile(context: context, resolved: resolved, content: text, append: false)
        } catch let failure as SandboxToolRefusal {
            return failure.envelope
        } catch {
            return sandboxExecutionFailure(tool: name, message: "Write failed: \(error.localizedDescription)")
        }
        return sandboxSuccess(
            tool: name,
            result: ["kind": "sandbox_file", "path": resolved, "edits": edits.count, "bytes": text.utf8.count])
    }
}

// MARK: - sandbox_exec

struct SandboxExecTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    let name = BuiltinSandboxTools.exec
    var description: String {
        """
        Run a shell command in the agent's sandbox (macOS, `/bin/sh`). Commands run on this Mac but confined: \
        they can read system tools and write only inside your workspace. **Reserve this for builds, git, \
        processes and anything else that needs a shell.** For file IO, search, edit and write, prefer the \
        dedicated `sandbox_*` tools. The network is OFF unless the user turned it on for this agent.

        Runs to completion in the foreground. Prefer ONE rich invocation (chained with `&&` / `;` / pipes) \
        over many round-trips. Takes a single command LINE, passed verbatim. Multi-line scripts: \
        `sandbox_write_file` the script, then run it. Pass `timeout: <seconds>` for an idle ceiling \
        (killed after N silent seconds; default \(Self.defaultIdleTimeout)). Output is truncated at ~50KB \
        (head + tail kept). The per-turn command count is capped, so chain inside one call.
        """
    }

    static let defaultIdleTimeout = 120
    static let maxIdleTimeout = 1800

    var requirements: [String] { [] }
    /// Arbitrary commands: the user is asked unless they set Auto.
    var defaultPermissionPolicy: ToolPermissionPolicy { .ask }
    /// Streaming-style tool: the idle timeout is its safety net, not the
    /// registry's 120 s wall clock; cancellation kills the process.
    var bypassRegistryTimeout: Bool { true }

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "command": .object([
                    "type": .string("string"),
                    "description": .string("Shell command to run (single string, e.g. `wc -l src/*.swift`)."),
                ]),
                "cwd": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Working directory. Defaults to your home — OMIT unless you need a different "
                            + "directory. Use a path relative to your home or absolute under it."),
                ]),
                "timeout": .object([
                    "type": .string("integer"),
                    "description": .string(
                        "Idle timeout in seconds: the command is killed if it prints nothing for this long "
                            + "(default \(Self.defaultIdleTimeout), max \(Self.maxIdleTimeout))."),
                ]),
            ]),
            "required": .array([.string("command")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let context: SandboxToolContext
        switch await SandboxToolContext.resolve(tool: name) {
        case .failure(let refusal): return refusal.envelope
        case .success(let value): context = value
        }
        guard
            SandboxExecLimiter.shared.checkAndIncrement(
                agentName: context.agentName, limit: max(1, context.config.maxCommandsPerTurn))
        else {
            return ToolEnvelope.failure(
                kind: .rejected,
                message:
                    "Per-turn command limit reached (\(context.config.maxCommandsPerTurn) commands). "
                    + "Wait until the next turn or chain steps inside one `sandbox_exec` call.",
                tool: name, retryable: false)
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let cmdReq = requireString(
            args, "command", expected: "shell command string (e.g. `ls -la`)", tool: name)
        guard case .value(let command) = cmdReq else { return cmdReq.failureEnvelope ?? "" }
        var cwd = context.home
        if let cwdArg = args["cwd"] as? String, !cwdArg.isEmpty {
            let cwdReq = requireSandboxPath(cwdArg, home: context.home, field: "cwd", tool: name)
            guard case .value(let resolvedCwd) = cwdReq else { return cwdReq.failureEnvelope ?? "" }
            cwd = resolvedCwd
        }
        let idle = TimeInterval(
            min(max(coerceInt(args["timeout"]) ?? Self.defaultIdleTimeout, 1), Self.maxIdleTimeout))
        if let notReady = await context.ensureReady(tool: name) { return notReady }

        let secrets = SandboxExecSecrets.values(for: context.agentId)
        let kill = SandboxProcessKill()
        let result: ContainerExecResult
        do {
            result = try await withTaskCancellationHandler {
                try await context.run(
                    "set -o pipefail; \(command)", cwd: cwd, timeout: idle, extraEnv: secrets,
                    onProcessStarted: { handle in kill.set(handle) })
            } onCancel: {
                kill.cancel()
            }
        } catch SandboxError.timeout {
            return ToolEnvelope.failure(
                kind: .timeout,
                message: "Command produced no output for \(Int(idle)) seconds and was stopped.",
                tool: name, retryable: true)
        } catch {
            if Task.isCancelled { throw CancellationError() }
            return sandboxExecutionFailure(tool: name, message: "Command failed to run: \(error.localizedDescription)")
        }
        // Stored secrets ride into the env, so `echo $KEY` must not put the
        // value in model context (upstream #2157).
        let stdout = SecretScrubber.scrub(result.stdout, secrets: secrets)
        let stderr = SecretScrubber.scrub(result.stderr, secrets: secrets)
        var warnings: [String] = []
        if !context.config.sandboxNetworkEnabled, Self.looksLikeNetworkFailure(stderr) {
            warnings.append(
                "Network access is off for this agent, so this command cannot reach the internet. The user can turn it on in the agent's sandbox settings."
            )
        }
        if result.exitCode == 141 {
            warnings.append("Exit 141 is SIGPIPE from `| head`-style pipelines; captured output is still valid.")
        }
        return sandboxSuccess(
            tool: name,
            result: [
                "stdout": sandboxTruncate(stdout),
                "stderr": sandboxTruncate(stderr, maxChars: ToolOutputCaps.execStderr),
                "exit_code": Int(result.exitCode),
                "cwd": cwd,
            ],
            warnings: warnings.isEmpty ? nil : warnings)
    }

    static func looksLikeNetworkFailure(_ stderr: String) -> Bool {
        let lowered = stderr.lowercased()
        return ["could not resolve host", "nodename nor servname", "network is unreachable", "temporary failure in name resolution"]
            .contains { lowered.contains($0) }
    }
}

/// The agent's stored secrets as env vars (key to value). The same map
/// scrubs output afterwards.
enum SandboxExecSecrets {
    @TaskLocal static var testingSecrets: [String: String]?

    static func values(for agentId: UUID) -> [String: String] {
        if let testingSecrets { return testingSecrets }
        return AgentSecretsKeychain.getFilteredSecrets(agentId: agentId)
    }
}
