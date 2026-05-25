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
        let inputBinding = $observedSession.input
        let selModelBinding = $observedSession.selectedModel
        let attBinding = $observedSession.pendingAttachments
        let voiceBinding = $observedSession.isContinuousVoiceMode
        let vstateBinding = $observedSession.voiceInputState
        let overlayBinding = $observedSession.showVoiceOverlay
        let pickerItems: [ModelPickerItem] = filteredPickerItems
        let activeMO = $observedSession.activeModelOptions
        let isStreaming = observedSession.isStreaming
        let supportsImg = observedSession.selectedModelSupportsImages
        let estTokens = observedSession.estimatedContextTokens
        let ctxBreakdown = observedSession.estimatedContextBreakdown
        let fTrigger = focusTrigger
        let agentId = windowState.agentId
        let windowId = windowState.windowId
        let isCompact = windowState.showSidebar
        let onSend: (Any?) -> Void = { manualText in
            if let t = manualText as? String { observedSession.input = t }
            if observedSession.isStreaming {
                let inp = observedSession.input
                let att = observedSession.pendingAttachments
                observedSession.enqueueSend(inp, attachments: att)
            } else { observedSession.sendCurrent() }
        }
        let onStop: () -> Void = { observedSession.stop() }
        let onClear: () -> Void = { observedSession.reset() }
        let onSkill: (String) -> Void = { _ in }
        let onSendNow = { observedSession.sendNowInterrupting() }
        let onCancelSend = { observedSession.cancelQueuedSend() }
        let autoSpeakBinding = $observedSession.autoSpeakAssistant
        let queuedBinding = $observedSession.queuedSend

        FloatingInputCard(
            text: inputBinding,
            selectedModel: selModelBinding,
            pendingAttachments: attBinding,
            isContinuousVoiceMode: voiceBinding,
            voiceInputState: vstateBinding,
            showVoiceOverlay: overlayBinding,
            pickerItems: pickerItems,
            activeModelOptions: activeMO,
            isStreaming: isStreaming,
            supportsImages: supportsImg,
            estimatedContextTokens: estTokens,
            contextBreakdown: ctxBreakdown,
            onSend: onSend,
            onStop: onStop,
            focusTrigger: fTrigger,
            agentId: agentId,
            windowId: windowId,
            isCompact: isCompact,
            onClearChat: onClear,
            onSkillSelected: onSkill,
            pendingSkillId: $observedSession.pendingOneOffSkillId,
            autoSpeakAssistant: $observedSession.autoSpeakAssistant,
            queuedSend: $observedSession.queuedSend,
            onSendNow: onSendNow,
            onCancelQueued: onCancelSend
        )
    }
}
