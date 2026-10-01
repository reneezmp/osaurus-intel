//
//  ChatContentView.swift
//  OsaurusCore
//
//  M10.5 Phase 7: Standalone View struct for the entire chat content body.
//  Separated to break opaque type metadata chain in chatModeContent.
//  Single struct avoids the pairwise metadata cycle that plagued
//  ChatInputSection+ChatSidebarSection coexistence.
//

import AppKit
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
    var messageThread: (CGFloat, CGFloat) -> AnyView
    var promptOverlayLayer: AnyView
    var onChatOverlayActivated: () -> Void
    /// Installs / tears down the window-scoped Cmd+F (find bar) and Esc key
    /// monitor. Must run on appear/disappear here — `ChatView.body` just
    /// delegates to `chatModeContent` with no lifecycle hooks of its own
    /// (see `ChatView.setupKeyMonitor`/`cleanupKeyMonitor`), so this was the
    /// only place upstream's monitor wiring could still attach after the
    /// M10.5 Phase 7 extraction into this standalone view. It never got
    /// carried over — `.onDisappear` below was an empty stub — so Cmd+F
    /// silently had no monitor to catch it.
    var onSetupFindKeyMonitor: () -> Void
    var onCleanupFindKeyMonitor: () -> Void
    var handleChatToolbarSelectDiscovered: (Notification) -> Void
    var onRelayAgentNotify: (Notification) -> Void
    var onPickerItemsChanged: ([ModelPickerItem]) -> Void
    var onChangeSelectedProvider: (UUID?) -> Void
    var whatsNewContent: (WhatsNewRelease) -> AnyView
    var agentSheetContent: (DiscoveredAgent) -> AnyView

    // Measured header + composer heights so the message thread can get an EXPLICIT
    // height (window − header − composer) and STOP above the composer instead of
    // scrolling behind it. On Ventura the NSScrollView ignores a flexible maxHeight
    // (it inflates to its content height); only an explicit frame bounds it.
    // (Renée, 2026-06-13.)
    /// Observed so the project page and its settings rail follow renames
    /// and edits (upstream `ChatView` observes it the same way).
    @ObservedObject private var projectManager = ProjectManager.shared
    @State private var measuredHeaderHeight: CGFloat = 44
    @State private var measuredComposerHeight: CGFloat = 100

    /// User-adjustable width of the History sidebar, persisted across launches
    /// so a chosen width sticks. Clamped to `sidebarWidthRange` on read so a
    /// stale out-of-bounds value can never wedge the layout. Upstream 035ed272.
    @AppStorage("chatSidebarWidth") private var storedSidebarWidth: Double = 240
    /// Transient width while an edge drag is in flight. Kept in view state so
    /// the resize tracks the cursor at 60fps without hitting UserDefaults on
    /// every frame; the final value is committed to `storedSidebarWidth` on
    /// drag end. `nil` means no drag is active.
    @State private var liveSidebarWidth: Double?
    /// Allowed range for the resizable sidebar. The floor keeps the header
    /// controls usable; the ceiling stops the sidebar from crowding out the
    /// chat on narrow windows.
    private static let sidebarWidthRange: ClosedRange<Double> = 260...460

    /// Clamp a raw width to the allowed range.
    private func clampSidebarWidth(_ raw: Double) -> Double {
        min(max(raw, Self.sidebarWidthRange.lowerBound), Self.sidebarWidthRange.upperBound)
    }

    /// Effective sidebar width: the live drag value while resizing, otherwise
    /// the persisted width. Always clamped.
    private var clampedSidebarWidth: CGFloat {
        CGFloat(clampSidebarWidth(liveSidebarWidth ?? storedSidebarWidth))
    }

    /// Draggable divider on the sidebar's trailing edge (shared control with
    /// the inspector's leading edge). Upstream `ColumnResizeHandle`.
    private var sidebarResizeHandle: some View {
        ColumnResizeHandle(
            edge: .trailing,
            range: Self.sidebarWidthRange,
            storedWidth: $storedSidebarWidth,
            liveWidth: $liveSidebarWidth
        )
    }

    // MARK: Inspector (upstream #2907 part C)

    /// User-adjustable width of the right-hand inspector, persisted like the
    /// sidebar's and clamped to `inspectorWidthRange` on read.
    @AppStorage("chatInspectorWidth") private var storedInspectorWidth: Double = ChatContentView.defaultInspectorWidth
    /// Transient inspector width while its edge drag is in flight.
    @State private var liveInspectorWidth: Double?

    /// Allowed range for the resizable inspector. Same floor as the
    /// inspector's squeeze limit; the ceiling keeps the chat column readable.
    static let inspectorWidthRange: ClosedRange<Double> = 300...520
    /// Design width the inspector opens at before the user resizes it.
    static let defaultInspectorWidth: Double = 380
    /// Chat column kept readable beside the inspector.
    private static let chatColumnMinWidthWithPanel: CGFloat = 440

    static func clampInspectorWidth(_ raw: Double) -> Double {
        min(max(raw, inspectorWidthRange.lowerBound), inspectorWidthRange.upperBound)
    }

    private var clampedInspectorWidth: CGFloat {
        CGFloat(Self.clampInspectorWidth(liveInspectorWidth ?? storedInspectorWidth))
    }

    private var inspectorResizeHandle: some View {
        ColumnResizeHandle(
            edge: .leading,
            range: Self.inspectorWidthRange,
            storedWidth: $storedInspectorWidth,
            liveWidth: $liveInspectorWidth
        )
    }

    /// The inspector pane on screen, if any. Hidden on the project page,
    /// which has no chat to inspect; the requested pane stays remembered.
    nonisolated static func visibleInspectorPane(
        requested: ChatInspectorPane?,
        isProjectPageOpen: Bool
    ) -> ChatInspectorPane? {
        guard let requested, !isProjectPageOpen else { return nil }
        return requested
    }

    /// Whether the sidebar steps aside (not persisted) for the inspector:
    /// both only stay up once the window can hold the sidebar at its
    /// current width, a readable chat column and the inspector at its floor.
    nonisolated static func sidebarStepsAside(
        windowWidth: CGFloat, sidebarWidth: CGFloat, inspectorOpen: Bool
    ) -> Bool {
        inspectorOpen
            && windowWidth < sidebarWidth + chatColumnMinWidthWithPanel + CGFloat(inspectorWidthRange.lowerBound)
    }

    /// Inspector width for a window of `totalWidth`: the user's chosen width
    /// when it fits, otherwise squeezed down to its floor before the chat
    /// column gives.
    nonisolated static func changesPanelWidth(
        totalWidth: CGFloat, sidebarWidth: CGFloat, preferredWidth: CGFloat
    ) -> CGFloat {
        let available = totalWidth - sidebarWidth - chatColumnMinWidthWithPanel
        let preferred = CGFloat(clampInspectorWidth(Double(preferredWidth)))
        return min(preferred, max(CGFloat(inspectorWidthRange.lowerBound), available))
    }

    /// The left rail (Agents | Projects), with every window-level handoff
    /// it needs. Upstream `navigatorRail(width:)`, minus workspace and
    /// network agents (docs/CHAT_WINDOW_LAYOUT_INTEL.md).
    /// First line of the user message that led to `turnId`, for the File
    /// Changes timeline's turn headers. Upstream (`ChatView`).
    private func userPromptExcerpt(for turnId: UUID) -> String? {
        let turns = session.turns
        guard let index = turns.firstIndex(where: { $0.id == turnId }) else { return nil }
        guard let user = turns[..<index].last(where: { $0.role == .user }) else { return nil }
        let line = user.content.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return trimmed.count > 120 ? String(trimmed.prefix(120)) + "…" : trimmed
    }

    private func navigatorRail(width sidebarWidth: CGFloat) -> some View {
        ChatSessionSidebar(
            sessions: windowState.filteredSessions,
            agentId: windowState.agentId,
            keepsProjectsLens: windowState.enteredChatFromProjectPage,
            width: sidebarWidth,
            onSelect: { [weak windowState] data in
                windowState?.openProjectId = nil
                windowState?.enteredChatFromProjectPage = false
                windowState?.loadSession(data)
                isPinnedToBottom = true
            },
            onDeleteProject: { [weak windowState] id in
                ChatSessionsManager.shared.deleteProject(id: id)
                // The open chat may have been a member; its next
                // auto-save must not resurrect the id.
                windowState?.syncTabSessions(withProjectId: id) { $0.projectId = nil }
                if windowState?.openProjectId == id {
                    windowState?.openProjectId = nil
                }
                windowState?.refreshSessions()
            },
            onOpenProject: { [weak windowState] project in
                windowState?.openProjectId = project.id
            },
            openProjectId: windowState.openProjectId,
            onStop: { [weak windowState] id in
                // This window's own run stops directly; anything else
                // routes through the monitor.
                if windowState?.session.sessionId == id {
                    windowState?.session.stop()
                } else {
                    SessionActivityMonitor.shared.stop(sessionId: id)
                }
            },
            onOpenInNewTab: { [weak windowState] data in
                windowState?.openProjectId = nil
                windowState?.enteredChatFromProjectPage = false
                windowState?.openSessionInNewTab(data)
            },
            onSelectAgent: { [weak windowState] newAgentId in
                windowState?.switchAgent(to: newAgentId)
            },
            onNewChatWithAgent: { [weak windowState] newAgentId in
                windowState?.startNewChat(with: newAgentId)
                isPinnedToBottom = true
            }
        )
    }

    private func publishRailGeometry(sidebarAutoHidden: Bool, inspectorWidth: CGFloat) {
        if windowState.isSidebarAutoHidden != sidebarAutoHidden {
            windowState.isSidebarAutoHidden = sidebarAutoHidden
        }
        if windowState.inspectorColumnWidth != inspectorWidth {
            windowState.inspectorColumnWidth = inspectorWidth
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let windowWidth: CGFloat = proxy.size.width
            let inspectorPane = Self.visibleInspectorPane(
                requested: windowState.effectiveInspectorPane,
                isProjectPageOpen: windowState.openProjectId != nil)
            let projectInspectorVisible = windowState.isProjectPageVisible && windowState.showProjectInspector
            let inspectorVisible = inspectorPane != nil || projectInspectorVisible
            let sidebarAutoHidden =
                windowState.showSidebar
                && Self.sidebarStepsAside(
                    windowWidth: windowWidth,
                    sidebarWidth: clampedSidebarWidth,
                    inspectorOpen: inspectorVisible)
            let sidebarVisible = windowState.showSidebar && !sidebarAutoHidden
            let sidebarWidth: CGFloat = sidebarVisible ? clampedSidebarWidth : 0
            let inspectorWidth: CGFloat =
                inspectorVisible
                ? Self.changesPanelWidth(
                    totalWidth: windowWidth,
                    sidebarWidth: sidebarWidth,
                    preferredWidth: clampedInspectorWidth) : 0
            let chatWidth = windowWidth - sidebarWidth - inspectorWidth
            let effectiveContentWidth = min(chatWidth, 1100)
            let chromeHeight = measuredHeaderHeight + measuredComposerHeight
            let threadHeight = max(80, proxy.size.height - chromeHeight)

            HStack(alignment: .top, spacing: 0) {
                // Sidebar (navigator: Agents | Projects)
                VStack(alignment: .leading, spacing: 0) {
                    if sidebarVisible {
                        navigatorRail(width: sidebarWidth)
                    }
                }
                .frame(width: sidebarWidth, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)
                .clipped()
                .overlay(alignment: .trailing) {
                    if sidebarVisible {
                        sidebarResizeHandle
                    }
                }
                .zIndex(1)

                // Main chat area
                ZStack {
                    chatBackground
                    if let project = projectManager.project(for: windowState.openProjectId) {
                        // A project is open: the main area shows upstream's
                        // project page (a folder of chats) instead of the
                        // chat thread/composer; its settings are in the
                        // right rail. `chatBackground` above stays so the
                        // window chrome is continuous.
                        ProjectDetailView(
                            project: project,
                            windowState: windowState,
                            onOpenSession: { [weak windowState] data in
                                windowState?.openProjectId = nil
                                windowState?.enteredChatFromProjectPage = true
                                windowState?.loadSession(data)
                                isPinnedToBottom = true
                            },
                            onNewChat: { [weak windowState] in windowState?.startNewChat(in: project) },
                            onDelete: { [weak windowState] in
                                ChatSessionsManager.shared.deleteProject(id: project.id)
                                windowState?.syncTabSessions(withProjectId: project.id) { $0.projectId = nil }
                                windowState?.openProjectId = nil
                                windowState?.refreshSessions()
                            }
                        )
                        // Intel: keyed to the project id so a switch is a
                        // full rebuild with fresh state (the instructions
                        // migration fix, 3fc23c3eb).
                        .id(project.id)
                        .transition(.opacity)
                    } else {
                    VStack(spacing: 0) {
                        chatHeader
                            .background(
                                GeometryReader { g in
                                    Color.clear.preference(
                                        key: ChatHeaderHeightKey.self, value: g.size.height)
                                }
                            )
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
                                // EXPLICIT height = window − header − composer so the
                                // thread STOPS above the composer (instead of scrolling
                                // behind it). The NSScrollView ignores a flexible
                                // maxHeight on Ventura — it inflates to its content
                                // height — so only an explicit frame bounds it.
                                // (Renée, 2026-06-13.)
                                // messageThread self-sizes to `threadHeight` and
                                // clips its scroll view internally (overlays float
                                // outside that clip). (Renée, 2026-06-13.)
                                messageThread(effectiveContentWidth, threadHeight)
                                    .frame(maxWidth: .infinity)
                            }
                        } else {
                            VStack(spacing: 16) {
                                ProgressView().scaleEffect(0.8)
                                Text("Discovering models…").font(theme.font(size: 13)).foregroundStyle(theme.secondaryText)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .transition(.opacity)
                        }
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
                            // Compact when a side column (sidebar or
                            // inspector) narrows the chat.
                            isCompact: sidebarVisible || inspectorVisible,
                            // Never wired up: FloatingInputCard's built-in /clear
                            // handler falls back to a "pass a handler" toast
                            // without this. Mirrors the Cmd+N "New Chat" action
                            // (`ChatWindowState.startNewChat()`) — same
                            // save-current/flush/reset-session/refresh-sidebar
                            // behavior the toolbar button and shortcut use.
                            onClearChat: { [weak windowState] in
                                windowState?.startNewChat()
                            },
                            onGenerateTitle: { [weak observedSession] in
                                observedSession?.generateTitleFromSlashCommand()
                            },
                            onCompact: { [weak observedSession] in
                                observedSession?.compactConversation()
                            },
                            isCompacting: observedSession.isCompacting,
                            suggestCompaction: observedSession.shouldSuggestCompaction,
                            autoSpeakAssistant: $observedSession.autoSpeakAssistant,
                            queuedSend: $observedSession.queuedSend,
                            folderState: observedSession.folderState,
                            onDraftChange: { [weak observedSession] in
                                observedSession?.noteComposerDraft($0)
                            },
                            onWillRehydrate: { [weak observedSession] in
                                observedSession?.promoteComposerDraft()
                            }
                        )
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)
                        .background(
                            GeometryReader { g in
                                Color.clear.preference(
                                    key: ChatComposerHeightKey.self, value: g.size.height)
                            }
                        )
                    }
                    }
                }
                // Pin the chat column to the WINDOW's height (GeometryReader) and clip,
                // so a mis-measure can never push content past the window. The thread
                // gets an explicit height (above) computed from the measured header +
                // composer, so it stops above the composer with a real scrollbar.
                // (Renée, 2026-06-13.)
                .frame(height: proxy.size.height)
                .clipped()
                .onPreferenceChange(ChatHeaderHeightKey.self) { measuredHeaderHeight = $0 }
                .onPreferenceChange(ChatComposerHeightKey.self) { measuredComposerHeight = $0 }

                // Right-hand rail: this chat's inspector (History; File
                // Changes once file history is ported) or, while a project
                // is on screen, that project's settings. One toolbar toggle,
                // one width, one resize seam.
                VStack(alignment: .leading, spacing: 0) {
                    if projectInspectorVisible,
                        let project = projectManager.project(for: windowState.openProjectId)
                    {
                        ProjectInspectorPanel(
                            project: project,
                            currentAgentId: windowState.agentId,
                            width: inspectorWidth
                        )
                        // Intel: a fresh instance per project, like the page.
                        .id(project.id)
                    } else if let inspectorPane {
                        ChatInspectorPanel(
                            windowState: windowState,
                            pane: inspectorPane,
                            width: inspectorWidth,
                            sessionId: session.sessionId,
                            focusSetId: $windowState.changesPanelFocusSetId,
                            userPrompt: { userPromptExcerpt(for: $0) },
                            // Same route as a sidebar row: the chat opens in
                            // the current tab and the rail stays up.
                            onSelectSession: { [weak windowState] data in
                                windowState?.openProjectId = nil
                                windowState?.enteredChatFromProjectPage = false
                                windowState?.loadSession(data)
                                isPinnedToBottom = true
                            }
                        )
                    }
                }
                .frame(width: inspectorWidth, alignment: .top)
                .frame(maxHeight: .infinity, alignment: .top)
                .clipped()
                .overlay(alignment: .leading) {
                    if inspectorVisible {
                        inspectorResizeHandle
                    }
                }
                .zIndex(1)
            }
            .animation(theme.animationQuick(), value: inspectorVisible)
            // Publish the geometry-driven step-aside so the toolbar toggle
            // and tab strip describe the sidebar actually on screen.
            // Intel: single-value `onChange` plus `onAppear` (macOS 13).
            .onAppear {
                publishRailGeometry(sidebarAutoHidden: sidebarAutoHidden, inspectorWidth: inspectorWidth)
            }
            .onChange(of: sidebarAutoHidden) { hidden in
                publishRailGeometry(sidebarAutoHidden: hidden, inspectorWidth: inspectorWidth)
            }
            // Same for the right rail's width: the strip insets its trailing
            // edge by it so the tabs end where the chat column ends (#2910).
            .onChange(of: inspectorWidth) { width in
                publishRailGeometry(sidebarAutoHidden: sidebarAutoHidden, inspectorWidth: width)
            }
            .onDisappear {
                windowState.isSidebarAutoHidden = false
                windowState.inspectorColumnWidth = 0
            }
        }
        .frame(
            minWidth: windowState.minimumContentSize.width,
            idealWidth: 950,
            maxWidth: .infinity,
            minHeight: windowState.minimumContentSize.height,
            idealHeight: 610,
            maxHeight: .infinity
        )
        // The native Intel chat window already supplies the real macOS corner
        // mask. A second SwiftUI mask here cuts the content inward and leaves
        // the window background visible as gray wedges at all four corners.
        // Keep the upstream rounded content treatment for Apple Silicon.
        #if OSAURUS_INTEL
        .clipShape(Rectangle())
        #else
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        #endif
        #if OSAURUS_INTEL
        // The native frame clips the full-size hosting view at the correct
        // Ventura window radius. Its default backing color is AppKit gray,
        // though, and the antialiased edge exposes a one-pixel gray crescent
        // between that frame and the themed SwiftUI content. Keep the backing
        // synchronized with the active theme so those edge pixels disappear.
        .background(
            IntelChatWindowBackingColor(color: NSColor(theme.primaryBackground))
        )
        #endif
        .ignoresSafeArea()
        .onReceive(NotificationCenter.default.publisher(for: .chatToolbarBackToProject)) { notification in
            guard let targetWindowId = notification.userInfo?["windowId"] as? UUID,
                targetWindowId == windowState.windowId
            else { return }
            windowState.openProjectId = session.projectId
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatOverlayActivated)) { _ in
            focusTrigger &+= 1; isPinnedToBottom = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatToolbarSelectDiscoveredAgent)) { n in
            handleChatToolbarSelectDiscovered(n)
        }
        .onReceive(NotificationCenter.default.publisher(for: .chatToolbarSelectRelayAgent)) { _ in }
        .onReceive(NotificationCenter.default.publisher(for: .vadStartNewSession)) { _ in }
        .onAppear {
            session.applyInitialModelSelection()
            onSetupFindKeyMonitor()
        }
        .onDisappear {
            onCleanupFindKeyMonitor()
        }
        .onChange(of: observedSession.pickerItems) { newItems in
            onPickerItemsChanged(newItems)
        }
        .onChange(of: windowState.selectedDiscoveredAgentProviderId) { providerId in
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

#if OSAURUS_INTEL
private struct IntelChatWindowBackingColor: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> BackingColorView {
        BackingColorView(color: color)
    }

    func updateNSView(_ nsView: BackingColorView, context: Context) {
        nsView.color = color
        nsView.applyColor()
    }

    final class BackingColorView: NSView {
        var color: NSColor

        init(color: NSColor) {
            self.color = color
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyColor()
        }

        func applyColor() {
            window?.backgroundColor = color
        }
    }
}
#endif

// Measured heights of the chat chrome, used to give the message thread an explicit
// height (window − header − composer) so it stops above the composer.
private struct ChatHeaderHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

private struct ChatComposerHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
