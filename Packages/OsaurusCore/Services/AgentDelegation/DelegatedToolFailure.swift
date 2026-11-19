//
//  DelegatedToolFailure.swift
//  OsaurusCore — Agent delegation
//
//  Typed metadata from the one terminal tool rejection in a chat run, kept
//  separately from its user-visible lifecycle error string, so a delegated
//  child's refusal (for example a denied approval) reaches the parent as the
//  same typed error instead of a retryable "failed" summary.
//  Ported from upstream Classic's `AgentDelegationDispatcher.swift`
//  (W-subagents stage 2); the dispatcher itself arrives in stage 3.
//

import Foundation

/// Typed metadata from the one terminal tool rejection in a chat run.
struct DelegatedToolFailure: Sendable {
    let runID: UUID
    let kind: ToolEnvelope.Kind
    let message: String
    let retryable: Bool?
}

struct DelegatedToolFailureState {
    private(set) var runID: UUID?
    private var accepting = false
    private var failure: DelegatedToolFailure?

    mutating func begin(runID: UUID) {
        self.runID = runID
        accepting = true
        failure = nil
    }

    mutating func finish(runID: UUID) {
        guard self.runID == runID else { return }
        accepting = false
    }

    mutating func record(_ envelope: String, runID: UUID) {
        guard accepting, self.runID == runID,
            let data = envelope.data(using: .utf8),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["ok"] as? Bool == false,
            let rawKind = object["kind"] as? String,
            let kind = ToolEnvelope.Kind(rawValue: rawKind)
        else { return }
        failure = DelegatedToolFailure(
            runID: runID, kind: kind,
            message: ToolEnvelope.failureMessage(envelope), retryable: object["retryable"] as? Bool)
    }

    var current: DelegatedToolFailure? {
        guard let failure, failure.runID == runID else { return nil }
        return failure
    }
}
