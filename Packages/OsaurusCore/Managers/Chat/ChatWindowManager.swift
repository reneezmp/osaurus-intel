#if !OSAURUS_INTEL
//
//  ChatWindowManager.swift
//  osaurus
//
//  Manages multiple chat windows, each representing an independent session.
//  Handles window lifecycle, focus tracking, and VAD routing.
//

import AppKit
import Combine
import SwiftUI

/// Represents an active chat window with its associated session
public struct ChatWindowInfo: Identifiable, Sendable {
    public let id: UUID
    public let agentId: UUID
    public let sessionId: UUID?
    public let createdAt: Date

    public init(id: UUID = UUID(), agentId: UUID, sessionId: UUID? = nil, createdAt: Date = Date()) {
        self.id = id
        self.agentId = agentId
        self.sessionId = sessionId
        self.createdAt = createdAt
    }
}

/// Manages multiple chat windows in the application
@MainActor
public final class ChatWindowManager: NSObject, ObservableObject {
    public static let shared = ChatWindowManager()

    // MARK: - Published State

    /// All active chat windows
    @Published public private(set) var windows: [UUID: ChatWindowInfo] = [:]

    /// The last focused chat window ID (for hotkey toggle)
    @Published public private(set) var lastFocusedWindowId: UUID?

    // MARK: - Private State

    private var nsWindows: [UUID: NSWindow] = [:]
    private var windowDelegates: [UUID: ChatWindowDelegate] = [:]
    private var windowStates: [UUID: ChatWindowState] = [:]
    private var sessionCallbacks: [UUID: () -> Void] = [:]

    /// Sleep/wake observers on `NSWorkspace.shared.notificationCenter`.
    /// Held so we can detach them in `deinit`. Pause the greeting pool
    /// on sleep so a closed laptop doesn't keep firing background
    /// inferences against the GPU.
    nonisolated(unsafe) private var sleepObserver: NSObjectProtocol?
    nonisolated(unsafe) private var wakeObserver: NSObjectProtocol?

    private override init() {
        super.init()
        installSleepWakeObservers()
    }

    deinit {
        let nc = NSWorkspace.shared.notificationCenter
        if let token = sleepObserver { nc.removeObserver(token) }
        if let token = wakeObserver { nc.removeObserver(token) }
    }

    /// Hook NSWorkspace's sleep/wake notifications to the pool's
    /// pause/resume seam. Notifications from `NSWorkspace` arrive on
    /// the main thread, but the pool is an actor so we hop through
    /// `Task` to call into it.
    private func installSleepWakeObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        sleepObserver = nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { await GenerativeGreetingPool.shared.pause() }
        }
        wakeObserver = nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { _ in
            Task { await GenerativeGreetingPool.shared.resume() }
        }
    }

    // MARK: - Public API

    /// Create a new chat window with default agent
    /// - Parameters:
    ///   - agentId: The agent for this window (defaults to active agent)
    ///   - showImmediately: Whether to show the window immediately (default: true)
    /// - Returns: The window identifier
    @discardableResult
    public func createWindow(agentId: UUID? = nil, showImmediately: Bool = true) -> UUID {
        return createWindowInternal(agentId: agentId, sessionData: nil, showImmediately: showImmediately)
    }

    /// Create a new chat window with existing session data
    /// - Parameters:
    ///   - agentId: The agent for this window (defaults to active agent)
    ///   - sessionData: Optional existing session to load
    ///   - showImmediately: Whether to show the window immediately (default: true)
    /// - Returns: The window identifier
    @discardableResult
    func createWindow(
        agentId: UUID? = nil,
        sessionData: ChatSessionData?,
        showImmediately: Bool = true
    ) -> UUID {
        return createWindowInternal(agentId: agentId, sessionData: sessionData, showImmediately: showImmediately)
    }

    /// Internal implementation for creating windows
    private func createWindowInternal(
        agentId: UUID?,
        sessionData: ChatSessionData?,
        showImmediately: Bool
    ) -> UUID {
        let windowId = UUID()
        // A brand-new chat opens on the new-chat agent (the Orchestrator
        // unless `new_chat_agent` says otherwise), not on whichever agent the
        // last window happened to be browsing (upstream #2936).
        let effectiveAgentId = agentId ?? AgentManager.shared.newChatAgentId

        let info = ChatWindowInfo(
            id: windowId,
            agentId: effectiveAgentId,
            sessionId: sessionData?.id,
            createdAt: Date()
        )

        windows[windowId] = info

        // Create the actual NSWindow
        let window = createNSWindow(
            windowId: windowId,
            agentId: effectiveAgentId,
            sessionData: sessionData
        )

        nsWindows[windowId] = window

        // Show the window if requested
        if showImmediately {
            showWindow(id: windowId)
        }

        print(
            "[ChatWindowManager] Created window \(windowId) for agent \(effectiveAgentId) (shown: \(showImmediately))"
        )

        return windowId
    }

    /// Stop all active sessions (chat and work) across all windows.
    /// Called during app termination to prevent crashes from in-flight inference.
    public func stopAllSessions() {
        for (_, state) in windowStates {
            state.cleanup()
        }
    }

    /// Close a chat window by ID
    public func closeWindow(id: UUID) {
        guard let window = nsWindows[id] else {
            print("[ChatWindowManager] No window found for ID \(id)")
            return
        }

        // Check if we should allow the close (may show background task dialog)
        guard shouldAllowClose(id: id) else {
            return
        }

        // Close will trigger the delegate which handles cleanup
        window.close()
    }

    /// Gate the close: if the session is mid-stream and not already
    /// detached to a background task, surface the in-chat confirmation
    /// overlay and tell AppKit to keep the window open. The user's pick
    /// (Continue in Background / Stop and Close) re-enters via
    /// `closeWindow(id:)`, which now passes this gate.
    private func shouldAllowClose(id: UUID) -> Bool {
        guard let state = windowStates[id] else { return true }
        if BackgroundTaskManager.shared.isWindowDetachedToBackground(windowId: id) {
            return true
        }
        guard state.session.isStreaming else { return true }
        state.showCloseConfirmation = true
        return false
    }

    /// Show/focus a window by ID
    public func showWindow(id: UUID) {
        guard let window = nsWindows[id] else {
            print("[ChatWindowManager] No window found for ID \(id)")
            return
        }

        // Unhide app if hidden
        NSApp.unhide(nil)

        // Deminiaturize if needed
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }

        // Activate app and bring this specific window forward
        _ = NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)
        NSApp.activate(ignoringOtherApps: true)

        window.orderFrontRegardless()
        window.makeKeyAndOrderFront(nil)

        // Update last focused
        lastFocusedWindowId = id
    }

    /// Hide a window by ID
    public func hideWindow(id: UUID) {
        guard let window = nsWindows[id] else { return }
        // Drop any cached AI-generated empty-state content so re-opening
        // the window pops a fresh entry from `GenerativeGreetingPool`
        // instead of flashing the previous session's greeting before
        // the trigger replaces it. Idempotent — clearing an already
        // `.idle` session is a no-op.
        if let state = windowStates[id] {
            state.session.resetGenerativeGreeting()
        }
        // Tell the pool the user no longer has THIS window's agent on
        // screen so the 5-min ticker stops topping up its cache. The
        // pool scopes the clear to the matching agent so a second
        // visible window for a different agent keeps its active
        // pointer; same-agent multi-window is rare enough that any
        // residual over-clearing is recovered on the next empty-state
        // appearance via `setActive`.
        if let info = windows[id] {
            let agentId = info.agentId
            Task { await GenerativeGreetingPool.shared.clearActive(agentId: agentId) }
        }
        window.orderOut(nil)
        print("[ChatWindowManager] Hid window \(id)")
    }

    /// Toggle the last focused window (or create new if none exist)
    public func toggleLastFocused() {
        if let lastId = lastFocusedWindowId, let window = nsWindows[lastId] {
            // smart toggle: only hide if the window is already visible, frontmost, and the app is active
            // otherwise, toggling should just bring it to the front
            let isFrontmost = window.isVisible && window.isKeyWindow && NSApp.isActive

            if isFrontmost {
                hideWindow(id: lastId)
            } else {
                showWindow(id: lastId)
            }
        } else if let firstId = windows.keys.first {
            // No last focused, show first available
            showWindow(id: firstId)
        } else {
            // No windows exist, create new one
            createWindow()
        }
    }

    /// Find windows by agent ID
    public func findWindows(byAgentId agentId: UUID) -> [ChatWindowInfo] {
        windows.values.filter { $0.agentId == agentId }
    }

    /// Find a window by session ID
    public func findWindow(bySessionId sessionId: UUID) -> ChatWindowInfo? {
        windows.values.first { $0.sessionId == sessionId }
    }

    /// Check if any windows are visible
    public var hasVisibleWindows: Bool {
        nsWindows.values.contains { $0.isVisible }
    }

    /// True when any open chat session is currently streaming a model
    /// response. Read by `GenerativeGreetingPool` to defer background
    /// refills while an interactive turn is in flight — both calls
    /// share the same MLX context and unboxing them concurrently
    /// degrades token-per-second on the user's active conversation.
    public var isAnySessionStreaming: Bool {
        windowStates.values.contains { $0.session.isStreaming }
    }

    /// Get the count of active windows
    public var windowCount: Int {
        windows.count
    }

    /// Check if a specific window exists
    public func windowExists(id: UUID) -> Bool {
        windows[id] != nil
    }

    /// Get the NSWindow for a specific window ID (for event matching)
    public func getNSWindow(id: UUID) -> NSWindow? {
        nsWindows[id]
    }

    /// Get window info by ID
    public func windowInfo(id: UUID) -> ChatWindowInfo? {
        windows[id]
    }

    /// Get the window state for a specific window (for accessing session/agent)
    func windowState(id: UUID) -> ChatWindowState? {
        windowStates[id]
    }

    /// Returns the set of local model names selected by currently-open chat
    /// windows. Used as a "keep loaded for next interaction" hint for GC.
    ///
    /// Safety against unloading a model mid-stream is enforced by `ModelLease`
    /// inside `ModelRuntime.unloadModelsNotIn` — this set only needs to cover
    /// the UX heuristic of "the user still has a window open with this model
    /// selected, don't pay reload cost on their next keystroke".
    func activeLocalModelNames() -> Set<String> {
        Set(
            windowStates.values.compactMap { state in
                guard let model = state.session.selectedModel,
                    let found = ModelManager.findInstalledModel(named: model)
                else { return nil }
                return found.name
            }
        )
    }

    /// Set a callback to be invoked when window is about to close (for session saving)
    public func setCloseCallback(for windowId: UUID, callback: @escaping () -> Void) {
        sessionCallbacks[windowId] = callback
    }

    /// Set window pinned (float on top) state
    public func setWindowPinned(id: UUID, pinned: Bool) {
        guard let window = nsWindows[id] else { return }
        window.level = pinned ? .floating : .normal
        print("[ChatWindowManager] Window \(id) pinned: \(pinned)")
    }

    /// Focus all existing windows (for dock icon click)
    public func focusAllWindows() {
        guard !windows.isEmpty else { return }

        NSApp.unhide(nil)
        _ = NSRunningApplication.current.activate(options: .activateIgnoringOtherApps)

        // Bring all windows to front without churn on key window state
        for (_, window) in nsWindows {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.orderFrontRegardless()
        }

        // Make the intended window key once
        if let lastId = lastFocusedWindowId, let window = nsWindows[lastId] {
            window.makeKeyAndOrderFront(nil)
        } else if let firstWindow = nsWindows.values.first {
            firstWindow.makeKeyAndOrderFront(nil)
        }

        print("[ChatWindowManager] Focused all \(windows.count) windows")
    }

    // MARK: - Background Task Window Support

    /// Lazily create a window from an `ExecutionContext`, reusing its sessions.
    /// Called when the user taps "View" on a dispatch toast.
    @discardableResult
    public func createWindowForContext(
        _ context: ExecutionContext,
        showImmediately: Bool = true
    ) -> UUID {
        let windowId = UUID()
        let windowState = ChatWindowState(windowId: windowId, executionContext: context)

        windows[windowId] = ChatWindowInfo(
            id: windowId,
            agentId: context.agentId,
            createdAt: Date()
        )

        let window = createNSWindowForBackgroundTask(windowId: windowId, windowState: windowState)
        nsWindows[windowId] = window
        windowStates[windowId] = windowState

        if showImmediately { showWindow(id: windowId) }

        print("[ChatWindowManager] Created window \(windowId) for context \(context.id)")
        return windowId
    }

    /// Create an NSWindow for viewing a background task (reuses existing window state)
    private func createNSWindowForBackgroundTask(
        windowId: UUID,
        windowState: ChatWindowState
    ) -> NSWindow {
        // Create ChatView with the existing window state
        let chatView = ChatView(windowState: windowState)
            .environment(\.theme, windowState.theme)

        let hostingController = NSHostingController(rootView: chatView)

        let panel = createChatPanel(windowId: windowId, windowState: windowState)
        panel.contentViewController = hostingController

        applyWindowFramePersistence(panel: panel)

        return panel
    }

    // MARK: - Private Helpers

    private func createNSWindow(
        windowId: UUID,
        agentId: UUID,
        sessionData: ChatSessionData?
    ) -> NSWindow {
        // Create per-window state container (isolates from shared singletons)
        let windowState = ChatWindowState(
            windowId: windowId,
            agentId: agentId,
            sessionData: sessionData
        )
        windowStates[windowId] = windowState

        // Create ChatView with window state
        let chatView = ChatView(windowState: windowState)
            .environment(\.theme, windowState.theme)

        let hostingController = NSHostingController(rootView: chatView)

        let panel = createChatPanel(windowId: windowId, windowState: windowState)
        panel.contentViewController = hostingController

        applyWindowFramePersistence(panel: panel)

        return panel
    }

    /// Shared logic for creating the basic ChatPanel with its toolbar and delegate.
    private func createChatPanel(windowId: UUID, windowState: ChatWindowState) -> ChatPanel {
        // Calculate centered position on active screen, with offset for multiple windows
        let defaultSize = NSSize(width: 800, height: 610)
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main

        // Cascade offset based on number of existing windows (25pt per window)
        // Use count - 1 so the first window starts at the base position
        let cascadeOffset = CGFloat(max(0, windows.count - 1)) * 25.0

        let initialRect: NSRect
        if let s = screen {
            let vf = s.visibleFrame
            let baseOrigin = NSPoint(
                x: vf.midX - defaultSize.width / 2,
                y: vf.midY - defaultSize.height / 2
            )
            var origin = NSPoint(
                x: baseOrigin.x + cascadeOffset,
                y: baseOrigin.y - cascadeOffset
            )
            if origin.x + defaultSize.width > vf.maxX {
                origin.x = vf.minX + 50
            }
            if origin.y < vf.minY {
                origin.y = vf.maxY - defaultSize.height - 50
            }
            initialRect = NSRect(origin: origin, size: defaultSize)
        } else {
            initialRect = NSRect(origin: .zero, size: defaultSize)
        }

        let panel = ChatPanel(
            contentRect: initialRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isOpaque = true
        panel.backgroundColor = .windowBackgroundColor
        panel.hasShadow = true
        panel.animationBehavior = .none
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.worksWhenModal = true
        panel.isReleasedWhenClosed = false
        // No AppKit snapshot restoration. Frame autosave (below, via
        // `applyWindowFramePersistence`) handles position persistence.
        panel.isRestorable = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .managed]

        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = false
        panel.acceptsMouseMovedEvents = true
        panel.appearance = NSAppearance(named: windowState.theme.isDark ? .darkAqua : .aqua)

        let toolbar = NSToolbar(identifier: "ChatToolbar")
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        // Anchor the agent pill at the toolbar's geometric center; without
        // this it drifts off-axis because of the asymmetric leading/trailing
        // items and the traffic-light area.
        toolbar.centeredItemIdentifier = ChatToolbarDelegate.agentItem

        let toolbarDelegate = ChatToolbarDelegate(windowState: windowState, session: windowState.session)
        toolbar.delegate = toolbarDelegate
        panel.chatToolbarDelegate = toolbarDelegate
        panel.toolbar = toolbar
        panel.toolbarStyle = .unified
        IntelNativeWindowRendering.restoreTitlebarControls(in: panel)
        DispatchQueue.main.async { [weak panel] in
            guard let panel else { return }
            IntelNativeWindowRendering.restoreTitlebarControls(in: panel)
        }

        // Set up delegate for lifecycle events
        let delegate = ChatWindowDelegate(windowId: windowId, manager: self)
        windowDelegates[windowId] = delegate
        panel.delegate = delegate

        return panel
    }

    /// Common method for window frame persistence and cascading.
    private func applyWindowFramePersistence(panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let cascadeOffset = CGFloat(max(0, windows.count - 1)) * 25.0

        // Try to load saved frame for ALL windows to get the user's preferred size
        _ = panel.setFrameUsingName(WindowFrameAutosaveKey.chat.rawValue)

        if windows.count > 1 {
            // Recalculate origin for subsequent windows in case the size changed from default
            let currentSize = panel.frame.size
            if let s = screen {
                let vf = s.visibleFrame
                let baseOrigin = NSPoint(
                    x: vf.midX - currentSize.width / 2,
                    y: vf.midY - currentSize.height / 2
                )
                var origin = NSPoint(
                    x: baseOrigin.x + cascadeOffset,
                    y: baseOrigin.y - cascadeOffset
                )
                if origin.x + currentSize.width > vf.maxX {
                    origin.x = vf.minX + 50
                }
                if origin.y < vf.minY {
                    origin.y = vf.maxY - currentSize.height - 50
                }
                panel.setFrameOrigin(origin)
            }
        }

        // Only the first window will save its changes back to the slot
        if windows.count == 1 {
            panel.setFrameAutosaveName(WindowFrameAutosaveKey.chat.rawValue)
        }
    }

    // Called by delegate when window becomes key
    fileprivate func windowDidBecomeKey(id: UUID) {
        lastFocusedWindowId = id
        print("[ChatWindowManager] Window \(id) became key")
    }

    // Called by delegate to determine if window should close (for Cmd+W, etc.)
    fileprivate func windowShouldClose(id: UUID) -> Bool {
        return shouldAllowClose(id: id)
    }

    // Called by delegate when window will close
    fileprivate func windowWillClose(id: UUID) {
        print("[ChatWindowManager] Window \(id) will close")

        let isDetachedToBackground = BackgroundTaskManager.shared.isWindowDetachedToBackground(windowId: id)

        // Only invoke save callback and cleanup if NOT detached to background
        // (background task needs the session to keep running)
        if !isDetachedToBackground {
            if let callback = sessionCallbacks[id] {
                callback()
            }
            windowStates[id]?.cleanup()
        }

        // Clean up all local references. BackgroundTaskState independently retains
        // the ChatWindowState it needs, so removing it here is always safe.
        sessionCallbacks.removeValue(forKey: id)
        windowDelegates.removeValue(forKey: id)
        windowStates.removeValue(forKey: id)

        let closedSessionId = windows[id]?.sessionId
        let closedAgentId = windows[id]?.agentId
        Task {
            if let sid = closedSessionId {
                PluginHostContext.invalidateSessionToolCache(sessionId: sid.uuidString)
            }
            if let aid = closedAgentId {
                // Drop any 10-second-TTL memory context snapshot so a freshly
                // opened window for the same agent rebuilds from current state.
                // Without this, a user who edits memory in window B and closes
                // window A could briefly see the stale A-era assembly on the
                // next compose pass.
                await MemoryContextAssembler.shared.invalidateCache(agentId: aid.uuidString)
            }
            let idlePolicy =
                ServerConfigurationStore.load()?.modelIdleResidencyPolicy
                ?? ServerConfiguration.default.modelIdleResidencyPolicy
            if idlePolicy == .immediately {
                let active = self.activeLocalModelNames()
                await ModelRuntime.shared.unloadModelsNotIn(active)
            }
        }

        // Sever NSWindow -> NSHostingController link so the SwiftUI view tree
        // and its @State storage are released even if the panel lingers briefly.
        nsWindows[id]?.contentViewController = nil
        nsWindows.removeValue(forKey: id)
        windows.removeValue(forKey: id)

        // Update last focused if this was the focused window
        if lastFocusedWindowId == id {
            lastFocusedWindowId = windows.keys.first
        }

        // Post notification for VAD resume
        NotificationCenter.default.post(name: .chatViewClosed, object: id)

        let msg = isDetachedToBackground ? " (detached to background)" : ""
        print("[ChatWindowManager] Window \(id) cleanup complete\(msg), remaining: \(windows.count)")
    }
}

// MARK: - Chat Panel

/// Custom panel that keeps native traffic lights and hosts a unified toolbar.
private final class ChatPanel: NSPanel {
    /// Keep toolbar delegate alive (NSToolbar's delegate is weak).
    var chatToolbarDelegate: ChatToolbarDelegate?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

// MARK: - Chat Toolbar

/// Toolbar delegate that places each control in its own `NSToolbarItem`
/// so macOS applies native per-item styling (pill backgrounds, spacing).
@MainActor
private final class ChatToolbarDelegate: NSObject, NSToolbarDelegate {
    fileprivate static let sidebarItem = NSToolbarItem.Identifier("ChatToolbar.sidebar")
    fileprivate static let agentItem = NSToolbarItem.Identifier("ChatToolbar.agent")
    fileprivate static let actionItem = NSToolbarItem.Identifier("ChatToolbar.action")
    fileprivate static let pinItem = NSToolbarItem.Identifier("ChatToolbar.pin")

    /// Layout: sidebar on the leading edge, agent pill centered (via the
    /// toolbar's `centeredItemIdentifier`), action + pin on the trailing edge.
    /// The flexible spaces let the trailing items hug the right edge.
    /// Any stale identifiers AppKit may have persisted in user defaults
    /// fall through to `default: nil` in `itemForItemIdentifier`, which
    /// renders them as no-ops rather than crashing.
    private static let itemIdentifiers: [NSToolbarItem.Identifier] = [
        sidebarItem, .flexibleSpace, agentItem, .flexibleSpace, actionItem, pinItem,
    ]

    private weak var windowState: ChatWindowState?
    private weak var session: ChatSession?

    init(windowState: ChatWindowState, session: ChatSession) {
        self.windowState = windowState
        self.session = session
        super.init()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.itemIdentifiers
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.itemIdentifiers
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let windowState, let session else { return nil }

        switch itemIdentifier {
        case Self.sidebarItem:
            return makeHostingItem(
                identifier: itemIdentifier,
                rootView:
                    ChatToolbarSidebarView(windowState: windowState)
            )

        case Self.agentItem:
            return makeHostingItem(
                identifier: itemIdentifier,
                rootView:
                    ChatToolbarAgentView(windowState: windowState, session: session)
            )

        case Self.actionItem:
            return makeHostingItem(
                identifier: itemIdentifier,
                rootView:
                    ChatToolbarActionView(windowState: windowState, session: session)
            )

        case Self.pinItem:
            return makeHostingItem(
                identifier: itemIdentifier,
                rootView:
                    ChatToolbarPinView(windowState: windowState)
            )

        default:
            return nil
        }
    }

    private func makeHostingItem<Content: View>(
        identifier: NSToolbarItem.Identifier,
        rootView: Content
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(origin: .zero, size: hostingView.fittingSize)
        item.view = hostingView
        if #available(macOS 13.0, *) {
            item.isBordered = false
        }
        return item
    }
}

// MARK: - Toolbar Item Views

/// Sidebar toggle button.
private struct ChatToolbarSidebarView: View {
    @ObservedObject var windowState: ChatWindowState

    var body: some View {
        HeaderActionButton(
            icon: "sidebar.left",
            help: windowState.showSidebar ? "Hide sidebar" : "Show sidebar",
            action: {
                withAnimation(windowState.theme.animationQuick()) {
                    windowState.showSidebar.toggle()
                }
            }
        )
        .environment(\.theme, windowState.theme)
    }
}

/// Agent selector pill that lives in the toolbar's centered slot.
private struct ChatToolbarAgentView: View {
    @ObservedObject var windowState: ChatWindowState
    @ObservedObject var session: ChatSession

    /// Incremented by the `/agent` slash command notification to pop the
    /// agent picker open from the input card.
    @State private var openPickerTrigger: Int = 0

    var body: some View {
        AgentPill(
            agents: windowState.agents,
            activeAgentId: windowState.agentId,
            onSelectAgent: { newAgentId in
                windowState.switchAgent(to: newAgentId)
            },
            discoveredAgents: windowState.discoveredAgents,
            onSelectDiscoveredAgent: { agent in
                NotificationCenter.default.post(
                    name: .chatToolbarSelectDiscoveredAgent,
                    object: agent,
                    userInfo: ["windowId": windowState.windowId]
                )
            },
            activeDiscoveredAgent: windowState.selectedDiscoveredAgent,
            pairedRelayAgents: windowState.pairedRelayAgents,
            onSelectRelayAgent: { relay in
                NotificationCenter.default.post(
                    name: .chatToolbarSelectRelayAgent,
                    object: relay,
                    userInfo: ["windowId": windowState.windowId]
                )
            },
            activeRelayAgent: windowState.selectedRelayAgent,
            onOpenActiveAgentSettings: {
                let active = windowState.agents.first { $0.id == windowState.agentId }
                let deeplinkId = (active?.isBuiltIn == false) ? active?.id : nil
                AppDelegate.shared?.showManagementWindow(
                    initialTab: .agents,
                    deeplinkAgentId: deeplinkId
                )
            },
            openPickerTrigger: openPickerTrigger
        )
        .environment(\.theme, windowState.theme)
        .onReceive(NotificationCenter.default.publisher(for: .chatToolbarOpenAgentPicker)) { notification in
            guard let targetWindowId = notification.userInfo?["windowId"] as? UUID,
                targetWindowId == windowState.windowId
            else { return }
            openPickerTrigger &+= 1
        }
    }
}

extension Notification.Name {
    static let chatToolbarSelectDiscoveredAgent = Notification.Name("chatToolbarSelectDiscoveredAgent")
    static let chatToolbarSelectRelayAgent = Notification.Name("chatToolbarSelectRelayAgent")
    /// Posted by the `/agent` slash command to pop open the toolbar's agent
    /// picker for the window identified in `userInfo["windowId"]`.
    static let chatToolbarOpenAgentPicker = Notification.Name("chatToolbarOpenAgentPicker")
}

/// Contextual action button: settings (empty state) or new-chat plus.
private struct ChatToolbarActionView: View {
    @ObservedObject var windowState: ChatWindowState
    @ObservedObject var session: ChatSession

    var body: some View {
        Group {
            if session.turns.isEmpty {
                SettingsButton(action: {
                    AppDelegate.shared?.showManagementWindow(initialTab: nil)
                })
            } else {
                HeaderActionButton(
                    icon: "plus",
                    help: "New chat",
                    action: { windowState.startNewChat() }
                )
            }
        }
        .environment(\.theme, windowState.theme)
    }
}

/// Pin button. Observes windowState for reactive theme updates.
private struct ChatToolbarPinView: View {
    @ObservedObject var windowState: ChatWindowState

    var body: some View {
        PinButton(windowId: windowState.windowId)
            .environment(\.theme, windowState.theme)
    }
}

// MARK: - Window Delegate

@MainActor
private final class ChatWindowDelegate: NSObject, NSWindowDelegate {
    let windowId: UUID
    weak var manager: ChatWindowManager?

    init(windowId: UUID, manager: ChatWindowManager) {
        self.windowId = windowId
        self.manager = manager
        super.init()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        manager?.windowDidBecomeKey(id: windowId)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return manager?.windowShouldClose(id: windowId) ?? true
    }

    func windowWillClose(_ notification: Notification) {
        manager?.windowWillClose(id: windowId)
    }
}
#else

// MARK: - Intel fork: minimal ChatWindowManager stub

import AppKit
import Combine
import SwiftUI

public struct ChatWindowInfo: Identifiable, Sendable {
    public let id: UUID
    public let agentId: UUID
    public let sessionId: UUID?
    public let createdAt: Date

    public init(id: UUID = UUID(), agentId: UUID, sessionId: UUID? = nil, createdAt: Date = Date()) {
        self.id = id
        self.agentId = agentId
        self.sessionId = sessionId
        self.createdAt = createdAt
    }
}

/// Behavior of the ⌘N shortcut in the File menu. Off (default) keeps ⌘N on
/// "New Window". On, ⌘N starts a new chat in the frontmost chat window (the
/// sidebar "New Chat" action) and "New Window" moves to ⇧⌘N. Toggled in
/// Chat settings, read by the app's File menu commands. Upstream e0eeba12.
public enum NewChatShortcutSetting {
    public static let defaultsKey = "chatCmdNStartsNewChatInCurrentWindow"
}

/// Settings ▸ Chat ▸ "Check Spelling While Typing": run the macOS spell
/// checker (red underline + right-click suggestions) in the chat composer.
/// Default off, matching the raw-input feel the composer has always had;
/// autocorrect and smart substitutions stay off regardless. Upstream
/// 4680ce594.
public enum ComposerSpellCheckSetting {
    public static let defaultsKey = "chatComposerSpellCheckEnabled"
    public static let defaultValue = false

    /// Current value for callers outside SwiftUI.
    public static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: defaultsKey) == nil
            ? defaultValue
            : UserDefaults.standard.bool(forKey: defaultsKey)
    }
}

@MainActor
public final class ChatWindowManager: NSObject, ObservableObject, NSWindowDelegate {
    public static let shared = ChatWindowManager()

    @Published public private(set) var windows: [UUID: ChatWindowInfo] = [:]
    @Published public private(set) var lastFocusedWindowId: UUID?

    public var windowCount: Int { windows.count }
    public var hasVisibleWindows: Bool { !windows.isEmpty }

    private var nsWindows: [UUID: NSWindow] = [:]
    private var windowStates: [UUID: ChatWindowState] = [:]
    /// M12 Gap 1: retains each window's toolbar delegate (NSToolbar holds
    /// its delegate weakly, so without this the centered agent pill would
    /// vanish the moment `createWindow` returns).
    private var toolbarDelegates: [UUID: IntelChatToolbarDelegate] = [:]

    /// A plain open (no agent asked for) reopens on the chat the user was
    /// last reading; a window opened for a specific agent keeps that
    /// agent's fresh chat in front, with remembered tabs behind it.
    public func createWindow(agentId: UUID? = nil) -> UUID {
        createWindow(agentId: agentId, focusesRememberedChat: agentId == nil)
    }

    func createWindow(agentId: UUID?, focusesRememberedChat: Bool) -> UUID {
        // M12 Gap 1: tie a freshly opened window to a real agent so the
        // toolbar pill shows it. Upstream #2936: that is the new-chat agent
        // (the Orchestrator unless `new_chat_agent` says otherwise), not the
        // agent the last window was browsing.
        let resolvedAgentId = agentId ?? AgentManager.shared.newChatAgentId
        let info = ChatWindowInfo(agentId: resolvedAgentId)
        windows[info.id] = info
        lastFocusedWindowId = info.id

        let state = ChatWindowState(windowId: info.id, agentId: resolvedAgentId)
        windowStates[info.id] = state

        // Upstream #2664: new chat windows open at the visible screen size of
        // the screen under the pointer (cascaded for more windows), so the
        // navigator and inspector never squeeze the chat column.
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let initialRect = Self.initialFrame(on: screen, cascadeIndex: windows.count - 1)
        let window = IntelChatWindow(
            contentRect: initialRect,
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.chatWindowState = state
        window.title = "Osaurus (Intel)"
        // Unified toolbar look that matches the Apple Silicon chat window:
        // transparent titlebar + full-size content so the SwiftUI ChatView
        // flows under the toolbar.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // No hairline under the toolbar in full screen (upstream).
        window.titlebarSeparatorStyle = .none
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.appearance = NSAppearance(named: state.theme.isDark ? .darkAqua : .aqua)

        let toolbar = NSToolbar(identifier: "IntelChatToolbar")
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        let toolbarDelegate = IntelChatToolbarDelegate(windowState: state)
        toolbar.delegate = toolbarDelegate
        toolbarDelegates[info.id] = toolbarDelegate
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        IntelNativeWindowRendering.restoreTitlebarControls(in: window)

        // M13 follow-up (Renée 2026-06-04): host a ThemedAlertHost scoped to
        // this chat window so themed confirmations raised from inside it
        // actually render. The sidebar's delete-conversation dialog presents
        // through `ThemedAlertCenter` keyed on `@Environment(\.themedAlertScope)`;
        // without a matching host in the window's view tree the dialog had
        // nowhere to draw, so "Delete" silently no-op'd. `.chat(info.id)`
        // gives each window its own scope (no cross-window dialog bleed).
        let chatView = IntelChatWindowRootView(windowState: state)
            .themedAlertScope(.chat(info.id))
            .overlay(ThemedAlertHost(scope: .chat(info.id)))
        window.contentView = NSHostingView(rootView: chatView)
        DispatchQueue.main.async { [weak window] in
            guard let window else { return }
            IntelNativeWindowRendering.restoreTitlebarControls(in: window)
        }
        // M12 follow-up (Renée 2026-06-03 crashes): the manager owns each
        // window's lifecycle. `isReleasedWhenClosed = false` is deliberate —
        // with `true`, AppKit auto-released the window on close while our
        // `nsWindows` dict still held it, so (a) a later `showWindow(id:)`
        // (menu-bar "Ask AI") poked freed memory, and (b) once we added the
        // delegate to purge bookkeeping, removing our strong ref on top of
        // AppKit's release double-freed it mid-close. With `false`, our dict is
        // the sole strong ref; `windowWillClose` removes it → ARC frees the
        // window cleanly after the close stack unwinds.
        window.isReleasedWhenClosed = false
        window.delegate = self
        applyWindowFramePersistence(window, screen: screen)
        fitToScreen(window, state: state)
        nsWindows[info.id] = window
        // Remembered tabs of windows that are gone (last launch, or a window
        // closed earlier) come back in this one; then track its own tabs.
        restoreRememberedTabs(into: state, focusesRememberedChat: focusesRememberedChat)
        // Remembered tabs first (so a hibernated stand-in never shadows a
        // live run: `restoreTabs` skips registry-owned ids), then the
        // registry's own runs. Upstream.
        ensureTaskRegistrationObserver()
        attachRegistryRuns(to: state)
        observeTabLayout(of: state)
        // Activate + front (works when summoned via hotkey from another app).
        bringToFront(window)

        return info.id
    }

    /// Open a window for a background/scheduled task's execution context.
    ///
    /// M13 Schedules restore: `BackgroundTaskManager.openTaskWindow` calls this
    /// when the user clicks to view a running scheduled task. Scheduled runs
    /// execute headless (no window), so this only backs the "view task"
    /// affordance — it reuses the battle-tested `createWindow` builder seeded
    /// with the task's agent. (Binding the window to the task's existing
    /// session content is a follow-up; the headless run has already produced
    /// its output.)
    @discardableResult
    public func createWindowForContext(
        _ context: ExecutionContext,
        showImmediately: Bool = true
    ) -> UUID {
        let id = createWindow(agentId: context.agentId)
        if !showImmediately { nsWindows[id]?.orderOut(nil) }
        return id
    }

    /// Overload that opens a window pre-loaded with a stored session.
    /// Used by AgentDetailView's history rows (un-body-swapped in M11
    /// Phase 11.A.4) to reopen a past conversation. Mirrors the upstream
    /// `createWindow(agentId:sessionData:showImmediately:)` signature.
    @discardableResult
    func createWindow(
        agentId: UUID,
        sessionData: ChatSessionData?,
        showImmediately: Bool = true
    ) -> UUID {
        if let sessionId = sessionData?.id,
            let owner = revealOpenSession(sessionId, showImmediately: showImmediately)
        {
            return owner
        }
        let id = createWindow(agentId: agentId, focusesRememberedChat: sessionData == nil)
        if let sessionData, let state = windowStates[id] {
            // A tab of its own (or the restored tab already showing it), so
            // it never replaces a remembered tab.
            state.openSessionInNewTab(sessionData)
        }
        return id
    }

    func windowState(id: UUID) -> ChatWindowState? {
        windowStates[id]
    }

    /// A persisted conversation has one mutable window/tab owner. Hydrating
    /// a second copy lets either copy's saves overwrite the other's later
    /// turns. Upstream `979d53b40`: ownership is any tab of any window, and
    /// revealing it focuses that tab.
    @discardableResult
    func revealOpenSession(
        _ sessionId: UUID,
        excludingWindowId: UUID? = nil,
        showImmediately: Bool = true
    ) -> UUID? {
        guard
            let (id, state) = windowStates.first(where: {
                $0.key != excludingWindowId
                    && $0.value.tabSessions.contains { $0.sessionId == sessionId }
            })
        else { return nil }
        if showImmediately {
            state.focusTab(forSessionId: sessionId)
            showWindow(id: id)
        }
        return id
    }

    /// The live `ChatSession` currently showing the given persisted session
    /// id in any open window, else one still running after its tab closed.
    /// Used by `SessionActivityMonitor.stop` to route a navigator Stop.
    func session(forSessionId sessionId: UUID) -> ChatSession? {
        // Prefer the visible (active-tab) instance, then any inactive tab.
        if let active = windowStates.values.first(where: { $0.session.sessionId == sessionId }) {
            return active.session
        }
        for state in windowStates.values {
            if let match = state.liveTabSessions.first(where: { $0.sessionId == sessionId }) {
                return match
            }
        }
        return DetachedChatRunRegistry.shared.liveSession(forSessionId: sessionId)
    }

    /// The window whose tabs include `sessionId`, if any.
    func findWindow(bySessionId sessionId: UUID) -> UUID? {
        windowStates.first { $0.value.tabSessions.contains { $0.sessionId == sessionId } }?.key
    }

    /// Open a saved chat as a tab: focus the tab that already shows it,
    /// else open it in the last focused window, creating a window only when
    /// none is open. Upstream `openHistorySession`.
    func openSessionAsTab(_ data: ChatSessionData) {
        if revealOpenSession(data.id) != nil { return }
        if let targetId = preferredWindowId(), let state = windowStates[targetId] {
            showWindow(id: targetId)
            state.openSessionInNewTab(data)
            return
        }
        createWindow(agentId: data.agentId, sessionData: data)
    }

    // MARK: Background runs as tabs (upstream #2630)

    private var taskRegisteredCancellable: AnyCancellable?

    /// Armed on first window creation rather than in `init`: the two
    /// singletons reference each other, so subscribing from `init` could
    /// re-enter a singleton still being constructed. Upstream.
    private func ensureTaskRegistrationObserver() {
        guard taskRegisteredCancellable == nil else { return }
        taskRegisteredCancellable = BackgroundTaskManager.shared.taskRegistered
            .sink { [weak self] state in
                self?.surfaceRegisteredTask(state)
            }
    }

    /// A run was just registered: surface it as a tab of its agent in the
    /// frontmost window, without stealing focus. Runs the user detached
    /// (`.chat` source) are skipped. No window is created for a headless
    /// launch.
    private func surfaceRegisteredTask(_ state: BackgroundTaskState) {
        guard state.source != .chat else { return }
        if findWindow(bySessionId: state.id) != nil { return }
        guard let targetId = preferredWindowId(), let target = windowStates[targetId] else { return }
        target.attachBackgroundTab(for: state)
    }

    /// Surface every registry run not shown in another window as tabs of a
    /// freshly created window.
    private func attachRegistryRuns(to state: ChatWindowState) {
        for task in BackgroundTaskManager.shared.tasksForTabs() where task.chatSession != nil {
            if let shownIn = findWindow(bySessionId: task.id), shownIn != state.windowId { continue }
            state.attachBackgroundTab(for: task)
        }
    }

    /// Bring a registry run on screen as a tab of its agent: focus the tab
    /// that already shows it (in whichever window), else attach it to the
    /// frontmost window and select it, else open a window for it.
    /// Upstream `revealTask`.
    public func revealTask(_ taskId: UUID) {
        guard let state = BackgroundTaskManager.shared.taskState(for: taskId) else { return }
        if let shownIn = findWindow(bySessionId: taskId), let host = windowStates[shownIn] {
            host.focusTab(forSessionId: taskId)
            showWindow(id: shownIn)
            return
        }
        if let targetId = preferredWindowId(), let target = windowStates[targetId] {
            target.attachBackgroundTab(for: state)
            target.focusTab(forSessionId: taskId)
            showWindow(id: targetId)
            return
        }
        // No window: one opens and attaches every registry run itself.
        let windowId = createWindow(agentId: state.agentId)
        windowStates[windowId]?.focusTab(forSessionId: taskId)
    }

    /// The window new tabs go to: the last focused one, else any.
    private func preferredWindowId() -> UUID? {
        if let lastId = lastFocusedWindowId, windowStates[lastId] != nil { return lastId }
        return windowStates.keys.first
    }

    // MARK: Remembered tabs (upstream c240123ed)

    /// Coalesces the per-window change signals into one write per run-loop
    /// turn: `tabs` / `activeTabId` mutate several times inside a single
    /// tab operation.
    private var tabLayoutPersistScheduled = false

    private func observeTabLayout(of state: ChatWindowState) {
        state.onTabLayoutChanged = { [weak self] in
            self?.scheduleTabLayoutPersist()
        }
    }

    private func scheduleTabLayoutPersist() {
        guard !tabLayoutPersistScheduled else { return }
        tabLayoutPersistScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.tabLayoutPersistScheduled = false
            self.persistTabLayoutNow()
        }
    }

    /// Write every open window's tabs to `ChatTabLayoutStore`. Records of
    /// windows that are no longer open are left as they are: they are what
    /// the next window restores.
    /// Upstream #3003: collect the snapshots here (main-actor state), then do
    /// the `UserDefaults` read and write on a background queue so a busy
    /// cfprefsd can't hang the main thread. Intel: the quit path passes
    /// `synchronously: true` so the record is written before the process
    /// exits (a background write could be lost at termination).
    func persistTabLayoutNow(store: ChatTabLayoutStore = .shared, synchronously: Bool = false) {
        let snapshots: [UUID: ChatTabLayoutRecord] = windowStates.reduce(into: [:]) { result, pair in
            result[pair.key] = pair.value.tabLayoutSnapshot()
        }
        let write = {
            var layout = store.load()
            for (id, record) in snapshots {
                layout.windows[id] = record
            }
            store.save(layout)
        }
        if synchronously {
            write()
        } else {
            DispatchQueue.global(qos: .utility).async(execute: write)
        }
    }

    /// Adopt the tabs of every window that is not open any more (the
    /// previous launch's windows, or one closed earlier in this run) into a
    /// freshly created window, then forget those records so nothing is
    /// restored twice. A chat remembered by the pre-tabs Intel build
    /// (`IntelLastChatStore`) comes back the same way, once.
    func restoreRememberedTabs(
        into state: ChatWindowState,
        focusesRememberedChat: Bool = true,
        store: ChatTabLayoutStore = .shared,
        legacyStore: IntelLastChatStore = .shared
    ) {
        let orphans = store.orphanRecords(openWindowIds: Set(windowStates.keys))
        var records = orphans.map(\.record)
        if let legacy = Self.legacyLastChatRecord(from: legacyStore) {
            records.insert(legacy, at: 0)
        }
        guard !records.isEmpty else { return }
        // Oldest record first; the first record whose active chat comes
        // back is the one the merged window opens on.
        var restored = 0
        for record in records {
            restored += state.restoreTabs(from: record, selectsActive: focusesRememberedChat)
        }
        store.remove(windowIds: orphans.map(\.id))
        if restored > 0 {
            print("[ChatWindowManager] Restored \(restored) remembered tab(s) into window \(state.windowId)")
        }
    }

    /// The chat the pre-tabs build remembered, as a one-tab record. Taken
    /// once: the key is removed whether or not the chat still exists.
    static func legacyLastChatRecord(from store: IntelLastChatStore) -> ChatTabLayoutRecord? {
        guard let id = store.take() else { return nil }
        return ChatTabLayoutRecord(
            tabs: [.init(sessionId: id, lastActivatedAt: Date())],
            activeSessionId: id,
            savedAt: .distantPast
        )
    }

    /// Kept for callers that summon chat with no window open: a new window
    /// restores remembered tabs on its own.
    @discardableResult
    func createWindowRestoringLastChat() -> UUID {
        createWindow()
    }

    #if DEBUG
        /// Exercise ownership routing without constructing an NSWindow.
        func withRegisteredWindowStateForTesting<T>(
            _ state: ChatWindowState, _ body: () throws -> T
        ) rethrows -> T {
            let previous = windowStates[state.windowId]
            windowStates[state.windowId] = state
            defer { windowStates[state.windowId] = previous }
            return try body()
        }
    #endif

    public func focusAllWindows() {
        for (_, window) in nsWindows {
            window.makeKeyAndOrderFront(nil)
        }
    }

    func setCloseCallback(for windowId: UUID, callback: @escaping () -> Void) {}

    public func toggleLastFocused() {
        // Toggle closed only if our chat is genuinely the frontmost window
        // right now (app active + window key). Otherwise summon it.
        if NSApp.isActive,
            let id = lastFocusedWindowId,
            let window = nsWindows[id],
            window.isKeyWindow
        {
            NSLog("[ChatWindowManager] toggleLastFocused → hide (frontmost)")
            window.orderOut(nil)
            return
        }
        if let id = lastFocusedWindowId, let window = nsWindows[id] {
            NSLog("[ChatWindowManager] toggleLastFocused → summon lastFocused")
            bringToFront(window)
        } else if let window = nsWindows.values.first {
            NSLog("[ChatWindowManager] toggleLastFocused → summon first window (count=\(nsWindows.count))")
            bringToFront(window)
        } else {
            NSLog("[ChatWindowManager] toggleLastFocused → no windows, creating one")
            _ = createWindowRestoringLastChat()
        }
    }

    public func showWindow(id: UUID) {
        guard let window = nsWindows[id] else {
            NSLog("[ChatWindowManager] showWindow: no window for id \(id)")
            return
        }
        bringToFront(window)
    }

    /// Start a new chat in the frontmost chat window, mirroring the sidebar
    /// "New Chat" button. Targets the last-focused window as long as it still
    /// exists, even when hidden, and brings it to the front first. Returns
    /// false when no chat window exists so the caller can fall back to
    /// creating a new window. Upstream e0eeba12.
    @discardableResult
    public func startNewChatInLastFocusedWindow() -> Bool {
        let targetId: UUID? =
            if let lastId = lastFocusedWindowId, windowStates[lastId] != nil {
                lastId
            } else {
                windowStates.keys.first
            }
        guard let targetId, let state = windowStates[targetId] else { return false }
        showWindow(id: targetId)
        state.startNewChatInCurrentProject()
        return true
    }

    /// Start a new chat on `agentId` in the frontmost chat window: a blank
    /// active tab is repurposed, otherwise a new tab opens for the agent.
    /// Returns false when no chat window exists. Upstream #2781.
    @discardableResult
    public func startNewChatInLastFocusedWindow(agentId: UUID) -> Bool {
        guard let targetId = preferredWindowId(), let state = windowStates[targetId] else { return false }
        showWindow(id: targetId)
        state.startNewChat(with: agentId)
        return true
    }

    private var shortcutTargetState: ChatWindowState? {
        if let keyID = nsWindows.first(where: { $0.value.isKeyWindow })?.key {
            return windowStates[keyID]
        }
        if let lastID = lastFocusedWindowId, let window = nsWindows[lastID], window.isVisible {
            return windowStates[lastID]
        }
        return nil
    }

    /// ⌘B mirrors the toolbar sidebar button for the focused visible window.
    public func toggleSidebarInFocusedWindow() {
        guard let state = shortcutTargetState else { return }
        withAnimation(state.theme.animationQuick()) { state.toggleSidebar() }
    }

    /// ⇧⌘. selects the next local agent, but leaves a project route alone.
    public func cycleAgentInFocusedWindow() {
        guard let state = shortcutTargetState,
              !state.isProjectPageVisible,
              state.selectedDiscoveredAgent == nil,
              state.selectedRelayAgent == nil,
              state.agents.count > 1,
              let index = state.agents.firstIndex(where: { $0.id == state.agentId })
        else { return }
        state.switchAgent(to: state.agents[(index + 1) % state.agents.count].id)
    }

    /// Bring a window (and the app) reliably to the front from anywhere —
    /// including from another app or over a full-screen Space. Activating the
    /// app is what makes a global-hotkey summon work from the background;
    /// `.moveToActiveSpace` makes the window follow to the current Space instead
    /// of appearing on its original (possibly hidden) one.
    /// Default chat window size: the screen's visible frame (upstream #2664).
    static func defaultWindowSize(fitting screen: NSScreen?) -> NSSize {
        guard let visible = screen?.visibleFrame else { return NSSize(width: 1200, height: 800) }
        return visible.size
    }

    /// Centered on `screen`, offset 25pt per extra window, kept on screen.
    static func initialFrame(on screen: NSScreen?, cascadeIndex: Int) -> NSRect {
        let size = defaultWindowSize(fitting: screen)
        guard let visible = screen?.visibleFrame else { return NSRect(origin: .zero, size: size) }
        let offset = CGFloat(max(0, cascadeIndex)) * 25
        var origin = NSPoint(x: visible.midX - size.width / 2 + offset, y: visible.midY - size.height / 2 - offset)
        if origin.x + size.width > visible.maxX { origin.x = visible.minX + 50 }
        if origin.y < visible.minY { origin.y = visible.maxY - size.height - 50 }
        return NSRect(origin: origin, size: size)
    }

    /// Upstream's `WindowFrameAutosaveKey.chat` (that enum lives in the
    /// excluded `WindowManager.swift`).
    static let frameAutosaveName = "ChatWindow"

    /// Frame autosave (upstream): every window opens at the size the first
    /// window last had; only the first window writes the slot back.
    private func applyWindowFramePersistence(_ window: NSWindow, screen: NSScreen?) {
        _ = window.setFrameUsingName(Self.frameAutosaveName)
        if windows.count > 1 {
            let recentered = Self.initialFrame(on: screen, cascadeIndex: windows.count - 1)
            let size = window.frame.size
            window.setFrameOrigin(
                NSPoint(
                    x: recentered.midX - size.width / 2,
                    y: recentered.midY - size.height / 2))
        } else {
            window.setFrameAutosaveName(Self.frameAutosaveName)
        }
    }

    /// Height the unified titlebar + toolbar strip adds above the root view.
    static let chatChromeHeight: CGFloat = 66

    /// Largest root-view area the chat window can show on `screen`.
    static func chatAvailableContentSize(on screen: NSScreen?) -> CGSize {
        guard let visible = screen?.visibleFrame else { return .zero }
        return CGSize(width: visible.width, height: visible.height - chatChromeHeight)
    }

    /// Clamp the chat floor to the window's screen and shrink an oversized
    /// frame to fit (upstream 3a17bc04d).
    private func fitToScreen(_ window: NSWindow, state: ChatWindowState) {
        let screen = window.screen ?? NSScreen.main
        state.updateMinimumContentSize(availableContentSize: Self.chatAvailableContentSize(on: screen))
        guard let visible = screen?.visibleFrame else { return }
        var frame = window.frame
        frame.size.width = min(frame.size.width, visible.width)
        frame.size.height = min(frame.size.height, visible.height)
        if frame.size != window.frame.size { window.setFrame(frame, display: false) }
    }

    public func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            let id = windowId(for: window),
            let state = windowStates[id]
        else { return }
        fitToScreen(window, state: state)
    }

    private func bringToFront(_ window: NSWindow) {
        SparkleChatGate.markChatVisible()
        NSApp.activate(ignoringOtherApps: true)
        window.collectionBehavior.insert(.moveToActiveSpace)
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
    }

    public func closeWindow(id: UUID) {
        // Snapshot the tabs while they are all still here: cleanup drops
        // them, and this record is what the next window brings back.
        persistTabLayoutNow()
        windows.removeValue(forKey: id)
        nsWindows[id]?.close()
        nsWindows.removeValue(forKey: id)
        windowStates[id]?.cleanup()
        windowStates.removeValue(forKey: id)
        toolbarDelegates.removeValue(forKey: id)
        stashedToolbars.removeValue(forKey: id)
        if lastFocusedWindowId == id {
            lastFocusedWindowId = windows.keys.first
        }
        // VAD Mode resumes once the last chat window is gone (IntelVoiceLaunch).
        NotificationCenter.default.post(name: .chatViewClosed, object: id)
    }

    // MARK: - NSWindowDelegate (Intel chat windows)

    func windowId(for window: NSWindow) -> UUID? {
        nsWindows.first(where: { $0.value === window })?.key
    }

    /// Purge a closed window's bookkeeping so nothing later references the
    /// freed NSWindow. Does NOT call `window.close()` (AppKit is already
    /// closing it) or rely on the entry still being present.
    public func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            let id = windowId(for: window)
        else { return }
        persistTabLayoutNow()
        windows.removeValue(forKey: id)
        nsWindows.removeValue(forKey: id)
        windowStates[id]?.cleanup()
        windowStates.removeValue(forKey: id)
        toolbarDelegates.removeValue(forKey: id)
        stashedToolbars.removeValue(forKey: id)
        if lastFocusedWindowId == id {
            lastFocusedWindowId = windows.keys.first
        }
        // VAD Mode resumes once the last chat window is gone (IntelVoiceLaunch).
        NotificationCenter.default.post(name: .chatViewClosed, object: id)
    }

    // MARK: Full screen (upstream)

    /// Toolbars detached while their window is in full screen, by window.
    private var stashedToolbars: [UUID: NSToolbar] = [:]

    /// AppKit draws the full-screen toolbar with an opaque system backdrop
    /// that can't be themed. Detach the NSToolbar in full screen (rather
    /// than hiding it: AppKit manages toolbar visibility across the
    /// transition and can override a manual `isVisible`); the SwiftUI
    /// content shows `ChatFullScreenHeaderView` instead.
    public func windowWillEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = windowId(for: window) else { return }
        stashedToolbars[id] = window.toolbar
        window.toolbar = nil
        windowStates[id]?.isFullScreen = true
    }

    public func windowDidExitFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, let id = windowId(for: window) else { return }
        if let toolbar = stashedToolbars.removeValue(forKey: id) {
            window.toolbar = toolbar
            IntelNativeWindowRendering.restoreTitlebarControls(in: window)
        }
        windowStates[id]?.isFullScreen = false
    }

    /// If AppKit restored a toolbar while entering, drop the stash so a
    /// second one is never attached later.
    public func windowDidEnterFullScreen(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window.toolbar != nil,
            let id = windowId(for: window)
        else { return }
        stashedToolbars.removeValue(forKey: id)
    }

    /// Track the genuinely-focused window so "Ask AI" / dock reopen target the
    /// right one (and never a stale id).
    public func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow,
            let id = windowId(for: window)
        else { return }
        lastFocusedWindowId = id
        // Once-per-user layout tour (upstream #2630 / #2664); it defers
        // itself while first-run dialogs are up.
        ChatLayoutTour.shared.autoStartIfEligible(windowId: id)
        // Upstream pauses VAD Mode whenever the chat is shown, so the chat's
        // microphone never competes with the wake-word listener.
        if VADService.shared.state != .idle {
            Task { await VADService.shared.pause() }
        }
    }

    public func findWindows(byAgentId agentId: UUID) -> [(id: UUID, info: ChatWindowInfo)] {
        windows.filter { $0.value.agentId == agentId }.map { ($0.key, $0.value) }
    }

    public func getNSWindow(id: UUID) -> NSWindow? {
        nsWindows[id]
    }

    public func activeLocalModelNames() -> Set<String> {
        Set()
    }

    public var isAnySessionStreaming: Bool {
        windowStates.values.contains { $0.tabSessions.contains { $0.isStreaming } }
            || DetachedChatRunRegistry.shared.sessions.contains { $0.isStreaming }
    }

    /// Pin Window: float above other apps' windows (upstream).
    public func setWindowPinned(id: UUID, pinned: Bool) {
        nsWindows[id]?.level = pinned ? .floating : .normal
    }

    public func stopAllSessions() {
        // Quit teardown: record every window's tabs BEFORE cleanup drops the
        // inactive ones (cleanup also stops listening for layout changes).
        persistTabLayoutNow(synchronously: true)
        windowStates.values.forEach { $0.cleanup() }
        windows.removeAll()
        nsWindows.removeAll()
        windowStates.removeAll()
        toolbarDelegates.removeAll()
        stashedToolbars.removeAll()
    }
}

// MARK: - Intel Chat Window (tabs)

/// Swaps `ChatView` whenever the window's session changes (tab switch,
/// reattaching a running chat). `ChatView` binds `@ObservedObject` to the
/// session captured at construction, so it must be rebuilt; `.id` keyed on
/// session identity resets its per-conversation `@State` the way a fresh
/// window would. Upstream `ChatWindowRootView`.
private struct IntelChatWindowRootView: View {
    @ObservedObject var windowState: ChatWindowState

    var body: some View {
        VStack(spacing: 0) {
            if windowState.isFullScreen {
                ChatFullScreenHeaderView(windowState: windowState)
            }
            ChatView(windowState: windowState)
                .id(ObjectIdentifier(windowState.session))
        }
        .environment(\.theme, windowState.theme)
    }
}

/// Themed replacement for the NSToolbar while in native full screen, where
/// AppKit's toolbar backdrop can't be themed. Mirrors the toolbar layout:
/// sidebar toggle leading, tab strip, the inspector / pin row trailing.
/// Upstream.
private struct ChatFullScreenHeaderView: View {
    @ObservedObject var windowState: ChatWindowState

    var body: some View {
        HStack(spacing: 8) {
            IntelToolbarSidebarView(windowState: windowState)
            // Trailing fallback: two 28pt buttons, their 8pt gap, the HStack
            // spacing and the row's horizontal padding — until measured.
            ChatTabStripView(windowState: windowState, leadingChromeWidth: 76, trailingChromeWidth: 84)
            IntelToolbarTrailingView(windowState: windowState)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(windowState.theme.primaryBackground)
    }
}

/// The chat window, with browser-style tab shortcuts (upstream
/// `ChatPanel`). ⌘W closes the active tab; only a lone blank tab closes
/// the window. Shortcuts are key equivalents so they win over views that
/// swallow key-downs (the composer).
final class IntelChatWindow: NSWindow {
    weak var chatWindowState: ChatWindowState?

    override func performClose(_ sender: Any?) {
        if let state = chatWindowState, state.closeActiveTabIfPossible() {
            return
        }
        super.performClose(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if let state = chatWindowState,
            let shortcut = ChatTabShortcut(event: event),
            shortcut.perform(on: state)
        {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

/// The tab shortcuts a chat window handles itself (upstream `ChatPanel`):
/// ⌘N new tab in the current project (overrides File ▸ New Window while the
/// chat surface is showing; on the project page the menu keeps ⌘N), ⌘T new
/// tab, ⇧⌘T reopen the last closed tab, ⌃Tab / ⌃⇧Tab and ⇧⌘] / ⇧⌘[ cycle
/// tabs. AppKit asks the key window before the menu bar, so handling them
/// here is what keeps New Window from firing.
enum ChatTabShortcut: Equatable {
    case newTabInCurrentProject
    case newTab
    case reopenClosedTab
    case nextTab
    case previousTab

    init?(keyCode: UInt16, characters: String, flags: NSEvent.ModifierFlags) {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        // Tab key (keyCode 48) with ⌃: next / previous tab.
        if keyCode == 48, flags.contains(.control) {
            self = flags.contains(.shift) ? .previousTab : .nextTab
            return
        }
        switch (flags, characters.lowercased()) {
        case (.command, "n"): self = .newTabInCurrentProject
        case (.command, "t"): self = .newTab
        case ([.command, .shift], "t"): self = .reopenClosedTab
        case ([.command, .shift], "]"), ([.command, .shift], "}"): self = .nextTab
        case ([.command, .shift], "["), ([.command, .shift], "{"): self = .previousTab
        default: return nil
        }
    }

    init?(event: NSEvent) {
        self.init(
            keyCode: event.keyCode,
            characters: event.charactersIgnoringModifiers ?? "",
            flags: event.modifierFlags)
    }

    /// Returns false when the shortcut does nothing here, so the key
    /// travels on (tabs are chat chrome; the project page has none).
    @MainActor
    func perform(on state: ChatWindowState) -> Bool {
        guard !state.isProjectPageVisible else { return false }
        switch self {
        case .newTabInCurrentProject: state.newTabInCurrentProject()
        case .newTab: state.newTab()
        case .reopenClosedTab: state.reopenLastClosedTab()
        case .nextTab: state.selectAdjacentTab(offset: 1)
        case .previousTab: state.selectAdjacentTab(offset: -1)
        }
        return true
    }
}

// MARK: - Intel Chat Toolbar

/// Places each control in its own `NSToolbarItem` so macOS applies native
/// per-item styling. Upstream `ChatToolbarDelegate` layout: sidebar toggle
/// leading, the tab strip filling the middle, the inspector toggle and Pin
/// Window trailing. The agent pill lives in the navigator (sidebar) now, as
/// upstream; Settings is the navigator's footer row.
@MainActor
final class IntelChatToolbarDelegate: NSObject, NSToolbarDelegate {
    static let sidebarItem = NSToolbarItem.Identifier("IntelChatToolbar.sidebar")
    static let tabsItem = NSToolbarItem.Identifier("IntelChatToolbar.tabs")
    /// The single trailing item: inspector toggle and Pin Window as one row
    /// of identically sized buttons (a hidden item of its own would still
    /// reserve AppKit's inter-item spacing).
    static let trailingItem = NSToolbarItem.Identifier("IntelChatToolbar.trailing")

    /// The tab item is flexible, so it doubles as the space that pushes the
    /// trailing item to the right edge.
    private static let ids: [NSToolbarItem.Identifier] = [sidebarItem, tabsItem, trailingItem]

    private weak var windowState: ChatWindowState?

    init(windowState: ChatWindowState) {
        self.windowState = windowState
        super.init()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.ids
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        Self.ids
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        guard let windowState else { return nil }
        switch itemIdentifier {
        case Self.sidebarItem:
            return host(itemIdentifier, IntelToolbarSidebarView(windowState: windowState))
        case Self.tabsItem:
            return makeTabStripItem(itemIdentifier, ChatTabStripView(windowState: windowState))
        case Self.trailingItem:
            return host(itemIdentifier, IntelToolbarTrailingView(windowState: windowState))
        default:
            return nil
        }
    }

    private func host<Content: View>(
        _ identifier: NSToolbarItem.Identifier,
        _ rootView: Content
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let hosting = NSHostingView(rootView: rootView)
        // Let AppKit follow SwiftUI's intrinsic size instead of freezing the
        // initial fitting size and clipping it.
        hosting.sizingOptions = [.intrinsicContentSize]
        item.view = hosting
        item.isBordered = false
        return item
    }

    /// The tab strip's item takes whatever width the toolbar has left, like
    /// a flexible space. AppKit sizes it in the same layout pass as the
    /// window resize, so the strip never waits on a measurement of its own
    /// (upstream #2802: sizing it from its content made the toolbar squeeze,
    /// jump and draw tabs over the sidebar on a fast resize).
    private func makeTabStripItem<Content: View>(
        _ identifier: NSToolbarItem.Identifier,
        _ rootView: Content
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let hosting = NSHostingView(rootView: rootView)
        hosting.sizingOptions = []
        hosting.translatesAutoresizingMaskIntoConstraints = false
        // A min/max RANGE is what makes a toolbar item flexible: AppKit
        // stretches it into the free space. A large preferred width instead
        // reads as the space the item needs, and AppKit hides it as too wide.
        NSLayoutConstraint.activate([
            hosting.widthAnchor.constraint(
                greaterThanOrEqualToConstant: ChatTabStripView.minimumItemWidth),
            hosting.widthAnchor.constraint(lessThanOrEqualToConstant: 10_000),
            hosting.heightAnchor.constraint(equalToConstant: ChatTabStripView.stripHeight),
        ])
        hosting.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        hosting.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)
        item.view = hosting
        item.isBordered = false
        // Fold the trailing buttons into the overflow menu before the tabs.
        item.visibilityPriority = .high
        return item
    }
}

// MARK: - Intel Toolbar Item Views

private struct IntelToolbarSidebarView: View {
    @ObservedObject var windowState: ChatWindowState

    var body: some View {
        HeaderActionButton(
            icon: "sidebar.left",
            help: windowState.isSidebarVisible ? "Hide sidebar" : "Show sidebar",
            action: {
                withAnimation(windowState.theme.animationQuick()) {
                    windowState.toggleSidebar()
                }
            }
        )
        .environment(\.theme, windowState.theme)
    }
}

/// The single trailing toolbar item: the right-rail toggle and Pin Window
/// as one row of `HeaderActionButton`s with one spacing rule. Upstream
/// `ChatToolbarTrailingView`: the toggle opens the chat inspector for a
/// chat and Project Settings for a project; only the window pin is
/// chat-only chrome. No file-count badge on Intel yet (no file history).
private struct IntelToolbarTrailingView: View {
    @ObservedObject var windowState: ChatWindowState

    var body: some View {
        HStack(spacing: 8) {
            let isProject = windowState.isProjectPageVisible
            let isOpen = windowState.isRightRailOpen
            HeaderActionButton(
                icon: "sidebar.right",
                help: railToggleHelp(isProject: isProject, isOpen: isOpen),
                isActive: isOpen,
                badge: isProject ? nil : windowState.inspectorBadgeCount,
                action: {
                    withAnimation(windowState.theme.animationQuick()) {
                        if isProject {
                            windowState.toggleProjectInspector()
                        } else {
                            windowState.toggleInspector()
                        }
                    }
                }
            )
            .accessibilityLabel(
                Text(LocalizedStringKey(railToggleHelp(isProject: isProject, isOpen: isOpen)), bundle: .module))
            // Tour spotlight anchor (invisible; reports the button's frame).
            .background(TourAnchorMarker(anchor: .historyButton))

            if !isProject {
                HeaderActionButton(
                    icon: windowState.isWindowPinned ? "pin.fill" : "pin",
                    help: windowState.isWindowPinned ? "Unpin Window" : "Pin Window",
                    action: {
                        windowState.isWindowPinned.toggle()
                        ChatWindowManager.shared.setWindowPinned(
                            id: windowState.windowId, pinned: windowState.isWindowPinned)
                    }
                )
            }
        }
        .environment(\.theme, windowState.theme)
    }

    /// Key of the toggle's tooltip (a `HeaderActionButton.help` string).
    private func railToggleHelp(isProject: Bool, isOpen: Bool) -> String {
        switch (isProject, isOpen) {
        case (true, true): return "Hide project settings"
        case (true, false): return "Show project settings"
        case (false, true): return "Hide inspector"
        case (false, false): return "Show inspector"
        }
    }
}
#endif
