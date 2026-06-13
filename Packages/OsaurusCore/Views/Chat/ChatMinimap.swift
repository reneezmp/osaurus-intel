//
//  ChatMinimap.swift
//  osaurus
//
//  Thin vertical minimap showing one row per user message. Collapsed,
//  each row is a short horizontal tick. On hover, the container grows
//  and each tick morphs into a vertical handle paired with a number
//  and single-line preview of the user message. Clicking a row scrolls
//  the thread to that turn.
//

import SwiftUI

struct ChatMinimap: View {
    struct Marker: Identifiable, Equatable {
        /// Turn ID of the user message.
        let id: UUID
        let preview: String
    }

    let markers: [Marker]
    let activeMarkerId: UUID?
    let onSelect: (UUID) -> Void

    @Environment(\.theme) private var theme
    // Hoisted to the parent (ChatView) so it survives the `AnyView` identity
    // erasure on the messageThread closure — otherwise scroll-driven re-renders
    // reset it and the expanded minimap collapses mid-scroll. (Renée, 2026-06-13.)
    @Binding var isExpanded: Bool

    private let expandAnimation = Animation.spring(response: 0.36, dampingFraction: 0.86)

    var body: some View {
        let rows = VStack(alignment: .leading, spacing: isExpanded ? 1 : 6) {
            ForEach(markers) { m in
                row(for: m)
            }
        }
        .padding(.vertical, isExpanded ? 6 : 10)
        .padding(.horizontal, isExpanded ? 6 : 7)

        return Group {
            if isExpanded {
                // Expanded, a long chat's prompt list can exceed the window, so
                // make it independently scrollable to reach every prompt. Fills
                // the available height (see the minimap overlay in messageThread)
                // so the ScrollView has a bounded height to scroll within.
                // (Renée, 2026-06-13.)
                ScrollView(.vertical, showsIndicators: false) {
                    rows
                }
                .frame(width: 240)
                .frame(maxHeight: .infinity)
            } else {
                rows
                    .frame(width: 24, alignment: .trailing)
            }
        }
        .background(containerBackground)
        // Collapsed, the strip is translucent so the message text reads through
        // it instead of being covered; it becomes fully opaque on hover (and the
        // 24pt frame still catches the hover to expand). (Renée, 2026-06-13.)
        .opacity(isExpanded ? 1.0 : 0.3)
        .animation(expandAnimation, value: isExpanded)
        .onHover { hovering in
            isExpanded = hovering
        }
    }

    // MARK: - Background

    private var containerBackground: some View {
        let shape = RoundedRectangle(cornerRadius: isExpanded ? 10 : 8, style: .continuous)
        return
            shape
            .fill(theme.secondaryBackground.opacity(isExpanded ? 0.96 : 0.70))
            .overlay(
                shape.strokeBorder(
                    theme.secondaryText.opacity(0.14),
                    lineWidth: 1
                )
            )
            .shadow(
                color: theme.shadowColor.opacity(isExpanded ? 0.25 : 0.12),
                radius: isExpanded ? 12 : 5,
                x: 0,
                y: isExpanded ? 3 : 1
            )
    }

    // MARK: - Row

    private func row(for marker: Marker) -> some View {
        let isActive = marker.id == activeMarkerId

        return Button {
            guard isExpanded else { return }
            onSelect(marker.id)
        } label: {
            HStack(spacing: 10) {
                handle(isActive: isActive)

                if isExpanded {
                    Text(displayText(for: marker))
                        .font(.system(size: 12))
                        .foregroundColor(isActive ? theme.primaryText : theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.vertical, isExpanded ? 4 : 0)
            .padding(.horizontal, isExpanded ? 6 : 0)
            .frame(maxWidth: .infinity, alignment: isExpanded ? .leading : .trailing)
            .background(rowBackground(isActive: isActive))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func handle(isActive: Bool) -> some View {
        let color: Color = isActive ? theme.accentColor : theme.secondaryText.opacity(0.5)
        let width: CGFloat = isExpanded ? 3 : (isActive ? 12 : 10)
        let height: CGFloat = isExpanded ? 14 : 2
        return Capsule(style: .continuous)
            .fill(color)
            .frame(width: width, height: height)
    }

    private func rowBackground(isActive: Bool) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(isExpanded && isActive ? theme.accentColor.opacity(0.16) : Color.clear)
    }

    private func displayText(for marker: Marker) -> String {
        let trimmed = marker.preview.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "(empty message)" }
        return trimmed.replacingOccurrences(of: "\n", with: " ")
    }
}
