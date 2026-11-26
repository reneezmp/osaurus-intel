//
//  IntelParallelToolBatch.swift
//  osaurus
//
//  Upstream Classic's parallel tool batch (`AgentToolLoop.runBatchInParallel`,
//  `pathSerializationKey`; stage 5c row 17): the calls of one model round run
//  concurrently, `file_write` / `file_edit` calls on the same path run one
//  after another in model order, and the results come back in call order. A
//  failing call becomes its own error envelope and never aborts the others.
//  Approvals are NOT handled here: the engine resolves every approval serially,
//  in model order, before it runs the approved calls through this batch.
//

import Foundation

/// One approved call handed to the batch.
struct IntelBatchCall: Sendable, Equatable {
    var callId: String
    var toolName: String
    var jsonArguments: String
}

/// What one call produced.
struct IntelBatchExecution: Sendable, Equatable {
    var result: String
    var isError: Bool = false
    var durationMs: Double = 0
}

extension AgentToolLoop {
    /// Folder tools that mutate one target path. Two parallel calls on the same
    /// path read-then-write non-atomically (lost update), so same-path slots
    /// run serially while distinct paths stay parallel (upstream).
    static let pathMutatingToolNames: Set<String> = ["file_write", "file_edit"]

    /// Non-nil when the call mutates a single target path; calls sharing a key
    /// run serially in model order (upstream `pathSerializationKey`).
    static func pathSerializationKey(toolName: String, jsonArguments: String) -> String? {
        guard pathMutatingToolNames.contains(toolName) else { return nil }
        guard let data = jsonArguments.data(using: .utf8),
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let rawPath = obj["path"] as? String
        else { return nil }
        let path = (rawPath.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).standardizingPath
        guard !path.isEmpty else { return nil }
        return path
    }

    /// Tools whose successful execution ends the run from inside a batch
    /// (upstream `interceptToolNames`). A batch holding one runs serially in
    /// model order instead of in parallel.
    static let interceptToolNames: Set<String> = AgentLoopRunEnd.toolNames

    static func containsIntercept(_ toolNames: [String]) -> Bool {
        toolNames.contains { interceptToolNames.contains($0) }
    }

    /// How the engine runs one round's approved calls.
    enum BatchMode: Equatable, Sendable {
        /// One call, or a round with a call that can change what the rest of
        /// the round may call (`capabilities` loads tools): gate, run and report
        /// each call in turn, as before the parallel batch.
        case inline
        /// An agent-loop control call (`complete`, `clarify`, ...) is in the
        /// round: approvals first, then the calls one by one in model order.
        case serial
        /// Approvals first, then every call concurrently (upstream).
        case parallel
    }

    static func batchMode(forToolNames names: [String]) -> BatchMode {
        guard names.count > 1 else { return .inline }
        if names.contains(CapabilitiesTool.toolName) { return .inline }
        if containsIntercept(names) { return .serial }
        return .parallel
    }

    /// Upstream's batch executor: every call concurrently in a task group (no
    /// concurrency cap, as upstream), same-path mutating calls chained in model
    /// order, results restored to input order. `serial` runs the calls one by
    /// one in order instead. Cancellation: calls not yet started when the run
    /// is stopped come back as a paired "cancelled" envelope, so no assistant
    /// tool call dangles.
    static func runBatchInParallel(
        _ calls: [IntelBatchCall],
        serial: Bool = false,
        execute: @escaping @Sendable (IntelBatchCall) async throws -> String
    ) async -> [IntelBatchExecution] {
        @Sendable func executeOne(_ call: IntelBatchCall) async -> IntelBatchExecution {
            if Task.isCancelled {
                return IntelBatchExecution(
                    result: ToolEnvelope.failure(
                        kind: .executionError,
                        message: "Run cancelled before this call executed.",
                        tool: call.toolName,
                        retryable: false
                    )
                )
            }
            let start = Date()
            do {
                let result = try await execute(call)
                return IntelBatchExecution(
                    result: result, durationMs: Date().timeIntervalSince(start) * 1_000)
            } catch {
                return IntelBatchExecution(
                    result: ToolEnvelope.fromError(error, tool: call.toolName),
                    isError: true,
                    durationMs: Date().timeIntervalSince(start) * 1_000)
            }
        }

        if serial || calls.count <= 1 {
            var out: [IntelBatchExecution] = []
            for call in calls { out.append(await executeOne(call)) }
            return out
        }

        // Same-path mutating calls share a group (run in order); every other
        // call is its own group.
        var groups: [[Int]] = []
        var groupIndexByKey: [String: Int] = [:]
        for (index, call) in calls.enumerated() {
            if let key = pathSerializationKey(toolName: call.toolName, jsonArguments: call.jsonArguments) {
                if let existing = groupIndexByKey[key] {
                    groups[existing].append(index)
                    continue
                }
                groupIndexByKey[key] = groups.count
            }
            groups.append([index])
        }

        // Two or more foreground `spawn_agent` calls in one message are one
        // fan-out wave (upstream): one approval card and one fan-out limit
        // check in `SpawnWaveGate`, while each call keeps its own digest.
        let spawnWave = SpawnWaveContext.make(for: calls)
        if let spawnWave {
            await SpawnWaveGate.shared.open(spawnWave)
        }
        defer {
            if let spawnWave {
                let waveId = spawnWave.waveId
                Task { await SpawnWaveGate.shared.close(waveId: waveId) }
            }
        }

        let indexed: [(Int, IntelBatchExecution)] = await ChatExecutionContext.$currentBatchId.withValue(UUID()) {
            await ChatExecutionContext.$spawnWave.withValue(spawnWave) {
                await withTaskGroup(of: [(Int, IntelBatchExecution)].self) { group in
                    for slotGroup in groups {
                        group.addTask {
                            var results: [(Int, IntelBatchExecution)] = []
                            for index in slotGroup { results.append((index, await executeOne(calls[index]))) }
                            return results
                        }
                    }
                    var collected: [(Int, IntelBatchExecution)] = []
                    for await items in group { collected.append(contentsOf: items) }
                    return collected
                }
            }
        }
        return indexed.sorted { $0.0 < $1.0 }.map { $0.1 }
    }
}
