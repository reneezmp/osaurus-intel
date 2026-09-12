//
//  IntelConfigPlanApprovalCard.swift
//  OsaurusCore
//
//  Bottom-pinned review card for an exact Intel Gate 5A plan.
//

#if OSAURUS_INTEL

import SwiftUI

struct IntelConfigPlanApprovalCard: View {
    let sessionID: String?
    @ObservedObject private var queue = IntelConfigApprovalQueue.shared
    @ObservedObject private var themeManager = ThemeManager.shared

    private var theme: ThemeProtocol { themeManager.currentTheme }

    var body: some View {
        VStack {
            Spacer()
            if let request = pendingRequest {
                card(for: request)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: pendingRequest?.id)
        .onAppear { mountSurface() }
        .onDisappear {
            if let sessionID { queue.surfaceDidUnmount(sessionID: sessionID) }
        }
        .allowsHitTesting(pendingRequest != nil)
        .id(sessionID)
    }

    private var pendingRequest: IntelConfigApprovalRequest? {
        guard let sessionID else { return nil }
        return queue.pending.first { $0.sessionID == sessionID }
    }

    private func mountSurface() {
        if let sessionID { queue.surfaceDidMount(sessionID: sessionID) }
    }

    private func card(for request: IntelConfigApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.rectangle.portrait")
                    .foregroundColor(theme.accentColor)
                Text("Review configuration changes", bundle: .module)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(theme.primaryText)
                Spacer()
                Text("Gate 5B", bundle: .module)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }

            if request.plan.changes.isEmpty {
                Text("This plan contains no changes.", bundle: .module)
                    .font(.system(size: 12))
                    .foregroundColor(theme.secondaryText)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(request.plan.changes) { change in
                            changeRow(change)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(theme.tertiaryBackground)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1))
                )
            }

            HStack {
                Spacer()
                Button("Cancel") {
                    queue.resolve(id: request.id, outcome: .denied)
                }
                .buttonStyle(.bordered)
                Button("Apply") {
                    queue.resolve(id: request.id, outcome: .approved)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(theme.cardBackground)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.cardBorder, lineWidth: 1))
                .shadow(color: Color.black.opacity(0.2), radius: 16, y: 6)
        )
        .frame(maxWidth: 500)
        .environment(\.theme, theme)
    }

    private func changeRow(_ change: IntelDeclarativeConfigurationChange) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(change.path)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(theme.primaryText)
            HStack(alignment: .top, spacing: 8) {
                valueBox(label: "Before", value: change.before)
                Image(systemName: "arrow.right")
                    .foregroundColor(theme.tertiaryText)
                    .padding(.top, 14)
                valueBox(label: "After", value: change.after)
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.inputBackground)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.inputBorder, lineWidth: 1))
        )
    }

    private func valueBox(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundColor(theme.tertiaryText)
            Text(value)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(theme.secondaryText)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#endif
