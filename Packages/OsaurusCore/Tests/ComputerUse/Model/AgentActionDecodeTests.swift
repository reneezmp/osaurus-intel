//
//  AgentActionDecodeTests.swift
//  OsaurusCoreTests — Computer Use
//
//  Decode/coerce/validate coverage for the single model-facing envelope
//  (`AgentAction.decode`). This is the JSON-discipline boundary every small
//  local model hits first, so the regressions we've actually shipped get a
//  deterministic guard here:
//   • malformed JSON and the ChatEngine `_error`/`invalid_tool_arguments`
//     envelope (the misleading "Missing required property: verb" bug),
//   • string→int `mark` coercion from quantized models,
//   • nested `target:{mark}` decode (regression for the upstream Gemma parser
//     fix that used to stringify the nested object),
//   • invalid / missing verbs, and
//   • `semanticProblem()` per verb (the verb-specific required fields the JSON
//     schema can't express).
//
//  Pure, model-free: `decode` is a static function over a string.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite struct AgentActionDecodeTests {

    // MARK: - Helpers

    private func decoded(_ json: String) -> AgentAction? {
        if case .action(let action) = AgentAction.decode(argumentsJSON: json) { return action }
        return nil
    }

    private func invalidReason(_ json: String) -> String? {
        if case .invalid(let reason) = AgentAction.decode(argumentsJSON: json) { return reason }
        return nil
    }

    // MARK: - Malformed JSON

    @Test func testMalformedJSONIsInvalid() {
        let reason = invalidReason("{not valid json")
        #expect(reason != nil)
        #expect(reason?.localizedCaseInsensitiveContains("valid json") ?? false, "Expected a 'not valid JSON' reason; got: \(reason ?? "nil")")
    }

    @Test func testNonObjectJSONIsInvalid() {
        // A bare array is valid JSON but not an agent_action object.
        #expect(invalidReason("[1, 2, 3]") != nil)
    }

    // MARK: - ChatEngine `_error` envelope

    @Test func testErrorEnvelopeSurfacesMessageAndField() {
        let json = """
            {"_error":"invalid_tool_arguments","_message":"Property 'mark' must be an integer","_field":"mark"}
            """
        let reason = invalidReason(json)
        #expect(reason != nil)
        #expect(reason?.contains("Property 'mark' must be an integer") ?? false)
        #expect(reason?.contains("mark") ?? false, "The offending field should be surfaced; got: \(reason ?? "nil")")
        // Crucially NOT the misleading generic "Missing required property: verb".
        #expect(!(reason?.localizedCaseInsensitiveContains("missing required") ?? true))
    }

    @Test func testErrorEnvelopeMarkFieldCarriesConcreteShapeHint() {
        // A bare "must be an integer" doesn't help a model that keeps emitting
        // `"mark": true`; the re-ask should show the corrected shape + the
        // `describe` fallback. Model-agnostic feedback — it never changes which
        // values are accepted, only what the model is told to fix.
        let json = """
            {"_error":"invalid_tool_arguments","_message":"Property 'mark' must be an integer","_field":"mark"}
            """
        let reason = invalidReason(json)
        #expect(reason != nil)
        #expect(reason?.contains("Property 'mark' must be an integer") ?? false)
        #expect(reason?.contains("{\"mark\": 1}") ?? false, "Should show a concrete corrected mark; got: \(reason ?? "nil")")
        #expect(reason?.localizedCaseInsensitiveContains("true/false") ?? false, "Should call out the boolean mistake; got: \(reason ?? "nil")")
        #expect(reason?.contains("describe") ?? false, "Should offer the describe fallback; got: \(reason ?? "nil")")
    }

    @Test func testErrorEnvelopeTargetFieldCarriesObjectHint() {
        let json = """
            {"_error":"invalid_tool_arguments","_message":"Property 'target' must be an object","_field":"target"}
            """
        let reason = invalidReason(json)
        #expect(reason?.contains("mark") ?? false, "got: \(reason ?? "nil")")
        #expect(reason?.contains("describe") ?? false, "got: \(reason ?? "nil")")
    }

    /// A native JSON boolean `mark` is REJECTED, not silently mapped to `1`.
    /// `ArgumentCoercion.int(true)` happens to return `1` (NSNumber.intValue),
    /// but the preflight `SchemaValidator` excludes booleans on purpose:
    /// mapping `true` → "element 1" is a synthetic repair that could click the
    /// wrong element in a multi-element view. We surface a clear re-ask instead.
    @Test func testBooleanMarkIsRejectedNotCoercedToOne() {
        let reason = invalidReason(#"{"verb":"click","target":{"mark":true}}"#)
        #expect(reason != nil, "A boolean mark must not decode to a valid action")
        #expect(reason?.localizedCaseInsensitiveContains("integer") ?? false, "Reason should explain mark must be an integer; got: \(reason ?? "nil")")
    }

    @Test func testErrorEnvelopeWithoutFieldOmitsFieldSuffix() {
        let json = """
            {"_error":"invalid_tool_arguments","_message":"Bad shape.","_field":""}
            """
        let reason = invalidReason(json)
        #expect(reason == "Bad shape.")
    }

    @Test func testErrorEnvelopeWithoutMessageFallsBack() {
        let json = #"{"_error":"invalid_tool_arguments"}"#
        let reason = invalidReason(json)
        #expect(reason != nil)
        #expect(reason?.localizedCaseInsensitiveContains("required shape") ?? false)
    }

    // MARK: - Coercion

    @Test func testStringMarkIsCoercedToInt() {
        let action = decoded(#"{"verb":"click","target":{"mark":"3"},"note":"open it"}"#)
        #expect((action?.verb) == .click)
        #expect((action?.target?.mark) == 3, "A string mark from a quantized model should coerce to Int")
    }

    @Test func testStringReplaceIsCoercedToBool() {
        let action = decoded(#"{"verb":"type","text":"hi","replace":"false"}"#)
        #expect((action?.verb) == .type)
        #expect((action?.replace) == false)
    }

    @Test func testStringifiedModifiersArrayCoerced() {
        let action = decoded(#"{"verb":"press_key","key":"a","modifiers":"[\"cmd\"]"}"#)
        #expect((action?.key) == "a")
        #expect((action?.modifiers) == ["cmd"])
    }

    // MARK: - Nested target (Gemma parser regression)

    @Test func testNestedTargetMarkDecodes() {
        // The upstream Gemma parser fix stopped stringifying `target:{mark:1}`;
        // at the decode level a proper nested object must decode to a real mark.
        let action = decoded(#"{"verb":"click","target":{"mark":1},"note":"x"}"#)
        #expect((action?.target?.mark) == 1)
        #expect((action?.target?.describe) == nil)
    }

    @Test func testNestedTargetDescribeDecodes() {
        let action = decoded(#"{"verb":"click","target":{"describe":"the Send button"}}"#)
        #expect((action?.target?.mark) == nil)
        #expect((action?.target?.describe) == "the Send button")
    }

    @Test func testNestedTargetWithBothMarkAndDescribe() {
        let action = decoded(#"{"verb":"click","target":{"mark":4,"describe":"Save"}}"#)
        #expect((action?.target?.mark) == 4)
        #expect((action?.target?.describe) == "Save")
    }

    // MARK: - Verb validity

    @Test func testInvalidVerbIsRejected() {
        let reason = invalidReason(#"{"verb":"frobnicate"}"#)
        #expect(reason != nil)
        #expect(reason?.localizedCaseInsensitiveContains("verb") ?? false, "Reason should reference the verb constraint; got: \(reason ?? "nil")")
    }

    @Test func testMissingVerbIsRejected() {
        let reason = invalidReason(#"{"text":"hello"}"#)
        #expect(reason != nil)
        #expect(reason?.localizedCaseInsensitiveContains("verb") ?? false)
    }

    @Test func testVerbCaseIsNormalized() {
        // Quantized models routinely capitalize; the enum match is lenient.
        #expect((decoded(#"{"verb":"OBSERVE"}"#)?.verb) == .observe)
    }

    @Test func testUnexpectedPropertyRejected() {
        let reason = invalidReason(#"{"verb":"observe","bogus":1}"#)
        #expect(reason != nil)
        #expect(reason?.localizedCaseInsensitiveContains("bogus") ?? false)
    }

    // MARK: - semanticProblem() per verb

    @Test func testClickRequiresTarget() {
        #expect(invalidReason(#"{"verb":"click"}"#)?.contains("target") ?? false)
    }

    @Test func testClearRequiresTarget() {
        #expect(invalidReason(#"{"verb":"clear"}"#)?.contains("target") ?? false)
    }

    @Test func testTypeRequiresText() {
        #expect(invalidReason(#"{"verb":"type"}"#)?.contains("text") ?? false)
    }

    @Test func testSetValueRequiresText() {
        #expect(invalidReason(#"{"verb":"set_value","target":{"mark":1}}"#)?.contains("text") ?? false)
    }

    @Test func testSetValueRequiresTarget() {
        let reason = invalidReason(#"{"verb":"set_value","text":"x"}"#)
        #expect(reason?.contains("target") ?? false, "got: \(reason ?? "nil")")
    }

    @Test func testPressKeyRequiresKey() {
        #expect(invalidReason(#"{"verb":"press_key"}"#)?.contains("key") ?? false)
    }

    @Test func testScrollRequiresDirection() {
        #expect(invalidReason(#"{"verb":"scroll"}"#)?.contains("direction") ?? false)
    }

    @Test func testOpenRequiresApp() {
        #expect(invalidReason(#"{"verb":"open"}"#)?.contains("app") ?? false)
    }

    @Test func testFindRequiresQueryOrRoles() {
        #expect(invalidReason(#"{"verb":"find"}"#) != nil)
        // A roles-only find is valid.
        #expect((decoded(#"{"verb":"find","roles":["button"]}"#)?.verb) == .find)
    }

    @Test func testDoneRequiresReason() {
        #expect(invalidReason(#"{"verb":"done"}"#)?.contains("reason") ?? false)
    }

    @Test func testGiveUpRequiresReason() {
        #expect(invalidReason(#"{"verb":"give_up"}"#)?.contains("reason") ?? false)
    }

    // MARK: - New verbs (Phase 2)

    @Test func testDoubleClickRequiresTarget() {
        #expect(invalidReason(#"{"verb":"double_click"}"#)?.contains("target") ?? false)
    }

    @Test func testRightClickRequiresTarget() {
        #expect(invalidReason(#"{"verb":"right_click"}"#)?.contains("target") ?? false)
    }

    @Test func testDoubleClickDecodes() {
        let action = decoded(#"{"verb":"double_click","target":{"mark":2}}"#)
        #expect((action?.verb) == .doubleClick)
        #expect((action?.target?.mark) == 2)
    }

    @Test func testRightClickDecodes() {
        let action = decoded(#"{"verb":"right_click","target":{"describe":"the row"}}"#)
        #expect((action?.verb) == .rightClick)
        #expect((action?.target?.describe) == "the row")
    }

    @Test func testDragRequiresStartTarget() {
        let reason = invalidReason(#"{"verb":"drag","to":{"mark":2}}"#)
        #expect(reason?.contains("target") ?? false, "got: \(reason ?? "nil")")
    }

    @Test func testDragRequiresDestination() {
        let reason = invalidReason(#"{"verb":"drag","target":{"mark":1}}"#)
        #expect(reason?.contains("to") ?? false, "got: \(reason ?? "nil")")
    }

    @Test func testDragDecodesBothEndpoints() {
        let action = decoded(#"{"verb":"drag","target":{"mark":1},"to":{"mark":7}}"#)
        #expect((action?.verb) == .drag)
        #expect((action?.target?.mark) == 1)
        #expect((action?.to?.mark) == 7)
    }

    @Test func testWaitDecodesAndNeedsNoFields() {
        #expect((decoded(#"{"verb":"wait"}"#)?.verb) == .wait)
        let action = decoded(#"{"verb":"wait","seconds":3}"#)
        #expect((action?.seconds) == 3)
    }

    @Test func testWaitSecondsCoercedFromString() {
        #expect((decoded(#"{"verb":"wait","seconds":"2"}"#)?.seconds) == 2)
    }

    // MARK: - Valid actions

    @Test func testObserveDecodes() {
        #expect((decoded(#"{"verb":"observe"}"#)?.verb) == .observe)
    }

    @Test func testTypeWithoutTargetIsValid() {
        let action = decoded(#"{"verb":"type","text":"hello world"}"#)
        #expect((action?.verb) == .type)
        #expect((action?.text) == "hello world")
    }

    @Test func testScrollDecodesDirectionAndAmount() {
        let action = decoded(#"{"verb":"scroll","direction":"down","amount":5}"#)
        #expect((action?.direction) == .down)
        #expect((action?.amount) == 5)
    }

    @Test func testDoneDecodesReason() {
        let action = decoded(#"{"verb":"done","reason":"All set."}"#)
        #expect((action?.verb) == .done)
        #expect((action?.reason) == "All set.")
    }

    // MARK: - argumentsJSON() round-trip

    @Test func testArgumentsJSONRoundTrips() {
        let cases: [AgentAction] = [
            AgentAction(verb: .observe),
            AgentAction(verb: .click, target: AgentTarget(mark: 3), note: "open it"),
            AgentAction(verb: .click, target: AgentTarget(describe: "the Send button")),
            AgentAction(verb: .type, text: "hello", replace: true, note: "fill the field"),
            AgentAction(verb: .setValue, target: AgentTarget(mark: 2), text: "v"),
            AgentAction(verb: .pressKey, key: "return", modifiers: ["cmd", "shift"]),
            AgentAction(verb: .scroll, direction: .down, amount: 4),
            AgentAction(verb: .open, app: "Safari"),
            AgentAction(verb: .find, query: "Send", roles: ["button"]),
            AgentAction(verb: .doubleClick, target: AgentTarget(mark: 5)),
            AgentAction(verb: .rightClick, target: AgentTarget(describe: "the row")),
            AgentAction(verb: .drag, target: AgentTarget(mark: 1), to: AgentTarget(mark: 9)),
            AgentAction(verb: .wait, seconds: 3),
            AgentAction(verb: .done, reason: "Completed."),
        ]
        for original in cases {
            let json = original.argumentsJSON()
            guard let round = decoded(json) else {
                Issue.record("argumentsJSON for \(original.verb) did not decode: \(json)"); return
            }
            #expect(round == original, "Round-trip mismatch for \(original.verb): \(json)")
        }
    }
}
