//
//  IntelSandboxView.swift
//  osaurus
//
//  Intel fork (W-seatbelt-sandbox stage 5): the Sandbox page for the host
//  backend. Upstream's `SandboxView` (with its `isSeatbelt` branches) is the
//  VM page: provisioning journey, CPU/memory, boot timings, image downloads,
//  per-agent environments. None of that exists under Seatbelt, so this page
//  shows only what the host backend has: the status and start/stop, the
//  shared network master switch, the confinement self-test, the background
//  processes that are running (with Stop), and the workspace folder.
//
//  Ventura rules: single-value `onChange`, plain button styles, SF Symbols
//  that exist on macOS 13. Every string goes through `L()` / localized text.
//

import SwiftUI

struct IntelSandboxView: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var sandboxState = SandboxManager.State.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    @State private var networkAllowed: Bool = SandboxConfigurationStore.load().network != "none"
    @State private var jobs: [JobRow] = []
    @State private var diagnostics: [SandboxManager.DiagnosticResult]?
    @State private var isRunningDiagnostics = false
    @State private var isBusy = false
    @State private var actionError: String?
    @State private var refreshTask: Task<Void, Never>?

    /// One running background process, for the list.
    struct JobRow: Identifiable, Equatable {
        let agentName: String
        let pid: String
        let command: String
        var id: String { "\(agentName):\(pid)" }
    }

    var body: some View {
        VStack(spacing: 0) {
            ManagerHeader(title: L("Sandbox"), subtitle: subtitle)
            if !sandboxState.availability.isAvailable {
                unavailableState
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        statusCard
                        networkCard
                        processesCard
                        selfTestCard
                    }
                    .padding(24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .environment(\.theme, theme)
        .onAppear { startRefreshing() }
        .onDisappear {
            refreshTask?.cancel()
            refreshTask = nil
        }
    }

    // MARK: - Header

    private var subtitle: String {
        guard sandboxState.availability.isAvailable else { return L("Unavailable") }
        switch sandboxState.status {
        case .running: return L("Sandbox running")
        case .stopped: return L("Sandbox stopped")
        case .starting: return L("Sandbox starting...")
        case .notProvisioned: return L("Not set up")
        case .error(let message): return L("Error: \(message)")
        }
    }

    private var unavailableState: some View {
        VStack(spacing: 10) {
            Image(systemName: "shippingbox")
                .font(.system(size: 30))
                .foregroundColor(theme.tertiaryText)
            Text(
                sandboxState.availability.reason ?? L("This Mac cannot run the sandbox."))
                .font(.system(size: 13))
                .foregroundColor(theme.secondaryText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    // MARK: - Cards

    private func card<Content: View>(
        title: String, icon: String, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(theme.primaryText)
            }
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(theme.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(theme.cardBorder, lineWidth: 1))
        )
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundColor(theme.tertiaryText)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func pillButton(
        _ title: String, icon: String, disabled: Bool = false, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .semibold))
                Text(title)
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundColor(theme.accentColor)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.accentColor.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(theme.accentColor.opacity(0.2), lineWidth: 1))
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
    }

    private var statusCard: some View {
        card(title: L("Status"), icon: "shippingbox") {
            caption(
                L(
                    "Agent commands run on this Mac inside a macOS sandbox profile. They can read system tools and write only in the sandbox workspace folder; nothing outside it is visible to them."
                ))
            HStack(spacing: 8) {
                if sandboxState.status.isRunning {
                    pillButton(L("Stop Sandbox"), icon: "stop.fill", disabled: isBusy) { stopSandbox() }
                } else {
                    pillButton(L("Start Sandbox"), icon: "play.fill", disabled: isBusy) { startSandbox() }
                }
                pillButton(L("Open Workspace Folder"), icon: "folder") {
                    OsaurusPaths.revealInFinder(OsaurusPaths.containerWorkspace())
                }
            }
            if let actionError {
                Text(actionError)
                    .font(.system(size: 11))
                    .foregroundColor(theme.errorColor)
            }
        }
    }

    private var networkCard: some View {
        card(title: L("Network Access"), icon: "network") {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("Allow agents to use the network"))
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(theme.primaryText)
                    caption(
                        L(
                            "Master switch. A sandboxed command reaches the network only when this is on AND the agent's own Network Access switch is on (off by default). The macOS sandbox cannot limit which sites."
                        ))
                }
                Spacer()
                Toggle(
                    "",
                    isOn: Binding(
                        get: { networkAllowed },
                        set: { setNetworkAllowed($0) })
                )
                .toggleStyle(.switch)
                .labelsHidden()
            }
        }
    }

    private var processesCard: some View {
        card(title: L("Background Processes"), icon: "gearshape.2") {
            caption(
                L(
                    "Processes an agent started in the background. They stop when the agent's run ends, when the sandbox stops, and when Osaurus quits."
                ))
            if jobs.isEmpty {
                Text(L("No background processes are running."))
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            } else {
                VStack(spacing: 6) {
                    ForEach(jobs) { job in
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(job.command)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundColor(theme.primaryText)
                                    .lineLimit(1)
                                Text("pid \(job.pid)")
                                    .font(.system(size: 10))
                                    .foregroundColor(theme.tertiaryText)
                            }
                            Spacer()
                            pillButton(L("Stop"), icon: "stop.fill") { stop(job) }
                        }
                    }
                }
                pillButton(L("Stop All"), icon: "xmark.circle") { stopAllJobs() }
            }
        }
    }

    private var selfTestCard: some View {
        card(title: L("Self-Test"), icon: "checkmark.shield") {
            caption(
                L(
                    "Checks that commands run, that writes outside the workspace are blocked, and that the network is blocked. It never leaves this Mac."
                ))
            pillButton(
                isRunningDiagnostics ? L("Running...") : L("Run Self-Test"), icon: "play.circle",
                disabled: isRunningDiagnostics || !sandboxState.status.isRunning
            ) { runSelfTest() }
            if let diagnostics {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, result in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundColor(result.passed ? theme.successColor : theme.errorColor)
                            Text("\(result.name): \(result.detail)")
                                .font(.system(size: 11))
                                .foregroundColor(theme.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    private func startRefreshing() {
        refreshTask?.cancel()
        refreshTask = Task { @MainActor in
            while !Task.isCancelled {
                jobs = SandboxBackgroundJobs.shared.allRunning().map {
                    JobRow(agentName: $0.agentName, pid: $0.job.pid, command: $0.job.command)
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }
        }
    }

    private func startSandbox() {
        isBusy = true
        actionError = nil
        Task { @MainActor in
            do {
                try await SandboxManager.shared.startContainer()
            } catch {
                actionError = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func stopSandbox() {
        isBusy = true
        actionError = nil
        Task { @MainActor in
            do {
                try await SandboxManager.shared.stopContainer()
            } catch {
                actionError = error.localizedDescription
            }
            isBusy = false
        }
    }

    private func setNetworkAllowed(_ allowed: Bool) {
        networkAllowed = allowed
        var config = SandboxConfigurationStore.load()
        config.network = allowed ? "outbound" : "none"
        SandboxConfigurationStore.save(config)
    }

    private func stop(_ job: JobRow) {
        Task { _ = await SandboxBackgroundJobs.shared.stop(agentName: job.agentName, pid: job.pid) }
    }

    private func stopAllJobs() {
        Task { await SandboxBackgroundJobs.shared.stopEverything() }
    }

    private func runSelfTest() {
        isRunningDiagnostics = true
        diagnostics = nil
        Task { @MainActor in
            diagnostics = await SandboxManager.shared.runDiagnostics(networkEnabled: false)
            isRunningDiagnostics = false
        }
    }
}
