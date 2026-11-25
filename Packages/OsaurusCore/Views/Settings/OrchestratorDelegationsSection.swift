//
//  OrchestratorDelegationsSection.swift
//  osaurus
//
//  The Orchestrator's Delegations list (W-subagents stage 5; upstream
//  `OrchestratorDelegationsSection`): every task the Orchestrator or a custom
//  agent handed to a subagent, with status, duration, throughput and a way
//  into the worker's chat. Intel: sent runs only (workspaces are deferred, so
//  there is no Sent / Received switch).
//

import SwiftUI

struct OrchestratorDelegationsSection: View {
    @ObservedObject private var themeManager = ThemeManager.shared
    @ObservedObject private var backgroundTasks = BackgroundTaskManager.shared

    @State private var rows: [DelegationRecord] = []
    @State private var refreshTick = 0

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        SettingsSection(title: "Delegations", icon: "list.bullet.rectangle") {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(
                        "Every task the Orchestrator (or a custom agent) handed to a subagent. Open a chat to read the full worker transcript.",
                        bundle: .module
                    )
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button {
                        reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(theme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help(L("Refresh"))
                }

                if rows.isEmpty {
                    Text("No delegations yet.", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .padding(.vertical, 8)
                } else {
                    VStack(spacing: 6) {
                        ForEach(rows) { row in
                            delegationRow(row)
                        }
                    }
                }
            }
        }
        .onAppear { reload() }
        .onReceive(backgroundTasks.objectWillChange) { _ in
            // Live status changes (queued → running → completed) refresh the
            // list; coalesced by the small state hop so a busy run doesn't
            // re-read the DB per token.
            refreshTick += 1
        }
        .task(id: refreshTick) {
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            reload()
        }
    }

    private func reload() {
        rows = DelegationRecordLoader.load()
    }

    private func delegationRow(_ row: DelegationRecord) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: Self.statusIcon(row.status))
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(statusColor(row.status))
                .frame(width: 14)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(verbatim: row.agentName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                        .lineLimit(1)
                    if row.needsInput {
                        Text("Needs input", bundle: .module)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundColor(theme.warningColor)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(theme.warningColor.opacity(0.12)))
                    }
                }
                Text(verbatim: row.task)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(verbatim: Self.metricsLine(row))
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
            }
            Spacer(minLength: 8)
            Button {
                Self.openChat(row)
            } label: {
                Text("Open Chat", bundle: .module)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.accentColor)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("orchestrator.delegations.openChat")
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.tertiaryBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(theme.inputBorder, lineWidth: 1)
                )
        )
    }

    /// Compact "status · 1m 12s · 42.5 tok/s · 2 files" line. Pure, for tests.
    static func metricsLine(_ row: DelegationRecord) -> String {
        var parts: [String] = [statusLabel(row.status)]
        parts.append(formatDuration(row.duration))
        if let tps = row.tokensPerSecond {
            parts.append(String(format: "%.1f tok/s", tps))
        }
        if let tokens = row.completionTokens {
            parts.append("\(tokens) tokens")
        }
        if row.artifactCount > 0 {
            parts.append(row.artifactCount == 1 ? "1 file" : "\(row.artifactCount) files")
        }
        return parts.joined(separator: " · ")
    }

    static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m \(total % 60)s" }
        return "\(total / 3600)h \((total % 3600) / 60)m"
    }

    static func statusLabel(_ status: DelegationRecord.Status) -> String {
        switch status {
        case .queued: return L("Queued")
        case .running: return L("Running")
        case .waitingForInput: return L("Waiting for input")
        case .completed: return L("Completed")
        case .failed: return L("Failed")
        case .cancelled: return L("Cancelled")
        }
    }

    /// SF Symbols that exist on macOS 13.
    static func statusIcon(_ status: DelegationRecord.Status) -> String {
        switch status {
        case .queued: return "clock"
        case .running: return "arrow.triangle.2.circlepath"
        case .waitingForInput: return "questionmark.circle"
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.circle.fill"
        case .cancelled: return "minus.circle"
        }
    }

    private func statusColor(_ status: DelegationRecord.Status) -> Color {
        switch status {
        case .queued, .running: return theme.accentColor
        case .waitingForInput: return theme.warningColor
        case .completed: return theme.successColor
        case .failed: return theme.errorColor
        case .cancelled: return theme.tertiaryText
        }
    }

    private static func openChat(_ row: DelegationRecord) {
        if row.isLive, BackgroundTaskManager.shared.taskState(for: row.id) != nil {
            BackgroundTaskManager.shared.openTaskWindow(row.id)
            return
        }
        guard let session = ChatSessionsManager.shared.session(for: row.id) else {
            ToastManager.shared.error(L("This delegation's chat is no longer available."))
            return
        }
        ChatWindowManager.shared.openSessionAsTab(session)
    }
}
