//
//  FloatingInputCard.swift
//  osaurus
//
//  Premium floating input card with model chip and smooth animations
//

import AVFoundation
import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct FloatingInputCard: View {
    @Binding var text: String
    @Binding var selectedModel: String?
    @Binding var pendingAttachments: [Attachment]
    /// When true, voice input auto-restarts after AI responds (continuous conversation mode)
    @Binding var isContinuousVoiceMode: Bool
    @Binding var voiceInputState: VoiceInputState
    @Binding var showVoiceOverlay: Bool
    let pickerItems: [ModelPickerItem]
    @Binding var activeModelOptions: [String: ModelOptionValue]
    let isStreaming: Bool
    let supportsImages: Bool
    /// Current estimated context token count for the session
    let estimatedContextTokens: Int
    /// Per-category breakdown of context token usage
    var contextBreakdown: ContextBreakdown = .zero
    let onSend: (String?) -> Void
    let onStop: () -> Void
    /// Trigger to focus the input field (increment to focus)
    var focusTrigger: Int = 0
    /// Current agent ID (used for agent-specific settings)
    var agentId: UUID? = nil
    /// Window ID for targeted VAD notifications
    var windowId: UUID? = nil
    /// Compact mode (sidebar open) - hides secondary chip content
    var isCompact: Bool = false
    /// Callback to clear the current chat session (triggered by /clear command).
    var onClearChat: (() -> Void)? = nil
    /// Callback to generate an AI title for the current chat (triggered by /title command).
    var onGenerateTitle: (() -> Void)? = nil
    /// Compact older messages (upstream #136): `/compact`, the token chip's
    /// context menu, and the near-limit notice.
    var onCompact: (() -> Void)? = nil
    /// `/screenshot` (upstream): capture the screen into the chat.
    var onCaptureScreenshot: (() -> Void)? = nil
    var isCompacting: Bool = false
    /// Upstream compaction state for the context card's progress / result
    /// rows (`ChatSession.compactionState`).
    var compactionState: ContextCompactionUIState = .idle
    var suggestCompaction: Bool = false
    /// An older span of the chat can be summarized (upstream
    /// `canCompactConversation`); shows "Compact conversation" in the
    /// context popover.
    var canCompactConversation: Bool = false
    /// Callback when the user selects a skill slash command. Passes the skill UUID so the
    /// caller can inject that skill's instructions as one-off context for the next send.
    var onSkillSelected: ((UUID) -> Void)? = nil
    /// Binding to the session's pending one-off skill. Non-nil shows a dismissable skill chip.
    @Binding var pendingSkillId: UUID?
    /// Binding to the session's auto-speak preference. When true, a chip is shown
    /// so the user can disable it without waiting to be re-prompted.
    @Binding var autoSpeakAssistant: Bool
    /// Single-slot queued send that was authored while a run was streaming.
    /// Non-nil renders a chip + flips the Send button into "Send Now"
    /// (interrupt) mode. Nil → ordinary Send / Queue behavior.
    @Binding var queuedSend: QueuedSend?
    /// Cancel + immediately dispatch the queued send. Only invoked when
    /// `queuedSend != nil` (the SendNow button is otherwise hidden).
    var onSendNow: (() -> Void)?
    /// Discard the queued send without sending it. Called by the chip's ×.
    var onCancelQueued: (() -> Void)?
    @ObservedObject var folderState: ChatFolderState
    @ObservedObject private var recentFolders = RecentFoldersStore.shared
    @AppStorage(ComposerSpellCheckSetting.defaultsKey)
    private var spellCheckEnabled: Bool = ComposerSpellCheckSetting.defaultValue
    /// Fired on every keystroke with the composer's current text, so the
    /// session can keep a draft mirror for stash/restore across chat and
    /// agent switches without re-rendering per key (upstream 65cbb73e0).
    var onDraftChange: ((String) -> Void)? = nil
    /// Called when the card (re)appears so the owner can surface any unsent
    /// draft into `text` before the card rehydrates from it.
    var onWillRehydrate: (() -> Void)? = nil
    /// Terminal-style input history (Up/Down arrows recall previously sent
    /// messages). Returns the current conversation's sent inputs, newest
    /// first; nil disables the feature.
    var inputHistoryProvider: (() -> [String])?
    /// Identity of the conversation backing the history. Navigation state
    /// resets when it changes so a recalled index can't leak across chats.
    var inputHistoryKey: UUID?

    init(
        text: Binding<String>,
        selectedModel: Binding<String?>,
        pendingAttachments: Binding<[Attachment]>,
        isContinuousVoiceMode: Binding<Bool>,
        voiceInputState: Binding<VoiceInputState>,
        showVoiceOverlay: Binding<Bool>,
        pickerItems: [ModelPickerItem],
        activeModelOptions: Binding<[String: ModelOptionValue]>,
        isStreaming: Bool,
        supportsImages: Bool,
        estimatedContextTokens: Int,
        contextBreakdown: ContextBreakdown = .zero,
        onSend: @escaping (String?) -> Void,
        onStop: @escaping () -> Void,
        focusTrigger: Int = 0,
        agentId: UUID? = nil,
        windowId: UUID? = nil,
        isCompact: Bool = false,
        onClearChat: (() -> Void)? = nil,
        onGenerateTitle: (() -> Void)? = nil,
        onCompact: (() -> Void)? = nil,
        onCaptureScreenshot: (() -> Void)? = nil,
        isCompacting: Bool = false,
        compactionState: ContextCompactionUIState = .idle,
        suggestCompaction: Bool = false,
        canCompactConversation: Bool = false,
        onSkillSelected: ((UUID) -> Void)? = nil,
        pendingSkillId: Binding<UUID?> = .constant(nil),
        autoSpeakAssistant: Binding<Bool> = .constant(false),
        queuedSend: Binding<QueuedSend?> = .constant(nil),
        onSendNow: (() -> Void)? = nil,
        onCancelQueued: (() -> Void)? = nil,
        folderState: ChatFolderState? = nil,
        onDraftChange: ((String) -> Void)? = nil,
        onWillRehydrate: (() -> Void)? = nil,
        inputHistoryProvider: (() -> [String])? = nil,
        inputHistoryKey: UUID? = nil
    ) {
        self.inputHistoryProvider = inputHistoryProvider
        self.inputHistoryKey = inputHistoryKey
        self.onDraftChange = onDraftChange
        self.onWillRehydrate = onWillRehydrate
        self._text = text
        self._selectedModel = selectedModel
        self._pendingAttachments = pendingAttachments
        self._isContinuousVoiceMode = isContinuousVoiceMode
        self._voiceInputState = voiceInputState
        self._showVoiceOverlay = showVoiceOverlay
        self.pickerItems = pickerItems
        self._activeModelOptions = activeModelOptions
        self.isStreaming = isStreaming
        self.supportsImages = supportsImages
        self.estimatedContextTokens = estimatedContextTokens
        self.contextBreakdown = contextBreakdown
        self.onSend = onSend
        self.onStop = onStop
        self.focusTrigger = focusTrigger
        self.agentId = agentId
        self.windowId = windowId
        self.isCompact = isCompact
        self.onClearChat = onClearChat
        self.onGenerateTitle = onGenerateTitle
        self.onCompact = onCompact
        self.onCaptureScreenshot = onCaptureScreenshot
        self.isCompacting = isCompacting
        self.compactionState = compactionState
        self.suggestCompaction = suggestCompaction
        self.canCompactConversation = canCompactConversation
        self.onSkillSelected = onSkillSelected
        self._pendingSkillId = pendingSkillId
        self._autoSpeakAssistant = autoSpeakAssistant
        self._queuedSend = queuedSend
        self.onSendNow = onSendNow
        self.onCancelQueued = onCancelQueued
        self._folderState = ObservedObject(wrappedValue: folderState ?? ChatFolderState())
    }

    // Observe managers for reactive updates
    @ObservedObject private var agentManager = AgentManager.shared
    @ObservedObject private var sandboxState = SandboxManager.State.shared
    @ObservedObject private var clipboardService = ClipboardService.shared
    @ObservedObject private var appConfig = AppConfiguration.shared

    // MARK: - Slash Command State

    private var slashRegistry = SlashCommandRegistry.shared
    @State private var slashSelectedIndex: Int = 0
    /// Slash query the user dismissed with Escape. Suppresses the popup for
    /// that exact query so the typed text survives; cleared as soon as the
    /// query changes (typing resumes) so the popup can reappear.
    @State private var dismissedSlashQuery: String?
    @State private var inputHistoryState = ChatInputHistoryState()

    // MARK: - "@" File Menu State

    /// Highlighted row in the "@" file completion popup.
    @State private var atSelectedIndex: Int = 0
    /// Filesystem entries for the current "@" query. Populated off the main
    /// actor by `atMenuTask` so directory enumeration never blocks the UI.
    @State private var atMenuItems: [AtFileItem] = []
    /// Outcome of the latest listing; `.denied` drives the recovery affordance.
    @State private var atMenuStatus: AtFileMenuStatus = .ok
    /// Resolved directory for the latest listing; used to label + re-grant a
    /// denied folder.
    @State private var atMenuDirectory: String = ""
    /// True while a listing is in flight for a brand-new query (no prior items
    /// to keep showing). Suppresses an empty-state flash before results arrive.
    @State private var atMenuLoading: Bool = false
    /// In-flight listing task; cancelled and replaced on every query change.
    @State private var atMenuTask: Task<Void, Never>?


    /// Non-nil when the cursor is inside a slash command token (e.g. "/tr" or "hello /tr").
    /// The slash must be at the start of text or immediately after whitespace.
    /// Nil once a space or newline follows the slash (command completed or dismissed).
    private var activeSlashQuery: String? {
        // Find the last '/' in the text
        guard let slashRange = localText.range(of: "/", options: .backwards) else { return nil }

        // The slash must be at position 0 or preceded by whitespace
        let before = localText[..<slashRange.lowerBound]
        if !before.isEmpty {
            guard let lastChar = before.last, lastChar.isWhitespace else { return nil }
        }

        // Everything after the slash must have no spaces/newlines (still typing the token)
        let afterSlash = String(localText[slashRange.upperBound...])
        guard !afterSlash.contains(" ") && !afterSlash.contains("\n") else { return nil }

        return afterSlash
    }

    private var slashFilteredCommands: [SlashCommand] {
        guard let query = activeSlashQuery else { return [] }
        return slashRegistry.filtered(query: query)
    }

    private var showSlashPopup: Bool {
        guard let query = activeSlashQuery else { return false }
        return query != dismissedSlashQuery && !slashFilteredCommands.isEmpty
    }

    /// Non-nil when the cursor is inside an "@" file token (e.g. "@src/ma" or
    /// "look at @src/ma"). The "@" must start the text or follow whitespace.
    /// Unlike the slash token, the query may contain "/" (a path); it ends only
    /// at a space or newline. Returns nil once the token is completed/dismissed.
    private var activeAtQuery: String? {
        guard let atRange = localText.range(of: "@", options: .backwards) else { return nil }

        // The "@" must be at the start of the text or preceded by whitespace,
        // so email-style "name@host" tokens don't trigger the menu.
        let before = localText[..<atRange.lowerBound]
        if let lastChar = before.last, !lastChar.isWhitespace { return nil }

        // Everything after "@" is the path query; a space or newline ends it.
        let afterAt = String(localText[atRange.upperBound...])
        guard !afterAt.contains(" ") && !afterAt.contains("\n") else { return nil }

        return afterAt
    }

    /// Show the "@" menu when a query is active and there's something useful to
    /// display: entries, a denied-folder recovery row, or an empty-folder
    /// notice. Hidden for a not-found path (still being typed) and while the
    /// first results for a new query are loading (avoids an empty flash).
    /// Never shown at the same time as the slash popup.
    private var showAtPopup: Bool {
        guard activeAtQuery != nil, !showSlashPopup else { return false }
        if !atMenuItems.isEmpty { return true }
        switch atMenuStatus {
        case .denied: return true
        case .notFound: return false
        case .ok: return !atMenuLoading  // empty folder / no matches, once loaded
        }
    }

    /// Whether the current "@" query is narrowing by a partial name (vs. listing
    /// a whole directory), used to pick the right empty-state wording.
    private var atMenuIsFiltering: Bool {
        guard let query = activeAtQuery else { return false }
        return !query.isEmpty && !query.hasSuffix("/")
    }


    // Local state for text input to prevent parent re-renders on every keystroke
    @State private var localText: String = ""
    @State private var isFocused: Bool = false
    @State private var isComposing: Bool = false
    /// Keeps focus in the input through the send/queue state cascade.
    /// `syncAndSend` and `sendNowButton` arm `lockFocus(for:)` before
    /// the mutations that would otherwise let AppKit blur the field.
    @StateObject private var textViewFocusController = TextViewFocusController()
    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme
    @State private var isDragOver = false
    @State private var showModelPicker = false
    /// Column picker card size (upstream #2947), reported by the card.
    @State private var modelPickerCardSize: CGSize = .zero
    @State private var showCloudModelBrowser = false
    @ObservedObject private var chatModelFavorites = FavoriteModelsStore.shared
    @State private var isSandboxHovered = false
    @State private var sandboxPulseAmount: CGFloat = 1.0
    @State private var sandboxPulseTask: Task<Void, Never>? = nil
    @State private var isClipboardHovered = false
    @State private var clipboardPulseAmount: CGFloat = 0.0
    @State private var clipboardPulseOpacity: Double = 0.0
    // Cache picker items to prevent popover refresh during streaming
    @State private var cachedPickerItems: [ModelPickerItem] = []
    // MARK: - Voice Input State
    @ObservedObject private var speechService = SpeechService.shared
    @ObservedObject private var speechModelManager = SpeechModelManager.shared
    @State private var voiceConfig = SpeechConfiguration.default

    // Pause detection state
    @State private var lastSpeechTime: Date = .distantFuture
    @State private var hasDetectedSpeechThisTurn: Bool = false
    @State private var wasStreaming = false

    @State private var showMicPermissionAlert: Bool = false

    /// Tracks last voice activity time for silence timeout
    @State private var lastVoiceActivityTime: Date = Date()

    /// Displayed silence timeout duration (updated by timer for smooth UI updates)
    @State private var displayedSilenceTimeoutDuration: Double = 0

    /// Tracks confirmed transcription length to detect actual changes (for silence timeout)
    @State private var lastConfirmedLength: Int = 0

    @State private var pauseTimerCancellable: AnyCancellable? = nil
    @State private var liveVoiceAttachmentId: UUID?
    /// Active pasted-content attachment whose preview sheet is showing.
    /// Set on chip tap; cleared on dismiss.
    @State private var pastedContentPreview: Attachment?
    @State private var pastedContentEdit: Attachment?
    /// Character threshold above which clipboard text is converted to a
    /// pasted-content attachment instead of being inlined into the input.
    // Compared against `.utf8.count`, not `.count`: grapheme-cluster
    // counting a large clipboard payload (e.g. a multi-MB paste) can block
    // the main thread for seconds (Sentry: "App Hanging" in this closure /
    // `CustomNSTextView.paste`), while `.utf8.count` is effectively free —
    // Swift's native String storage is already UTF8. This is only a
    // rough "is this a big paste" gate, so counting bytes instead of
    // characters doesn't change the decision in practice.
    private static let pastedContentThreshold: Int = 400
    @State private var liveVoicePreencodeTask: Task<Void, Never>?
    @State private var lastLiveVoicePreencodeAt: Date = .distantPast
    @State private var lastLiveVoicePreencodeSampleCount: Int = 0

    // TextEditor should grow up to ~6 lines before scrolling
    private var inputFontSize: CGFloat { CGFloat(theme.bodySize) }
    private let maxVisibleLines: CGFloat = 6
    private var maxHeight: CGFloat {
        // Approximate line height from font metrics (ascender/descender/leading)
        let lineHeight = Self.lineHeight(forFontSize: inputFontSize)
        // Small extra padding so the last line isn't cramped
        return lineHeight * maxVisibleLines + 8
    }

    // `NSFont.systemFont(ofSize:)` plus the ascender/descender/leading reads run
    // on the main thread inside `body`/`sizeThatFits` on every layout pass, and
    // the underlying font-descriptor/dynamic-type lookups have shown up as app
    // hangs during layout. Line height is a pure function of the point size, so
    // memoize it and serve the memo thereafter.
    private static let lineHeightCacheLock = NSLock()
    private nonisolated(unsafe) static var lineHeightCache: [CGFloat: CGFloat] = [:]
    private static func lineHeight(forFontSize size: CGFloat) -> CGFloat {
        lineHeightCacheLock.lock()
        defer { lineHeightCacheLock.unlock() }
        if let cached = lineHeightCache[size] { return cached }
        let font = NSFont.systemFont(ofSize: size)
        let lineHeight = font.ascender - font.descender + font.leading
        lineHeightCache[size] = lineHeight
        return lineHeight
    }
    private let maxImageSize: Int = 10 * 1024 * 1024  // 10MB limit

    private var canSend: Bool {
        // While the slash command popup is visible, Enter selects a command — not sends
        guard !showSlashPopup else { return false }

        let hasText = !localText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasContent = hasText || !pendingAttachments.isEmpty
        // During streaming, "send" enqueues the payload (handled by the
        // parent). The bar swaps Send for SendQueue/SendNow visually but
        // the keyboard path still goes through onSend → enqueueSend.
        return hasContent
    }

    private var showPlaceholder: Bool {
        localText.isEmpty && pendingAttachments.isEmpty && !isComposing
    }

    /// Breakdown augmented with real-time typing tokens
    private var displayContextBreakdown: ContextBreakdown {
        var bd = contextBreakdown
        if !localText.isEmpty {
            let typingTokens = TokenEstimator.estimate(localText)
            bd.setTokens(
                for: "input",
                in: \.messages,
                tokens: (bd.messages.first { $0.id == "input" }?.tokens ?? 0) + typingTokens,
                label: "Input",
                tint: .cyan
            )
        }
        return bd
    }

    // MARK: - Context budget (upstream ring + popover, Intel math)

    /// One pass over the context-budget chain (upstream
    /// `ContextBudgetSnapshot`): resolve the window and assess the
    /// typing-augmented breakdown once per render. Bind it to a local and
    /// read fields off it; re-reading `contextBudget` repeats the work.
    private struct ContextBudgetSnapshot {
        var resolution: IntelContextBudget.WindowResolution?
        /// Breakdown including what is currently being typed.
        var breakdown: ContextBreakdown
        var assessment: IntelContextBudget.Assessment

        /// The window in force (model catalog, else the Context Length
        /// setting).
        var maxTokens: Int? { resolution?.tokens }
        /// Context tokens including what is currently being typed.
        var displayTokens: Int { breakdown.total }
        /// The usable budget (window × 85%), the chip's denominator.
        var usableTokens: Int? { maxTokens.map(IntelContextBudget.effectiveBudget(contextWindow:)) }
        var usageRatio: Double? { assessment.usageRatio }
        var nearLimit: Bool { assessment.nearLimit }
        var hardOverflow: Bool { assessment.hardOverflow }
    }

    private var contextBudget: ContextBudgetSnapshot {
        let resolution = IntelContextBudget.resolveWindow(modelId: selectedModel)
        let breakdown = displayContextBreakdown
        let assessment =
            resolution.map {
                IntelContextBudget.assess(
                    breakdown: breakdown,
                    contextWindow: $0.tokens,
                    maxResponseTokens: agentManager.effectiveMaxTokens(for: effectiveAgentId)
                )
            } ?? .empty
        return ContextBudgetSnapshot(resolution: resolution, breakdown: breakdown, assessment: assessment)
    }

    private var isVoiceConfigured: Bool {
        voiceConfig.voiceInputEnabled
            && speechModelManager.downloadedModelsCount > 0
    }

    /// Whether voice input is ready to actually start recording (model loaded into memory).
    private var isVoiceAvailable: Bool {
        isVoiceConfigured && speechService.isModelLoaded
    }

    /// Whether voice is in a recording/active state
    private var isVoiceActive: Bool {
        voiceInputState != .idle
    }

    /// Current silence duration for pause detection visualization
    private var currentSilenceDuration: Double {
        guard voiceInputState == .recording else { return 0 }
        return Date().timeIntervalSince(lastSpeechTime)
    }

    private var mainContent: some View {
        VStack(spacing: 12) {
            if (pickerItems.count > 1
                || contextBudget.displayTokens > 0
                || isSandboxAvailable
                || (appConfig.chatConfig.enableClipboardMonitoring && clipboardService.hasNewContent))
                && !showVoiceOverlay
            {
                selectorRow
                    .padding(.top, 8)
                    .padding(.horizontal, 20)
            }

            if showVoiceOverlay {
                VoiceInputOverlay(
                    state: $voiceInputState,
                    audioLevel: speechService.audioLevel,
                    transcription: speechService.currentTranscription,
                    confirmedText: speechService.confirmedTranscription,
                    pauseDuration: voiceConfig.pauseDuration,
                    confirmationDelay: voiceConfig.confirmationDelay,
                    silenceDuration: currentSilenceDuration,
                    silenceTimeoutDuration: voiceConfig.silenceTimeoutSeconds,
                    silenceTimeoutProgress: displayedSilenceTimeoutDuration,
                    isContinuousMode: isContinuousVoiceMode,
                    isStreaming: isStreaming,
                    transcriptionStopMode: voiceConfig.transcriptionStopMode,
                    onCancel: { cancelVoiceInput() },
                    onSend: { message in sendVoiceMessage(message) },
                    onEdit: { transferToTextInput() }
                )
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98)),
                        removal: .opacity.combined(with: .scale(scale: 0.98))
                    )
                )
            } else {
                inputCard
                // Float the slash / "@" menus above the card instead of
                // stacking them in the layout, so opening one never shifts the
                // selector row or the transcript (upstream #3017). The `.top`
                // guide lifts the overlay fully above the card's top edge.
                .overlay(alignment: .top) {
                    composerPopupOverlay
                        .alignmentGuide(.top) { dimensions in dimensions.height + 4 }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
                .onDrop(of: dropAcceptedTypes, isTargeted: $isDragOver) { providers in
                    handleFileDrop(providers)
                }
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98)),
                        removal: .opacity.combined(with: .scale(scale: 0.98))
                    )
                )
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: showVoiceOverlay)
    }

    var body: some View {
        let _ = ChatPerfTrace.shared.count("body.FloatingInputCard")
        mainContent
            .onAppear {
                let isReappear = !localText.isEmpty || voiceInputState != .idle
                onWillRehydrate?()
                localText = text
                print("[VoiceDebug] FloatingInputCard onAppear (reappear=\(isReappear))")

                // Focus immediately when view appears
                isFocused = true

                // Load voice config (cached after first load)
                loadVoiceConfig()

                if voiceConfig.voiceInputEnabled && !speechService.isModelLoaded
                    && !speechService.isLoadingModel
                    && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                {
                    if let model = SpeechModelManager.shared.selectedModel {
                        print("[VoiceDebug] Kicking off model load for: \(model.id)")
                        Task {
                            try? await speechService.loadModel(model.id)
                        }
                    } else {
                        print("[VoiceDebug] No selected model — cannot load")
                    }
                }

                if speechService.isRecording {
                    if voiceInputState == .idle {
                        voiceInputState = .recording
                        lastVoiceActivityTime = Date()
                        resetPauseDetectionForRecording()
                    }
                    if !showVoiceOverlay {
                        showVoiceOverlay = true
                    }
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .startVoiceInputInChat)) { notification in
                // Start voice input when triggered by VAD - enable continuous mode
                // Only respond if this notification targets our window
                guard let targetWindowId = notification.object as? UUID,
                    targetWindowId == windowId
                else {
                    return
                }

                if isVoiceAvailable && !showVoiceOverlay && !isStreaming {
                    print(
                        "[FloatingInputCard] Received .startVoiceInputInChat notification for window \(windowId?.uuidString ?? "nil")"
                    )
                    isContinuousVoiceMode = true
                    lastVoiceActivityTime = Date()
                    startVoiceInput()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .voiceConfigurationChanged)) { _ in
                // Reload voice config when settings change
                loadVoiceConfig()

                if voiceConfig.voiceInputEnabled && !speechService.isModelLoaded
                    && !speechService.isLoadingModel
                    && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
                {
                    if let model = SpeechModelManager.shared.selectedModel {
                        Task { try? await speechService.loadModel(model.id) }
                    }
                }
            }
            .onChange(of: isStreaming) { nowStreaming in
                defer { wasStreaming = nowStreaming }
                // Safety net: if focus was lost during streaming (e.g.
                // the user clicked elsewhere or dismissed a dialog),
                // re-claim it once the agent finishes so the user can
                // type immediately. The normal send path keeps focus
                // throughout via `TextViewFocusController.lockFocus`.
                if wasStreaming && !nowStreaming {
                    isFocused = true
                }

                // When AI finishes responding and we're in continuous voice mode, restart voice input
                if wasStreaming && !nowStreaming && isContinuousVoiceMode {
                    print("[FloatingInputCard] AI response finished in continuous mode - restarting voice")
                    // Reset silence timeout for the new turn
                    lastVoiceActivityTime = Date()

                    // Small delay to let UI settle
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 500_000_000)  // 500ms
                        if isContinuousVoiceMode && isVoiceAvailable && !showVoiceOverlay {
                            startVoiceInput()
                        }
                    }
                }
            }
            .onDisappear {
                // Stop any active voice recording, but check if we should keep continuous mode
                if isVoiceActive {
                    print("[FloatingInputCard] onDisappear: Stopping active voice recording")
                    // Don't use cancelVoiceInput() here as it forces continuous mode off.
                    // Instead, just stop recording but preserve the mode.
                    cancelLiveVoicePreencodeSession(removeRegistryEntry: true)
                    Task {
                        _ = await speechService.stopStreamingTranscription()
                        speechService.clearTranscription()
                    }
                    voiceInputState = .idle
                    showVoiceOverlay = false
                }
            }
            .onChange(of: text) { newValue in
                // Sync from binding when it changes externally (e.g., quick actions)
                if newValue != localText {
                    localText = newValue
                }
            }
            .onChange(of: localText) { newValue in
                onDraftChange?(newValue)
                // Reset popup selection whenever the typed query changes
                slashSelectedIndex = 0
                atSelectedIndex = 0
                // Typing after an Escape-dismissal re-arms the slash popup
                if dismissedSlashQuery != nil, activeSlashQuery != dismissedSlashQuery {
                    dismissedSlashQuery = nil
                }
                // Re-list the "@" menu off the main actor for the new query.
                refreshAtMenu()
            }
            .onChange(of: showSlashPopup) { _ in
                // Keep registry in sync so the global key monitor can suppress
                // Escape from closing the window while either popup is open.
                syncPopupVisibility()
            }
            .onDisappear {
                atMenuTask?.cancel()
                SlashCommandRegistry.shared.isPopupVisible = false
            }
            .onChange(of: focusTrigger) { _ in
                isFocused = true
            }
            .onChange(of: speechService.isRecording) { isRecording in
                print(
                    "[FloatingInputCard] isRecording changed to: \(isRecording). voiceInputState: \(voiceInputState), showVoiceOverlay: \(showVoiceOverlay)"
                )
                // Sync voice state with service
                if isRecording {
                    if voiceInputState == .idle && showVoiceOverlay {
                        voiceInputState = .recording
                        lastVoiceActivityTime = Date()
                        resetPauseDetectionForRecording()
                        print("[FloatingInputCard] Recording confirmed - voice input ready")
                    } else if voiceInputState == .idle, VADService.shared.state != .listening {
                        // Intel: never adopt VAD Mode's wake-word listening as
                        // chat input (chat windows can stay open on Intel).
                        print("[FloatingInputCard] External recording detected. Overlay: \(showVoiceOverlay)")
                        voiceInputState = .recording
                        lastVoiceActivityTime = Date()
                        resetPauseDetectionForRecording()
                    }
                } else {
                    // If service stopped recording (e.g. via Esc key in ChatView), sync local state.
                    // Preserve `.sending` so the overlay stays up during LLM cleanup.
                    if voiceInputState != .idle && voiceInputState != .sending {
                        voiceInputState = .idle
                        showVoiceOverlay = false
                    }
                }
            }
            .onChange(of: speechService.isSpeechDetected) { detected in
                if detected && voiceInputState == .recording {
                    hasDetectedSpeechThisTurn = true
                    lastSpeechTime = Date()
                }
            }
            .onChange(of: speechService.currentTranscription) { newValue in
                // When new transcription arrives, user is speaking
                // Only reset silence timer if there is also active audio detection or meaningful level
                if voiceInputState == .recording && !newValue.isEmpty {
                    if speechService.isSpeechDetected || speechService.audioLevel > 0.05 {
                        hasDetectedSpeechThisTurn = true
                        lastSpeechTime = Date()
                    }
                }
            }
            .onChange(of: speechService.confirmedTranscription) { newValue in
                // When confirmed transcription changes, user was speaking
                if voiceInputState == .recording && !newValue.isEmpty {
                    if speechService.isSpeechDetected || speechService.audioLevel > 0.05 {
                        hasDetectedSpeechThisTurn = true
                        lastSpeechTime = Date()
                    }
                }
            }
            .onChange(of: voiceInputState) { newState in
                if newState == .recording {
                    resetPauseDetectionForRecording()
                }
            }
            .onChange(of: showVoiceOverlay) { isShowing in
                if isShowing {
                    pauseTimerCancellable = Timer.publish(every: 0.1, on: .main, in: .common)
                        .autoconnect()
                        .sink { [self] _ in
                            checkForPause()
                            checkForSilenceTimeout()
                            handlePauseCountdown()
                            scheduleLiveVoicePreencodeIfNeeded()
                        }
                } else {
                    pauseTimerCancellable = nil
                }
            }
            .modifier(VoiceDebugObservers())
            .themedAlert(
                "Microphone access is off",
                isPresented: $showMicPermissionAlert,
                message:
                    "Osaurus needs microphone access to transcribe speech. Enable it in System Settings → Privacy & Security → Microphone, then try again.",
                primaryButton: .primary("Open System Settings") {
                    if let url = URL(
                        string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone"
                    ) {
                        NSWorkspace.shared.open(url)
                    }
                },
                secondaryButton: .cancel("Cancel")
            )
            .task {
                // log full voice state once the view has settled (deferred to avoid type-checker load in body)
                // 100ms
                try? await Task.sleep(nanoseconds: 100_000_000)
                logVoiceState(trigger: "onAppear")
            }
    }

    // MARK: - Voice Input Methods

    private func loadVoiceConfig() {
        voiceConfig = SpeechConfigurationStore.load()
    }

    private func logVoiceState(trigger: String) {
        let enabled = voiceConfig.voiceInputEnabled
        let permission = speechService.microphonePermissionGranted
        let downloaded = speechModelManager.downloadedModelsCount
        let loading = speechService.isLoadingModel
        let loaded = speechService.isModelLoaded
        let configured = isVoiceConfigured
        let available = isVoiceAvailable
        print(
            """
            [VoiceDebug] [\(trigger)] \
            enabled=\(enabled) | \
            micPermission=\(permission) | \
            downloadedCount=\(downloaded) | \
            isLoading=\(loading) | \
            isLoaded=\(loaded) | \
            → isVoiceConfigured=\(configured) | \
            → isVoiceAvailable=\(available)
            """
        )
    }

}

// MARK: - Voice Debug Helpers

/// Standalone log helper so VoiceDebugObservers can call it without a card reference.
fileprivate func voiceDebugLog(
    trigger: String,
    enabled: Bool,
    micPermission: Bool,
    downloadedCount: Int,
    isLoading: Bool,
    isLoaded: Bool
) {
    let configured = enabled && micPermission && downloadedCount > 0
    let available = configured && isLoaded
    print(
        """
        [VoiceDebug] [\(trigger)] \
        enabled=\(enabled) | \
        micPermission=\(micPermission) | \
        downloadedCount=\(downloadedCount) | \
        isLoading=\(isLoading) | \
        isLoaded=\(isLoaded) | \
        → isVoiceConfigured=\(configured) | \
        → isVoiceAvailable=\(available)
        """
    )
}

// MARK: - Voice Debug Observers

/// Watches the four properties that feed into isVoiceConfigured / isVoiceAvailable
/// and emits a debug log line whenever any of them change.
private struct VoiceDebugObservers: ViewModifier {
    @ObservedObject private var speechService = SpeechService.shared
    @ObservedObject private var speechModelManager = SpeechModelManager.shared

    func body(content: Content) -> some View {
        content
            .onChange(of: speechService.microphonePermissionGranted) { granted in
                print("[VoiceDebug] microphonePermissionGranted → \(granted)")
                voiceDebugLog(
                    trigger: "micPermission",
                    enabled: SpeechConfigurationStore.load().voiceInputEnabled,
                    micPermission: granted,
                    downloadedCount: speechModelManager.downloadedModelsCount,
                    isLoading: speechService.isLoadingModel,
                    isLoaded: speechService.isModelLoaded
                )
            }
            .onChange(of: speechService.isModelLoaded) { loaded in
                print("[VoiceDebug] isModelLoaded → \(loaded)")
                voiceDebugLog(
                    trigger: "isModelLoaded",
                    enabled: SpeechConfigurationStore.load().voiceInputEnabled,
                    micPermission: speechService.microphonePermissionGranted,
                    downloadedCount: speechModelManager.downloadedModelsCount,
                    isLoading: speechService.isLoadingModel,
                    isLoaded: loaded
                )
            }
            .onChange(of: speechService.isLoadingModel) { loading in
                print("[VoiceDebug] isLoadingModel → \(loading)")
            }
            .onChange(of: speechModelManager.downloadedModelsCount) { count in
                print("[VoiceDebug] downloadedModelsCount → \(count)")
                voiceDebugLog(
                    trigger: "downloadedModelsCount",
                    enabled: SpeechConfigurationStore.load().voiceInputEnabled,
                    micPermission: speechService.microphonePermissionGranted,
                    downloadedCount: count,
                    isLoading: speechService.isLoadingModel,
                    isLoaded: speechService.isModelLoaded
                )
            }
    }
}

extension FloatingInputCard {

    fileprivate func startVoiceInput() {
        // Branch on TCC up front:
        //   .denied / .restricted → themed "enable in Settings" alert
        //   .notDetermined        → trigger the system permission prompt
        //                           and prime the model load on grant
        //   .authorized           → fall through to the existing flow
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .denied, .restricted:
            showMicPermissionAlert = true
            return
        case .notDetermined:
            Task { @MainActor in
                let granted = await speechService.requestMicrophonePermission()
                if granted, let model = SpeechModelManager.shared.selectedModel,
                    !speechService.isModelLoaded, !speechService.isLoadingModel
                {
                    Task { try? await speechService.loadModel(model.id) }
                }
            }
            return
        case .authorized:
            break
        @unknown default:
            return
        }

        guard isVoiceAvailable else {
            print(
                "[VoiceDebug] startVoiceInput called but isVoiceAvailable=false — triggering emergency load if possible"
            )
            if let model = SpeechModelManager.shared.selectedModel, !speechService.isLoadingModel {
                Task { try? await speechService.loadModel(model.id) }
            }
            return
        }

        // If continuous mode is active, we should be aggressive about ensuring the UI is shown.
        // If recording is already active (e.g. VAD or zombie state), just attach to it.
        if speechService.isRecording {
            print("[FloatingInputCard] startVoiceInput: Recording already active, ensuring UI is visible")
            showVoiceOverlay = true
            if liveVoiceAttachmentId == nil {
                beginLiveVoicePreencodeSession()
            }
            if voiceInputState == .idle {
                voiceInputState = .recording
                lastVoiceActivityTime = Date()
                resetPauseDetectionForRecording()
            }
            return
        }

        // Don't start if already recording (handled above) or starting
        guard voiceInputState == .idle else { return }

        // Show overlay immediately for visual feedback, but don't set recording state yet.
        // Recording state will be set when speechService.isRecording becomes true.
        showVoiceOverlay = true
        beginLiveVoicePreencodeSession()

        Task {
            do {
                try await speechService.startStreamingTranscription()

                // Wait for isRecording to become true (with timeout)
                let startTime = Date()
                let maxWait: TimeInterval = 3.0  // Max 3 seconds to start

                while !speechService.isRecording {
                    if Date().timeIntervalSince(startTime) > maxWait {
                        print("[FloatingInputCard] Timeout waiting for recording to start")
                        throw SpeechError.transcriptionFailed("Recording failed to start")
                    }
                    try await Task.sleep(nanoseconds: 50_000_000)  // 50ms
                }

                // Recording confirmed - now set the recording state
                // lastVoiceActivityTime is reset in onChange(of: isRecording)

            } catch {
                print("[FloatingInputCard] Failed to start voice input: \(error)")
                await MainActor.run {
                    voiceInputState = .idle
                    showVoiceOverlay = false
                    if case SpeechError.microphonePermissionDenied = error {
                        showMicPermissionAlert = true
                    }
                }
            }
        }
    }

    private func beginLiveVoicePreencodeSession() {
        if let oldId = liveVoiceAttachmentId {
            LiveVoiceAudioInputRegistry.shared.remove(for: oldId)
        }
        liveVoicePreencodeTask?.cancel()
        liveVoicePreencodeTask = nil
        liveVoiceAttachmentId = UUID()
        lastLiveVoicePreencodeAt = .distantPast
        lastLiveVoicePreencodeSampleCount = 0
    }

    private func cancelLiveVoicePreencodeSession(removeRegistryEntry: Bool) {
        liveVoicePreencodeTask?.cancel()
        liveVoicePreencodeTask = nil
        if removeRegistryEntry, let id = liveVoiceAttachmentId {
            LiveVoiceAudioInputRegistry.shared.remove(for: id)
        }
        liveVoiceAttachmentId = nil
        lastLiveVoicePreencodeAt = .distantPast
        lastLiveVoicePreencodeSampleCount = 0
    }

    @discardableResult
    private func scheduleLiveVoicePreencodeIfNeeded(
        force: Bool = false,
        snapshot providedSnapshot: LiveVoiceAudioSnapshot? = nil,
        attachmentId providedAttachmentId: UUID? = nil
    ) -> Task<Void, Never>? {
        guard mediaCapabilities.supportsAudio,
            let modelName = selectedModel,
            ModelFamilyNames.isNemotronOmniFamily(modelName)
        else {
            return nil
        }

        guard let snapshot = providedSnapshot ?? speechService.currentLiveAudioSnapshot(),
            !snapshot.samples.isEmpty
        else {
            return nil
        }

        let attachmentId: UUID
        if let providedAttachmentId {
            attachmentId = providedAttachmentId
        } else if let existing = liveVoiceAttachmentId {
            attachmentId = existing
        } else {
            let newId = UUID()
            liveVoiceAttachmentId = newId
            attachmentId = newId
        }

        let sampleCount = snapshot.samples.count
        let minSampleDelta = max(4_000, snapshot.sampleRate / 2)
        if !force {
            guard sampleCount >= minSampleDelta else { return nil }
            guard Date().timeIntervalSince(lastLiveVoicePreencodeAt) >= 0.75 else { return nil }
            guard sampleCount - lastLiveVoicePreencodeSampleCount >= minSampleDelta else { return nil }
        }

        lastLiveVoicePreencodeAt = Date()
        lastLiveVoicePreencodeSampleCount = sampleCount

        let samples = snapshot.samples
        let sampleRate = snapshot.sampleRate
        let task = Task.detached(priority: .utility) {
            let result = await ModelRuntime.shared.preencodeLiveVoiceAudioIfResident(
                modelName: modelName,
                attachmentId: attachmentId,
                samples: samples,
                sampleRate: sampleRate
            )
            print(
                "[Osaurus][LiveVoice] preencode_status=\(result.status.rawValue) samples=\(result.sampleCount) sample_rate=\(result.sampleRate) encode_ms=\(result.encodeMs) message=\(result.message ?? "")"
            )
        }
        liveVoicePreencodeTask = task
        return task
    }

    private func cancelVoiceInput() {
        print("[FloatingInputCard] User cancelled voice input - disabling continuous mode")
        hasDetectedSpeechThisTurn = false
        lastConfirmedLength = 0
        isContinuousVoiceMode = false
        cancelLiveVoicePreencodeSession(removeRegistryEntry: true)
        Task {
            _ = await speechService.stopStreamingTranscription()
            speechService.clearTranscription()
        }
        voiceInputState = .idle
        showVoiceOverlay = false
    }

    // MARK: - Pause Detection

    /// Resets pause detection state for a new recording turn.
    /// Handles the case where `isSpeechDetected` is already true (e.g. VAD-triggered start).
    private func resetPauseDetectionForRecording() {
        hasDetectedSpeechThisTurn = false
        lastSpeechTime = .distantFuture
        lastConfirmedLength = 0

        if speechService.isSpeechDetected {
            hasDetectedSpeechThisTurn = true
            lastSpeechTime = Date()
        }
    }

    private func checkForPause() {
        guard voiceInputState == .recording,
            voiceConfig.transcriptionStopMode == .automatic,
            voiceConfig.pauseDuration > 0
        else { return }

        let hasContent = !speechService.currentTranscription.isEmpty || !speechService.confirmedTranscription.isEmpty
        let silenceDuration = Date().timeIntervalSince(lastSpeechTime)

        guard hasContent else {
            if silenceDuration >= voiceConfig.pauseDuration && hasDetectedSpeechThisTurn {
                print(
                    "[FloatingInputCard] Pause threshold reached but no content (silence: \(String(format: "%.1f", silenceDuration))s, current: '\(speechService.currentTranscription)', confirmed: '\(speechService.confirmedTranscription)')"
                )
            }
            return
        }

        if silenceDuration >= voiceConfig.pauseDuration {
            voiceInputState = .paused(remaining: voiceConfig.confirmationDelay)
            print(
                "[FloatingInputCard] Pause detected after \(String(format: "%.1f", silenceDuration))s silence, triggering countdown"
            )
        }
    }

    private func checkForSilenceTimeout() {
        // Only check when overlay is showing and it's user's turn (not streaming)
        guard showVoiceOverlay,
            !isStreaming,
            voiceConfig.silenceTimeoutSeconds > 0,
            voiceInputState == .recording,
            speechService.isRecording
        else {
            // Reset display when conditions aren't met
            if displayedSilenceTimeoutDuration != 0 {
                displayedSilenceTimeoutDuration = 0
            }
            return
        }

        // Reset timer when there's real-time voice activity (not cumulative text)
        let currentConfirmedLen = speechService.confirmedTranscription.count
        let hasNewConfirmedText = currentConfirmedLen > lastConfirmedLength
        if hasNewConfirmedText {
            lastConfirmedLength = currentConfirmedLen
        }

        if speechService.isSpeechDetected || hasNewConfirmedText || !speechService.currentTranscription.isEmpty {
            lastVoiceActivityTime = Date()
        }

        // Calculate and update displayed silence duration
        let silenceDuration = Date().timeIntervalSince(lastVoiceActivityTime)
        displayedSilenceTimeoutDuration = silenceDuration

        // Check if timeout exceeded
        if silenceDuration >= voiceConfig.silenceTimeoutSeconds {
            let hasContent =
                !speechService.currentTranscription.isEmpty || !speechService.confirmedTranscription.isEmpty

            if hasContent && voiceConfig.transcriptionStopMode == .automatic {
                print("[FloatingInputCard] Silence timeout with content - triggering auto-send")
                voiceInputState = .paused(remaining: voiceConfig.confirmationDelay)
            } else if !hasContent {
                print("[FloatingInputCard] Silence timeout without content - closing voice input")
                stopVoiceInputFromTimeout()
            }
        }
    }

    private func handlePauseCountdown() {
        guard case .paused(let remaining) = voiceInputState else { return }

        // Decrement by 0.1s (the timer interval)
        let newRemaining = remaining - 0.1

        if newRemaining <= 0 {
            // Countdown finished, send message
            let transcribedText = [
                speechService.confirmedTranscription,
                speechService.currentTranscription,
            ]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

            if !transcribedText.isEmpty {
                sendVoiceMessage(transcribedText)
            } else {
                stopVoiceInputFromTimeout()
            }
        } else {
            // Update remaining time
            voiceInputState = .paused(remaining: newRemaining)
        }
    }

    private func stopVoiceInputFromTimeout() {
        cancelLiveVoicePreencodeSession(removeRegistryEntry: true)
        Task {
            _ = await speechService.stopStreamingTranscription(force: false)
            speechService.clearTranscription()
        }
        voiceInputState = .idle
        showVoiceOverlay = false
    }

    private func sendVoiceMessage(_ message: String) {
        print("[FloatingInputCard] Sending voice message. Continuous mode: \(isContinuousVoiceMode)")
        logVoiceState(trigger: "sendVoiceMessage-start")
        let voiceCaptureStart = CFAbsoluteTimeGetCurrent()
        let voiceSnapshot = mediaCapabilities.supportsAudio ? speechService.currentLiveAudioSnapshot() : nil
        let snapshotMs = Int((CFAbsoluteTimeGetCurrent() - voiceCaptureStart) * 1000)
        let wavEncodeStart = CFAbsoluteTimeGetCurrent()
        let voiceAudioData = voiceSnapshot?.wavData()
        let wavEncodeMs = Int((CFAbsoluteTimeGetCurrent() - wavEncodeStart) * 1000)
        let voiceAttachmentId = liveVoiceAttachmentId ?? UUID()
        liveVoiceAttachmentId = voiceAttachmentId
        let finalPreencodeTask = voiceSnapshot.flatMap {
            scheduleLiveVoicePreencodeIfNeeded(
                force: true,
                snapshot: $0,
                attachmentId: voiceAttachmentId
            )
        }
        if mediaCapabilities.supportsAudio {
            let wavBytes = voiceAudioData?.count ?? 0
            let durationMs = Int((voiceSnapshot?.durationSeconds ?? 0) * 1000)
            print(
                "[Osaurus][LiveVoice] snapshot_ms=\(snapshotMs) wav_encode_ms=\(wavEncodeMs) wav_bytes=\(wavBytes) sample_rate=\(voiceSnapshot?.sampleRate ?? 0) duration_ms=\(durationMs)"
            )
        }

        // show sending state first
        voiceInputState = .sending

        Task {
            _ = await speechService.stopStreamingTranscription()
            // clear transcription so next voice input starts fresh
            speechService.clearTranscription()
            logVoiceState(trigger: "sendVoiceMessage-afterStop")

            print("[FloatingInputCard] Invoking cleanup for voice message (\(message.count) chars)")
            let cleanedMessage = await TranscriptionCleanupService.shared.clean(message)
            print("[FloatingInputCard] Cleanup done. Original: \(message) | Cleaned: \(cleanedMessage)")
            await finalPreencodeTask?.value

            await MainActor.run {
                voiceInputState = .idle
                showVoiceOverlay = false

                let existing = localText.trimmingCharacters(in: .whitespacesAndNewlines)
                let fullMessage = existing.isEmpty ? cleanedMessage : "\(existing) \(cleanedMessage)"

                if let voiceAudioData {
                    let voiceAttachment = Attachment(
                        id: voiceAttachmentId,
                        kind: .audio(
                            voiceAudioData,
                            format: "wav",
                            filename: "voice-input.wav"
                        )
                    )
                    if let voiceSnapshot {
                        LiveVoiceAudioInputRegistry.shared.store(
                            snapshot: voiceSnapshot,
                            for: voiceAttachment.id
                        )
                    }
                    pendingAttachments.append(voiceAttachment)
                }

                // try to paste. if it fails (permissions), we fall back to direct text setting
                if KeyboardSimulationService.shared.pasteText(cleanedMessage) {
                    // success: clear UI state immediately
                    localText = ""
                    text = ""
                    // small delay before sending to let UI breathe before model starts streaming
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        localText = ""
                        text = ""
                        onSend(fullMessage)
                    }
                } else {
                    // failed (no permission): set text and clear local buffer before sending
                    localText = ""
                    text = ""
                    onSend(fullMessage)
                }
                cancelLiveVoicePreencodeSession(removeRegistryEntry: voiceAudioData == nil)
            }
        }
    }

    private func transferToTextInput() {
        print("[FloatingInputCard] Transferring to text input - disabling continuous mode")
        // Transfer transcription to text input and close overlay
        let transcribedText = [
            speechService.confirmedTranscription,
            speechService.currentTranscription,
        ]
        .filter { !$0.isEmpty }
        .joined(separator: " ")

        voiceInputState = .sending
        // exit continuous mode when switching to text
        isContinuousVoiceMode = false

        Task {
            _ = await speechService.stopStreamingTranscription()
            speechService.clearTranscription()

            let cleaned = await TranscriptionCleanupService.shared.clean(transcribedText)

            await MainActor.run {
                voiceInputState = .idle
                showVoiceOverlay = false

                let existing = localText.trimmingCharacters(in: .whitespacesAndNewlines)
                let fullCombined = existing.isEmpty ? cleaned : "\(existing) \(cleaned)"

                if KeyboardSimulationService.shared.pasteText(cleaned) {
                    isFocused = true
                } else {
                    // Fallback if paste fails
                    localText = fullCombined
                    text = fullCombined
                    isFocused = true
                }
            }
        }
    }

    private func syncAndSend() {
        guard canSend else { return }
        let message = localText
        // Hold first responder through the binding-flush cascade
        // (clearing local + bound text, parent reconcile, optional
        // new run kickoff). 300 ms covers the longest observed
        // cascade with margin. Covers both fresh sends and queueing.
        textViewFocusController.lockFocus(for: 0.3)
        localText = ""
        text = ""
        // Sending resets history navigation; the sent text becomes the
        // newest history entry once its turn lands.
        inputHistoryState = ChatInputHistoryState()
        onSend(message)
    }

    // MARK: - Input History (terminal-style Up/Down recall)

    private func handleHistoryArrowUp() -> Bool {
        guard let provider = inputHistoryProvider, caretIsOnFirstLine else { return false }
        guard
            let result = ChatInputHistory.recall(
                state: inputHistoryState,
                entries: provider(),
                currentDraft: localText
            )
        else { return false }
        inputHistoryState = result.state
        applyHistoryText(result.text)
        return true
    }

    private func handleHistoryArrowDown() -> Bool {
        guard inputHistoryState.index != nil, caretIsOnLastLine else { return false }
        guard
            let result = ChatInputHistory.advance(
                state: inputHistoryState,
                entries: inputHistoryProvider?() ?? []
            )
        else { return false }
        inputHistoryState = result.state
        applyHistoryText(result.text)
        return true
    }

    /// Replace the composer text with a recalled entry and put the caret at
    /// the end, matching terminal behavior.
    private func applyHistoryText(_ newText: String) {
        localText = newText
        text = newText
        DispatchQueue.main.async {
            guard let tv = textViewFocusController.textView else { return }
            let end = (tv.string as NSString).length
            tv.setSelectedRange(NSRange(location: end, length: 0))
            tv.scrollRangeToVisible(NSRange(location: end, length: 0))
        }
    }

    /// True when the caret is a plain insertion point on the first line of
    /// the composer. History recall only triggers there, so Up still moves
    /// the caret inside a multi-line draft.
    private var caretIsOnFirstLine: Bool {
        guard let tv = textViewFocusController.textView else { return false }
        let range = tv.selectedRange()
        guard range.length == 0 else { return false }
        let ns = tv.string as NSString
        return !ns.substring(to: min(range.location, ns.length)).contains("\n")
    }

    /// True when the caret is a plain insertion point on the last line of
    /// the composer. Walking history forward only triggers there.
    private var caretIsOnLastLine: Bool {
        guard let tv = textViewFocusController.textView else { return false }
        let range = tv.selectedRange()
        guard range.length == 0 else { return false }
        let ns = tv.string as NSString
        return !ns.substring(from: min(range.location, ns.length)).contains("\n")
    }

    /// Replace the trailing "@…" token with `replacement`, preserving the text
    /// before the "@".
    private func replacingAtToken(with replacement: String) -> String {
        guard let atRange = localText.range(of: "@", options: .backwards) else {
            return replacement
        }
        return String(localText[..<atRange.lowerBound]) + replacement
    }

    /// Apply a selected file/folder to the input. Folders keep the popup open
    /// with a trailing "/" so the user can drill deeper CLI-style; files insert
    /// the path followed by a space, which closes the token.
    private func applyAtItem(_ item: AtFileItem) {
        let inserted = item.isDirectory ? "@\(item.path)/" : "@\(item.path) "
        let newText = replacingAtToken(with: inserted)
        localText = newText
        text = newText
        isFocused = true
    }

    /// Refresh `atMenuItems` for the current "@" query off the main actor.
    /// Cancels any prior listing so fast typing can't pile up work. A nil query
    /// (token dismissed) clears the list synchronously.
    private func refreshAtMenu() {
        atMenuTask?.cancel()
        guard let query = activeAtQuery else {
            atMenuItems = []
            atMenuStatus = .ok
            atMenuLoading = false
            syncPopupVisibility()
            return
        }
        // Only treat this as a blocking "load" when we have nothing to show yet;
        // when refining an existing list we keep the current rows visible.
        atMenuLoading = atMenuItems.isEmpty
        // Snapshot THIS chat's folder root here (main actor); the enumeration
        // itself runs detached so filesystem I/O never blocks the UI.
        let rootPath = folderState.rootPath
        atMenuTask = Task {
            let result = await Task.detached(priority: .userInitiated) {
                AtFileMenu.list(query: query, rootPath: rootPath)
            }.value
            if Task.isCancelled { return }
            atMenuItems = result.items
            atMenuStatus = result.status
            atMenuDirectory = result.directory
            atMenuLoading = false
            syncPopupVisibility()
        }
    }

    /// Recover from a denied folder. macOS won't re-prompt after a denial, but
    /// because the app is non-sandboxed, the user explicitly picking the folder
    /// in an open panel re-grants TCC access. On success we re-list so browsing
    /// resumes in place. The panel is a main-actor modal (user interaction);
    /// the listing it triggers stays off the main thread.
    private func grantAtMenuAccess() {
        let directory = atMenuDirectory
        guard !directory.isEmpty else { return }
        Task {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = false
            panel.allowsMultipleSelection = false
            panel.directoryURL = URL(fileURLWithPath: directory)
            panel.prompt = L("Grant Access")
            panel.message = L("Grant osaurus access to this folder")
            guard await panel.beginModal() == .OK else { return }
            isFocused = true
            refreshAtMenu()
        }
    }

    /// Mirror whether either completion popup is showing into the shared
    /// registry so the global key monitor can suppress Escape (which would
    /// otherwise close the window) while a popup is open. Folded into
    /// `refreshAtMenu` and the slash `onChange` so it adds no body chain link.
    private func syncPopupVisibility() {
        SlashCommandRegistry.shared.isPopupVisible = showSlashPopup || showAtPopup
    }

    // MARK: - Input Key Handling

    /// Return/Enter in the text field: apply the highlighted popup entry when a
    /// popup is open, otherwise send the message.
    private func handleInputCommit() {
        if showSlashPopup {
            let cmds = slashFilteredCommands
            if slashSelectedIndex < cmds.count {
                applySlashCommand(cmds[slashSelectedIndex])
            }
        } else if showAtPopup {
            if atSelectedIndex < atMenuItems.count {
                applyAtItem(atMenuItems[atSelectedIndex])
            }
        } else {
            syncAndSend()
        }
    }

    /// Up arrow: move the open popup's selection, else navigate input history.
    private func handleInputArrowUp() -> Bool {
        if showSlashPopup {
            slashSelectedIndex = max(0, slashSelectedIndex - 1)
            return true
        }
        if showAtPopup {
            atSelectedIndex = max(0, atSelectedIndex - 1)
            return true
        }
        return handleHistoryArrowUp()
    }

    /// Down arrow: move the open popup's selection, else navigate input history.
    private func handleInputArrowDown() -> Bool {
        if showSlashPopup {
            slashSelectedIndex = min(slashFilteredCommands.count - 1, slashSelectedIndex + 1)
            return true
        }
        if showAtPopup {
            atSelectedIndex = min(atMenuItems.count - 1, atSelectedIndex + 1)
            return true
        }
        return handleHistoryArrowDown()
    }

    /// Escape while a popup is open: dismiss just the popup. The typed text
    /// (including the slash/"@" token) is left intact; the "@" menu removes
    /// only its token so surrounding text survives.
    private func handlePopupEscape() -> Bool {
        if showSlashPopup {
            dismissedSlashQuery = activeSlashQuery
            return true
        }
        if showAtPopup {
            let newText = replacingAtToken(with: "")
            localText = newText
            text = newText
            return true
        }
        return false
    }

    /// The slash-command and "@" file menus, floated over the input card
    /// (upstream #3017).
    private var composerPopupOverlay: some View {
        VStack(spacing: 4) {
            if showSlashPopup {
                SlashCommandPopup(
                    commands: slashFilteredCommands,
                    selectedIndex: $slashSelectedIndex,
                    onSelect: applySlashCommand
                )
                .transition(
                    .asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)),
                        removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))
                    )
                )
            }

            atFileMenuPopupView
        }
    }

    /// The "@" file completion popup, extracted from `composerPopupOverlay` to
    /// keep that view builder within the Swift type-checker's reach.
    @ViewBuilder
    private var atFileMenuPopupView: some View {
        if showAtPopup {
            AtFileMenuPopup(
                items: atMenuItems,
                status: atMenuStatus,
                deniedDirectoryName: (atMenuDirectory as NSString).lastPathComponent,
                emptyMessage: atMenuIsFiltering ? L("No matching files") : L("This folder is empty"),
                selectedIndex: $atSelectedIndex,
                onSelect: applyAtItem,
                onGrantAccess: grantAtMenuAccess
            )
            .transition(
                .asymmetric(
                    insertion: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom)),
                    removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .bottom))
                )
            )
        }
    }


    // MARK: - Slash Commands

    /// Returns the text with the active slash token replaced by `replacement`.
    private func replacingSlashToken(with replacement: String) -> String {
        guard let slashRange = localText.range(of: "/", options: .backwards) else {
            return replacement
        }
        let before = localText[..<slashRange.lowerBound]
        // Strip trailing space added by the button if replacement is empty
        let prefix = replacement.isEmpty ? before.trimmingCharacters(in: .whitespaces) : String(before)
        return prefix + replacement
    }

    private func applySlashCommand(_ command: SlashCommand) {
        switch command.kind {
        case .action:
            let newText = replacingSlashToken(with: "")
            localText = newText
            text = newText
            handleBuiltInSlashAction(command.name)
        case .template:
            let templateText = command.template ?? ""
            let newText = replacingSlashToken(with: templateText)
            localText = newText
            text = newText
            isFocused = true
        case .skill:
            let newText = replacingSlashToken(with: "")
            localText = newText
            text = newText
            isFocused = true
            onSkillSelected?(command.id)
        }
    }

    private func handleBuiltInSlashAction(_ name: String) {
        switch name {
        case "clear":
            if let clearChat = onClearChat {
                clearChat()
            } else {
                ToastManager.shared.infoLocalized("Clear Chat", message: "Pass an onClearChat handler to enable /clear")
            }
        case "model":
            openModelPicker()
        case "agent":
            NotificationCenter.default.post(
                name: .chatToolbarOpenAgentPicker,
                object: nil,
                userInfo: windowId.map { ["windowId": $0] }
            )
        case "screenshot":
            if let capture = onCaptureScreenshot {
                capture()
            } else {
                ToastManager.shared.infoLocalized(
                    "Screenshot Unavailable",
                    message: "Pass an onCaptureScreenshot handler to enable /screenshot"
                )
            }
        case "title":
            if let generateTitle = onGenerateTitle {
                generateTitle()
            } else {
                ToastManager.shared.infoLocalized(
                    "Chat Title", message: "Pass an onGenerateTitle handler to enable /title")
            }
        case "compact":
            // Upstream #2999: say why nothing happens instead of failing
            // silently.
            if compactionState.isRunning {
                ToastManager.shared.infoLocalized(
                    "Compact Conversation",
                    message: "Compaction is already running."
                )
            } else if isStreaming {
                ToastManager.shared.infoLocalized(
                    "Compact Conversation",
                    message: "Wait for the current response to finish, then run /compact."
                )
            } else if let compact = onCompact, canCompactConversation {
                compact()
            } else if onCompact == nil {
                ToastManager.shared.infoLocalized(
                    "Compact", message: "Compaction isn't available in this window.")
            } else {
                ToastManager.shared.infoLocalized(
                    "Compact Conversation",
                    message: "Nothing to compact yet. The recent conversation is already as small as it can get."
                )
            }
        case "help":
            ToastManager.shared.infoLocalized(
                "Slash Commands",
                message: "Type / to open commands. ↑↓ to navigate, ↵ to select, Esc to dismiss."
            )
        default:
            break
        }
    }

    // MARK: - Queued Send Chip

    /// Compact chip preview of the message that's queued to flush when the
    /// active run finishes (or be dispatched immediately via Send Now).
    /// Visible only when `queuedSend != nil`.
    @ViewBuilder
    private var queuedSendChipView: some View {
        if let queued = queuedSend {
            let preview: String = {
                let trimmed = queued.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    return L("Queued attachment")
                }
                if trimmed.count <= 80 { return trimmed }
                return String(trimmed.prefix(80)) + "\u{2026}"
            }()
            HStack(spacing: 5) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.accentColor)
                Text("Queued:", bundle: .module)
                    .font(theme.font(size: 11, weight: .semibold))
                    .foregroundColor(theme.accentColor)
                Text(verbatim: preview)
                    .font(theme.font(size: 11, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Button {
                    withAnimation(theme.springAnimation()) {
                        if let onCancelQueued {
                            onCancelQueued()
                        } else {
                            queuedSend = nil
                        }
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(theme.secondaryText)
                        .padding(3)
                        .background(Circle().fill(theme.tertiaryBackground))
                }
                .buttonStyle(.plain)
                .localizedHelp("Cancel queued message")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.accentColor.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.accentColor.opacity(0.3), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Pending Skill Chip

    @ViewBuilder
    private var pendingSkillChipView: some View {
        if let skillId = pendingSkillId,
            let skill = SkillManager.shared.skill(for: skillId)
        {
            HStack(spacing: 5) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundColor(theme.accentColor)
                Text(skill.name)
                    .font(theme.font(size: 11, weight: .medium))
                    .foregroundColor(theme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Button {
                    withAnimation(theme.springAnimation()) {
                        pendingSkillId = nil
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundColor(theme.secondaryText)
                        .padding(3)
                        .background(Circle().fill(theme.tertiaryBackground))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.accentColor.opacity(0.1))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(theme.accentColor.opacity(0.25), lineWidth: 0.5)
            )
        }
    }

    // MARK: - Pending Attachments Preview (Inline)

    private var inlinePendingAttachmentsPreview: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(Array(pendingAttachments.enumerated()), id: \.element.id) { index, attachment in
                    switch attachment.kind {
                    case .image(let data):
                        CachedImageThumbnail(
                            imageData: data,
                            size: 40,
                            onRemove: {
                                withAnimation(theme.springAnimation()) {
                                    _ = pendingAttachments.remove(at: index)
                                }
                            }
                        )
                    case .imageRef:
                        // Pending attachments are pre-spillover; refs only
                        // appear after persistence. Defensive-render an
                        // empty thumbnail so we don't crash on a pending
                        // queue that someone re-hydrated from disk.
                        if let data = attachment.loadImageData() {
                            CachedImageThumbnail(
                                imageData: data,
                                size: 40,
                                onRemove: {
                                    withAnimation(theme.springAnimation()) {
                                        _ = pendingAttachments.remove(at: index)
                                    }
                                }
                            )
                        }
                    case .document, .documentRef:
                        DocumentChip(
                            attachment: attachment,
                            onRemove: {
                                withAnimation(theme.springAnimation()) {
                                    _ = pendingAttachments.remove(at: index)
                                }
                            },
                            onTap: attachment.isPastedContent
                                ? {
                                    pastedContentPreview = attachment
                                } : nil,
                            onEdit: attachment.isPastedContent
                                ? {
                                    pastedContentEdit = attachment
                                } : nil,
                            onInline: attachment.isPastedContent
                                ? {
                                    inlinePastedContent(attachment)
                                } : nil
                        )
                    case .audio, .audioRef, .video, .videoRef:
                        // Audio/video attachments display as a labeled chip
                        // with a media-type icon. Inline-bytes are kept on
                        // the pending queue (pre-spillover); refs may also
                        // round-trip through chat history. Same on-remove
                        // semantics as image/document chips.
                        DocumentChip(attachment: attachment) {
                            withAnimation(theme.springAnimation()) {
                                _ = pendingAttachments.remove(at: index)
                            }
                        }
                    }
                }
            }
        }
        .frame(height: 48)
        .sheet(item: $pastedContentPreview) { attachment in
            PastedContentSheet(attachment: attachment) {
                pastedContentPreview = nil
            }
        }
        .sheet(item: $pastedContentEdit) { attachment in
            PastedContentSheet(
                attachment: attachment,
                onDismiss: { pastedContentEdit = nil },
                onSave: { updated in
                    if let idx = pendingAttachments.firstIndex(where: { $0.id == attachment.id }) {
                        pendingAttachments[idx] = .pastedContent(updated)
                    }
                    pastedContentEdit = nil
                }
            )
        }
    }

    private func inlinePastedContent(_ attachment: Attachment) {
        guard let content = attachment.loadDocumentContent(), !content.isEmpty else { return }
        let existing = localText
        let combined: String
        if existing.isEmpty {
            combined = content
        } else if existing.hasSuffix("\n") {
            combined = existing + content
        } else {
            combined = existing + "\n" + content
        }
        withAnimation(theme.springAnimation()) {
            pendingAttachments.removeAll { $0.id == attachment.id }
        }
        localText = combined
        text = combined
        isFocused = true
    }

    // MARK: - Selector Row (Model + Tools)

    private var activeProfileOptions: [ModelOptionDefinition] {
        guard let model = selectedModel else { return [] }
        return ModelProfileRegistry.options(for: model)
    }

    private var selectorRow: some View {
        HStack(spacing: 6) {
            if !pickerItems.isEmpty {
                modelSelectorChip
            }

            // Thinking and every other model option live in the picker's
            // third column now (upstream #2958); no separate chips.

            if autoSpeakAssistant {
                autoSpeakToggleChip
            }

            // Sandbox toggle: visible whenever the sandbox is available on
            // this system. Mutual exclusion with the folder backend is
            // enforced inside `toggleSandbox()` (it clears the active
            // folder before enabling sandbox), not by hiding the chip —
            // that way the user can always see and switch backends.
            if isSandboxAvailable {
                sandboxToggleChip
            }

            // Clipboard chip (visible when there's something new on the clipboard and monitoring is enabled)
            if AppConfiguration.shared.chatConfig.enableClipboardMonitoring && clipboardService.hasNewContent {
                clipboardToggleChip
            }

            // Folder context selector: always available so the user can
            // point any chat at a working directory. Mutual exclusion with
            // sandbox is enforced inside the selection handlers (they
            // disable autonomous exec before opening the picker).
            folderContextChip

            Spacer()
        }
    }

    // MARK: - Context Budget Ring

    /// Context budget as a circular progress ring in the button bar, left of
    /// the send controls (upstream #2947 moved it there from the selector
    /// row). All budget math stays here; the chip only renders it.
    @ViewBuilder
    private var contextBudgetRing: some View {
        let budget = contextBudget
        if budget.displayTokens > 0 {
            FloatingContextChip(
                displayTokens: budget.displayTokens,
                usableTokens: budget.usableTokens,
                modelMaxTokens: budget.maxTokens,
                windowSource: budget.resolution?.source,
                isStreaming: isStreaming,
                isNearLimit: budget.nearLimit,
                isHardOverflow: budget.hardOverflow,
                usageRatio: budget.usageRatio,
                formatTokenCount: formatTokenCount,
                breakdown: { budget.breakdown },
                compactionState: compactionState,
                canCompact: canCompactConversation && onCompact != nil && !isStreaming && !isCompacting,
                onCompact: onCompact
            )
        }
    }

    /// Format token count for compact display (e.g., "1.2k", "15k")
    private func formatTokenCount(_ tokens: Int) -> String {
        if tokens < 1000 {
            return "\(tokens)"
        } else if tokens < 10000 {
            let k = Double(tokens) / 1000.0
            return String(format: "%.1fk", k)
        } else {
            let k = tokens / 1000
            return "\(k)k"
        }
    }

    // MARK: - Model Selector

    private var selectedPickerItem: ModelPickerItem? {
        guard let id = selectedModel else { return nil }
        return pickerItems.first { $0.id == id }
    }

    private var isSelectedModelDeprecated: Bool {
        guard let id = selectedModel else { return false }
        return ModelManager.replacementForDeprecatedModel(id) != nil
    }

    private func openModelPicker() {
        guard !showModelPicker else { return }
        cachedPickerItems = pickerItems
        modelPickerCardSize = ChatModelPickerCard.initialSize(
            providers: chatPickerProviders,
            selectedModel: selectedModel,
            optionsControl: modelPickerOptionsControl
        )
        showModelPicker = true
    }

    /// The pill stays visually simple (upstream removed its trailing icons);
    /// thinking and vision details move to the tooltip and VoiceOver value.
    private var modelSelectorDetails: String {
        var details: [String] = []
        if let model = selectedModel, inlineReasoningSuffix == nil,
            ModelProfileRegistry.profile(for: model)?.thinkingOption != nil
        {
            let explicit = ModelProfileRegistry.thinkingEnabled(for: model, values: activeModelOptions)
            if let explicit {
                details.append(explicit ? L("Thinking on") : L("Thinking off"))
            } else {
                details.append([L("Thinking"), L("Default")].joined(separator: ": "))
            }
        }
        if selectedPickerItem?.isVLM == true {
            details.append(L("Vision"))
        }
        return details.joined(separator: "\n")
    }

    /// "· Medium": the explicit `reasoningEffort` choice, else the profile
    /// default (upstream's "model · effort").
    private var inlineReasoningSuffix: String? {
        guard let model = selectedModel else { return nil }
        return ModelProfileRegistry.inlineReasoningSuffixLabel(for: model, values: activeModelOptions)
    }

    private var modelSelectorChip: some View {
        SelectorChip(isActive: showModelPicker) {
            if showModelPicker { dismissModelPicker() } else { openModelPicker() }
        } content: {
            HStack(spacing: 6) {
                if isSelectedModelDeprecated {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(theme.font(size: CGFloat(theme.captionSize) - 2))
                        .foregroundColor(.orange)
                        .localizedHelp("This model is outdated. Click to switch to a newer version.")
                } else {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                }

                // Model name and reasoning text, without suffix icons.
                if let option = selectedPickerItem {
                    HStack(spacing: 4) {
                        Text(option.displayName)
                            .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                            .foregroundColor(isSelectedModelDeprecated ? .orange : theme.secondaryText)
                            .lineLimit(1)

                        if let suffix = inlineReasoningSuffix {
                            Text(verbatim: "· \(suffix)")
                                .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .regular))
                                .foregroundColor(theme.tertiaryText)
                                .lineLimit(1)
                        }

                        if !isCompact, let params = option.parameterCount {
                            Text(params)
                                .font(theme.font(size: CGFloat(theme.captionSize) - 3, weight: .medium))
                                .foregroundColor(.blue.opacity(0.8))
                                .padding(.horizontal, 4)
                                .padding(.vertical, 1)
                                .background(
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .fill(Color.blue.opacity(0.12))
                                )
                        }
                    }
                } else {
                    Text("Select Model", bundle: .module)
                        .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                        .foregroundColor(theme.secondaryText)
                }
            }
        }
        .accessibilityValue(Text(verbatim: modelSelectorDetails))
        .help(modelSelectorDetails.isEmpty ? L("Model ready") : modelSelectorDetails)
        .anchoredCard(isPresented: $showModelPicker, size: modelPickerCardSize, accessibilityLabel: L("Model picker")) {
            ChatModelPickerCard(
                providers: chatPickerProviders,
                selectedModel: $selectedModel,
                optionsControl: modelPickerOptionsControl,
                onExploreLocal: {
                    dismissModelPicker()
                    AppDelegate.shared?.showManagementWindow(initialTab: .models)
                },
                onExploreCloud: {
                    dismissModelPicker()
                    DispatchQueue.main.async { showCloudModelBrowser = true }
                },
                onSizeChange: { modelPickerCardSize = $0 }
            )
            .environment(\.theme, theme)
        }
        .sheet(isPresented: $showCloudModelBrowser) {
            CloudModelBrowserDialog(
                options: cloudPickerItems,
                selectedModel: $selectedModel,
                onDismiss: { showCloudModelBrowser = false },
                onManageCloud: {
                    showCloudModelBrowser = false
                    AppDelegate.shared?.showManagementWindow(initialTab: .credits)
                }
            )
            .environment(\.theme, theme)
            .intelControlRendering(theme: theme)
        }
        .onChange(of: showModelPicker) { isShowing in
            if isShowing {
                // Snapshot options when the card opens to prevent refresh during streaming
                cachedPickerItems = pickerItems
                Task {
                    await RemoteProviderManager.shared.connectOsaurusRouterIfPossible()
                    await ModelPickerItemCache.shared.buildModelPickerItems()
                }
            }
        }
        .onChange(of: pickerItems) { newItems in
            // mirror upstream changes while open so picker triggered refreshes are visible
            if showModelPicker {
                cachedPickerItems = newItems
            }
        }
    }

    private var cloudPickerItems: [ModelPickerItem] {
        pickerItems.filter {
            if case .remote(_, let providerID) = $0.source {
                return providerID == RemoteProviderManager.osaurusRouterProviderId
            }
            return false
        }
    }

    /// Cloud shows the favourites shortlist plus the selected model; other
    /// providers show everything (upstream).
    private var chatPickerProviders: [ChatModelPickerProvider] {
        let shortlist = Set(cachedPickerItems.filter {
            chatModelFavorites.isFavorite($0.favoriteKey) || $0.id == selectedModel
        }.map(\.id))
        return ChatModelPickerProvider.groups(from: cachedPickerItems, cloudModelIDs: shortlist)
    }

    /// The picker's third column: the semantic Thinking row plus every other
    /// option the selected model's profile exposes. Writes are deferred a
    /// runloop so the pill (which shows the effort) never resizes during the
    /// card's own update (upstream).
    private var modelPickerOptionsControl: ModelPickerOptionsControl? {
        guard let model = selectedModel else { return nil }
        let thinkingOption = ModelProfileRegistry.profile(for: model)?.thinkingOption
        let options = activeProfileOptions.filter { $0.id != thinkingOption?.id }
        let thinking: ModelPickerThinkingControl? = thinkingOption.map { _ in
            let explicit = ModelProfileRegistry.thinkingEnabled(for: model, values: activeModelOptions)
            return ModelPickerThinkingControl(
                isEnabled: explicit ?? false,
                isExplicit: explicit != nil,
                onSetEnabled: { enabled in
                    DispatchQueue.main.async { persistThinkingOverride(enabled, for: model) }
                }
            )
        }
        guard !options.isEmpty || thinking != nil else { return nil }
        return ModelPickerOptionsControl(
            thinking: thinking,
            options: options,
            values: ModelProfileRegistry.normalizedOptions(for: model, persisted: activeModelOptions),
            defaults: ModelProfileRegistry.defaults(for: model),
            onChange: { optionId, newValue in
                DispatchQueue.main.async {
                    guard selectedModel == model else { return }
                    var updated = activeModelOptions
                    if optionId == "reasoningEffort" {
                        updated.removeValue(forKey: "disableThinking")
                    }
                    if let newValue {
                        updated[optionId] = newValue
                    } else {
                        updated.removeValue(forKey: optionId)
                    }
                    activeModelOptions = updated
                    ModelOptionsStore.shared.saveOptions(updated, for: model)
                }
            }
        )
    }

    /// Semantic-to-stored Thinking write (upstream): inverted options such as
    /// `disableThinking` never flip their raw boolean directly; nil resets.
    private func persistThinkingOverride(_ enabled: Bool?, for model: String) {
        guard selectedModel == model,
            let thinkingOpt = ModelProfileRegistry.profile(for: model)?.thinkingOption
        else { return }
        var updated = activeModelOptions
        if let enabled, let stored = ModelProfileRegistry.thinkingStoredOption(for: model, enabled: enabled) {
            updated[stored.id] = stored.value
        } else {
            updated.removeValue(forKey: thinkingOpt.id)
        }
        activeModelOptions = updated
        ModelOptionsStore.shared.saveOptions(updated, for: model)
    }

    // MARK: - Auto-Speak Toggle

    @ViewBuilder
    private var autoSpeakToggleChip: some View {
        SelectorChip(isActive: autoSpeakAssistant) {
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) {
                autoSpeakAssistant.toggle()
            }
        } content: {
            HStack(spacing: 5) {
                Image(systemName: autoSpeakAssistant ? "checkmark.square.fill" : "square")
                    .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .semibold))
                    .foregroundColor(autoSpeakAssistant ? theme.accentColor : theme.tertiaryText)
                    .contentTransition(.opacity)

                Text("Auto-speak", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(autoSpeakAssistant ? theme.secondaryText : theme.tertiaryText)
            }
        }
        .localizedHelp("Auto-speak every reply in this chat")
    }


    // MARK: - Sandbox Toggle Chip

    private var effectiveAgentId: UUID {
        agentId ?? Agent.defaultId
    }

    private var isSandboxAvailable: Bool {
        sandboxState.availability.isAvailable
    }

    private var isSandboxEnabled: Bool {
        agentManager.effectiveAutonomousExec(for: effectiveAgentId)?.enabled == true
    }

    private var isSandboxLoading: Bool {
        isSandboxEnabled && (sandboxState.status == .starting || sandboxState.isProvisioning)
    }

    private var isSandboxRunning: Bool {
        sandboxState.status.isRunning
    }

    /// Visible failure for the active agent, surfaced by the registrar via
    /// `SandboxManager.State.shared.activeAgentUnavailability`. When set we
    /// paint the chip red and put the reason in the tooltip so the user
    /// has an in-app signal that something went wrong (instead of finding
    /// out only via the model paraphrasing the system-prompt notice).
    private var sandboxFailure: SandboxToolRegistrar.UnavailabilityReason? {
        sandboxState.activeAgentUnavailability
    }

    private var isSandboxFailed: Bool {
        isSandboxEnabled && sandboxFailure != nil
    }

    private func retrySandbox() {
        let agentId = effectiveAgentId
        Task {
            SandboxToolRegistrar.shared.resetStartupFailures()
            await SandboxToolRegistrar.shared.registerTools(for: agentId)
        }
    }

    /// Primary tap on the sandbox chip. While the sandbox is starting
    /// up — or has failed — we route the click into the Settings →
    /// Sandbox tab so the user can see the real-time provisioning
    /// journey (step list, byte progress, ETA, retry button) instead
    /// of staring at an opaque pulsing pill. Toggling on/off only
    /// makes sense once the sandbox is in a settled state.
    private func handleSandboxChipTap() {
        if isSandboxLoading || isSandboxFailed {
            AppDelegate.shared?.showManagementWindow(initialTab: .sandbox)
            return
        }
        toggleSandbox()
    }

    private func toggleSandbox() {
        let currentConfig = agentManager.effectiveAutonomousExec(for: effectiveAgentId)
        var newConfig = currentConfig ?? .default
        newConfig.enabled.toggle()
        let agentId = effectiveAgentId
        let manager = agentManager
        let willEnable = newConfig.enabled
        let folderService = folderState
        Task {
            // Sandbox and folder backends are mutually exclusive — clear the
            // folder context BEFORE provisioning sandbox so we don't briefly
            // leave both backends "live". On a provision failure we roll the
            // sandbox flag back but leave the folder cleared (the user can
            // re-pick it); avoiding a partial-state mess is worth the extra
            // tap.
            if willEnable && folderService.hasActiveFolder {
                folderService.clearFolder()
            }
            do {
                try await manager.updateAutonomousExec(newConfig, for: agentId)
            } catch {
                // Don't silently swallow provision failures — log loudly and
                // roll the persisted toggle back so the chip flips back to
                // its previous state. The failure reason still flows to the
                // model via SandboxToolRegistrar's unavailability notice.
                debugLog(
                    "[Sandbox] Toggle failed for agent \(agentId): \(error.localizedDescription)"
                )
                var rollback = newConfig
                rollback.enabled.toggle()
                try? await manager.updateAutonomousExec(rollback, for: agentId)
            }
        }
    }

    /// Disable autonomous execution (sandbox) if currently enabled. Used by
    /// folder selection paths to enforce sandbox/folder mutual exclusion at
    /// the tap site instead of by hiding chips.
    private func disableSandboxIfEnabled() async {
        guard isSandboxEnabled else { return }
        var config = agentManager.effectiveAutonomousExec(for: effectiveAgentId) ?? .default
        config.enabled = false
        do {
            try await agentManager.updateAutonomousExec(config, for: effectiveAgentId)
        } catch {
            debugLog(
                "[Sandbox] Failed to disable sandbox for folder backend switch: \(error.localizedDescription)"
            )
        }
    }

    /// Disable sandbox (if enabled) then open the system folder picker.
    /// Drives both the chip's main tap and the context-menu "Change Folder"
    /// item so they share one mutual-exclusion path.
    private func selectFolderWithSandboxOff() {
        Task {
            await disableSandboxIfEnabled()
            _ = await folderState.selectFolder(from: NSApp.keyWindow)
        }
    }

    private var sandboxHelpText: String {
        if let failure = sandboxFailure, isSandboxEnabled {
            return "Sandbox unavailable: \(failure.message)\nClick to open Sandbox settings."
        } else if isSandboxLoading {
            return "Sandbox is starting up — click to view progress."
        } else if isSandboxEnabled && isSandboxRunning {
            return "Sandbox is active — click to disable. Right-click for settings."
        } else if isSandboxEnabled {
            return "Sandbox enabled — container not running"
        } else {
            return "Enable Sandbox for autonomous code execution"
        }
    }

    /// Foreground tint for the chip's icon + dot. Failure beats running so a
    /// briefly-flapping container that came up but failed to provision still
    /// reads as red.
    private var sandboxChipAccent: Color {
        if isSandboxFailed { return .red }
        if isSandboxLoading { return .orange }
        if isSandboxEnabled && isSandboxRunning { return .green }
        return theme.tertiaryText
    }

    private var sandboxToggleChip: some View {
        Button(action: handleSandboxChipTap) {
            HStack(spacing: 5) {
                if isSandboxFailed {
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.red)
                } else if isSandboxLoading {
                    ProgressView()
                        .controlSize(.mini)
                        .scaleEffect(0.6)
                        .frame(width: 8, height: 8)
                        .tint(Color.orange)
                } else if isSandboxEnabled && isSandboxRunning {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                }

                Image(systemName: isSandboxEnabled ? "shippingbox.fill" : "shippingbox")
                    .font(.system(size: CGFloat(theme.captionSize) - 2, weight: .medium))
                    .foregroundColor(sandboxChipAccent)

                Text("Sandbox", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(
                        isSandboxFailed
                            ? .red
                            : (isSandboxEnabled
                                ? (isSandboxRunning ? theme.primaryText : theme.secondaryText)
                                : theme.tertiaryText)
                    )
                    .lineLimit(1)
                    .opacity(isSandboxLoading ? sandboxPulseAmount : 1.0)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(sandboxChipBackground)
            .clipShape(Capsule())
            .overlay(sandboxChipBorder)
            .shadow(
                color: isSandboxFailed
                    ? Color.red.opacity(0.15)
                    : (isSandboxEnabled && isSandboxRunning
                        ? Color.green.opacity(0.12)
                        : (isSandboxHovered ? theme.accentColor.opacity(0.1) : .clear)),
                radius: 4,
                x: 0,
                y: 1
            )
        }
        .buttonStyle(.plain)
        // Intentionally NOT `.disabled(isSandboxLoading)` — the chip
        // stays tappable during provisioning so the user can click
        // through to the Sandbox settings tab and watch the journey
        // unfold. Toggling on/off is intercepted by
        // `handleSandboxChipTap` in that state.
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isSandboxHovered = hovering
            }
        }
        .help(sandboxHelpText)
        .contextMenu {
            if isSandboxFailed {
                Button {
                    retrySandbox()
                } label: {
                    Text("Retry Sandbox", bundle: .module)
                }
            }
            Button {
                AppDelegate.shared?.showManagementWindow(initialTab: .sandbox)
            } label: {
                Text("Open Sandbox Settings", bundle: .module)
            }
        }
        .task(id: isSandboxLoading) {
            sandboxPulseTask?.cancel()
            guard isSandboxLoading else {
                sandboxPulseAmount = 1.0
                return
            }
            sandboxPulseTask = Task {
                while !Task.isCancelled {
                    withAnimation(.easeInOut(duration: 0.8)) {
                        sandboxPulseAmount = 0.4
                    }
                    try? await Task.sleep(nanoseconds: 800_000_000)
                    guard !Task.isCancelled else { break }
                    withAnimation(.easeInOut(duration: 0.8)) {
                        sandboxPulseAmount = 1.0
                    }
                    try? await Task.sleep(nanoseconds: 800_000_000)
                }
            }
        }
    }

    @ViewBuilder
    private var sandboxChipBackground: some View {
        ZStack {
            Capsule()
                .fill(theme.secondaryBackground.opacity(isSandboxHovered || isSandboxEnabled ? 0.95 : 0.8))

            if isSandboxFailed {
                Capsule()
                    .fill(Color.red.opacity(isSandboxHovered ? 0.16 : 0.10))
            } else if isSandboxEnabled && isSandboxRunning {
                Capsule()
                    .fill(Color.green.opacity(isSandboxHovered ? 0.14 : 0.08))
            } else if isSandboxLoading {
                Capsule()
                    .fill(Color.orange.opacity(0.06))
            } else if isSandboxHovered {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [theme.accentColor.opacity(0.06), Color.clear],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
    }

    @ViewBuilder
    private var sandboxChipBorder: some View {
        if isSandboxFailed {
            Capsule()
                .strokeBorder(Color.red.opacity(isSandboxHovered ? 0.45 : 0.30), lineWidth: 1)
        } else if isSandboxEnabled && isSandboxRunning {
            Capsule()
                .strokeBorder(Color.green.opacity(isSandboxHovered ? 0.4 : 0.25), lineWidth: 1)
        } else if isSandboxLoading {
            Capsule()
                .strokeBorder(Color.orange.opacity(isSandboxHovered ? 0.35 : 0.2), lineWidth: 1)
        } else {
            Capsule()
                .strokeBorder(
                    LinearGradient(
                        colors: [
                            theme.glassEdgeLight.opacity(isSandboxHovered ? 0.25 : 0.15),
                            theme.primaryBorder.opacity(isSandboxHovered ? 0.2 : 0.12),
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
        }
    }

    // MARK: - Clipboard Chip

    private var clipboardChipInfo: (icon: String, label: String) {
        guard let content = clipboardService.currentContent else {
            return ("paperclip", "Clipboard")
        }
        switch content {
        case .text:
            return ("text.quote", "Content")
        case .image:
            return ("photo", "Image")
        case .file(let url):
            let kind = Attachment.Kind.document(filename: url.lastPathComponent, content: "", fileSize: 0)
            let icon = Attachment(kind: kind).fileIcon
            return (icon, url.lastPathComponent)
        }
    }

    private var clipboardChipLabel: some View {
        let info = clipboardChipInfo
        return HStack(spacing: 5) {
            Image(systemName: info.icon)
                .font(.system(size: CGFloat(theme.captionSize) - 2, weight: .medium))
                .foregroundColor(theme.accentColor)

            HStack(spacing: 4) {
                Text("Paste \(info.label) From", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(theme.secondaryText)

                Text(clipboardService.lastSourceApp ?? "Clipboard")
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .bold))
                    .foregroundColor(theme.accentColor)
            }
            .lineLimit(1)

            Image(systemName: "chevron.right")
                .font(theme.font(size: CGFloat(theme.captionSize) - 4, weight: .bold))
                .foregroundColor(theme.tertiaryText.opacity(0.7))
                .padding(.leading, 2)
        }
    }

    private var clipboardToggleChip: some View {
        Button(action: attachClipboardSnippet) {
            clipboardChipLabel
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    Capsule()
                        .fill(theme.secondaryBackground.opacity(isClipboardHovered ? 0.95 : 0.8))
                )
                .clipShape(Capsule())
                .overlay(
                    // main static border
                    Capsule()
                        .strokeBorder(
                            LinearGradient(
                                colors: [
                                    theme.glassEdgeLight.opacity(isClipboardHovered ? 0.25 : 0.15),
                                    theme.accentColor.opacity(isClipboardHovered ? 0.6 : 0.15),
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            lineWidth: 1
                        )
                )
                .overlay(
                    // animated clockwise border sweep using custom shape to fix vertical frame issue
                    ClipboardSweepShape()
                        .trim(from: 0, to: clipboardPulseAmount)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    theme.glassEdgeLight.opacity(0.8),
                                    theme.accentColor,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            style: StrokeStyle(lineWidth: 1.5, lineCap: .round)
                        )
                        .opacity(clipboardPulseOpacity)
                )
                .overlay(
                    // accompanying glow that follows the sweep
                    ClipboardSweepShape()
                        .trim(from: 0, to: clipboardPulseAmount)
                        .stroke(theme.accentColor, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .opacity(clipboardPulseOpacity * 0.4)
                        .blur(radius: 3)
                )
                .shadow(
                    color: theme.accentColor.opacity(isClipboardHovered ? 0.35 : (0.05 + clipboardPulseOpacity * 0.2)),
                    radius: isClipboardHovered ? 6 : (4 + clipboardPulseOpacity * 4),
                    x: 0,
                    y: 1
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isClipboardHovered = hovering
            }
        }
        .help(Text(localized: "Attach snippet from \(clipboardService.lastSourceApp ?? "clipboard")"))
        .contextMenu {
            Button {
                clipboardService.markAsRead()
            } label: {
                Text("Dismiss", bundle: .module)
            }
            Divider()
            if let content = clipboardService.currentContent {
                switch content {
                case .text(let text):
                    Button {
                        if text.utf8.count >= Self.pastedContentThreshold {
                            withAnimation(theme.springAnimation()) {
                                pendingAttachments.append(.pastedContent(text))
                            }
                        } else {
                            localText += text
                        }
                        clipboardService.markAsRead()
                    } label: {
                        Text("Paste to Input", bundle: .module)
                    }
                case .file:
                    Button {
                        attachClipboardSnippet()
                    } label: {
                        Text("Attach File", bundle: .module)
                    }
                case .image:
                    Button {
                        attachClipboardSnippet()
                    } label: {
                        Text("Attach Image", bundle: .module)
                    }
                }
            }
        }
        .transition(.scale(scale: 0.8).combined(with: .opacity))
        .onAppear {
            if clipboardService.hasNewContent {
                triggerPulse()
            }
        }
        .onChange(of: clipboardService.hasNewContent) { newValue in
            if newValue {
                triggerPulse()
            }
        }
    }

    private func triggerPulse() {
        // reset state immediately and hide animation layers
        clipboardPulseAmount = 0
        clipboardPulseOpacity = 0

        // small delay to ensure the window transition is complete
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            withAnimation(.easeIn(duration: 0.1)) {
                clipboardPulseOpacity = 1.0
            }

            // animate the stroke clockwise around the capsule
            withAnimation(.easeInOut(duration: 0.8)) {
                clipboardPulseAmount = 1.0
            }

            // fade out after completion
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
                withAnimation(.easeOut(duration: 0.4)) {
                    clipboardPulseOpacity = 0
                }
            }
        }
    }

    private func attachClipboardSnippet() {
        guard let content = clipboardService.currentContent else { return }

        switch content {
        case .text(let text):
            if text.utf8.count >= Self.pastedContentThreshold {
                // Large paste → convert to a "pasted content" attachment.
                // Lets the user view / remove the snippet without polluting
                // the input field with hundreds of lines of text.
                withAnimation(theme.springAnimation()) {
                    pendingAttachments.append(.pastedContent(text))
                    clipboardService.markAsRead()
                    isFocused = true
                }
            } else {
                // Inject directly into the text input area for better UX (editing)
                withAnimation(theme.springAnimation()) {
                    if localText.isEmpty {
                        localText = text
                    } else {
                        if !localText.hasSuffix("\n") {
                            localText += "\n"
                        }
                        localText += text
                    }
                    clipboardService.markAsRead()
                    isFocused = true
                }
            }

        case .image(let data):
            withAnimation(theme.springAnimation()) {
                pendingAttachments.append(.image(data))
                clipboardService.markAsRead()
            }

        case .file(let url):
            if DocumentParser.isImageFile(url: url) {
                let animation = theme.springAnimation()
                Task { @MainActor in
                    // The image decode and PNG re-encode block for seconds
                    // on a large file, so they run off the main actor.
                    let pngData = await Task.detached(priority: .userInitiated) {
                        () -> Data? in
                        guard let data = try? Data(contentsOf: url),
                            let nsImage = NSImage(data: data)
                        else { return nil }
                        return nsImage.pngData()
                    }.value
                    guard let pngData else { return }
                    withAnimation(animation) {
                        pendingAttachments.append(.image(pngData))
                        clipboardService.markAsRead()
                    }
                }
            } else if DocumentParser.canParse(url: url) {
                let animation = theme.springAnimation()
                Task.detached(priority: .userInitiated) {
                    do {
                        let attachments = try DocumentParser.parseAll(url: url)
                        await MainActor.run {
                            withAnimation(animation) {
                                self.pendingAttachments.append(contentsOf: attachments)
                                self.clipboardService.markAsRead()
                            }
                        }
                    } catch {
                        _ = await MainActor.run {
                            ToastManager.shared.error(L("Could not attach file"), message: error.localizedDescription)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Folder Context Chip

    private var folderContextChip: some View {
        let hasFolder = folderState.hasActiveFolder

        return HStack(spacing: 4) {
            Button(action: selectFolderWithSandboxOff) {
                folderChipContent(hasFolder: hasFolder, canEdit: true)
            }
            .buttonStyle(.plain)
            .help(hasFolder ? Text(localized: "Change working folder") : Text(localized: "Select a working folder"))
            // The selected-folder name is decorative in the chip, so expose a
            // stable name, value, and identifier to VoiceOver and UI tests.
            .accessibilityLabel(Text("Folder", bundle: .module))
            .accessibilityValue(Text(verbatim: hasFolder
                ? (folderState.context?.rootPath.lastPathComponent ?? "") : ""))
            .accessibilityIdentifier("composer.folderChip")
            .contextMenu {
                if hasFolder {
                    Button {
                        selectFolderWithSandboxOff()
                    } label: {
                        Label {
                            Text("Change Folder", bundle: .module)
                        } icon: {
                            Image(systemName: "folder.badge.gear")
                        }
                    }
                    Button {
                        Task { await folderState.refreshContext() }
                    } label: {
                        Label {
                            Text("Refresh Context", bundle: .module)
                        } icon: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    Divider()
                    Button(role: .destructive) {
                        folderState.clearFolder()
                    } label: {
                        Label {
                            Text("Clear Folder", bundle: .module)
                        } icon: {
                            Image(systemName: "folder.badge.minus")
                        }
                    }
                }
                agentDefaultFolderMenuItems
                recentFolderMenuItems
            }

            if hasFolder {
                Button {
                    folderState.clearFolder()
                } label: {
                    Image(systemName: "xmark")
                        .font(theme.font(size: CGFloat(theme.captionSize) - 4, weight: .bold))
                        .foregroundColor(theme.tertiaryText)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(theme.secondaryBackground.opacity(0.8)))
                        .overlay(Circle().strokeBorder(theme.primaryBorder.opacity(0.5), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .localizedHelp("Clear folder selection")
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
        .animation(.easeOut(duration: 0.15), value: hasFolder)
    }

    /// The agent's default working folder (upstream #25). Intel makes it an
    /// explicit choice instead of saving every pick.
    @ViewBuilder
    private var agentDefaultFolderMenuItems: some View {
        let id = agentId ?? Agent.defaultId
        if id != Agent.defaultId, let agent = AgentManager.shared.agent(for: id) {
            let current = folderState.persistedPath
            let saved = agent.workingFolderPath
            if let current, current != saved {
                Divider()
                Button {
                    AgentManager.shared.setWorkingFolder(path: current, for: id)
                    ToastManager.shared.success(
                        L("Default folder saved"),
                        message: L("New chats with \(agent.name) will open in this folder."))
                } label: {
                    Label {
                        Text("Use as Default for \(agent.name)", bundle: .module)
                    } icon: {
                        Image(systemName: "pin")
                    }
                }
            }
            if saved != nil {
                if current == nil || current == saved { Divider() }
                Button {
                    AgentManager.shared.setWorkingFolder(path: nil, for: id)
                } label: {
                    Label {
                        Text("Stop Using a Default Folder", bundle: .module)
                    } icon: {
                        Image(systemName: "pin.slash")
                    }
                }
            }
        }
    }

    /// Recent working folders (upstream 3034800ef), excluding the current
    /// one. Intel shows them in the folder chip's context menu.
    @ViewBuilder
    private var recentFolderMenuItems: some View {
        let current = folderState.persistedPath
        let recents = recentFolders.entries.filter { $0.path != current }
        if !recents.isEmpty {
            Divider()
            Section {
                ForEach(recents) { entry in
                    Button {
                        useRecentFolder(entry)
                    } label: {
                        Label {
                            Text(verbatim: entry.name)
                        } icon: {
                            Image(systemName: "folder")
                        }
                    }
                    .help(Text(verbatim: entry.path))
                }
            } header: {
                Text("Recent Folders", bundle: .module)
            }
        }
    }

    private func useRecentFolder(_ entry: RecentFoldersStore.Entry) {
        Task {
            guard let url = await RecentFoldersStore.resolveURL(for: entry) else {
                RecentFoldersStore.shared.remove(path: entry.path)
                ToastManager.shared.error(
                    L("Folder not found"),
                    message: L("It was moved or deleted, so it was removed from Recent Folders.")
                )
                return
            }
            await disableSandboxIfEnabled()
            if await folderState.setFolder(url) != nil {
                RecentFoldersStore.shared.record(path: url.standardizedFileURL.path)
            }
        }
    }

    @ViewBuilder
    private func folderChipContent(hasFolder: Bool, canEdit: Bool) -> some View {
        HStack(spacing: 4) {
            Image(systemName: hasFolder ? "folder.fill" : "folder.badge.plus")
                .font(theme.font(size: CGFloat(theme.captionSize) - 2))
                .foregroundColor(hasFolder ? theme.accentColor : theme.tertiaryText)
                .opacity(canEdit ? 1.0 : 0.7)

            if let context = folderState.context {
                Text(context.rootPath.lastPathComponent)
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(canEdit ? theme.secondaryText : theme.tertiaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if canEdit {
                Text("Folder", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.captionSize), weight: .medium))
                    .foregroundColor(theme.tertiaryText)
            }

            if canEdit {
                Image(systemName: "chevron.up.chevron.down")
                    .font(theme.font(size: CGFloat(theme.captionSize) - 3, weight: .semibold))
                    .foregroundColor(theme.tertiaryText)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule()
                .fill(theme.secondaryBackground.opacity(canEdit ? 0.6 : 0.4))
        )
        .overlay(
            Capsule()
                .strokeBorder(theme.primaryBorder.opacity(canEdit ? 0.4 : 0.2), lineWidth: 0.5)
        )
    }

    private var keyboardHint: some View {
        HStack(spacing: 4) {
            Text("⏎")
                .font(theme.font(size: CGFloat(theme.captionSize) - 2, weight: .medium))
            Text("to send", bundle: .module)
                .font(theme.font(size: CGFloat(theme.captionSize) - 1))
        }
        .foregroundColor(theme.tertiaryText.opacity(0.7))
    }

    private func dismissModelPicker() {
        showModelPicker = false
    }

    // MARK: - Compaction notice

    /// Offered when the chat nears the context limit (upstream #136). Intel
    /// never compacts on its own: it's a paid call, so the user decides.
    private var compactionNotice: some View {
        HStack(spacing: 8) {
            if isCompacting {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("Summarizing older messages…", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
            } else {
                Image(systemName: "exclamationmark.bubble")
                    .font(.system(size: 11))
                    .foregroundColor(theme.warningColor)
                Text("This chat is getting long for the model. Compact older messages to keep going.", bundle: .module)
                    .font(.system(size: 11))
                    .foregroundColor(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                Button {
                    onCompact?()
                } label: {
                    Text("Compact", bundle: .module)
                }
                .buttonStyle(ThemedBorderedButtonStyle(prominent: true))
                .controlSize(.small)
                .disabled(isStreaming)
                .localizedHelp("Summarizes the older part of this chat with the current model (one cloud request). The full chat stays visible.")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.warningColor.opacity(0.08))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(theme.warningColor.opacity(0.3), lineWidth: 1))
        )
    }

    // MARK: - Input Card

    private var inputCard: some View {
        let hasChipRow = !pendingAttachments.isEmpty || pendingSkillId != nil || queuedSend != nil
        return VStack(alignment: .leading, spacing: 0) {
            if (suggestCompaction || isCompacting), onCompact != nil {
                compactionNotice
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }
            if hasChipRow {
                HStack(alignment: .center, spacing: 6) {
                    queuedSendChipView
                    pendingSkillChipView
                    if !pendingAttachments.isEmpty {
                        inlinePendingAttachmentsPreview
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
            }

            textInputArea
                .padding(.horizontal, 12)
                .padding(.top, hasChipRow ? 6 : 10)
                .padding(.bottom, 6)

            buttonBar
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
        }
        .fixedSize(horizontal: false, vertical: true)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(effectiveBorderStyle, lineWidth: isDragOver ? 2 : (isFocused ? 1.5 : 0.5))
        )
        /*
        .shadow(
            color: shadowColor,
            radius: isFocused ? 12 : 6,
            x: 0,
            y: isFocused ? 4 : 2
        )
        */
        .animation(.easeOut(duration: 0.15), value: isFocused)
        .animation(.easeOut(duration: 0.1), value: isDragOver)
    }

    // MARK: - Voice Input Button

    private var voiceInputButton: some View {
        // Only render the disabled "loading…" state when mic access has
        // actually been granted. For `.notDetermined`/`.denied` the model
        // can't be used yet, and a background autoload (e.g.
        // `SpeechService.autoLoadIfNeeded` at launch) would otherwise
        // freeze the button and swallow the tap that needs to surface
        // either the system mic prompt or the denied alert.
        let micAuthorized = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        return Group {
            if speechService.isLoadingModel && micAuthorized {
                // Original disabled-spinner state — only when mic is
                // already authorized, since otherwise no model load is
                // running and the tap must remain free to surface either
                // the system prompt or the denied alert.
                InputActionButton(
                    icon: "mic.fill",
                    help: "Loading voice model…",
                    action: {}
                )
                .overlay(
                    ProgressView()
                        .scaleEffect(0.5)
                        .allowsHitTesting(false)
                )
                .disabled(true)
                .opacity(0.5)
            } else {
                InputActionButton(
                    icon: "mic.fill",
                    help: "Voice input (speak to type)",
                    action: { startVoiceInput() }
                )
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.96)))
    }

    private func appendAttachment(_ attachment: Attachment) {
        withAnimation(theme.springAnimation()) {
            pendingAttachments.append(attachment)
        }
    }

    private func parseAndAttach(url: URL) {
        let filename = url.lastPathComponent
        let animation = theme.springAnimation()
        Task.detached(priority: .userInitiated) {
            do {
                let attachments = try DocumentParser.parseAll(url: url)
                await MainActor.run {
                    withAnimation(animation) {
                        self.pendingAttachments.append(contentsOf: attachments)
                    }
                }
            } catch {
                _ = await MainActor.run {
                    ToastManager.shared.error(
                        L("Could not attach \(filename)"),
                        message: error.localizedDescription
                    )
                }
            }
        }
    }

    /// Capability-gated UTType allowlist for both the file picker and
    /// the drop zone. Resolves from `selectedModel` plus the session's
    /// already-known image support bit. Text-only models keep document
    /// attach support but reject image/audio/video media.
    ///
    /// See `Models/Configuration/ModelMediaCapabilities.swift` for the
    /// substring/regex matcher; tests pin the boundary at
    /// `ModelMediaCapabilitiesMCDCTests`.
    private var mediaCapabilities: ModelMediaCapabilities.Capabilities {
        ModelMediaCapabilities.composerCapabilities(
            modelId: selectedModel,
            fallbackSupportsImages: supportsImages
        )
    }

    /// UTTypes the drop zone advertises. `fileURL` stays enabled for
    /// documents, while image/audio/video are advertised only when the
    /// selected model can consume them.
    private var dropAcceptedTypes: [UTType] {
        var types: [UTType] = [UTType.fileURL]
        let cap = mediaCapabilities
        if cap.supportsImage {
            types.append(.image)
        }
        if cap.supportsAudio {
            types.append(.audio)
            // explicit common audio formats so HEIF-style "any audio"
            // type negotiation doesn't miss specific containers
            types.append(.mp3)
            types.append(.wav)
            types.append(.mpeg4Audio)
        }
        if cap.supportsVideo {
            types.append(.movie)
            types.append(.video)
            types.append(.quickTimeMovie)
            types.append(.mpeg4Movie)
        }
        return types
    }

    /// File-picker `allowedContentTypes`. Same gating as `dropAcceptedTypes`
    /// but flattened (no fileURL parent — picker accepts concrete types
    /// only). Picker shows audio/video formats only when the loaded
    /// model can actually consume them.
    private var pickerAllowedTypes: [UTType] {
        var types: [UTType] = []
        let cap = mediaCapabilities
        if cap.supportsImage {
            types.append(.image)
        }
        types.append(contentsOf: DocumentParser.supportedDocumentTypes)
        if cap.supportsAudio {
            types.append(.audio)
            types.append(.mp3)
            types.append(.wav)
            types.append(.mpeg4Audio)
        }
        if cap.supportsVideo {
            types.append(.movie)
            types.append(.video)
            types.append(.quickTimeMovie)
            types.append(.mpeg4Movie)
        }
        return types
    }

    private func pickAttachment() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = pickerAllowedTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.message =
            mediaCapabilities.anyMedia
            ? "Select files to attach (\(mediaCapabilities.summary) supported)"
            : "Select files to attach"

        if panel.runModal() == .OK {
            for url in panel.urls {
                attachIfAllowed(url: url)
            }
        }
    }

    /// Routes a file URL to the right attachment kind based on its
    /// extension + the loaded model's capabilities. Drops files that
    /// the current model can't consume rather than silently attaching
    /// them as opaque documents.
    private func attachIfAllowed(url: URL) {
        let ext = url.pathExtension.lowercased()
        let cap = mediaCapabilities

        // Image fast path — only for image-capable models.
        if DocumentParser.isImageFile(url: url) {
            guard cap.supportsImage else {
                ToastManager.shared.error(
                    L("Cannot attach \(url.lastPathComponent)"),
                    message:
                        cap.anyMedia
                        ? L("The current model supports \(cap.summary) only.")
                        : L("The current model is text-only.")
                )
                return
            }
            let sizeLimit = maxImageSize
            Task { @MainActor in
                // The image decode and PNG re-encode block for seconds on a
                // large file, so they run off the main actor and only the
                // finished bytes are attached here.
                let pngData = await Task.detached(priority: .userInitiated) {
                    () -> Data? in
                    guard let data = try? Data(contentsOf: url), data.count <= sizeLimit,
                        let nsImage = NSImage(data: data)
                    else { return nil }
                    return nsImage.pngData()
                }.value
                if let pngData {
                    appendAttachment(.image(pngData))
                }
            }
            return
        }

        // Audio path — only for omni models.
        if cap.supportsAudio, audioExtensions.contains(ext) {
            attachAudio(url: url, ext: ext)
            return
        }

        // Video path — Qwen-VL family + SmolVLM 2 + Nemotron-Omni.
        if cap.supportsVideo, videoExtensions.contains(ext) {
            attachVideo(url: url)
            return
        }

        // Document fallback — markdown, PDF, etc.
        if DocumentParser.canParse(url: url) {
            parseAndAttach(url: url)
            return
        }

        // Reject otherwise — surface a toast so the user knows why.
        ToastManager.shared.error(
            L("Cannot attach \(url.lastPathComponent)"),
            message:
                cap.anyMedia
                ? L("The current model supports \(cap.summary) only.")
                : L("The current model is text-only.")
        )
    }

    private static let audioExtensions: Set<String> = [
        "wav", "mp3", "m4a", "flac", "ogg", "opus", "aac", "wma",
    ]

    private static let videoExtensions: Set<String> = [
        "mp4", "mov", "m4v", "qt", "webm", "mkv", "avi",
    ]

    private var audioExtensions: Set<String> { Self.audioExtensions }
    private var videoExtensions: Set<String> { Self.videoExtensions }

    /// Attach audio bytes from a file URL. Reads inline; spillover to
    /// the encrypted blob store is handled later in the chat-history
    /// persistence layer (`AttachmentBlobStore.spillIfNeeded`) when
    /// the turn is committed. Format string is the lowercased file
    /// extension and flows directly into
    /// `MessageContentPart.audioInput.format`.
    private func attachAudio(url: URL, ext: String) {
        guard let data = try? Data(contentsOf: url) else {
            ToastManager.shared.error(
                L("Could not read \(url.lastPathComponent)"),
                message: L("File may be unreadable or too large to attach.")
            )
            return
        }
        // Cap inline audio at 50 MB — beyond that the user is sending
        // multi-minute clips that should go through a streaming API.
        guard data.count <= 50 * 1024 * 1024 else {
            ToastManager.shared.errorLocalized(
                "Audio file too large",
                message: "Files larger than 50 MB are not supported in chat attachments."
            )
            return
        }
        appendAttachment(.audio(data, format: ext, filename: url.lastPathComponent))
    }

    /// Attach video bytes from a file URL. Same lifecycle as audio,
    /// but with a tighter inline cap (30 MB) since video is bigger
    /// per-second and the runtime extracts only 8 frames anyway.
    private func attachVideo(url: URL) {
        guard let data = try? Data(contentsOf: url) else {
            ToastManager.shared.error(
                L("Could not read \(url.lastPathComponent)"),
                message: L("File may be unreadable or too large to attach.")
            )
            return
        }
        guard data.count <= 100 * 1024 * 1024 else {
            ToastManager.shared.errorLocalized(
                "Video file too large",
                message: "Files larger than 100 MB are not supported. Trim before attaching."
            )
            return
        }
        appendAttachment(.video(data, filename: url.lastPathComponent))
    }

    private func handleFileDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        let cap = mediaCapabilities

        for provider in providers {
            if cap.supportsImage,
                provider.hasItemConformingToTypeIdentifier(UTType.image.identifier)
            {
                handled = true
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, error in
                    guard let data = data, error == nil, data.count <= maxImageSize else { return }
                    // Decode and re-encode on the provider's background queue;
                    // only the finished bytes hop to the main thread.
                    guard let nsImage = NSImage(data: data),
                        let pngData = nsImage.pngData()
                    else { return }
                    DispatchQueue.main.async {
                        appendAttachment(.image(pngData))
                    }
                }
            } else if cap.supportsAudio,
                provider.hasItemConformingToTypeIdentifier(UTType.audio.identifier)
            {
                handled = true
                // Audio path — load via fileURL so we get the extension,
                // not raw data identifier.
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let urlData = item as? Data,
                        let url = URL(dataRepresentation: urlData, relativeTo: nil)
                    else { return }
                    DispatchQueue.main.async {
                        self.attachIfAllowed(url: url)
                    }
                }
            } else if cap.supportsVideo,
                provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier)
                    || provider.hasItemConformingToTypeIdentifier(UTType.video.identifier)
            {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let urlData = item as? Data,
                        let url = URL(dataRepresentation: urlData, relativeTo: nil)
                    else { return }
                    DispatchQueue.main.async {
                        self.attachIfAllowed(url: url)
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                handled = true
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, error in
                    guard let data = item as? Data,
                        let url = URL(dataRepresentation: data, relativeTo: nil)
                    else { return }
                    DispatchQueue.main.async {
                        // attachIfAllowed handles audio/video/image/doc routing
                        // + capability rejection in one place.
                        self.attachIfAllowed(url: url)
                    }
                }
            }
        }
        return handled
    }

    /// Placeholder text for the input field.
    private var placeholderText: String { L("Message or attach files...") }

    private var textInputArea: some View {
        EditableTextView(
            text: $localText,
            fontSize: inputFontSize,
            textColor: theme.primaryText,
            cursorColor: theme.cursorColor,
            isFocused: $isFocused,
            isComposing: $isComposing,
            maxHeight: maxHeight,
            focusController: textViewFocusController,
            spellCheckEnabled: spellCheckEnabled,
            onCommit: { handleInputCommit() },
            onShiftCommit: nil,
            onArrowUp: { handleInputArrowUp() },
            onArrowDown: { handleInputArrowDown() },
            onEscape: (showSlashPopup || showAtPopup) ? { handlePopupEscape() } : nil,
            onPasteText: { pasted in
                guard pasted.utf8.count >= Self.pastedContentThreshold else { return false }
                withAnimation(theme.springAnimation()) {
                    pendingAttachments.append(.pastedContent(pasted))
                }
                return true
            }
        )
        .frame(maxHeight: maxHeight)
        // A different conversation now backs the composer — drop any
        // in-flight history navigation so its index can't recall entries
        // from the previous chat. (Intel: single-value onChange.)
        .onChange(of: inputHistoryKey) { _ in
            inputHistoryState = ChatInputHistoryState()
        }
        .overlay(alignment: .topLeading) {
            // Placeholder - uses theme body size
            if showPlaceholder {
                Text(placeholderText)
                    .font(theme.font(size: inputFontSize, weight: .regular))
                    .foregroundColor(theme.placeholderText)
                    .padding(.leading, 6)
                    .padding(.top, 2)
                    .allowsHitTesting(false)
            }
        }
        .background(
            PasteboardImageMonitor(
                supportsImages: mediaCapabilities.supportsImage,
                onImagePaste: { imageData in
                    withAnimation(theme.springAnimation()) {
                        pendingAttachments.append(.image(imageData))
                    }
                }
            )
        )
    }

    // MARK: - Button Bar

    private var buttonBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                mediaButton
                slashCommandButton
                if isVoiceConfigured {
                    voiceInputButton
                        .disabled(isStreaming)
                        .opacity(isStreaming ? 0.4 : 1.0)
                }
            }

            Spacer()

            HStack(spacing: 8) {
                keyboardHint
                contextBudgetRing
                if isStreaming {
                    stopButton
                    if queuedSend != nil {
                        sendNowButton
                    } else {
                        sendQueueButton
                    }
                } else {
                    sendButton
                }
            }
        }
    }

    // MARK: - Action Buttons

    private var mediaButton: some View {
        InputActionButton(
            icon: "paperclip",
            help: "Attach file (image, PDF, text, etc.)",
            action: pickAttachment
        )
    }

    private var slashCommandButton: some View {
        SlashCommandTriggerButton(isActive: showSlashPopup) {
            guard !showSlashPopup else { return }
            if localText.isEmpty {
                localText = "/"
            } else if localText.last?.isWhitespace == true {
                localText += "/"
            } else {
                localText += " /"
            }
            isFocused = true
        }
    }

    private var stopButton: some View {
        StopButton(action: onStop)
    }

    private var sendButton: some View {
        SendButton(canSend: canSend, action: syncAndSend)
    }

    /// Streaming + empty queue: pressing Send queues the message. Same
    /// dispatcher as `sendButton` (`syncAndSend → onSend`); the parent
    /// notices `isStreaming == true` and routes to `enqueueSend`.
    private var sendQueueButton: some View {
        SendQueueButton(canSend: canSend, action: syncAndSend)
    }

    /// Streaming + a queued message present: pressing this stops the
    /// current run and dispatches the queued payload immediately.
    private var sendNowButton: some View {
        SendNowButton {
            // Stop -> send cascade fans out across more runloop turns
            // than syncAndSend, hence the longer lock.
            textViewFocusController.lockFocus(for: 0.4)
            onSendNow?()
        }
    }

    // MARK: - Card Styling

    private var cardBackground: some View {
        ZStack {
            // NSVisualEffectView-backed glass behind everything, only when
            // the prompt card's own glass toggle is on. The fill above is
            // already semi-transparent so the material shows through.
            if theme.glassInputEnabled {
                ThemedGlassSurface(cornerRadius: 20)
            }

            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(theme.primaryBackground.opacity(theme.isDark ? 0.82 : 0.94))

            // subtle accent gradient at top (enhanced when focused)
            LinearGradient(
                colors: [
                    theme.accentColor.opacity(isFocused ? 0.08 : (theme.isDark ? 0.04 : 0.025)),
                    Color.clear,
                ],
                startPoint: .top,
                endPoint: .center
            )
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        }
    }

    private var effectiveBorderStyle: AnyShapeStyle {
        if isDragOver {
            return AnyShapeStyle(theme.accentColor)
        }
        return borderGradient
    }

    private var borderGradient: AnyShapeStyle {
        if isFocused {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        theme.accentColor.opacity(0.5),
                        theme.accentColor.opacity(0.2),
                        theme.glassEdgeLight.opacity(0.15),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        } else {
            return AnyShapeStyle(
                LinearGradient(
                    colors: [
                        theme.glassEdgeLight.opacity(theme.isDark ? 0.2 : 0.3),
                        theme.primaryBorder.opacity(0.12),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
        }
    }

    private var shadowColor: Color {
        isFocused ? theme.accentColor.opacity(0.18) : theme.shadowColor.opacity(0.12)
    }
}

// MARK: - Clipboard Animation Shape

/// A custom capsule shape that starts its path at the top center to allow for clockwise border sweeps
struct ClipboardSweepShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = rect.height / 2

        // Start at top center (12 o'clock)
        path.move(to: CGPoint(x: rect.midX, y: 0))

        // Top right straight line
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: 0))

        // Right semi-circle
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: radius),
            radius: radius,
            startAngle: Angle(degrees: -90),
            endAngle: Angle(degrees: 90),
            clockwise: false
        )

        // Bottom straight line
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))

        // Left semi-circle
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: radius),
            radius: radius,
            startAngle: Angle(degrees: 90),
            endAngle: Angle(degrees: 270),
            clockwise: false
        )

        // Top left straight line back to center
        path.addLine(to: CGPoint(x: rect.midX, y: 0))

        return path
    }
}

// MARK: - Cached Image Thumbnail

/// A thumbnail view that caches the decoded NSImage to prevent expensive re-decoding on every parent re-render
struct CachedImageThumbnail: View {
    let imageData: Data
    let size: CGFloat
    let onRemove: () -> Void

    @State private var cachedImage: NSImage?
    @Environment(\.theme) private var theme

    var body: some View {
        ZStack(alignment: .topTrailing) {
            if let nsImage = cachedImage {
                let thumbSize = AttachmentThumbnailLayout.size(for: nsImage, longAxis: size)
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: thumbSize.width, height: thumbSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.primaryBorder.opacity(0.3), lineWidth: 1)
                    )
            } else {
                // Square placeholder — aspect is unknown until decode completes.
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(theme.secondaryBackground)
                    .frame(width: size, height: size)
            }

            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(theme.font(size: 16, weight: .regular))
                    .foregroundColor(.white)
                    .background(
                        Circle()
                            .fill(Color.black.opacity(0.6))
                            .frame(width: 18, height: 18)
                    )
            }
            .buttonStyle(.plain)
            .offset(x: 4, y: -4)
        }
        .padding(.top, 4)
        .padding(.trailing, 4)
        .task(id: imageData) {
            cachedImage = NSImage(data: imageData)
        }
    }
}

// MARK: - Pasteboard Image Monitor

/// Monitors for Cmd+V paste events and checks if the pasteboard contains an image
struct PasteboardImageMonitor: NSViewRepresentable {
    let supportsImages: Bool
    let onImagePaste: (Data) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = PasteMonitorView()
        view.supportsImages = supportsImages
        view.onImagePaste = onImagePaste
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let view = nsView as? PasteMonitorView {
            view.supportsImages = supportsImages
            view.onImagePaste = onImagePaste
        }
    }
}

class PasteMonitorView: NSView {
    var supportsImages: Bool = false
    var onImagePaste: ((Data) -> Void)?
    private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil && monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self = self else { return event }
                // Check for Cmd+V
                if event.modifierFlags.contains(.command) && event.charactersIgnoringModifiers == "v" {
                    if self.handlePasteIfImage() {
                        return nil  // Consume the event
                    }
                }
                return event
            }
        }
    }

    override func removeFromSuperview() {
        if let monitor = monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
        super.removeFromSuperview()
    }

    private func handlePasteIfImage() -> Bool {
        guard supportsImages else { return false }

        let pasteboard = NSPasteboard.general

        // Avoid pasteboard type enumeration and object-conversion APIs here.
        // Sentry APPLE-MACOS-43 showed AppKit pasteboard conversion can race
        // paste monitoring on Cmd+V.
        if let imageData = pasteboard.data(forType: .png) {
            onImagePaste?(imageData)
            return true
        }

        if let imageData = pasteboard.data(forType: .tiff) {
            // Consume the event now and convert asynchronously: the decode
            // and PNG re-encode of a large pasted image block for seconds,
            // so they run off the main actor.
            Task { @MainActor [weak self] in
                let pngData = await Task.detached(priority: .userInitiated) {
                    () -> Data? in
                    guard let nsImage = NSImage(data: imageData) else { return nil }
                    return nsImage.pngData()
                }.value
                if let pngData {
                    self?.onImagePaste?(pngData)
                }
            }
            return true
        }

        let fileURLTypes: [NSPasteboard.PasteboardType] = [
            .fileURL,
            NSPasteboard.PasteboardType("public.file-url"),
        ]
        for type in fileURLTypes {
            guard let raw = pasteboard.string(forType: type),
                let url = URL(string: raw),
                url.isFileURL
            else { continue }
            if let uti = try? url.resourceValues(forKeys: [.typeIdentifierKey]).typeIdentifier,
                UTType(uti)?.conforms(to: .image) == true
            {
                // Consume the event now and convert asynchronously: reading
                // and re-encoding a large image file blocks for seconds, so
                // it runs off the main actor.
                Task { @MainActor [weak self] in
                    let pngData = await Task.detached(priority: .userInitiated) {
                        () -> Data? in
                        guard let data = try? Data(contentsOf: url),
                            let nsImage = NSImage(data: data)
                        else { return nil }
                        return nsImage.pngData()
                    }.value
                    if let pngData {
                        self?.onImagePaste?(pngData)
                    }
                }
                return true
            }
        }

        return false
    }
}

// MARK: - NSImage PNG Conversion

extension NSImage {
    /// Convert NSImage to PNG data
    func pngData() -> Data? {
        guard let tiffData = self.tiffRepresentation,
            let bitmap = NSBitmapImageRep(data: tiffData)
        else {
            return nil
        }
        return bitmap.representation(using: .png, properties: [:])
    }
}

// MARK: - Context Breakdown Popover

/// A roll-up of one or more breakdown entries shown as a single legend row.
/// Multi-entry groups collapse behind a disclosure; single-entry groups render
/// as a plain row.
private struct BudgetGroup: Identifiable {
    let id: String
    let label: String
    let tint: ContextBreakdown.Tint
    let entries: [ContextBreakdown.Entry]

    var tokens: Int { entries.reduce(0) { $0 + $1.tokens } }
    var isExpandable: Bool { entries.count > 1 }
}

/// The composer's context-budget panel, presented in the same arrowless,
/// themed card as the wallet and model picker, aligned to the trailing edge
/// of the context ring.
private struct ContextBreakdownPopover: View {
    let breakdown: ContextBreakdown
    /// Usable conversation budget (model maximum × safety margin).
    let maxTokens: Int?
    /// Raw maximum reported by the model bundle/provider fallback.
    let modelMaxTokens: Int?
    /// Intel: where the window came from (model catalog or the Context
    /// Length setting); upstream `AgentLoopBudget.ContextWindowSource`.
    let modelLimitSource: IntelContextBudget.WindowSource?
    let isStreaming: Bool
    let isNearLimit: Bool
    let isHardOverflow: Bool
    let formatTokenCount: (Int) -> String
    /// Session compaction state — drives the inline progress / result row.
    var compactionState: ContextCompactionUIState = .idle
    /// True when the manual "Compact conversation" button should show
    /// (an uncovered older span exists and no turn is streaming).
    var canCompact: Bool = false
    var onCompact: (() -> Void)? = nil
    /// Live disk-cache usage for the footer readout. nil when the disk cache is
    /// off or no quota is configured, in which case the section is hidden
    // Intel: no disk-cache section (the on-SSD prompt cache is MLX-only).
    /// Reports the card height to request: the content's natural height,
    /// capped at `maxPopoverHeight`.
    var onHeightChange: (CGFloat) -> Void = { _ in }


    @Environment(\.theme) private var theme
    @Environment(\.anchoredCardMetrics) private var cardMetrics

    /// Which multi-entry groups are drilled open. Starts empty so the popover
    /// opens in its compact, grouped form.
    @State private var expandedGroups: Set<String> = []

    /// Cap on the popover height (the model picker's cap); longer breakdowns
    /// scroll past this.
    private let maxPopoverHeight: CGFloat = 480

    private var utilization: ContextBudgetUtilization {
        computeContextBudgetUtilization(
            usedTokens: breakdown.total,
            maxTokens: maxTokens
        )
    }

    private var statusColor: Color {
        if isHardOverflow { return theme.errorColor }
        if isNearLimit { return theme.warningColor }
        return theme.accentColor
    }

    private var limitLabel: String? {
        if isHardOverflow { return L("Over limit") }
        if isNearLimit { return L("Near limit") }
        return nil
    }

    /// Each row's share of the *current* total, not of the model's full
    /// window — the window is typically so large (e.g. 262k) that share-of-
    /// budget rounds every category to 0%. Share-of-total instead sums to
    /// ~100% and tracks the stacked bar, which fills the whole track.
    private func percent(_ tokens: Int) -> String {
        let total = breakdown.total
        guard total > 0 else { return "0%" }
        let pct = Int((Double(tokens) / Double(total) * 100).rounded())
        return "\(pct)%"
    }

    /// IDs in `breakdown.context` that read as their own category rather than
    /// folding into the "System Prompt" roll-up. Order here is their canonical
    /// display order beneath the system-prompt group.
    private static let standaloneContextIDs = ["memory", "screenContext", "tools"]

    /// `breakdown.context` rolled into display groups: every manifest prompt
    /// section collapses into one "System Prompt" group; Memory, Screen
    /// Context, and Tools stay as their own rows (they're large and the user
    /// reasons about them individually).
    private var contextGroups: [BudgetGroup] {
        let standalone = Set(Self.standaloneContextIDs)
        var groups: [BudgetGroup] = []

        let sections = breakdown.context.filter { !standalone.contains($0.id) }
        if !sections.isEmpty {
            groups.append(
                BudgetGroup(id: "systemPrompt", label: L("System Prompt"), tint: .indigo, entries: sections)
            )
        }
        for id in Self.standaloneContextIDs {
            if let entry = breakdown.context.first(where: { $0.id == id }) {
                groups.append(BudgetGroup(id: entry.id, label: entry.label, tint: entry.tint, entries: [entry]))
            }
        }
        return groups
    }

    /// Stacked-bar segments — one block per individual entry (every prompt
    /// section, Tools, Memory, and each message row) so the bar shows the full
    /// breakdown. The legend collapses these into groups; the bar does not.
    private var barSegments: [(id: String, tint: ContextBreakdown.Tint, tokens: Int)] {
        breakdown.allEntries
            .filter { $0.tokens > 0 }
            .map { (id: $0.id, tint: $0.tint, tokens: $0.tokens) }
    }

    /// One-line italic notice rendered above the entry list when the
    /// composer auto-disabled features for a small-context model.
    /// `nil` collapses the row entirely so normal-sized models render
    /// the same popover they always did.
    private var autoDisableNotice: String? {
        guard let info = breakdown.disable,
            info.disabledTools || info.disabledMemory
        else { return nil }
        let modelLabel =
            info.modelId.flatMap { id in
                id.caseInsensitiveCompare("foundation") == .orderedSame
                    || id.caseInsensitiveCompare("default") == .orderedSame
                    ? "Foundation" : id
            } ?? "this model"
        let ctxBlurb = info.contextLength.map { "(~\(formatTokenCount($0)) ctx)" } ?? ""
        let what: String
        switch (info.disabledTools, info.disabledMemory) {
        case (true, true): what = "Tools and memory"
        case (true, false): what = "Tools"
        case (false, true): what = "Memory"
        case (false, false): return nil
        }
        return "\(what) auto-disabled — \(modelLabel) \(ctxBlurb) is too small."
    }

    private func color(for tint: ContextBreakdown.Tint) -> Color {
        switch tint {
        case .purple: return theme.isDark ? Color(red: 0.68, green: 0.52, blue: 1.0) : .purple
        case .blue: return theme.isDark ? Color(red: 0.45, green: 0.68, blue: 1.0) : .blue
        case .orange: return theme.isDark ? Color(red: 1.0, green: 0.68, blue: 0.35) : .orange
        case .green: return theme.isDark ? Color(red: 0.45, green: 0.85, blue: 0.55) : .green
        case .gray: return theme.isDark ? Color(red: 0.58, green: 0.62, blue: 0.68) : Color(white: 0.55)
        case .cyan: return theme.isDark ? Color(red: 0.35, green: 0.82, blue: 0.9) : .cyan
        case .teal: return theme.isDark ? Color(red: 0.3, green: 0.75, blue: 0.75) : .teal
        case .indigo: return theme.isDark ? Color(red: 0.55, green: 0.48, blue: 0.95) : .indigo
        }
    }

    // MARK: - Body

    var body: some View {
        // The card hugs its content up to `maxPopoverHeight`; a long
        // "System Prompt" drill-down scrolls past that.
        ScrollView(.vertical, showsIndicators: false) {
            contentStack
                .padding(PickerCardMetrics.padding)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    ceil(geometry.size.height)
                } action: { height in
                    onHeightChange(min(height, maxPopoverHeight))
                }
        }
        .intelScrollBounceBasedOnSize()  // Intel: macOS 13.3+
        .frame(
            width: cardMetrics?.visibleSize.width ?? PickerCardMetrics.infoCardWidth,
            height: cardMetrics?.visibleSize.height
        )
        .pickerCardSurface()
    }

    /// The popover's content column. Extracted so `body` can wrap it in a
    /// height-bounded `ScrollView`.
    private var contentStack: some View {
        VStack(alignment: .leading, spacing: 8) {
            PickerCardHeading(title: L("Context budget")) { statusAccessory }

            VStack(alignment: .leading, spacing: PickerCardMetrics.infoSectionSpacing) {
                hero

                if let notice = autoDisableNotice {
                    autoDisableRow(notice)
                }

                if !contextGroups.isEmpty || !breakdown.messages.isEmpty {
                    breakdownSection
                }

                VStack(alignment: .leading, spacing: 0) {
                    if showsCompactionSection {
                        compactionSection
                    }
                    contextWindowCapLink
                }
            }
        }
    }

    /// Status beside the heading. Usage itself lives in the hero, so this
    /// only speaks up for a limit warning or a live turn.
    @ViewBuilder
    private var statusAccessory: some View {
        if let limitLabel {
            Text(verbatim: limitLabel)
                .font(theme.font(size: theme.pickerCardBodySize, weight: .medium))
                .foregroundStyle(statusColor)
        } else if isStreaming {
            HStack(spacing: 5) {
                Circle()
                    .fill(theme.successColor)
                    .frame(width: 6, height: 6)
                Text("Live", bundle: .module)
                    .font(theme.font(size: theme.pickerCardBodySize))
                    .foregroundStyle(theme.secondaryText)
            }
        }
    }

    /// Intel: Settings › Conversation › Advanced › Context Length, the
    /// window Intel falls back to when the catalog doesn't know the model
    /// (upstream links its Context Window Cap under Server › Cache).
    private var contextWindowCapLink: some View {
        PickerCardTextLink(title: L("Open Context Length"), icon: "arrow.up.right") {
            AppDelegate.shared?.showManagementWindow(initialTab: .chat)
            DispatchQueue.main.async {
                SettingsHighlightCoordinator.shared.request("settings.chat.contextLength")
            }
        }
        .localizedHelp("Open Settings → Conversation → Advanced → Context Length")
    }


    /// Horizontal fill gauge for the hero usage and disk-cache readouts.
    private func usageBar(fraction: Double, tint: Color, height: CGFloat) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(theme.tertiaryBackground)
                Capsule()
                    .fill(tint)
                    // Keep a sliver visible at ~0% so the bar reads as a gauge.
                    .frame(width: max(height, min(1, fraction) * proxy.size.width))
            }
        }
        .frame(height: height)
        .animation(.easeOut(duration: 0.2), value: fraction)
    }


    // MARK: - Compaction

    /// The compaction row shows whenever there's something to act on or
    /// report: the manual trigger is available, a run is in flight, or a
    /// run just completed/failed.
    private var showsCompactionSection: Bool {
        if canCompact { return true }
        switch compactionState {
        case .idle, .needsModelSelection: return false
        case .running, .completed, .failed: return true
        }
    }

    /// Helper copy naming the model the next compaction run will use:
    /// the configured compaction model, else the chat's current model
    /// (`IntelContextCompaction.effectiveModelIdentifier`). Read
    /// per-render from the in-memory config cache — no file I/O.
    private var compactionHelperText: String {
        let configured = IntelContextCompaction.configuredModelIdentifier()
        if IntelContextCompaction.usesChatModelFallback(configured: configured) {
            return L(
                "Summarizes older messages with the current chat model to free up context. The visible chat is unchanged. Pick a dedicated model in Settings → Conversation → Advanced → Compaction Model."
            )
        }
        let name = configured.map(Self.shortModelName) ?? ""
        return L("Summarizes older messages with \(name) to free up context. The visible chat is unchanged.")
    }

    /// `provider/model` → `model`; a bare id stays as is.
    private static func shortModelName(_ identifier: String) -> String {
        identifier.split(separator: "/", maxSplits: 1).last.map(String.init) ?? identifier
    }

    @ViewBuilder
    private var compactionSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            switch compactionState {
            case .running(let phase):
                statusRow {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 16, height: 16)
                } text: {
                    Text(verbatim: phase.label)
                }
            case .completed(let savedTokens):
                statusRow {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(theme.successColor)
                } text: {
                    Text("Compacted — ~\(formatTokenCount(savedTokens)) tokens reclaimed", bundle: .module)
                }
            case .failed(let message):
                statusRow {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(theme.warningColor)
                } text: {
                    Text(verbatim: message)
                }
                if canCompact { compactLink(label: L("Retry compaction")) }
            case .idle, .needsModelSelection:
                if canCompact {
                    compactLink(label: L("Compact conversation"))
                }
            }
        }
    }

    /// Icon + message row for a compaction state, aligned with legend rows.
    private func statusRow<Icon: View, Label: View>(
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder text: () -> Label
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            icon()
                .font(.system(size: 11))
                .frame(width: 16)
            text()
                .font(theme.font(size: theme.pickerCardBodySize))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 4)
        .pickerCardRowChrome(highlighted: false, minHeight: PickerCardMetrics.valueRowHeight)
    }

    private func compactLink(label: String) -> some View {
        PickerCardTextLink(title: label, icon: "arrow.down.right.and.arrow.up.left") {
            onCompact?()
        }
        .help(Text(verbatim: compactionHelperText))
    }

    /// The one place usage is stated: tokens against the usable budget, its
    /// share, a fill bar, and the headroom / model-limit caption.
    private var hero: some View {
        let prefix = isStreaming ? "" : "~"
        let captionFont = theme.font(size: theme.pickerCardCaptionSize)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(verbatim: "\(prefix)\(formatTokenCount(breakdown.total))")
                    .font(theme.font(size: theme.pickerCardHeroSize, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(isHardOverflow ? theme.errorColor : theme.primaryText)
                    .contentTransition(.numericText())
                Group {
                    if let maxTokens = utilization.maxTokens {
                        Text("/ \(formatTokenCount(maxTokens)) tokens", bundle: .module)
                    } else {
                        Text("tokens", bundle: .module)
                    }
                }
                .font(theme.font(size: theme.pickerCardBodySize))
                .foregroundStyle(theme.secondaryText)
                Spacer(minLength: 4)
                if let percent = utilization.percent {
                    Text(verbatim: "\(percent)%")
                        .font(theme.font(size: theme.pickerCardBodySize, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(statusColor)
                        .contentTransition(.numericText())
                }
            }

            if let fraction = utilization.fraction {
                usageBar(fraction: fraction, tint: statusColor, height: 6)
            }

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let remaining = utilization.remainingTokens {
                    Text("\(formatTokenCount(remaining)) remaining", bundle: .module)
                        .contentTransition(.numericText())
                } else {
                    Text("Model context limit unavailable", bundle: .module)
                }
                Spacer(minLength: 4)
                if let modelMaxTokens {
                    Text(verbatim: "\(modelLimitLabel) \(formatTokenCount(modelMaxTokens))")
                        .lineLimit(1)
                        .help(
                            Text(
                                "The usable budget is \(Int(IntelContextBudget.safetyMargin * 100))% of the model maximum, leaving room for the reply.",
                                bundle: .module
                            )
                        )
                }
            }
            .font(captionFont)
            .foregroundStyle(theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, PickerCardMetrics.rowInset)
    }

    private var modelLimitLabel: String {
        switch modelLimitSource {
        case .modelCatalog:
            return L("Model maximum")
        case .userSetting:
            // Intel: the catalog doesn't know this model, so the window is
            // Settings › Conversation › Context Length (upstream's label for a
            // window the user chose).
            return L("Your context limit")
        case nil:
            return L("Model maximum")
        }
    }

    private func autoDisableRow(_ notice: String) -> some View {
        statusRow {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.warningColor)
        } text: {
            Text(verbatim: notice)
        }
    }

    /// What the used tokens are made of: the stacked bar directly above its
    /// legend, prompt sources first, then the conversation's messages.
    private var breakdownSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            PickerCardSectionTitle(L("Breakdown"))
            compositionBar
                .padding(.horizontal, PickerCardMetrics.rowInset)
                .padding(.top, 2)
                .padding(.bottom, 6)
                .help(Text("Share of the tokens used in this chat", bundle: .module))
            if !contextGroups.isEmpty {
                contextGroupList
            }
            if !breakdown.messages.isEmpty {
                PickerCardSectionTitle(L("Messages"))
                entryGroup(breakdown.messages, highlightOutput: true)
            }
        }
    }

    // MARK: - Stacked Bar

    private var compositionBar: some View {
        let segments = barSegments
        // Composition deliberately fills its own track. Actual model-window
        // headroom is represented separately by the hero's usage bar.
        let scale = max(breakdown.total, 1)
        return GeometryReader { geo in
            let gapTotal = CGFloat(max(segments.count - 1, 0))
            let available = max(0, geo.size.width - gapTotal)
            let widths = computeContextBudgetSegmentWidths(
                tokens: segments.map(\.tokens),
                totalTokens: scale,
                available: available,
                fillsTrack: true
            )
            HStack(spacing: 1) {
                // Positional identity: segment ids mirror prompt-section ids,
                // which aren't guaranteed unique across the manifest, so keying
                // by id would risk a duplicate-ID ForEach trap.
                ForEach(Array(zip(segments, widths).enumerated()), id: \.offset) { _, pair in
                    let (segment, width) = pair
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(for: segment.tint).opacity(0.85))
                        .frame(width: width)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 3))
        }
        .frame(height: 6)
        .background(RoundedRectangle(cornerRadius: 3).fill(theme.tertiaryBackground))
    }

    // MARK: - Legend

    /// The context legend at group granularity. Expandable groups render a
    /// tappable header that reveals their per-section rows indented beneath.
    private var contextGroupList: some View {
        VStack(alignment: .leading, spacing: PickerCardMetrics.rowSpacing) {
            ForEach(contextGroups) { group in
                if group.isExpandable {
                    let expanded = expandedGroups.contains(group.id)
                    BudgetDisclosureRow(expanded: expanded) {
                        // No withAnimation: the anchored card animates its
                        // own resize from the reported height.
                        if expanded {
                            expandedGroups.remove(group.id)
                        } else {
                            expandedGroups.insert(group.id)
                        }
                    } label: {
                        legendRowContent(
                            tint: group.tint,
                            label: group.label,
                            tokens: group.tokens,
                            disclosure: expanded
                        )
                    }

                    if expanded {
                        // Key by position, not `entry.id`: a prompt section's
                        // id isn't guaranteed unique across the manifest, so
                        // duplicate ForEach IDs would trap. Positional
                        // identity is what we want for a static,
                        // display-only list anyway.
                        ForEach(Array(group.entries.enumerated()), id: \.offset) { _, entry in
                            entryRow(entry, nested: true)
                        }
                    }
                } else if let entry = group.entries.first {
                    entryRow(entry)
                }
            }
        }
    }

    private func entryGroup(_ entries: [ContextBreakdown.Entry], highlightOutput: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: PickerCardMetrics.rowSpacing) {
            ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                entryRow(entry, highlighted: highlightOutput && entry.id == "output")
            }
        }
    }

    private func entryRow(
        _ entry: ContextBreakdown.Entry,
        highlighted: Bool = false,
        nested: Bool = false
    ) -> some View {
        legendRowContent(
            tint: entry.tint,
            label: entry.label,
            tokens: entry.tokens,
            highlighted: highlighted,
            nested: nested
        )
        .pickerCardRowChrome(highlighted: false, minHeight: PickerCardMetrics.valueRowHeight)
    }

    /// Swatch, label, token count and share. `disclosure` adds the rotating
    /// chevron used by expandable groups; `nested` indents a drill-down row
    /// under its group and quiets its text.
    private func legendRowContent(
        tint: ContextBreakdown.Tint,
        label: String,
        tokens: Int,
        disclosure: Bool? = nil,
        highlighted: Bool = false,
        nested: Bool = false
    ) -> some View {
        let textSize = theme.pickerCardBodySize - (nested ? 1 : 0)
        return HStack(spacing: 8) {
            Circle()
                .fill(color(for: tint))
                .frame(width: 7, height: 7)
                .frame(width: 16)

            Text(label)
                .font(theme.font(size: textSize))
                .foregroundStyle(nested ? theme.secondaryText : theme.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)

            if let disclosure {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(theme.tertiaryText)
                    .rotationEffect(.degrees(disclosure ? 90 : 0))
            }

            Spacer(minLength: 6)

            Text(formatTokenCount(tokens))
                .font(theme.font(size: textSize))
                .monospacedDigit()
                .foregroundStyle(highlighted ? color(for: tint) : theme.primaryText)
                .contentTransition(highlighted ? .numericText() : .identity)

            Text(percent(tokens))
                .font(theme.font(size: theme.pickerCardCaptionSize))
                .monospacedDigit()
                .foregroundStyle(theme.tertiaryText)
                .frame(width: 32, alignment: .trailing)
        }
        .padding(.leading, nested ? 24 : 0)
    }
}

/// Expandable legend row ("System Prompt"): the picker's hover fill on an
/// otherwise read-only list, so it reads as the one clickable row.
private struct BudgetDisclosureRow<Label: View>: View {
    let expanded: Bool
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            label()
                .pickerCardRowChrome(highlighted: hovered, minHeight: PickerCardMetrics.valueRowHeight)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .accessibilityValue(expanded ? L("Expanded") : L("Collapsed"))
    }
}

/// Context/token indicator on the right edge of the selector row. Extracted
/// from `FloatingInputCard` so popover hover/pin state re-renders only this
/// chip. All budget math stays in the parent (it also gates sending); this
/// view just renders the passed values. `breakdown` is a closure so the
/// panel's content is computed only while it is open.
private struct FloatingContextChip: View {
    let displayTokens: Int
    let usableTokens: Int?
    let modelMaxTokens: Int?
    /// Intel: where the window came from (upstream passes the resolution).
    let windowSource: IntelContextBudget.WindowSource?
    let isStreaming: Bool
    let isNearLimit: Bool
    let isHardOverflow: Bool
    /// Fraction of the effective budget the next send occupies, driving the
    /// progress ring. nil when the model window is unknown (empty ring).
    let usageRatio: Double?
    let formatTokenCount: (Int) -> String
    let breakdown: () -> ContextBreakdown
    /// LLM compaction state + manual trigger, rendered inside the popover.
    var compactionState: ContextCompactionUIState = .idle
    var canCompact: Bool = false
    var onCompact: (() -> Void)? = nil
    @Environment(\.theme) private var theme

    @State private var showContextBreakdown = false
    /// True when the context panel was opened by click. Hover previews dismiss
    /// automatically; pinned panels remain interactive until an outside click
    /// or a second click on the trigger.
    @State private var contextPanelPinned = false
    @State private var contextHover = HoverPreviewPresence()
    /// Measured before the first presentation, then updated as sections
    /// expand.
    @State private var contextPanelHeight: CGFloat = 0
    @State private var contextHoverTask: Task<Void, Never>?
    /// Delayed dismiss for the context panel. Gives the cursor a grace
    /// period to travel from the trigger into the panel (which lives in its
    /// own window, so hovering it doesn't keep the trigger "hovered").
    @State private var contextDismissTask: Task<Void, Never>?
    var body: some View {
        let warningColor: Color? =
            isHardOverflow ? .red : (isNearLimit ? .orange : nil)
        let prefix = isStreaming ? "" : "~"
        let tokenText =
            if let maxCtx = usableTokens {
                "\(prefix)\(formatTokenCount(displayTokens)) / \(formatTokenCount(maxCtx))"
            } else {
                "\(prefix)\(formatTokenCount(displayTokens))"
            }

        Button {
            contextHoverTask?.cancel()
            contextDismissTask?.cancel()
            if showContextBreakdown && contextPanelPinned {
                showContextBreakdown = false
                contextPanelPinned = false
            } else {
                contextPanelPinned = true
                showContextBreakdown = true
            }
        } label: {
            // Circular budget gauge. Ring-state tinting: amber at ≥85% of
            // the window (soft warning — compaction will engage), red when
            // the non-compactable prefix alone can't fit (send is gated).
            ZStack {
                // Track color comes from a TEXT token, not a border token:
                // borders are tuned to be faint against the background in
                // many themes, while text tokens are guaranteed legible in
                // every theme (custom themes must define them too), so the
                // unused portion of the ring stays visible everywhere.
                Circle()
                    .stroke(theme.tertiaryText.opacity(0.45), lineWidth: 2.5)
                Circle()
                    .trim(from: 0, to: CGFloat(min(1, max(0, usageRatio ?? 0))))
                    .stroke(
                        warningColor ?? theme.accentColor,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 15, height: 15)
            .frame(width: 24, height: 24)
            .contentShape(Circle())
            .animation(.easeOut(duration: 0.2), value: usageRatio)
        }
        .buttonStyle(.plain)
        .pointingHandCursor()
        .help(
            isHardOverflow
                ? String(
                    localized:
                        "Context is full: the system prompt, tools, and input alone exceed this model's window. Shorten the input, disable tools, or pick a larger-context model.",
                    bundle: .module
                )
                : isNearLimit
                    ? String(
                        localized:
                            "Context is nearly full (≥85% of the model window). Older messages will be compacted; consider starting a fresh chat for best quality.",
                        bundle: .module
                    )
                    : String(localized: "Context used: \(tokenText) tokens", bundle: .module)
        )
        .accessibilityLabel(
            Text("Context budget: \(tokenText) tokens", bundle: .module)
        )
        .onHover { hovering in
            contextHover.isOverTrigger = hovering
            if hovering {
                openContextBreakdown()
            } else if !contextPanelPinned {
                scheduleContextDismiss()
            }
        }
        .anchoredCard(
            isPresented: $showContextBreakdown,
            size: CGSize(width: PickerCardMetrics.infoCardWidth, height: contextPanelHeight),
            alignment: .trailing,
            constrainToWindow: true,
            takesFocus: contextPanelPinned,
            accessibilityLabel: L("Context Budget")
        ) {
            // `anchoredCard` builds its content on every render, so gate it
            // to keep `breakdown()` from running while the panel is closed.
            if showContextBreakdown {
                contextPanel
            }
        }
        .onChange(of: showContextBreakdown) { isShown in  // Intel: single-value onChange (macOS 13)
            // Outside-click dismissal flips the binding directly. Clear the
            // pinned state so the next hover behaves as a passive preview.
            if !isShown {
                contextHover.isOverPanel = false
                contextPanelPinned = false
                contextPanelHeight = 0
                contextHoverTask?.cancel()
                contextDismissTask?.cancel()
            }
        }
        .onDisappear {
            contextHoverTask?.cancel()
            contextDismissTask?.cancel()
        }
    }

    private var contextPanel: some View {
        ContextBreakdownPopover(
            breakdown: breakdown(),
            maxTokens: usableTokens,
            modelMaxTokens: modelMaxTokens,
            modelLimitSource: windowSource,
            isStreaming: isStreaming,
            isNearLimit: isNearLimit,
            isHardOverflow: isHardOverflow,
            formatTokenCount: formatTokenCount,
            compactionState: compactionState,
            canCompact: canCompact,
            onCompact: onCompact,
            onHeightChange: { contextPanelHeight = $0 }
        )
        // Keep the panel alive while the cursor is over it, so the user
        // can travel from the trigger and click the disclosure headers.
        .contentShape(Rectangle())
        .onHover { hovering in
            contextHover.isOverPanel = hovering
            if hovering {
                contextDismissTask?.cancel()
            } else if !contextPanelPinned {
                scheduleContextDismiss()
            }
        }
    }

    /// Open the context panel after a short hover dwell, cancelling any
    /// pending dismiss so a quick re-entry doesn't flicker it closed.
    private func openContextBreakdown() {
        contextDismissTask?.cancel()
        contextHoverTask?.cancel()
        contextHoverTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            showContextBreakdown = true
        }
    }

    /// Dismiss the context panel after a grace period, giving the cursor
    /// time to cross the gap into the panel window.
    private func scheduleContextDismiss() {
        contextHoverTask?.cancel()
        contextDismissTask?.cancel()
        guard contextHover.shouldDismiss(isPinned: contextPanelPinned) else { return }
        contextDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled,
                contextHover.shouldDismiss(isPinned: contextPanelPinned)
            else { return }
            showContextBreakdown = false
        }
    }
}


// MARK: - Context Budget Segment Widths

/// Pre-allocates pixel widths for the Context Budget stacked bar so the
/// rendered segments never overflow `available` (the GeometryReader width
/// minus the 1pt gaps between segments) and — when `fillsTrack` is true —
/// fill the track exactly even after rounding/floor adjustments.
///
/// Behavior:
/// - Returns zeros when `available <= 0` or `totalTokens <= 0`.
/// - Initial widths are proportional to `tokens[i] / totalTokens * available`.
/// - Non-zero entries get a 1pt floor so tiny segments stay visible without
///   dominating the bar (the old `3pt` floor caused overflow with 4+ tiny
///   entries plus 1pt inter-item spacing).
/// - If the sum overflows `available`, all widths are scaled by
///   `available / sum` so they fit exactly. This guarantees the bar never
///   spills past the GeometryReader background.
/// - When `fillsTrack` is true (no ceiling case), any remaining slack is
///   redistributed weighted by `tokens[i]` so segments cover the full track.
///   When false (ceiling present), the leftover is the caller's headroom
///   slot, surfaced as a trailing `Spacer`.
func computeContextBudgetSegmentWidths(
    tokens: [Int],
    totalTokens: Int,
    available: CGFloat,
    fillsTrack: Bool
) -> [CGFloat] {
    guard !tokens.isEmpty else { return [] }
    guard available > 0, totalTokens > 0 else {
        return Array(repeating: 0, count: tokens.count)
    }

    let totalDouble = Double(totalTokens)
    let availableDouble = Double(available)

    var widths: [Double] = tokens.map { count in
        guard count > 0 else { return 0 }
        let raw = Double(count) / totalDouble * availableDouble
        return max(raw, 1)
    }

    var sum = widths.reduce(0, +)

    if sum > availableDouble && sum > 0 {
        let scale = availableDouble / sum
        widths = widths.map { $0 * scale }
        sum = widths.reduce(0, +)
    }

    if fillsTrack, sum < availableDouble {
        let slack = availableDouble - sum
        let tokenTotal = tokens.reduce(0, +)
        if tokenTotal > 0 {
            for i in widths.indices where tokens[i] > 0 {
                widths[i] += slack * Double(tokens[i]) / Double(tokenTotal)
            }
        }
    }

    return widths.map { CGFloat($0) }
}

// MARK: - Selector Chip

/// Polished selector chip for model pickers
private struct SelectorChip<Content: View>: View {
    let isActive: Bool
    let action: () -> Void
    @ViewBuilder let content: () -> Content

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            content()
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(chipBackground)
                .clipShape(Capsule())
                .overlay(chipBorder)
                .shadow(
                    color: isHovered || isActive ? theme.accentColor.opacity(0.1) : .clear,
                    radius: 4,
                    x: 0,
                    y: 1
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }

    @ViewBuilder
    private var chipBackground: some View {
        ZStack {
            Capsule()
                .fill(theme.secondaryBackground.opacity(isHovered || isActive ? 0.95 : 0.8))

            if isHovered || isActive {
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.accentColor.opacity(0.06),
                                Color.clear,
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
    }

    private var chipBorder: some View {
        Capsule()
            .strokeBorder(
                LinearGradient(
                    colors: [
                        theme.glassEdgeLight.opacity(isHovered || isActive ? 0.25 : 0.15),
                        (isActive ? theme.accentColor : theme.primaryBorder).opacity(
                            isHovered || isActive ? 0.2 : 0.12
                        ),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 1
            )
    }
}


// MARK: - Input Action Button

/// Polished circular action button for input card (media, voice, etc.)
private struct SlashCommandTriggerButton: View {
    let isActive: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(theme.tertiaryBackground.opacity(isHovered ? 0.95 : 0.8))

                if isHovered {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [theme.accentColor.opacity(0.1), Color.clear],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                Text("/")
                    .font(.system(size: 16, weight: .medium, design: .monospaced))
                    .foregroundColor(
                        isActive ? theme.accentColor : (isHovered ? theme.accentColor : theme.secondaryText)
                    )
            }
            .frame(width: 32, height: 32)
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                theme.glassEdgeLight.opacity(isHovered ? 0.25 : 0.15),
                                theme.primaryBorder.opacity(isHovered ? 0.2 : 0.1),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.5
                    )
            )
        }
        .buttonStyle(.plain)
        .localizedHelp("Browse slash commands")
        .onHover { isHovered = $0 }
    }
}

private struct InputActionButton: View {
    let icon: String
    let help: String
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(theme.tertiaryBackground.opacity(isHovered ? 0.95 : 0.8))

                if isHovered {
                    Circle()
                        .fill(
                            LinearGradient(
                                colors: [
                                    theme.accentColor.opacity(0.1),
                                    Color.clear,
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                }

                Image(systemName: icon)
                    .font(theme.font(size: CGFloat(theme.bodySize), weight: .medium))
                    .foregroundColor(isHovered ? theme.accentColor : theme.secondaryText)
            }
            .frame(width: 32, height: 32)
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                theme.glassEdgeLight.opacity(isHovered ? 0.25 : 0.15),
                                theme.primaryBorder.opacity(isHovered ? 0.2 : 0.1),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: isHovered ? theme.accentColor.opacity(0.15) : .clear,
                radius: 6,
                x: 0,
                y: 2
            )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Send Button

/// Polished send button with hover glow effect
private struct SendButton: View {
    let canSend: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            ZStack {
                // Background gradient
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.accentColor,
                                theme.accentColor.opacity(0.85),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                // Brighter overlay on hover
                if isHovered && canSend {
                    Circle()
                        .fill(Color.white.opacity(0.15))
                }

                Image(systemName: "arrow.up")
                    .font(theme.font(size: CGFloat(theme.bodySize) + 1, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 32, height: 32)
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isHovered ? 0.35 : 0.2),
                                theme.accentColor.opacity(0.3),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: theme.accentColor.opacity(isHovered && canSend ? 0.5 : 0.35),
                radius: isHovered && canSend ? 10 : 6,
                x: 0,
                y: isHovered && canSend ? 4 : 2
            )
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .opacity(canSend ? 1 : 0.5)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .animation(.easeOut(duration: 0.1), value: canSend)
    }
}

// MARK: - Stop Button

/// Polished stop button with red accent
private struct StopButton: View {
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(.white)
                    .frame(width: 8, height: 8)
                Text("Stop", bundle: .module)
                    .font(theme.font(size: CGFloat(theme.captionSize) - 1, weight: .medium))
            }
            .foregroundColor(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                ZStack {
                    Capsule()
                        .fill(Color.red.opacity(isHovered ? 1.0 : 0.9))

                    if isHovered {
                        Capsule()
                            .fill(Color.white.opacity(0.1))
                    }
                }
            )
            .overlay(
                Capsule()
                    .strokeBorder(Color.white.opacity(isHovered ? 0.3 : 0.15), lineWidth: 1)
            )
            .shadow(
                color: Color.red.opacity(isHovered ? 0.4 : 0.25),
                radius: isHovered ? 8 : 4,
                x: 0,
                y: 2
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
}

// MARK: - Send Queue Button

/// Used while a run is streaming and the queue is empty. Pressing it
/// stores the current input as a single-slot pending send (handled by
/// the parent). Shares the exact 32×32 circular footprint of
/// `SendButton`; the only visual delta is a muted gray fill (instead of
/// the accent gradient) plus a hover tooltip that explains the queue
/// semantics. The icon stays `arrow.up` so users still read it as
/// "send".
private struct SendQueueButton: View {
    let canSend: Bool
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(theme.tertiaryBackground.opacity(canSend ? 0.95 : 0.7))

                if isHovered && canSend {
                    Circle()
                        .fill(theme.accentColor.opacity(0.12))
                }

                Image(systemName: "arrow.up")
                    .font(theme.font(size: CGFloat(theme.bodySize) + 1, weight: .semibold))
                    .foregroundColor(theme.secondaryText)
            }
            .frame(width: 32, height: 32)
            .overlay(
                Circle()
                    .strokeBorder(theme.secondaryText.opacity(isHovered ? 0.35 : 0.2), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .opacity(canSend ? 1 : 0.5)
        .localizedHelp("Queue message · sent when current run finishes")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .animation(.easeOut(duration: 0.1), value: canSend)
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
}

// MARK: - Send Now Button

/// Accent-tinted variant that stops the active run and dispatches the
/// queued send immediately. Visible only when a queued message exists.
/// Same 32×32 circular footprint as `SendButton`; differentiated by a
/// `bolt.fill` icon (signals "urgent / now") and a hover tooltip.
private struct SendNowButton: View {
    let action: () -> Void

    @State private var isHovered = false
    @Environment(\.theme) private var theme

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                theme.accentColor,
                                theme.accentColor.opacity(0.85),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )

                if isHovered {
                    Circle()
                        .fill(Color.white.opacity(0.15))
                }

                Image(systemName: "bolt.fill")
                    .font(theme.font(size: CGFloat(theme.bodySize) + 1, weight: .semibold))
                    .foregroundColor(.white)
            }
            .frame(width: 32, height: 32)
            .overlay(
                Circle()
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(isHovered ? 0.35 : 0.2),
                                theme.accentColor.opacity(0.3),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            )
            .shadow(
                color: theme.accentColor.opacity(isHovered ? 0.5 : 0.35),
                radius: isHovered ? 10 : 6,
                x: 0,
                y: isHovered ? 4 : 2
            )
        }
        .buttonStyle(.plain)
        .localizedHelp("Send now · interrupts current run")
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95)))
    }
}

// MARK: - Resume Button

/// Polished resume button with accent color
// MARK: - Preview

#if DEBUG
    struct FloatingInputCard_Previews: PreviewProvider {
        struct PreviewWrapper: View {
            @State private var text = ""
            @State private var model: String? = "foundation"
            @State private var attachments: [Attachment] = []
            @State private var isContinuousVoiceMode: Bool = false
            @State private var voiceInputState: VoiceInputState = .idle
            @State private var showVoiceOverlay: Bool = false
            @State private var activeModelOpts: [String: ModelOptionValue] = [:]

            var body: some View {
                VStack {
                    Spacer()
                    FloatingInputCard(
                        text: $text,
                        selectedModel: $model,
                        pendingAttachments: $attachments,
                        isContinuousVoiceMode: $isContinuousVoiceMode,
                        voiceInputState: $voiceInputState,
                        showVoiceOverlay: $showVoiceOverlay,
                        pickerItems: [
                            .foundation(),
                            ModelPickerItem(
                                id: "mlx-community/Llama-3.2-3B-Instruct-4bit",
                                displayName: "Llama 3.2 3B Instruct 4bit",
                                source: .local,
                                parameterCount: "3B",
                                quantization: "4-bit",
                                isVLM: false
                            ),
                        ],
                        activeModelOptions: $activeModelOpts,
                        isStreaming: false,
                        supportsImages: true,
                        estimatedContextTokens: 2450,
                        onSend: { _ in },
                        onStop: {}
                    )
                }
                .frame(width: 700, height: 400)
                .background(Color(hex: "0f0f10"))
            }
        }

        static var previews: some View {
            PreviewWrapper()
        }
    }
#endif

extension View {
    /// Intel: `scrollBounceBehavior` needs macOS 13.3; earlier Ventura keeps
    /// the default bounce.
    @ViewBuilder
    func intelScrollBounceBasedOnSize() -> some View {
        if #available(macOS 13.3, *) {
            scrollBounceBehavior(.basedOnSize)
        } else {
            self
        }
    }
}
