//
//  IntelDispatchEnvelopeTests.swift
//  osaurusTests
//
//  Upstream 13cc78ae3, Intel analogue: a watcher run's user turn renders
//  its instructions, not the machine framing. Built from the producer's own
//  constants so producer and parser cannot drift apart.
//

import Foundation
import Testing

@testable import OsaurusCore

struct IntelDispatchEnvelopeTests {

    @Test func firstRunAndFollowUpFramingAreHidden() {
        let instructions = "Sort new invoices into Year/Month folders."
        for framing in [WatcherManager.firstRunFraming, WatcherManager.followUpFraming] {
            let stored = instructions + framing + WatcherManager.idempotencyFooter
            #expect(IntelDispatchEnvelope.displayText(for: stored) == instructions)
        }
    }

    @Test func ordinaryMessagesAreUnchanged() {
        let typed = "Please organize my downloads."
        #expect(IntelDispatchEnvelope.displayText(for: typed) == typed)
        // A footer alone (no framing) is left as-is rather than guessed at.
        let footerOnly = "Hi" + WatcherManager.idempotencyFooter
        #expect(IntelDispatchEnvelope.displayText(for: footerOnly) == footerOnly)
    }
}
