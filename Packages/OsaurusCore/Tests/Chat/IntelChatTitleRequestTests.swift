import Testing

@testable import OsaurusCore

@Suite("Intel chat title request")
struct IntelChatTitleRequestTests {
    @Test("The title budget leaves room for a thinking model")
    @MainActor
    func budgetMatchesUpstream() {
        let request = ChatSession.titleRequest(
            model: "deepseek-flash", userText: "How do I plant basil?", assistantText: "Use a warm pot.")
        #expect(request.max_tokens == 96)
        #expect(request.messages.count == 2)
        #expect(request.messages.last?.content?.contains("How do I plant basil?") == true)
    }

    @Test("Thinking is switched off exactly when the model has the option")
    @MainActor
    func thinkingOffFollowsTheModelProfile() {
        for model in ["deepseek-flash", "qwen3-8b", "some-unknown-model"] {
            let request = ChatSession.titleRequest(model: model, userText: "Hi", assistantText: "Hello")
            let stored = ModelProfileRegistry.thinkingStoredOption(for: model, enabled: false)
            if let stored {
                #expect(request.modelOptions?[stored.id] == stored.value)
            } else {
                #expect(request.modelOptions == nil)
            }
        }
    }
}
