//
//  ProcessRunner.swift
//  OsaurusPluginKit
//
//  Consolidated subprocess runner (best-of-breed from the osaurus-maps /
//  osaurus-emacs / osaurus-mail variants):
//
//  - Drains stdout/stderr concurrently via `readabilityHandler` while the
//    process runs, so output larger than the pipe buffer cannot deadlock
//    the exit wait.
//  - Enforces a timeout (default 30 s) with SIGTERM, escalating to
//    SIGKILL after a 2 s grace period.
//  - Caps captured output (default 5 MB per stream); once a stream hits
//    the cap, further output is dropped.
//

import Foundation

public enum ProcessRunnerError: Error, CustomStringConvertible {
    case launchFailed(String)

    public var description: String {
        switch self {
        case .launchFailed(let reason): return "Failed to launch process: \(reason)"
        }
    }
}

public enum ProcessRunner {

    public struct Output {
        public let exitStatus: Int32
        public let stdout: Data
        public let stderr: Data
        public let timedOut: Bool

        /// UTF-8 decode of stdout (lossy fallback to empty string).
        public var stdoutText: String { String(data: stdout, encoding: .utf8) ?? "" }
        /// UTF-8 decode of stderr (lossy fallback to empty string).
        public var stderrText: String { String(data: stderr, encoding: .utf8) ?? "" }
    }

    public static let defaultTimeout: TimeInterval = 30
    public static let defaultMaxOutputBytes = 5 * 1024 * 1024
    /// Grace period between SIGTERM and SIGKILL on timeout.
    public static let killGracePeriod: TimeInterval = 2

    public static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = defaultTimeout,
        maxOutputBytes: Int = defaultMaxOutputBytes
    ) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        let lock = NSLock()
        var stdoutData = Data()
        var stderrData = Data()

        func appendCapped(_ chunk: Data, to buffer: inout Data) {
            let remaining = maxOutputBytes - buffer.count
            guard remaining > 0 else { return }
            buffer.append(chunk.prefix(remaining))
        }

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock()
            appendCapped(chunk, to: &stdoutData)
            lock.unlock()
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            lock.lock()
            appendCapped(chunk, to: &stderrData)
            lock.unlock()
        }

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe.fileHandleForReading.readabilityHandler = nil
            throw ProcessRunnerError.launchFailed(error.localizedDescription)
        }

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()  // SIGTERM
            if exited.wait(timeout: .now() + killGracePeriod) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = exited.wait(timeout: .now() + killGracePeriod)
            }
        }
        process.waitUntilExit()

        // Detach handlers, then pick up any bytes still buffered in the
        // pipes after exit. Skipped on the timeout path: an orphaned
        // grandchild (e.g. a `sleep` spawned by a killed `sh`) can inherit
        // the pipe write ends and keep them open, making `readToEnd` block
        // for the grandchild's full lifetime.
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if !timedOut {
            if let rest = try? stdoutPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                lock.lock()
                appendCapped(rest, to: &stdoutData)
                lock.unlock()
            }
            if let rest = try? stderrPipe.fileHandleForReading.readToEnd(), !rest.isEmpty {
                lock.lock()
                appendCapped(rest, to: &stderrData)
                lock.unlock()
            }
        }

        lock.lock()
        defer { lock.unlock() }
        return Output(
            exitStatus: process.terminationStatus,
            stdout: stdoutData,
            stderr: stderrData,
            timedOut: timedOut
        )
    }
}
