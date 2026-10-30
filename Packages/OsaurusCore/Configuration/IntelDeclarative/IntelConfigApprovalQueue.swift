//
//  IntelConfigApprovalQueue.swift
//  OsaurusCore
//
//  Caller-independent, in-memory approval handoff for Intel Gate 5B.
//

#if OSAURUS_INTEL

import Foundation
import Combine

public enum IntelConfigApprovalOutcome: Sendable, Equatable {
    case approved
    case denied
    case timedOut
    case cancelled
}

public struct IntelConfigApprovalRequest: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let sessionID: String
    public let plan: IntelDeclarativeConfigurationPlan
    /// Raised by a run from the owner's paired phone: listed on
    /// `GET /config/approvals` for the phone to answer (upstream, MOBILE_PROTOCOL
    /// §16.3). Plans raised in a Mac chat never leave the Mac.
    public let fromPairedPhone: Bool

    public init(
        id: UUID = UUID(), sessionID: String, plan: IntelDeclarativeConfigurationPlan, fromPairedPhone: Bool = false
    ) {
        self.id = id
        self.sessionID = sessionID
        self.plan = plan
        self.fromPairedPhone = fromPairedPhone
    }
}

/// A process-wide queue lets any model/tool caller await the same user-owned
/// approval surface. It deliberately stores no approval receipt and never
/// applies a plan; Gate 5A remains the authority for stale/replay checks.
@MainActor
public final class IntelConfigApprovalQueue: ObservableObject {
    public static let shared = IntelConfigApprovalQueue()

    @Published public private(set) var pending: [IntelConfigApprovalRequest] = []

    private var continuations: [UUID: CheckedContinuation<IntelConfigApprovalOutcome, Never>] = [:]
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private var mountedSurfaces: [String: Int] = [:]

    public init() {}

    public func hasMountedSurface(for sessionID: String) -> Bool {
        mountedSurfaces[sessionID, default: 0] > 0
    }

    public func surfaceDidMount(sessionID: String) {
        mountedSurfaces[sessionID, default: 0] += 1
    }

    public func surfaceDidUnmount(sessionID: String) {
        let remaining = max(0, mountedSurfaces[sessionID, default: 0] - 1)
        if remaining == 0 {
            mountedSurfaces.removeValue(forKey: sessionID)
        } else {
            mountedSurfaces[sessionID] = remaining
        }
    }

    /// Enqueues the exact plan and suspends until the card resolves it or the
    /// caller is cancelled. A timeout is intentionally bounded by default.
    public func requestApproval(
        plan: IntelDeclarativeConfigurationPlan,
        sessionID: String,
        fromPairedPhone: Bool = false,
        timeout: TimeInterval = 300
    ) async -> IntelConfigApprovalOutcome {
        let request = IntelConfigApprovalRequest(sessionID: sessionID, plan: plan, fromPairedPhone: fromPairedPhone)

        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }

                continuations[request.id] = continuation
                pending.append(request)

                if timeout > 0 {
                    let nanoseconds = UInt64(min(timeout, 86_400) * 1_000_000_000)
                    timeoutTasks[request.id] = Task { [weak self] in
                        do {
                            try await Task.sleep(nanoseconds: nanoseconds)
                        } catch {
                            return
                        }
                        guard !Task.isCancelled else { return }
                        self?.resolve(id: request.id, outcome: .timedOut)
                    }
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in
                self?.resolve(id: request.id, outcome: .cancelled)
            }
        })
    }

    public func resolve(id: UUID, outcome: IntelConfigApprovalOutcome) {
        pending.removeAll { $0.id == id }
        timeoutTasks.removeValue(forKey: id)?.cancel()
        guard let continuation = continuations.removeValue(forKey: id) else { return }
        continuation.resume(returning: outcome)
    }

    /// The phone's answer (upstream): false when the id is not a pending
    /// phone plan — already answered, timed out, or never the phone's.
    public func resolveFromPairedPhone(id: UUID, apply: Bool) -> Bool {
        guard pending.contains(where: { $0.id == id && $0.fromPairedPhone }) else { return false }
        resolve(id: id, outcome: apply ? .approved : .denied)
        return true
    }

    /// The phone's pending plans as `GET /config/approvals` JSON, in
    /// upstream's row shape (`plan.payload()` plus `id`, `prune`, `summary`).
    /// Intel's plan only updates the Orchestrator's settings, so every row
    /// is one `update` action per changed path, and Intel never prunes.
    public func pairedPhoneListJSON() -> Data {
        let rows: [[String: Any]] = pending.filter(\.fromPairedPhone).map { request in
            var row = Self.pairedPhonePayload(request.plan)
            row["id"] = request.id.uuidString
            row["prune"] = false
            row["summary"] = Self.pairedPhoneSummary(request.plan)
            return row
        }
        return (try? JSONSerialization.data(withJSONObject: ["approvals": rows], options: [.sortedKeys]))
            ?? Data(#"{"approvals":[]}"#.utf8)
    }

    static func pairedPhonePayload(_ plan: IntelDeclarativeConfigurationPlan) -> [String: Any] {
        var dict: [String: Any] = [
            "change_count": plan.changes.count,
            "actions": plan.changes.map { change -> [String: Any] in
                ["section": "orchestrator", "target": change.path, "kind": "update",
                 "changes": ["\(change.before) → \(change.after)"]]
            },
        ]
        if !plan.warnings.isEmpty {
            dict["notes"] = plan.warnings
            dict["high_risk"] = true
        }
        return dict
    }

    static func pairedPhoneSummary(_ plan: IntelDeclarativeConfigurationPlan) -> String {
        guard !plan.changes.isEmpty else { return "No changes — current state already matches the document." }
        var lines = ["orchestrator:"]
        for change in plan.changes {
            lines.append("  ~ \(change.path)")
            lines.append("      \(change.before) → \(change.after)")
        }
        lines += plan.warnings.map { "note: \($0)" }
        return lines.joined(separator: "\n")
    }

    /// Denies every visible and suspended request, including requests from
    /// callers whose chat surface has already disappeared.
    public func cancelAll() {
        let ids = Set(pending.map(\.id)).union(continuations.keys)
        for id in ids {
            resolve(id: id, outcome: .cancelled)
        }
    }
}

/// Caller-independent facade used by the model tool. Without a mounted chat
/// surface it fails closed instead of presenting a generic prompt capable of
/// persisting an Always Allow choice.
public enum IntelConfigApprovalService {
    public static func requestApproval(
        plan: IntelDeclarativeConfigurationPlan
    ) async -> IntelConfigApprovalOutcome {
        guard let sessionID = ChatExecutionContext.currentSessionId, !sessionID.isEmpty else {
            return .cancelled
        }
        // The owner's paired phone is attended: its run parks the plan for the
        // phone to answer (`GET /config/approvals`, upstream MOBILE_PROTOCOL
        // §16.3). Only a Secure Channel run sets this (`W-identity-mobile`).
        if ChatExecutionContext.hasRemoteReviewer {
            return await IntelConfigApprovalQueue.shared.requestApproval(
                plan: plan, sessionID: sessionID, fromPairedPhone: true, timeout: 300)
        }
        let hasSurface = await MainActor.run {
            IntelConfigApprovalQueue.shared.hasMountedSurface(for: sessionID)
        }
        guard hasSurface else { return .cancelled }
        return await IntelConfigApprovalQueue.shared.requestApproval(plan: plan, sessionID: sessionID)
    }
}

#endif
