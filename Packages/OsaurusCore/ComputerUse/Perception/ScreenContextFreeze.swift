//
//  ScreenContextFreeze.swift
//  OsaurusCore — Computer Use
//
//  W-computer-use stage 6. The chat side of screen context: decides whether a
//  send may capture the screen at all, and freezes the rendered
//  `[Screen Context]` block once per chat (upstream #1610: captured at the
//  first send, reused byte-for-byte afterwards so the provider's prompt cache
//  keeps the earlier turns).
//
//  Owner policy (Intel): off by default; the user turns it on per agent
//  (`AgentSettings.screenContextEnabled`, under Computer Use). What is
//  captured is text only (no screenshot), is sent only to the model the user
//  chose for this chat, and is never captured for an unattended source
//  (schedule, watcher, plugin, API call, delegated child). Capturing only
//  *checks* Accessibility (`ScreenContextDistiller` returns an empty snapshot
//  when it is missing); it never asks for it.
//
//  Pure and injectable so the tests use a fake capture closure: no real
//  screen, Accessibility, or TCC prompt.
//

import Foundation

enum ScreenContextGate {
    /// Whether this send may capture the screen. `agentEnabled` is
    /// `AgentManager.effectiveScreenContextEnabled`. The source rule is the
    /// same attended-chat rule `computer_use` itself follows
    /// (`ComputerUseKind.unattendedRefusal`).
    static func mayCapture(
        agentEnabled: Bool,
        source: SessionSource?,
        isUnattendedDispatch: Bool,
        isExternalSurface: Bool
    ) -> Bool {
        guard agentEnabled else { return false }
        return ComputerUseKind.unattendedRefusal(
            source: source,
            isUnattendedDispatch: isUnattendedDispatch,
            isExternalSurface: isExternalSurface
        ) == nil
    }
}

@MainActor
final class ScreenContextFreeze {
    /// The frozen block (tags included), nil when nothing shareable was seen.
    private(set) var block: String?
    /// Estimated token cost of `block`, for the "Screen Context" budget row.
    private(set) var tokens: Int = 0
    /// True once a send has captured (or deliberately skipped) this chat's
    /// snapshot; later sends reuse it without touching the screen again.
    private(set) var isFrozen = false

    /// The block to prepend to this send's user turn, or nil. Captures at most
    /// once per chat, and only when `allowed`. A send that is not allowed
    /// neither captures nor freezes, and shares nothing (a frozen block from
    /// an earlier allowed send is not replayed once the user turned the
    /// option off).
    func blockForSend(
        allowed: Bool,
        capture: () async -> String
    ) async -> String? {
        guard allowed else { return nil }
        if !isFrozen {
            let rendered = await capture().trimmingCharacters(in: .whitespacesAndNewlines)
            block = rendered.isEmpty ? nil : rendered
            tokens = block.map { ContextBudgetManager.estimateTokens(for: $0) } ?? 0
            isFrozen = true
        }
        return block
    }

    /// A new or loaded conversation re-freezes on its next send.
    func reset() {
        block = nil
        tokens = 0
        isFrozen = false
    }
}
