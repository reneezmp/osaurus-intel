import AppKit
import Foundation
import Testing

@testable import OsaurusCore

@MainActor
@Suite("Intel Ventura rendering contracts")
struct IntelVenturaRenderingTests {
    @Test("Theme appearance follows the rendered background")
    func appearanceUsesBackgroundLuminance() {
        #expect(IntelNativeWindowRendering.inferredDarkBackground(.white) == false)
        #expect(IntelNativeWindowRendering.inferredDarkBackground(.black) == true)
    }

    @Test("Completed assistant turns emit statistics and actions")
    func completedAssistantFooter() {
        let turn = ChatTurn(role: .assistant, content: "Done.")
        turn.timeToFirstToken = 0.4
        turn.generationTokensPerSecond = 12.5
        turn.generationTokenCount = 20

        let blocks = BlockMemoizer().blocks(from: [turn], agentName: "Assistant")

        #expect(blocks.contains { if case .generationStats = $0.kind { true } else { false } })
        #expect(blocks.contains { if case .assistantActions = $0.kind { true } else { false } })
    }

    @Test("Streaming assistant turns do not emit a footer")
    func streamingAssistantHasNoFooter() {
        let turn = ChatTurn(role: .assistant, content: "Still writing")
        turn.generationTokenCount = 3

        let blocks = BlockMemoizer().blocks(
            from: [turn],
            streamingTurnId: turn.id,
            agentName: "Assistant"
        )

        #expect(!blocks.contains { if case .generationStats = $0.kind { true } else { false } })
        #expect(!blocks.contains { if case .assistantActions = $0.kind { true } else { false } })
    }
}
