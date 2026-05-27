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
                        ChatSessionSidebar(
                            sessions: fSessions,
                            agentId: aId,
                            currentSessionId: sessId,
                            onNewChat: { [weak windowState] in windowState?.startNewChat() }
                        )
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
                        HStack(spacing: 8) {
                            Circle().fill(observedSession.isStreaming ? Color.green : Color.gray).frame(width: 8, height: 8)
                            Text(observedSession.isStreaming ? "Streaming…" : "Idle")
                                .font(.caption).foregroundStyle(.secondary)
                            Text("Model: \(session.selectedModel ?? "none")")
                                .font(.caption2).foregroundStyle(.tertiary)
                            if let err = observedSession.lastStreamError {
                                Text(err).font(.caption).foregroundStyle(.red)
                            }
                        }.padding(.horizontal, 8).padding(.top, 4)
                        if session.hasAnyModel || session.isDiscoveringModels {
                            let _ = observedSession.turns.count
                            if observedSession.turns.isEmpty {
                                VStack(spacing: 16) {
                                    Image(systemName: "bubble.left.and.bubble.right.fill")
                                        .font(.system(size: 40))
                                        .foregroundStyle(theme.secondaryText.opacity(0.4))
                                    Text("New Chat")
                                        .font(theme.font(size: 20, weight: .semibold))
                                        .foregroundStyle(theme.primaryText)
                                    Text("Type a message below to start")
                                        .font(theme.font(size: 14))
                                        .foregroundStyle(theme.secondaryText)
                                }
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                ScrollViewReader { scrollProxy in
                                    ScrollView {
                                        LazyVStack(alignment: .leading, spacing: 0) {
                                            ForEach(Array(observedSession.turns.enumerated()), id: \.offset) { i, turn in
                                                let isUser = turn.role == .user
                                                VStack(alignment: isUser ? .trailing : .leading, spacing: 4) {
                                                    Text(isUser ? "You" : "Assistant")
                                                        .font(theme.font(size: 11, weight: .medium))
                                                        .foregroundStyle(theme.tertiaryText)
                                                        .padding(.leading, isUser ? 0 : 4)
                                                        .padding(.trailing, isUser ? 4 : 0)

                                                    if !turn.thinking.isEmpty {
                                                        DisclosureGroup(
                                                            content: {
                                                                Text(turn.thinking)
                                                                    .font(theme.font(size: 13))
                                                                    .italic()
                                                                    .foregroundStyle(theme.secondaryText)
                                                                    .textSelection(.enabled)
                                                                    .frame(maxWidth: .infinity, alignment: .leading)
                                                            },
                                                            label: { Text("Thinking…").font(theme.font(size: 12, weight: .medium)) }
                                                        )
                                                        .padding(.horizontal, 12)
                                                        .padding(.vertical, 6)
                                                        .background(theme.secondaryBackground.opacity(0.6))
                                                        .clipShape(RoundedRectangle(cornerRadius: 10))
                                                        .frame(maxWidth: effectiveContentWidth * 0.85, alignment: isUser ? .trailing : .leading)
                                                    }

                                                    if !turn.content.isEmpty || (turn.contentIsEmpty && !turn.thinking.isEmpty) {
                                                        if turn.content.isEmpty {
                                                            ProgressView()
                                                                .scaleEffect(0.7)
                                                                .padding(.horizontal, 12)
                                                                .padding(.vertical, 6)
                                                                .background(isUser ? theme.accentColor.opacity(0.15) : theme.secondaryBackground)
                                                                .clipShape(RoundedRectangle(cornerRadius: 14))
                                                                .frame(maxWidth: effectiveContentWidth * 0.85, alignment: isUser ? .trailing : .leading)
                                                        } else {
                                                            Text(turn.content)
                                                                .font(theme.font(size: 14))
                                                                .foregroundStyle(isUser ? theme.primaryText : theme.primaryText)
                                                                .textSelection(.enabled)
                                                                .padding(.horizontal, 14)
                                                                .padding(.vertical, 10)
                                                                .background(isUser ? theme.accentColor.opacity(0.15) : theme.secondaryBackground)
                                                                .clipShape(RoundedRectangle(cornerRadius: 16))
                                                                .frame(maxWidth: effectiveContentWidth * 0.85, alignment: isUser ? .trailing : .leading)
                                                        }
                                                    }
                                                }
                                                .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
                                                .padding(.horizontal, 16)
                                                .padding(.vertical, 6)
                                                .id(i)
                                            }
                                        }
                                        .padding(.vertical, 12)
                                    }
                                    .onChange(of: observedSession.turns.count) { _, _ in
                                        if let last = observedSession.turns.indices.last {
                                            withAnimation { scrollProxy.scrollTo(last, anchor: .bottom) }
                                        }
                                    }
                                    .onChange(of: observedSession.turns.last?.content ?? "") { _, _ in
                                        if let last = observedSession.turns.indices.last {
                                            withAnimation { scrollProxy.scrollTo(last, anchor: .bottom) }
                                        }
                                    }
                                }
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
        .onAppear {
            if session.selectedModel == nil {
                session.selectedModel = "deepseek-v4-pro"
            }
        }
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
