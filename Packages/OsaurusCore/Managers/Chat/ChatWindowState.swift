#if !OSAURUS_INTEL
//
//  ChatWindowState.swift
//  osaurus
//
//  Per-window state container that isolates each ChatView window from shared singletons.
//  Pre-computes values needed for view rendering so view body is read-only.
//

import AppKit
import Combine
import Foundation
import SwiftUI

/// Per-window state container for ChatView - each window creates its own instance
@MainActor
final class ChatWindowState: ObservableObject {
    // MARK: - Identity & Session

    let windowId: UUID
    let session: ChatSession
    let foundationModelAvailable: Bool

    // MARK: - View State

    @Published var showSidebar: Bool = false

    /// Drives the in-chat "Keep this chat running?" confirmation overlay
    /// that intercepts a close while `session.isStreaming` is true. Set
    /// from `ChatWindowManager.shouldAllowClose`; cleared by the alert's
    /// button actions in `ChatView`.
    @Published var showCloseConfirmation: Bool = false

    // MARK: - Agent State

    @Published var agentId: UUID
    @Published private(set) var agents: [Agent] = []
    @Published private(set) var discoveredAgents: [DiscoveredAgent] = []
    @Published var selectedDiscoveredAgent: DiscoveredAgent?
    @Published var selectedDiscoveredAgentProviderId: UUID?
    @Published private(set) var pairedRelayAgents: [PairedRelayAgent] = []
    @Published var selectedRelayAgent: PairedRelayAgent?

    // MARK: - Theme State

    @Published private(set) var theme: ThemeProtocol
    @Published private(set) var cachedBackgroundImage: NSImage?

    // MARK: - Pre-computed View Values

    @Published private(set) var filteredSessions: [ChatSessionData] = []
    @Published private(set) var cachedSystemPrompt: String = ""
    @Published private(set) var cachedActiveAgent: Agent = .default
    @Published private(set) var cachedAgentDisplayName: String = L("Assistant")

    // MARK: - Private

    private nonisolated(unsafe) var notificationObservers: [NSObjectProtocol] = []
    private var sessionRefreshWorkItem: DispatchWorkItem?
    private var bonjourCancellable: AnyCancellable?
    private var agentsCancellable: AnyCancellable?
    private var sessionsCancellable: AnyCancellable?

    // MARK: - Initialization

    init(windowId: UUID, agentId: UUID, sessionData: ChatSessionData? = nil) {
        self.windowId = windowId
        self.agentId = agentId
        self.session = ChatSession()
        self.foundationModelAvailable = AppConfiguration.shared.foundationModelAvailable
        self.theme = Self.loadTheme(for: agentId)

        // Load initial data
        self.agents = AgentManager.shared.agents
        self.filteredSessions = ChatSessionsManager.shared.sessions(for: agentId)

        // Pre-compute view values
        self.cachedSystemPrompt = AgentManager.shared.effectiveSystemPrompt(for: agentId)
        self.cachedActiveAgent = agents.first { $0.id == agentId } ?? .default
        self.cachedAgentDisplayName = Self.displayName(for: cachedActiveAgent)
        decodeBackgroundImageAsync(themeConfig: theme.customThemeConfig)

        // Configure session
        self.session.windowState = self
        self.session.agentId = agentId
        self.session.applyInitialModelSelection()
        if let data = sessionData {
            self.session.load(from: data)
        }
        self.session.onSessionChanged = { [weak self] in
            self?.refreshSessionsDebounced()
        }

        setupNotificationObservers()
        observeBonjourBrowser()
        observeAgentManager()
        observeSessionsManager()
        refreshPairedRelayAgents()
    }

    /// Wrap an existing `ExecutionContext`, reusing its sessions without duplication.
    /// Used for lazy window creation when a user clicks "View" on a toast.
    init(windowId: UUID, executionContext context: ExecutionContext) {
        self.windowId = windowId
        self.agentId = context.agentId
        self.session = context.chatSession
        self.foundationModelAvailable = AppConfiguration.shared.foundationModelAvailable
        self.theme = Self.loadTheme(for: context.agentId)

        self.agents = AgentManager.shared.agents
        self.filteredSessions = ChatSessionsManager.shared.sessions(for: context.agentId)
        self.cachedSystemPrompt = AgentManager.shared.effectiveSystemPrompt(for: context.agentId)
        self.cachedActiveAgent = agents.first { $0.id == context.agentId } ?? .default
        self.cachedAgentDisplayName = Self.displayName(for: cachedActiveAgent)
        decodeBackgroundImageAsync(themeConfig: theme.customThemeConfig)

        self.session.onSessionChanged = { [weak self] in
            self?.refreshSessionsDebounced()
        }

        setupNotificationObservers()
        observeBonjourBrowser()
        observeAgentManager()
        observeSessionsManager()
        refreshPairedRelayAgents()
    }

    deinit {
        print("[ChatWindowState] deinit – windowId: \(windowId)")
        notificationObservers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    /// Stops any running execution and breaks reference chains — call when window is closing.
    func cleanup() {
        removeEphemeralProviderIfNeeded()
        selectedDiscoveredAgent = nil
        selectedDiscoveredAgentProviderId = nil
        selectedRelayAgent = nil
        session.stop()
        session.onSessionChanged = nil
    }

    // MARK: - Close-Confirmation Actions

    /// "Continue in Background" — adopt the live session as a background
    /// task (visible in the notch) and dismiss the window.
    func confirmCloseInBackground() {
        BackgroundTaskManager.shared.detachChatWindow(windowId: windowId)
        ChatWindowManager.shared.closeWindow(id: windowId)
    }

    /// "Stop and Close" — cancel the in-flight stream, then dismiss.
    func confirmCloseAndStop() {
        session.stop()
        ChatWindowManager.shared.closeWindow(id: windowId)
    }

    // MARK: - API

    var activeAgent: Agent { cachedActiveAgent }

    var themeId: UUID? {
        AgentManager.shared.themeId(for: agentId)
    }

    func switchAgent(to newAgentId: UUID) {
        TTSService.shared.stop()
        if !session.turns.isEmpty { session.save() }
        adoptAgent(newAgentId)
        session.reset(for: newAgentId)
        refreshSessions()
    }

    func startNewChat() {
        TTSService.shared.stop()
        if !session.turns.isEmpty { session.save() }
        flushCurrentSession()
        session.reset(for: agentId)
        refreshSessions()
    }

    func loadSession(_ sessionData: ChatSessionData) {
        guard sessionData.id != session.sessionId else { return }
        TTSService.shared.stop()
        if !session.turns.isEmpty { session.save() }
        flushCurrentSession()

        let resolvedData = ChatSessionStore.load(id: sessionData.id) ?? sessionData
        let targetAgentId = resolvedData.agentId ?? Agent.defaultId

        // Sync the window's active agent with the loaded session so the
        // chat header, theme, dropdown, sidebar filter, and downstream
        // save()/reset() calls all reflect the conversation's true agent
        // (#1005). Without this, clicking "New Chat" afterwards silently
        // re-tags the conversation to the previously-selected agent.
        if targetAgentId != agentId {
            adoptAgent(targetAgentId)
        }

        session.load(from: resolvedData)
        refreshSessions()
    }

    /// Switch every per-agent piece of window state (`agentId`,
    /// discovered/relay-agent pills, theme, system-prompt cache, global
    /// active-agent pointer) to `newAgentId` WITHOUT touching the
    /// session's content. `switchAgent` calls this before resetting the
    /// session for a brand-new chat; `loadSession` calls it before
    /// loading turns from disk.
    private func adoptAgent(_ newAgentId: UUID) {
        removeEphemeralProviderIfNeeded()
        selectedDiscoveredAgent = nil
        selectedDiscoveredAgentProviderId = nil
        selectedRelayAgent = nil
        agentId = newAgentId
        refreshTheme()
        refreshAgentConfig()
        AgentManager.shared.setActiveAgent(newAgentId)
    }

    private func flushCurrentSession() {
        guard let sid = session.sessionId else { return }
        let agentStr = (session.agentId ?? Agent.defaultId).uuidString
        let convStr = sid.uuidString
        Task {
            await MemoryService.shared.flushSession(agentId: agentStr, conversationId: convStr)
        }
    }

    // MARK: - Refresh Methods

    func refreshAgents() {
        agents = AgentManager.shared.agents
        cachedActiveAgent = agents.first { $0.id == agentId } ?? .default
        cachedAgentDisplayName = Self.displayName(for: cachedActiveAgent)
    }

    func refreshSessions() {
        filteredSessions = ChatSessionsManager.shared.sessions(for: agentId)
    }

    /// Coalesces rapid `refreshSessions()` calls (e.g. during streaming saves).
    func refreshSessionsDebounced() {
        sessionRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.refreshSessions()
            }
        }
        sessionRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
    }

    func refreshTheme() {
        let newTheme = Self.loadTheme(for: agentId)
        let oldConfig = theme.customThemeConfig
        let newConfig = newTheme.customThemeConfig
        // Skip only if the full config is identical (not just the ID) and the
        // global font zoom is unchanged — the zoom lives on the theme instance,
        // not in the config, so it must be compared separately. Upstream 1b955c2b.
        let oldScale = (theme as? CustomizableTheme)?.fontScale
        let newScale = (newTheme as? CustomizableTheme)?.fontScale
        guard oldConfig != newConfig || oldScale != newScale else { return }
        let shouldRedecodeBackgroundImage = Self.needsBackgroundImageRedecode(
            oldConfig: oldConfig,
            newConfig: newConfig
        )

        theme = newTheme

        if shouldRedecodeBackgroundImage {
            decodeBackgroundImageAsync(themeConfig: newConfig)
        }
    }

    nonisolated static func needsBackgroundImageRedecode(oldConfig: CustomTheme?, newConfig: CustomTheme?) -> Bool {
        BackgroundImageDecodeKey(config: oldConfig) != BackgroundImageDecodeKey(config: newConfig)
    }

    func refreshAgentConfig() {
        cachedSystemPrompt = AgentManager.shared.effectiveSystemPrompt(for: agentId)
        cachedActiveAgent = agents.first { $0.id == agentId } ?? .default
        cachedAgentDisplayName = Self.displayName(for: cachedActiveAgent)
        session.invalidateTokenCache()
    }

    func refreshAll() async {
        refreshAgents()
        refreshSessions()
        refreshTheme()
        refreshAgentConfig()
        await session.refreshPickerItems()
    }

    // MARK: - Private

    private func observeBonjourBrowser() {
        bonjourCancellable = BonjourBrowser.shared.$discoveredAgents
            .receive(on: RunLoop.main)
            .sink { [weak self] agents in
                self?.discoveredAgents = agents
                if let selected = self?.selectedDiscoveredAgent,
                    !agents.contains(where: { $0.id == selected.id })
                {
                    self?.removeEphemeralProviderIfNeeded()
                    self?.selectedDiscoveredAgent = nil
                    self?.selectedDiscoveredAgentProviderId = nil
                }
                self?.refreshPairedRelayAgents(discoveredAgents: agents)
            }
    }

    /// Mirror `AgentManager.shared.$agents` into this window so the picker,
    /// `cachedActiveAgent`, and `cachedAgentDisplayName` stay live across
    /// mutations from anywhere (AgentsView, onboarding, plugins, other
    /// windows). The publisher is already `@MainActor`-bound, so we skip
    /// `.receive(on:)` to avoid an unnecessary RunLoop hop.
    ///
    /// `@Published` replays its current value on subscribe; since the
    /// initializers populate the cached fields with the same source-of-
    /// truth values just before calling this, that first replay no-ops in
    /// the `oldActive == newActive` gate of `applyAgentsUpdate`.
    private func observeAgentManager() {
        agentsCancellable = AgentManager.shared.$agents
            .sink { [weak self] latest in
                self?.applyAgentsUpdate(latest)
            }
    }

    private func observeSessionsManager() {
        sessionsCancellable = ChatSessionsManager.shared.$sessions
            .dropFirst()
            .sink { [weak self] _ in
                self?.refreshSessions()
            }
    }

    /// Reconcile our snapshot with a fresh emission from `AgentManager.$agents`.
    ///
    /// - Active agent missing → fall back to Default via `switchAgent`.
    /// - Otherwise always update the dropdown-facing snapshot (cheap path
    ///   that handles non-active mutations).
    /// - Only when the active agent's `Agent` value changed do we touch the
    ///   token cache, system-prompt cache, and theme — same gating the
    ///   removed `.agentUpdated` observer used to do, now driven by the
    ///   source-of-truth array's `Equatable` diff.
    ///
    /// IMPORTANT: do not read from `AgentManager.shared.agents` (or
    /// `effectiveSystemPrompt`, which routes through it) inside this
    /// method. Combine's `@Published` emits in `willSet`, so during the
    /// sink callback the singleton's storage still holds the OLD array;
    /// only `latest` and the resolved `newActive` are guaranteed fresh.
    private func applyAgentsUpdate(_ latest: [Agent]) {
        let oldActive = cachedActiveAgent
        agents = latest

        guard let newActive = latest.first(where: { $0.id == agentId }) else {
            #if OSAURUS_INTEL
            // SESSION-DEATH GUARD (Intel): a transient/partial `$agents`
            // emission must NEVER tear down the live session. The Intel
            // AgentManager rebuilds `agents` by re-decoding every custom-agent
            // JSON from disk on each reload; if the active agent's file is
            // momentarily unreadable (mid-write / transient I/O), it drops out
            // of `latest` for one emission. The old code reacted by calling
            // `switchAgent(.default)` -> `session.reset()`, wiping the
            // conversation and killing any in-flight run ("name flashes, then
            // poof"). Only fall back to Default when we're CONFIDENT the agent
            // is genuinely gone: list non-empty, not mid-stream, and the
            // agent's JSON truly no longer exists on disk.
            let agentFile = OsaurusPaths.agents()
                .appendingPathComponent("\(agentId.uuidString).json")
            let fileStillExists = FileManager.default.fileExists(atPath: agentFile.path)
            let trulyGone = !latest.isEmpty && !session.isStreaming && !fileStillExists
            if trulyGone {
                print("[ChatWindowState] active agent \(agentId) genuinely removed → fallback to Default")
                switchAgent(to: Agent.defaultId)
            } else {
                print(
                    "[ChatWindowState] IGNORING transient agents emission missing active agent "
                        + "\(agentId) (count=\(latest.count) streaming=\(session.isStreaming) "
                        + "fileExists=\(fileStillExists)) — keeping session alive"
                )
            }
            return
            #else
            // `switchAgent` updates theme/sessions/config and persists the
            // selection. `agents` was just swapped above, so any re-read
            // inside `switchAgent` sees the fresh list.
            switchAgent(to: Agent.defaultId)
            return
            #endif
        }

        cachedActiveAgent = newActive
        cachedAgentDisplayName = Self.displayName(for: newActive)

        guard newActive != oldActive else { return }

        // The Default agent's mutable settings live in `ChatConfiguration`
        // and are kept fresh by the `.appConfigurationChanged` observer;
        // here we only refresh the cache for the custom-agent case (using
        // the fresh `newActive`, not the stale singleton).
        if !newActive.isBuiltIn {
            cachedSystemPrompt = newActive.systemPrompt
        }
        session.invalidateTokenCache()

        if newActive.themeId != oldActive.themeId {
            refreshTheme()
        }
    }

    func refreshPairedRelayAgents(discoveredAgents: [DiscoveredAgent]? = nil) {
        let knownAgents = discoveredAgents ?? self.discoveredAgents
        let discoveredIds = Set(knownAgents.map(\.id))
        let manager = RemoteProviderManager.shared
        pairedRelayAgents = manager.configuration.providers.compactMap { provider in
            guard provider.providerType == .osaurus,
                !manager.isEphemeral(id: provider.id),
                let agentId = provider.remoteAgentId,
                let relayAddress = provider.remoteAgentAddress,
                !discoveredIds.contains(agentId)
            else { return nil }
            return PairedRelayAgent(
                id: agentId,
                name: provider.name,
                remoteAgentAddress: relayAddress,
                providerId: provider.id
            )
        }
    }

    private func removeEphemeralProviderIfNeeded() {
        guard let providerId = selectedDiscoveredAgentProviderId,
            RemoteProviderManager.shared.isEphemeral(id: providerId)
        else { return }
        RemoteProviderManager.shared.removeProvider(id: providerId)
    }

    private static func loadTheme(for agentId: UUID) -> ThemeProtocol {
        if let themeId = AgentManager.shared.themeId(for: agentId),
            let custom = ThemeManager.shared.installedThemes.first(where: { $0.metadata.id == themeId })
        {
            return CustomizableTheme(config: custom)
        }
        return ThemeManager.shared.currentTheme
    }

    /// Built-in (Default) agent always renders as the localized "Assistant"
    /// label so the chat header doesn't expose the internal `"Default"` name;
    /// custom agents render their stored name verbatim.
    private static func displayName(for agent: Agent) -> String {
        agent.isBuiltIn ? L("Assistant") : agent.name
    }

    private func decodeBackgroundImageAsync(themeConfig: CustomTheme?) {
        Task { [weak self] in
            let decoded = themeConfig?.background.decodedImage()
            self?.cachedBackgroundImage = decoded
        }
    }

    private struct BackgroundImageDecodeKey: Equatable {
        let themeId: UUID?
        let backgroundType: ThemeBackground.BackgroundType?
        let imageData: String?

        init(config: CustomTheme?) {
            self.themeId = config?.metadata.id
            self.backgroundType = config?.background.type
            self.imageData = config?.background.imageData
        }
    }

    private func setupNotificationObservers() {
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .activeAgentChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.refreshAgents() } }
        )
        // Note: .chatOverlayActivated intentionally not observed here
        // State is loaded in init(), refreshAll() would cause excessive re-renders
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .appConfigurationChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in Task { @MainActor in self?.refreshAgentConfig() } }
        )
        // refresh theme when any theme on disk changes. refreshTheme()
        // re-resolves from `installedThemes`/`currentTheme` and no ops via its
        // config equality guard if this window's effective theme is unchanged,
        // so windows pinned to an agent specific theme also pick up live edits
        // to that theme without waiting for a reopen
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .globalThemeChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.refreshTheme() }
            }
        )
        // Note: `.agentUpdated` is intentionally not observed here.
        // `observeAgentManager()` covers active-custom-agent updates by
        // diffing the published `agents` array, and the
        // `.appConfigurationChanged` observer above covers Default-agent
        // updates (whose settings live in `ChatConfiguration`).

        // Clear the selected paired/relay agent pill when its provider is
        // removed from settings.
        notificationObservers.append(
            NotificationCenter.default.addObserver(
                forName: .remoteProviderStatusChanged,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self,
                        let providerId = self.selectedDiscoveredAgentProviderId
                    else { return }
                    let providerExists = RemoteProviderManager.shared.configuration.providers
                        .contains(where: { $0.id == providerId })
                    guard !providerExists else { return }
                    self.selectedDiscoveredAgent = nil
                    self.selectedRelayAgent = nil
                    self.selectedDiscoveredAgentProviderId = nil
                    self.refreshPairedRelayAgents()
                }
            }
        )
    }
}
#else
// Intel fork: per-window chat state with browser-style tabs (upstream
// #2630 and follow-ups, docs/CHAT_TABS_INTEL.md). Upstream's workspace,
// relay and inspector state is absent: Intel has local agents only.
import AppKit
import Combine
import Foundation
import SwiftUI

/// One browser-style tab in a chat window. Identity is the tab's own id;
/// the session it holds is replaceable (opening a chat inside the tab can
/// swap it, just like the window's single session used to be swapped).
struct ChatTab: Identifiable, Equatable {
    let id: UUID
    var session: ChatSession
    /// LRU stamp: when this tab last became the active tab. Drives which
    /// idle tabs get hibernated when the window holds too many.
    var lastActivatedAt: Date = Date()
    /// A hibernated tab keeps only a metadata-level session (title, agent,
    /// ids; no turns) so the chip still renders; the transcript reloads
    /// when the tab is selected again.
    var isHibernated: Bool = false

    static func == (lhs: ChatTab, rhs: ChatTab) -> Bool {
        lhs.id == rhs.id && lhs.session === rhs.session
    }
}

/// Which agent a tab belongs to. The tab strip shows only the active
/// agent's tabs, and picking another agent shows that agent's. Upstream
/// also scopes chats with a teammate's shared agent (`.workspace`); Intel
/// has no workspaces, so every tab is a local agent's.
enum ChatTabScope: Hashable {
    case local(UUID)

    @MainActor
    static func of(_ session: ChatSession) -> ChatTabScope {
        .local(session.agentId ?? Agent.defaultId)
    }
}

/// The panes of the chat window's right-hand inspector. One rail, two
/// contents, both about the tab on screen. Intel has no file change
/// history yet (`W-file-history`), so only History is ever shown; the case
/// stays so the rail's code matches upstream.
enum ChatInspectorPane: Hashable {
    /// This chat's file history: timeline, per-file net state, revert.
    case fileChanges
    /// The past chats of this chat's agent (search, filters, import).
    case history
}

@MainActor
final class ChatWindowState: ObservableObject {
    let windowId: UUID
    /// The session the window shows: always the active tab's. Replaceable,
    /// so the window root rebuilds `ChatView` around a new instance
    /// (`.id(ObjectIdentifier(session))`). The didSet keeps the tab entry in
    /// sync when in-tab navigation replaces the instance.
    @Published private(set) var session: ChatSession {
        didSet { syncActiveTabSession() }
    }
    let foundationModelAvailable: Bool = false

    // MARK: Tabs

    /// Browser-style tabs, each holding its own `ChatSession`. Inactive tabs
    /// keep their sessions alive (a reply keeps streaming there); closing a
    /// tab saves and stops its session, or hands a running one to
    /// `DetachedChatRunRegistry`.
    @Published private(set) var tabs: [ChatTab] = [] {
        didSet { onTabLayoutChanged?() }
    }
    @Published private(set) var activeTabId: UUID = UUID() {
        didSet { onTabLayoutChanged?() }
    }

    /// Fired whenever the tabs or the active tab change (and on session
    /// refreshes, which is when a blank tab gets its first saved turn).
    /// `ChatWindowManager` uses it to remember open tabs across window
    /// close and relaunch (`ChatTabLayoutStore`). Not `@Published`.
    var onTabLayoutChanged: (() -> Void)?

    /// The agent whose tabs the strip shows: the window's agent, which
    /// follows the active tab.
    var activeScope: ChatTabScope { .local(agentId) }

    /// The tabs visible in the strip: the active agent's, in global order.
    /// The active tab is always included so the strip never shows a
    /// selection it doesn't contain.
    var scopedTabs: [ChatTab] {
        let scope = activeScope
        return tabs.filter { $0.id == activeTabId || ChatTabScope.of($0.session) == scope }
    }

    /// Tabs in `scope`, in global order.
    func tabs(in scope: ChatTabScope) -> [ChatTab] {
        tabs.filter { ChatTabScope.of($0.session) == scope }
    }

    /// Every session this window holds, across all tabs.
    var tabSessions: [ChatSession] { tabs.map(\.session) }

    /// Sessions actually hydrated (hibernated stand-ins have ids but no
    /// transcript).
    var liveTabSessions: [ChatSession] {
        tabs.filter { !$0.isHibernated }.map(\.session)
    }

    // MARK: View state

    /// Session sidebar starts open so a fresh window surfaces its agents
    /// immediately; the toolbar toggle still collapses it per window.
    @Published var showSidebar: Bool = true

    /// True while the sidebar is stepping aside for the open inspector
    /// because the window is too narrow for both (`ChatContentView` sets it
    /// from its geometry). Separate from `showSidebar` so the user's choice
    /// survives and the sidebar returns when the inspector closes.
    @Published var isSidebarAutoHidden: Bool = false

    /// Width of the right rail actually on screen, 0 while closed.
    /// `ChatContentView` sets it from its geometry; the tab strip reads it to
    /// stop the tabs at the chat column's trailing edge (#2910).
    @Published var inspectorColumnWidth: CGFloat = 0

    /// Whether the sidebar is on screen. The toolbar toggle and the tab
    /// strip inset read this, not `showSidebar`.
    var isSidebarVisible: Bool { showSidebar && !isSidebarAutoHidden }

    /// Toolbar button / ⌘B. When the sidebar is stepping aside for the
    /// inspector, the user asking for it wins: the inspector closes and the
    /// sidebar (still "shown") comes back — a plain flip would hide nothing
    /// visible and leave the button looking broken.
    func toggleSidebar() {
        if showSidebar && isSidebarAutoHidden {
            if isProjectPageVisible {
                showProjectInspector = false
            } else {
                inspectorPane = nil
            }
            return
        }
        showSidebar.toggle()
    }

    /// True while the active chat was entered from its project's page (or
    /// started there via ⌘N); keeps the navigator on its Projects lens.
    @Published var enteredChatFromProjectPage: Bool = false

    /// Floating window (Pin Window in the toolbar).
    @Published var isWindowPinned: Bool = false

    // MARK: Inspector (upstream #2907 part C)

    /// Which pane the right-hand inspector shows, or nil while it is closed.
    @Published var inspectorPane: ChatInspectorPane? {
        didSet { if let inspectorPane { lastInspectorPane = inspectorPane } }
    }

    /// The pane the inspector reopens on. History by default.
    @Published private(set) var lastInspectorPane: ChatInspectorPane = .history

    /// True once the user picked the pane on purpose (lens bar tap). A
    /// pinned pane is shown as asked; an unpinned request may fall back.
    @Published private(set) var inspectorPanePinned = false

    var isInspectorOpen: Bool { inspectorPane != nil }

    /// Whether the right rail shows Project Settings while a project is on
    /// screen. The same toolbar toggle that opens the chat inspector drives
    /// it there; the choice is remembered across projects and launches
    /// (open by default: a project's settings are what the rail is for).
    @Published var showProjectInspector: Bool =
        UserDefaults.standard.object(forKey: projectInspectorDefaultsKey) as? Bool ?? true
    {
        didSet { UserDefaults.standard.set(showProjectInspector, forKey: Self.projectInspectorDefaultsKey) }
    }

    static let projectInspectorDefaultsKey = "chatWindow.showProjectInspector"

    /// Toolbar toggle while a project is open (mirror of `toggleInspector()`).
    func toggleProjectInspector() {
        showProjectInspector.toggle()
    }

    /// True when a right rail is on screen for the current content: the
    /// chat inspector for a chat, Project Settings for a project.
    var isRightRailOpen: Bool {
        isProjectPageVisible ? showProjectInspector : isInspectorOpen
    }

    /// File change history is not ported (`W-file-history`): always zero.
    let fileChangesCount: Int = 0
    let fileChangeSetCount: Int = 0

    /// The pane the rail actually draws. An unpinned File Changes request
    /// for a chat with no change sets shows History instead. Upstream.
    nonisolated static func effectiveInspectorPane(
        requested: ChatInspectorPane?,
        fileChangeSetCount: Int,
        isPinned: Bool
    ) -> ChatInspectorPane? {
        guard requested == .fileChanges, fileChangeSetCount == 0, !isPinned else { return requested }
        return .history
    }

    var effectiveInspectorPane: ChatInspectorPane? {
        Self.effectiveInspectorPane(
            requested: inspectorPane,
            fileChangeSetCount: fileChangeSetCount,
            isPinned: inspectorPanePinned
        )
    }

    /// Toolbar button: closes the inspector when it is open, otherwise
    /// reopens it on the pane it last showed.
    func toggleInspector() {
        if inspectorPane == nil {
            inspectorPanePinned = false
            inspectorPane = lastInspectorPane
        } else {
            inspectorPane = nil
        }
    }

    /// Show `pane` (opening the inspector or switching in place) and pin it.
    func showInspector(_ pane: ChatInspectorPane) {
        inspectorPanePinned = true
        inspectorPane = pane
    }

    func closeInspector() {
        inspectorPane = nil
    }

    /// Change set the inspector should reveal (File Changes; unused until
    /// file history is ported).
    @Published var changesPanelFocusSetId: UUID?

    /// Count shown on the toolbar's inspector toggle: the files this chat
    /// changed, only while the inspector is closed, only for local chats,
    /// and never zero. Upstream; always nil on Intel until file history is
    /// ported (`fileChangesCount` is 0).
    nonisolated static func inspectorBadgeCount(
        fileChangesCount: Int,
        isInspectorOpen: Bool,
        isRemoteAgentChat: Bool
    ) -> Int? {
        guard fileChangesCount > 0, !isInspectorOpen, !isRemoteAgentChat else { return nil }
        return fileChangesCount
    }

    var inspectorBadgeCount: Int? {
        Self.inspectorBadgeCount(
            fileChangesCount: fileChangesCount,
            isInspectorOpen: isInspectorOpen,
            isRemoteAgentChat: selectedDiscoveredAgentProviderId != nil
        )
    }
    @Published var showCloseConfirmation: Bool = false
    /// Drives the in-conversation find bar (Cmd+F). Set by the window-level
    /// key monitor (which cannot touch `ChatView`'s `@State`) and cleared by
    /// the bar's close button or the Esc dismissal chain.
    @Published var isFindBarVisible: Bool = false
    @Published var agentId: UUID
    @Published var agents: [Agent] = []
    @Published var discoveredAgents: [DiscoveredAgent] = []
    @Published var selectedDiscoveredAgent: DiscoveredAgent? = nil
    @Published var selectedDiscoveredAgentProviderId: UUID? = nil
    @Published var pairedRelayAgents: [PairedRelayAgent] = []
    @Published var selectedRelayAgent: PairedRelayAgent? = nil
    @Published var theme: ThemeProtocol
    @Published var cachedBackgroundImage: NSImage? = nil
    @Published var filteredSessions: [ChatSessionData] = []
    @Published var cachedSystemPrompt: String = ""
    @Published var cachedActiveAgent: Agent = .default
    @Published var cachedAgentDisplayName: String = "Assistant"
    @Published var selectedModel: String = "deepseek-v4-pro"
    @Published var availableModels: [String] = ["deepseek-flash", "deepseek-v4-pro"]
    /// Non-nil while the window's main content area is showing a project
    /// page instead of the chat thread/composer. In-memory window state only
    /// (not persisted `Codable`), so a plain stored property is safe here —
    /// this is NOT `ChatSessionData`/`Project`, the types the "never add a
    /// non-optional stored property to a persisted Codable type" rule guards.
    @Published public var openProjectId: UUID?

    // MARK: Minimum window size (upstream 3a17bc04d, #2728)

    /// The chat layout's design floor. Screens that can show it use it
    /// verbatim; smaller ones clamp it so the composer never hangs off the
    /// bottom (e.g. a scaled 1024x640 display).
    static let designMinimumContentSize = CGSize(width: 800, height: 575)
    @Published private(set) var minimumContentSize: CGSize = ChatWindowState.designMinimumContentSize

    /// Clamp the design floor to `available` (the root view's largest area
    /// on this window's screen). A non-positive axis means "no screen known"
    /// and keeps the design value.
    func updateMinimumContentSize(availableContentSize available: CGSize) {
        let design = Self.designMinimumContentSize
        var next = design
        if available.width > 0 { next.width = min(design.width, floor(available.width)) }
        if available.height > 0 { next.height = min(design.height, floor(available.height)) }
        guard next != minimumContentSize else { return }
        minimumContentSize = next
    }

    /// Holds the `.globalThemeChanged` notification observer so it can be
    /// torn down in `cleanup()`. M11 Phase 11.A.1.x bug fix: prior to this,
    /// the Intel `ChatWindowState` stub set `theme` once in init and never
    /// observed the upstream `globalThemeChanged` notification (posted by
    /// `ThemeManager.applyCustomTheme` / `setAppearanceMode` /
    /// `clearCustomTheme`). Picking a theme in the Settings → Themes tab
    /// (un-body-swapped in 11.A.1) updated the management window but left
    /// chat windows pinned to whatever theme was active at window-creation
    /// time. Mirrors the upstream observer registered in
    /// `ChatWindowState.observeAppConfigurationChanges()` (excluded on Intel).
    private var themeObserver: NSObjectProtocol?

    /// M12 Gap 1 (agent picker): keeps `agents` mirrored to
    /// `AgentManager.shared.$agents` so the toolbar's `AgentPill` dropdown
    /// always reflects creates/deletes/renames made in Settings → Agents.
    /// Mirrors the upstream `agentsCancellable` (the AS `ChatWindowState`
    /// subscribes the same way; that path is excluded on Intel).
    private var agentsCancellable: AnyCancellable?

    /// M13 Schedules follow-up (Renée 2026-06-04): keeps the sidebar's session
    /// list reactive to `ChatSessionsManager.shared.$sessions`. Mirrors the
    /// upstream `sessionsCancellable` (the AS path subscribes the same way;
    /// it was missing on Intel). Without it, sessions saved outside this
    /// window — a headless scheduled run, a stream landing in a sibling
    /// window — only appeared after a manual refresh (switching agents).
    private var sessionsCancellable: AnyCancellable?

    var activeAgent: Agent { cachedActiveAgent }
    /// The active custom agent may select a theme that is independent of
    /// Settings → Themes. Keep the identifier visible to chat presentation so
    /// switching agents cannot leak the previous agent's appearance.
    var themeId: UUID? { AgentManager.shared.themeId(for: agentId) }

    init(windowId: UUID, agentId: UUID, sessionData: ChatSessionData? = nil) {
        self.windowId = windowId
        self.agentId = agentId
        let initial = ChatSession()
        self.session = initial
        self.theme = Self.loadTheme(for: agentId)
        self.filteredSessions = ChatSessionsManager.shared.sessions(for: agentId)
        let tab = ChatTab(id: UUID(), session: initial)
        self.tabs = [tab]
        self.activeTabId = tab.id
        initial.agentId = agentId
        link(initial)
        if let sessionData {
            initial.load(
                from: Self.resolvedSessionData(
                    sessionData, stored: ChatSessionsManager.shared.session(for: sessionData.id)))
        }
        observeThemeChanges()
        observeAgents()
        observeSessionsManager()
    }

    init(windowId: UUID, executionContext: Any? = nil) {
        self.windowId = windowId
        self.agentId = AgentManager.shared.activeAgentId
        let initial = ChatSession()
        self.session = initial
        self.theme = ThemeManager.shared.currentTheme
        self.filteredSessions = ChatSessionsManager.shared.sessions(for: agentId)
        let tab = ChatTab(id: UUID(), session: initial)
        self.tabs = [tab]
        self.activeTabId = tab.id
        initial.agentId = agentId
        link(initial)
        observeThemeChanges()
        observeAgents()
        observeSessionsManager()
    }

    /// Point a session at this window: busy alerts and sidebar refreshes
    /// reach the window that shows it.
    private func link(_ target: ChatSession) {
        target.windowState = self
        target.onSessionChanged = { [weak self] in
            self?.refreshSessions()
        }
    }

    /// Stay subscribed to the sessions store so the sidebar refreshes when a
    /// session is saved/deleted/renamed anywhere — including headless
    /// scheduled runs. Mirrors the upstream observer (ChatWindowState.swift
    /// AS branch); `dropFirst` skips the seed value we already read in `init`.
    private func observeSessionsManager() {
        sessionsCancellable = ChatSessionsManager.shared.$sessions
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshSessions() }
    }

    /// Seed `agents` from `AgentManager` and stay subscribed to its
    /// `@Published` list. Also refreshes the per-agent caches the chat
    /// header reads (`cachedActiveAgent`, `cachedAgentDisplayName`,
    /// `cachedSystemPrompt`).
    private func observeAgents() {
        refreshAgents()
        agentsCancellable = AgentManager.shared.$agents
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAgents() }
    }

    /// Mirror the live agent list + recompute the active-agent caches.
    private func refreshAgents() {
        agents = AgentManager.shared.agents
        cachedActiveAgent = agents.first { $0.id == agentId } ?? .default
        cachedAgentDisplayName =
            cachedActiveAgent.name.isEmpty ? "Assistant" : cachedActiveAgent.name
        cachedSystemPrompt = AgentManager.shared.effectiveSystemPrompt(for: agentId)
        // Agent edits publish through this stream. Re-resolve here so a theme
        // chosen in Agent Settings reaches an already-open chat immediately.
        refreshTheme()
    }

    /// Repoint the window's per-agent chrome (pill, theme, prompt caches,
    /// sidebar filter) at `newAgentId`. Callers decide what happens to the
    /// session; this only follows it.
    private func adoptAgent(_ newAgentId: UUID) {
        guard newAgentId != agentId else { return }
        agentId = newAgentId
        AgentManager.shared.setActiveAgent(newAgentId)
        refreshAgents()
    }

    /// An untouched chat: nothing sent, nothing running, nothing pending.
    private func isBlank(_ s: ChatSession) -> Bool {
        s.turns.isEmpty && !s.isStreaming && s.awaitingClarify == nil
    }

    // MARK: Agent switching

    /// Pick another agent: show that agent's tabs. When the agent already
    /// has tabs in this window, the one that needs input (else the most
    /// recently used) is focused and a blank tab left behind in the outgoing
    /// agent's scope is dropped. Otherwise a blank active tab is repurposed,
    /// else the conversation stays put in its tab and the new agent opens in
    /// a fresh tab. Upstream `switchAgent(to:)`.
    func switchAgent(to newAgentId: UUID) {
        // Picking an agent means "show me this agent's chats": dismiss the
        // project page even when the agent is already active, otherwise the
        // early return leaves the page covering the chat (upstream ee9adf6ae).
        openProjectId = nil
        enteredChatFromProjectPage = false
        let scope = ChatTabScope.local(newAgentId)
        guard scope != activeScope else { return }
        TTSService.shared.stop()
        if focusExistingTab(in: scope) { return }
        if isBlank(session) {
            adoptAgent(newAgentId)
            session.reset(for: newAgentId)
            refreshSessions()
            return
        }
        newTab(agentId: newAgentId)
    }

    /// Start a fresh chat with `newAgentId` from its navigator row (hover
    /// "+"), a project's default agent, or a launch for a specific agent.
    /// Unlike `switchAgent`, this never lands on one of the agent's existing
    /// tabs: on the active agent it acts like New Chat, otherwise a new tab
    /// opens. Upstream `startNewChat(with:)`.
    func startNewChat(with newAgentId: UUID) {
        openProjectId = nil
        enteredChatFromProjectPage = false
        if ChatTabScope.local(newAgentId) == activeScope {
            startNewChat()
            return
        }
        TTSService.shared.stop()
        newTab(agentId: newAgentId)
    }

    /// Show an agent's existing tabs: focus the one waiting for input, else
    /// the most recently activated one. A blank tab left behind in the
    /// outgoing scope is dropped so switching back and forth never litters
    /// the strip with empty chats. Returns false when the scope has no tabs.
    private func focusExistingTab(in scope: ChatTabScope) -> Bool {
        let candidates = tabs.filter { $0.id != activeTabId && ChatTabScope.of($0.session) == scope }
        guard !candidates.isEmpty else { return false }
        let target =
            candidates.first { !$0.isHibernated && $0.session.awaitingClarify != nil }
            ?? candidates.max { $0.lastActivatedAt < $1.lastActivatedAt }
        guard let target else { return false }
        let outgoing = tabs.first { $0.id == activeTabId }
        selectTab(id: target.id)
        if let outgoing, !outgoing.isHibernated, isBlank(outgoing.session),
            ChatTabScope.of(outgoing.session) != scope
        {
            // The blank tab goes away, but whatever the user had typed in
            // it comes back the next time this agent gets a New Chat.
            outgoing.session.stashDraft()
            dropTab(outgoing)
        }
        return true
    }

    /// Remove an INACTIVE tab from the strip and dispose of its session.
    private func dropTab(_ tab: ChatTab) {
        guard tab.id != activeTabId, tabs.contains(where: { $0.id == tab.id }) else { return }
        tabs.removeAll { $0.id == tab.id }
        teardownTabSession(tab.session)
    }

    // MARK: New chats

    /// Start a new chat. Browser-style: a blank active tab is reused in
    /// place; otherwise the current conversation keeps its tab (a running
    /// reply keeps streaming there) and the new chat opens in a new tab.
    /// Callers that stamp project membership afterwards act on `session`,
    /// which is then the new tab's session.
    func startNewChat() {
        guard isBlank(session) else {
            newTab()
            return
        }
        TTSService.shared.stop()
        session.reset(for: agentId)
        refreshSessions()
    }

    /// Keep ⌘N in the open project, or in the current session's project.
    func startNewChatInCurrentProject() {
        let projectID = openProjectId ?? session.projectId
        guard let project = ProjectManager.shared.project(for: projectID) else {
            openProjectId = nil
            enteredChatFromProjectPage = false
            startNewChat()
            return
        }
        startNewChat(in: project)
    }

    func startNewChat(in project: Project) {
        openProjectId = nil
        enteredChatFromProjectPage = true
        if let defaultAgentID = project.defaultAgentId,
            defaultAgentID != agentId,
            agents.contains(where: { $0.id == defaultAgentID })
        {
            // A project's new chat is always a fresh one, even when the
            // project's agent already has tabs here.
            startNewChat(with: defaultAgentID)
        } else {
            startNewChat()
        }
        stampProject(project)
    }

    /// ⌘N / ⌘T: ALWAYS open a new tab, staying in the current project
    /// context (the open project page, else the current chat's project).
    /// Upstream `newTabInCurrentProject()`.
    func newTabInCurrentProject() {
        let project = ProjectManager.shared.project(for: openProjectId ?? session.projectId)
        openProjectId = nil
        enteredChatFromProjectPage = project != nil
        newTab()
        guard let project else { return }
        stampProject(project)
    }

    /// Mark the (fresh) active session as a member of `project`.
    private func stampProject(_ project: Project) {
        session.projectId = project.id
        adoptProjectFolder(project)
    }

    /// Open the project's folder in the active (fresh) session. The
    /// project's folder wins over the agent's default folder (#25). Only a
    /// project that has a folder overrides: the agent default restores
    /// asynchronously, so an empty project must not cancel it.
    func adoptProjectFolder(_ project: Project) {
        guard project.folderPath != nil || project.folderBookmark != nil else { return }
        session.folderState.restore(
            bookmark: project.folderBookmark,
            path: project.folderPath
        )
    }

    var isProjectPageVisible: Bool { openProjectId != nil }

    // MARK: Opening saved chats

    func loadSession(_ sessionData: ChatSessionData) {
        guard sessionData.id != session.sessionId else { return }
        // One mutable owner per saved chat (upstream 979d53b40): if another
        // window already shows it, bring that window forward instead of
        // loading a competing copy here. Checked before touching this
        // window's session so neither transcript is mutated.
        if ChatWindowManager.shared.revealOpenSession(
            sessionData.id, excludingWindowId: windowId
        ) != nil { return }
        // Browser-style dedupe: another tab already showing this chat is
        // focused instead of loading a second copy into this tab.
        if let existing = tabs.first(where: {
            $0.id != activeTabId && $0.session.sessionId == sessionData.id
        }) {
            selectTab(id: existing.id)
            return
        }
        TTSService.shared.stop()
        if !session.turns.isEmpty { session.save() }
        // A run in flight (or paused on a clarify question) keeps its own
        // tab; the target opens in a fresh tab instead of stopping it.
        if Self.hasWorkInFlight(session) {
            newTab(agentId: sessionData.agentId)
        }
        // Loading an existing conversation must adopt its agent before the
        // session publishes restored state. Otherwise the header keeps the
        // launch-time "Default" agent until the user changes agents manually.
        adoptAgent(sessionData.agentId)
        // Reopening a chat that is still running (a closed tab's reply, or
        // a schedule/watcher run): attach that live instance (the stream
        // keeps rendering) instead of a stale copy from disk that would race
        // its saves.
        if let live = DetachedChatRunRegistry.shared.liveSession(forSessionId: sessionData.id)
            ?? BackgroundTaskManager.shared.liveTask(forSessionId: sessionData.id)?.chatSession
        {
            attachDetached(live)
            return
        }
        // Some UI surfaces may hand us a metadata-only row. Resolve the full
        // Intel session from its durable manager before loading so a later
        // incremental save cannot replace a stored transcript with an empty
        // snapshot (upstream 9af6f53d).
        let resolved = Self.resolvedSessionData(
            sessionData,
            stored: ChatSessionsManager.shared.session(for: sessionData.id)
        )
        session.load(from: resolved)
        refreshSessions()
    }

    static func resolvedSessionData(
        _ candidate: ChatSessionData, stored: ChatSessionData?
    ) -> ChatSessionData {
        candidate.turns.isEmpty ? (stored ?? candidate) : candidate
    }

    /// Open a saved conversation in a new tab, or focus the tab that
    /// already shows it. An untouched blank tab is reused (Chrome).
    func openSessionInNewTab(_ sessionData: ChatSessionData) {
        openProjectId = nil
        if let existing = tabs.first(where: { $0.session.sessionId == sessionData.id }) {
            selectTab(id: existing.id)
            return
        }
        if ChatWindowManager.shared.revealOpenSession(
            sessionData.id, excludingWindowId: windowId
        ) != nil { return }
        if !isBlank(session) {
            newTab(agentId: sessionData.agentId, restoresDraft: false)
        }
        loadSession(sessionData)
    }

    /// Replace the active tab's (blank) session with a running instance
    /// handed back by `DetachedChatRunRegistry`.
    private func attachDetached(_ live: ChatSession) {
        DetachedChatRunRegistry.shared.take(live)
        let outgoing = session
        outgoing.stashDraft()
        link(live)
        live.promoteComposerDraft()
        session = live
        adoptAgent(live.agentId ?? Agent.defaultId)
        if outgoing !== live { teardownTabSession(outgoing) }
        refreshSessions()
    }

    /// The sidebar is about to delete conversation `id`. An inactive tab
    /// showing it just closes, without a save that would resurrect the row;
    /// the active tab resets in place.
    func prepareForSessionDeletion(id: UUID) {
        if let tab = tabs.first(where: { $0.id != activeTabId && $0.session.sessionId == id }) {
            tabs.removeAll { $0.id == tab.id }
            let doomed = tab.session
            doomed.stop()
            doomed.onSessionChanged = nil
            doomed.windowState = nil
            return
        }
        guard session.sessionId == id else { return }
        session.reset()
        refreshSessions()
    }

    /// Mirror a sidebar metadata change (rename, pin, archive) onto every
    /// live tab session of that chat so its next auto-save keeps it.
    func syncTabSessions(withId id: UUID, _ update: (ChatSession) -> Void) {
        for tab in tabs where tab.session.sessionId == id {
            update(tab.session)
        }
    }

    /// Same, for every tab whose chat belongs to project `projectId`.
    func syncTabSessions(withProjectId projectId: UUID, _ update: (ChatSession) -> Void) {
        for tab in tabs where tab.session.projectId == projectId {
            update(tab.session)
        }
    }

    // MARK: Tabs API

    /// Open a new tab with a fresh empty chat and make it active. The
    /// outgoing tab keeps its session untouched.
    func newTab(agentId newAgentId: UUID? = nil, restoresDraft: Bool = true) {
        // Browser-style: every ⌘T / ⌘N / + press opens another tab, even
        // when the active one is still blank. Blank tabs are never
        // persisted, so extras cost nothing across a relaunch.
        persistActiveSessionForTabSwitch()
        if let newAgentId { adoptAgent(newAgentId) }
        let fresh = makeFreshSession(agentId: agentId, restoresDraft: restoresDraft)
        let tab = ChatTab(id: UUID(), session: fresh)
        // One un-animated update for strip + content: letting SwiftUI
        // interpolate the strip growing while ChatView remounts (the `.id`
        // swap) reads as a visual glitch.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            tabs.append(tab)
            activeTabId = tab.id
            session = fresh
        }
        refreshSessions()
        hibernateColdTabsIfNeeded()
    }

    /// Reorder a tab (drag-to-reorder in the strip). `newIndex` is the
    /// target slot within the tab's OWN scope (the strip only shows one
    /// agent's tabs); tabs of other agents keep their relative positions.
    func moveTab(id: UUID, to newIndex: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let scopedIds = tabs(in: ChatTabScope.of(tabs[from].session)).map(\.id)
        guard let fromScoped = scopedIds.firstIndex(of: id) else { return }
        let toScoped = min(max(newIndex, 0), scopedIds.count - 1)
        guard fromScoped != toScoped,
            let to = tabs.firstIndex(where: { $0.id == scopedIds[toScoped] })
        else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: to)
    }

    /// Switch the visible chat to another tab. The outgoing session stays
    /// with its tab, so an in-flight stream keeps running there.
    func selectTab(id: UUID) {
        guard id != activeTabId, let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        persistActiveSessionForTabSwitch()
        tabs[idx].lastActivatedAt = Date()
        if tabs[idx].isHibernated {
            wake(tabAt: idx)
        }
        activeTabId = id
        adoptTabSession(tabs[idx].session)
        hibernateColdTabsIfNeeded()
    }

    /// Cycle to the next (+1) or previous (-1) tab of the active agent,
    /// wrapping around.
    func selectAdjacentTab(offset: Int) {
        let scoped = scopedTabs
        guard scoped.count > 1,
            let idx = scoped.firstIndex(where: { $0.id == activeTabId })
        else { return }
        let next = ((idx + offset) % scoped.count + scoped.count) % scoped.count
        selectTab(id: scoped[next].id)
    }

    /// Close a tab. Closing stays within the tab's agent: the neighbor that
    /// takes over is the next tab of the same agent, and closing an agent's
    /// last tab replaces it with a blank chat for that agent — unless that
    /// tab is already blank, in which case nothing happens and ⌘W falls
    /// through to closing the window.
    func closeTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closing = tabs[idx]
        let scope = ChatTabScope.of(closing.session)
        let scoped = tabs(in: scope)
        let scopedIdx = scoped.firstIndex(where: { $0.id == id }) ?? 0
        let siblings = scoped.filter { $0.id != id }
        // A lone blank tab has nothing to close.
        if id == activeTabId, siblings.isEmpty, !closing.isHibernated, isBlank(closing.session) { return }

        rememberClosedTab(closing, at: scopedIdx)
        if id != activeTabId {
            tabs.remove(at: idx)
            teardownTabSession(closing.session)
            return
        }

        // The removal itself animates (the strip keys a layout animation on
        // the tab ids, so neighbors slide over); the session swap below is
        // wrapped un-animated so ChatView's remount doesn't interpolate.
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true

        if siblings.isEmpty {
            let replacement = ChatTab(id: UUID(), session: makeFreshSession(agentId: agentId))
            withTransaction(transaction) {
                tabs[idx] = replacement
                activeTabId = replacement.id
                adoptTabSession(replacement.session)
            }
        } else {
            tabs.remove(at: idx)
            let neighborId = siblings[min(scopedIdx, siblings.count - 1)].id
            guard let neighborIdx = tabs.firstIndex(where: { $0.id == neighborId }) else { return }
            if tabs[neighborIdx].isHibernated { wake(tabAt: neighborIdx) }
            tabs[neighborIdx].lastActivatedAt = Date()
            let neighbor = tabs[neighborIdx]
            withTransaction(transaction) {
                activeTabId = neighbor.id
                adoptTabSession(neighbor.session)
            }
        }
        teardownTabSession(closing.session)
    }

    /// ⌘W: close the active tab when there is something to close. Returns
    /// false for a lone blank tab, the only case where ⌘W closes the window.
    @discardableResult
    func closeActiveTabIfPossible() -> Bool {
        guard let active = tabs.first(where: { $0.id == activeTabId }) else { return false }
        let hasSiblings = scopedTabs.count > 1
        guard hasSiblings || active.isHibernated || !isBlank(active.session) else { return false }
        closeTab(id: activeTabId)
        return true
    }

    // MARK: Background runs as tabs (upstream #2630)

    /// Surface a registry-owned run (schedule, watcher, API dispatch) as a
    /// tab of its agent WITHOUT taking focus: the live `ChatSession` is
    /// linked to this window and appended as an inactive tab, so the run
    /// shows up under its agent while the user keeps working. Execution
    /// stays with the registry. Returns whether a tab was added.
    @discardableResult
    func attachBackgroundTab(for task: BackgroundTaskState) -> Bool {
        guard let live = task.chatSession else { return false }
        let alreadyShown = tabs.contains {
            $0.session === live || ($0.session.sessionId != nil && $0.session.sessionId == live.sessionId)
        }
        guard !alreadyShown else { return false }
        link(live)
        tabs.append(ChatTab(id: UUID(), session: live))
        refreshSessions()
        return true
    }

    /// Bring the tab showing `sessionId` to the front (waking it if
    /// hibernated). Returns false when no tab here shows it.
    @discardableResult
    func focusTab(forSessionId sessionId: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.session.sessionId == sessionId }) else { return false }
        selectTab(id: tab.id)
        return true
    }

    /// Tear down every tab except the active one (window close).
    func teardownInactiveTabSessions() {
        let inactive = tabs.filter { $0.id != activeTabId }
        tabs.removeAll { $0.id != activeTabId }
        for tab in inactive {
            teardownTabSession(tab.session)
        }
    }

    /// Make an incoming tab's session the visible one, syncing the window's
    /// per-agent chrome the same way `loadSession` does for in-tab switches.
    private func adoptTabSession(_ target: ChatSession) {
        adoptAgent(target.agentId ?? Agent.defaultId)
        // The composer remounts for the incoming tab and rehydrates from
        // `input`; surface the tab's unsent keystrokes there first (#2708).
        target.promoteComposerDraft()
        session = target
        refreshSessions()
    }

    /// Save the active session before another tab takes over the surface.
    /// Deliberately does NOT stop it: the outgoing tab still owns it.
    private func persistActiveSessionForTabSwitch() {
        TTSService.shared.stop()
        if !session.turns.isEmpty { session.save() }
    }

    static func hasWorkInFlight(_ s: ChatSession) -> Bool {
        DetachedChatRunRegistry.hasWorkInFlight(s)
    }

    /// Dispose of a session whose tab (or window) closed. A running or
    /// clarify-paused one is handed to `DetachedChatRunRegistry` and keeps
    /// going; an idle one is saved and stopped.
    private func teardownTabSession(_ closingSession: ChatSession) {
        closingSession.onSessionChanged = nil
        closingSession.windowState = nil
        // A registry-owned run (schedule, watcher, dispatch) shown in this
        // tab: execution belongs to the registry, so closing the tab only
        // unlinks the view. Closing the tab of a FINISHED run is how the
        // user dismisses it: the task leaves the registry. Upstream.
        if let task = BackgroundTaskManager.shared.task(owning: closingSession) {
            if !task.status.isActive {
                if !closingSession.turns.isEmpty { closingSession.save() }
                BackgroundTaskManager.shared.finalizeTask(task.id)
            }
            return
        }
        if DetachedChatRunRegistry.shared.adopt(closingSession) { return }
        if !closingSession.turns.isEmpty { closingSession.save() }
        closingSession.stop()
    }

    // MARK: Recently closed tabs (⇧⌘T)

    private struct ClosedTab {
        let sessionId: UUID
        /// Slot within the chat's agent scope at the time it closed.
        let index: Int
    }

    /// Most recent last. Only saved conversations are remembered: a blank
    /// tab has nothing to reopen.
    private var recentlyClosedTabs: [ClosedTab] = []
    private static let recentlyClosedLimit = 10

    private func rememberClosedTab(_ tab: ChatTab, at index: Int) {
        guard let sessionId = tab.session.sessionId,
            tab.isHibernated || !tab.session.turns.isEmpty
        else { return }
        recentlyClosedTabs.removeAll { $0.sessionId == sessionId }
        recentlyClosedTabs.append(ClosedTab(sessionId: sessionId, index: index))
        if recentlyClosedTabs.count > Self.recentlyClosedLimit {
            recentlyClosedTabs.removeFirst(recentlyClosedTabs.count - Self.recentlyClosedLimit)
        }
    }

    /// Whether ⇧⌘T has anything to bring back.
    var canReopenClosedTab: Bool { !recentlyClosedTabs.isEmpty }

    /// Reopen the most recently closed tab at its old position (browser
    /// ⇧⌘T). Conversations deleted since are skipped; one already open is
    /// focused.
    func reopenLastClosedTab() {
        while let closed = recentlyClosedTabs.popLast() {
            let sessionId = closed.sessionId
            if let open = tabs.first(where: { $0.session.sessionId == sessionId }) {
                selectTab(id: open.id)
                return
            }
            if ChatWindowManager.shared.revealOpenSession(
                sessionId, excludingWindowId: windowId
            ) != nil { return }
            let live = DetachedChatRunRegistry.shared.liveSession(forSessionId: sessionId)
            guard let data = live.map({ $0.toSessionData() })
                ?? ChatSessionsManager.shared.session(for: sessionId)
            else { continue }
            // Always its own tab (a blank active tab is left alone), like a
            // browser restoring a closed tab.
            newTab(agentId: data.agentId, restoresDraft: false)
            loadSession(data)
            moveTab(id: activeTabId, to: closed.index)
            return
        }
    }

    // MARK: Remembered tabs (relaunch / window reopen)

    /// The saved conversations this window has open, for
    /// `ChatTabLayoutStore`. Blank tabs are skipped (nothing to reopen).
    func tabLayoutSnapshot() -> ChatTabLayoutRecord {
        let entries = tabs.compactMap { tab -> ChatTabLayoutRecord.Tab? in
            // Registry-owned runs are skipped: the registry surfaces them
            // itself while they live (upstream).
            guard let sessionId = tab.session.sessionId,
                tab.isHibernated || !tab.session.turns.isEmpty,
                BackgroundTaskManager.shared.task(owning: tab.session) == nil
            else { return nil }
            return ChatTabLayoutRecord.Tab(sessionId: sessionId, lastActivatedAt: tab.lastActivatedAt)
        }
        let activeSessionId = tabs.first { $0.id == activeTabId }?.session.sessionId
        return ChatTabLayoutRecord(
            tabs: entries,
            activeSessionId: entries.contains { $0.sessionId == activeSessionId } ? activeSessionId : nil,
            savedAt: Date()
        )
    }

    /// Bring remembered tabs back as hibernated tabs (metadata only; the
    /// transcript loads when a tab is selected). Conversations deleted
    /// since, or already open here, are skipped. When the record's active
    /// chat came back and this window is still on its initial blank tab,
    /// that tab is selected and the blank dropped, so the window reopens
    /// on the chat the user was reading (unless `selectsActive` is false:
    /// the window was opened for something specific). Returns how many tabs
    /// came back.
    @discardableResult
    func restoreTabs(from record: ChatTabLayoutRecord, selectsActive: Bool = true) -> Int {
        var restored = 0
        for entry in record.tabs
        where !tabs.contains(where: { $0.session.sessionId == entry.sessionId })
            && BackgroundTaskManager.shared.taskState(for: entry.sessionId) == nil
        {
            guard var snapshot = ChatSessionsManager.shared.session(for: entry.sessionId) else { continue }
            snapshot.turns = []
            let cold = makeFreshSession(agentId: snapshot.agentId, loading: snapshot)
            var tab = ChatTab(id: UUID(), session: cold)
            tab.isHibernated = true
            tab.lastActivatedAt = entry.lastActivatedAt
            tabs.append(tab)
            restored += 1
        }
        guard restored > 0 else { return 0 }
        if selectsActive, let activeSessionId = record.activeSessionId,
            let target = tabs.first(where: { $0.session.sessionId == activeSessionId }),
            let initial = tabs.first(where: { $0.id == activeTabId }),
            !initial.isHibernated, isBlank(initial.session), initial.session.unsentComposerText.isEmpty
        {
            selectTab(id: target.id)
            dropTab(initial)
        }
        return restored
    }

    // MARK: Tab hibernation (LRU)

    /// How many tabs keep a fully hydrated session (transcript, rendered
    /// blocks) at once. Beyond this the least recently used idle tabs are
    /// hibernated to a metadata-only session.
    static let warmTabLimit = 5

    /// Hibernate the coldest idle tabs once more than `warmTabLimit` are
    /// hydrated. Streaming, clarify-paused and unsaved (blank) tabs are
    /// never hibernated: their state lives only in memory.
    private func hibernateColdTabsIfNeeded() {
        let warm = tabs.enumerated()
            .filter { $0.element.id != activeTabId && !$0.element.isHibernated }
            .sorted { $0.element.lastActivatedAt < $1.element.lastActivatedAt }
        var excess = warm.count - (Self.warmTabLimit - 1)
        for (idx, tab) in warm where excess > 0 {
            guard canHibernate(tab.session) else { continue }
            hibernate(tabAt: idx)
            excess -= 1
        }
    }

    private func canHibernate(_ s: ChatSession) -> Bool {
        guard let sessionId = s.sessionId, !s.turns.isEmpty, !Self.hasWorkInFlight(s),
            s.queuedSend == nil
        else { return false }
        // A registry run that hasn't started yet has no turns to reload;
        // swapping it for a stand-in would divorce the tab from its run.
        return BackgroundTaskManager.shared.liveTask(forSessionId: sessionId) == nil
    }

    /// Save the tab's session, then swap it for a metadata-only stand-in
    /// (same ids/title/agent/project, no turns).
    private func hibernate(tabAt idx: Int) {
        let live = tabs[idx].session
        live.save()
        var snapshot = live.toSessionData()
        snapshot.turns = []
        let cold = makeFreshSession(agentId: live.agentId ?? Agent.defaultId, loading: snapshot)
        // `ChatSessionData` carries no composer text; carry the unsent
        // draft across so hibernating a tab does not eat it (#2708).
        cold.input = live.unsentComposerText
        // Share (not copy) the saved scroll position (#2911).
        cold.scrollPositionStore = live.scrollPositionStore
        live.stop()
        live.onSessionChanged = nil
        live.windowState = nil
        tabs[idx].session = cold
        tabs[idx].isHibernated = true
    }

    /// Reload a hibernated tab's transcript in place. Intel keeps every
    /// saved chat in `ChatSessionsManager`'s memory, so this is a
    /// synchronous copy, not upstream's async disk read.
    private func wake(tabAt idx: Int) {
        let cold = tabs[idx].session
        defer { tabs[idx].isHibernated = false }
        guard let sid = cold.sessionId,
            let full = ChatSessionsManager.shared.session(for: sid)
        else { return }
        // `load` stashes and restores the composer draft by session id.
        cold.load(from: full)
    }

    /// Keep the active tab's entry pointing at the window's current session
    /// after in-tab navigation replaces the instance.
    private func syncActiveTabSession() {
        guard let idx = tabs.firstIndex(where: { $0.id == activeTabId }) else { return }
        if tabs[idx].session !== session {
            tabs[idx].session = session
        }
    }

    /// Build a fresh, window-linked `ChatSession` (new tabs, closed-tab
    /// replacements, hibernated stand-ins).
    private func makeFreshSession(
        agentId: UUID,
        loading data: ChatSessionData? = nil,
        restoresDraft: Bool = true
    ) -> ChatSession {
        let fresh = ChatSession()
        fresh.agentId = agentId
        link(fresh)
        fresh.applyInitialModelSelection()
        if let data {
            fresh.load(from: data)
        } else {
            // A fresh chat opens in its agent's default working folder,
            // exactly like New Chat (`ChatSession.reset`).
            fresh.applyAgentDefaultFolder()
            if restoresDraft {
                // A fresh New Chat for this agent picks up the draft left in
                // an earlier New Chat for the same agent.
                fresh.restoreDraft()
            }
        }
        return fresh
    }

    // MARK: Theme

    /// Subscribe to `.globalThemeChanged` so theme picks in Settings
    /// propagate to this chat window in real time. Mirrors the upstream
    /// observer in `ChatWindowState.observeAppConfigurationChanges()`
    /// (excluded on Intel) that drives the same behavior on Apple Silicon.
    private func observeThemeChanges() {
        themeObserver = NotificationCenter.default.addObserver(
            forName: .globalThemeChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshTheme() }
        }
    }

    /// Re-read the effective theme for this agent and republish it. Custom
    /// agent themes intentionally override the global Settings theme only for
    /// that agent's chat window.
    func refreshTheme() {
        let newTheme = Self.loadTheme(for: agentId)
        // `@Published` deduplicates on Equatable-of-self semantics, but
        // `ThemeProtocol` isn't Equatable, so we always republish here.
        // SwiftUI's environment-key diffing inside the view layer handles
        // no-op redraws cleanly.
        theme = newTheme
    }

    private static func loadTheme(for agentId: UUID) -> ThemeProtocol {
        if let themeId = AgentManager.shared.themeId(for: agentId),
           let customTheme = ThemeManager.shared.installedThemes.first(where: {
               $0.metadata.id == themeId
           })
        {
            return CustomizableTheme(config: customTheme)
        }
        return ThemeManager.shared.currentTheme
    }

    func confirmCloseInBackground() { showCloseConfirmation = false }
    func confirmCloseAndStop() { showCloseConfirmation = false }
    func refreshPairedRelayAgents(discoveredAgents: [DiscoveredAgent]? = nil) {}

    /// Window close: every tab's session is saved and stopped, or handed to
    /// `DetachedChatRunRegistry` while it still runs.
    func cleanup() {
        if let observer = themeObserver {
            NotificationCenter.default.removeObserver(observer)
            themeObserver = nil
        }
        agentsCancellable?.cancel()
        agentsCancellable = nil
        sessionsCancellable?.cancel()
        sessionsCancellable = nil
        onTabLayoutChanged = nil
        teardownInactiveTabSessions()
        teardownTabSession(session)
    }

    func refreshSessions() {
        onTabLayoutChanged?()
        filteredSessions = ChatSessionsManager.shared.sessions(for: agentId)
    }
}
#endif
