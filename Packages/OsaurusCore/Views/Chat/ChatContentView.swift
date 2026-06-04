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
                            onSelect: { [weak windowState] data in windowState?.loadSession(data) },
                            onNewChat: { [weak windowState] in windowState?.startNewChat() },
                            onDelete: { [weak windowState] id in
                                guard let windowState else { return }
                                // If the row being deleted is the session
                                // currently loaded in this window, reset the
                                // live session FIRST. Otherwise the live
                                // session still holds that id + its turns and
                                // re-persists itself on the next send() or via
                                // the synchronous save() inside reset()→stop()→
                                // completeRunCleanup — resurrecting the row we
                                // just deleted. startNewChat may re-save it, so
                                // delete AFTER to guarantee it's gone.
                                if windowState.session.sessionId == id {
                                    windowState.startNewChat()
                                }
                                ChatSessionsManager.shared.delete(id: id)
                                windowState.refreshSessions()
                            },
                            onRename: { [weak windowState] id, title in
                                ChatSessionsManager.shared.rename(id: id, title: title)
                                windowState?.refreshSessions()
                            },
                            onSetArchived: { [weak windowState] id, archived in
                                ChatSessionsManager.shared.setArchived(id: id, archived: archived)
                                windowState?.refreshSessions()
                            },
                            onExport: { _, _ in
                                // Export pipeline is amputated on Intel
                                // (ChatSessionExportCoordinator + ExportChooserSheet
                                // both live in excluded files). The Export menu
                                // item is gated to hidden inside the sidebar.
                            }
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
                        chatHeader
                        if let err = observedSession.lastStreamError {
                            Text(err)
                                .font(.caption)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .transition(.move(edge: .top).combined(with: .opacity))
                        }
                        if session.hasAnyModel || session.isDiscoveringModels {
                            let _ = observedSession.turns.count
                            if observedSession.turns.isEmpty {
                                emptyStateView
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            } else {
                                messageThread(effectiveContentWidth)
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
                        FloatingInputCard(
                            text: $observedSession.input,
                            selectedModel: $observedSession.selectedModel,
                            pendingAttachments: $observedSession.pendingAttachments,
                            isContinuousVoiceMode: $observedSession.isContinuousVoiceMode,
                            voiceInputState: $observedSession.voiceInputState,
                            showVoiceOverlay: $observedSession.showVoiceOverlay,
                            pickerItems: filteredPickerItems,
                            activeModelOptions: $observedSession.activeModelOptions,
                            isStreaming: observedSession.isStreaming,
                            supportsImages: false,
                            estimatedContextTokens: observedSession.estimatedContextTokens,
                            contextBreakdown: observedSession.estimatedContextBreakdown,
                            onSend: { [weak observedSession] sentText in
                                // FloatingInputCard clears the `text` binding (which
                                // is $observedSession.input) just BEFORE calling
                                // onSend, so `session.sendCurrent()` would see an
                                // empty input and silently no-op. Instead, route
                                // the text it passes us directly through `send(_:
                                // attachments:)` which is what sendCurrent calls
                                // internally anyway.
                                guard let session = observedSession else { return }
                                let attachments = session.pendingAttachments
                                session.pendingAttachments = []
                                let body = sentText ?? ""
                                guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                    || !attachments.isEmpty
                                else { return }
                                session.send(body, attachments: attachments)
                            },
                            onStop: { [weak observedSession] in observedSession?.stop() },
                            focusTrigger: focusTrigger,
                            agentId: windowState.agentId,
                            windowId: windowState.windowId,
                            isCompact: windowState.showSidebar,
                            autoSpeakAssistant: $observedSession.autoSpeakAssistant,
                            queuedSend: $observedSession.queuedSend
                        )
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
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
