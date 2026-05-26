//
//  ChatContentView.swift
//  OsaurusCore
//
//  M10.5 Phase 7: Standalone View struct for the entire chat content body.
//  Separated to break opaque type metadata chain in chatModeContent.
//  Single struct avoids the pairwise metadata cycle that plagued
//  ChatInputSection+ChatSidebarSection coexistence.
//

import SwiftUI

struct ChatContentView: View {
    @ObservedObject var windowState: ChatWindowState
    @ObservedObject var observedSession: ChatSession
    @ObservedObject var session: ChatSession
    @Binding var pendingWhatsNew: WhatsNewRelease?
    @Binding var pendingDiscoveredAgent: DiscoveredAgent?
    @Binding var focusTrigger: Int
    @Binding var isPinnedToBottom: Bool
    var filteredPickerItems: [ModelPickerItem]
    var theme: ThemeProtocol
    var keyMonitor: Any?
    var chatBackground: AnyView
    var chatHeader: AnyView
    var emptyStateView: AnyView
    var messageThread: (CGFloat) -> AnyView
    var promptOverlayLayer: AnyView
    var onChatOverlayActivated: () -> Void
    var handleChatToolbarSelectDiscovered: (Notification) -> Void
    var onRelayAgentNotify: (Notification) -> Void
    var onPickerItemsChanged: ([ModelPickerItem]) -> Void
    var onChangeSelectedProvider: (UUID?) -> Void
    var whatsNewContent: (WhatsNewRelease) -> AnyView
    var agentSheetContent: (DiscoveredAgent) -> AnyView

    var body: some View {
        GeometryReader { proxy in
            let windowWidth: CGFloat = proxy.size.width
            let showSidebar: Bool = windowState.showSidebar
            let sidebarWidth: CGFloat = showSidebar ? 240 : 0
            let chatWidth = windowWidth - sidebarWidth
            let effectiveContentWidth = min(chatWidth, 1100)

            HStack(alignment: .top, spacing: 0) {
                // Sidebar
                let fSessions: [ChatSessionData] = windowState.filteredSessions
                let aId: UUID = windowState.agentId
                let sessId: UUID? = session.sessionId
                VStack(alignment: .leading, spacing: 0) {
                    if windowState.showSidebar {
                        ChatSessionSidebar(sessions: fSessions, agentId: aId, currentSessionId: sessId)
                    }
                }
                .frame(width: sidebarWidth, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)
                .clipped()
                .zIndex(1)

                // Main chat area
                ZStack {
                    chatBackground
                    VStack(spacing: 0) {
                        chatHeader
                        if session.hasAnyModel || session.isDiscoveringModels {
                            if !session.hasVisibleThreadMessages {
                                emptyStateView
                            } else {
                                messageThread(effectiveContentWidth)
                                    .blur(radius: false ? 1.5 : 0)
                                    .allowsHitTesting(true)
                                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                            }
                        } else {
                            VStack(spacing: 16) {
                                ProgressView().scaleEffect(0.8)
                                Text("Discovering models…").font(theme.font(size: 13)).foregroundStyle(theme.secondaryText)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
                        }
                        Spacer()
                        HStack(spacing: 8) {
                            TextField("Message", text: $observedSession.input)
                                .textFieldStyle(.plain)
                                .font(theme.font(size: 14))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                            if observedSession.isStreaming {
                                Button(action: { observedSession.stop() }) {
                                    Image(systemName: "stop.fill").font(.system(size: 14))
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
            }
        }
        .frame(minWidth: 800, idealWidth: 950, maxWidth: .infinity, minHeight: 575, idealHeight: 610, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: .chatOverlayActivated)) { _ in
            focusTrigger &+= 1; isPinnedToBottom = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatToolbarSelectDiscoveredAgent)) { n in
            handleChatToolbarSelectDiscovered(n)
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatToolbarSelectRelayAgent)) { _ in }
        .onReceive(NotificationCenter.default.publisher(for: .vadStartNewSession)) { _ in }
        .onAppear {}
        .onDisappear {}
        .onChange(of: observedSession.pickerItems) { _, newItems in
            onPickerItemsChanged(newItems)
        }
        .onChange(of: windowState.selectedDiscoveredAgentProviderId) { _, providerId in
            onChangeSelectedProvider(providerId)
        }
        .environment(\.theme, windowState.theme)
        .tint(theme.accentColor)
        .sheet(item: $pendingWhatsNew) { release in
            whatsNewContent(release)
        }
        .sheet(item: $pendingDiscoveredAgent) { agent in
            agentSheetContent(agent)
        }
    }
}
