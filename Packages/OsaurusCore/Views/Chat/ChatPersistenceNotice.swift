//
//  ChatPersistenceNotice.swift
//  osaurus
//
//  Upstream's `ChatPersistenceStatus` and `ChatPersistenceNotice`
//  (`ChatSessionStore` save retry, #1737 / #2736), over Intel's
//  `ChatSessionsManager`. W-cov-reaudit 5a (2026-11-11). Upstream draws the
//  notice with its design-system catalog; Intel uses the run-progress
//  notice's row style.
//

import Combine
import SwiftUI

/// Chats whose latest save failed and is waiting for a retry.
@MainActor
final class ChatPersistenceStatus: ObservableObject {
    static let shared = ChatPersistenceStatus()
    @Published var unsaved: Set<UUID> = []
}

struct ChatPersistenceNotice: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var status = ChatPersistenceStatus.shared
    let sessionId: UUID?

    var body: some View {
        if let sessionId, status.unsaved.contains(sessionId) {
            HStack(spacing: 8) {
                Image(systemName: "externaldrive.badge.exclamationmark")
                    .font(.system(size: CGFloat(theme.captionSize), weight: .semibold))
                    .foregroundColor(theme.warningColor)
                Text(localized: "History isn't saved yet. Retrying automatically; keep Osaurus open.")
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: { ChatSessionsManager.shared.retryUnsaved() }) {
                    Text(localized: "Retry")
                        .font(theme.font(size: CGFloat(theme.captionSize), weight: .semibold))
                        .foregroundColor(theme.warningColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(theme.warningColor.opacity(theme.isDark ? 0.14 : 0.10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(theme.warningColor.opacity(0.22), lineWidth: 1)
            )
            .padding(.bottom, 8)
            .accessibilityElement(children: .contain)
            .transition(.opacity)
        }
    }
}
