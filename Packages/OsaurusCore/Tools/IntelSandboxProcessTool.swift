//
//  IntelSandboxProcessTool.swift
//  osaurus
//
//  Intel fork (W-seatbelt-sandbox stage 4): `sandbox_process`, the poll /
//  wait / kill companion of `sandbox_exec(background: true)`. Upstream's tool
//  (in `BuiltinSandboxTools.swift`) probes the pid with `kill -0` and
//  `/proc` inside the Linux guest. On the host the app owns the process, so
//  the tool asks the job registry (`SandboxBackgroundJobs`) directly:
//
//  - it only ever touches jobs this agent started (an arbitrary pid, or
//    another agent's job, is "unknown"), so it cannot signal anything else;
//  - the log tail is read by a confined `tail` command (never an app-side
//    read of a path the sandbox could have swapped for a symlink) and
//    scrubbed of stored secrets;
//  - it is offered only to agents whose own `backgroundProcessEnabled` is on.
//

import Foundation

struct SandboxProcessTool: OsaurusTool, PermissionedTool, @unchecked Sendable {
    let name = BuiltinSandboxTools.process
    let description =
        "Manage background jobs started by `sandbox_exec(background:true)`. `action=\"poll\"` returns whether "
        + "the pid is still running plus a tail of the log; `\"wait\"` blocks until exit (or `timeout` seconds); "
        + "`\"kill\"` sends SIGTERM (`force:true` for SIGKILL). Pass the `pid` returned by the launching "
        + "`sandbox_exec` call. Only your own background jobs can be managed."

    var requirements: [String] { [] }
    /// Reads and stops this agent's own jobs only.
    var defaultPermissionPolicy: ToolPermissionPolicy { .auto }
    /// `wait` can run up to `maxWait` seconds; cancellation ends the loop.
    var bypassRegistryTimeout: Bool { true }

    static let maxWait = 300
    static let defaultWait = 60

    var parameters: JSONValue? {
        .object([
            "type": .string("object"),
            "additionalProperties": .bool(false),
            "properties": .object([
                "action": .object([
                    "type": .string("string"),
                    "enum": .array([.string("poll"), .string("wait"), .string("kill")]),
                    "description": .string("`poll`, `wait`, or `kill`."),
                ]),
                "pid": .object([
                    "type": .string("string"),
                    "description": .string("Process id returned by `sandbox_exec(background:true)`."),
                ]),
                "timeout": .object([
                    "type": .string("integer"),
                    "description": .string(
                        "Seconds to block on `wait` (default \(Self.defaultWait), max \(Self.maxWait))."),
                ]),
                "tail_lines": .object([
                    "type": .string("integer"),
                    "description": .string("Lines of the job log to include (default 40, max 200)."),
                ]),
                "force": .object([
                    "type": .string("boolean"),
                    "description": .string("Send SIGKILL instead of SIGTERM on `kill`."),
                ]),
            ]),
            "required": .array([.string("action"), .string("pid")]),
        ])
    }

    func execute(argumentsJSON: String) async throws -> String {
        let context: SandboxToolContext
        switch await SandboxToolContext.resolve(tool: name) {
        case .failure(let refusal): return refusal.envelope
        case .success(let value): context = value
        }
        guard context.config.backgroundProcessEnabled else {
            return ToolEnvelope.failure(
                kind: .unavailable,
                message:
                    "Background processes are off for this agent. The user can turn them on in the agent's sandbox settings.",
                tool: name, retryable: false)
        }
        let argsReq = requireArgumentsDictionary(argumentsJSON, tool: name)
        guard case .value(let args) = argsReq else { return argsReq.failureEnvelope ?? "" }
        let actionReq = requireString(
            args, "action", expected: "one of `poll`, `wait`, `kill`", tool: name)
        guard case .value(let action) = actionReq else { return actionReq.failureEnvelope ?? "" }
        let pidReq = requireString(
            args, "pid", expected: "process id returned by `sandbox_exec(background:true)`", tool: name)
        guard case .value(let pid) = pidReq else { return pidReq.failureEnvelope ?? "" }
        guard Int32(pid) != nil else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "`pid` must be the numeric pid string returned by `sandbox_exec(background:true)`. Got `\(pid)`.",
                field: "pid", expected: "numeric pid string", tool: name)
        }
        let jobs = SandboxToolContext.manager.backgroundJobs
        guard let job = jobs.lookup(agentName: context.agentName, pid: pid) else {
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message:
                    "No background job with pid `\(pid)` is known for this agent. It may have been stopped when the run ended, or the sandbox restarted. Start it again with `sandbox_exec(background:true)`.",
                field: "pid", expected: "pid of a running background job", tool: name)
        }
        let tailLines = min(max(coerceInt(args["tail_lines"]) ?? 40, 0), 200)
        let secrets = SandboxExecSecrets.values(for: context.agentId)

        switch action {
        case "poll":
            let tail = await Self.tail(job: job, lines: tailLines, context: context, secrets: secrets)
            return ToolEnvelope.success(tool: name, result: Self.status(job: job, tail: tail))
        case "wait":
            let seconds = min(max(coerceInt(args["timeout"]) ?? Self.defaultWait, 1), Self.maxWait)
            var waited = 0.0
            while job.isRunning, waited < Double(seconds) {
                if Task.isCancelled { throw CancellationError() }
                try? await Task.sleep(nanoseconds: 250_000_000)
                waited += 0.25
            }
            let tail = await Self.tail(job: job, lines: tailLines, context: context, secrets: secrets)
            var payload = Self.status(job: job, tail: tail)
            payload["exited"] = !job.isRunning
            payload["timed_out"] = job.isRunning
            return ToolEnvelope.success(tool: name, result: payload)
        case "kill":
            let force = coerceBool(args["force"]) ?? false
            let stopped = await jobs.stop(agentName: context.agentName, pid: pid, force: force)
            var payload: [String: Any] = [
                "pid": pid, "killed": stopped, "signal": force ? "SIGKILL" : "SIGTERM",
            ]
            if let code = job.exitCode { payload["exit_code"] = Int(code) }
            return ToolEnvelope.success(tool: name, result: payload)
        default:
            return ToolEnvelope.failure(
                kind: .invalidArgs,
                message: "Unsupported `action`: `\(action)`. Use `poll`, `wait`, or `kill`.",
                field: "action", expected: "one of `poll`, `wait`, `kill`", tool: name)
        }
    }

    private static func status(job: SandboxBackgroundJobs.Job, tail: String) -> [String: Any] {
        var payload: [String: Any] = [
            "pid": job.pid,
            "alive": job.isRunning,
            "log_file": job.logFile,
            "log_tail": tail,
        ]
        if let code = job.exitCode { payload["exit_code"] = Int(code) }
        return payload
    }

    /// The last `lines` of the job log, read by a confined command and
    /// scrubbed of the agent's stored secrets (jobs run with the same
    /// secret-bearing environment as foreground commands).
    private static func tail(
        job: SandboxBackgroundJobs.Job,
        lines: Int,
        context: SandboxToolContext,
        secrets: [String: String]
    ) async -> String {
        guard lines > 0 else { return "" }
        let result = try? await context.run(
            "tail -n \(lines) '\(sandboxShellEscape(job.logFile))' 2>/dev/null", timeout: 10)
        let text = SecretScrubber.scrub(result?.stdout ?? "", secrets: secrets)
        return sandboxTruncate(text, maxChars: ToolOutputCaps.execStdout)
    }
}
