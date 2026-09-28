//
//  DatabaseHistoryView.swift
//  osaurus
//
//  Audit + run history for the agent (the old Activity tab, now the
//  Database workspace's History section): every dispatched run from
//  the scheduler DB plus a per-run trace pulled from this agent's
//  `_changelog`. The runs list is the master pane, and selecting a row
//  populates the trace on the right. Mirrors §7's "Activity" design.
//

import SwiftUI

struct DatabaseHistoryView: View {
    @Environment(\.theme) private var theme

    let agentId: UUID

    @State private var runs: [AgentRunRecord] = []
    @State private var selectedRunId: UUID? = nil
    @State private var changelogRows: [ChangelogEntry] = []
    @State private var isLoadingRuns = true
    @State private var isLoadingTrace = false
    @State private var loadError: String? = nil
    /// Intel: changes with no run id (normal chats and edits in the Tables
    /// view). Upstream's History lists runs only, so these were invisible.
    @State private var chatChangeCount = 0

    /// Selection sentinel for the "Chat & manual edits" entry.
    nonisolated static let chatChangesSelection = UUID(uuidString: "00000000-0000-0000-0000-0000000C4A75")!

    init(agentId: UUID) {
        self.agentId = agentId
    }

    /// Intel lists automation runs only: self-scheduled wakes (`schedule`)
    /// come from model scheduling tools this build does not ship.
    nonisolated static func visibleRuns(_ runs: [AgentRunRecord]) -> [AgentRunRecord] {
        runs.filter { $0.triggerKind != .schedule }
    }

    nonisolated static func triggerLabel(_ kind: AgentRunTriggerKind) -> String {
        switch kind {
        case .recurringSchedule: return L("Schedule")
        case .watcher: return L("Watcher")
        case .user: return L("Manual")
        case .schedule: return L("Self-scheduled")
        }
    }

    var body: some View {
        // Minimums are deliberately conservative: the workspace body is
        // dropped into a Settings detail pane (~750pt at standard width)
        // and HSplitView refuses to compress past the sum of its
        // children's `minWidth`.
        HSplitView {
            runsList
                .frame(minWidth: 210, idealWidth: 300, maxWidth: 420)
            tracePane
                .frame(minWidth: 300, maxWidth: .infinity)
                .layoutPriority(1)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.primaryBackground)
        .task { await loadRuns() }
        .onChange(of: agentId) { _ in Task { await loadRuns() } }
        .onChange(of: selectedRunId) { _ in Task { await loadTrace() } }
    }

    @ViewBuilder
    private var runsList: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Runs", bundle: .module)
                    .font(.system(size: 11, weight: .bold))
                    .tracking(0.5)
                    .foregroundColor(theme.tertiaryText)
                Spacer()
                Button {
                    Task { await loadRuns() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            Divider().foregroundColor(theme.primaryBorder)
            if isLoadingRuns {
                ProgressView().padding(24)
            } else if runs.isEmpty && chatChangeCount == 0 {
                Text("No runs yet. When the agent works on a schedule or automation, each run shows up here.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
                    .padding(24)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if chatChangeCount > 0 {
                            chatChangesRow
                        }
                        ForEach(runs, id: \.id) { run in
                            runRow(run)
                        }
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.secondaryBackground.opacity(0.25))
    }

    @ViewBuilder
    private var chatChangesRow: some View {
        let isSelected = selectedRunId == Self.chatChangesSelection
        Button {
            selectedRunId = Self.chatChangesSelection
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .foregroundColor(theme.accentColor)
                    Text("Chat & manual edits", bundle: .module)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Spacer()
                    Text(verbatim: "\(chatChangeCount)")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                }
                Text("Changes made outside scheduled or automated runs.", bundle: .module)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? theme.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    @ViewBuilder
    private func runRow(_ run: AgentRunRecord) -> some View {
        let isSelected = selectedRunId == run.id
        Button {
            selectedRunId = run.id
        } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    statusIcon(for: run.status)
                    Text(run.status.rawValue.capitalized)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Spacer()
                    Text(Self.triggerLabel(run.triggerKind))
                        .font(.system(size: 9, weight: .medium))
                        .foregroundColor(theme.tertiaryText)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(theme.tertiaryBackground)
                        )
                }
                Text(run.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                Text(run.instructions)
                    .font(.system(size: 10))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7)
                    .fill(isSelected ? theme.accentColor.opacity(0.12) : Color.clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
    }

    @ViewBuilder
    private func statusIcon(for status: AgentRunStatus) -> some View {
        switch status {
        case .running:
            Image(systemName: "arrow.triangle.2.circlepath")
                .foregroundColor(.blue)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .foregroundColor(.red)
        case .cancelled:
            Image(systemName: "stop.circle.fill")
                .foregroundColor(.orange)
        case .clamped:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
        }
    }

    @ViewBuilder
    private var tracePane: some View {
        VStack(alignment: .leading, spacing: 0) {
            if selectedRunId == Self.chatChangesSelection {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chat & manual edits", bundle: .module)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(theme.primaryText)
                    Text("What the agent changed during normal chats, and edits you made in the Tables view. Newest first, up to 500.", bundle: .module)
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                Divider().foregroundColor(theme.primaryBorder)
                if isLoadingTrace {
                    ProgressView().padding(24)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(changelogRows) { row in
                                changelogRowView(row)
                            }
                        }
                    }
                }
            } else if let runId = selectedRunId, let run = runs.first(where: { $0.id == runId }) {
                traceHeader(for: run)
                Divider().foregroundColor(theme.primaryBorder)
                if isLoadingTrace {
                    ProgressView().padding(24)
                } else if changelogRows.isEmpty {
                    Text("No database changes were recorded for this run.", bundle: .module)
                        .font(.system(size: 12))
                        .foregroundColor(theme.tertiaryText)
                        .padding(24)
                } else {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(changelogRows) { row in
                                changelogRowView(row)
                            }
                        }
                    }
                }
            } else {
                Text("Select a run to see its trace.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.tertiaryText)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func traceHeader(for run: AgentRunRecord) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                statusIcon(for: run.status)
                Text(run.status.rawValue.capitalized)
                    .font(.system(size: 12, weight: .semibold))
                Text("·")
                    .foregroundColor(theme.tertiaryText)
                Text(Self.triggerLabel(run.triggerKind))
                    .font(.system(size: 11))
                    .foregroundColor(theme.tertiaryText)
                Spacer()
                if let ended = run.endedAt {
                    Text(durationLabel(from: run.startedAt, to: ended))
                        .font(.system(size: 11))
                        .foregroundColor(theme.tertiaryText)
                }
            }
            if let error = run.error, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.red)
                    .lineLimit(3)
            }
            HStack(spacing: 12) {
                if let tin = run.tokensIn {
                    statBadge(label: "in", value: "\(tin)")
                }
                if let tout = run.tokensOut {
                    statBadge(label: "out", value: "\(tout)")
                }
                if let cost = run.costUSD {
                    statBadge(label: "$", value: String(format: "%.4f", cost))
                }
                Spacer()
            }
            Text(run.instructions)
                .font(.system(size: 11))
                .foregroundColor(theme.tertiaryText)
                .lineLimit(3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func statBadge(label: String, value: String) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(theme.tertiaryText)
            Text(value)
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.primaryText)
        }
    }

    @ViewBuilder
    private func changelogRowView(_ row: ChangelogEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(row.op)
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundColor(theme.accentColor)
                if let table = row.tableName {
                    Text(table)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.primaryText)
                }
                if let pk = row.rowPK {
                    Text(pk)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(theme.tertiaryText)
                        .lineLimit(1)
                }
                Spacer()
                Text(row.actor)
                    .font(.system(size: 9))
                    .foregroundColor(theme.tertiaryText)
                Text(row.timestamp.formatted(date: .omitted, time: .standard))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
            }
            if let sql = row.sql, !sql.isEmpty {
                Text(sql)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundColor(theme.tertiaryText)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(Divider().foregroundColor(theme.primaryBorder), alignment: .bottom)
    }

    private func durationLabel(from start: Date, to end: Date) -> String {
        let seconds = end.timeIntervalSince(start)
        if seconds < 60 {
            return String(format: "%.1fs", seconds)
        }
        let minutes = Int(seconds) / 60
        let rem = Int(seconds) % 60
        return "\(minutes)m \(rem)s"
    }

    // MARK: - Loading

    /// Number of `_changelog` rows with no run id. Only opens the database
    /// when its file already exists, so viewing History never creates one.
    nonisolated static func countChatChanges(agentId: UUID) -> Int {
        guard FileManager.default.fileExists(atPath: OsaurusPaths.agentDatabaseFile(for: agentId).path)
        else { return 0 }
        guard
            let result = try? LocalAgentBridge.shared.query(
                agentId: agentId,
                sql: "SELECT COUNT(*) FROM _changelog WHERE run_id IS NULL",
                params: []
            ),
            case .integer(let count)? = result.rows.first?.first
        else { return 0 }
        return Int(count)
    }

    @MainActor
    private func loadRuns() async {
        isLoadingRuns = true
        defer { isLoadingRuns = false }
        do {
            try SchedulerDatabase.shared.open()
            runs = Self.visibleRuns(try SchedulerDatabase.shared.runs(agentId: agentId, limit: 200))
            chatChangeCount = Self.countChatChanges(agentId: agentId)
            if let current = selectedRunId,
                runs.contains(where: { $0.id == current })
                    || (current == Self.chatChangesSelection && chatChangeCount > 0)
            {
                // Keep current selection across refreshes.
            } else {
                selectedRunId = runs.first?.id ?? (chatChangeCount > 0 ? Self.chatChangesSelection : nil)
            }
        } catch {
            loadError = error.localizedDescription
            runs = []
        }
    }

    @MainActor
    private func loadTrace() async {
        guard let runId = selectedRunId else {
            changelogRows = []
            return
        }
        isLoadingTrace = true
        defer { isLoadingTrace = false }
        do {
            let isChat = runId == Self.chatChangesSelection
            let sql =
                isChat
                ? "SELECT ts, actor, op, table_name, row_pk, sql "
                    + "FROM _changelog WHERE run_id IS NULL ORDER BY ts DESC LIMIT 500"
                : "SELECT ts, actor, op, table_name, row_pk, sql "
                    + "FROM _changelog WHERE run_id = ?1 ORDER BY ts ASC"
            let result = try LocalAgentBridge.shared.query(
                agentId: agentId,
                sql: sql,
                params: isChat ? [] : [.text(runId.uuidString)]
            )
            changelogRows = result.rows.enumerated().compactMap { (index, row) in
                guard row.count >= 6 else { return nil }
                let ts: Int64 = {
                    if case .integer(let v) = row[0] { return v }
                    return 0
                }()
                return ChangelogEntry(
                    index: index,
                    timestamp: Date(timeIntervalSince1970: TimeInterval(ts)),
                    actor: textValue(row[1]) ?? "",
                    op: textValue(row[2]) ?? "",
                    tableName: textValue(row[3]),
                    rowPK: textValue(row[4]),
                    sql: textValue(row[5])
                )
            }
        } catch {
            changelogRows = []
        }
    }

    private func textValue(_ value: AgentSQLValue) -> String? {
        if case .text(let v) = value { return v }
        return nil
    }
}

private struct ChangelogEntry: Identifiable {
    var id: Int { index }
    let index: Int
    let timestamp: Date
    let actor: String
    let op: String
    let tableName: String?
    let rowPK: String?
    let sql: String?
}
