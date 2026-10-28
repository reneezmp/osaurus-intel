//
//  GroundedFileSideEffectCheckTests.swift
//  osaurusTests
//
//  Coverage for the file side-effect advisory: a message that narrates a
//  file write ("appended to the file") while no file-writing tool succeeded
//  this run gets a factual `[System Notice]` staged for the next step. The
//  notice describes recorded execution only; it does not authorize or
//  instruct a file write.
//

import Foundation
import Testing

@testable import OsaurusCore

private enum LiveReadOnlyFileRegression {
    static let request =
        "Use a file-reading tool to read probe.json in the working folder and report its nonce and integer value. Do not modify it."

    // Exact first final answer from the native 9aac/877 SQL transcript,
    // session D97F5BFB-F49E-4C8E-92DA-D59008FF7BCF. The old bare "to file"
    // regex misclassified the closing memory comparison as a write claim.
    static let answer = "\n\n" + #"""
        I read `probe.json` in the working folder. Here are its contents (unmodified):

        **probe.json**
        ```json
        {"nonce":"responses-integrated-20261025","value":42}
        ```

        **Reported values:**
        - **Nonce:** `responses-integrated-20261025`
        - **Integer value:** `42`

        The file is 53 bytes, one line, valid JSON, and was read without any modification. (Note: the file's actual `value` is 42, which matches the "Integer value: 42" memory entry; the "Current integer value in probe.json is 43" memory entry appears stale relative to the file on disk.)
        """#
}

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

    @Test func exactLiveReadOnlyAnswerWithFencedJSONAndMemoryComparisonIsNotAWriteClaim() {
        #expect(!GroundedFileSideEffectCheck.containsFileSideEffectClaim(LiveReadOnlyFileRegression.answer))
    }

    @Test(arguments: [
        "The memory entry appears stale relative to the file on disk.",
        "These values are identical to the file contents.",
        "The report refers to the file we read.",
        "The written report contains the nonce ABC and value 42.",
        "The written report points to the file.",
        "The written instructions refer to the file.",
    ])
    func fileDestinationWithoutWritePredicateIsNotAClaim(text: String) {
        #expect(!GroundedFileSideEffectCheck.containsFileSideEffectClaim(text))
    }

    @Test(arguments: [
        "The summary was written to the file.",
        "Appended it to your file.",
        "Wrote the extracted content to the file.",
        "I added the summary to the file.",
        "I pasted the result to the file.",
        "I have written the report.",
    ])
    func affirmativeWritePredicateWithDestinationStillTrips(text: String) {
        #expect(GroundedFileSideEffectCheck.containsFileSideEffectClaim(text))
    }

    // MARK: isGroundedFileWriteOutcome

    // Upstream #3104 (`W-media-generation`). The third argument is Intel's:
    // a cloud image is a `generated_media_job`, not upstream's local kind.
    @Test(arguments: [
        ("image", "native_image_generation_job"), ("video", "generated_media_job"),
        ("image", "generated_media_job"),
    ])
    func completedMediaArtifact_groundsButQueuedOrEmptyDoesNot(tool: String, kind: String) {
        var payload: [String: Any] = [
            "kind": kind,
            "status": "completed",
            "images": [["path": "/tmp/generated.png"]],
            "media": ["path": "/tmp/generated.mp4"],
        ]
        func grounded() -> Bool {
            GroundedFileSideEffectCheck.isGroundedFileWriteOutcome(
                toolName: tool, result: ToolEnvelope.success(tool: tool, result: payload))
        }
        #expect(grounded())
        payload["status"] = "queued"
        #expect(!grounded())
        payload["status"] = "failed"
        #expect(!grounded())
        payload["status"] = "completed"
        payload["images"] = [["path": ""]]
        payload["media"] = ["path": ""]
        #expect(!grounded())
        #expect(!GroundedFileSideEffectCheck.isGroundedFileWriteOutcome(
            toolName: tool,
            result: ToolEnvelope.failure(kind: .invalidArgs, message: "invalid size", tool: tool)))
    }

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
