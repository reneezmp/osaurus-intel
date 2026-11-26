//
//  IntelSandboxBackgroundJobs.swift
//  osaurus
//
//  Intel fork (W-seatbelt-sandbox stage 4): the registry of background jobs
//  started by `sandbox_exec(background: true)`. Upstream's
//  `SandboxBackgroundJobs` (in `BuiltinSandboxTools.swift`) maps pid to log
//  file and leaves the process to the Linux guest. On the host the app owns
//  the process, so this registry also holds it and enforces the owner
//  policy (docs/W_SEATBELT_SANDBOX_PLAN.md):
//
//  - jobs live inside the sandbox profile they were launched with (the
//    manager builds the same profile as a foreground exec);
//  - a job is stopped when the run that started it ends, when the sandbox is
//    stopped / reset / removed, and at app quit;
//  - at most `maxJobsPerAgent` run at once, and none lives longer than
//    `maxLifetime` even inside a long run;
//  - only pids this registry started can be polled, waited on or killed, so
//    `sandbox_process` can never signal an arbitrary process.
//

import Foundation

final class SandboxBackgroundJobs: @unchecked Sendable {
    /// The shared manager's registry. Test managers own a private one.
    static let shared = SandboxBackgroundJobs()

    static let maxJobsPerAgent = 4
    /// Finished jobs kept (so a late poll can still report the exit and the
    /// log tail) per agent before the oldest are dropped.
    static let maxFinishedKept = 8
    static let defaultMaxLifetime: TimeInterval = 3600

    struct Job: Sendable {
        let pid: String
        let logFile: String
        let command: String
        let startedAt: Date
        /// The chat session / run that started it; nil for other surfaces.
        let owner: String?
        let process: SeatbeltExecutor.BackgroundProcess

        var exitCode: Int32? { process.exitCode }
        var isRunning: Bool { process.isRunning }
    }

    private let lock = NSLock()
    private var jobs: [String: [String: Job]] = [:]  // agentName -> pid -> Job
    let maxLifetime: TimeInterval

    init(maxLifetime: TimeInterval = SandboxBackgroundJobs.defaultMaxLifetime) {
        self.maxLifetime = maxLifetime
    }

    // MARK: - Registration

    /// True when the agent may start another job.
    func canStart(agentName: String) -> Bool {
        runningCount(agentName: agentName) < Self.maxJobsPerAgent
    }

    func runningCount(agentName: String) -> Int {
        lock.withLock { (jobs[agentName] ?? [:]).values.filter { $0.isRunning }.count }
    }

    @discardableResult
    func register(
        agentName: String,
        process: SeatbeltExecutor.BackgroundProcess,
        logFile: String,
        command: String,
        owner: String?
    ) -> Job {
        let job = Job(
            pid: String(process.pid),
            logFile: logFile,
            command: command,
            startedAt: Date(),
            owner: owner,
            process: process
        )
        lock.withLock {
            var perAgent = jobs[agentName] ?? [:]
            perAgent[job.pid] = job
            // Drop the oldest finished jobs beyond the keep limit.
            let finished = perAgent.values.filter { !$0.isRunning }.sorted { $0.startedAt < $1.startedAt }
            for old in finished.dropLast(Self.maxFinishedKept) { perAgent.removeValue(forKey: old.pid) }
            jobs[agentName] = perAgent
        }
        // Lifetime ceiling. Only signals while the leader still runs, so a
        // recycled pid is never touched.
        let ceiling = maxLifetime
        Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(ceiling * 1_000_000_000))
            if process.isRunning { await process.terminate() }
        }
        return job
    }

    func lookup(agentName: String, pid: String) -> Job? {
        lock.withLock { jobs[agentName]?[pid] }
    }

    func remove(agentName: String, pid: String) {
        lock.withLock {
            jobs[agentName]?.removeValue(forKey: pid)
            if jobs[agentName]?.isEmpty == true { jobs.removeValue(forKey: agentName) }
        }
    }

    /// Every job that is still running, with its agent (for the Sandbox page).
    func allRunning() -> [(agentName: String, job: Job)] {
        lock.withLock {
            jobs.flatMap { agent, perAgent in perAgent.values.filter { $0.isRunning }.map { (agent, $0) } }
                .sorted { $0.1.startedAt < $1.1.startedAt }
        }
    }

    func jobs(agentName: String) -> [Job] {
        lock.withLock { Array((jobs[agentName] ?? [:]).values).sorted { $0.startedAt < $1.startedAt } }
    }

    // MARK: - Stopping

    private func matching(where predicate: (String, Job) -> Bool) -> [Job] {
        lock.withLock {
            jobs.flatMap { agent, perAgent in perAgent.values.map { (agent, $0) } }
                .filter { predicate($0.0, $0.1) }
                .map(\.1)
        }
    }

    /// SIGTERM, grace, SIGKILL for one job. Returns true once the leader is gone.
    func stop(agentName: String, pid: String, force: Bool = false) async -> Bool {
        guard let job = lookup(agentName: agentName, pid: pid) else { return true }
        if force {
            job.process.signalGroup(SIGKILL)
            var waited = 0.0
            while job.isRunning, waited < 3 {
                try? await Task.sleep(nanoseconds: 100_000_000)
                waited += 0.1
            }
        } else {
            await job.process.terminate()
        }
        return !job.isRunning
    }

    /// Stop every job the given run started. Called when the run ends.
    func stopRun(owner: String) async {
        let targets = matching { _, job in job.owner == owner }
        await withTaskGroup(of: Void.self) { group in
            for job in targets { group.addTask { await job.process.terminate(graceSeconds: 1) } }
        }
    }

    /// Stop every job of one agent (agent removed, sandbox switched off).
    func stopAll(agentName: String) async {
        let targets = matching { agent, _ in agent == agentName }
        await withTaskGroup(of: Void.self) { group in
            for job in targets { group.addTask { await job.process.terminate(graceSeconds: 1) } }
        }
    }

    /// Stop every job (sandbox stopped / reset / removed).
    func stopEverything() async {
        let targets = matching { _, _ in true }
        await withTaskGroup(of: Void.self) { group in
            for job in targets { group.addTask { await job.process.terminate(graceSeconds: 1) } }
        }
    }

    /// Synchronous hard stop for `applicationWillTerminate`: SIGKILL every
    /// job's process group and reap the leaders.
    func killAllNow() {
        for job in matching(where: { _, _ in true }) { job.process.killNow() }
    }
}
