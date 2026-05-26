//
//  ChatInputSection.swift
//  OsaurusCore
//
//  M10.5 Phase 7B: Minimal Intel-native chat input replacing FloatingInputCard.
//  Concrete types only — eliminates 20+ generic params from metadata graph
//  (breaking runtime _swift_getGenericMetadata cycle) while providing
//  working text input + send/stop + Enter support + theme-aware styling.
//

import SwiftUI

struct ChatInputSection: View {
    @ObservedObject var observedSession: ChatSession
    @ObservedObject var windowState: ChatWindowState
    var filteredPickerItems: [ModelPickerItem]
    var focusTrigger: Int
    var isPromptOverlayActive: Bool
    var theme: ThemeProtocol

    var body: some View {
        HStack(spacing: 8) {
            TextField("Message", text: $observedSession.input)
                .textFieldStyle(.plain)
                .font(theme.font(size: 14))
                .padding(.horizontal, 14)
                .padding(.vertical, 10)

            if observedSession.isStreaming {
                Button(action: { observedSession.stop() }) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14))
                }
                .buttonStyle(.borderless)
            } else {
                Button(action: { observedSession.sendCurrent() }) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 20))
                        .foregroundStyle(
                            observedSession.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                ? theme.secondaryText : theme.accentColor
                        )
                }
                .buttonStyle(.borderless)
                .disabled(observedSession.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(.horizontal, 10)
        .background(theme.secondaryBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(theme.primaryBorder, lineWidth: 1))
    }
}
