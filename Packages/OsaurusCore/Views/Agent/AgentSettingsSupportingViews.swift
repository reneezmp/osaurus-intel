//
//  AgentSettingsSupportingViews.swift
//  OsaurusCore
//
//  Small Intel-safe controls shared by the agent detail settings surface.
//  The full schedule and watcher managers remain the source of truth; these
//  views only expose their existing operations from the per-agent rows.
//

import SwiftUI

struct AgentScheduleActionMenu: View {
    @Environment(\.theme) private var theme

    let schedule: Schedule
    let isRunning: Bool
    let onEdit: () -> Void
    let onRunNow: () -> Void
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void

    @State private var showingDeleteConfirmation = false

    var body: some View {
        HStack(spacing: 4) {
            actionButton("Edit", icon: "pencil", action: onEdit)
            actionButton("Run Now", icon: "play.fill", disabled: isRunning, action: onRunNow)
            actionButton(
                schedule.isEnabled ? "Pause" : "Resume",
                icon: schedule.isEnabled ? "pause.fill" : "play.fill"
            ) {
                onToggle(!schedule.isEnabled)
            }
            actionButton("Delete", icon: "trash", destructive: true) {
                showingDeleteConfirmation = true
            }
        }
        .confirmationDialog(
            "Delete this schedule?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        }
    }

    private func actionButton(
        _ title: LocalizedStringKey,
        icon: String,
        disabled: Bool = false,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(title, bundle: .module)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(destructive ? theme.errorColor : theme.secondaryText)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.tertiaryBackground)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .help(Text(title, bundle: .module))
        .accessibilityLabel(Text(title, bundle: .module))
    }
}

struct AgentWatcherActionMenu: View {
    @Environment(\.theme) private var theme

    let watcher: Watcher
    let isRunning: Bool
    let onEdit: () -> Void
    let onRunNow: () -> Void
    let onToggle: (Bool) -> Void
    let onDelete: () -> Void

    @State private var showingDeleteConfirmation = false

    var body: some View {
        HStack(spacing: 4) {
            actionButton("Edit", icon: "pencil", action: onEdit)
            actionButton("Run Now", icon: "play.fill", disabled: isRunning, action: onRunNow)
            actionButton(
                watcher.isEnabled ? "Pause" : "Resume",
                icon: watcher.isEnabled ? "pause.fill" : "play.fill"
            ) {
                onToggle(!watcher.isEnabled)
            }
            actionButton("Delete", icon: "trash", destructive: true) {
                showingDeleteConfirmation = true
            }
        }
        .confirmationDialog(
            "Delete this watcher?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        }
    }

    private func actionButton(
        _ title: LocalizedStringKey,
        icon: String,
        disabled: Bool = false,
        destructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
                Text(title, bundle: .module)
                    .font(.system(size: 10, weight: .medium))
            }
            .foregroundColor(destructive ? theme.errorColor : theme.secondaryText)
            .padding(.horizontal, 8)
            .frame(height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(theme.tertiaryBackground)
            )
        }
        .buttonStyle(.plain)
        .disabled(disabled)
        .opacity(disabled ? 0.45 : 1)
        .help(Text(title, bundle: .module))
        .accessibilityLabel(Text(title, bundle: .module))
    }
}
