//
//  ChatInputSection.swift
//  OsaurusCore
//
//  M10.5 Phase B: Extracted FloatingInputCard section from ChatView.
//  Separate View struct preserves @ObservedObject identity and gets its
//  own per-expression type-checking budget.
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
            supportsImages: observedSession.selectedModelSupportsImages,
            estimatedContextTokens: observedSession.estimatedContextTokens,
            contextBreakdown: observedSession.estimatedContextBreakdown,
            onSend: { manualText in
                if let t = manualText { observedSession.input = t }
                if observedSession.isStreaming {
                    observedSession.enqueueSend(observedSession.input, attachments: observedSession.pendingAttachments)
                } else { observedSession.sendCurrent() }
            },
            onStop: { observedSession.stop() },
            focusTrigger: focusTrigger,
            agentId: windowState.agentId,
            windowId: windowState.windowId,
            isCompact: windowState.showSidebar,
            onClearChat: { observedSession.reset() },
            pendingSkillId: $observedSession.pendingOneOffSkillId,
            autoSpeakAssistant: $observedSession.autoSpeakAssistant,
            queuedSend: $observedSession.queuedSend,
            onSendNow: { observedSession.sendNowInterrupting() },
            onCancelQueued: { observedSession.cancelQueuedSend() }
        )
    }
}
