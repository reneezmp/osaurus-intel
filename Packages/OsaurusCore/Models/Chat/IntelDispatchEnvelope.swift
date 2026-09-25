//
//  IntelDispatchEnvelope.swift
//  OsaurusCore (Intel fork)
//
//  Display-time stripping of the machine framing a watcher run writes into
//  its user turn (Intel analogue of upstream `DispatchEnvelope`, 13cc78ae3).
//  The stored turn and the model request are never touched — this only
//  recovers the human-authored instructions so the chat renders a message
//  instead of a template. Intel produces only the watcher framing; upstream's
//  channel, delegation, and self-scheduled envelopes do not exist here.
//

import Foundation

enum IntelDispatchEnvelope {
    /// The user-authored instructions for display, or `content` unchanged
    /// when it does not end with an exact watcher framing. Cheap: two
    /// `hasSuffix` checks for an ordinary typed message.
    static func displayText(for content: String) -> String {
        let footer = WatcherManager.idempotencyFooter
        guard content.hasSuffix(footer) else { return content }
        let body = String(content.dropLast(footer.count))
        for framing in [WatcherManager.firstRunFraming, WatcherManager.followUpFraming]
        where body.hasSuffix(framing) {
            let instructions = String(body.dropLast(framing.count))
            return instructions.isEmpty ? content : instructions
        }
        return content
    }
}
