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
        Menu {
            Button(action: onEdit) {
                Label("Edit", systemImage: "pencil")
            }
            Button(action: onRunNow) {
                Label("Run Now", systemImage: "play.fill")
            }
            .disabled(isRunning)
            Divider()
            Button {
                onToggle(!schedule.isEnabled)
            } label: {
                Label(
                    schedule.isEnabled ? "Pause" : "Resume",
                    systemImage: schedule.isEnabled ? "pause.circle" : "play.circle"
                )
            }
            Divider()
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .frame(width: 24, height: 24)
                .background(Circle().fill(theme.tertiaryBackground))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
        .confirmationDialog(
            "Delete this schedule?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        }
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
        Menu {
            Button(action: onEdit) {
                Label("Edit", systemImage: "pencil")
            }
            Button(action: onRunNow) {
                Label("Run Now", systemImage: "play.fill")
            }
            .disabled(isRunning)
            Divider()
            Button {
                onToggle(!watcher.isEnabled)
            } label: {
                Label(
                    watcher.isEnabled ? "Pause" : "Resume",
                    systemImage: watcher.isEnabled ? "pause.circle" : "play.circle"
                )
            }
            Divider()
            Button(role: .destructive) {
                showingDeleteConfirmation = true
            } label: {
                Label("Delete", systemImage: "trash")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(theme.secondaryText)
                .frame(width: 24, height: 24)
                .background(Circle().fill(theme.tertiaryBackground))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 24)
        .confirmationDialog(
            "Delete this watcher?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: onDelete)
            Button("Cancel", role: .cancel) {}
        }
    }
}
