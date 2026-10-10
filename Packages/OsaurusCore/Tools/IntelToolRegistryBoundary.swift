//
//  IntelToolRegistryBoundary.swift
//  OsaurusCore — Intel fork
//
//  Upstream's ToolRegistry execution boundary (Tools/ToolRegistry.swift is
//  excluded on Intel; Intel's registry lives in IntelStubConformers.swift):
//  argument preflight (schema coercion + validation), the wall-clock
//  timeout race, and result normalization (lossless compression, envelope
//  normalization, universal byte cap). Copied verbatim from upstream
//  (W-agent-loop-tools, 2026-10-10); keep in step with upstream's
//  ToolRegistry on every sync.
//

import Foundation
import os

private let toolBodyTimeoutQueue = DispatchQueue(label: "ai.osaurus.tool-registry.timeout")

private final class ToolBodyRaceState: @unchecked Sendable {
    private let lock = NSLock()
    private var didResume = false
    private var pendingResult: String?
    private var continuation: CheckedContinuation<String, Never>?
    private var bodyTask: Task<Void, Never>?
    private var timeoutTimer: DispatchSourceTimer?
    private var bodyFinished = false
    private var graceContinuation: CheckedContinuation<Bool, Never>?

    /// The body task exited (whatever won the race). Wakes a grace waiter.
    func markBodyFinished() {
        lock.lock()
        bodyFinished = true
        let waiter = graceContinuation
        graceContinuation = nil
        lock.unlock()
        waiter?.resume(returning: true)
    }

    /// Wait up to `seconds` for the body to exit after the race was lost
    /// (timeout/cancellation), so file writes it still completes land
    /// inside the caller's journal capture. Returns false when it didn't.
    func waitForBody(graceSeconds seconds: TimeInterval, queue: DispatchQueue) async -> Bool {
        if isBodyFinished() { return true }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            if !armGrace(continuation) {
                continuation.resume(returning: true)
                return
            }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + .nanoseconds(max(0, Int(seconds * 1_000_000_000))))
            timer.setEventHandler { [self] in
                lock.lock()
                let waiter = graceContinuation
                graceContinuation = nil
                lock.unlock()
                waiter?.resume(returning: false)
                timer.cancel()
            }
            timer.resume()
        }
    }

    private func isBodyFinished() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return bodyFinished
    }

    /// Registers the grace waiter; false when the body already exited.
    private func armGrace(_ continuation: CheckedContinuation<Bool, Never>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if bodyFinished { return false }
        graceContinuation = continuation
        return true
    }

    func install(continuation: CheckedContinuation<String, Never>) {
        lock.lock()
        if didResume, let pendingResult {
            self.pendingResult = nil
            lock.unlock()
            continuation.resume(returning: pendingResult)
            return
        }
        self.continuation = continuation
        lock.unlock()
    }

    func setTasks(bodyTask: Task<Void, Never>, timeoutTimer: DispatchSourceTimer) {
        lock.lock()
        if didResume {
            lock.unlock()
            bodyTask.cancel()
            timeoutTimer.cancel()
            return
        }
        self.bodyTask = bodyTask
        self.timeoutTimer = timeoutTimer
        lock.unlock()
    }

    func complete(_ result: String) {
        lock.lock()
        guard !didResume else {
            lock.unlock()
            return
        }
        didResume = true
        let continuation = self.continuation
        if continuation == nil {
            pendingResult = result
        }
        self.continuation = nil
        let bodyTask = self.bodyTask
        let timeoutTimer = self.timeoutTimer
        self.bodyTask = nil
        self.timeoutTimer = nil
        lock.unlock()

        bodyTask?.cancel()
        timeoutTimer?.cancel()
        continuation?.resume(returning: result)
    }
}

extension ToolRegistry {
    /// Upstream `SecretPromptAction.actionKey` (Tools/SandboxSecretTools.swift,
    /// excluded on Intel). Intel's `SecretPromptParser` is a stub that never
    /// matches, so the secret-prompt guard below is inert until secret
    /// prompts land; it is kept so the boundary stays upstream's.
    static let secretPromptActionKey = "secret_prompt"

    /// `userInfo` keys on the code-7 (missing system permission) error
    /// (upstream; read by `ToolEnvelope.fromError`).
    nonisolated static let missingPermissionUserInfoKey = "ai.osaurus.toolRegistry.permission"
    nonisolated static let missingPermissionSettingsURLUserInfoKey = "ai.osaurus.toolRegistry.systemSettingsURL"

    /// Bypass-path for streaming-aware tools. Runs the body straight
    /// through with the same error-mapping as `runToolBody`, but no
    /// wall-clock race. Cancellation still propagates: when the calling
    /// task is cancelled, the body's own `Task.isCancelled` checks (or
    /// the underlying process signals) tear it down.
    nonisolated internal static func runToolBodyUntimed(
        _ tool: OsaurusTool,
        argumentsJSON: String,
        authorizeBody: (@Sendable () async -> String?)? = nil
    ) async throws -> String {
        do {
            try Task.checkCancellation()
            if let refusal = await authorizeBody?() { return refusal }
            try Task.checkCancellation()
            return try await tool.execute(argumentsJSON: argumentsJSON)
        } catch is CancellationError {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: L("Tool '\(tool.name)' was cancelled."),
                tool: tool.name,
                retryable: false
            )
        } catch {
            return ToolEnvelope.fromError(error, tool: tool.name)
        }
    }

    /// Outcome of `preflight`: either the cleaned arguments to dispatch
    /// with, or a ready-to-return failure envelope JSON string.
    enum PreflightOutcome {
        case ready(argumentsJSON: String)
        case rejected(envelopeJSON: String)
    }

    /// Pre-dispatch step that applies schema-aware coercion and then
    /// validation. Coercion runs FIRST so quantized models that send
    /// arrays / objects as JSON-encoded strings (e.g.
    /// `"actions": "[{\"action\":\"type\"}]"` for a schema declaring
    /// `actions: array`) get auto-unwrapped before either the validator
    /// or the tool body sees them.
    ///
    /// Returns `.rejected` when the validator finds the (post-coercion)
    /// arguments invalid; otherwise `.ready` with the JSON the tool body
    /// should consume. Re-serialisation only happens when coercion
    /// actually changed the shape — when the model sent native types we
    /// preserve the original literal byte-for-byte so downstream
    /// consumers (logging, storage) see what the client sent.
    ///
    /// Tools without a declared schema or with un-parseable JSON args
    /// fall through unchanged: parsing is best-effort, and tool bodies
    /// keep their richer `requireXxx` helpers as the second line of
    /// defence.
    /// Internal (not private) so the test helper exercises the exact
    /// coerce → validate → hint path the dispatcher uses.
    nonisolated static func preflight(
        argumentsJSON: String,
        schema: JSONValue?,
        toolName: String,
        hint: ((String) -> String?)? = nil,
        preservingEmpty: Set<String> = []
    ) -> PreflightOutcome {
        guard let schema,
            let data = argumentsJSON.data(using: .utf8),
            let parsed = try? JSONSerialization.jsonObject(with: data)
        else { return .ready(argumentsJSON: argumentsJSON) }

        let coerced = SchemaValidator.coerceArguments(parsed, against: schema, preservingEmpty: preservingEmpty)
        let result = SchemaValidator.validate(arguments: coerced, against: schema)
        if !result.isValid, var message = result.errorMessage {
            // Tools can explain where a misplaced key belongs (e.g. `sheet`
            // inside a `file_edit` operation). Guidance only — the call is
            // still rejected, never rewritten.
            if let field = result.field, let extra = hint?(field) {
                message += (message.hasSuffix(".") ? " " : ". ") + extra
            }
            return .rejected(
                envelopeJSON: ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: message,
                    field: result.field,
                    tool: toolName
                )
            )
        }

        // Try to detect "coercion changed the shape" via canonicalised
        // JSON byte equality. When the bytes match, hand back the
        // original literal; otherwise re-serialise so the tool body
        // gets native types.
        let opts: JSONSerialization.WritingOptions = [.sortedKeys]
        guard let coercedData = try? JSONSerialization.data(withJSONObject: coerced, options: opts),
            let originalData = try? JSONSerialization.data(withJSONObject: parsed, options: opts)
        else { return .ready(argumentsJSON: argumentsJSON) }

        if coercedData == originalData {
            return .ready(argumentsJSON: argumentsJSON)
        }
        guard let coercedJSON = String(data: coercedData, encoding: .utf8) else {
            return .ready(argumentsJSON: argumentsJSON)
        }
        return .ready(argumentsJSON: coercedJSON)
    }

    /// Registry-boundary result normalization, applied to EVERY executed
    /// tool body's output (built-in, MCP, plugin, dynamic):
    ///
    /// 1. Envelope normalization — plain-text results (MCP content
    ///    conversions, plugin prose, legacy tools) wrap into the canonical
    ///    success envelope so every consumer (`isError`, `classify`,
    ///    dedupe, transcripts) sees one shape.
    /// 2. Universal output cap — results above
    ///    `ToolOutputCaps.universalResult` are head+tail truncated and
    ///    re-wrapped with `truncated: true` plus a recovery hint, so no
    ///    single call (base64 payload, giant diff, runaway listing) can
    ///    blow the context window in one turn. Error-ness is preserved.
    nonisolated static func normalizeToolResult(_ raw: String, tool: String) -> String {
        // The secret-prompt marker is deliberately NOT an envelope —
        // `SecretPromptParser` keys off `action` at the JSON root and the
        // chat loop replaces it with a real envelope after the overlay
        // resolves. Wrapping it here would break the secure-input flow.
        // Bound the marker scan to the payload head — `raw` can be hundreds of
        // MB and this runs on the (main-actor) registry path; the secret-prompt
        // marker is a leading root key, so scanning the whole string just to
        // detect it could hang the UI.
        if raw.prefix(4096).contains("\"action\":\"\(Self.secretPromptActionKey)\""),
            SecretPromptParser.parse(raw) != nil
        {
            return raw
        }

        // Lossless formatting compaction at ingest. Runs AFTER the
        // secret-prompt guard (the marker must reach the chat loop byte-exact)
        // and BEFORE the cap, so an external pretty-JSON payload that crushes
        // back under the cap avoids truncation entirely. Meaning-preserving and
        // deterministic, so the KV-prefix stays byte-stable. See
        // `ToolOutputCompressor`.
        let payload = ToolOutputCompressor.compact(raw)

        // The cap protects a TOKEN budget (~25K tokens), and tokens track
        // UTF-8 bytes far better than Swift characters: a 100,000-character
        // CJK/emoji-heavy payload is ~300 KB and ~3× the tokens of ASCII.
        // Measure in bytes; slice in characters at the proportional length so
        // ASCII payloads behave exactly as before (bytes == characters).
        let cap = ToolOutputCaps.universalResult
        let isEnvelope = ToolEnvelope.isSuccess(payload) || ToolEnvelope.isError(payload)
        let byteCount = payload.utf8.count

        if byteCount <= cap {
            return isEnvelope ? payload : ToolEnvelope.success(tool: tool, text: payload)
        }
        // Head-biased: at the registry backstop the front of an oversized
        // payload is what identifies it (the recovery hint rides in the
        // envelope, not the marker). The cap is a BYTE budget: a proportional
        // character slice is only a first guess (mixed emoji/ASCII payloads
        // are denser at one end than the other), so shrink the character
        // budget until the kept text really fits.
        var characterCap = max(1, Int(Double(cap) * Double(payload.count) / Double(byteCount)))
        var truncatedContent = HeadTailTruncation.apply(payload, cap: characterCap, headFraction: 2.0 / 3.0)
        var passes = 0
        while truncatedContent.utf8.count > cap, characterCap > 1, passes < 12 {
            passes += 1
            characterCap = max(1, Int(Double(characterCap) * Double(cap) / Double(truncatedContent.utf8.count)))
            truncatedContent = HeadTailTruncation.apply(payload, cap: characterCap, headFraction: 2.0 / 3.0)
        }
        // Character slicing cannot bound bytes when a single grapheme is
        // larger than the budget (one base letter plus tens of thousands of
        // combining marks is ONE Character), or when the pass limit ran out:
        // the byte-exact cut is the guarantee, the loop above only the
        // grapheme-friendly first choice.
        if truncatedContent.utf8.count > cap {
            truncatedContent = HeadTailTruncation.applyByteExact(payload, byteCap: cap, headFraction: 2.0 / 3.0)
        }
        let hint =
            "Output exceeded the per-call cap and was truncated (head and tail kept). "
            + "Re-run with narrower arguments — filters, `max_results`, line ranges, or "
            + "head/tail options — to retrieve the missing region."

        if ToolEnvelope.isError(payload) {
            return ToolEnvelope.failure(
                kind: .executionError,
                message: "Tool '\(tool)' failed and its error output exceeded the per-call cap. " + hint,
                tool: tool,
                metadata: [
                    "truncated": true,
                    "original_chars": payload.count,
                    "content": truncatedContent,
                ]
            )
        }
        return ToolEnvelope.success(
            tool: tool,
            result: [
                "kind": "truncated_output",
                "truncated": true,
                "original_chars": payload.count,
                "content": truncatedContent,
            ] as [String: Any],
            warnings: [hint]
        )
    }

    /// Default per-tool wall-clock cap (seconds). Mirrors
    /// `PluginHostAPI.toolExecutionTimeout` so the chat-side and plugin-side
    /// loops have matching semantics. Tools that need a tighter or looser
    /// budget (e.g. sandbox shell, MCP provider) still set their own.
    public static let defaultToolTimeoutSeconds: TimeInterval = 120

    /// Trampoline that executes the tool outside of MainActor isolation,
    /// racing the body against a wall-clock timeout. On timeout we cancel
    /// the body task and return a `kind: .timeout` envelope so the model
    /// sees a structured signal instead of a hung agent loop. Internal so
    /// tests can drive it with a small `timeoutSeconds` value without
    /// waiting for the full 120s production budget.
    ///
    /// This intentionally does not use `withTaskGroup`: structured child
    /// groups must drain before returning, so a non-cooperative tool body
    /// that ignores cancellation can still hold the caller until it exits.
    /// The timeout branch also uses a dedicated GCD timer queue rather than
    /// `Task.sleep`, because a saturated Swift executor can otherwise delay
    /// the "wall-clock" timeout behind unrelated async work.
    /// After a timeout or cancellation wins the race, how long to wait for
    /// the (cancelled) body to actually exit before returning. The caller's
    /// file-history capture ends when this returns, so writes the body
    /// finishes inside this window are still journaled and undoable.
    nonisolated static let defaultBodyGraceSeconds: TimeInterval = 5

    nonisolated internal static func runToolBody(
        _ tool: OsaurusTool,
        argumentsJSON: String,
        timeoutSeconds: TimeInterval,
        bodyGraceSeconds: TimeInterval = defaultBodyGraceSeconds,
        authorizeBody: (@Sendable () async -> String?)? = nil
    ) async throws -> String {
        let toolName = tool.name
        let timeoutEnvelope = ToolEnvelope.failure(
            kind: .timeout,
            message:
                L("Tool '\(toolName)' exceeded the \(Int(timeoutSeconds))s execution budget."),
            tool: toolName,
            retryable: true
        )
        let cancellationEnvelope = ToolEnvelope.failure(
            kind: .executionError,
            message: L("Tool '\(toolName)' was cancelled."),
            tool: toolName,
            retryable: false
        )
        let race = ToolBodyRaceState()

        let result = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                race.install(continuation: continuation)
                let timeoutTimer = DispatchSource.makeTimerSource(queue: toolBodyTimeoutQueue)
                let timeoutNanoseconds = max(0, Int(timeoutSeconds * 1_000_000_000))
                timeoutTimer.schedule(deadline: .now() + .nanoseconds(timeoutNanoseconds))
                timeoutTimer.setEventHandler {
                    race.complete(timeoutEnvelope)
                }
                timeoutTimer.resume()

                let bodyTask = Task {
                    defer { race.markBodyFinished() }
                    do {
                        try Task.checkCancellation()
                        if let refusal = await authorizeBody?() {
                            race.complete(refusal)
                            return
                        }
                        try Task.checkCancellation()
                        let result = try await tool.execute(argumentsJSON: argumentsJSON)
                        race.complete(result)
                    } catch is CancellationError {
                        race.complete(cancellationEnvelope)
                    } catch {
                        race.complete(ToolEnvelope.fromError(error, tool: toolName))
                    }
                }
                race.setTasks(bodyTask: bodyTask, timeoutTimer: timeoutTimer)
            }
        } onCancel: {
            race.complete(cancellationEnvelope)
        }
        // A lost race means the body may still be running. Give it a bounded
        // window to exit so late writes stay inside the journal capture.
        if bodyGraceSeconds > 0 {
            let finished = await race.waitForBody(graceSeconds: bodyGraceSeconds, queue: toolBodyTimeoutQueue)
            if !finished {
                Logger(subsystem: "ai.osaurus", category: "tools").warning(
                    "tool \(toolName, privacy: .public) still running \(Int(bodyGraceSeconds))s after timeout/cancel; later writes are not journaled")
            }
        }
        return result
    }
}
