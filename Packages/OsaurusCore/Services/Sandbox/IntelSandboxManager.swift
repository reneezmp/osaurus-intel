//
//  IntelSandboxManager.swift
//  osaurus
//
//  Intel fork: the compiled host-sandbox slice of upstream's
//  `SandboxManager` (Services/Sandbox/SandboxManager.swift, which stays in
//  Package.swift's exclude list because it is the Containerization VM
//  stack). Only upstream's Seatbelt branches live here: availability
//  cache (#3094, #3105), host "provisioning", `exec` under a deny-default
//  `sandbox-exec` profile, per-agent homes under the workspace folder,
//  Seatbelt info/diagnostics. Method names and signatures follow upstream
//  so `BuiltinSandboxTools` and the registrar port over unchanged.
//
//  Owner policy (docs/W_SEATBELT_SANDBOX_PLAN.md): the sandbox only ever
//  restricts. Network is OFF unless the caller passes `networkEnabled: true`
//  (the user's explicit per-agent setting) AND the shared sandbox config
//  still says "outbound"; either side denying wins. Upstream defaults both
//  to on, Intel does not.
//

import Foundation

public actor SandboxManager {
    public static let shared = SandboxManager()

    /// Intel gate (stage 2 of W-seatbelt-sandbox): while false, nothing is
    /// published into `State.availability`, so Onboarding, the agent editor
    /// and the chat chip keep treating the sandbox as unavailable. Stage 5
    /// flipped it: the tools and the UI exist, and every switch they offer
    /// starts off. The Default agent never gets the sandbox (the chip hides
    /// for it), and an agent still needs its own opt-in.
    nonisolated static let publishesAvailabilityToUI = true

    private var _status: ContainerStatus = .notProvisioned
    private var _availability: SandboxAvailability?
    private var _removedByUser = false
    private var _stoppedExplicitly = false
    private var _lastBootReadyAt: Date?
    private var inFlightStartTask: Task<Void, Error>?
    /// Tests give each manager its own throwaway workspace.
    private let workspaceRootOverride: URL?
    private let publishesState: Bool
    /// Tests: a fresh `State` for a throwaway manager to publish availability
    /// into, so the shared one is never touched.
    private let availabilityStateOverride: State?

    public var stoppedExplicitly: Bool { _stoppedExplicitly }
    public var lastBootReadyAt: Date? { _lastBootReadyAt }

    /// Background jobs (stage 4). The shared manager uses the process-wide
    /// registry that the app-quit hook kills; test managers own a private one.
    nonisolated let backgroundJobs: SandboxBackgroundJobs

    public init() {
        self.workspaceRootOverride = nil
        self.publishesState = true
        self.availabilityStateOverride = nil
        self.backgroundJobs = SandboxBackgroundJobs.shared
    }

    /// Test seam: a manager rooted at a temp workspace that does not touch the
    /// shared `State` or the sandbox configuration file.
    init(
        workspaceRoot: URL,
        maxJobLifetime: TimeInterval = SandboxBackgroundJobs.defaultMaxLifetime,
        availabilityState: State? = nil
    ) {
        self.workspaceRootOverride = workspaceRoot
        self.publishesState = false
        self.availabilityStateOverride = availabilityState
        self.backgroundJobs = SandboxBackgroundJobs(maxLifetime: maxJobLifetime)
    }

    private var workspaceURL: URL {
        workspaceRootOverride ?? OsaurusPaths.containerWorkspace()
    }

    // MARK: - Observable State (MainActor bridge)

    @MainActor
    public final class State: ObservableObject {
        public static let shared = State()
        // Intel: unavailable until `publishesAvailabilityToUI` is flipped.
        @Published public var availability: SandboxAvailability =
            .unavailable(reason: "Intel: host sandbox not enabled")
        @Published public var status: ContainerStatus = .notProvisioned
        @Published public var provisioningPhase: String? = nil
        @Published public var provisioningProgress: Double? = nil
        @Published public var isProvisioning: Bool = false
        @Published public var containerInfo: ContainerInfo?
        /// FloatingInputCard's sandbox chip reads this for the active agent.
        @Published var activeAgentUnavailability: SandboxToolRegistrar.UnavailabilityReason? = nil
    }

    // MARK: - Availability (cached, #3094 / #3105)

    public func checkAvailability() async -> SandboxAvailability {
        if let cached = _availability { return cached }
        return await refreshAvailability()
    }

    /// Resolve the backend before an operation gates on availability, so a
    /// first-run action does not hit an empty actor-local cache.
    func requireAvailabilityForOperation() async throws {
        guard (await checkAvailability()).isAvailable else {
            throw SandboxError.unavailable
        }
    }

    public func refreshAvailability() async -> SandboxAvailability {
        _availability = nil
        let result = Self.resolveAvailability()
        _availability = result
        if publishesState && Self.publishesAvailabilityToUI {
            await MainActor.run { State.shared.availability = result }
        } else if let state = availabilityStateOverride {
            await MainActor.run { state.availability = result }
        }
        return result
    }

    /// Intel always runs the Seatbelt backend; it is available when
    /// `sandbox-exec` exists.
    static func resolveAvailability() -> SandboxAvailability {
        switch SandboxBackend.current {
        case .virtualMachine:
            return .unavailable(reason: "The Linux VM sandbox needs Apple Silicon")
        case .seatbelt:
            return SeatbeltSandbox.isSupported
                ? .available
                : .unavailable(reason: "sandbox-exec was not found on this Mac")
        }
    }

    // MARK: - Status

    public func status() -> ContainerStatus { _status }

    public func refreshStatus() async -> ContainerStatus {
        if !_status.isRunning {
            if _removedByUser || (publishesState && !SandboxConfigurationStore.load().setupComplete) {
                _status = .notProvisioned
            } else if _status != .notProvisioned || publishesState {
                _status = .stopped
            }
        }
        syncStatus()
        return _status
    }

    private func syncStatus() {
        guard publishesState else { return }
        let status = _status
        Task { @MainActor in
            State.shared.status = status
            NotificationCenter.default.post(name: .toolsListChanged, object: nil)
        }
    }

    private func log(_ level: SandboxLogBuffer.Entry.Level, _ message: String) {
        guard publishesState else { return }
        Task { @MainActor in
            SandboxLogBuffer.shared.append(level: level, message: message, source: "seatbelt")
        }
    }

    // MARK: - Provision / Start / Stop

    /// "Provision" the Seatbelt backend: no VM, no download. Make sure the
    /// workspace tree exists and flip status to running.
    private func provisionSeatbelt() throws {
        guard SeatbeltSandbox.isSupported else {
            throw SandboxError.provisionFailed(
                "sandbox-exec not found at \(SeatbeltSandbox.sandboxExecPath)")
        }
        let fm = FileManager.default
        let root = workspaceURL
        for dir in [
            root,
            root.appendingPathComponent("agents", isDirectory: true),
            root.appendingPathComponent("shared", isDirectory: true),
        ] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if publishesState {
            var config = SandboxConfigurationStore.load()
            if !config.setupComplete {
                config.setupComplete = true
                SandboxConfigurationStore.save(config)
            }
        }
        _status = .running
        _lastBootReadyAt = Date()
        syncStatus()
        log(
            .info,
            "Seatbelt backend ready: commands run under sandbox-exec confinement (workspace: \(root.path))"
        )
    }

    public func provision() async throws {
        try await requireAvailabilityForOperation()
        _removedByUser = false
        try provisionSeatbelt()
    }

    public func startContainer() async throws {
        // Coalesce concurrent callers behind one attempt.
        if let existing = inFlightStartTask {
            try await existing.value
            return
        }
        let task = Task<Void, Error> { try await self._performStartContainer() }
        inFlightStartTask = task
        defer { inFlightStartTask = nil }
        try await task.value
    }

    private func _performStartContainer() async throws {
        try await requireAvailabilityForOperation()
        guard !_removedByUser else { return }
        _stoppedExplicitly = false
        if await refreshStatus().isRunning { return }
        _status = .starting
        syncStatus()
        do {
            try await provision()
        } catch {
            _status = .stopped
            syncStatus()
            throw error
        }
    }

    public func stopContainer() async throws {
        _stoppedExplicitly = true
        // Confinement is per exec, so stopping gates future execs; background
        // jobs are the only long-lived processes and stop here too.
        await backgroundJobs.stopEverything()
        _status = .stopped
        syncStatus()
    }

    /// Mark the sandbox removed. The workspace folder (the user's files) is
    /// left in place; only the "set up" state is dropped.
    public func removeContainer() async throws {
        try await stopContainer()
        _status = .notProvisioned
        _removedByUser = true
        syncStatus()
        if publishesState {
            var config = SandboxConfigurationStore.load()
            config.setupComplete = false
            SandboxConfigurationStore.save(config)
        }
    }

    public func resetContainer() async throws {
        try await removeContainer()
        try await provision()
    }

    /// Seatbelt has no guest and is always considered alive while running.
    public func probeRuntimeAlive() async -> Bool { _status.isRunning }

    /// VM-only in upstream; nothing to lose on the host backend.
    public func markRuntimeLost(reason: String) async {}

    // MARK: - Exec

    /// Run `command` as a host process under `sandbox-exec`. `user` is
    /// ignored (no per-user separation on this backend). Network is denied
    /// unless `networkEnabled` is true and the shared config allows it.
    public func exec(
        user: String? = nil,
        command: String,
        env: [String: String] = [:],
        cwd: String? = nil,
        timeout: TimeInterval? = 30,
        networkEnabled: Bool = false,
        streamToLogs: Bool = false,
        logSource: String? = nil,
        stdoutTee: (any SeatbeltOutputWriter)? = nil,
        stderrTee: (any SeatbeltOutputWriter)? = nil,
        onProcessStarted: (@Sendable (ProcessHandle) -> Void)? = nil
    ) async throws -> ContainerExecResult {
        guard _status.isRunning else {
            throw SandboxError.containerNotRunning
        }
        let root = workspaceURL.path
        let network = Self.effectiveNetworkPolicy(
            agentNetworkEnabled: networkEnabled,
            configNetwork: publishesState ? SandboxConfigurationStore.load().network : "none"
        )
        let profile = SeatbeltSandbox.profile(
            workspaceRoot: root,
            tempDir: SeatbeltSandbox.scratchDir,
            network: network
        )
        let mappedCwd = cwd.map { SeatbeltPathMapper.mapToHost($0, workspaceRoot: root) }
        let netLabel = network == .allowed ? "allowed" : "denied"
        log(.debug, "sandbox-exec [net:\(netLabel)] $ \(String(command.prefix(160)))")
        return try await SeatbeltExecutor.run(
            SeatbeltExecutor.Request(
                command: SeatbeltPathMapper.mapToHost(command, workspaceRoot: root),
                env: SeatbeltPathMapper.mapEnvToHost(env, workspaceRoot: root),
                cwd: mappedCwd ?? root,
                timeout: timeout,
                profile: profile,
                stdoutTee: stdoutTee,
                stderrTee: stderrTee,
                onProcessStarted: onProcessStarted
            ))
    }

    /// Start `command` as a background job under the same profile a
    /// foreground exec would get (stage 4). The command's own output is
    /// redirected to `logPath` (an in-sandbox path under the agent home)
    /// by the confined shell itself. Returns the registered job; the caller
    /// owns the stop policy (`backgroundJobs`).
    func execBackground(
        agentName: String,
        command: String,
        env: [String: String] = [:],
        cwd: String? = nil,
        networkEnabled: Bool = false,
        logPath: String,
        owner: String?
    ) async throws -> SandboxBackgroundJobs.Job {
        guard _status.isRunning else { throw SandboxError.containerNotRunning }
        guard backgroundJobs.canStart(agentName: agentName) else {
            throw SandboxError.execFailed(
                "Too many background processes are running for this agent "
                    + "(max \(SandboxBackgroundJobs.maxJobsPerAgent)). Stop one with `sandbox_process` first.")
        }
        let root = workspaceURL.path
        let network = Self.effectiveNetworkPolicy(
            agentNetworkEnabled: networkEnabled,
            configNetwork: publishesState ? SandboxConfigurationStore.load().network : "none"
        )
        let profile = SeatbeltSandbox.profile(
            workspaceRoot: root,
            tempDir: SeatbeltSandbox.scratchDir,
            network: network
        )
        let mappedCwd = cwd.map { SeatbeltPathMapper.mapToHost($0, workspaceRoot: root) }
        // The redirect is part of the confined command, so it is limited by
        // the same write rules (the app never opens the log itself).
        let wrapped = "exec >'\(sandboxShellEscape(logPath))' 2>&1; set -o pipefail; \(command)"
        log(.debug, "sandbox-exec [background] $ \(String(command.prefix(160)))")
        let process = try await SeatbeltExecutor.launchBackground(
            SeatbeltExecutor.Request(
                command: SeatbeltPathMapper.mapToHost(wrapped, workspaceRoot: root),
                env: SeatbeltPathMapper.mapEnvToHost(env, workspaceRoot: root),
                cwd: mappedCwd ?? root,
                timeout: nil,
                profile: profile,
                stdoutTee: nil,
                stderrTee: nil,
                onProcessStarted: nil
            ))
        return backgroundJobs.register(
            agentName: agentName, process: process, logFile: logPath, command: command, owner: owner)
    }

    /// Both the per-agent switch and the shared config must allow the
    /// network. Intel default for the switch is off.
    nonisolated static func effectiveNetworkPolicy(
        agentNetworkEnabled: Bool,
        configNetwork: String
    ) -> SeatbeltSandbox.NetworkPolicy {
        guard agentNetworkEnabled else { return .denied }
        return SeatbeltSandbox.NetworkPolicy.from(configNetwork: configNetwork)
    }

    public func execAsRoot(
        command: String,
        timeout: TimeInterval? = 60,
        streamToLogs: Bool = false,
        logSource: String? = nil,
        stdoutTee: (any SeatbeltOutputWriter)? = nil,
        stderrTee: (any SeatbeltOutputWriter)? = nil,
        onProcessStarted: (@Sendable (ProcessHandle) -> Void)? = nil
    ) async throws -> ContainerExecResult {
        try await exec(
            command: command,
            timeout: timeout,
            streamToLogs: streamToLogs,
            logSource: logSource,
            stdoutTee: stdoutTee,
            stderrTee: stderrTee,
            onProcessStarted: onProcessStarted
        )
    }

    public func execAsAgent(
        _ agentName: String,
        command: String,
        pluginName: String? = nil,
        env: [String: String] = [:],
        timeout: TimeInterval? = 30,
        networkEnabled: Bool = false,
        streamToLogs: Bool = false,
        logSource: String? = nil,
        stdoutTee: (any SeatbeltOutputWriter)? = nil,
        stderrTee: (any SeatbeltOutputWriter)? = nil,
        onProcessStarted: (@Sendable (ProcessHandle) -> Void)? = nil
    ) async throws -> ContainerExecResult {
        let cwd = pluginName.map { OsaurusPaths.inContainerPluginDir(agentName, $0) }
        return try await exec(
            user: "agent-\(agentName)",
            command: command,
            env: env,
            cwd: cwd,
            timeout: timeout,
            networkEnabled: networkEnabled,
            streamToLogs: streamToLogs,
            logSource: logSource,
            stdoutTee: stdoutTee,
            stderrTee: stderrTee,
            onProcessStarted: onProcessStarted
        )
    }

    // MARK: - Agent homes

    /// No guest, no Linux users, no bridge shim: bootstrap is the host-side
    /// directory tree plus the first-run SOUL seed.
    public func bootstrapAgent(
        agentName: String,
        agentId: UUID?,
        soulSeedBody: String?
    ) async throws {
        try Self.bootstrapAgentOnHost(
            agentName: agentName, soulSeedBody: soulSeedBody, workspaceRoot: workspaceURL)
    }

    public func ensureAgentUser(_ agentName: String) async throws {
        try Self.bootstrapAgentOnHost(
            agentName: agentName, soulSeedBody: nil, workspaceRoot: workspaceURL)
    }

    /// Host-side equivalent of upstream's guest bootstrap script. Static so
    /// it is testable without the actor.
    static func bootstrapAgentOnHost(
        agentName: String,
        soulSeedBody: String?,
        workspaceRoot: URL = OsaurusPaths.containerWorkspace()
    ) throws {
        let home = try agentHome(agentName: agentName, workspaceRoot: workspaceRoot)
        let fm = FileManager.default
        try fm.createDirectory(
            atPath: home + "/plugins", withIntermediateDirectories: true, attributes: nil)
        // chmod 700 like the guest script: keeps other host users out.
        try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: home)
        if let soulSeedBody {
            let soulPath = home + "/SOUL.md"
            if !fm.fileExists(atPath: soulPath) {
                try soulSeedBody.write(toFile: soulPath, atomically: true, encoding: .utf8)
            }
        }
    }

    public func removeAgentUser(_ agentName: String) async throws -> Bool {
        let home = try Self.agentHome(agentName: agentName, workspaceRoot: workspaceURL)
        let fm = FileManager.default
        guard fm.fileExists(atPath: home) else { return false }
        try fm.removeItem(atPath: home)
        return true
    }

    /// Host path of an agent's home. Rejects names that would step out of
    /// `<workspace>/agents` (empty, path separators, dot segments).
    static func agentHome(agentName: String, workspaceRoot: URL) throws -> String {
        guard !agentName.isEmpty, agentName != ".", agentName != "..",
            !agentName.contains("/"), !agentName.contains("\0")
        else {
            throw SandboxError.userCreationFailed("invalid agent name")
        }
        return SeatbeltPathMapper.mapToHost(
            OsaurusPaths.inContainerAgentHome(agentName), workspaceRoot: workspaceRoot.path)
    }

    // MARK: - Container info

    public struct ContainerInfo: Sendable {
        public let status: ContainerStatus
        public let agentUsers: [String]
        public let diskUsage: String?
        public let uptime: String?
        public let memoryUsage: String?
        public let cpuLoad: String?
        public let processCount: Int?
    }

    public func info() async -> ContainerInfo {
        let result = await computeInfo()
        if publishesState {
            await MainActor.run { State.shared.containerInfo = result }
        }
        return result
    }

    private func computeInfo() async -> ContainerInfo {
        func bare(_ status: ContainerStatus) -> ContainerInfo {
            ContainerInfo(
                status: status, agentUsers: [], diskUsage: nil, uptime: nil,
                memoryUsage: nil, cpuLoad: nil, processCount: nil)
        }
        if inFlightStartTask != nil { return bare(_status) }
        let current = _status.isRunning ? ContainerStatus.running : await refreshStatus()
        guard current.isRunning else { return bare(current) }

        // Host-side numbers only: agent homes, workspace disk use, time up.
        let fm = FileManager.default
        let agentsDir = workspaceURL.appendingPathComponent("agents", isDirectory: true)
        let users =
            ((try? fm.contentsOfDirectory(atPath: agentsDir.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
        var uptime: String? = nil
        if let ready = _lastBootReadyAt {
            uptime = "\(Int(Date().timeIntervalSince(ready))) seconds"
        }
        var disk: String? = nil
        if let r = try? await exec(command: "du -sh /workspace 2>/dev/null | cut -f1", timeout: 5) {
            let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !out.isEmpty { disk = out }
        }
        return ContainerInfo(
            status: current, agentUsers: users, diskUsage: disk, uptime: uptime,
            memoryUsage: nil, cpuLoad: nil, processCount: nil)
    }

    // MARK: - Diagnostics

    public struct DiagnosticResult: Sendable {
        public let name: String
        public let passed: Bool
        public let detail: String
    }

    /// Verify the properties this backend promises: commands run, the
    /// workspace is read-write, writes OUTSIDE it are blocked, and the
    /// network is blocked (it is off by default on Intel). The network probe
    /// only ever connects to a loopback listener this process opens, so no
    /// diagnostic traffic leaves the Mac.
    public func runDiagnostics(networkEnabled: Bool = false) async -> [DiagnosticResult] {
        let execResult = await diagnose("exec") {
            let r = try await self.exec(command: "echo hello from sandbox")
            let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard out == "hello from sandbox" else {
                throw SandboxError.execFailed("expected 'hello from sandbox', got '\(out)'")
            }
            return out
        }

        let writeResult = await diagnose("workspace-rw") {
            let r = try await self.exec(
                command: "f=/workspace/.osaurus-diag-$$; echo ok > \"$f\" && cat \"$f\" && rm -f \"$f\""
            )
            guard r.succeeded, r.stdout.contains("ok") else {
                throw SandboxError.execFailed(
                    "workspace write failed (exit \(r.exitCode)): \(r.stderr)")
            }
            return "workspace read/write OK"
        }

        let confinementResult = await diagnose("confinement") {
            // A write outside the workspace MUST be denied by the profile.
            // The app itself is not confined, so checking the host file
            // system afterwards is authoritative. Unique name per run.
            let escapePath = "/private/tmp/osaurus-seatbelt-escape-\(UUID().uuidString)"
            _ = try await self.exec(command: "touch \(escapePath) 2>/dev/null")
            if FileManager.default.fileExists(atPath: escapePath) {
                try? FileManager.default.removeItem(atPath: escapePath)
                throw SandboxError.execFailed(
                    "a write outside the workspace succeeded: the sandbox profile is not being enforced"
                )
            }
            return "writes outside the workspace are blocked"
        }

        let networkResult = await diagnose("network") {
            let reached = try await self.loopbackReachable(networkEnabled: networkEnabled)
            if networkEnabled { return reached ? "network permitted as configured" : "network probe blocked" }
            guard !reached else {
                throw SandboxError.execFailed(
                    "network is configured off but a connection succeeded: the sandbox profile is not being enforced"
                )
            }
            return "network blocked as configured"
        }

        return [execResult, writeResult, confinementResult, networkResult]
    }

    /// Open a loopback listener in this (unconfined) process and ask the
    /// sandboxed shell to connect to it. Never leaves the machine.
    private func loopbackReachable(networkEnabled: Bool) async throws -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SandboxError.execFailed("could not open a loopback probe socket") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else {
            throw SandboxError.execFailed("could not listen on the loopback probe socket")
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard named == 0 else { throw SandboxError.execFailed("could not read the probe port") }
        let port = UInt16(bigEndian: addr.sin_port)
        let r = try await exec(
            command: "/usr/bin/nc -z -w 2 127.0.0.1 \(port)",
            timeout: 10,
            networkEnabled: networkEnabled
        )
        return r.exitCode == 0
    }

    private func diagnose(_ name: String, _ block: () async throws -> String) async -> DiagnosticResult {
        do {
            let detail = try await block()
            return DiagnosticResult(name: name, passed: true, detail: detail)
        } catch {
            return DiagnosticResult(name: name, passed: false, detail: error.localizedDescription)
        }
    }
}
