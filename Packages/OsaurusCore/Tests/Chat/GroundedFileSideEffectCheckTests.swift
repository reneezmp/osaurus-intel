//
//  GroundedFileSideEffectCheckTests.swift
//  osaurusTests
//
//  Coverage for the file side-effect advisory: a message that narrates a
//  file write ("appended to the file") while no file-writing tool succeeded
//  this run gets a factual `[System Notice]` staged for the next step. The
//  loop never stops on it — the model either calls the file tool or says
//  nothing was written.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite
struct GroundedFileSideEffectCheckTests {

    // MARK: containsFileSideEffectClaim

    @Test
    func appendedToFile_trips() {
        #expect(
            GroundedFileSideEffectCheck.containsFileSideEffectClaim(
                "I've appended the summary to the file. Fetching the next page now."
            )
        )
    }

    @Test
    func progressiveNarration_trips() {
        #expect(
            GroundedFileSideEffectCheck.containsFileSideEffectClaim(
                "Appending the extracted text to the file now, then fetching the next page."
            )
        )
    }

    @Test
    func savedTheReport_trips() {
        #expect(GroundedFileSideEffectCheck.containsFileSideEffectClaim("Saved the report."))
    }

    @Test
    func createdMarkdownDocument_trips() {
        #expect(
            GroundedFileSideEffectCheck.containsFileSideEffectClaim(
                "I created the markdown document with the three sections you asked for."
            )
        )
    }

    @Test
    func futureIntent_doesNotTrip() {
        #expect(
            !GroundedFileSideEffectCheck.containsFileSideEffectClaim(
                "I'll append it to the file once the page is fetched."
            )
        )
        #expect(
            !GroundedFileSideEffectCheck.containsFileSideEffectClaim(
                "Let me save the report next."
            )
        )
    }

    @Test
    func honestNegation_doesNotTrip() {
        #expect(
            !GroundedFileSideEffectCheck.containsFileSideEffectClaim(
                "Nothing was written to the file — no write tool is available in this chat."
            )
        )
        #expect(
            !GroundedFileSideEffectCheck.containsFileSideEffectClaim(
                "I couldn't save the report because the write failed."
            )
        )
    }

    @Test
    func question_doesNotTrip() {
        #expect(
            !GroundedFileSideEffectCheck.containsFileSideEffectClaim(
                "Should I append this to the file?"
            )
        )
    }

    @Test
    func ordinaryProse_doesNotTrip() {
        #expect(
            !GroundedFileSideEffectCheck.containsFileSideEffectClaim(
                "Here is the report you asked for, with three sections."
            )
        )
        #expect(
            !GroundedFileSideEffectCheck.containsFileSideEffectClaim(
                "The page describes how the compiler writes object files."
            )
        )
    }

    // MARK: isGroundedFileWriteOutcome

    @Test
    func successfulFileWrite_grounds() {
        #expect(
            GroundedFileSideEffectCheck.isGroundedFileWriteOutcome(
                toolName: "file_write",
                result: ToolEnvelope.success(tool: "file_write", text: "ok")
            )
        )
        #expect(
            GroundedFileSideEffectCheck.isGroundedFileWriteOutcome(
                toolName: "sandbox_write_file",
                result: ToolEnvelope.success(tool: "sandbox_write_file", text: "ok")
            )
        )
    }

    @Test
    func failedFileWrite_doesNotGround() {
        #expect(
            !GroundedFileSideEffectCheck.isGroundedFileWriteOutcome(
                toolName: "file_write",
                result: ToolEnvelope.failure(
                    kind: .invalidArgs,
                    message: "path is outside the workspace",
                    tool: "file_write"
                )
            )
        )
    }

    @Test
    func nonWriteTool_doesNotGround() {
        #expect(
            !GroundedFileSideEffectCheck.isGroundedFileWriteOutcome(
                toolName: "fetch_html",
                result: ToolEnvelope.success(tool: "fetch_html", text: "<html/>")
            )
        )
    }
}

// Intel: upstream's driver-behavior cases run `AgentToolLoop`, which Intel's
// cloud engine replaces. The same scenarios (bounded noticed retry, grounded
// outcomes accepted, surfaces without the hooks unaffected) are covered by
// `IntelGroundedClaimGuardTests` and the engine cases in
// `IntelLoopHarnessTests`.
