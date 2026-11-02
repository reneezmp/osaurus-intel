//
//  InlineIntentValueShapeTests.swift
//
//  `SelectableTextView.inlineIntent` checks the bridged NSNumber shape before
//  the struct cast (upstream #3266: the failing cast was a slow runtime lookup
//  that hung long/streaming messages). Pins every value shape it accepts.
//

import Foundation
import Testing

@testable import OsaurusCore

struct InlineIntentValueShapeTests {
    @Test func inlineIntentReadsBridgedNSNumber() {
        let raw = InlinePresentationIntent([.code, .stronglyEmphasized]).rawValue
        let attributes: [NSAttributedString.Key: Any] = [
            .inlinePresentationIntent: NSNumber(value: raw)
        ]
        #expect(SelectableTextView.inlineIntent(attributes) == [.code, .stronglyEmphasized])
    }

    @Test func inlineIntentReadsNativeValue() {
        let attributes: [NSAttributedString.Key: Any] = [
            .inlinePresentationIntent: InlinePresentationIntent.emphasized
        ]
        #expect(SelectableTextView.inlineIntent(attributes) == .emphasized)
    }

    @Test func inlineIntentMissingKeyIsEmpty() {
        #expect(SelectableTextView.inlineIntent([:]).isEmpty)
    }

    @Test func inlineIntentUnrecognisedValueIsEmpty() {
        let attributes: [NSAttributedString.Key: Any] = [.inlinePresentationIntent: "code"]
        #expect(SelectableTextView.inlineIntent(attributes).isEmpty)
    }
}
