//
//  ProcessRunnerTests.swift
//
//  Shell-script fixtures via /bin/sh -c: exit codes, both streams,
//  timeout with SIGTERM→SIGKILL escalation, large output, and the
//  output cap.
//

import XCTest

@testable import OsaurusPluginKit

final class ProcessRunnerTests: XCTestCase {

    private func runShell(
        _ script: String,
        timeout: TimeInterval = 10,
        maxOutputBytes: Int = ProcessRunner.defaultMaxOutputBytes
    ) throws -> ProcessRunner.Output {
        try ProcessRunner.run(
            executable: "/bin/sh",
            arguments: ["-c", script],
            timeout: timeout,
            maxOutputBytes: maxOutputBytes)
    }

    func testCapturesStdoutAndExitStatus() throws {
        let output = try runShell("printf hello; exit 0")
        XCTAssertEqual(output.exitStatus, 0)
        XCTAssertEqual(output.stdoutText, "hello")
        XCTAssertEqual(output.stderrText, "")
        XCTAssertFalse(output.timedOut)
    }

    func testCapturesStderrAndNonZeroExit() throws {
        let output = try runShell("printf oops 1>&2; exit 7")
        XCTAssertEqual(output.exitStatus, 7)
        XCTAssertEqual(output.stdoutText, "")
        XCTAssertEqual(output.stderrText, "oops")
    }

    func testCapturesBothStreamsConcurrently() throws {
        let output = try runShell("printf out; printf err 1>&2")
        XCTAssertEqual(output.stdoutText, "out")
        XCTAssertEqual(output.stderrText, "err")
    }

    func testTimeoutTerminatesProcess() throws {
        let start = Date()
        let output = try runShell("sleep 30", timeout: 0.5)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(output.timedOut)
        XCTAssertNotEqual(output.exitStatus, 0)
        XCTAssertLessThan(elapsed, 5, "SIGTERM path should return well before the sleep finishes")
    }

    func testSigkillEscalationWhenSigtermIsTrapped() throws {
        // The child ignores SIGTERM, forcing the 2 s grace period and the
        // SIGKILL escalation.
        let start = Date()
        let output = try runShell("trap '' TERM; sleep 30", timeout: 0.5)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertTrue(output.timedOut)
        XCTAssertLessThan(elapsed, 10, "SIGKILL escalation should return promptly after grace")
    }

    func testLargeOutputDoesNotDeadlock() throws {
        // 1 MB of output — far beyond the 64 KB pipe buffer that
        // deadlocks naive waitUntilExit implementations.
        let output = try runShell("dd if=/dev/zero bs=1024 count=1024 2>/dev/null")
        XCTAssertEqual(output.exitStatus, 0)
        XCTAssertEqual(output.stdout.count, 1024 * 1024)
        XCTAssertFalse(output.timedOut)
    }

    func testOutputCapTruncatesStdout() throws {
        // 256 KB produced, 64 KB cap.
        let cap = 64 * 1024
        let output = try runShell(
            "dd if=/dev/zero bs=1024 count=256 2>/dev/null", maxOutputBytes: cap)
        XCTAssertEqual(output.exitStatus, 0)
        XCTAssertEqual(output.stdout.count, cap)
    }

    func testOutputCapAppliesPerStream() throws {
        let cap = 8 * 1024
        let output = try runShell(
            "dd if=/dev/zero bs=1024 count=32 2>/dev/null; "
                + "{ dd if=/dev/zero bs=1024 count=32 2>/dev/null; } 1>&2",
            maxOutputBytes: cap)
        XCTAssertEqual(output.stdout.count, cap)
        XCTAssertEqual(output.stderr.count, cap)
    }

    func testLaunchFailureThrows() {
        XCTAssertThrowsError(
            try ProcessRunner.run(
                executable: "/nonexistent/binary/\(UUID().uuidString)",
                arguments: [])
        ) { error in
            guard case ProcessRunnerError.launchFailed = error else {
                return XCTFail("expected launchFailed, got \(error)")
            }
        }
    }
}
